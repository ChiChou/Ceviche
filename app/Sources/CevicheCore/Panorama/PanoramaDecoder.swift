import Foundation
import CoreImage
import ImageIO

/// A RAW photo developed by Apple's decoder into linear extended sRGB for merging: demosaiced, lens corrected
/// (distortion, vignetting and chromatic aberration where the camera is supported), highlights recovered, white
/// balance shared by every photo, and no tone response, so the merged DNG gets Apple's tone response once when it is
/// developed. Values above 1 keep recovered highlights.
final class PanoramaFrame {
    let width: Int
    let height: Int
    /// width × height RGBA Float32, top row first.
    let pixels: [Float]
    init(width: Int, height: Int, pixels: [Float]) { self.width = width; self.height = height; self.pixels = pixels }
}

struct PanoramaFrameMetadata: Sendable {
    var filename: String
    var make: String
    var model: String
    /// Oriented size of the full photo.
    var width: Int
    var height: Int
    var focalLength35mm: Double?
    /// Whether the decoder corrects the lens's distortion; when it doesn't, the alignment fits it.
    var lensCorrected = true
    /// EXIF `yyyy:MM:dd HH:mm:ss`, as the camera recorded it.
    var captureTime: String?
    var temperature: Double
    var tint: Double

    /// One second after the latest of `times`, so a merge sorts right after the photos it was made from instead of tying
    /// with the last of them (or landing among them, dated like its reference photo).
    static func captureTime(after times: [String?]) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // Only the first 19 characters: some cameras append fractions or a zone the format doesn't cover.
        guard let last = times.compactMap({ $0.flatMap { formatter.date(from: String($0.prefix(19))) } }).max() else { return nil }
        return formatter.string(from: last.addingTimeInterval(1))
    }
}

enum PanoramaDecoder {
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func metadata(_ url: URL) throws -> PanoramaFrameMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = CIRAWFilter(imageURL: url), raw.nativeSize.width > 0 else {
            throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) isn’t a RAW photo this device can read."))
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let size = RawRenderer.orientedRAWSize(raw)
        let focal = focalLength35mm(properties)
        return PanoramaFrameMetadata(filename: url.lastPathComponent,
            make: (tiff[kCGImagePropertyTIFFMake as String] as? String ?? "").trimmingCharacters(in: .whitespaces),
            model: (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").trimmingCharacters(in: .whitespaces),
            width: Int(size.width), height: Int(size.height), focalLength35mm: focal, lensCorrected: raw.isLensCorrectionSupported,
            captureTime: exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
    }

    /// The 35 mm equivalent focal length: as recorded, or from the focal length and the sensor size the focal plane
    /// resolution implies. Canon bodies record no equivalent, and a panorama solved from a guessed 50 mm can't reach 24 mm.
    static func focalLength35mm(_ properties: [String: Any]) -> Double? {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func number(_ dictionary: [String: Any], _ key: CFString) -> Double? { (dictionary[key as String] as? NSNumber)?.doubleValue }
        if let recorded = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm), recorded > 0 { return recorded }
        guard let focal = number(exif, kCGImagePropertyExifFocalLength), focal > 0,
              let across = number(exif, kCGImagePropertyExifFocalPlaneXResolution), across > 0,
              let down = number(exif, kCGImagePropertyExifFocalPlaneYResolution), down > 0,
              let width = number(properties, kCGImagePropertyPixelWidth), let height = number(properties, kCGImagePropertyPixelHeight) else { return nil }
        let unit = number(exif, kCGImagePropertyExifFocalPlaneResolutionUnit).map(Int.init) ?? 2
        let millimetres = unit == 3 ? 10.0 : unit == 4 ? 1.0 : 25.4
        let diagonal = hypot(width / across * millimetres, height / down * millimetres)
        guard diagonal > 3, diagonal < 80 else { return nil }
        return focal * hypot(36, 24) / diagonal
    }

