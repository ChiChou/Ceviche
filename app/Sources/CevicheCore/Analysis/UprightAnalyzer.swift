// Includes adaptations from RAWmakase, Copyright (c) 2026 RAWmakase contributors (MIT).
// See app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/rawmakase/SOURCE.txt.
import CoreGraphics
import Foundation
import simd

/// Straight edges in the displayed photo, found by `LineSegmentDetector`, give its
/// vertical and horizontal vanishing points, from which Level, Vertical, Full and Auto are camera rotations at the
/// photo's focal length. The result is stored as homographies of the untransformed photo, the frame the guides live
/// in, so it survives crop rotation, flips and reopening.
public enum UprightAnalyzer {
    typealias V = SIMD3<Double>
    /// A 3×3 matrix as its rows.
    typealias Mat = [V]

    /// A straight edge, its ends in centred coordinates of the displayed photo, y down, in units of its long edge.
    struct Segment {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var length: Double { simd_length(b - a) }
    }
    /// What the analysis found, in the displayed photo's camera frame (x right, y down, z forward).
    struct Vanishing {
        /// Direction of vertical lines, pointing down the photo.
        var vertical: V?
        /// Direction of horizontal lines, orthogonal to `vertical`.
        var horizontal: V?
        /// Roll of the horizon in radians (positive when it falls to the right), for Level when there is no vertical.
        var horizon: Double?
        var isEmpty: Bool { vertical == nil && horizon == nil }
    }

    /// Analyses a preview of the photo as displayed (orientation applied; no crop, straightening, transform or
    /// upright). `quarterTurns` and the flips are those the preview was rendered with, so the corrections can be
    /// expressed in the untransformed photo of `sourceSize`.
    public static func analyze(_ image: CGImage, focal: Double, sourceSize: CGSize, quarterTurns: Int, flipHorizontal: Bool, flipVertical: Bool) -> UprightAnalysis? {
        guard let lines = lineSegments(image) else { return nil }
        let found = vanishingPoints(lines, focal: focal)
        let r = rotations(found)
        var oriented = GeometryAdjustments(); oriented.flipHorizontal = flipHorizontal; oriented.flipVertical = flipVertical
        guard let plan = try? GeometryPlan(size: sourceSize, settings: oriented, quarterTurns: quarterTurns) else { return nil }
        // Untransformed 0–1 coordinates (bottom-left origin) to displayed ones: an affine map, sampled from the plan.
        let o = plan.displayPoint(MaskPoint(x: 0, y: 0)), x = plan.displayPoint(MaskPoint(x: 1, y: 0)), y = plan.displayPoint(MaskPoint(x: 0, y: 1))
        let orient = ProjectiveMap(m: [x.x-o.x, y.x-o.x, o.x, x.y-o.y, y.y-o.y, o.y, 0, 0, 1])
        // Displayed 0–1 coordinates (y up) to centred long-edge units with y down, where the rotations act.
        let long = Double(max(image.width, image.height)), width = Double(image.width)/long, height = Double(image.height)/long
        let centred = ProjectiveMap(m: [width, 0, -width/2, 0, -height, height/2, 0, 0, 1])
        guard let back = try? centred.inverted(), let unorient = try? orient.inverted() else { return nil }
        func stored(_ rotation: Mat) -> [Double]? {
            let g = cameraTurn(rotation, focal: focal)
            let turn = ProjectiveMap(m: [g[0].x, g[0].y, g[0].z, g[1].x, g[1].y, g[1].z, g[2].x, g[2].y, g[2].z])
            let m = orient.followed(by: centred).followed(by: turn).followed(by: back).followed(by: unorient).m
            guard m.allSatisfy(\.isFinite), abs(m[8]) > 1e-9 else { return nil }
            return m.map { $0 / m[8] }
        }
        guard let auto = stored(r.auto), let level = stored(r.level), let vertical = stored(r.vertical), let full = stored(r.full) else { return nil }
        return UprightAnalysis(auto: auto, level: level, vertical: vertical, full: full, empty: found.isEmpty)
    }

    /// Focal length in units of the photo's long edge: the 35 mm equivalent over 36 mm.
    public static func focal(equivalent35mm: Double?, focalLength: Double?, make: String?, model: String?) -> Double {
        let equivalent: Double
        if let equivalent35mm, equivalent35mm > 0 { equivalent = equivalent35mm }
        else if let focalLength, focalLength > 0 {
            // Fujifilm leaves the 35 mm equivalent out; its GFX sensors are 44 mm wide and the rest APS-C.
            let gfx = (make ?? "").uppercased().hasPrefix("FUJIFILM") && (model ?? "").hasPrefix("GFX")
            equivalent = focalLength * (gfx ? 0.79 : 1.5226)
        } else { equivalent = 35 }
        return equivalent / 36
    }

