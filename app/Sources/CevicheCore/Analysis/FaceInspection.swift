import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Every face in a photo, cut from the full-resolution original, so focus and eyes are judged at actual pixels: a
/// downscaled face hides softness and an upscaled one invents it. Nothing is scored; the photographer judges.
public enum FaceInspection {
    public struct Face: Sendable {
        /// Normalized, top-left origin, in the upright photo.
        public var bounds: CGRect
        /// The face from the original, at most `maxCropSide` pixels on a side.
        public var crop: CGImage
    }

    /// Long edge the faces are found at. Vision misses faces in a 30 MP and larger frame handed over whole (one in nine
    /// of a group), and finds them all at this size.
    static let detectionSize = 2400
    /// Largest side of a crop, in original pixels. A larger face shows its eyes and the middle of the face at actual
    /// pixels rather than shrinking to fit.
    public static let maxCropSide = 420

    /// Finds the faces on the camera preview (or a detection-size decode) and renders only their crops from the
    /// original at actual pixels, left to right. Decoding a 42–60 MP RAW whole for a few 420 px crops took 0.5–2.8 GB
    /// and a second per photo; rendering the regions through Core Image takes tens of MB and a tenth of that.
    public static func faces(at url: URL) throws -> [Face] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        if let small = ImageDecode.analysisImage(source, url: url, pixelSize: detectionSize, minimum: PhotoQualityAnalyzer.previewMinimum),
           let faces = try? detect(small),
           let found = ImageDecode.onLargeStack({ crops(faces, url: url, source: source) }) {
            return found
        }
        // A TIFF or PNG, or a file Core Image can't read: decode the whole original, one at a time.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              let found = try ImageDecode.oneAtATime({ () throws -> [Face]? in
                  guard let image = ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else { return nil }
                  return try faces(in: image)
              })
        else { throw CocoaError(.fileReadCorruptFile) }
        return found
    }

    /// Each face's crop rendered from the original at actual pixels; nil when Core Image can't read the original. Only
    /// the regions are rendered: the RAW is demosaiced where the crops are, never as a whole frame.
    private static func crops(_ faces: [CGRect], url: URL, source: CGImageSource) -> [Face]? {
        guard let original = original(url, source: source) else { return nil }
        let size = original.extent.size
        return faces.compactMap { bounds in
            // Core Image counts from the bottom left; the crop rectangles from the top left.
            let rect = cropRect(face: bounds, imageSize: size, maxSide: maxCropSide)
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            let region = CGRect(x: original.extent.minX + rect.minX, y: original.extent.maxY - rect.maxY, width: rect.width, height: rect.height)
            return context.createCGImage(original, from: region, format: .RGBA8, colorSpace: displaySpace).map { Face(bounds: bounds, crop: $0) }
        }
    }

    /// One context for every crop; intermediates are not kept, since each photo is rendered once.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The original upright at full size, unrendered: a RAW through Apple's decoder, a JPEG or HEIF as Core Image reads
    /// it. Nil for other formats: Core Image took 5.9 GB for crops of a layered 16-bit TIFF that ImageIO decodes in 1.6.
    private static func original(_ url: URL, source: CGImageSource) -> CIImage? {
        guard let type = (CGImageSourceGetType(source) as String?).flatMap({ UTType($0) }) else { return nil }
        let image: CIImage?
        if type.conforms(to: .rawImage) { image = CIRAWFilter(imageURL: url)?.outputImage }
        else if type.conforms(to: .jpeg) || type.conforms(to: .heif) || type.conforms(to: .heic) { image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) }
        else { return nil }
        guard let image, !image.extent.isInfinite, image.extent.width >= 1, image.extent.height >= 1 else { return nil }
        return image
    }

    /// Faces in an upright image, normalized with a top-left origin, left to right.
    private static func detect(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: downscaled(image, longEdge: detectionSize)).perform([request])
        return (request.results ?? []).map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.midX < $1.midX }
    }

    /// The faces of an upright image, left to right, each crop copied out so the full image can be released.
    public static func faces(in image: CGImage) throws -> [Face] {
        let size = CGSize(width: image.width, height: image.height)
        return try detect(image).compactMap { bounds in
            copy(image, cropRect(face: bounds, imageSize: size, maxSide: maxCropSide)).map { Face(bounds: bounds, crop: $0) }
        }
    }

    /// The face with room for hair and chin, in pixels of `imageSize` (top-left origin), inside the image. A face too
    /// large for `maxSide` is cut to its eyes and middle: Vision's box puts the eyes about 40 % down.
    static func cropRect(face: CGRect, imageSize: CGSize, maxSide: Int) -> CGRect {
        let box = CGRect(x: face.minX * imageSize.width, y: face.minY * imageSize.height,
                         width: face.width * imageSize.width, height: face.height * imageSize.height)
        let full = max(box.width, box.height) * 1.35
        let side = min(full, Double(maxSide), imageSize.width, imageSize.height)
        let centre = CGPoint(x: box.midX, y: box.minY + box.height * (side < full ? 0.4 : 0.45))
        let x = min(max(0, centre.x - side / 2), imageSize.width - side), y = min(max(0, centre.y - side / 2), imageSize.height - side)
        // Rounded, not `integral`: growing outward to whole pixels would pass the side limit by one.
        return CGRect(x: x.rounded(), y: y.rounded(), width: side.rounded(), height: side.rounded()).intersection(CGRect(origin: .zero, size: imageSize))
    }

    private static func downscaled(_ image: CGImage, longEdge: Int) -> CGImage {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        guard scale < 1 else { return image }
        return draw(image, into: CGSize(width: (Double(image.width) * scale).rounded(), height: (Double(image.height) * scale).rounded()),
                    from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
    }

    /// `rect` (top-left origin) as an image of its own, not a view onto `image`'s pixels.
    private static func copy(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return draw(image, into: rect.size, from: rect)
    }

    private static func draw(_ image: CGImage, into size: CGSize, from rect: CGRect) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Drawing maps the whole image; place it so `rect` (top-left origin) fills the context (bottom-left origin).
        let scale = size.width / rect.width
        context.draw(image, in: CGRect(x: -rect.minX * scale, y: (rect.maxY - Double(image.height)) * scale,
                                       width: Double(image.width) * scale, height: Double(image.height) * scale))
        return context.makeImage()
    }
}
