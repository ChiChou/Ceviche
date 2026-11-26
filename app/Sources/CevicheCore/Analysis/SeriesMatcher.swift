import Foundation
import CoreImage
import ImageIO
import Vision
import simd

/// The three develop values a match sets, in the app's own units: they go to Apple's decoder as they are.
public struct SeriesMatchValues: Equatable, Sendable {
    public var exposure: Double
    public var temperature: Double
    public var tint: Double
    public init(exposure: Double, temperature: Double, tint: Double) { self.exposure = exposure; self.temperature = temperature; self.tint = tint }
    var mired: Double { 1e6 / temperature }
    /// Inside the sliders' ranges.
    var clamped: SeriesMatchValues {
        SeriesMatchValues(exposure: min(5, max(-5, exposure)), temperature: min(50000, max(2000, temperature)), tint: min(150, max(-150, tint)))
    }
    var rounded: SeriesMatchValues {
        SeriesMatchValues(exposure: (exposure * 100).rounded() / 100, temperature: temperature.rounded(), tint: tint.rounded())
    }
}

/// What a photo was matched on.
public enum SeriesMatchMethod: String, Sendable {
    /// The part of the scene it shares with the reference.
    case overlap
    /// The reference's white balance, and the exposure difference the cameras recorded.
    case exif
    /// The skin of the largest face in each.
    case skin
    /// Nothing to go on: the photo shares no scene with the reference and was taken in other light. It is left alone.
    case unmatched
    public var title: String {
        switch self {
        case .unmatched: L10n.tr("No Match")
        case .overlap: L10n.tr("Overlap")
        case .exif: L10n.tr("EXIF")
        case .skin: L10n.tr("Skin")
        }
    }
}

/// What to match a photo on: the best it has, or one way asked for.
public enum SeriesMatchPreference: String, Sendable, CaseIterable, Identifiable {
    case automatic, exif, skin
    public var id: String { rawValue }
}

public struct SeriesMatchResult: Sendable {
    public let method: SeriesMatchMethod
    public let values: SeriesMatchValues
    /// The share of the textured blocks under the reference that show the same thing in both, when the photos register.
    public let agreement: Double?
    public let hasFace: Bool
}

/// Matches photos to a reference in exposure and white balance. Each photo is matched on what can be trusted most:
/// the scene it shares with the reference when the two register; otherwise the reference's white balance with the
/// exposure difference the camera recorded, which holds only while the light holds; or, when asked, the skin of a face
/// in both. Whole-picture statistics follow the framing instead of the light and are not used. The values are solved by
/// Newton through Apple's decoder, so they are exactly what Develop will render.
public final class SeriesMatcher: @unchecked Sendable {
    public static let workSize = 1024
    static let block = 16
    private let reference: Photo
    private let values: SeriesMatchValues
    private let context: CIContext
    private let linear: Raster
    private let blocks: [SIMD3<Double>?]
    private let median: Double
    private let features: [PanoramaFeature]
    private let skin: SIMD3<Double>?

