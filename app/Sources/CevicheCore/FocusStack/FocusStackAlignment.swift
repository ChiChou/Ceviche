import Foundation
import simd

/// Breathing correction for a focus bracket. Focusing changes a lens's magnification a little, so photos of one scene
/// from one spot differ by a similarity transform: a small shift and roll from handling, and a scale from focusing.
///
/// Corners found in a sharp photo are often missing from a blurred one, so each pair is registered directly on its
/// pixels instead: coarse-to-fine Gauss–Newton on deliberately blurred log luminance, with a gain and offset for the
/// contrast that defocus takes away. Each photo is registered against its capture-order neighbour, where focus differs
/// least, and directly against the reference; a joint least-squares solve then reconciles all of these with the reference
/// held fixed, so small pairwise scale errors don't add up along the bracket. A weak prior keeps the scale smooth along
/// capture order, which is usually focus order, without requiring it.
enum FocusStackAlignment {
    /// Long edge of the matching proxies.
    static let longEdge = 800

    /// Photos of one scene differ by a few percent at most; anything beyond this is a failed match.
    static func plausible(_ model: HDRSimilarity, width: Int, height: Int) -> Bool {
        abs(model.scale - 1) < 0.12 && abs(model.rotationDegrees) < 4
            && model.displacement(width: Double(width), height: Double(height)) < 0.2 * Double(max(width, height))
    }

    /// A matching proxy pyramid, finest first: log luminance relative to the photo's median, blurred so that differently
    /// focused photos share their coarse structure. The output pixels are never taken from it.
    static func pyramid(_ frame: PanoramaFrame) -> [LuminancePlane] {
        var plane = LuminancePlane(frame, longEdge: longEdge)
        let sorted = plane.values.sorted()
        let median = max(sorted[sorted.count / 2], 1e-5)
        plane.values = plane.values.map { log2($0 / median + 1.0 / 64) }
        plane.values = FocusStackFilters.gaussian(plane.values, width: plane.width, height: plane.height, sigma: 1.5)
        var levels = [plane]
        while let last = levels.last, min(last.width, last.height) >= 64, max(last.width, last.height) > 120 {
            let w = last.width / 2, h = last.height / 2
            var values = [Float](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w {
                let p = 2 * y * last.width + 2 * x
                values[y * w + x] = 0.25 * (last.values[p] + last.values[p + 1] + last.values[p + last.width] + last.values[p + last.width + 1])
            }}
            levels.append(LuminancePlane(width: w, height: h, values: FocusStackFilters.gaussian(values, width: w, height: h, sigma: 0.8)))
        }
        return levels
    }

    /// The similarity mapping `frame`'s proxy coordinates onto `target`'s (continuous coordinates, pixel centres at +0.5),
    /// with the normalized correlation of the registered pair; nil when the registration diverges.
    static func register(_ frame: [LuminancePlane], onto target: [LuminancePlane]) -> (HDRSimilarity, confidence: Double)? {
        guard frame.count == target.count, let coarse = frame.last, let coarseTarget = target.last,
              coarse.width == coarseTarget.width, coarse.height == coarseTarget.height else { return nil }
        // φ: S(q) = q + A(q − centre)·(a, b, tx, ty) maps target points into the frame; g, c match contrast.
        var phi = [0.0, 0, 0, 0, 1, 0]
        let start = coarseShift(coarse, coarseTarget)
        phi[2] = start.x; phi[3] = start.y
        for level in stride(from: frame.count - 1, through: 0, by: -1) {
            if level < frame.count - 1 { phi[2] *= 2; phi[3] *= 2 }
            let f = frame[level], r = target[level]
            let gradient = gradients(f)
            let stride = f.width * f.height > 200_000 ? 2 : 1
            var scale = Double.infinity
            for _ in 0..<40 {
                guard let (step, rms) = gaussNewton(f, gradient, r, phi, robust: scale, stride: stride) else { return nil }
                scale = 1.5 * rms
                for k in 0..<6 { phi[k] += step[k] }
                let centreSize = 0.5 * Double(max(f.width, f.height))
                if abs(step[2]) < 1e-3, abs(step[3]) < 1e-3, abs(step[0]) * centreSize < 1e-3, abs(step[1]) * centreSize < 1e-3 { break }
            }
        }
        let finest = frame[0]
        let centre = SIMD2(Double(finest.width), Double(finest.height)) / 2
        let a = phi[0], b = phi[1]
        let linear = simd_double2x2(columns: (SIMD2(1 + a, b), SIMD2(-b, 1 + a)))
        let toFrame = HDRSimilarity(linear: linear, translation: SIMD2(phi[2], phi[3]) - (linear - matrix_identity_double2x2) * centre)
        let model = toFrame.inverse
        guard model.scale.isFinite, plausible(model, width: finest.width, height: finest.height) else { return nil }
        return (model, correlation(frame[0], target[0], toFrame))
    }

