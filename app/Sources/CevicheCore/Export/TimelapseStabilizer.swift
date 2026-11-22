import Foundation
import CoreGraphics
import ImageIO
import simd

/// How far a frame's view sits from the series' own: the shift of the picture, as fractions of the photo's width and
/// height (top-left origin), and its roll about the centre in radians. A point of the series' view shows at
/// `rotate(point − centre) + centre + shift` in this frame.
public struct TimelapseShift: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var angle: Double
    public init(dx: Double = 0, dy: Double = 0, angle: Double = 0) { self.dx = dx; self.dy = dy; self.angle = angle }
    public static let zero = TimelapseShift()
}

/// Steadying a series shot from a tripod: each frame's small shift and roll from the series' view, measured on the
/// parts of the picture that stay put, and the margin the video's frame gives up so every frame can be moved back.
/// Frames that moved further than a tripod does, or that can't be measured, are left as they are.
public struct TimelapseStabilization: Equatable, Sendable {
    /// By frame position; nil where the frame is left as it is.
    public var shifts: [TimelapseShift?]
    /// Each side's margin, as fractions of the photo's width and height.
    public var margin: CGSize
    /// The steady parts turned with the stars at the sky's own pace: there was no land to hold on to, and every frame
    /// is left as it is.
    public var followedSky = false
    public init(shifts: [TimelapseShift?], margin: CGSize, followedSky: Bool = false) {
        self.shifts = shifts; self.margin = margin; self.followedSky = followedSky
    }

    /// A frame's correction for rendering, or nil when it is left alone and no margin is needed.
    public func frame(_ position: Int) -> Frame? {
        guard shifts.indices.contains(position) else { return nil }
        return Frame(shift: shifts[position] ?? .zero, margin: margin)
    }
    /// The positions the stabilizer couldn't steady.
    public var unsteadied: [Int] { shifts.indices.filter { shifts[$0] == nil } }

    public struct Frame: Equatable, Sendable {
        public var shift: TimelapseShift
        public var margin: CGSize
        public init(shift: TimelapseShift, margin: CGSize) { self.shift = shift; self.margin = margin }
    }
}

public enum TimelapseStabilizer {
    /// A tripod settles, sways in wind or creeps as the lens cools by a fraction of this. Past it, the camera was moved.
    public static let maximumShift = 0.05
    /// Roll past this, in radians (1°), is no tripod drift either.
    public static let maximumAngle = Double.pi / 180
    /// Shifts below this fraction (about a pixel of a 4K video) aren't worth a resample.
    static let negligible = 0.0002
    /// The long edge measurement works at; the catalog's previews are about this size.
    static let workingEdge = 640

    /// The sky turns 15° an hour. A tripod's roll creeps far slower than a fifth of that and its shift than 3 % of the
    /// frame an hour, so steady motion at these paces is stars, not the camera.
    static let skyRoll = 3.0 * Double.pi / 180 / 3600
    static let skyShift = 0.03 / 3600

    /// Measures every frame of `previews`, in playing order; nil previews are left as they are. `times` are the frames'
    /// capture times, to tell the sky's turning from the camera's.
    public static func stabilize(_ previews: [CGImage?], times: [Date?] = [], isCancelled: () -> Bool = { false }) -> TimelapseStabilization {
        stabilize(count: previews.count, times: times, isCancelled: isCancelled) { previews[$0] }
    }

