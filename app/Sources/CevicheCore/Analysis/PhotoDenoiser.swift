import Foundation
import CoreImage

/// How Denoise treats a photo.
public struct DenoiseSettings: Codable, Equatable, Sendable {
    /// 0–100: how much of the network's result replaces the photo.
    public var strength = 100.0
    /// Strength is measured from the photo's own noise instead (`PhotoDenoiser.measuredStrength`).
    public var measured = false
    public init(strength: Double = 100, measured: Bool = false) { self.strength = strength; self.measured = measured }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        strength = try values.decodeIfPresent(Double.self, forKey: .strength) ?? 100
        measured = try values.decodeIfPresent(Bool.self, forKey: .measured) ?? false
    }
}

/// The photo's Develop settings Denoise works at: its Exposure, which the network sees it brightened by, and its white
/// balance, which the photo is developed at and the DNG keeps in its pixels.
public struct DenoiseDevelopment: Equatable, Sendable {
    public var exposure = 0.0
    /// A RAW's Temperature and Tint as Develop has them; nil develops at the photo's as-shot white balance.
    public var temperature: Double?
    public var tint: Double?
    public init(exposure: Double = 0, temperature: Double? = nil, tint: Double? = nil) {
        self.exposure = exposure; self.temperature = temperature; self.tint = tint
    }
    /// The settings saved for a photo; nil is the photo as shot.
    public init(_ saved: Adjustments?) {
        self.init(exposure: saved?.exposure ?? 0, temperature: saved?.temperature, tint: saved?.tint)
    }
}

/// Denoise: develops a RAW photo at its Develop white balance (demosaiced, lens-corrected, without the decoder's
/// noise reduction), runs NAFNet over the whole frame and writes the result as a linear DNG that keeps the photo's
/// EXIF, like a merge. Core Image runs the decode on the GPU when there is one and on the CPU otherwise; Core ML
/// picks the Neural Engine, GPU or CPU for the network.
public enum PhotoDenoiser {
    /// The name the result gets after the photo's own: `DSC0001-NR.dng`.
    public static let suffix = "NR"

