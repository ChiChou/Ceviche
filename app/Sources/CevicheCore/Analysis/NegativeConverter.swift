import Foundation
import CoreImage
import ImageIO
import simd

/// The film a negative was shot on: color negatives are balanced per channel against their orange mask, black and white
/// ones are inverted on luminance into a neutral positive.
public enum NegativeFilm: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case color = "Color", blackAndWhite = "B&W"
}

/// Quarter turns followed by a horizontal reflection. Controls operate on the displayed axes; the frame stays
/// in scan coordinates so orientation never changes the film-base measurement or the selected picture area.
public struct NegativeOrientation: Equatable, Sendable {
    public private(set) var quarterTurns = 0
    public private(set) var mirrored = false
    public init() {}

    public var swapsDimensions: Bool { quarterTurns % 2 != 0 }
    public func rotated(clockwise: Bool) -> Self {
        var result = self
        let step = (clockwise ? 1 : -1) * (mirrored ? -1 : 1)
        result.quarterTurns = (quarterTurns + step + 4) % 4
        return result
    }
    public func flipped(horizontal: Bool) -> Self {
        var result = self
        result.mirrored.toggle()
        if !horizontal { result.quarterTurns = (quarterTurns + 2) % 4 }
        return result
    }
    /// Scan fractions from the top left, mapped onto the displayed scan.
    public func displayPoint(_ point: CGPoint) -> CGPoint {
        var p = point
        for _ in 0..<quarterTurns { p = CGPoint(x: 1 - p.y, y: p.x) }
        if mirrored { p.x = 1 - p.x }
        return p
    }
    /// A displayed corner dragged back onto the original scan.
    public func scanPoint(_ point: CGPoint) -> CGPoint {
        var p = point
        if mirrored { p.x = 1 - p.x }
        for _ in 0..<quarterTurns { p = CGPoint(x: p.y, y: 1 - p.x) }
        return p
    }
    /// The same orientation baked into pixels for the positive DNG.
    func apply(to image: CIImage) -> CIImage {
        let orientations: [CGImagePropertyOrientation] = mirrored
            ? [.upMirrored, .leftMirrored, .downMirrored, .rightMirrored]
            : [.up, .right, .down, .left]
        let image = image.oriented(orientations[quarterTurns])
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

/// The picture area on a scan: four corners in fractions of the scan's width and height from its top left, in the
/// order top left, top right, bottom right, bottom left. Converting maps it onto a rectangle, which straightens and
/// crops in one step.
public struct FrameQuad: Codable, Equatable, Sendable {
    public var corners: [CGPoint]
    public init(corners: [CGPoint]) {
        precondition(corners.count == 4)
        self.corners = corners
    }
    public static let full = FrameQuad(corners: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])

    /// The point at `(u, v)` on the straightened frame (fractions from its top left) on the scan.
    public func scanPoint(_ p: CGPoint) -> CGPoint {
        let q = homography * SIMD3(Double(p.x), Double(p.y), 1)
        return CGPoint(x: q.x / q.z, y: q.y / q.z)
    }
    /// The inverse of `scanPoint`.
    public func framePoint(_ p: CGPoint) -> CGPoint {
        let q = homography.inverse * SIMD3(Double(p.x), Double(p.y), 1)
        return CGPoint(x: q.x / q.z, y: q.y / q.z)
    }
    /// Maps the unit square onto the corners (Heckbert's square-to-quad projection).
    private var homography: double3x3 {
        let p = corners.map { SIMD2(Double($0.x), Double($0.y)) }
        let s = p[0] - p[1] + p[2] - p[3], d1 = p[1] - p[2], d2 = p[3] - p[2]
        let det = d1.x * d2.y - d2.x * d1.y
        let g = abs(det) < 1e-12 ? 0 : (s.x * d2.y - d2.x * s.y) / det
        let h = abs(det) < 1e-12 ? 0 : (d1.x * s.y - s.x * d1.y) / det
        // Columns: x, y and constant terms.
        return double3x3(columns: (SIMD3(p[1].x - p[0].x + g * p[1].x, p[1].y - p[0].y + g * p[1].y, g),
                                   SIMD3(p[3].x - p[0].x + h * p[3].x, p[3].y - p[0].y + h * p[3].y, h),
                                   SIMD3(p[0].x, p[0].y, 1)))
    }
    /// Corners inside the scan and in order, so no edge crosses another.
    public var isValid: Bool {
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= -0.001 && $0.x <= 1.001 && $0.y >= -0.001 && $0.y <= 1.001 }) else { return false }
        let signs = (0..<4).map { i -> Double in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            return Double((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        }
        return signs.allSatisfy { $0 > 1e-6 } || signs.allSatisfy { $0 < -1e-6 }
    }
}

/// What one scan gives the measurement of an inversion: its film base read around the frame and the picture's
/// linear values per channel. A roll is measured on all its scans' samples at once.
public struct NegativeSample: Sendable {
    /// The film base read just outside the frame.
    var base: SIMD3<Float>
    /// Picture values per channel, opaque areas left out.
    var channels: [[Float]]
    /// The frame the sample was measured in.
    public let frame: FrameQuad
    /// The scan's exposure (seconds × ISO / f²), so a base picked on one scan can be carried to the others.
    var exposure: Double = 1
    /// What the base is multiplied by, per channel, to read as it would under one fixed white balance: scans shot at
    /// different white balances then compare. 1 until `NegativeConverter.rollSample` measures it.
    var neutral = SIMD3<Float>(repeating: 1)
    /// The base at an exposure of 1 under the fixed white balance, for telling rolls apart.
    public var comparableBase: SIMD3<Float> { NegativeConverter.measuredBase(self) * neutral / Float(exposure) }
}

/// How a negative becomes a positive: its film base (the clear orange or grey of unexposed film), each channel's
/// density range above it, and a midtone balance. Measured on the frame, or on a whole roll, so scans convert the
/// same in the preview and the file.
public struct NegativeInversion: Equatable, Sendable {
    /// Linear scan values of the film base, the positive's black.
    var base: SIMD3<Float>
    /// Stops of density above the base at the positive's white, per channel.
    var density: SIMD3<Float>
    /// Powers on the normalized density that bring each channel's midtones together.
    var gamma: SIMD3<Float>
    /// The scene's range in stops from the base to white.
    var stops: Float
    var monochrome: Bool
    /// The picture's median density above the base, log10, per channel: where a print puts mid gray.
    var median = SIMD3<Float>(repeating: 0.7)
    /// The positive's white, below 1 so the brightest highlights keep some room.
    static let white: Float = 0.9
    /// The brightest a positive gets: two stops over white. The opaque holder or dust would otherwise
    /// invert to values so high the DNG's white level leaves the picture too few levels.
    static let ceiling: Float = 3.6

