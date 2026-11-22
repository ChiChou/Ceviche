import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// What a tool saves when its photos are processed ones (HEIC, JPEG, TIFF, PNG, …). Their result is never a DNG: a
/// linear DNG takes Apple's DNG tone response on top of the tone the camera already gave the photo, and is many times
/// the size. Original keeps the photo's own format (rarer ones such as AVIF or WebP become HEIC); TIFF is 16-bit, or
/// half-float when the result is brighter than white. A RAW photo's result is always a DNG.
public enum ProcessedFormat: String, Codable, CaseIterable, Sendable {
    case original, tiff
}

/// The kind of file a tool's result is, decided by the photo it is based on.
public enum ToolResult {
    /// Whether `url` is a RAW photo, by its extension or else its contents.
    public static func isRAW(_ url: URL) -> Bool {
        if CatalogImporter.rawExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return false }
        return UTType(type as String)?.conforms(to: .rawImage) == true
    }

    /// The result's file extension: DNG for a RAW; for a processed photo, as `format` asks.
    public static func fileExtension(for source: URL, format: ProcessedFormat = .original) -> String {
        if isRAW(source) { return "dng" }
        let ext = source.pathExtension.lowercased()
        switch format {
        case .original: return keptExtensions.contains(ext) ? ext : "heic"
        case .tiff: return "tif"
        }
    }
    /// Processed formats Original saves as they came.
    static let keptExtensions: Set<String> = ["heic", "heif", "hif", "jpg", "jpeg", "png", "tif", "tiff"]

    private static let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// Writes `sdr` like the photo at `source`: in the format `url`'s extension names, in the photo's color space, upright,
    /// with its metadata. With `hdr`, HEIC and JPEG get a gain map derived from it, which keeps the highlights'
    /// brightness (ImageIO's gain-map encode from a float image clipped the brightest 0.4 stop), and TIFF is written as
    /// half floats in the extended color space with `hdr`'s values. `dropsExposure` leaves out the shutter speed and
    /// exposure bias, for a merge of several exposures.
    public static func writeRendered(_ sdr: CIImage, hdr: CIImage?, like source: URL, to url: URL, dropsExposure: Bool = false) throws {
        guard let original = CGImageSourceCreateWithURL(source as CFURL, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any] else {
            throw PanoramaError.message(L10n.tr("\(source.lastPathComponent) can’t be decoded."))
        }
        let space = CGImageSourceCreateImageAtIndex(original, 0, nil)?.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let depth = (properties[kCGImagePropertyDepth as String] as? Int) ?? 8
        let rect = sdr.extent.integral
        // Upright now, at its own size.
        properties[kCGImagePropertyOrientation as String] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = Int(rect.width)
            exif[kCGImagePropertyExifPixelYDimension as String] = Int(rect.height)
            exif.removeValue(forKey: kCGImagePropertyExifSubjectArea as String)
            if dropsExposure {
                exif.removeValue(forKey: kCGImagePropertyExifExposureTime as String)
                exif.removeValue(forKey: kCGImagePropertyExifExposureBiasValue as String)
            }
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            properties.removeValue(forKey: key as String)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "tif" || ext == "tiff" {
            // Deflate: about two thirds of LZW's size for 16-bit photos (50 against 79 MB for 12 megapixels).
            tiff[kCGImagePropertyTIFFCompression as String] = 8
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
            let picture = (hdr ?? sdr).cropped(to: rect)
            let output = hdr == nil ? space : (CGColorSpaceCreateExtended(space) ?? PanoramaDecoder.space)
            // The same samples with the alpha marked as padding, so the file holds three channels.
            guard let rendered = context.createCGImage(picture, from: rect, format: hdr == nil ? .RGBA16 : .RGBAh, colorSpace: output),
                  let provider = rendered.dataProvider,
                  let image = CGImage(width: rendered.width, height: rendered.height, bitsPerComponent: rendered.bitsPerComponent, bitsPerPixel: rendered.bitsPerPixel,
                                      bytesPerRow: rendered.bytesPerRow, space: output,
                                      bitmapInfo: CGBitmapInfo(rawValue: (rendered.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
                throw PanoramaError.message(L10n.tr("Can’t write \(url.lastPathComponent)."))
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PanoramaError.message(L10n.tr("Can’t write \(url.lastPathComponent).")) }
            return
        }
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        let image = sdr.cropped(to: rect).settingProperties(properties)
        var options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
        if let hdr { options[.hdrImage] = hdr.cropped(to: rect) }
        let data: Data?
        switch ext {
        case "heic", "heif", "hif": data = context.heifRepresentation(of: image, format: depth > 8 ? .RGBA16 : .RGBA8, colorSpace: space, options: options)
        case "jpg", "jpeg": data = context.jpegRepresentation(of: image, colorSpace: space, options: options)
        case "png": data = context.pngRepresentation(of: image, format: depth > 8 ? .RGBA16 : .RGBA8, colorSpace: space, options: [:])
        default: data = nil
        }
        guard let data else { throw PanoramaError.message(L10n.tr("The installed system cannot encode \(url.pathExtension.uppercased()).")) }
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// Writes a linear result (extended linear sRGB, rows top down) like the photo at `source`; alpha is dropped. A
    /// result brighter than white is HDR (see `writeRendered`), its SDR rendition tone mapped down to white. Brightness
    /// is luminance: a channel above 1 alone is a color outside sRGB, such as a Display P3 photo's, not a highlight.
    static func writeRendered(_ raster: PanoramaRaster, like source: URL, to url: URL, dropsExposure: Bool = false) throws {
        var rgba = raster.rgba, brightest: Float = 0
        for p in stride(from: 0, to: rgba.count, by: 4) {
            for c in 0..<3 { let v = rgba[p + c]; rgba[p + c] = v.isFinite ? max(0, v) : 0 }
            if rgba[p + 3] > 0 { brightest = max(brightest, 0.2126 * rgba[p] + 0.7152 * rgba[p + 1] + 0.0722 * rgba[p + 2]) }
            rgba[p + 3] = 1
        }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: raster.width * 16,
                            size: CGSize(width: raster.width, height: raster.height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        // A photo's SDR rendition decoded from Display P3 can reach a hair above white.
        let hdr = brightest > 1.05
        try writeRendered(hdr ? HDRRenderer.toneMap(image, source: brightest, target: 1) : image, hdr: hdr ? image : nil,
                          like: source, to: url, dropsExposure: dropsExposure)
    }
}

/// Writes a tool's linear result as the file its photos call for: a DNG for RAW photos; for processed ones, the photo's
/// own format or a TIFF, encoded back through the photo's color space so it looks as the photos did and takes their
/// edits as they are.
struct ToolResultWriter {
    var dng: PanoramaDNGWriter
    /// The photo the result is based on: its format, color space and metadata for a processed result.
    let source: URL
    /// Leaves the photo's shutter speed and exposure bias out of a processed result, as for a merge of exposures.
    var dropsExposure = false
    /// The extension the file is written as: by `url`'s own when writing, or this for a preview's file.
    var previewExtension: String { ToolResult.isRAW(source) ? "dng" : "tif" }

    /// Writes `raster` as `url`'s extension names it.
    func write(_ raster: PanoramaRaster, to url: URL, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws {
        guard url.pathExtension.lowercased() != "dng" else { return try dng.write(raster, to: url, progress: progress, cancelled: cancelled) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if cancelled() { throw CancellationError() }
        try ToolResult.writeRendered(raster, like: source, to: url, dropsExposure: dropsExposure)
        progress(1)
    }
}
