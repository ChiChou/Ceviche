import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct HDRMergeFrameMetadata: Codable, Sendable {
    var filename: String
    var isRAW: Bool
    var make: String
    var model: String
    /// Oriented size of the full photo.
    var width: Int
    var height: Int
    var captureTime: String?
    /// log2(exposure time × ISO / f-number²), when the camera recorded all three.
    var recordedStops: Double?
    /// As-shot white balance of a RAW photo.
    var temperature: Double
    var tint: Double
    /// How far above white a processed photo with an HDR gain map reaches, read with it; nil for RAW and SDR photos.
    var headroom: Float? = nil

    var panorama: PanoramaFrameMetadata {
        PanoramaFrameMetadata(filename: filename, make: make, model: model, width: width, height: height, focalLength35mm: nil,
                              captureTime: captureTime, temperature: temperature, tint: tint)
    }
}

/// Develops each bracket into linear extended sRGB. RAW photos go through `PanoramaDecoder` with one shared white balance
/// and no tone response; JPEG, HEIC and TIFF photos are linearized through their embedded profile, with their HDR gain map
/// when they have one (`headroom`). Either way values are proportional to scene light up to the photo's clipping point,
/// which is what the merge needs.
enum HDRMergeDecoder {
    static func isRAW(_ url: URL) -> Bool { ToolResult.isRAW(url) }

    /// Without `hdr`, a processed photo is read without its gain map, as HDR Merge reads brackets.
    static func metadata(_ url: URL, hdr: Bool = true) throws -> HDRMergeFrameMetadata {
        if isRAW(url) {
            let base = try PanoramaDecoder.metadata(url)
            return HDRMergeFrameMetadata(filename: base.filename, isRAW: true, make: base.make, model: base.model,
                                         width: base.width, height: base.height, captureTime: base.captureTime,
                                         recordedStops: recordedStops(url), temperature: base.temperature, tint: base.tint)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) isn’t a photo this Mac can read."))
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        return HDRMergeFrameMetadata(filename: url.lastPathComponent, isRAW: false,
            make: (tiff[kCGImagePropertyTIFFMake as String] as? String ?? "").trimmingCharacters(in: .whitespaces),
            model: (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespaces),
            width: swapped ? height : width, height: swapped ? width : height,
            captureTime: exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            recordedStops: recordedStops(url), temperature: 5000, tint: 0,
            headroom: hdr ? CIImage(contentsOf: url, options: [.expandToHDR: true]).map { Float($0.contentHeadroom) }.flatMap { $0 > 1 ? $0 : nil } : nil)
    }

    private static func recordedStops(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let time = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, time > 0,
              let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue, aperture > 0 else { return nil }
        let iso = ((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue).flatMap { $0 > 0 ? $0 : nil } ?? 100
        return log2(time * iso / (aperture * aperture))
    }

    /// Develops the photo reduced to fit `longEdge` (nil for full size).
    static func decode(_ url: URL, metadata: HDRMergeFrameMetadata, longEdge: Int?, whiteBalance: (temperature: Double, tint: Double),
                       context: CIContext, retouch: [RetouchStroke] = []) throws -> PanoramaFrame {
        if metadata.isRAW { return try PanoramaDecoder.decode(url, longEdge: longEdge, whiteBalance: whiteBalance, context: context, retouch: retouch) }
        return try autoreleasepool {
            let image = try developedImage(url, metadata: metadata, longEdge: longEdge, whiteBalance: whiteBalance, retouch: retouch)
            let width = Int(image.extent.width.rounded(.down)), height = Int(image.extent.height.rounded(.down))
            guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) decoded empty.")) }
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                               format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            for i in pixels.indices where !pixels[i].isFinite { pixels[i] = 0 }
            return PanoramaFrame(width: width, height: height, pixels: pixels)
        }
    }

    /// The development `decode` renders, with its extent at the origin, for rendering on the GPU instead.
    static func developedImage(_ url: URL, metadata: HDRMergeFrameMetadata, longEdge: Int?, whiteBalance: (temperature: Double, tint: Double),
                               retouch: [RetouchStroke] = []) throws -> CIImage {
        if metadata.isRAW { return try PanoramaDecoder.developedImage(url, longEdge: longEdge, whiteBalance: whiteBalance, retouch: retouch) }
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: metadata.headroom != nil]) else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded."))
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let longEdge {
            let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return PanoramaDecoder.retouched(image, retouch)
    }
}