    /// Measures `count` frames in playing order, asking `preview` for each frame's picture as it goes, so a long series
    /// never sits decoded in memory: a few dozen frames for the steady weight, then the reference and the frame in
    /// hand.
    public static func stabilize(count: Int, times: [Date?] = [], isCancelled: () -> Bool = { false },
                                 preview: (Int) -> CGImage?) -> TimelapseStabilization {
        let none = TimelapseStabilization(shifts: Array(repeating: nil, count: count), margin: .zero)
        guard count > 0 else { return none }
        // The reference: a frame in the middle that decodes.
        let order = (0..<count).sorted { abs($0 - count / 2) < abs($1 - count / 2) }
        var found: (Int, Plane)?
        for index in order { if let plane = preview(index).flatMap({ Plane($0, longEdge: workingEdge) }) { found = (index, plane); break } }
        guard let (reference, referencePlane) = found else { return none }
        let width = referencePlane.width, height = referencePlane.height
        func plane(_ index: Int) -> Plane? {
            if index == reference { return referencePlane }
            guard let plane = preview(index).flatMap({ Plane($0, longEdge: workingEdge) }), plane.width == width, plane.height == height else { return nil }
            return plane
        }
        let sampled = count <= 48 ? Array(0..<count) : (0..<48).map { $0 * (count - 1) / 47 }
        let weight = steadyWeight(sampled.compactMap(plane), width: width, height: height)
        let referencePyramid = Pyramid(referencePlane, weight: weight)

        // Each frame on one reference in the middle of the series: chained registrations carry each pair's small bias
        // into the next, and stars or clouds left in the weight bias every pair the same way. Where the light has
        // changed too much for that, the frame is measured on its neighbour toward the reference instead.
        var motions: [Affine?] = Array(repeating: nil, count: count)
        motions[reference] = .identity
        for direction in [-1, 1] {
            var last: (index: Int, pyramid: Pyramid)? = nil, index = reference + direction
            while (0..<count).contains(index), !isCancelled() {
                defer { index += direction }
                guard let frame = plane(index) else { continue }
                let pyramid = Pyramid(frame, weight: weight)
                if let motion = register(pyramid, onto: referencePyramid) {
                    motions[index] = motion; last = (index, pyramid)
                } else if let previous = last, let pair = register(pyramid, onto: previous.pyramid), let chained = motions[previous.index] {
                    motions[index] = pair.then(chained); last = (index, pyramid)
                }
            }
        }
        if isCancelled() { return none }
        // The series' view is its median: the frames that stayed put need nothing, and the margin is shared by
        // either side.
        let measured = motions.compactMap { $0 }
        guard !measured.isEmpty else { return TimelapseStabilization(shifts: motions.map { _ in nil }, margin: .zero) }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        let centre = SIMD2(Double(width), Double(height)) / 2
        let base = Affine.rigid(angle: median(measured.map(\.angle)),
                                shift: SIMD2(median(measured.map { $0.apply(centre).x - centre.x }), median(measured.map { $0.apply(centre).y - centre.y })),
                                centre: centre)
        let inverseBase = base.inverse
        var shifts: [TimelapseShift?] = motions.map { motion in
            guard let motion else { return nil }
            // The frame's motion from the series' view.
            let relative = motion.then(inverseBase)
            let moved = relative.apply(centre) - centre
            let shift = TimelapseShift(dx: moved.x / Double(width), dy: moved.y / Double(height), angle: relative.angle)
            guard abs(shift.dx) <= maximumShift, abs(shift.dy) <= maximumShift, abs(shift.angle) <= maximumAngle else { return nil }
            return shift
        }
        for index in shifts.indices {
            guard let shift = shifts[index] else { continue }
            if abs(shift.dx) < negligible && abs(shift.dy) < negligible && abs(shift.angle) * Double(max(width, height)) / Double(width) < negligible {
                shifts[index] = .zero
            }
        }
        if followsSky(shifts, times: times) { return TimelapseStabilization(shifts: shifts.map { _ in .zero }, margin: .zero, followedSky: true) }
        return TimelapseStabilization(shifts: shifts, margin: margin(shifts, aspect: Double(width) / Double(height)))
    }