    /// Linear positive RGB for linear scan RGB.
    @inline(__always) func positive(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        if monochrome {
            let y = 0.2126 * r / base.x + 0.7152 * g / base.y + 0.0722 * b / base.z
            let t = max(0, log2(1 / max(y, 1e-6)) / density.y)
            let v = min(Self.ceiling, Self.white * exp2(stops * (t - 1)))
            return SIMD3(repeating: v.isFinite ? v : 0)
        }
        var out = SIMD3<Float>()
        let scan = SIMD3(r, g, b)
        for c in 0..<3 {
            let t = pow(max(0, log2(base[c] / max(scan[c], 1e-6)) / density[c]), gamma[c])
            let v = min(Self.ceiling, Self.white * exp2(stops * (t - 1)))
            out[c] = v.isFinite ? v : 0
        }
        return out
    }
    /// Inverts linear RGBA rows in place, keeping alpha.
    func apply(_ rgba: inout [Float]) {
        let count = rgba.count / 4
        rgba.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: max(1, min(64, count / 65536))) { chunk in
                let chunks = max(1, min(64, count / 65536))
                let start = count * chunk / chunks, end = count * (chunk + 1) / chunks
                for i in start..<end {
                    let v = positive(p[4 * i], p[4 * i + 1], p[4 * i + 2])
                    p[4 * i] = v.x; p[4 * i + 1] = v.y; p[4 * i + 2] = v.z
                }
            }
        }
    }
}

