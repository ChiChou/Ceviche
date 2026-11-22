import Accelerate
import Foundation
import simd

/// Straight edges in a grey image by the a-contrario method of R. Grompone von Gioi, J. Jakubowicz, J.-M. Morel and
/// G. Randall, "LSD: a Line Segment Detector", Image Processing On Line 2 (2012), doi:10.5201/ipol.2012.gjmr-lsd.
/// Written from the article's description of the method. Each pixel's level-line direction is kept as a unit vector,
/// so "aligned within τ" is a dot product against cos τ; filtering, gradients and the counts behind each false-alarm
/// test run on SIMD lanes, and the rectangle improvements, which only read the gradient field, run in parallel.
enum LineSegmentDetector {
    struct Line {
        /// Ends in the input's pixel coordinates (pixel centres at integers, y down).
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var width: Double
        /// −log10 of the number of false alarms; above `logEpsilon` for every line returned.
        var significance: Double
    }

    struct Parameters {
        /// The image is reduced to this scale with a Gaussian of `sigmaScale / scale` input pixels first.
        var scale = 0.8
        var sigmaScale = 0.6
        /// Bound on the gradient error from 8-bit quantization; weaker gradients have no reliable direction.
        var quantization = 2.0
        /// τ: how far a pixel's level line may turn from its region's and still join it.
        var angleTolerance = 22.5 * Double.pi / 180
        /// ε: lines must have fewer than 10^−ε false alarms.
        var logEpsilon = 0.0
        /// Share of a rectangle the region must fill, below which the region is refined.
        var density = 0.7
        var bins = 1024
    }