    /// Whether the measured motion runs steadily with time at the sky's pace: a straight-line fit of shift and roll
    /// against capture time that explains most of the motion, at a rate no tripod drifts.
    static func followsSky(_ shifts: [TimelapseShift?], times: [Date?]) -> Bool {
        let samples = shifts.indices.compactMap { index -> (t: Double, shift: TimelapseShift)? in
            guard let shift = shifts[index], times.indices.contains(index), let time = times[index] else { return nil }
            return (time.timeIntervalSinceReferenceDate, shift)
        }
        guard samples.count >= 4, let start = samples.map(\.t).min(), let end = samples.map(\.t).max(), end - start >= 30 else { return false }
        func fit(_ value: (TimelapseShift) -> Double) -> (slope: Double, explained: Double) {
            let n = Double(samples.count), mt = samples.map(\.t).reduce(0, +) / n, mv = samples.map { value($0.shift) }.reduce(0, +) / n
            var stv = 0.0, stt = 0.0, svv = 0.0
            for sample in samples {
                let dt = sample.t - mt, dv = value(sample.shift) - mv
                stv += dt * dv; stt += dt * dt; svv += dv * dv
            }
            guard stt > 0, svv > 0 else { return (0, 0) }
            return (stv / stt, stv * stv / (stt * svv))
        }
        let roll = fit(\.angle), x = fit(\.dx), y = fit(\.dy)
        return (abs(roll.slope) >= skyRoll && roll.explained > 0.8)
            || (abs(x.slope) >= skyShift && x.explained > 0.8) || (abs(y.slope) >= skyShift && y.explained > 0.8)
    }

    /// The margin each side gives up so every frame, moved back, still fills the video's frame.
    static func margin(_ shifts: [TimelapseShift?], aspect: Double) -> CGSize {
        var x = 0.0, y = 0.0
        for case let shift? in shifts {
            // A roll swings the frame's corners by up to half the other side times the angle.
            x = max(x, abs(shift.dx) + abs(shift.angle) * 0.5 / aspect)
            y = max(y, abs(shift.dy) + abs(shift.angle) * 0.5 * aspect)
        }
        return CGSize(width: x == 0 ? 0 : x + 0.001, height: y == 0 ? 0 : y + 0.001)
    }

    // MARK: Measuring

    /// Where the picture stays put through the series: detail present in the frames' mean that doesn't change from frame
    /// to frame. Stars, clouds, water and the aurora change; the land, buildings and the horizon don't. Measured at a
    /// quarter of the working size, from up to 48 frames spread over the series.
    static func steadyWeight(_ planes: [Plane], width: Int, height: Int) -> [Float] {
        let stride = 4, w = max(1, width / stride), h = max(1, height / stride)
        let picked = planes.count <= 48 ? planes : (0..<48).map { planes[$0 * (planes.count - 1) / 47] }
        let small = picked.map { $0.reduced(by: stride) }
        guard small.count >= 2 else { return [Float](repeating: 1, count: width * height) }
        var weight = [Float](repeating: 0, count: w * h)
        var samples = [Float](repeating: 0, count: small.count), deviations = samples
        for i in 0..<(w * h) {
            for k in small.indices { samples[k] = small[k].values[i] }
            let middle = Self.median(&samples)
            for k in small.indices { deviations[k] = abs(small[k].values[i] - middle) }
            let spread = Self.median(&deviations)
            // Detail that holds still: the typical frame's value stands clear of how much it changes.
            let detail = abs(middle), steady = detail * detail / (detail * detail + 4 * spread * spread + 1e-6)
            // Half-steady is a star that lingers or a cloud's edge: only the clearly steady counts.
            weight[i] = steady > 0.6 ? steady : 0
        }
        // The frame's own edge isn't the scene's.
        for y in 0..<h { for x in 0..<w where x < 2 || y < 2 || x >= w - 2 || y >= h - 2 { weight[y * w + x] = 0 } }
        let coarse = Plane(width: w, height: h, values: weight)
        return coarse.enlarged(to: width, height: height).values
    }