    /// The whole-pixel shift of `frame` against `target` with the least squared difference, searched exhaustively.
    private static func coarseShift(_ frame: LuminancePlane, _ target: LuminancePlane) -> SIMD2<Double> {
        let w = frame.width, h = frame.height, reach = max(2, max(w, h) / 9)
        let fm = frame.values.reduce(0, +) / Float(frame.values.count), tm = target.values.reduce(0, +) / Float(target.values.count)
        var best = (cost: Float.infinity, shift: SIMD2<Int>(0, 0))
        for dy in -reach...reach { for dx in -reach...reach {
            var cost: Float = 0, count = 0
            for y in max(0, -dy)..<min(h, h - dy) {
                let row = y * w, frameRow = (y + dy) * w
                for x in max(0, -dx)..<min(w, w - dx) {
                    let d = (frame.values[frameRow + x + dx] - fm) - (target.values[row + x] - tm)
                    cost += d * d
                }
                count += min(w, w - dx) - max(0, -dx)
            }
            guard count > w * h / 2 else { continue }
            // A slight preference for small shifts settles flat or repetitive scenes.
            let normalized = cost / Float(count) * (1 + 0.002 * Float(dx * dx + dy * dy))
            if normalized < best.cost { best = (normalized, SIMD2(dx, dy)) }
        }}
        return SIMD2(Double(best.shift.x), Double(best.shift.y))
    }

