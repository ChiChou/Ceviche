import SwiftUI
import CoreGraphics

/// How the canvas shows a very large picture, such as a merge previewed at full size: a reduced copy while it is
/// fitted, and, zoomed in, only the part in view at the resolution the screen needs. The whole picture as one layer
/// is tens of megapixels to upload and to scale on every frame of a zoom or a pan; what is off screen is never drawn.
enum ZoomDetail {
    /// Pictures above this many pixels are shown this way.
    static let large = 16_000_000
    /// The long edge of the reduced copy.
    static let reducedEdge = 2400
    /// The most pixels one piece holds.
    static let limit = 16_000_000

    /// A part of the picture ready to draw over the reduced copy.
    struct Piece: @unchecked Sendable {
        let source: CGImage
        /// Where it lies in the picture as shown, in fractions of its width and height from the top left.
        let region: CGRect
        let image: CGImage
        /// Its pixels per pixel of the source: 1 at full resolution.
        let density: CGFloat
    }

    static func isLarge(_ image: CGImage) -> Bool { image.width * image.height > large }

    /// A rectangle of the stored picture, in fractions from its top left, as it lies in the picture shown turned by
    /// `orientation`; nil for the mirrored orientations, which are drawn whole.
    static func shown(_ r: CGRect, _ orientation: Image.Orientation) -> CGRect? {
        switch orientation {
        case .up: r
        case .down: CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        // Turned a quarter clockwise to show: the stored top left is the shown top right.
        case .right: CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case .left: CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        default: nil
        }
    }
    /// The inverse: a rectangle of the shown picture in the stored one.
    static func stored(_ r: CGRect, _ orientation: Image.Orientation) -> CGRect? {
        switch orientation {
        case .up: r
        case .down: CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        case .right: CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case .left: CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        default: nil
        }
    }

    /// `image` drawn into `width` × `height` pixels, averaging down.
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let deep = image.bitsPerComponent > 8
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)))
        return context.makeImage()
    }

    /// The copy shown while the picture is fitted.
    static func reduced(_ image: CGImage) -> CGImage? {
        let scale = Double(reducedEdge) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        return scaled(image, width: Int((Double(image.width) * scale).rounded()), height: Int((Double(image.height) * scale).rounded()))
    }

    /// The part of `image` covering `visible` (of the shown picture, in fractions) and a margin around it, so a small
    /// pan needs no new piece, at `density` pixels per source pixel or as near as `limit` allows.
    static func piece(of image: CGImage, orientation: Image.Orientation, visible: CGRect, density: CGFloat) -> Piece? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let wanted = visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25).intersection(unit)
        guard !wanted.isEmpty, let part = stored(wanted, orientation) else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let pixels = CGRect(x: part.minX * width, y: part.minY * height, width: part.width * width, height: part.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixels.width >= 1, pixels.height >= 1, let crop = image.cropping(to: pixels),
              let region = shown(CGRect(x: pixels.minX / width, y: pixels.minY / height, width: pixels.width / width, height: pixels.height / height), orientation) else { return nil }
        var density = min(1, max(0.01, density))
        let count = pixels.width * pixels.height
        // At full resolution, and within the limit, the crop is drawn as it is: it shares the picture's pixels.
        if density >= 0.9, count <= CGFloat(limit) { return Piece(source: image, region: region, image: crop, density: 1) }
        if count * density * density > CGFloat(limit) { density = (CGFloat(limit) / count).squareRoot() }
        guard let drawn = scaled(crop, width: Int((pixels.width * density).rounded()), height: Int((pixels.height * density).rounded())) else { return nil }
        return Piece(source: image, region: region, image: drawn, density: density)
    }
}