    /// The rigid motion taking `reference`'s view to `frame`'s, coarse to fine; nil when they don't agree.
    static func register(_ frame: Pyramid, onto reference: Pyramid) -> Affine? {
        let levels = min(frame.levels.count, reference.levels.count)
        guard levels > 0 else { return nil }
        var motion = Affine.identity
        for level in stride(from: levels - 1, through: 0, by: -1) {
            let a = reference.levels[level], b = frame.levels[level], weight = reference.weights[level]
            if level == levels - 1 {
                // A tripod moves less than 5 %, a few pixels here: try them all before refining.
                let reach = max(2, Int((Double(a.width) * maximumShift * 1.3).rounded(.up)))
                motion = search(a, b, weight: weight, reach: reach)
            } else {
                motion = motion.scaled(by: 2)
            }
            motion = refine(a, b, weight: weight, from: motion, iterations: level == 0 ? 6 : 10)
        }
        let a = reference.levels[0], b = frame.levels[0]
        guard agreement(a, b, weight: reference.weights[0], motion: motion) > 0.5 else { return nil }
        return motion
    }

    /// The whole-pixel shift with the least weighted difference.
    static func search(_ a: Plane, _ b: Plane, weight: [Float], reach: Int) -> Affine {
        var best = (score: Float.infinity, dx: 0, dy: 0)
        for dy in -reach...reach { for dx in -reach...reach {
            var sum: Float = 0, total: Float = 0
            for y in max(0, -dy)..<min(a.height, a.height - dy) {
                let row = y * a.width, other = (y + dy) * b.width + dx
                for x in max(0, -dx)..<min(a.width, a.width - dx) {
                    let w = weight[row + x], d = a.values[row + x] - b.values[other + x]
                    sum += w * d * d; total += w
                }
            }
            guard total > 0 else { continue }
            let score = sum / total
            if score < best.score { best = (score, dx, dy) }
        } }
        return Affine.rigid(angle: 0, shift: SIMD2(Double(best.dx), Double(best.dy)), centre: SIMD2(Double(a.width), Double(a.height)) / 2)
    }

    /// Gauss–Newton on shift and roll: `b` sampled through the motion is brought onto `a`. Robust: a pixel that still
    /// disagrees once the rest line up (a star that has moved on, a passing light) counts less each round.
    static func refine(_ a: Plane, _ b: Plane, weight: [Float], from start: Affine, iterations: Int) -> Affine {
        let centre = SIMD2(Double(a.width), Double(a.height)) / 2
        var angle = start.angle, shift = start.apply(centre) - centre
        var scale = Double.infinity
        var residuals: [Float] = []
        residuals.reserveCapacity(a.width * a.height / 2)
        for _ in 0..<iterations {
            let motion = Affine.rigid(angle: angle, shift: shift, centre: centre)
            var h = simd_double3x3(0), g = SIMD3<Double>.zero
            let c = cos(angle), s = sin(angle)
            residuals.removeAll(keepingCapacity: true)
            for y in 1..<(a.height - 1) { for x in 1..<(a.width - 1) {
                let i = y * a.width + x
                var w = Double(weight[i])
                guard w > 0.05 else { continue }
                let p = motion.apply(SIMD2(Double(x), Double(y)))
                guard let (value, gx, gy) = b.sample(p) else { continue }
                let r = Double(value - a.values[i])
                residuals.append(Float(abs(r)))
                // Cauchy weight at about twice the typical residual.
                if scale.isFinite { let u = r / scale; w /= 1 + u * u }
                // d p / d angle for p = R(angle)(q − centre) + centre + shift.
                let qx = Double(x) - centre.x, qy = Double(y) - centre.y
                let dAngle = Double(gx) * (-s * qx - c * qy) + Double(gy) * (c * qx - s * qy)
                let j = SIMD3(Double(gx), Double(gy), dAngle)
                h += w * simd_double3x3(columns: (j * j.x, j * j.y, j * j.z))
                g += w * r * j
            } }
            guard abs(h.determinant) > 1e-12, !residuals.isEmpty else { break }
            let step = h.inverse * g
            shift.x -= step.x; shift.y -= step.y; angle -= step.z
            scale = max(1e-4, 2 * 1.4826 * Double(median(&residuals)))
            if abs(step.x) < 0.002 && abs(step.y) < 0.002 && abs(step.z) < 1e-6 { break }
        }
        return Affine.rigid(angle: angle, shift: shift, centre: centre)
    }

