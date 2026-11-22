import Foundation
import CoreImage

/// What a preview's scopes are measured from: decoded pixels, so they can be computed after the render, off the
/// renderer, and only while a scope is showing.
public struct ScopeSource: @unchecked Sendable {
    /// Levels: the preview itself when it is HDR (extended linear), otherwise the SDR thumbnail.
    let levels: CGImage
    /// Colour: always the SDR thumbnail, in the photo's output profile.
    let colour: CGImage
    /// Stops above SDR white the upper half of the level axis spans; nil for SDR.
    public let hdrStops: Double?
    init(levels: CGImage, colour: CGImage, hdrStops: Double?) { self.levels = levels; self.colour = colour; self.hdrStops = hdrStops }
}

/// Waveform and vectorscope counts for one preview.
///
/// The level axis is the histogram's: sRGB-encoded 0…1 for SDR; for HDR the lower half holds SDR (encoded) and the
/// upper half the stops above SDR white, up to `hdrStops`.
public struct Scopes: Sendable {
    public static let levels = 192
    public static let maximumColumns = 360
    /// Vectorscope cells per side; the plot reaches `chromaReach` from the centre, past the 100 % targets at about 0.5.
    public static let vectorSize = 256
    public static let chromaReach = 0.62
    public let columns: Int
    public let hdrStops: Double?
    /// Red, green, blue and Rec. 709 luma: `levels` rows of `columns` counts each, row 0 at the bottom (black).
    public let waveform: [[Float]]
    /// Pixels per column, for normalising the waveform.
    public let pixelsPerColumn: Float
    /// Cb across, Cr up (Rec. 709, on sRGB-encoded values), `vectorSize` squared, row 0 at the bottom.
    public let vectorscope: [Float]
    public let vectorPixels: Float

    public enum Channel: Int, CaseIterable, Sendable { case red, green, blue, luma }

    public init(_ source: ScopeSource) {
        hdrStops = source.hdrStops
        // Levels: decoded small enough that a column is about a point of the panel.
        let wave = Self.pixels(source.levels, maxWidth: Self.maximumColumns, linear: source.hdrStops != nil)
        columns = max(1, wave.width)
        pixelsPerColumn = Float(max(1, wave.height))
        var bins = Array(repeating: [Float](repeating: 0, count: columns * Self.levels), count: 4)
        let stops = max(1, source.hdrStops ?? 1), hdr = source.hdrStops != nil
        func level(_ value: Float) -> Int? {
            guard value.isFinite else { return nil }
            let position: Double
            if hdr {
                let v = Double(value)
                position = v <= 1 ? Self.encode(v) * 0.5 : 0.5 + log2(v) / stops * 0.5
            } else { position = Double(value) }
            return min(Self.levels - 1, max(0, Int((position * Double(Self.levels - 1)).rounded())))
        }
        for y in 0..<wave.height {
            for x in 0..<wave.width {
                let i = (y * wave.width + x) * 4
                let alpha = wave.data[i + 3]
                guard alpha > 0.000001 else { continue }
                let r = wave.data[i] / alpha, g = wave.data[i + 1] / alpha, b = wave.data[i + 2] / alpha
                for (channel, value) in [r, g, b].enumerated() { if let l = level(value) { bins[channel][l * columns + x] += 1 } }
                if let l = level(0.2126 * r + 0.7152 * g + 0.0722 * b) { bins[3][l * columns + x] += 1 }
            }
        }
        waveform = bins
        // Colour: unclipped extended sRGB, so colours outside sRGB land outside the hexagon of the 100 % targets.
        let colour = Self.pixels(source.colour, maxWidth: 400, linear: false)
        var vector = [Float](repeating: 0, count: Self.vectorSize * Self.vectorSize)
        var counted: Float = 0
        let scale = Double(Self.vectorSize) / (2 * Self.chromaReach), centre = Double(Self.vectorSize) / 2
        for i in stride(from: 0, to: colour.data.count, by: 4) {
            let alpha = colour.data[i + 3]
            guard alpha > 0.000001 else { continue }
            let chroma = Self.chroma(r: Double(colour.data[i] / alpha), g: Double(colour.data[i + 1] / alpha), b: Double(colour.data[i + 2] / alpha))
            let x = Int(centre + chroma.cb * scale), y = Int(centre + chroma.cr * scale)
            guard x >= 0, y >= 0, x < Self.vectorSize, y < Self.vectorSize else { continue }
            vector[y * Self.vectorSize + x] += 1; counted += 1
        }
        vectorscope = vector
        vectorPixels = max(1, counted)
    }

    /// Rec. 709 colour difference of sRGB-encoded values: Cb and Cr each span ±0.5 inside the gamut.
    public static func chroma(r: Double, g: Double, b: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }
    /// The six 100 % targets (red, yellow, green, cyan, blue, magenta), the corners of sRGB's outline on the plot.
    public static let targets: [(name: String, cb: Double, cr: Double)] = [
        ("R", 1, 0, 0), ("YL", 1, 1, 0), ("G", 0, 1, 0), ("CY", 0, 1, 1), ("B", 0, 0, 1), ("MG", 1, 0, 1)
    ].map { (target: (String, Double, Double, Double)) in let c = chroma(r: target.1, g: target.2, b: target.3); return (target.0, c.cb, c.cr) }
    /// The skin tone line, 123° counter-clockwise from +Cb as on broadcast vectorscopes.
    public static let skinLineAngle = 123.0 * .pi / 180

    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    /// Premultiplied RGBA floats, at most `maxWidth` wide, in extended (linear or sRGB-encoded) sRGB.
    static func pixels(_ image: CGImage, maxWidth: Int, linear: Bool) -> (data: [Float], width: Int, height: Int) {
        let source = CIImage(cgImage: image)
        let scale = min(1, Double(maxWidth) / max(1, source.extent.width))
        let small = scale < 1 ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true) : source
        let width = Int(small.extent.width.rounded(.down)), height = Int(small.extent.height.rounded(.down))
        guard width > 0, height > 0 else { return ([], 0, 0) }
        var data = [Float](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: Double(width), height: Double(height)),
                           format: .RGBAf, colorSpace: CGColorSpace(name: linear ? CGColorSpace.extendedLinearSRGB : CGColorSpace.extendedSRGB)!)
        }
        return (data, width, height)
    }
}