/// Convert Negative: develops a camera scan of a film negative as shot, maps the frame's four corners onto a rectangle,
/// inverts it against the film base and writes the positive as a linear DNG that keeps the scan's EXIF, like Denoise.
public enum NegativeConverter {
    /// The name the result gets after the scan's own: `DSC0001-Positive.dng`.
    public static let suffix = "Positive"
    /// The long side frames are found and measured at.
    static let analysisSize = 1600

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
    /// The scan developed as shot without noise reduction (grain is the picture), in linear extended sRGB, extent at the origin.
    static func developed(_ url: URL, metadata: PanoramaFrameMetadata, longEdge: Int?) throws -> CIImage {
        let image = try PanoramaDecoder.developedImage(url, longEdge: longEdge, whiteBalance: (metadata.temperature, metadata.tint), noiseReduction: false)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    /// The frame mapped onto a rectangle, extent at the origin; `longEdge` scales it down to at most that size.
    static func straightened(_ image: CIImage, frame: FrameQuad, longEdge: Int? = nil) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        // Core Image counts y up from the bottom.
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: (1 - p.y) * h) }
        var out = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(frame.corners[0]), "inputTopRight": point(frame.corners[1]),
            "inputBottomRight": point(frame.corners[2]), "inputBottomLeft": point(frame.corners[3]), "inputCrop": true])
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        if let longEdge {
            let scale = min(1, Double(longEdge) / max(out.extent.width, out.extent.height))
            if scale < 1 { out = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return out.cropped(to: CGRect(origin: .zero, size: CGSize(width: out.extent.width.rounded(.down), height: out.extent.height.rounded(.down))))
    }
    /// Linear RGBA rows top down.
    static func pixels(_ image: CIImage, context: CIContext) -> (rgba: [Float], width: Int, height: Int) {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var rgba = [Float](repeating: 0, count: max(0, width * height * 4))
        guard width > 0, height > 0 else { return (rgba, 0, 0) }
        rgba.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        return (rgba, width, height)
    }

    // MARK: Finding the frame

    /// The picture area on a scan given as linear RGBA rows top down: the long straight edges where the film base
    /// meets the picture, or where the film meets a dark holder when there is no base between them, paired so the
    /// frame sits about as far from both sides of the scan, then fitted as lines so a skewed frame is followed.
    static func detectFrame(_ rgba: [Float], width W: Int, height H: Int) -> FrameQuad {
        guard W > 32, H > 32 else { return .full }
        var L = [Float](repeating: 0, count: W * H)
        for i in 0..<W * H { L[i] = log2(max(1e-5, 0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2])) }
        func l(_ x: Int, _ y: Int) -> Float { L[min(H - 1, max(0, y)) * W + min(W - 1, max(0, x))] }
        let k = 2, step: Float = 0.12, holder: Float = 1.5
        // Positive where the left (or upper) side is brighter.
        func dx(_ x: Int, _ y: Int) -> Float { l(x - k, y) - l(x + k, y) }
        func dy(_ x: Int, _ y: Int) -> Float { l(x, y - k) - l(x, y + k) }

        /// A candidate edge: its position, how much of the frame's length it runs along, and which way it steps.
        struct Edge { var position: Int; var coverage: Double; var sign: Float }
        func peaks(_ range: Range<Int>, sign: Float, weight: Double, _ coverage: (Int) -> Double) -> [Edge] {
            guard !range.isEmpty else { return [] }
            let v = range.map(coverage)
            var out: [Edge] = []
            for i in v.indices where v[i] >= 0.3 {
                let window = max(0, i - 4)...min(v.count - 1, i + 4)
                if window.allSatisfy({ v[$0] <= v[i] }), !out.contains(where: { abs($0.position - (range.lowerBound + i)) <= 4 }) {
                    out.append(Edge(position: range.lowerBound + i, coverage: v[i] * weight, sign: sign))
                }
            }
            return Array(out.sorted { $0.coverage > $1.coverage }.prefix(8))
        }
        /// The pair of opposite edges that run furthest along the frame and leave similar margins. A base-to-picture edge
        /// further out than the film's own edge against the holder lies on the holder (a light leak or the holder's rim)
        /// and can't bound the frame: on a 6 × 6 scan, a bright line in the holder outscored the film's edge by a hair and
        /// took in the neighbouring frame.
        func pair(_ a: [Edge], _ b: [Edge], size: Int, low: Float, high: Float) -> (Edge, Edge) {
            let fallback = (Edge(position: 0, coverage: 0, sign: low), Edge(position: size - 1, coverage: 0, sign: high))
            let nearHolder = a.filter { $0.sign != low }.map(\.position).min(), farHolder = b.filter { $0.sign != high }.map(\.position).max()
            let a = a.filter { edge in edge.sign != low || nearHolder.map { edge.position >= $0 } ?? true }
            let b = b.filter { edge in edge.sign != high || farHolder.map { edge.position <= $0 } ?? true }
            var best = fallback, bestScore = -Double.infinity
            for p in a + [fallback.0] {
                for q in b + [fallback.1] where q.position - p.position > size / 4 {
                    let margins = abs(Double(p.position) - Double(size - 1 - q.position)) / Double(size)
                    let score = p.coverage + q.coverage - 2 * margins
                    if score > bestScore { bestScore = score; best = (p, q) }
                }
            }
            return best
        }
        func share(_ n: Int, _ total: Int) -> Double { Double(n) / Double(max(1, total)) }

        var ys = H / 10..<H * 9 / 10, xs = W / 10..<W * 9 / 10
        var left = Edge(position: 0, coverage: 0, sign: 1), right = Edge(position: W - 1, coverage: 0, sign: -1)
        var top = Edge(position: 0, coverage: 0, sign: 1), bottom = Edge(position: H - 1, coverage: 0, sign: -1)
        for _ in 0..<3 {
            let rows = Array(ys), columns = Array(xs)
            // Base to picture going inward, or holder to film (a large step the other way).
            let lc = peaks(k..<W / 2, sign: 1, weight: 1) { x in share(rows.filter { dx(x, $0) > step }.count, rows.count) }
                + peaks(k..<W / 2, sign: -1, weight: 0.9) { x in share(rows.filter { dx(x, $0) < -holder }.count, rows.count) }
            let rc = peaks(W / 2..<W - k, sign: -1, weight: 1) { x in share(rows.filter { dx(x, $0) < -step }.count, rows.count) }
                + peaks(W / 2..<W - k, sign: 1, weight: 0.9) { x in share(rows.filter { dx(x, $0) > holder }.count, rows.count) }
            let tc = peaks(k..<H / 2, sign: 1, weight: 1) { y in share(columns.filter { dy($0, y) > step }.count, columns.count) }
                + peaks(k..<H / 2, sign: -1, weight: 0.9) { y in share(columns.filter { dy($0, y) < -holder }.count, columns.count) }
            let bc = peaks(H / 2..<H - k, sign: -1, weight: 1) { y in share(columns.filter { dy($0, y) < -step }.count, columns.count) }
                + peaks(H / 2..<H - k, sign: 1, weight: 0.9) { y in share(columns.filter { dy($0, y) > holder }.count, columns.count) }
            (left, right) = pair(lc, rc, size: W, low: 1, high: -1)
            (top, bottom) = pair(tc, bc, size: H, low: 1, high: -1)
            let ih = bottom.position - top.position, iw = right.position - left.position
            ys = (top.position + ih / 10)..<max(top.position + ih / 10 + 1, bottom.position - ih / 10)
            xs = (left.position + iw / 10)..<max(left.position + iw / 10 + 1, right.position - iw / 10)
        }

        /// A fitted line `across = a * along + b` near a found edge, following its strongest step in each row or column.
        func fit(_ edge: Edge, along: Range<Int>, vertical: Bool) -> (a: Double, b: Double) {
            let reach = max(3, (vertical ? W : H) / 80)
            var samples: [(Double, Double)] = []
            for t in stride(from: along.lowerBound, to: along.upperBound, by: 2) {
                var best: (Int, Float) = (edge.position, 0)
                for p in max(1, edge.position - reach)...min((vertical ? W : H) - 2, edge.position + reach) {
                    let d = edge.sign * (vertical ? dx(p, t) : dy(t, p))
                    if d > best.1 { best = (p, d) }
                }
                if best.1 > step { samples.append((Double(t), Double(best.0))) }
            }
            var line = (a: 0.0, b: Double(edge.position))
            guard edge.coverage > 0, samples.count >= 12 else { return line }
            for _ in 0..<3 {
                let n = Double(samples.count)
                let sx = samples.reduce(0) { $0 + $1.0 }, sy = samples.reduce(0) { $0 + $1.1 }
                let sxx = samples.reduce(0) { $0 + $1.0 * $1.0 }, sxy = samples.reduce(0) { $0 + $1.0 * $1.1 }
                let denominator = n * sxx - sx * sx
                guard abs(denominator) > 1e-9 else { break }
                let a = (n * sxy - sx * sy) / denominator
                line = (a: max(-0.05, min(0.05, a)), b: (sy - a * sx) / n)
                let kept = samples.filter { abs($0.1 - (line.a * $0.0 + line.b)) <= 1.5 }
                if kept.count < 12 || kept.count == samples.count { break }
                samples = kept
            }
            return line
        }
        // Inward a little, past the soft edge of the picture.
        let inset = 1 + Double(max(W, H)) * 0.003
        var l = fit(left, along: ys, vertical: true), r = fit(right, along: ys, vertical: true)
        var t = fit(top, along: xs, vertical: false), b = fit(bottom, along: xs, vertical: false)
        l.b += inset; r.b -= inset; t.b += inset; b.b -= inset
        /// Where a vertical line `x = a y + b` meets a horizontal one `y = c x + d`.
        func corner(_ v: (a: Double, b: Double), _ h: (a: Double, b: Double)) -> CGPoint {
            let y = (h.a * v.b + h.b) / (1 - h.a * v.a), x = v.a * y + v.b
            return CGPoint(x: min(1, max(0, x / Double(W))), y: min(1, max(0, y / Double(H))))
        }
        let quad = FrameQuad(corners: [corner(l, t), corner(r, t), corner(r, b), corner(l, b)])
        return quad.isValid ? quad : .full
    }

    // MARK: Measuring

    /// The inversion for `frame` on a scan given as linear RGBA rows top down. The base is read just outside the
    /// frame, where film between and beside the pictures is unexposed, and is never darker than the clearest part of
    /// the picture; white is a little short of the densest part, per channel.
    static func inversion(_ rgba: [Float], width W: Int, height H: Int, frame: FrameQuad, straightened: [Float],
                          frameWidth fw: Int, frameHeight fh: Int, film: NegativeFilm?) -> (NegativeInversion, suggested: NegativeFilm) {
        let result = balance([sample(rgba, width: W, height: H, frame: frame, straightened: straightened, frameWidth: fw, frameHeight: fh)], film: film)
        return (result.inversions[0], result.suggested)
    }

    /// The base around `frame` and the picture inside it; `limit` keeps at most about that many picture pixels,
    /// evenly spread, so a long roll can be measured in one go.
    static func sample(_ rgba: [Float], width W: Int, height H: Int, frame: FrameQuad, straightened: [Float],
                       frameWidth fw: Int, frameHeight fh: Int, limit: Int? = nil) -> NegativeSample {
        // Base: a band just outside each edge, its brighter half.
        var band: [SIMD3<Float>] = []
        let near = Double(max(3, max(W, H) / 200)), far = Double(max(8, max(W, H) / 70))
        let center = frame.corners.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
        for i in 0..<4 {
            let a = frame.corners[i], b = frame.corners[(i + 1) % 4]
            let ax = Double(a.x) * Double(W), ay = Double(a.y) * Double(H), bx = Double(b.x) * Double(W), by = Double(b.y) * Double(H)
            let length = max(1, hypot(bx - ax, by - ay))
            var nx = -(by - ay) / length, ny = (bx - ax) / length
            let mx = (ax + bx) / 2 - Double(center.x) * Double(W), my = (ay + by) / 2 - Double(center.y) * Double(H)
            if nx * mx + ny * my < 0 { nx = -nx; ny = -ny }
            for s in stride(from: 0.1, through: 0.9, by: 1 / length) {
                for d in stride(from: near, through: far, by: 2) {
                    let x = Int(ax + (bx - ax) * s + nx * d), y = Int(ay + (by - ay) * s + ny * d)
                    guard x >= 0, y >= 0, x < W, y < H else { continue }
                    let p = 4 * (y * W + x)
                    band.append(SIMD3(rgba[p], rgba[p + 1], rgba[p + 2]))
                }
            }
        }
        func luminance(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
        func median(_ values: [Float]) -> Float { let s = values.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let cut = median(band.map(luminance))
        let bright = band.filter { luminance($0) >= cut }
        let base = SIMD3(median(bright.map(\.x)), median(bright.map(\.y)), median(bright.map(\.z)))

        // The picture, inside a margin of its own edges, without anything opaque (holder, tape or dust): no
        // negative is six stops denser than its base.
        var channels: [[Float]] = [[], [], []]
        let mx = fw / 25, my = fh / 25, opaque = base.y / 64
        let stride = limit.map { max(1, Int((Double(max(1, (fw - 2 * mx) * (fh - 2 * my))) / Double(max(1, $0))).squareRoot())) } ?? 1
        for y in Swift.stride(from: my, to: max(my + 1, fh - my), by: stride) where y < fh {
            for x in Swift.stride(from: mx, to: max(mx + 1, fw - mx), by: stride) where x < fw {
                let p = 4 * (y * fw + x)
                guard straightened[p + 1] > opaque else { continue }
                for c in 0..<3 { channels[c].append(max(0, straightened[p + c])) }
            }
        }
        return NegativeSample(base: base, channels: channels, frame: frame)
    }

    /// Inversions for scans measured together, in the samples' order. Each scan keeps its own film base, read around
    /// its frame and never darker than the clearest part of its picture, because the scan's exposure and light can
    /// change from frame to frame; `base`, picked on unexposed film, is given at an exposure of 1 and scaled to each
    /// scan's. The density range and midtone balance belong to the film, so they come from all the pictures together.
    /// Scans whose film base, against their exposure, doesn't match the roll's are converted on their own (`apart`):
    /// another film stock, black and white among color, or a change of light.
    public static func balance(_ samples: [NegativeSample], film: NegativeFilm?, base picked: SIMD3<Float>? = nil) -> (inversions: [NegativeInversion], suggested: NegativeFilm, apart: Set<Int>) {
        let apart = apart(samples)
        guard !apart.isEmpty else { return pooled(samples, film: film, base: picked) }
        let together = samples.indices.filter { !apart.contains($0) }
        let roll = pooled(together.map { samples[$0] }, film: film, base: picked)
        var inversions = [NegativeInversion?](repeating: nil, count: samples.count)
        for (index, inversion) in zip(together, roll.inversions) { inversions[index] = inversion }
        for index in apart { inversions[index] = pooled([samples[index]], film: nil, base: nil).inversions[0] }
        return (inversions.map { $0! }, roll.suggested, apart)
    }

    /// The film base a scan was measured with: read around the frame, never darker than the clearest part of its picture.
    fileprivate static func measuredBase(_ sample: NegativeSample) -> SIMD3<Float> {
        var base = sample.base
        for c in 0..<3 {
            let values = sample.channels[c].sorted()
            if !values.isEmpty { base[c] = max(base[c], values[Int(Double(values.count - 1) * 0.999)]) }
        }
        return simd_max(base, SIMD3(repeating: 1e-4))
    }

    /// Scans of three or more whose base, at an exposure of 1, doesn't match the scan most others match: off by more
    /// than a quarter stop in at least two channels. One channel alone may be clipped by the scan, as red often is under
    /// an orange mask. Measured against the largest group, so a selection spanning several rolls keeps the biggest.
    static func apart(_ samples: [NegativeSample]) -> Set<Int> {
        guard samples.count >= 3 else { return [] }
        let bases = samples.map { measuredBase($0) / Float($0.exposure) }
        func matches(_ a: Int, _ b: Int) -> Bool { (0..<3).map { abs(log2(bases[a][$0] / bases[b][$0])) }.sorted()[1] <= 0.25 }
        let counts = bases.indices.map { a in bases.indices.filter { matches(a, $0) }.count }
        guard let reference = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[reference] > 1 else { return [] }
        return Set(bases.indices.filter { !matches(reference, $0) })
    }

    private static func pooled(_ samples: [NegativeSample], film: NegativeFilm?, base picked: SIMD3<Float>?) -> (inversions: [NegativeInversion], suggested: NegativeFilm, apart: Set<Int>) {
        func median(_ values: [Float]) -> Float { let s = values.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let bases = samples.map { sample -> SIMD3<Float> in
            if let picked { return simd_max(picked * Float(sample.exposure), SIMD3(repeating: 1e-4)) }
            return measuredBase(sample)
        }
        // An orange mask is a color negative; clear or grey base is black and white.
        let suggested: NegativeFilm = median(bases.map { $0.max() / max(1e-6, $0.min()) }) < 1.3 ? .blackAndWhite : .color
        let monochrome = (film ?? suggested) == .blackAndWhite
        // Stops of density above each scan's own base, none more than ten.
        var stops: [[Float]] = [[], [], []]
        for (sample, base) in zip(samples, bases) {
            for c in 0..<3 { stops[c] += sample.channels[c].map { log2(base[c] / max($0, base[c] / 1024)) } }
        }
        guard !stops[0].isEmpty else {
            return (bases.map { NegativeInversion(base: $0, density: SIMD3(repeating: 4), gamma: SIMD3(repeating: 1), stops: 6, monochrome: monochrome) }, film ?? suggested, [])
        }
        for c in 0..<3 { stops[c].sort() }
        func percentile(_ c: Int, _ q: Double) -> Float { stops[c][Int(Double(stops[c].count - 1) * q)] }
        // White a little short of the densest part, per channel.
        var density = SIMD3<Float>(repeating: 1)
        for c in 0..<3 { density[c] = max(0.5, percentile(c, 0.995)) }
        if monochrome { density = SIMD3(repeating: (density.x + density.y + density.z) / 3) }
        // A color negative's contrast is about 0.6: the scene spans more stops than the film's density.
        let range = min(12, max(4, density.y / 0.6))
        var gamma = SIMD3<Float>(repeating: 1)
        if !monochrome {
            // Each channel's median, halfway (on a log scale) toward their mean, keeping black and white in place.
            var middle = SIMD3<Float>()
            for c in 0..<3 { middle[c] = min(0.95, max(0.05, percentile(c, 0.5) / density[c])) }
            let target = exp((log(middle.x) + log(middle.y) + log(middle.z)) / 3)
            for c in 0..<3 { gamma[c] = pow(log(target) / log(middle[c]), 0.6) }
        }
        // The picture's median density above its base, log10, for printing: the pooled stops are log2.
        let median = SIMD3<Float>((0..<3).map { c in percentile(c, 0.5) * log10(2) })
        return (bases.map { NegativeInversion(base: $0, density: density, gamma: gamma, stops: range, monochrome: monochrome, median: median) }, suggested, [])
    }

    // MARK: Converting

    /// Converts `source` into a positive DNG at `url`. Without a frame, it is found as the dialog would find it;
    /// without a film, the base decides. `progress` hears the fraction done and the step.
    /// `base` is film base picked on unexposed film, at an exposure of 1; `inversion`, when given, is used as it is
    /// (the scan's from a roll), and the scan isn't measured. `print` prints a color negative on paper instead.
    public static func convert(_ source: URL, to url: URL, frame: FrameQuad?, film: NegativeFilm?,
                               orientation: NegativeOrientation = NegativeOrientation(), base: SIMD3<Float>? = nil,
                               inversion: NegativeInversion? = nil, print: NegativePrint? = nil,
                               progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        let metadata = try PanoramaDecoder.metadata(source)
        progress(0, L10n.tr("Developing \(source.lastPathComponent)"))
        let context = context()
        let analysis = frame != nil && inversion != nil ? nil : try Analysis(source, metadata: metadata, context: context)
        guard let frame = frame ?? analysis?.detected,
              let inversion = inversion ?? analysis?.inversion(frame: frame, film: film, base: base, context: context).0 else { throw CancellationError() }
        if cancelled() { throw CancellationError() }
        progress(0.1, L10n.tr("Developing \(source.lastPathComponent)"))
        let full = straightened(try developed(source, metadata: metadata, longEdge: nil), frame: frame)
        var (rgba, width, height) = pixels(orientation.apply(to: full), context: context)
        guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) decoded empty.")) }
        if cancelled() { throw CancellationError() }
        progress(0.6, L10n.tr("Inverting"))
        if let print, !inversion.monochrome, let printed = print.printed(rgba, width: width, height: height, inversion: inversion, context: context) {
            rgba = printed
        } else {
            inversion.apply(&rgba)
        }
        for p in stride(from: 3, to: rgba.count, by: 4) { rgba[p] = 1 }
        if cancelled() { throw CancellationError() }
        progress(0.7, L10n.tr("Writing DNG"))
        let writer = PanoramaDNGWriter(metadata: metadata, source: DNGSourceMetadata(source, process: suffix))
        try writer.write(PanoramaRaster(width: width, height: height, rgba: rgba), to: url,
                         progress: { progress(0.7 + 0.3 * $0, L10n.tr("Writing DNG")) }, cancelled: cancelled)
    }

    /// The scan small enough to measure quickly, with the frame found on it.
    struct Analysis {
        let image: CIImage
        let rgba: [Float]
        let width: Int, height: Int
        let detected: FrameQuad
        /// Seconds × ISO / f², 1 when the scan doesn't say.
        let exposure: Double
        init(_ source: URL, metadata: PanoramaFrameMetadata, context: CIContext) throws {
            exposure = NegativeConverter.exposure(source)
            image = try NegativeConverter.developed(source, metadata: metadata, longEdge: NegativeConverter.analysisSize)
            (rgba, width, height) = NegativeConverter.pixels(image, context: context)
            guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) decoded empty.")) }
            detected = NegativeConverter.detectFrame(rgba, width: width, height: height)
        }
        /// The base and picture in `frame`; see `NegativeConverter.sample`.
        func sample(frame: FrameQuad, limit: Int? = nil, context: CIContext) -> NegativeSample {
            let picture = NegativeConverter.pixels(NegativeConverter.straightened(image, frame: frame), context: context)
            var sample = NegativeConverter.sample(rgba, width: width, height: height, frame: frame, straightened: picture.rgba,
                                                  frameWidth: picture.width, frameHeight: picture.height, limit: limit)
            sample.exposure = exposure
            return sample
        }
        /// The inversion for `frame` alone, with the film its base suggests.
        func inversion(frame: FrameQuad, film: NegativeFilm?, base: SIMD3<Float>? = nil, context: CIContext) -> (NegativeInversion, NegativeFilm) {
            let result = NegativeConverter.balance([sample(frame: frame, context: context)], film: film, base: base)
            return (result.inversions[0], result.suggested)
        }
        /// The mean of the scan around `point` (fractions from its top left).
        func color(at point: CGPoint) -> SIMD3<Float> {
            let r = max(2, max(width, height) / 400)
            let cx = Int(point.x * CGFloat(width)), cy = Int(point.y * CGFloat(height))
            var sum = SIMD3<Float>(), n: Float = 0
            for y in max(0, cy - r)...min(height - 1, cy + r) { for x in max(0, cx - r)...min(width - 1, cx + r) {
                let p = 4 * (y * width + x); sum += SIMD3(rgba[p], rgba[p + 1], rgba[p + 2]); n += 1
            }}
            return n > 0 ? sum / n : SIMD3(repeating: 1)
        }
    }

    /// The light a scan was taken with, seconds × ISO / f², from its EXIF.
    static func exposure(_ url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let time = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, time > 0 else { return 1 }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue ?? 100
        let f = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 1
        return time * max(1, iso) / max(0.01, f * f)
    }

    /// Picture pixels each scan gives a roll's measurement, so a long roll stays quick to balance.
    public static let rollSampleLimit = 40_000

    /// One scan's sample for measuring a roll, in `frame` or the frame found on it.
    public static func rollSample(_ source: URL, frame: FrameQuad?) throws -> NegativeSample {
        let context = context()
        let analysis = try Analysis(source, metadata: try PanoramaDecoder.metadata(source), context: context)
        var sample = analysis.sample(frame: frame ?? analysis.detected, limit: rollSampleLimit, context: context)
        sample.neutral = neutralGain(source, context: context)
        return sample
    }

    /// What each channel of the scan as shot is multiplied by to give it at 5000 K: measured on two small
    /// developments, since the decoder doesn't say. The white balance is applied before the camera's colour matrix, so
    /// this is a close fit (a few hundredths of a stop), not exact.
    static func neutralGain(_ source: URL, context: CIContext) -> SIMD3<Float> {
        guard let metadata = try? PanoramaDecoder.metadata(source), abs(metadata.temperature - 5000) > 20 || abs(metadata.tint) > 1,
              let shot = try? PanoramaDecoder.developedImage(source, longEdge: 200, whiteBalance: (metadata.temperature, metadata.tint), noiseReduction: false),
              let fixed = try? PanoramaDecoder.developedImage(source, longEdge: 200, whiteBalance: (5000, 0), noiseReduction: false) else { return SIMD3(repeating: 1) }
        let a = pixels(shot, context: context), b = pixels(fixed, context: context)
        guard a.width == b.width, a.height == b.height, a.width > 0 else { return SIMD3(repeating: 1) }
        // The brighter half: that is where the film base is.
        var sums = [(Float, SIMD3<Float>, SIMD3<Float>)]()
        for p in stride(from: 0, to: a.rgba.count, by: 4) {
            let x = SIMD3(a.rgba[p], a.rgba[p + 1], a.rgba[p + 2]), y = SIMD3(b.rgba[p], b.rgba[p + 1], b.rgba[p + 2])
            if x.min() > 1e-4, y.min() > 1e-4 { sums.append((x.y, x, y)) }
        }
        guard sums.count > 100 else { return SIMD3(repeating: 1) }
        sums.sort { $0.0 < $1.0 }
        var before = SIMD3<Float>(), after = SIMD3<Float>()
        for (_, x, y) in sums[(sums.count / 2)...] { before += x; after += y }
        return after / before
    }
}