    /// Weighted correlation of `a` and `b` brought onto it: near 1 when the steady parts line up.
    static func agreement(_ a: Plane, _ b: Plane, weight: [Float], motion: Affine) -> Double {
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for y in 0..<a.height { for x in 0..<a.width {
            let i = y * a.width + x, w = Double(weight[i])
            guard w > 0.05, let (value, _, _) = b.sample(motion.apply(SIMD2(Double(x), Double(y)))) else { continue }
            let va = Double(a.values[i]), vb = Double(value)
            sab += w * va * vb; saa += w * va * va; sbb += w * vb * vb
        } }
        guard saa > 0, sbb > 0 else { return 0 }
        return sab / (saa * sbb).squareRoot()
    }

    static func median(_ values: inout [Float]) -> Float {
        let middle = values.count / 2
        // Selection, not a sort: called once per pixel.
        var low = 0, high = values.count - 1
        while low < high {
            let pivot = values[(low + high) / 2]
            var i = low, j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j { values.swapAt(i, j); i += 1; j -= 1 }
            }
            if middle <= j { high = j } else if middle >= i { low = i } else { break }
        }
        return values[middle]
    }

    // MARK: Images

    /// Log luminance with its slow changes taken out, so exposure ramps and the light of dusk don't count as motion.
    struct Plane {
        let width: Int
        let height: Int
        var values: [Float]
        init(width: Int, height: Int, values: [Float]) { self.width = width; self.height = height; self.values = values }

        init?(_ image: CGImage, longEdge: Int) {
            let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
            let width = max(8, Int((Double(image.width) * scale).rounded())), height = max(8, Int((Double(image.height) * scale).rounded()))
            var pixels = [Float](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 32, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            // A quantum of an 8-bit preview's darkest step keeps the night's shadows from turning to noise.
            self.init(width: width, height: height, values: Self.highPassed(pixels.map { log2(max(0, $0) + 1.0 / 128) }, width: width, height: height))
        }

        /// The values less their local mean over a sixtieth of the long edge.
        private static func highPassed(_ values: [Float], width: Int, height: Int) -> [Float] {
            let radius = max(2, max(width, height) / 60)
            let blurred = Plane(width: width, height: height, values: values).boxBlurred(radius).boxBlurred(radius)
            return zip(values, blurred.values).map { $0 - $1 }
        }

        func boxBlurred(_ radius: Int) -> Plane {
            var horizontal = [Float](repeating: 0, count: values.count), out = horizontal
            for y in 0..<height {
                let row = y * width
                var sum: Float = 0, count: Float = 0
                for x in 0..<min(width, radius + 1) { sum += values[row + x]; count += 1 }
                for x in 0..<width {
                    horizontal[row + x] = sum / count
                    let add = x + radius + 1, drop = x - radius
                    if add < width { sum += values[row + add]; count += 1 }
                    if drop >= 0 { sum -= values[row + drop]; count -= 1 }
                }
            }
            for x in 0..<width {
                var sum: Float = 0, count: Float = 0
                for y in 0..<min(height, radius + 1) { sum += horizontal[y * width + x]; count += 1 }
                for y in 0..<height {
                    out[y * width + x] = sum / count
                    let add = y + radius + 1, drop = y - radius
                    if add < height { sum += horizontal[add * width + x]; count += 1 }
                    if drop >= 0 { sum -= horizontal[drop * width + x]; count -= 1 }
                }
            }
            return Plane(width: width, height: height, values: out)
        }

        /// Box-averaged down by `factor`.
        func reduced(by factor: Int) -> Plane {
            let w = max(1, width / factor), h = max(1, height / factor)
            var out = [Float](repeating: 0, count: w * h)
            let area = Float(factor * factor)
            for y in 0..<h { for x in 0..<w {
                var sum: Float = 0
                for v in 0..<factor { let row = (y * factor + v) * width + x * factor; for u in 0..<factor { sum += values[row + u] } }
                out[y * w + x] = sum / area
            } }
            return Plane(width: w, height: h, values: out)
        }

        /// Bilinearly enlarged to `width` × `height`.
        func enlarged(to newWidth: Int, height newHeight: Int) -> Plane {
            var out = [Float](repeating: 0, count: newWidth * newHeight)
            let sx = Double(width) / Double(newWidth), sy = Double(height) / Double(newHeight)
            for y in 0..<newHeight { for x in 0..<newWidth {
                let p = SIMD2((Double(x) + 0.5) * sx - 0.5, (Double(y) + 0.5) * sy - 0.5)
                out[y * newWidth + x] = clampedSample(p)
            } }
            return Plane(width: newWidth, height: newHeight, values: out)
        }

        private func clampedSample(_ p: SIMD2<Double>) -> Float {
            let x = min(max(0, p.x), Double(width - 1)), y = min(max(0, p.y), Double(height - 1))
            let x0 = min(width - 2, Int(x)), y0 = min(height - 2, Int(y))
            guard width > 1, height > 1 else { return values[0] }
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0)), i = y0 * width + x0
            let top = values[i] + (values[i + 1] - values[i]) * fx, bottom = values[i + width] + (values[i + width + 1] - values[i + width]) * fx
            return top + (bottom - top) * fy
        }

        /// The value at `p` and its gradient, bilinearly; nil outside.
        @inline(__always) func sample(_ p: SIMD2<Double>) -> (Float, Float, Float)? {
            guard p.x >= 0, p.y >= 0, p.x < Double(width - 1), p.y < Double(height - 1) else { return nil }
            let x0 = Int(p.x), y0 = Int(p.y), fx = Float(p.x - Double(x0)), fy = Float(p.y - Double(y0)), i = y0 * width + x0
            let a = values[i], b = values[i + 1], c = values[i + width], d = values[i + width + 1]
            let top = a + (b - a) * fx, bottom = c + (d - c) * fx
            return (top + (bottom - top) * fy, (b - a) * (1 - fy) + (d - c) * fy, bottom - top)
        }

        /// Halved, for the next level of a pyramid.
        var halved: Plane { reduced(by: 2) }
    }

    /// A plane and its halvings down to about 60 pixels, with the steady weight at each size.
    struct Pyramid {
        var levels: [Plane]
        var weights: [[Float]]
        init(_ plane: Plane, weight: [Float]) {
            levels = [plane]; weights = [weight]
            var weightPlane = Plane(width: plane.width, height: plane.height, values: weight)
            while let last = levels.last, min(last.width, last.height) >= 120 {
                levels.append(last.halved)
                weightPlane = weightPlane.halved
                weights.append(weightPlane.values)
            }
        }
    }

    /// A 2-D affine map in pixels: p ↦ linear · p + offset.
    struct Affine: Equatable {
        var linear: simd_double2x2
        var offset: SIMD2<Double>
        static let identity = Affine(linear: matrix_identity_double2x2, offset: .zero)
        static func rigid(angle: Double, shift: SIMD2<Double>, centre: SIMD2<Double>) -> Affine {
            let c = cos(angle), s = sin(angle)
            let linear = simd_double2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
            return Affine(linear: linear, offset: centre + shift - linear * centre)
        }
        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { linear * p + offset }
        var angle: Double { atan2(linear[0][1], linear[0][0]) }
        var inverse: Affine { let inverse = linear.inverse; return Affine(linear: inverse, offset: -(inverse * offset)) }
        /// This after `other`: p ↦ self(other(p)).
        func then(_ other: Affine) -> Affine { Affine(linear: linear * other.linear, offset: linear * other.offset + offset) }
        /// The same motion on an image `factor` times larger.
        func scaled(by factor: Double) -> Affine { Affine(linear: linear, offset: offset * factor) }
    }
}