    /// The photo developed at `development`'s white balance, in linear extended sRGB with its extent at the origin.
    static func developed(_ url: URL, metadata: PanoramaFrameMetadata, development: DenoiseDevelopment) throws -> CIImage {
        let balance = (development.temperature ?? metadata.temperature, development.tint ?? metadata.tint)
        return try PanoramaDecoder.developedImage(url, longEdge: nil, whiteBalance: balance, noiseReduction: false)
    }
    /// The edits to carry onto the DNG of `source` developed with `saved`: its white balance is in the DNG's pixels, so
    /// it carries as no change from as shot; everything else carries as it is.
    public static func carried(_ saved: Adjustments, source: URL) throws -> Adjustments {
        let metadata = try PanoramaDecoder.metadata(source)
        var carried = saved
        carried.temperature = metadata.temperature; carried.tint = metadata.tint
        return carried
    }
    /// The photo's Exposure in stops, as far as the network is shown it: noise in shadows a brightened photo shows is
    /// treated at the level it is seen.
    static func gain(_ exposure: Double) -> Double { min(4, max(-2, exposure.isFinite ? exposure : 0)) }
    /// `image` denoised at `strength`, seen by the network at `exposure` stops (see `gain`). Values brighter than white
    /// after the change keep theirs.
    static func denoised(_ image: CIImage, strength: Double, exposure: Double) throws -> CIImage {
        let gain = gain(exposure)
        let lifted = gain == 0 ? image : image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gain])
        let result = try NAFNetDenoiseKernel.denoised(lifted, amount: strength)
        return gain == 0 ? result : result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -gain])
    }
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }

    /// Denoises `source` into a DNG at `url`, developed at `development` (see `DenoiseDevelopment`); `progress` hears the
    /// fraction done and the step. Returns the strength used, the measured one when `settings.measured`.
    @discardableResult
    public static func denoise(_ source: URL, to url: URL, settings: DenoiseSettings, development: DenoiseDevelopment = DenoiseDevelopment(),
                               progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> Double {
        guard BundledModel.denoise.isAvailable else { throw PanoramaError.message(L10n.tr("The AI noise reduction model is not installed. Install it in Settings › Models.")) }
        let metadata = try PanoramaDecoder.metadata(source)
        progress(0, L10n.tr("Developing \(source.lastPathComponent)"))
        let developed = try developed(source, metadata: metadata, development: development)
        let exposure = development.exposure
        let width = Int(developed.extent.width.rounded(.down)), height = Int(developed.extent.height.rounded(.down))
        guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) decoded empty.")) }
        if cancelled() { throw CancellationError() }
        var strength = settings.strength
        let rgba = try denoised(developed, width: width, height: height, strength: settings.measured ? nil : settings.strength, exposure: exposure,
                                context: context(), progress: { progress(0.05 + 0.8 * $0, L10n.tr("Reducing noise")) }, cancelled: cancelled,
                                used: { strength = $0 })
        if cancelled() { throw CancellationError() }
        progress(0.85, L10n.tr("Writing DNG"))
        let writer = PanoramaDNGWriter(metadata: metadata, source: DNGSourceMetadata(source, process: suffix))
        try writer.write(PanoramaRaster(width: width, height: height, rgba: rgba), to: url,
                         progress: { progress(0.85 + 0.15 * $0, L10n.tr("Writing DNG")) }, cancelled: cancelled)
        return strength
    }

    /// Grain left on purpose, in 8-bit display levels: a trace of the noise stays so skin and skies keep some texture
    /// rather than looking painted.
    static let keptNoise = 2.0

    /// The strength that leaves `keptNoise` of the photo's noise. The noise is the spread of what the network took out
    /// (before − after) in display-encoded luma, 1.4826 × its median absolute value, so the few edges it softened count
    /// little. Every 7th pixel is read. A clean photo gets a light touch (40 % at least), a noisy one nearly all of it.
    static func measuredStrength(before: UnsafeBufferPointer<Float16>, after: UnsafeBufferPointer<Float>) -> Double {
        // Quarter-level bins over 0–64 levels; a larger difference is an edge, counted in the last bin.
        let bins = 256, perLevel: Float = 4
        var histogram = [Int](repeating: 0, count: bins)
        func encoded(_ v: Float) -> Float {
            let v = min(1, max(0, v))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 255 * (0.2126 * encoded(r) + 0.7152 * encoded(g) + 0.0722 * encoded(b)) }
        var count = 0
        for p in stride(from: 0, to: min(before.count, after.count) - 3, by: 4 * 7) {
            let a = luma(Float(before[p]), Float(before[p + 1]), Float(before[p + 2])), b = luma(after[p], after[p + 1], after[p + 2])
            let difference = abs(a - b)
            guard difference.isFinite else { continue }
            histogram[min(bins - 1, Int(difference * perLevel))] += 1
            count += 1
        }
        guard count > 0 else { return 100 }
        var seen = 0, median: Float = 0
        for (bin, n) in histogram.enumerated() {
            seen += n
            if seen * 2 >= count { median = (Float(bin) + 0.5) / perLevel; break }
        }
        let sigma = 1.4826 * Double(median)
        guard sigma > keptNoise else { return 40 }
        return min(100, max(40, (1 - keptNoise / sigma) * 100)).rounded()
    }

    /// `image`'s `width` × `height` pixels from the origin, denoised like `denoised(_:strength:exposure:)`, as linear
    /// RGBA rows top down with alpha 1. The frame is developed once into memory and every tile of the network runs
    /// once, rather than again at the edge of each region Core Image would render. A nil `strength` is measured from
    /// the result (`measuredStrength`); `used` hears the strength blended at.
    static func denoised(_ image: CIImage, width: Int, height: Int, strength: Double?, exposure: Double, context: CIContext,
                         progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false },
                         used: (Double) -> Void = { _ in }) throws -> [Float] {
        let gain = gain(exposure)
        let lifted = gain == 0 ? image : image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gain])
        var decoded = [Float16](repeating: 0, count: width * height * 4)
        decoded.withUnsafeMutableBytes {
            context.render(lifted, toBitmap: $0.baseAddress!, rowBytes: width * 8, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAh, colorSpace: PanoramaDecoder.space)
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        var blend = Float(min(1, max(0, (strength ?? 100) / 100)))
        let scale = Float(pow(2, -gain))
        try decoded.withUnsafeMutableBufferPointer { decoded in
            try rgba.withUnsafeMutableBufferPointer { rgba in
                // Rows top down from Core Image's maxY, which the grid counts as -height.
                if blend > 0 {
                    try NAFNetTiles.run(NAFNetTiles.Pixels(base: decoded.baseAddress!, rowLength: width * 4, x: 0, y: -height, width: width, height: height),
                                        into: NAFNetTiles.Pixels(base: rgba.baseAddress!, rowLength: width * 4, x: 0, y: -height, width: width, height: height),
                                        networks: NAFNetTiles.networks()) { done, total in
                        if cancelled() { throw CancellationError() }
                        progress(Double(done) / Double(total))
                    }
                    if strength == nil { blend = Float(measuredStrength(before: UnsafeBufferPointer(decoded), after: UnsafeBufferPointer(rgba)) / 100) }
                }
                used(Double(blend * 100).rounded())
                for p in stride(from: 0, to: rgba.count, by: 4) {
                    for c in 0..<3 {
                        let original = Float(decoded[p + c]), value = blend > 0 ? (original + blend * (rgba[p + c] - original)) * scale : original * scale
                        rgba[p + c] = value.isFinite ? value : 0
                    }
                    rgba[p + 3] = 1
                }
            }
        }
        return rgba
    }
}

