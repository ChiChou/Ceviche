import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// What goes round the picture. Every style is drawn at the file's own size, so none softens when the file is large;
/// the film styles show the film's edge, not a maker's markings.
public enum BorderStyle: Int, CaseIterable, Sendable {
    case plain, keyline, film35, mediumFormat, instant, carrier

    public var title: String {
        switch self {
        case .plain: L10n.tr("Plain")
        case .keyline: L10n.tr("Keyline")
        case .film35: L10n.tr("35 mm")
        case .mediumFormat: L10n.tr("Medium Format")
        case .instant: L10n.tr("Instant")
        case .carrier: L10n.tr("Filed Carrier")
        }
    }
    /// The border on each side for a `width`, both as fractions of the picture's long side: 35 mm film has its
    /// perforations above and below, an instant print its deep foot.
    public func insets(width: Double) -> BorderInsets {
        switch self {
        case .plain, .keyline, .mediumFormat, .carrier: BorderInsets(top: width, left: width, bottom: width, right: width)
        case .film35: BorderInsets(top: width * 1.5, left: width * 0.45, bottom: width * 1.5, right: width * 0.45)
        case .instant: BorderInsets(top: width, left: width, bottom: width * 3.2, right: width)
        }
    }
}

/// A border's width on each side, as fractions of the picture's long side.
public struct BorderInsets: Equatable, Sendable {
    public var top = 0.0, left = 0.0, bottom = 0.0, right = 0.0
    public static let none = BorderInsets()

    /// The same border in points on a bordered picture shown at `size`.
    public func shown(in size: CGSize) -> (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        guard size.width > 0, size.height > 0, self != .none else { return (0, 0, 0, 0) }
        // The long side in points, taking the picture as wide; when that leaves it taller than wide it is upright.
        var long = size.width / (1 + left + right)
        if size.height - (top + bottom) * long > long { long = size.height / (1 + top + bottom) }
        return (top * long, left * long, bottom * long, right * long)
    }
}

/// Where the photo sits inside its border.
public enum BorderLayout: Equatable, Sendable {
    case none
    /// A drawn border: its width on each side.
    case margins(BorderInsets)
    /// A pictured border: the opening it leaves for a landscape photo, and whether it is turned for an upright one.
    case opening(CGRect, turns: Bool)

    /// The photo's place on a bordered picture shown at `size`, from its top left. `upright` says the photo is taller
    /// than wide: a pictured border is turned for one, and the bordered picture's shape alone doesn't tell.
    public func pictureRect(in size: CGSize, upright: Bool) -> CGRect {
        switch self {
        case .none: return CGRect(origin: .zero, size: size)
        case .margins(let insets):
            let shown = insets.shown(in: size)
            return CGRect(x: shown.left, y: shown.top, width: max(1, size.width - shown.left - shown.right), height: max(1, size.height - shown.top - shown.bottom))
        case .opening(let opening, let turns):
            let opening = upright && turns ? CGRect(x: opening.minY, y: 1 - opening.maxX, width: opening.height, height: opening.width) : opening
            return CGRect(x: opening.minX * size.width, y: opening.minY * size.height, width: opening.width * size.width, height: opening.height * size.height)
        }
    }
}

/// What the Border filter's Style picks: one drawn in code, or a picture of the real thing.
public enum BorderChoice: Equatable, Sendable {
    case drawn(BorderStyle), asset(BorderAsset)
    /// The style at a place in the picker: the drawn ones, then the pictured ones.
    public init(index: Int) {
        if let style = BorderStyle(rawValue: index) { self = .drawn(style) }
        else if BorderAsset.all.indices.contains(index - BorderStyle.allCases.count) { self = .asset(BorderAsset.all[index - BorderStyle.allCases.count]) }
        else { self = .drawn(.plain) }
    }
    public static var titles: [String] { BorderStyle.allCases.map(\.title) + BorderAsset.all.map(\.title) }
}

