import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo Wide-Angle Faces reads: a RAW, developed as shot in linear light, or a rendered photo (HEIC, JPEG, …)
/// upright and in linear light, with an HDR gain map's highlights expanded.
struct WideAngleSource {
    let url: URL
    /// The 35 mm equivalent focal length from the EXIF; nil when it has none.
    let focalLength: Double?
    let isRAW: Bool
    private let raw: PanoramaFrameMetadata?
    /// The photo's own retouching, burnt in before the people are moved: the strokes would no longer fit them after.
    let retouch: [RetouchStroke]

    init(_ url: URL, retouch: [RetouchStroke] = []) throws {
        self.url = url
        self.retouch = retouch
        let type = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        isRAW = CatalogImporter.rawExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .rawImage) == true
        if isRAW {
            let metadata = try PanoramaDecoder.metadata(url)
            raw = metadata
            focalLength = metadata.focalLength35mm.flatMap { $0 > 0 ? $0 : nil }
        } else {
            raw = nil
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
            }
            focalLength = PanoramaDecoder.focalLength35mm(properties).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// A rendered photo at full size and upright, as stored (SDR), and with its gain map applied when it has one.
    func rendered() throws -> (sdr: CIImage, hdr: CIImage?) {
        guard let sdr = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let hdr = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
        }
        func atOrigin(_ i: CIImage) -> CIImage { PanoramaDecoder.retouched(i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY)), retouch) }
        return (atOrigin(sdr), hdr.contentHeadroom > 1 ? atOrigin(hdr) : nil)
    }

    /// The photo fitted to `longEdge` (nil for full size), extent at the origin.
    func developed(longEdge: Int?) throws -> CIImage {
        if let raw { return try PanoramaDecoder.developedImage(url, longEdge: longEdge, whiteBalance: (raw.temperature, raw.tint), retouch: retouch) }
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]) else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
        }
        image = PanoramaDecoder.retouched(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)), retouch)
        if let longEdge {
            let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale]) }
        }
        return image
    }
}

/// A photo developed for the Wide-Angle Faces dialog: as shot, at a working size, with its people found. Renders the
/// photo corrected for a set of people and settings, small enough to redraw while a slider moves.
public final class WideAnglePreviewer: @unchecked Sendable {
    /// The photo as shot, for Before.
    public let before: CGImage
    public let analysis: WideAngleAnalysis
    /// The 35 mm equivalent focal length from the EXIF; nil when it has none.
    public let focalLength: Double?
    private let developed: CIImage
    private let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private let exposure: Double

    /// `exposure` is the photo's Exposure, which the preview is shown at (RAW only: a rendered photo is shown as it is).
    public init(_ url: URL, exposure: Double, retouch: [RetouchStroke] = [], previewLongEdge: Int = 2400) throws {
        let source = try WideAngleSource(url, retouch: retouch)
        focalLength = source.focalLength
        let work = try source.developed(longEdge: WideAngleFaces.workLongEdge)
        analysis = try WideAngleFaces.analyze(work)
        let scale = min(1, Double(previewLongEdge) / max(work.extent.width, work.extent.height))
        developed = work.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        self.exposure = source.isRAW ? exposure : 0
        before = try Self.render(developed, exposure: self.exposure, context: context, space: display)
    }

    /// The photo corrected with `mesh`.
    public func corrected(_ mesh: WideAngleMesh) throws -> CGImage {
        try Self.render(try WideAngleFaces.warped(developed, mesh: mesh), exposure: exposure, context: context, space: display)
    }

    private static func render(_ image: CIImage, exposure: Double, context: CIContext, space: CGColorSpace) throws -> CGImage {
        let gain = PhotoDenoiser.gain(exposure)
        let shown = gain == 0 ? image : image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: gain])
        guard let image = context.createCGImage(shown, from: image.extent.integral, format: .RGBA8, colorSpace: space) else {
            throw PanoramaError.message(L10n.tr("The preview couldn’t be rendered."))
        }
        return image
    }
}

extension WideAngleFaces {
    /// The copy's file extension: a RAW becomes a DNG; a rendered photo is saved as `format` asks.
    public static func outputExtension(for source: URL, format: ProcessedFormat = .original) -> String {
        ToolResult.fileExtension(for: source, format: format)
    }

    /// Corrects `source` into `url`: the photo at full size, warped. A RAW is developed as shot and written as a linear
    /// DNG that keeps its EXIF; a rendered photo is written upright in its own format, with its HDR gain map and its
    /// EXIF and location. `people` are the dialog's (with any turned off or added); nil finds them anew. `focalLength`
    /// (35 mm equivalent) replaces the EXIF's.
    public static func correct(_ url: URL, to destination: URL, settings: WideAngleSettings, people: [WideAnglePerson]?, focalLength typed: Double? = nil, retouch: [RetouchStroke] = [],
                               progress: (Double, String) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        let source = try WideAngleSource(url, retouch: retouch)
        let focal = try focalLength(typed ?? source.focalLength)
        progress(0, L10n.tr("Finding people"))
        let analysis = try analyze(try source.developed(longEdge: workLongEdge))
        let chosen = people ?? analysis.people
        guard chosen.contains(where: \.enabled) else {
            throw PanoramaError.message(L10n.tr("No people to correct in \(url.lastPathComponent)."))
        }
        if cancelled() { throw CancellationError() }
        progress(0.2, L10n.tr("Developing \(url.lastPathComponent)"))
        let mesh = solve(analysis, people: chosen, focal: focal, settings: settings)
        guard source.isRAW else {
            // Both renditions of the photo move alike, so its gain map still fits.
            let (sdr, hdr) = try source.rendered()
            if cancelled() { throw CancellationError() }
            progress(0.5, L10n.tr("Saving \(destination.lastPathComponent)"))
            try ToolResult.writeRendered(try warped(sdr, mesh: mesh), hdr: try hdr.map { try warped($0, mesh: mesh) }, like: url, to: destination)
            return
        }
        let developed = try source.developed(longEdge: nil)
        let warped = try self.warped(developed, mesh: mesh)
        let width = Int(developed.extent.width.rounded(.down)), height = Int(developed.extent.height.rounded(.down))
        guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) decoded empty.")) }
        if cancelled() { throw CancellationError() }
        progress(0.4, L10n.tr("Correcting faces"))
        do {
            var rgba = [Float](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBytes {
                PhotoDenoiser.context().render(warped, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                               format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            for i in stride(from: 0, to: rgba.count, by: 4) {
                for c in 0..<3 where !rgba[i + c].isFinite { rgba[i + c] = 0 }
                rgba[i + 3] = 1
            }
            if cancelled() { throw CancellationError() }
            progress(0.7, L10n.tr("Writing DNG"))
            let writer = PanoramaDNGWriter(metadata: try PanoramaDecoder.metadata(url), source: DNGSourceMetadata(url, process: suffix))
            try writer.write(PanoramaRaster(width: width, height: height, rgba: rgba), to: destination,
                             progress: { progress(0.7 + 0.3 * $0, L10n.tr("Writing DNG")) }, cancelled: cancelled)
        }
    }
}