    /// Develops the photo reduced to fit `longEdge` (nil for full size) with the given white balance.
    static func decode(_ url: URL, longEdge: Int?, whiteBalance: (temperature: Double, tint: Double), context: CIContext,
                       retouch: [RetouchStroke] = []) throws -> PanoramaFrame {
        try autoreleasepool {
            let image = try developedImage(url, longEdge: longEdge, whiteBalance: whiteBalance, retouch: retouch)
            let width = Int(image.extent.width.rounded(.down)), height = Int(image.extent.height.rounded(.down))
            guard width > 0, height > 0 else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) decoded empty.")) }
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                               format: .RGBAf, colorSpace: space)
            }
            // Non-finite samples would poison the blend; out-of-gamut negatives are kept.
            for i in pixels.indices where !pixels[i].isFinite { pixels[i] = 0 }
            return PanoramaFrame(width: width, height: height, pixels: pixels)
        }
    }

    /// The development `decode` renders, with its extent at the origin, for callers that render it elsewhere.
    /// `noiseReduction` false turns the decoder's own noise reduction off, for Denoise, which does its own.
    /// `retouch` is the photo's own retouching, dust spots above all: sensor dust is in each photo's own place, so a merge
    /// takes it out of every photo before they are aligned rather than out of the result.
    static func developedImage(_ url: URL, longEdge: Int?, whiteBalance: (temperature: Double, tint: Double), noiseReduction: Bool = true,
                               retouch: [RetouchStroke] = []) throws -> CIImage {
        guard let raw = CIRAWFilter(imageURL: url) else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded.")) }
        let native = max(raw.nativeSize.width, raw.nativeSize.height)
        if let longEdge { raw.scaleFactor = Float(min(1, Double(longEdge) / native)) }
        raw.neutralTemperature = Float(whiteBalance.temperature)
        raw.neutralTint = Float(whiteBalance.tint)
        raw.exposure = 0
        raw.boostAmount = 0
        raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
        if !noiseReduction {
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        }
        guard var image = raw.outputImage else { throw PanoramaError.message(L10n.tr("\(url.lastPathComponent) can’t be decoded.")) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let longEdge {
            let scale = min(1, Double(longEdge) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        return retouched(image, retouch)
    }

    /// `frame` with a photo's retouching drawn in, for a merge that aligns on the photo untouched and shows it retouched.
    static func retouched(_ frame: PanoramaFrame, _ strokes: [RetouchStroke]) -> PanoramaFrame {
        guard strokes.contains(where: \.enabled) else { return frame }
        let rowBytes = frame.width * 16, bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let image = CIImage(bitmapData: frame.pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: rowBytes, size: bounds.size,
                            format: .RGBAf, colorSpace: space)
        var pixels = [Float](repeating: 0, count: frame.pixels.count)
        pixels.withUnsafeMutableBytes {
            retouchContext.render(retouched(image, strokes), toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        for i in pixels.indices where !pixels[i].isFinite { pixels[i] = 0 }
        return PanoramaFrame(width: frame.width, height: frame.height, pixels: pixels)
    }

    /// Fresh each time: a shared context would keep every full-size photo retouched through it.
    private static var retouchContext: CIContext { CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false]) }
    /// `image` with a photo's retouching drawn in, AI fills included: a fill is stored relative to its surroundings, so it
    /// relights to this undeveloped decode as it does to a changed exposure. Only the strokes' footprints change, so those are rendered once here and laid over the photo as plain pixels:
    /// whatever renders the photo next, on the CPU or into a texture, sees the same repair.
    static func retouched(_ image: CIImage, _ strokes: [RetouchStroke]) -> CIImage {
        let strokes = strokes.filter(\.enabled)
        guard !strokes.isEmpty else { return image }
        let context = retouchContext
        guard let repaired = try? RetouchRenderer(context: context).apply(strokes, to: image) else { return image }
        var out = image
        for stroke in strokes {
            let area = RetouchRenderer.bounds(of: stroke, in: image.extent)
            let width = Int(area.width), height = Int(area.height)
            guard width > 0, height > 0 else { continue }
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                context.render(repaired, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: area, format: .RGBAf, colorSpace: space)
            }
            let patch = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                                format: .RGBAf, colorSpace: space)
            out = patch.transformed(by: CGAffineTransform(translationX: area.minX, y: area.minY)).composited(over: out)
        }
        return out
    }
}