enum BorderRenderer {
    /// The photo behind a pictured border: the border is stretched until its opening is the photo's size, and turned
    /// first for an upright photo. Whatever the border leaves clear outside the photo is white paper.
    static func apply(_ image: CIImage, asset: BorderAsset) -> CIImage {
        let extent = image.extent
        guard var art = asset.image, extent.width >= 8, extent.height >= 8 else { return image }
        var opening = asset.opening
        if extent.height > extent.width, asset.turns {
            // A quarter turn counter-clockwise, back onto the origin.
            art = art.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).transformed(by: CGAffineTransform(translationX: art.extent.height, y: 0))
            opening = asset.uprightOpening
        }
        let width = (extent.width / opening.width).rounded(), height = (extent.height / opening.height).rounded()
        let frame = CGRect(x: extent.minX, y: extent.minY, width: width, height: height)
        let left = (opening.minX * width).rounded(), bottom = ((1 - opening.maxY) * height).rounded()
        let scaled = art.transformed(by: CGAffineTransform(translationX: -art.extent.minX, y: -art.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: width / art.extent.width, y: height / art.extent.height))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
        return scaled.composited(over: framed(image, by: CGPoint(x: left, y: bottom), over: CIImage(color: .white).cropped(to: frame))).cropped(to: frame)
    }

    /// The photo moved by `offset` and laid over `under`, which shows alone outside the photo's own rectangle. A plain
    /// composite let through what a filter's kernel made outside the photo (light with no coverage, which source-over
    /// adds rather than covers, or NaN), even cropped or drawn first: Fog lit the film above the photo.
    private static func framed(_ image: CIImage, by offset: CGPoint, over under: CIImage) -> CIImage {
        let placed = image.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        return framing.apply(extent: under.extent, arguments: [placed, under, CIVector(cgRect: placed.extent)]) ?? under
    }
    private static let framing = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 borderFrame(coreimage::sample_t photo, coreimage::sample_t under, float4 rect, coreimage::destination dest) {
            float2 c = dest.coord();
            bool inside = c.x >= rect.x && c.y >= rect.y && c.x < rect.x + rect.z && c.y < rect.y + rect.w;
            return inside ? photo + under * (1.0 - photo.a) : under;
        }
        """)[0] as! CIColorKernel

    /// The picture inside its border: the file grows by the border on every side.
    static func apply(_ image: CIImage, style: BorderStyle, width: Double, black: Bool) -> CIImage {
        let extent = image.extent, long = max(extent.width, extent.height)
        let insets = style.insets(width: width)
        let left = (long * insets.left).rounded(), right = (long * insets.right).rounded(), top = (long * insets.top).rounded(), bottom = (long * insets.bottom).rounded()
        guard left + right + top + bottom >= 1 else { return image }
        let frame = CGRect(x: extent.minX, y: extent.minY, width: extent.width + left + right, height: extent.height + top + bottom)
        let offset = CGPoint(x: left, y: bottom)
        // A plain mat needs no drawing.
        guard style != .plain, let art = art(style, size: frame.size, window: CGRect(x: left, y: bottom, width: extent.width, height: extent.height), unit: long * width, black: black) else {
            return framed(image, by: offset, over: CIImage(color: black ? .black : .white).cropped(to: frame))
        }
        return framed(image, by: offset, over: CIImage(cgImage: art).transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY)))
    }

    /// The border drawn round `window`, rows counted upward as Core Image has them. `unit` is the width asked for in
    /// pixels: every detail is sized from it.
    static func art(_ style: BorderStyle, size: CGSize, window: CGRect, unit: Double, black: Bool) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func grey(_ value: Double) -> CGColor { CGColor(srgbRed: value, green: value, blue: value, alpha: 1) }
        let paper = black ? grey(0) : grey(1), ink = black ? grey(0.92) : grey(0.02)
        // Film base, and what shows through its holes.
        let film = black ? grey(0.13) : grey(0.03), amber = CGColor(srgbRed: 1, green: 0.6, blue: 0.14, alpha: 0.9)
        let all = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        func fill(_ color: CGColor, _ rect: CGRect) { context.setFillColor(color); context.fill(rect) }
        func text(_ string: String, size: Double, at point: CGPoint) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): amber]))
            context.textPosition = point
            CTLineDraw(line, context)
        }
        switch style {
        case .plain: fill(paper, all)
        case .keyline:
            fill(paper, all)
            context.setStrokeColor(ink.copy(alpha: 0.85)!); context.setLineWidth(max(1, unit * 0.035))
            context.stroke(window.insetBy(dx: -unit * 0.28, dy: -unit * 0.28))
        case .film35:
            fill(film, all)
            // Perforations: 2.0 × 2.8 mm every 4.75 mm, in the proportions of the band they sit in.
            let band = window.minY, tall = band * 0.42, wide = tall * 0.71, pitch = wide * 2.4
            context.setFillColor(paper)
            for y in [band * 0.44 - tall / 2, size.height - band * 0.44 - tall / 2] {
                var x = pitch * 0.3
                while x < size.width {
                    context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: wide, height: tall), cornerWidth: wide * 0.2, cornerHeight: wide * 0.2, transform: nil))
                    x += pitch
                }
            }
            context.fillPath()
            // Frame numbers along the lower edge, as the film's own edge print has them.
            let letters = band * 0.17
            text("22", size: letters, at: CGPoint(x: window.minX + window.width * 0.12, y: band * 0.76))
            text("▸ 22A", size: letters, at: CGPoint(x: window.minX + window.width * 0.6, y: band * 0.76))
        case .mediumFormat:
            fill(film, all)
            let letters = unit * 0.3
            text("▸ 7", size: letters, at: CGPoint(x: window.minX + window.width * 0.08, y: window.maxY + unit * 0.38))
            text("7", size: letters, at: CGPoint(x: window.minX + window.width * 0.7, y: window.maxY + unit * 0.38))
            // The camera's notches in the frame edge, where light reaches the rebate.
            context.setFillColor(grey(0.93))
            for place in [0.68, 0.76] {
                let y = window.minY + window.height * place, reach = unit * 0.2
                context.move(to: CGPoint(x: window.minX, y: y - reach * 0.6)); context.addLine(to: CGPoint(x: window.minX - reach, y: y))
                context.addLine(to: CGPoint(x: window.minX, y: y + reach * 0.6)); context.closePath()
            }
            context.fillPath()
        case .instant:
            fill(black ? grey(0.05) : CGColor(srgbRed: 0.972, green: 0.966, blue: 0.95, alpha: 1), all)
        case .carrier:
            // A negative carrier filed out past the frame: the rebate prints as a rough black edge.
            fill(paper, all)
            let reach = unit * 0.32, rough = unit * 0.1, step = max(2, unit * 0.12)
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            let outer = window.insetBy(dx: -reach, dy: -reach)
            var points: [CGPoint] = [], wander = 0.0
            func walk(from a: CGPoint, to b: CGPoint, normal: CGPoint) {
                let length = hypot(b.x - a.x, b.y - a.y), count = max(1, Int(length / step))
                for i in 0..<count {
                    // A filed edge wanders slowly and chatters a little.
                    wander = wander * 0.82 + (random() - 0.5) * rough * 0.9
                    let offset = wander + (random() - 0.5) * rough * 0.35, t = Double(i) / Double(count)
                    points.append(CGPoint(x: a.x + (b.x - a.x) * t + normal.x * offset, y: a.y + (b.y - a.y) * t + normal.y * offset))
                }
            }
            walk(from: CGPoint(x: outer.minX, y: outer.minY), to: CGPoint(x: outer.maxX, y: outer.minY), normal: CGPoint(x: 0, y: -1))
            walk(from: CGPoint(x: outer.maxX, y: outer.minY), to: CGPoint(x: outer.maxX, y: outer.maxY), normal: CGPoint(x: 1, y: 0))
            walk(from: CGPoint(x: outer.maxX, y: outer.maxY), to: CGPoint(x: outer.minX, y: outer.maxY), normal: CGPoint(x: 0, y: 1))
            walk(from: CGPoint(x: outer.minX, y: outer.maxY), to: CGPoint(x: outer.minX, y: outer.minY), normal: CGPoint(x: -1, y: 0))
            context.setFillColor(ink); context.addLines(between: points); context.closePath(); context.fillPath()
        }
        return context.makeImage()
    }
}