public extension Scopes {
    /// How bright a cell is drawn: close to linear in its count against the busiest cells, as on a video scope, so a
    /// stray pixel stays faint and dense traces read as solid lines.
    static func brightness(_ counts: [Float], gamma: Float = 0.75) -> (Float) -> Float {
        let filled = counts.filter { $0 > 0 }.sorted()
        guard !filled.isEmpty else { return { _ in 0 } }
        let reference = max(1, filled[min(filled.count - 1, Int(Double(filled.count - 1) * 0.995))])
        return { count in count > 0 ? min(1, 0.04 + pow(count / reference, gamma)) : 0 }
    }

    enum WaveformStyle: Sendable { case luma, rgb, parade }

    /// The waveform as an image, `levels` high: white for luma, the channels added up for RGB (so neutral tones show
    /// white), and three side-by-side channels for a parade.
    func waveformImage(_ style: WaveformStyle) -> CGImage? {
        let panes = style == .parade ? 3 : 1, width = columns * panes, height = Self.levels
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let channels: [Channel] = style == .luma ? [.luma] : [.red, .green, .blue]
        // A 1-2-1 blur joins the traces of neighbouring rows of a smooth sky into one band, as on a video scope.
        let smoothed = channels.map { Self.smoothed(waveform[$0.rawValue], width: columns, height: height) }
        let curves = smoothed.map { Self.brightness($0) }
        for (index, channel) in channels.enumerated() {
            let counts = smoothed[index], curve = curves[index]
            let offset = style == .parade ? index * columns : 0
            for level in 0..<height {
                let row = height - 1 - level
                for x in 0..<columns {
                    let value = curve(counts[level * columns + x])
                    guard value > 0 else { continue }
                    let p = (row * width + offset + x) * 4
                    let byte = UInt8(min(255, value * 255))
                    switch channel {
                    case .luma: rgba[p] = byte; rgba[p + 1] = byte; rgba[p + 2] = byte
                    case .red, .green, .blue where style == .parade:
                        // Each pane on its own: lighter tints read better on the dark plate than pure primaries.
                        let tint = Self.paradeTints[channel.rawValue]
                        for c in 0..<3 { rgba[p + c] = UInt8(min(255, Float(byte) * tint[c])) }
                    case .red, .green, .blue: rgba[p + channel.rawValue] = max(rgba[p + channel.rawValue], byte)
                    }
                    rgba[p + 3] = 255
                }
            }
        }
        // The empty background stays transparent so the plate shows through; drawn cells are opaque.
        for p in stride(from: 0, to: rgba.count, by: 4) where rgba[p + 3] > 0 {
            let peak = max(rgba[p], rgba[p + 1], rgba[p + 2]); rgba[p + 3] = peak
        }
        return Self.image(rgba, width: width, height: height)
    }

    private static let paradeTints: [[Float]] = [[1, 0.3, 0.26], [0.3, 0.95, 0.3], [0.32, 0.5, 1]]

    /// The vectorscope as an image, each cell in the colour its position stands for, brighter where more pixels fall.
    func vectorscopeImage() -> CGImage? {
        let size = Self.vectorSize
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        // Colours spread over far more cells than levels do, so faint areas (a little foliage) get a gentler curve.
        let curve = Self.brightness(vectorscope, gamma: 0.5), half = Double(size) / 2, reach = Self.chromaReach
        for y in 0..<size {
            for x in 0..<size {
                let value = curve(vectorscope[y * size + x])
                guard value > 0 else { continue }
                let cb = (Double(x) + 0.5 - half) / half * reach, cr = (Double(y) + 0.5 - half) / half * reach
                // Back to RGB at a mid luma, then lifted so faint colours stay readable on the dark plate.
                var r = 0.6 + 1.5748 * cr, b = 0.6 + 1.8556 * cb
                var g = (0.6 - 0.2126 * r - 0.0722 * b) / 0.7152
                let saturation = min(1, 0.4 + hypot(cb, cr) * 12)
                r = 0.85 + (r - 0.85) * saturation; g = 0.85 + (g - 0.85) * saturation; b = 0.85 + (b - 0.85) * saturation
                let peak = max(1, r, g, b)
                let p = ((size - 1 - y) * size + x) * 4
                for (i, c) in [r, g, b].enumerated() { rgba[p + i] = UInt8(max(0, min(1, c / peak)) * Double(value) * 255) }
                rgba[p + 3] = UInt8(Double(value) * 255)
            }
        }
        return Self.image(rgba, width: size, height: size)
    }

    /// `counts` blurred by 1-2-1 across and up, keeping their total.
    static func smoothed(_ counts: [Float], width: Int, height: Int) -> [Float] {
        var across = counts, result = counts
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                across[i] = (counts[i - (x > 0 ? 1 : 0)] + 2 * counts[i] + counts[i + (x < width - 1 ? 1 : 0)]) / 4
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                result[i] = (across[i - (y > 0 ? width : 0)] + 2 * across[i] + across[i + (y < height - 1 ? width : 0)]) / 4
            }
        }
        return result
    }

    private static func image(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
