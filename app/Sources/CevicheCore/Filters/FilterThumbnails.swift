import CoreGraphics
import CoreImage
import Foundation

/// Small pictures of what a filter's choices look like on their own, for a picker: a border round a grey card, a
/// texture's marks on black. None of them is the photo, so they are made once and cost nothing while it is edited.
public enum FilterThumbnails {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let image = lock.withLock({ made[key] }) { return image }
        guard let image = make() else { return nil }
        lock.withLock { made[key] = image }
        return image
    }
    private static func picture(_ image: CIImage, width: Double) -> CGImage? {
        let scale = width / max(1, image.extent.width)
        let small = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: CGRect(x: 0, y: 0, width: (small.extent.width).rounded(.down), height: (small.extent.height).rounded(.down)),
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The Border filter's style at `index` in its picker (`BorderChoice`), round a mid-grey card.
    public static func border(_ index: Int, width: Double = 240) -> CGImage? {
        cached("border-\(index)-\(Int(width))") {
            let card = CIImage(color: CIColor(red: 0.42, green: 0.43, blue: 0.45)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
            switch BorderChoice(index: index) {
            case .asset(let asset): return picture(BorderRenderer.apply(card, asset: asset), width: width)
            case .drawn(let style): return picture(BorderRenderer.apply(card, style: style, width: 0.07, black: false), width: width)
            }
        }
    }

    /// The Dust and Scratches texture at `index`: its marks, light on black, as they print on a negative.
    public static func texture(_ index: Int, width: Double = 240) -> CGImage? {
        cached("texture-\(index)-\(Int(width))") {
            guard FilmTexture.all.indices.contains(index), let marks = FilmTexture.all[index].image else { return nil }
            // The marks are faint at this size: lifted so they read.
            return picture(marks.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.6]), width: width)
        }
    }
}