/// The scan for the Convert Negative dialog: the negative as shot, small, the frame found on it, and the scan inverted
/// as any frame measures it.
public final class NegativePreviewer: @unchecked Sendable {
    /// The negative, encoded for display.
    public let scan: CGImage
    public let detected: FrameQuad
    private let analysis: NegativeConverter.Analysis
    private let context = NegativeConverter.context()
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The scan's channels under one fixed white balance against as shot (`NegativeConverter.neutralGain`).
    private let neutral: SIMD3<Float>

    public init(_ source: URL) throws {
        analysis = try NegativeConverter.Analysis(source, metadata: try PanoramaDecoder.metadata(source), context: context)
        neutral = NegativeConverter.neutralGain(source, context: context)
        detected = analysis.detected
        guard let scan = context.createCGImage(analysis.image, from: analysis.image.extent, format: .RGBA8, colorSpace: display) else {
            throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) can’t be decoded."))
        }
        self.scan = scan
    }

    /// The film the base suggests for `frame`.
    public func suggestedFilm(_ frame: FrameQuad) -> NegativeFilm { analysis.inversion(frame: frame, film: nil, context: context).1 }
    /// This scan's part of a roll's measurement.
    public func rollSample(_ frame: FrameQuad) -> NegativeSample {
        var sample = analysis.sample(frame: frame, limit: NegativeConverter.rollSampleLimit, context: context)
        sample.neutral = neutral
        return sample
    }
    /// The scan's color around `point` (fractions of the scan from its top left) at an exposure of 1, for picking
    /// the film base.
    public func base(at point: CGPoint) -> SIMD3<Float> { analysis.color(at: point) / Float(analysis.exposure) }

    /// The whole scan inverted as `frame` measures it, for judging the frame on the positive; printed on paper when
    /// `print` is given and the negative is in color.
    public func inverted(_ frame: FrameQuad, film: NegativeFilm, base: SIMD3<Float>? = nil, print: NegativePrint? = nil) throws -> CGImage {
        try inverted(analysis.inversion(frame: frame, film: film, base: base, context: context).0, print: print)
    }
    /// The whole scan inverted with its inversion from a roll, or printed with it.
    public func inverted(_ inversion: NegativeInversion, print: NegativePrint? = nil) throws -> CGImage {
        var rgba = analysis.rgba
        if let print, !inversion.monochrome, let printed = print.printed(rgba, width: analysis.width, height: analysis.height, inversion: inversion, context: context) {
            rgba = printed
        } else {
            inversion.apply(&rgba)
        }
        let image = CIImage(bitmapData: Data(bytes: rgba, count: rgba.count * 4), bytesPerRow: analysis.width * 16,
                            size: CGSize(width: analysis.width, height: analysis.height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else {
            throw PanoramaError.message(L10n.tr("The preview couldn’t be rendered."))
        }
        return rendered
    }
}

/// Printing a color negative instead of inverting it: the film print reads the scan against its film base as the
/// densities of `stock`, the film the roll was shot on, and prints them on `paper` as the Darkroom prints a film,
/// at the paper's own timing for that stock.
public struct NegativePrint: Codable, Hashable, Sendable {
    public var stock: String
    public var paper: String
    public init(stock: String, paper: String) { self.stock = stock; self.paper = paper }
    public static let defaultStock = FilmSimulation.defaultStock

    /// Linear Rec. 709 RGBA rows of the print, or nil when the stock or paper is unknown or the build has no film
    /// engine; the scan is then inverted instead.
    func printed(_ scan: [Float], width: Int, height: Int, inversion: NegativeInversion, context: CIContext) -> [Float]? {
        var settings = FilmSimulation(stock: stock); settings.medium = paper
        settings.grain = 0; settings.halation = 0
        guard width > 0, height > 0, let medium = settings.output, medium.id == paper, medium.kind == .paper || medium.kind == .printFilm else { return nil }
        return FilmSimulationRenderer.print(scan: scan, width: width, height: height, base: inversion.base, settings: settings)
    }
}