    private static func gradients(_ plane: LuminancePlane) -> (x: [Float], y: [Float]) {
        let w = plane.width, h = plane.height, v = plane.values
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            gx[i] = 0.5 * (v[y * w + min(w - 1, x + 1)] - v[y * w + max(0, x - 1)])
            gy[i] = 0.5 * (v[min(h - 1, y + 1) * w + x] - v[max(0, y - 1) * w + x])
        }}
        return (gx, gy)
    }

    @inline(__always) private static func sample(_ values: [Float], _ w: Int, _ x: Double, _ y: Double) -> Float {
        let x0 = Int(x), y0 = Int(y), fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let i = y0 * w + x0
        let top = values[i] * (1 - fx) + values[i + 1] * fx, bottom = values[i + w] * (1 - fx) + values[i + w + 1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// One damped Gauss–Newton step for φ with Huber weights beyond `robust`, and the residual RMS.
    private static func gaussNewton(_ f: LuminancePlane, _ gradient: (x: [Float], y: [Float]), _ r: LuminancePlane, _ phi: [Double],
                                    robust: Double, stride: Int) -> ([Double], Double)? {
        let w = f.width, h = f.height
        let centre = SIMD2(Double(w), Double(h)) / 2
        let (a, b, tx, ty, g, c) = (phi[0], phi[1], phi[2], phi[3], phi[4], phi[5])
        let chunks = 16
        var partials = [(hessian: [Double], gradient: [Double], squares: Double, count: Int)](repeating: ([Double](repeating: 0, count: 36), [Double](repeating: 0, count: 6), 0, 0), count: chunks)
        partials.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                var hessian = [Double](repeating: 0, count: 36), grad = [Double](repeating: 0, count: 6), squares = 0.0, count = 0
                var y = chunk * stride
                while y < h {
                    for x in Swift.stride(from: 0, to: w, by: stride) {
                        let u = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - centre
                        let sx = Double(x) + 0.5 + a * u.x - b * u.y + tx - 0.5, sy = Double(y) + 0.5 + b * u.x + a * u.y + ty - 0.5
                        guard sx >= 1, sy >= 1, sx < Double(w - 2), sy < Double(h - 2) else { continue }
                        let fv = Double(sample(f.values, w, sx, sy)), fx = Double(sample(gradient.x, w, sx, sy)), fy = Double(sample(gradient.y, w, sx, sy))
                        let residual = g * fv + c - Double(r.values[y * w + x])
                        let weight = abs(residual) <= robust ? 1 : robust / abs(residual)
                        let j = SIMD8<Double>(g * (fx * u.x + fy * u.y), g * (-fx * u.y + fy * u.x), g * fx, g * fy, fv, 1, 0, 0)
                        for m in 0..<6 {
                            grad[m] += weight * j[m] * residual
                            for n in m..<6 { hessian[m * 6 + n] += weight * j[m] * j[n] }
                        }
                        squares += residual * residual; count += 1
                    }
                    y += chunks * stride
                }
                out[chunk] = (hessian, grad, squares, count)
            }
        }
        var hessian = [Double](repeating: 0, count: 36), grad = [Double](repeating: 0, count: 6), squares = 0.0, count = 0
        for p in partials {
            for k in 0..<36 { hessian[k] += p.hessian[k] }
            for k in 0..<6 { grad[k] += p.gradient[k] }
            squares += p.squares; count += p.count
        }
        guard count > 200 else { return nil }
        for m in 0..<6 { for n in 0..<m { hessian[m * 6 + n] = hessian[n * 6 + m] } }
        // Levenberg damping on the diagonal keeps a poorly constrained parameter from jumping.
        for m in 0..<6 { hessian[m * 6 + m] *= 1.001; hessian[m * 6 + m] += 1e-9 }
        guard let step = FocusStackFilters.solve(hessian, grad.map { -$0 }, size: 6), step.allSatisfy(\.isFinite) else { return nil }
        return (step, (squares / Double(count)).squareRoot())
    }

    /// Normalized cross-correlation of the target with the frame sampled through `toFrame`.
    private static func correlation(_ f: LuminancePlane, _ r: LuminancePlane, _ toFrame: HDRSimilarity) -> Double {
        let w = f.width, h = f.height
        var pairs: [(Double, Double)] = []
        pairs.reserveCapacity(w * h / 4)
        for y in Swift.stride(from: 0, to: h, by: 2) { for x in Swift.stride(from: 0, to: w, by: 2) {
            let s = toFrame.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
            guard s.x >= 0, s.y >= 0, s.x < Double(w - 1), s.y < Double(h - 1) else { continue }
            pairs.append((Double(sample(f.values, w, s.x, s.y)), Double(r.values[y * w + x])))
        }}
        guard pairs.count > 100 else { return 0 }
        let n = Double(pairs.count)
        let ma = pairs.reduce(0) { $0 + $1.0 } / n, mb = pairs.reduce(0) { $0 + $1.1 } / n
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (p, q) in pairs { ab += (p - ma) * (q - mb); aa += (p - ma) * (p - ma); bb += (q - mb) * (q - mb) }
        return max(0, ab / max((aa * bb).squareRoot(), 1e-12))
    }

    /// A registration between two photos: `transform` maps `from`'s pixels onto `to`'s.
    struct Link {
        var from: Int
        var to: Int
        var transform: HDRSimilarity
        var confidence: Double
    }

    /// Every photo's transform onto `anchor` from all links at once: least squares over points spread across each linked
    /// photo, with the anchor fixed. Each transform is linear in its parameters (T(p) = p + A(p − centre)·θ), so the
    /// solve is exact rather than iterated. Photos no link connects to the anchor are nil.
    static func solve(links: [Link], count: Int, anchor: Int, order: [Int], width: Int, height: Int) -> [HDRSimilarity?] {
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for link in links { parent[root(link.from)] = root(link.to) }
        let connected = (0..<count).filter { root($0) == root(anchor) && $0 != anchor }
        var slot = [Int: Int]()
        for (k, i) in connected.enumerated() { slot[i] = k }
        let n = 4 * connected.count
        var result = [HDRSimilarity?](repeating: nil, count: count)
        result[anchor] = .identity
        guard n > 0 else { return result }
        var normal = [Double](repeating: 0, count: n * n), rhs = [Double](repeating: 0, count: n)
        func add(_ terms: [(Int, Double)], _ value: Double, weight: Double) {
            for (i, a) in terms {
                rhs[i] += weight * a * value
                for (j, b) in terms { normal[i * n + j] += weight * a * b }
            }
        }
        let centre = SIMD2(Double(width), Double(height)) / 2
        func rows(_ u: SIMD2<Double>) -> [[Double]] { [[u.x, -u.y, 1, 0], [u.y, u.x, 0, 1]] }
        for link in links {
            let weight = max(0.05, link.confidence) * max(0.05, link.confidence)
            for gy in 0..<3 { for gx in 0..<3 {
                let p = SIMD2(Double(width) * (0.1 + 0.4 * Double(gx)), Double(height) * (0.1 + 0.4 * Double(gy)))
                let q = link.transform.apply(p)
                let rowsP = rows(p - centre), rowsQ = rows(q - centre), target = q - p
                for component in 0..<2 {
                    var terms: [(Int, Double)] = []
                    if let s = slot[link.from] { for k in 0..<4 { terms.append((4 * s + k, rowsP[component][k])) } }
                    if let s = slot[link.to] { for k in 0..<4 { terms.append((4 * s + k, -rowsQ[component][k])) } }
                    if !terms.isEmpty { add(terms, target[component], weight: weight) }
                }
            }}
        }
        // Scale changes smoothly along capture order: a weak penalty on its second difference.
        let reach = 0.5 * hypot(Double(width), Double(height)), smoothness = 0.02 * reach
        let sequence = order.filter { $0 == anchor || slot[$0] != nil }
        if sequence.count >= 3 {
            for k in 1..<(sequence.count - 1) {
                var terms: [(Int, Double)] = []
                for (i, factor) in [(sequence[k - 1], 1.0), (sequence[k], -2.0), (sequence[k + 1], 1.0)] {
                    if let s = slot[i] { terms.append((4 * s, factor * smoothness)) }
                }
                if !terms.isEmpty { add(terms, 0, weight: 0.01) }
            }
        }
        for i in 0..<n { normal[i * n + i] += 1e-9 }
        guard let theta = FocusStackFilters.solve(normal, rhs, size: n) else { return result }
        for (i, s) in slot {
            let a = theta[4 * s], b = theta[4 * s + 1], t = SIMD2(theta[4 * s + 2], theta[4 * s + 3])
            let linear = simd_double2x2(columns: (SIMD2(1 + a, b), SIMD2(-b, 1 + a)))
            result[i] = HDRSimilarity(linear: linear, translation: t - (linear - matrix_identity_double2x2) * centre)
        }
        return result
    }

    /// The transform without its scale, turning about the same image centre: alignment for shifts and roll only.
    static func withoutScale(_ model: HDRSimilarity, width: Int, height: Int) -> HDRSimilarity {
        let centre = SIMD2(Double(width), Double(height)) / 2
        let linear = model.linear * (1 / model.scale)
        return HDRSimilarity(linear: linear, translation: model.apply(centre) - linear * centre)
    }
}