    /// `pixels` are row-major luminance values on a 0–255 scale.
    static func detect(_ pixels: [Float], width: Int, height: Int, parameters: Parameters = Parameters()) -> [Line] {
        precondition(pixels.count == width * height && width > 0 && height > 0)
        let (image, w, h) = parameters.scale < 1 ? gaussianScale(pixels, width: width, height: height, scale: parameters.scale, sigmaScale: parameters.sigmaScale)
                                                 : (pixels, width, height)
        guard w >= 2, h >= 2 else { return [] }
        let field = GradientField(image, width: w, height: h, threshold: Float(parameters.quantization / sin(parameters.angleTolerance)))
        let p = parameters.angleTolerance / .pi
        // Tests: every rectangle (N M)^(5/2) of an N×M image, at 11 precisions.
        let logTests = 2.5 * (log10(Double(w)) + log10(Double(h))) + log10(11)
        // The fewest pixels that could be significant even if all were aligned.
        let minimumRegion = Int(-logTests / log10(p))

        var grower = RegionGrower(field: field)
        var candidates: [Rectangle] = []
        for seed in field.ordered(bins: parameters.bins) where grower.status[seed] == RegionGrower.free {
            let cosTolerance = Float(cos(parameters.angleTolerance))
            grower.grow(from: seed, cosTolerance: cosTolerance)
            guard grower.region.count >= minimumRegion,
                  var rectangle = grower.rectangle(precision: p),
                  grower.refine(&rectangle, seed: seed, density: parameters.density, precision: p) else { continue }
            candidates.append(rectangle)
        }

        // Improving a rectangle reads the gradient field only, so each is done on its own.
        var lines = [Line?](repeating: nil, count: candidates.count)
        lines.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                let (significance, rectangle) = field.improve(candidates[i], logTests: logTests, logEpsilon: parameters.logEpsilon)
                guard significance > parameters.logEpsilon else { return }
                // The gradient of pixel (x, y) is measured at (x + ½, y + ½); scaled pixel x sits at input x / scale.
                let scale = min(parameters.scale, 1)
                func input(_ point: SIMD2<Double>) -> SIMD2<Double> { (point + 0.5) / scale }
                out[i] = Line(a: input(rectangle.a), b: input(rectangle.b), width: rectangle.width / scale, significance: significance)
            }
        }
        return lines.compactMap { $0 }
    }

    // MARK: Scaling

    /// Gaussian filtering and resampling to `scale`, one axis at a time: each pass weights whole rows with vDSP, and a
    /// transpose turns the second axis into rows.
    static func gaussianScale(_ pixels: [Float], width: Int, height: Int, scale: Double, sigmaScale: Double) -> ([Float], Int, Int) {
        let w = Int(floor(Double(width) * scale)), h = Int(floor(Double(height) * scale))
        guard w > 0, h > 0 else { return ([], 0, 0) }
        let sigma = sigmaScale / scale
        let rows = resampleRows(pixels, rows: height, columns: width, to: h, scale: scale, sigma: sigma)   // h × width
        var transposed = [Float](repeating: 0, count: rows.count)
        vDSP_mtrans(rows, 1, &transposed, 1, vDSP_Length(width), vDSP_Length(h))                        // width × h
        let columns = resampleRows(transposed, rows: width, columns: h, to: w, scale: scale, sigma: sigma)  // w × h
        var result = [Float](repeating: 0, count: w * h)
        vDSP_mtrans(columns, 1, &result, 1, vDSP_Length(h), vDSP_Length(w))                               // h × w
        return (result, w, h)
    }

    /// Output row i is the Gaussian-weighted sum of the input rows around i / scale, mirrored at the edges.
    private static func resampleRows(_ input: [Float], rows: Int, columns: Int, to count: Int, scale: Double, sigma: Double) -> [Float] {
        let radius = Int(ceil(3 * sigma))
        var output = [Float](repeating: 0, count: count * columns)
        var weights = [Float](repeating: 0, count: 2 * radius + 2)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for i in 0..<count {
                    let centre = Double(i) / scale, first = Int(floor(centre)) - radius
                    var total: Float = 0
                    for k in 0..<weights.count {
                        let d = Double(first + k) - centre
                        weights[k] = Float(exp(-d * d / (2 * sigma * sigma))); total += weights[k]
                    }
                    let row = destination.baseAddress! + i * columns
                    for k in 0..<weights.count {
                        var weight = weights[k] / total
                        var j = first + k
                        if j < 0 { j = -j - 1 }
                        if j >= rows { j = 2 * rows - j - 1 }
                        j = min(max(j, 0), rows - 1)
                        vDSP_vsma(source.baseAddress! + j * columns, 1, &weight, row, 1, row, 1, vDSP_Length(columns))
                    }
                }
            }
        }
        return output
    }

    // MARK: Gradient

    /// Level-line directions and gradient magnitudes. Pixels with too weak a gradient, and the last row and column,
    /// have a zero direction, which no dot-product test accepts.
    struct GradientField: @unchecked Sendable {
        let width: Int, height: Int
        var ux: [Float], uy: [Float], magnitude: [Float]
        var defined: [Bool]

        init(_ image: [Float], width w: Int, height h: Int, threshold: Float) {
            width = w; height = h
            ux = [Float](repeating: 0, count: w * h); uy = ux; magnitude = ux
            defined = [Bool](repeating: false, count: w * h)
            image.withUnsafeBufferPointer { img in
                ux.withUnsafeMutableBufferPointer { ux in
                uy.withUnsafeMutableBufferPointer { uy in
                magnitude.withUnsafeMutableBufferPointer { mag in
                    let i = UnsafeRawPointer(img.baseAddress!)
                    let threshold8 = SIMD8<Float>(repeating: threshold)
                    for y in 0..<(h - 1) {
                        var x = 0
                        let row = y * w
                        // 2×2 differences: gx across, gy down, each averaged over the pair of rows or columns.
                        while x + 8 < w {
                            let o = (row + x) * 4
                            let a = i.loadUnaligned(fromByteOffset: o, as: SIMD8<Float>.self)
                            let b = i.loadUnaligned(fromByteOffset: o + 4, as: SIMD8<Float>.self)
                            let c = i.loadUnaligned(fromByteOffset: o + w * 4, as: SIMD8<Float>.self)
                            let d = i.loadUnaligned(fromByteOffset: o + w * 4 + 4, as: SIMD8<Float>.self)
                            let gx = (b + d - a - c) * 0.5, gy = (c + d - a - b) * 0.5
                            let m = (gx * gx + gy * gy).squareRoot()
                            let keep = m .> threshold8
                            let inverse = SIMD8<Float>(repeating: 0).replacing(with: 1 / m, where: keep)
                            // The level line runs along the edge: angle atan2(gx, −gy).
                            UnsafeMutableRawPointer(ux.baseAddress! + row + x).storeBytes(of: -gy * inverse, as: SIMD8<Float>.self)
                            UnsafeMutableRawPointer(uy.baseAddress! + row + x).storeBytes(of: gx * inverse, as: SIMD8<Float>.self)
                            UnsafeMutableRawPointer(mag.baseAddress! + row + x).storeBytes(of: m, as: SIMD8<Float>.self)
                            x += 8
                        }
                        while x < w - 1 {
                            let a = img[row + x], b = img[row + x + 1], c = img[row + w + x], d = img[row + w + x + 1]
                            let gx = (b + d - a - c) * 0.5, gy = (c + d - a - b) * 0.5
                            let m = (gx * gx + gy * gy).squareRoot()
                            mag[row + x] = m
                            if m > threshold { ux[row + x] = -gy / m; uy[row + x] = gx / m }
                            x += 1
                        }
                    }
                }}}
            }
            for y in 0..<(h - 1) { for x in 0..<(w - 1) where ux[y * w + x] != 0 || uy[y * w + x] != 0 { defined[y * w + x] = true } }
        }

        /// Defined pixels from the strongest gradient down, sorted into `bins` levels as the article does.
        func ordered(bins: Int) -> [Int] {
            var strongest: Float = 0
            for i in magnitude.indices where defined[i] { strongest = max(strongest, magnitude[i]) }
            guard strongest > 0 else { return [] }
            var counts = [Int](repeating: 0, count: bins)
            func bin(_ i: Int) -> Int { bins - 1 - min(bins - 1, Int(magnitude[i] / strongest * Float(bins))) }
            for i in magnitude.indices where defined[i] { counts[bin(i)] += 1 }
            var start = [Int](repeating: 0, count: bins)
            for b in 1..<bins { start[b] = start[b - 1] + counts[b - 1] }
            var order = [Int](repeating: 0, count: start[bins - 1] + counts[bins - 1])
            for i in magnitude.indices where defined[i] { let b = bin(i); order[start[b]] = i; start[b] += 1 }
            return order
        }

        // MARK: False alarms

        /// Pixels whose centres lie in the rectangle, and how many of them have a level line within the rectangle's
        /// precision of its direction. Rows are walked across their span, eight pixels at a time.
        func counts(_ r: Rectangle) -> (n: Int, k: Int) {
            let half = r.width / 2
            let spread = abs(r.normal.y) * half
            let top = max(0, Int(ceil(min(r.a.y, r.b.y) - spread - 1e-9))), bottom = min(height - 1, Int(floor(max(r.a.y, r.b.y) + spread + 1e-9)))
            guard top <= bottom else { return (0, 0) }
            var n = 0, k = 0
            let dx = Float(r.direction.x), dy = Float(r.direction.y), threshold = Float(r.cosPrecision)
            let dx8 = SIMD8<Float>(repeating: dx), dy8 = SIMD8<Float>(repeating: dy), threshold8 = SIMD8<Float>(repeating: threshold)
            ux.withUnsafeBufferPointer { ux in
            uy.withUnsafeBufferPointer { uy in
                let px = UnsafeRawPointer(ux.baseAddress!), py = UnsafeRawPointer(uy.baseAddress!)
                for y in top...bottom {
                    // Along: 0 ≤ (p − a)·d ≤ length; across: |(p − a)·n| ≤ width / 2; both linear in x on this row.
                    var low = -Double.infinity, high = Double.infinity
                    func clip(_ slope: Double, _ offset: Double, _ lower: Double, _ upper: Double) {
                        if abs(slope) < 1e-12 { if offset < lower - 1e-9 || offset > upper + 1e-9 { low = 1; high = 0 }; return }
                        let u = (lower - offset) / slope, v = (upper - offset) / slope
                        low = max(low, min(u, v)); high = min(high, max(u, v))
                    }
                    let ry = Double(y) - r.a.y
                    clip(r.direction.x, r.direction.y * ry - r.direction.x * r.a.x, 0, r.length)
                    clip(r.normal.x, r.normal.y * ry - r.normal.x * r.a.x, -half, half)
                    let first = max(0, Int(ceil(low - 1e-9))), last = min(width - 1, Int(floor(high + 1e-9)))
                    guard first <= last else { continue }
                    n += last - first + 1
                    var x = first
                    var aligned = SIMD8<Int32>(repeating: 0)
                    while x + 8 <= last + 1 {
                        let o = (y * width + x) * 4
                        let dot = px.loadUnaligned(fromByteOffset: o, as: SIMD8<Float>.self) * dx8 + py.loadUnaligned(fromByteOffset: o, as: SIMD8<Float>.self) * dy8
                        aligned &+= SIMD8<Int32>(repeating: 0).replacing(with: 1, where: dot .>= threshold8)
                        x += 8
                    }
                    for lane in 0..<8 { k += Int(aligned[lane]) }
                    while x <= last { let i = y * width + x; if ux[i] * dx + uy[i] * dy >= threshold { k += 1 }; x += 1 }
                }
            }}
            return (n, k)
        }

        /// −log10 NFA: the tests times the chance that k or more of n pixels align at probability p by accident.
        func significance(_ r: Rectangle, logTests: Double) -> Double {
            let (n, k) = counts(r)
            return -logTests - Self.log10BinomialTail(n: n, k: k, p: r.precision)
        }

        /// log10 of P[X ≥ k] for X ~ B(n, p), which is the regularized incomplete beta function I_p(k, n − k + 1).
        static func log10BinomialTail(n: Int, k: Int, p: Double) -> Double {
            guard n > 0, k > 0 else { return 0 }
            guard k <= n else { return -Double.infinity }
            let a = Double(k), b = Double(n - k + 1)
            // The continued fraction converges quickly below the distribution's middle; above it, the complement does.
            if p < (a + 1) / (a + b + 2) { return min(0, logIncompleteBeta(p, a, b) / M_LN10) }
            return log1p(-exp(logIncompleteBeta(1 - p, b, a))) / M_LN10
        }

        /// ln I_x(a, b) from its continued fraction (Abramowitz and Stegun 26.5.8), evaluated by Lentz's method;
        /// for x < (a + 1) / (a + b + 2), where a few dozen terms reach double precision whatever a and b are.
        static func logIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
            let front = a * log(x) + b * log1p(-x) - log(a) - (lgamma(a) + lgamma(b) - lgamma(a + b))
            let tiny = 1e-300
            func guarded(_ v: Double) -> Double { abs(v) < tiny ? tiny : v }
            var c = 1.0, d = 1 / guarded(1 - (a + b) * x / (a + 1)), fraction = d
            for m in 1...300 {
                let m = Double(m)
                // Even step, then odd step, of the fraction's coefficients.
                let even = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
                d = 1 / guarded(1 + even * d); c = guarded(1 + even / c); fraction *= d * c
                let odd = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
                d = 1 / guarded(1 + odd * d); c = guarded(1 + odd / c)
                let step = d * c
                fraction *= step
                if abs(step - 1) < 1e-13 { break }
            }
            return front + log(fraction)
        }

        /// The article's improvements, each kept only when it makes the rectangle more significant: finer precision,
        /// a narrower rectangle, either side trimmed, then finer precision again.
        func improve(_ rectangle: Rectangle, logTests: Double, logEpsilon: Double) -> (Double, Rectangle) {
            var best = rectangle, bestValue = significance(rectangle, logTests: logTests)
            func attempt(_ change: (inout Rectangle) -> Bool) {
                guard bestValue <= logEpsilon else { return }
                var r = best
                for _ in 0..<5 {
                    guard change(&r) else { break }
                    let value = significance(r, logTests: logTests)
                    if value > bestValue { bestValue = value; best = r }
                }
            }
            let finer: (inout Rectangle) -> Bool = { $0.setPrecision($0.precision / 2); return true }
            attempt(finer)
            attempt { r in guard r.width - 0.5 >= 1 else { return false }; r.width -= 0.5; return true }
            attempt { r in guard r.width - 0.5 >= 1 else { return false }; r.width -= 0.5; r.shift(0.25); return true }
            attempt { r in guard r.width - 0.5 >= 1 else { return false }; r.width -= 0.5; r.shift(-0.25); return true }
            attempt(finer)
            return (bestValue, best)
        }
    }

    // MARK: Regions

    /// A segment of given width around the line from `a` to `b`, tested at a precision (the chance a random level
    /// line counts as aligned with it).
    struct Rectangle {
        var a: SIMD2<Double>, b: SIMD2<Double>
        var width: Double
        private(set) var precision: Double
        private(set) var cosPrecision: Double
        var direction: SIMD2<Double> { simd_normalize(b - a) }
        var normal: SIMD2<Double> { let d = direction; return SIMD2(-d.y, d.x) }
        var length: Double { simd_distance(a, b) }
        init(a: SIMD2<Double>, b: SIMD2<Double>, width: Double, precision: Double) {
            self.a = a; self.b = b; self.width = width; self.precision = precision; cosPrecision = cos(precision * .pi)
        }
        mutating func setPrecision(_ p: Double) { precision = p; cosPrecision = cos(p * .pi) }
        /// Moves the rectangle across its own direction.
        mutating func shift(_ distance: Double) { let n = normal * distance; a += n; b += n }
    }

    /// Grows regions of aligned pixels from seeds, marking the pixels it takes.
    struct RegionGrower {
        static let free: UInt8 = 0, used: UInt8 = 1, undefined: UInt8 = 2
        let field: GradientField
        var status: [UInt8]
        private(set) var region: [Int] = []
        /// The region's level-line direction: the normalized sum of its pixels'.
        private(set) var direction = SIMD2<Float>(1, 0)

        init(field: GradientField) {
            self.field = field
            status = field.defined.map { $0 ? Self.free : Self.undefined }
        }

        /// Adds 8-connected free pixels aligned with the region as it grows, the region turning with each.
        mutating func grow(from seed: Int, cosTolerance: Float) {
            var region = self.region
            region.removeAll(keepingCapacity: true)
            let w = field.width, h = field.height
            var sum = SIMD2<Float>(field.ux[seed], field.uy[seed])
            var direction = simd_normalize(sum)
            region.append(seed); status[seed] = Self.used
            let neighbours = [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1]
            field.ux.withUnsafeBufferPointer { ux in
            field.uy.withUnsafeBufferPointer { uy in
            status.withUnsafeMutableBufferPointer { status in
                func consider(_ q: Int) {
                    guard status[q] == Self.free, ux[q] * direction.x + uy[q] * direction.y >= cosTolerance else { return }
                    status[q] = Self.used; region.append(q)
                    sum += SIMD2(ux[q], uy[q]); direction = sum * (1 / simd_length(sum))
                }
                var i = 0
                while i < region.count {
                    let p = region[i]
                    let x = p % w
                    // Away from the border every neighbour exists; the last row and column are never free, but the
                    // first ones still need their bounds checked.
                    if x > 0, x < w - 1, p >= w, p < (h - 1) * w {
                        for offset in neighbours { consider(p + offset) }
                    } else {
                        let y = p / w
                        for ny in max(0, y - 1)...min(h - 1, y + 1) { for nx in max(0, x - 1)...min(w - 1, x + 1) where ny != y || nx != x { consider(ny * w + nx) } }
                    }
                    i += 1
                }
            }}}
            self.region = region; self.direction = direction
        }

        private mutating func release() { for p in region { status[p] = Self.free }; region.removeAll(keepingCapacity: true) }

        /// The smallest rectangle along the region's principal axis, weighted by gradient magnitude, that holds its
        /// pixel centres; nil for a region with no extent.
        func rectangle(precision: Double) -> Rectangle? {
            let w = field.width
            var total = 0.0, cx = 0.0, cy = 0.0
            for p in region { let m = Double(field.magnitude[p]); total += m; cx += m * Double(p % w); cy += m * Double(p / w) }
            guard total > 0 else { return nil }
            cx /= total; cy /= total
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in region {
                let m = Double(field.magnitude[p]), dx = Double(p % w) - cx, dy = Double(p / w) - cy
                sxx += m * dx * dx; syy += m * dy * dy; sxy += m * dx * dy
            }
            // The principal axis of the weighted spread, turned to agree with the region's level-line direction.
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            var d = SIMD2(cos(theta), sin(theta))
            if d.x * Double(direction.x) + d.y * Double(direction.y) < 0 { d = -d }
            let n = SIMD2(-d.y, d.x), c = SIMD2(cx, cy)
            var along = (Double.infinity, -Double.infinity), across = (Double.infinity, -Double.infinity)
            for p in region {
                let v = SIMD2(Double(p % w), Double(p / w)) - c
                let l = simd_dot(v, d), t = simd_dot(v, n)
                along = (min(along.0, l), max(along.1, l)); across = (min(across.0, t), max(across.1, t))
            }
            guard along.1 > along.0 else { return nil }
            let middle = c + n * (across.0 + across.1) / 2
            return Rectangle(a: middle + d * along.0, b: middle + d * along.1, width: max(1, across.1 - across.0), precision: precision)
        }

        /// The article's refinement of a region that fills too little of its rectangle: grown again from the seed at a
        /// tolerance taken from the directions near the seed, then cut back around the seed until dense enough.
        /// False when nothing usable is left.
        mutating func refine(_ rect: inout Rectangle, seed: Int, density: Double, precision: Double) -> Bool {
            func dense(_ r: Rectangle) -> Bool { Double(region.count) / (r.length * r.width) >= density }
            if dense(rect) { return true }
            let w = field.width
            let seedPoint = SIMD2(Double(seed % w), Double(seed / w))
            let seedDirection = SIMD2(Double(field.ux[seed]), Double(field.uy[seed]))
            // The spread of level-line angles within one rectangle width of the seed.
            var sum = 0.0, squares = 0.0, count = 0.0
            for p in region where simd_distance(SIMD2(Double(p % w), Double(p / w)), seedPoint) <= rect.width {
                let u = SIMD2(Double(field.ux[p]), Double(field.uy[p]))
                let angle = atan2(seedDirection.x * u.y - seedDirection.y * u.x, simd_dot(seedDirection, u))
                sum += angle; squares += angle * angle; count += 1
            }
            let mean = sum / max(count, 1)
            let tolerance = 2 * max(0, squares / max(count, 1) - mean * mean).squareRoot()
            release()
            grow(from: seed, cosTolerance: Float(cos(tolerance)))
            guard region.count >= 2, let regrown = rectangle(precision: precision) else { return false }
            rect = regrown
            if dense(rect) { return true }

            // Cut the region back to ever smaller distances from the seed.
            var radius = region.map { simd_distance(SIMD2(Double($0 % w), Double($0 / w)), seedPoint) }.max() ?? 0
            while true {
                radius *= 0.75
                var kept: [Int] = []
                for p in region {
                    if simd_distance(SIMD2(Double(p % w), Double(p / w)), seedPoint) <= radius { kept.append(p) } else { status[p] = Self.free }
                }
                region = kept
                guard region.count >= 2 else { return false }
                var total = SIMD2<Float>.zero
                for p in region { total += SIMD2(field.ux[p], field.uy[p]) }
                if simd_length(total) > 0 { direction = simd_normalize(total) }
                guard let cut = rectangle(precision: precision) else { return false }
                rect = cut
                if dense(rect) { return true }
            }
        }
    }
}