    public init(reference url: URL, values: SeriesMatchValues) throws {
        context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .cacheIntermediates: false])
        reference = try Photo(url)
        self.values = values
        let image = reference.image(values)
        linear = Self.render(image, context)
        let grid = Grid(width: linear.width, height: linear.height)
        blocks = Self.blockMeans(linear, grid, clip: Self.clipLevel(linear))
        median = Self.median(blocks.compactMap { $0 }.map(Self.luminance))
        features = PanoramaFeatures.detect(Self.plane(linear), limit: 2000)
        let raster = linear
        skin = Self.skin(reference, values, raster, context).map { $0.mean(raster) }
    }
    /// Whether the reference shows a face to match skin against.
    public var referenceHasFace: Bool { skin != nil }

    /// The values that make the photo at `url` look like the reference. `current` is its white balance now, where the
    /// solve starts.
    public func match(_ url: URL, current: SeriesMatchValues, prefer: SeriesMatchPreference = .automatic) throws -> SeriesMatchResult {
        let target = try Photo(url)
        let asShot = target.image(current)
        let own = Self.render(asShot, context)
        let face = skin == nil ? nil : Self.skin(target, current, own, context)
        func solve(_ residual: (SeriesMatchValues) -> SIMD3<Double>) -> SeriesMatchValues {
            // From the photo's own white balance, with the exposure its own measure asks for: the recorded exposure is
            // stops off under another light.
            let first = residual(current)
            let start = SeriesMatchValues(exposure: current.exposure + (first.x.isFinite ? -first.x / log(2) : 0), temperature: current.temperature, tint: current.tint).clamped
            return Self.newton(start: start, residual)
        }
        if prefer == .skin, let face, let skin {
            let solved = solve { Self.difference(face.mean(Self.render(target.image($0), self.context)), skin) }
            return SeriesMatchResult(method: .skin, values: solved, agreement: nil, hasFace: true)
        }
        var agreement: Double?
        if prefer != .exif, let registration = register(target, asShot) {
            let size = CGSize(width: linear.width, height: linear.height)
            let grid = Grid(width: linear.width, height: linear.height)
            let warped = Self.render(Self.warp(asShot, registration, into: size), context)
            let means = Self.blockMeans(warped, grid, clip: Self.clipLevel(own))
            let targetMedian = Self.median(means.compactMap { $0 }.map(Self.luminance))
            var shared: [Int] = [], flat: [Int] = [], agree = 0, differ = 0
            for i in 0..<grid.count {
                guard let r = blocks[i], let t = means[i], Self.luminance(r) > median / 64, Self.luminance(t) > targetMedian / 64 else { continue }
                switch Self.compare(linear, warped, grid, i) {
                case .agree: shared.append(i); agree += 1
                case .flat: flat.append(i)
                case .differ: differ += 1
                }
            }
            let share = agree + differ > 0 ? Double(agree) / Double(agree + differ) : 0
            agreement = share
            // Flat on flat proves nothing; flat blocks count only where most textured ones agree.
            if share >= 0.5 { shared += flat }
            // Too little shared content (another scene, or one object in common): no overlap match.
            if shared.count >= 12, agree >= 12, share >= 0.25 {
                let solved = solve { values in
                    let image = Self.render(Self.warp(target.image(values), registration, into: size), self.context)
                    let now = Self.blockMeans(image, grid, clip: nil)
                    return Self.robustCentre(shared.compactMap { i in now[i].flatMap { t in self.blocks[i].map { Self.difference(t, $0) } } })
                }
                return SeriesMatchResult(method: .overlap, values: solved, agreement: share, hasFace: face != nil)
            }
        }
        var copied = SeriesMatchValues(exposure: values.exposure, temperature: values.temperature, tint: values.tint)
        if let a = reference.exposureIndex, let b = target.exposureIndex {
            // Stops apart in recorded exposure is other light altogether, where the reference's white balance is wrong too.
            guard abs(a - b) <= 3 else { return SeriesMatchResult(method: .unmatched, values: current, agreement: agreement, hasFace: face != nil) }
            copied.exposure += a - b
        } else { copied.exposure = current.exposure }
        return SeriesMatchResult(method: .exif, values: copied.clamped.rounded, agreement: agreement, hasFace: face != nil)
    }

    // MARK: Decoding

    /// One photo open in Apple's decoder, so rendering it again with other values reuses the decoder's work.
    private final class Photo {
        let raw: CIRAWFilter
        let focal: Double?
        /// log2 of the light the sensor was given (t · ISO / N²): the same light gives the same number.
        let exposureIndex: Double?

        init(_ url: URL) throws {
            guard let raw = CIRAWFilter(imageURL: url) else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) isn’t a RAW photo this device can read.")) }
            self.raw = raw
            let native = raw.nativeSize
            raw.scaleFactor = min(1, Float(SeriesMatcher.workSize) / Float(max(native.width, native.height, 1)))
            let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            func number(_ key: CFString) -> Double? {
                let value = exif[key as String]
                return ((value as? NSNumber)?.doubleValue ?? (value as? [NSNumber])?.first?.doubleValue).flatMap { $0 > 0 ? $0 : nil }
            }
            focal = PanoramaDecoder.focalLength35mm(properties) ?? number(kCGImagePropertyExifFocalLength)
            if let t = number(kCGImagePropertyExifExposureTime), let n = number(kCGImagePropertyExifFNumber) {
                exposureIndex = log2(t * (number(kCGImagePropertyExifISOSpeedRatings) ?? 100) / 100 / (n * n))
            } else { exposureIndex = nil }
        }

        /// Scene-linear (no boost, no local tone mapping), lens corrected as Develop does by default. `look` gives
        /// Apple's default rendering instead, for finding faces.
        func image(_ values: SeriesMatchValues, look: Bool = false) -> CIImage {
            raw.neutralTemperature = Float(values.temperature); raw.neutralTint = Float(values.tint); raw.exposure = Float(values.exposure)
            raw.boostAmount = look ? 1 : 0
            if !look {
                raw.boostShadowAmount = 0
                if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
            guard let output = raw.outputImage else { return CIImage.empty() }
            return output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))
        }
    }

    /// RGBA float pixels, top row first; alpha 1 where the pixel is inside the frame.
    struct Raster {
        var width: Int, height: Int
        var pixels: [Float]
        @inline(__always) func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> { let i = (y * width + x) * 4; return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2]) }
        @inline(__always) func alpha(_ x: Int, _ y: Int) -> Float { pixels[(y * width + x) * 4 + 3] }
    }

    private static func render(_ image: CIImage, _ context: CIContext) -> Raster {
        let w = max(1, Int(image.extent.width.rounded(.down))), h = max(1, Int(image.extent.height.rounded(.down)))
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        return Raster(width: w, height: h, pixels: pixels)
    }

    // MARK: Registration

    /// Row-major 3 × 3: a pixel of the target (top-left origin) to the reference's.
    struct Homography {
        var m: simd_double3x3
        func map(_ p: SIMD2<Double>) -> SIMD2<Double> { let v = m * SIMD3(p.x, p.y, 1); return SIMD2(v.x / v.z, v.y / v.z) }

        /// Least squares through four or more pairs (normalized, h33 = 1).
        static func fit(_ source: [SIMD2<Double>], _ destination: [SIMD2<Double>]) -> Homography? {
            guard source.count >= 4, source.count == destination.count else { return nil }
            func normalizer(_ points: [SIMD2<Double>]) -> simd_double3x3 {
                let c = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
                let d = points.reduce(0) { $0 + simd_distance($1, c) } / Double(points.count)
                let s = d > 0 ? 2.0.squareRoot() / d : 1
                return simd_double3x3(rows: [SIMD3(s, 0, -s * c.x), SIMD3(0, s, -s * c.y), SIMD3(0, 0, 1)])
            }
            let ns = normalizer(source), nd = normalizer(destination)
            var normal = [Double](repeating: 0, count: 64), right = [Double](repeating: 0, count: 8)
            for (p0, q0) in zip(source, destination) {
                let pv = ns * SIMD3(p0.x, p0.y, 1), qv = nd * SIMD3(q0.x, q0.y, 1)
                let p = SIMD2(pv.x, pv.y), q = SIMD2(qv.x, qv.y)
                for (row, b) in [([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y], q.x), ([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y], q.y)] {
                    for i in 0..<8 { right[i] += row[i] * b; for j in 0..<8 { normal[i * 8 + j] += row[i] * row[j] } }
                }
            }
            if source.count > 4 { for i in 0..<8 { normal[i * 8 + i] += 1e-9 } }
            guard let x = SeriesMatcher.solve(normal, right, 8) else { return nil }
            let h = nd.inverse * simd_double3x3(rows: [SIMD3(x[0], x[1], x[2]), SIMD3(x[3], x[4], x[5]), SIMD3(x[6], x[7], 1)]) * ns
            let scale = h[2][2]
            guard abs(scale) > 1e-12 else { return nil }
            return Homography(m: simd_double3x3(columns: (h[0] / scale, h[1] / scale, h[2] / scale)))
        }
    }

    static func solve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var m = a, x = b
        for column in 0..<n {
            var pivot = column
            for r in column + 1..<n where abs(m[r * n + column]) > abs(m[pivot * n + column]) { pivot = r }
            guard abs(m[pivot * n + column]) > 1e-300 else { return nil }
            if pivot != column { for c in 0..<n { m.swapAt(column * n + c, pivot * n + c) }; x.swapAt(column, pivot) }
            for r in column + 1..<n {
                let f = m[r * n + column] / m[column * n + column]
                if f == 0 { continue }
                for c in column..<n { m[r * n + c] -= f * m[column * n + c] }
                x[r] -= f * x[column]
            }
        }
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = x[r]
            for c in r + 1..<n { s -= m[r * n + c] * x[c] }
            x[r] = s / m[r * n + r]
        }
        return x
    }

    /// The luminance the corner detector reads, with the median at 18 % so exposure doesn't change what it finds.
    private static func plane(_ image: Raster) -> LuminancePlane {
        var values = [Float](repeating: 0, count: image.width * image.height)
        for i in values.indices { values[i] = max(0, 0.2126 * image.pixels[i * 4] + 0.7152 * image.pixels[i * 4 + 1] + 0.0722 * image.pixels[i * 4 + 2]) }
        let middle = Float(max(1e-6, median(stride(from: 0, to: values.count, by: 7).map { Double(values[$0]) })))
        for i in values.indices { values[i] *= 0.18 / middle }
        return LuminancePlane(width: image.width, height: image.height, values: values)
    }

    /// Draws the same samples on every run, so a photo matches the same way twice.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64 = 0x5eed
        mutating func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 2685821657736338717
        }
    }

    private static func ransac(_ matches: [PanoramaMatch]) -> (Homography, Int)? {
        guard matches.count >= 8 else { return nil }
        var generator = Generator()
        func inliers(_ h: Homography) -> [Int] {
            matches.indices.filter { let p = h.map(matches[$0].b); return p.x.isFinite && simd_distance_squared(p, matches[$0].a) < 9 }
        }
        var best: [Int] = []
        for _ in 0..<3000 {
            var pick = Set<Int>()
            while pick.count < 4 { pick.insert(Int.random(in: 0..<matches.count, using: &generator)) }
            guard let h = Homography.fit(pick.map { matches[$0].b }, pick.map { matches[$0].a }) else { continue }
            let found = inliers(h)
            if found.count > best.count { best = found }
        }
        guard best.count >= 8, var h = Homography.fit(best.map { matches[$0].b }, best.map { matches[$0].a }) else { return nil }
        for _ in 0..<2 {
            let found = inliers(h)
            guard found.count >= 8, let refit = Homography.fit(found.map { matches[$0].b }, found.map { matches[$0].a }) else { break }
            h = refit; best = found
        }
        return (h, best.count)
    }

    /// The target laid over the reference's frame; transparent outside the target.
    private static func warp(_ target: CIImage, _ h: Homography, into size: CGSize) -> CIImage {
        let w = target.extent.width, height = target.extent.height
        func corner(_ x: Double, _ y: Double) -> CIVector { let p = h.map(SIMD2(x, y)); return CIVector(x: p.x, y: size.height - p.y) }
        let warped = target.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": corner(0, 0), "inputTopRight": corner(w, 0), "inputBottomRight": corner(w, height), "inputBottomLeft": corner(0, height)])
        let frame = CGRect(origin: .zero, size: size)
        return warped.cropped(to: frame).composited(over: CIImage(color: .clear).cropped(to: frame))
    }

    /// Correlation of gradient strength over the pixels both cover, which exposure and white balance don't change, and
    /// the share of the reference the target covers.
    private static func correlation(_ a: Raster, _ b: Raster) -> (overlap: Double, correlation: Double) {
        let step = 2
        func lum(_ image: Raster, _ x: Int, _ y: Int) -> Double { log(max(1e-5, luminance(image.rgb(x, y)))) }
        var xs: [Double] = [], ys: [Double] = [], inside = 0, total = 0
        for y in stride(from: step, to: a.height - step, by: step) { for x in stride(from: step, to: a.width - step, by: step) {
            total += 1
            guard b.alpha(x, y) > 0.999, b.alpha(x + step, y) > 0.999, b.alpha(x, y + step) > 0.999 else { continue }
            inside += 1
            xs.append(hypot(lum(a, x + step, y) - lum(a, x, y), lum(a, x, y + step) - lum(a, x, y)))
            ys.append(hypot(lum(b, x + step, y) - lum(b, x, y), lum(b, x, y + step) - lum(b, x, y)))
        } }
        guard xs.count > 100 else { return (Double(inside) / Double(max(1, total)), 0) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in xs.indices { let dx = xs[i] - mx, dy = ys[i] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        return (Double(inside) / Double(max(1, total)), sxy / max(1e-12, (sxx * syy).squareRoot()))
    }

    /// The target onto the reference: corners matched after scaling the target by the focal-length ratio, so both show
    /// the scene at about the same size, then a homography. Nil when the photos don't show the same place.
    private func register(_ target: Photo, _ image: CIImage) -> Homography? {
        var ratio = 1.0
        if let a = reference.focal, let b = target.focal { ratio = b / a }
        let size = CGSize(width: linear.width, height: linear.height)
        var best: (h: Homography, correlation: Double, inliers: Int, overlap: Double)?
        for s in abs(log(ratio)) > 0.05 ? [1 / ratio, 1.0] : [1.0] {
            let scaled = Self.render(image.transformed(by: CGAffineTransform(scaleX: s, y: s)), context)
            guard scaled.width > 64, scaled.height > 64 else { continue }
            let matches = PanoramaFeatures.match(features, PanoramaFeatures.detect(Self.plane(scaled), limit: 2000), ratio: 0.85)
            guard let (fitted, inliers) = Self.ransac(matches) else { continue }
            let h = Homography(m: fitted.m * simd_double3x3(diagonal: SIMD3(s, s, 1)))
            let c = Self.correlation(linear, Self.render(Self.warp(image, h, into: size), context))
            if c.overlap > 0.05, best == nil || c.correlation > best!.correlation { best = (h, c.correlation, inliers, c.overlap) }
            if c.correlation > 0.7 { break }
        }
        // Light from another side changes the shading, so a lower correlation with many matches still counts.
        guard let best, best.overlap > 0.1, best.correlation > 0.5 || (best.inliers >= 40 && best.correlation > 0.3) else { return nil }
        return best.h
    }

    // MARK: Shared content

    struct Grid {
        let size = SeriesMatcher.block, columns: Int, rows: Int
        init(width: Int, height: Int) { columns = width / SeriesMatcher.block; rows = height / SeriesMatcher.block }
        var count: Int { columns * rows }
    }

    @inline(__always) static func luminance(_ v: SIMD3<Double>) -> Double { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
    @inline(__always) static func luminance(_ v: SIMD3<Float>) -> Double { Double(0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z) }
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The level a channel clips at, when the photo has a clipped plateau; nil when nothing is clipped.
    private static func clipLevel(_ image: Raster) -> Float? {
        var top: Float = 0
        for i in stride(from: 0, to: image.pixels.count, by: 4) where image.pixels[i + 3] > 0.999 { top = max(top, image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]) }
        var near = 0, total = 0
        for i in stride(from: 0, to: image.pixels.count, by: 4) where image.pixels[i + 3] > 0.999 {
            total += 1
            if max(image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]) >= 0.98 * top { near += 1 }
        }
        return Double(near) >= 0.0002 * Double(total) ? 0.95 * top : nil
    }

    /// Each block's mean; nil for a block with a pixel outside the frame or clipped.
    private static func blockMeans(_ image: Raster, _ grid: Grid, clip: Float?) -> [SIMD3<Double>?] {
        var out = [SIMD3<Double>?](repeating: nil, count: grid.count)
        guard image.width >= grid.columns * grid.size, image.height >= grid.rows * grid.size else { return out }
        out.withUnsafeMutableBufferPointer { buffer in
            let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: grid.rows) { by in
                for bx in 0..<grid.columns {
                    var sum = SIMD3<Double>.zero, ok = true
                    outer: for y in by * grid.size..<(by + 1) * grid.size { for x in bx * grid.size..<(bx + 1) * grid.size {
                        let i = (y * image.width + x) * 4
                        if image.pixels[i + 3] < 0.999 { ok = false; break outer }
                        if let clip, max(image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]) >= clip { ok = false; break outer }
                        sum += SIMD3(Double(image.pixels[i]), Double(image.pixels[i + 1]), Double(image.pixels[i + 2]))
                    } }
                    buffer[by * grid.columns + bx] = ok ? sum / Double(grid.size * grid.size) : nil
                }
            }
        }
        return out
    }

    private enum Content { case flat, agree, differ }

    /// Whether a block shows the same thing in both: the correlation of log luminance inside it. Two flat blocks can't
    /// be told apart.
    private static func compare(_ a: Raster, _ b: Raster, _ grid: Grid, _ i: Int) -> Content {
        let bx = i % grid.columns, by = i / grid.columns
        var xs: [Double] = [], ys: [Double] = []
        for y in stride(from: by * grid.size, to: (by + 1) * grid.size, by: 2) { for x in stride(from: bx * grid.size, to: (bx + 1) * grid.size, by: 2) {
            xs.append(log(max(1e-6, luminance(a.rgb(x, y))))); ys.append(log(max(1e-6, luminance(b.rgb(x, y)))))
        } }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for k in xs.indices { let dx = xs[k] - mx, dy = ys[k] - my; sxy += dx * dy; sxx += dx * dx; syy += dy * dy }
        let sa = (sxx / Double(xs.count)).squareRoot(), sb = (syy / Double(ys.count)).squareRoot()
        if sa < 0.04 && sb < 0.04 { return abs(sa - sb) < 0.03 ? .flat : .differ }
        if sa < 0.04 || sb < 0.04 { return .differ }
        return sxy / (sxx * syy).squareRoot() > 0.7 ? .agree : .differ
    }

    /// (log luminance ratio, log R/G ratio, log B/G ratio) of `t` against `r`.
    static func difference(_ t: SIMD3<Double>, _ r: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(log(luminance(t) / luminance(r)), log((t.x / t.y) / (r.x / r.y)), log((t.z / t.y) / (r.z / r.y)))
    }

    /// A robust centre of the differences: from the per-component median, Cauchy-weighted means.
    static func robustCentre(_ all: [SIMD3<Double>]) -> SIMD3<Double> {
        let ds = all.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard !ds.isEmpty else { return .zero }
        var c = SIMD3(median(ds.map(\.x)), median(ds.map(\.y)), median(ds.map(\.z)))
        for _ in 0..<8 {
            let distances = ds.map { simd_distance($0, c) }
            let scale = max(0.01, 1.4826 * median(distances))
            let weights = distances.map { 1 / (1 + ($0 / (2.5 * scale)) * ($0 / (2.5 * scale))) }
            c = zip(ds, weights).reduce(SIMD3<Double>.zero) { $0 + $1.0 * $1.1 } / weights.reduce(0, +)
        }
        return c
    }

    // MARK: Solve

    /// Newton on (exposure, mired, tint) against a three-part residual, with a forward-difference Jacobian, capped
    /// steps and the sliders' ranges. Converges in one to three steps.
    static func newton(start: SeriesMatchValues, _ f: (SeriesMatchValues) -> SIMD3<Double>) -> SeriesMatchValues {
        func make(_ e: Double, _ mired: Double, _ tint: Double) -> SeriesMatchValues { SeriesMatchValues(exposure: e, temperature: 1e6 / max(1, mired), tint: tint).clamped }
        var s = start.clamped, r = f(s)
        guard r.x.isFinite, r.y.isFinite, r.z.isFinite else { return s.rounded }
        for _ in 0..<6 {
            if simd_reduce_max(simd_abs(r)) < 0.002 { break }
            let steps = [0.25, 15.0, 5.0]
            var jacobian = [Double](repeating: 0, count: 9)
            for k in 0..<3 {
                var e = s.exposure, m = s.mired, t = s.tint
                switch k { case 0: e += steps[0]; case 1: m += steps[1]; default: t += steps[2] }
                let column = (f(make(e, m, t)) - r) / steps[k]
                jacobian[k] = column.x; jacobian[3 + k] = column.y; jacobian[6 + k] = column.z
            }
            guard var d = solve(jacobian, [-r.x, -r.y, -r.z], 3), d.allSatisfy(\.isFinite) else { break }
            d[0] = min(2, max(-2, d[0])); d[1] = min(80, max(-80, d[1])); d[2] = min(40, max(-40, d[2]))
            let next = make(s.exposure + d[0], s.mired + d[1], s.tint + d[2]), rn = f(next)
            // Only a step that helps; otherwise half of it.
            if simd_length_squared(rn) < simd_length_squared(r) { s = next; r = rn } else {
                let half = make(s.exposure + d[0] / 2, s.mired + d[1] / 2, s.tint + d[2] / 2), rh = f(half)
                if simd_length_squared(rh) < simd_length_squared(r) { s = half; r = rh } else { break }
            }
        }
        return s.rounded
    }

    // MARK: Skin

    /// Skin of the largest face as a fixed set of pixels: the lower middle of the face box (cheeks, nose and mouth, so
    /// sunglasses and hair stay out), then pixels near the median skin colour in the middle of its brightness, so a
    /// beard, teeth and highlights don't count. Chosen once; every render averages the same pixels.
    struct Skin {
        var pixels: [Int]
        func mean(_ image: Raster) -> SIMD3<Double> {
            var s = SIMD3<Double>.zero
            for i in pixels { s += SIMD3(Double(image.pixels[i * 4]), Double(image.pixels[i * 4 + 1]), Double(image.pixels[i * 4 + 2])) }
            return s / Double(pixels.count)
        }
    }

    private static func skin(_ photo: Photo, _ values: SeriesMatchValues, _ linear: Raster, _ context: CIContext) -> Skin? {
        let look = photo.image(values, look: true)
        guard let picture = context.createCGImage(look, from: CGRect(x: 0, y: 0, width: linear.width, height: linear.height), format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: picture, options: [:]).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              face.confidence > 0.5 else { return nil }
        let w = Double(linear.width), h = Double(linear.height), b = face.boundingBox
        let box = (x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
        guard box.width >= 12, box.height >= 12 else { return nil }
        var candidates: [(Int, Double, Double, Double)] = []
        for y in max(0, Int(box.y + 0.45 * box.height))..<min(linear.height, Int(box.y + 0.9 * box.height)) {
            for x in max(0, Int(box.x + 0.2 * box.width))..<min(linear.width, Int(box.x + 0.8 * box.width)) {
                let p = linear.rgb(x, y)
                guard p.x > 0, p.y > 0, p.z > 0 else { continue }
                candidates.append((y * linear.width + x, luminance(p), log(Double(p.x / p.y)), log(Double(p.z / p.y))))
            }
        }
        guard candidates.count >= 30 else { return nil }
        let brightness = candidates.map(\.1).sorted()
        let low = brightness[Int(Double(brightness.count - 1) * 0.3)], high = brightness[Int(Double(brightness.count - 1) * 0.85)]
        let red = median(candidates.map(\.2)), blue = median(candidates.map(\.3))
        let kept = candidates.filter { $0.1 >= low && $0.1 <= high && abs($0.2 - red) < 0.15 && abs($0.3 - blue) < 0.15 }.map(\.0)
        return kept.count >= 20 ? Skin(pixels: kept) : nil
    }
}
