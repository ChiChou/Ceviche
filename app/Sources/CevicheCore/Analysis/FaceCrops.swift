import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Faces cut from the original for Check Faces, given where the culling measure found them
/// (`PhotoQualityReport.Face.bounds`). Only the face regions are rendered: Core Image reads the original lazily, so a
/// 42–60 MP RAW costs tens of MB here rather than the 0.5–2.8 GB of a whole decode.
public enum FaceCrops {
    /// A face for a grid tile: square, head and shoulders, scaled to `pixels` on a side. `nil` when it can't be read.
    public static func tiles(at url: URL, faces: [CGRect], pixels: Int) -> [CGImage?] {
        guard !faces.isEmpty, let size = originalSize(url) else { return faces.map { _ in nil } }
        let regions = faces.map { tileRegion(face: $0, imageSize: size) }
        // Decode no finer than the largest face needs: a RAW at a lower scale factor is far quicker.
        let needed = regions.map { Double(pixels) / max($0.width, 1) }.max() ?? 1
        guard let image = original(url, scale: min(1, needed * 1.05)) else { return faces.map { _ in nil } }
        return regions.map { render(image, region: $0, originalSize: size, longEdge: pixels) }
    }

    /// The photo quickly, for showing while the original renders: the camera's embedded preview when it is at least
    /// `longEdge / 2` on its long side, else a decode at `longEdge`. Upright.
    public static func preview(at url: URL, longEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(_ key: CFString) -> CGImage? {
            ImageDecode.thumbnail(source, 0, [key: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: longEdge] as CFDictionary)
        }
        if let embedded = make(kCGImageSourceCreateThumbnailFromImageIfAbsent), max(embedded.width, embedded.height) >= longEdge / 2 { return embedded }
        return make(kCGImageSourceCreateThumbnailFromImageAlways)
    }

    /// The whole original upright at full size, rendered through Core Image (a RAW through Apple's decoder), for
    /// zooming in to actual pixels. About 4 bytes a pixel: 170 MB for 42 MP.
    public static func whole(at url: URL) -> CGImage? {
        guard let image = original(url, scale: 1) else { return nil }
        let extent = image.extent
        // A context of its own, gone with the call: the shared one would keep the whole decode.
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                                     from: CGRect(origin: .zero, size: CGSize(width: floor(extent.width), height: floor(extent.height))),
                                     format: .RGBA8, colorSpace: displaySpace)
    }

    /// The original's upright size in pixels, without decoding it.
    public static func uprightSize(at url: URL) -> CGSize? { originalSize(url) }

    /// Square, about twice the face, around its middle, inside the image (top-left origin, original pixels).
    static func tileRegion(face: CGRect, imageSize: CGSize) -> CGRect {
        let width = face.width * imageSize.width, height = face.height * imageSize.height
        let side = min(max(width, height) * 2, imageSize.width, imageSize.height)
        let x = min(max(0, face.midX * imageSize.width - side / 2), imageSize.width - side)
        let y = min(max(0, face.midY * imageSize.height - side / 2), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// One context for every crop; intermediates are not kept, since each region is rendered once.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private static func isRAW(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? else { return false }
        return UTType(type)?.conforms(to: .rawImage) ?? false
    }

    /// The upright size the face bounds are proportions of.
    private static func originalSize(_ url: URL) -> CGSize? {
        guard let image = original(url, scale: 1), image.extent.width >= 1 else { return nil }
        return image.extent.size
    }

    /// The original upright, unrendered and scaled by `scale`: a RAW through Apple's decoder, anything else as Core Image
    /// reads it.
    private static func original(_ url: URL, scale: Double) -> CIImage? {
        let image: CIImage?
        if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
            if scale < 1 { raw.scaleFactor = Float(scale) }
            image = raw.outputImage
        } else {
            let read = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            image = scale < 1 ? read?.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1]) : read
        }
        guard let image, !image.extent.isInfinite, image.extent.width >= 1, image.extent.height >= 1 else { return nil }
        return image
    }

    /// `region` (top-left origin, in pixels of `originalSize`) from `image`, which may be the original scaled down,
    /// shrunk further to `longEdge` when given.
    private static func render(_ image: CIImage, region: CGRect, originalSize: CGSize, longEdge: Int?) -> CGImage? {
        guard region.width >= 1, region.height >= 1 else { return nil }
        let extent = image.extent, sx = extent.width / originalSize.width, sy = extent.height / originalSize.height
        // Core Image counts from the bottom left.
        let rect = CGRect(x: extent.minX + region.minX * sx, y: extent.maxY - region.maxY * sy, width: region.width * sx, height: region.height * sy)
            .integral.intersection(extent)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var cropped = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        if let longEdge, max(rect.width, rect.height) > Double(longEdge) {
            let scale = Double(longEdge) / max(rect.width, rect.height)
            cropped = cropped.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        }
        let out = CGRect(x: 0, y: 0, width: floor(cropped.extent.width), height: floor(cropped.extent.height))
        guard out.width >= 1, out.height >= 1 else { return nil }
        return context.createCGImage(cropped, from: out, format: .RGBA8, colorSpace: displaySpace)
    }
}

extension PhotoQualityReport.Face {
    /// Both eyes look closed at `sensitivity`, by the rule Find Flawed Photos uses (`closedEyes`), size aside.
    public func eyesClosed(_ sensitivity: CullingSensitivity) -> Bool { eyesClosed(below: sensitivity.closedEye) }
}