/// A close look at Denoise on one photo, for the dialog: the photo at its Develop white balance and Exposure, small,
/// and a full-size crop before and after the network, as the DNG will have them.
public final class DenoisePreviewer: @unchecked Sendable {
    public let overview: CGImage
    /// Full-size width and height, as developed.
    public let size: CGSize
    private let developed: CIImage
    private let exposure: Double
    private let context = PhotoDenoiser.context()
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The tiles denoised so far, so moving the crop runs only new ones.
    private let tiles = NAFNetTileCache()

    public init(_ source: URL, development: DenoiseDevelopment) throws {
        let metadata = try PanoramaDecoder.metadata(source)
        developed = try PhotoDenoiser.developed(source, metadata: metadata, development: development)
        exposure = development.exposure
        size = developed.extent.size
        let scale = min(1, 720 / max(size.width, size.height))
        let small = Self.brightened(developed, exposure).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let overview = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: display) else {
            throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) can’t be decoded."))
        }
        self.overview = overview
    }

    /// The full-size pixels around `center` (fractions of the width and height from the top left), `size` across or
    /// as much of the photo as there is, before and after the network at full strength, as the DNG will have them. The
    /// tiles run from the middle out, and ones run before for this photo are reused; `progress` hears the crop as shot
    /// and then the result after each tile, where tiles still to run show the photo as shot. `cancelled` is asked
    /// between tiles.
    public func crop(center: CGPoint, size: CGSize, progress: (_ before: CGImage, _ after: CGImage) -> Void = { _, _ in },
                     cancelled: () -> Bool = { false }) throws -> (before: CGImage, after: CGImage) {
        let rect = region(center: center, size: size)
        let width = Int(self.size.width), height = Int(self.size.height)
        // On the tile grid as the DNG has it: rows counted down from the top, which is at -height.
        let xs = Int(rect.minX)..<Int(rect.maxX), ys = -Int(rect.maxY)..<(-Int(rect.minY))
        let reachX = NAFNetTiles.reach(xs).clamped(to: 0..<width), reachY = NAFNetTiles.reach(ys).clamped(to: -height..<0)
        // The photo is developed once for every tile the crop needs; past its edges the tiles repeat the edge pixels.
        var source = [Float](repeating: 0, count: reachX.count * reachY.count * 4)
        source.withUnsafeMutableBytes {
            context.render(Self.brightened(developed, exposure), toBitmap: $0.baseAddress!, rowBytes: reachX.count * 16,
                           bounds: CGRect(x: reachX.lowerBound, y: -reachY.upperBound, width: reachX.count, height: reachY.count),
                           format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        var sums = [Float](repeating: 0, count: xs.count * ys.count * 4), shown = sums
        let networks = try NAFNetTiles.networks()
        return try source.withUnsafeMutableBufferPointer { source in
            try sums.withUnsafeMutableBufferPointer { sums in
                try shown.withUnsafeMutableBufferPointer { shown in
                    let from = NAFNetTiles.Pixels(base: source.baseAddress!, rowLength: reachX.count * 4,
                                                  x: reachX.lowerBound, y: reachY.lowerBound, width: reachX.count, height: reachY.count)
                    let target = NAFNetTiles.Pixels(base: sums.baseAddress!, rowLength: xs.count * 4, x: xs.lowerBound, y: ys.lowerBound, width: xs.count, height: ys.count)
                    var output = target; output.base = shown.baseAddress!
                    // No tile done yet: the crop as shot.
                    NAFNetTiles.resolve(target, source: from, into: output)
                    let before = try image(output)
                    progress(before, before)
                    try NAFNetTiles.run(from, into: target, networks: networks, center: (xs.lowerBound + xs.count / 2, ys.lowerBound + ys.count / 2),
                                        cache: tiles) { done, total in
                        if cancelled() { throw CancellationError() }
                        if done < total { NAFNetTiles.resolve(target, source: from, into: output); progress(before, try image(output)) }
                    }
                    return (before, try image(target))
                }
            }
        }
    }
    /// Linear pixels in display sRGB.
    private func image(_ pixels: NAFNetTiles.Pixels<Float>) throws -> CGImage {
        let data = Data(bytes: pixels.base, count: pixels.rowLength * pixels.height * 4)
        let image = CIImage(bitmapData: data, bytesPerRow: pixels.rowLength * 4, size: CGSize(width: pixels.width, height: pixels.height),
                            format: .RGBAf, colorSpace: PanoramaDecoder.space)
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else {
            throw PanoramaError.message(L10n.tr("The preview couldn’t be rendered."))
        }
        return rendered
    }
    /// Where `crop` reads, in fractions of the width and height from the top left.
    public func frame(center: CGPoint, size: CGSize) -> CGRect {
        let rect = region(center: center, size: size)
        return CGRect(x: rect.minX / self.size.width, y: 1 - rect.maxY / self.size.height, width: rect.width / self.size.width, height: rect.height / self.size.height)
    }
    /// The crop in Core Image's coordinates, kept inside the photo.
    private func region(center: CGPoint, size: CGSize) -> CGRect {
        let width = min(max(1, size.width.rounded()), self.size.width), height = min(max(1, size.height.rounded()), self.size.height)
        let x = min(self.size.width - width, max(0, center.x * self.size.width - width / 2)).rounded()
        let y = min(self.size.height - height, max(0, (1 - center.y) * self.size.height - height / 2)).rounded()
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The developed linear values at the photo's Exposure, encoded for display without a tone curve.
    static func brightened(_ image: CIImage, _ exposure: Double) -> CIImage {
        let gain = PhotoDenoiser.gain(exposure)
        return gain == 0 ? image : image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gain])
    }
}