    // MARK: Edges

    /// Edges shorter than this share of the long edge are texture, not structure.
    static let minLength = 0.015
    /// Longest side of the image handed to the detector.
    private static let analysisSize = 1024

    /// Line segments on the photo's luminance. Nil only if the image cannot be read.
    static func lineSegments(_ image: CGImage) -> [Segment]? {
        guard let (luminance, w, h) = luminance(image) else { return nil }
        let long = Double(max(w, h))
        func centred(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2((p.x - Double(w)/2) / long, (p.y - Double(h)/2) / long) }
        return LineSegmentDetector.detect(luminance.map(Float.init), width: w, height: h)
            .map { Segment(a: centred($0.a), b: centred($0.b)) }.filter { $0.length >= minLength }
    }

    /// The image as 0–255 luminance no longer than `analysisSize`, averaged over each pixel's footprint.
    static func luminance(_ image: CGImage) -> ([Double], Int, Int)? {
        let scale = min(1, Double(analysisSize)/Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width)*scale)), h = max(3, Int(Double(image.height)*scale))
        var pixels = [UInt8](repeating: 0, count: w*h)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return nil }
        return (pixels.map { Double($0) }, w, h)
    }

    // MARK: Vanishing points

    /// Minimum support (summed squared length, in long-edge units) of a vanishing direction, and the fewest edges
    /// that may make it up; below either nothing is corrected. A facade's edges span tenths of the photo; the
    /// pillars of a car or the folds of a shirt do not reach this.
    private static let minSupport = 0.04, minSupporters = 3

    static func vanishingPoints(_ segments: [Segment], focal f: Double) -> Vanishing {
        /// The segment's angle in the image, in degrees within [0, 180).
        func angle(_ s: Segment) -> Double {
            let a = atan2(s.b.y - s.a.y, s.b.x - s.a.x) * 180 / .pi
            return a - (a / 180).rounded(.down) * 180
        }
        func tilt(_ d: V) -> Double { atan2(abs(d.z), d.y) * 180 / .pi }
        let nearVertical = segments.filter { abs(angle($0) - 90) < 25 }
        let vertical = fit(nearVertical, focal: f,
            accept: { tilt($0) < 50 && atan2(abs($0.x), $0.y) * 180 / .pi < 20 },
            // Cameras are usually held within a few degrees of plumb: a strong tilt needs strong evidence.
            weight: { 1 / (1 + pow(tilt($0) / 20, 2)) })
            .flatMap { $0.support >= minSupport ? $0.direction : nil }
        let horizontal: V? = vertical.flatMap { v in
            // Within 10° of orthogonal to the vertical, then made exactly so.
            let others = segments.filter { abs(angle($0) - 90) >= 25 }
            guard let found = fit(others, focal: f, accept: { abs(simd_dot($0, v)) < sin(10 * Double.pi / 180) }, weight: { _ in 1 }),
                  found.support >= minSupport else { return nil }
            let projected = unit(found.direction - simd_dot(found.direction, v) * v)
            return projected.x < 0 ? -projected : projected
        }
        // Without a vertical, the long near-level edges give a horizon.
        var sum = 0.0, weight = 0.0
        for s in segments {
            var a = atan2(s.b.y - s.a.y, s.b.x - s.a.x)
            a -= (a / .pi).rounded() * .pi
            if abs(a) < 5 * .pi / 180 { let w = s.length*s.length; sum += w*a; weight += w }
        }
        return Vanishing(vertical: vertical, horizontal: horizontal, horizon: weight >= minSupport ? sum/weight : nil)
    }

    /// The unit normal of the plane through the camera centre and the segment, for focal length `f`.
    static func normal(_ s: Segment, focal f: Double) -> V { unit(simd_cross(V(s.a.x, s.a.y, f), V(s.b.x, s.b.y, f))) }

    /// The direction best supported by `segments`, and its support: the summed squared length of the segments whose
    /// planes pass within 1° of it. Candidates are the intersections of pairs of segments, every pair of the longest
    /// and a length-weighted sample of the rest; the best, by support and `weight`, is then fitted to its supporters.
    /// `accept` rules out directions the caller knows to be implausible.
    static func fit(_ segments: [Segment], focal f: Double, accept: (V) -> Bool, weight: (V) -> Double) -> (direction: V, support: Double)? {
        guard segments.count >= 2 else { return nil }
        let normals = segments.map { normal($0, focal: f) }
        let weights = segments.map { $0.length * $0.length }
        func supporters(_ d: V, within degrees: Double) -> [Int] {
            let limit = sin(degrees * .pi / 180)
            return normals.indices.filter { abs(simd_dot(normals[$0], d)) < limit }
        }
        func support(_ d: V, within degrees: Double) -> Double { supporters(d, within: degrees).reduce(0) { $0 + weights[$1] } }
        func direction(_ i: Int, _ j: Int) -> V? {
            let d = simd_cross(normals[i], normals[j])
            guard simd_length_squared(d) > 1e-18 else { return nil }
            return downward(unit(d))
        }
        var best: (direction: V, score: Double)?
        func consider(_ i: Int, _ j: Int) {
            guard i != j, let d = direction(i, j), accept(d) else { return }
            let score = support(d, within: 2) * weight(d)
            if best == nil || score > best!.score { best = (d, score) }
        }
        let byLength = segments.indices.sorted { weights[$0] > weights[$1] }
        let longest = byLength.prefix(40)
        for (n, i) in longest.enumerated() { for j in longest.dropFirst(n + 1) { consider(i, j) } }
        var cumulative: [Double] = []; cumulative.reserveCapacity(weights.count)
        var total = 0.0
        for w in weights { total += w; cumulative.append(total) }
        var generator = SplitMix64(seed: 0x5EED_0F_11_E5)
        func sample() -> Int {
            let target = Double.random(in: 0..<total, using: &generator)
            var low = 0, high = cumulative.count - 1
            while low < high { let mid = (low + high) / 2; if cumulative[mid] > target { high = mid } else { low = mid + 1 } }
            return low
        }
        if total > 0 { for _ in 0..<400 { consider(sample(), sample()) } }
        guard var d = best?.direction else { return nil }
        // Least squares on the supporters: the direction closest to all their planes.
        for degrees in [2.0, 1.5, 1] {
            var scatter = simd_double3x3(0)
            for i in supporters(d, within: degrees) {
                let n = normals[i]
                scatter += weights[i] * simd_double3x3(columns: (n.x * n, n.y * n, n.z * n))
            }
            guard let refined = smallestEigenvector(scatter).map(downward), accept(refined) else { break }
            d = refined
        }
        let final = supporters(d, within: 1)
        guard final.count >= minSupporters else { return nil }
        return (d, final.reduce(0) { $0 + weights[$1] })
    }

    /// Flips a direction to point down the photo, so the same vanishing point always has the same sign.
    private static func downward(_ d: V) -> V { d.y < 0 || (d.y == 0 && (d.x < 0 || (d.x == 0 && d.z < 0))) ? -d : d }

    /// The unit eigenvector of the smallest eigenvalue of a symmetric matrix: the eigenvalues from the trigonometric
    /// solution of the characteristic cubic, the vector from the null space of `m − λI`. Nil when that eigenvalue
    /// is repeated, so no single direction is distinguished.
    static func smallestEigenvector(_ m: simd_double3x3) -> V? {
        let identity = matrix_identity_double3x3
        let mean = (m[0][0] + m[1][1] + m[2][2]) / 3
        let offDiagonal = m[0][1]*m[0][1] + m[0][2]*m[0][2] + m[1][2]*m[1][2]
        let spread = ((m[0][0] - mean)*(m[0][0] - mean) + (m[1][1] - mean)*(m[1][1] - mean) + (m[2][2] - mean)*(m[2][2] - mean) + 2*offDiagonal) / 6
        guard spread > 1e-24 else { return nil }
        let p = spread.squareRoot()
        let b = (m - mean * identity) * (1 / p)
        let phi = acos(min(1, max(-1, b.determinant / 2))) / 3
        let smallest = mean + 2 * p * cos(phi + 2 * .pi / 3), middle = mean + 2 * p * cos(phi - 2 * .pi / 3)
        guard middle - smallest > 1e-9 * max(1, abs(smallest)) else { return nil }
        let a = m - smallest * identity
        let rows = [V(a[0][0], a[1][0], a[2][0]), V(a[0][1], a[1][1], a[2][1]), V(a[0][2], a[1][2], a[2][2])]
        let candidates = [simd_cross(rows[0], rows[1]), simd_cross(rows[0], rows[2]), simd_cross(rows[1], rows[2])]
        guard let v = candidates.max(by: { simd_length_squared($0) < simd_length_squared($1) }), simd_length_squared(v) > 1e-24 else { return nil }
        return unit(v)
    }

    /// A deterministic generator, so an analysis repeats exactly.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Rotations

    static let identity: Mat = [V(1,0,0), V(0,1,0), V(0,0,1)]
    static func mul(_ a: Mat, _ b: Mat) -> Mat {
        let columns = [V(b[0].x, b[1].x, b[2].x), V(b[0].y, b[1].y, b[2].y), V(b[0].z, b[1].z, b[2].z)]
        return a.map { row in V(simd_dot(row, columns[0]), simd_dot(row, columns[1]), simd_dot(row, columns[2])) }
    }
    static func apply(_ m: Mat, _ v: V) -> V { V(simd_dot(m[0], v), simd_dot(m[1], v), simd_dot(m[2], v)) }
    static func unit(_ a: V) -> V { a / max(1e-12, simd_length(a)) }
    /// Rotation by `angle` radians about `axis` (Rodrigues' formula).
    static func rotation(_ axis: V, _ angle: Double) -> Mat {
        let u = unit(axis), s = sin(angle), c = cos(angle)
        let outer: Mat = [u.x * u, u.y * u, u.z * u]
        let skew: Mat = [V(0, -u.z, u.y), V(u.z, 0, -u.x), V(-u.y, u.x, 0)]
        return (0..<3).map { i in c * identity[i] + s * skew[i] + (1 - c) * outer[i] }
    }
    /// The smallest rotation taking direction `from` to `to`.
    static func align(_ from: V, _ to: V) -> Mat {
        let from = unit(from), to = unit(to), axis = simd_cross(from, to), s = simd_length(axis)
        guard s >= 1e-9 else { return identity }
        return rotation(axis, atan2(s, simd_dot(from, to)))
    }

    /// Level's roll: the turn in the photo's plane that makes its verticals plumb or, without them, its horizon
    /// level.
    static func levelRoll(_ v: Vanishing) -> Double {
        if let d = v.vertical { return atan2(d.x, d.y) }
        return -(v.horizon ?? 0)
    }
    /// How much of a vertical tilt (degrees) Auto removes: nothing below 2°, rising smoothly to 80 % by 12°, then
    /// easing off for strong tilts, which usually are the photographer's intent.
    static func autoTiltShare(_ degrees: Double) -> Double {
        let t = abs(degrees)
        let ramp = min(1, max(0, (t - 2) / 10))
        let ease = t <= 12 ? 1 : 1 / (1 + (t - 12) / 15)
        return 0.8 * ramp * ramp * (3 - 2 * ramp) * ease
    }
    /// The rotations for each mode: Level rolls, Vertical also tilts, Full also pans, Auto removes part of the tilt
    /// and only a slight pan.
    static func rotations(_ v: Vanishing) -> (auto: Mat, level: Mat, vertical: Mat, full: Mat) {
        let down = V(0, 1, 0), forward = V(0, 0, 1)
        let level = rotation(forward, levelRoll(v))
        guard let d = v.vertical else { return (level, level, level, level) }
        let vertical = align(d, down)
        // The tilt that remains once the roll is removed, and what Auto keeps of it.
        let rolled = apply(level, d)
        let tilt = atan2(-rolled.z, rolled.y)
        let kept = tilt * (1 - autoTiltShare(tilt * 180 / .pi))
        var auto = align(d, V(0, cos(kept), -sin(kept)))
        var full = vertical
        if let h = v.horizontal {
            // Pan about the vertical until the horizontals lie in the image plane; the facade turned least wins,
            // so the pan stays within ±45°.
            let h = apply(vertical, h)
            let quarter = Double.pi / 2
            var pan = atan2(h.z, h.x)
            pan -= (pan / quarter).rounded() * quarter
            full = mul(rotation(down, pan), vertical)
            if abs(pan) * 180 / .pi < 5 { auto = mul(rotation(down, 0.5 * pan), auto) }
        }
        return (auto, level, vertical, full)
    }
    /// A camera rotation as the homography it makes of the photo, in centred long-edge units at focal length `f`:
    /// K·R·K⁻¹.
    static func cameraTurn(_ rotation: Mat, focal f: Double) -> Mat {
        let k: Mat = [V(f, 0, 0), V(0, f, 0), V(0, 0, 1)], kInverse: Mat = [V(1/f, 0, 0), V(0, 1/f, 0), V(0, 0, 1)]
        return mul(k, mul(rotation, kInverse))
    }
}
