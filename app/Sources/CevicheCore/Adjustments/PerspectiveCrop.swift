import CoreGraphics
import Foundation
import Vision

/// The proportions a perspective crop is rectified to: always the photographer's, never solved from the photo.
/// Recovering them from the corners and the focal length was off by up to 13 % at copy-stand geometry.
public enum PerspectiveProportion: Codable, Hashable, Sendable {
    /// As the four corners measure it: right only when the camera faced the work squarely.
    case asPhotographed
    /// ISO A and B paper, 1 : √2.
    case iso
    case letter, fourByFive, twoByThree, square
    /// Entered width and height, in any one unit.
    case custom(width: Double, height: Double)

    public static let presets: [PerspectiveProportion] = [.asPhotographed, .iso, .letter, .fourByFive, .twoByThree, .square]
    public var title: String {
        switch self {
        case .asPhotographed: L10n.tr("As Photographed")
        case .iso: L10n.tr("A-series")
        case .letter: L10n.tr("Letter")
        case .fourByFive: "4 : 5"
        case .twoByThree: "2 : 3"
        case .square: "1 : 1"
        case .custom: L10n.tr("Custom")
        }
    }
    public var isCustom: Bool { if case .custom = self { true } else { false } }
    /// Short side over long side; nil where the corners decide.
    var ratio: Double? {
        switch self {
        case .asPhotographed: nil
        case .iso: 1 / 2.0.squareRoot()
        case .letter: 8.5 / 11
        case .fourByFive: 4.0 / 5
        case .twoByThree: 2.0 / 3
        case .square: 1
        case .custom(let width, let height): width > 0 && height > 0 && width.isFinite && height.isFinite ? min(width, height) / max(width, height) : nil
        }
    }
}

/// Perspective crop: a work photographed at an angle (an artwork, a document, a screen), pulled square from its four
/// corners. Part of the edit, in place of Upright: the rectified work becomes the canvas the crop frame sits on.
///
/// A detected rectangle is only a start (0.2–0.9° of shear when it is the right one, and the wrong object in 4 of 11
/// photos), so the corners are the photographer's to place.
public struct PerspectiveCrop: Codable, Equatable, Sendable {
    /// The four corners in source coordinates, like Upright's guides. Any order: they are sorted when solved.
    public var corners: [MaskPoint]
    public var proportion = PerspectiveProportion.asPhotographed

    public static let inset = [MaskPoint(x: 0.1, y: 0.9), MaskPoint(x: 0.9, y: 0.9), MaskPoint(x: 0.9, y: 0.1), MaskPoint(x: 0.1, y: 0.1)]
    public init(corners: [MaskPoint] = PerspectiveCrop.inset, proportion: PerspectiveProportion = .asPhotographed) {
        self.corners = corners; self.proportion = proportion
    }

    /// Top left, top right, bottom right, bottom left as seen (y up), whatever order they come in: around the
    /// centre, starting at the corner nearest the frame's top left.
    static func ordered(_ points: [CGPoint], height: Double) -> [CGPoint] {
        let centre = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        // Clockwise as seen is descending angle with y up.
        let around = points.sorted { atan2($0.y - centre.y, $0.x - centre.x) > atan2($1.y - centre.y, $1.x - centre.x) }
        let first = around.indices.min { around[$0].x + height - around[$0].y < around[$1].x + height - around[$1].y } ?? 0
        return (0..<4).map { around[(first + $0) % 4] }
    }
    static func area(_ p: [CGPoint]) -> Double {
        var sum = 0.0
        for i in 0..<4 { let a = p[i], b = p[(i + 1) % 4]; sum += Double(a.x * b.y - b.x * a.y) }
        return abs(sum) / 2
    }
    /// Four points in the photo at the corners of a convex quadrilateral of some size: what can be rectified.
    public var isValid: Bool {
        guard corners.count == 4, corners.allSatisfy(\.isValid) else { return false }
        let p = Self.ordered(corners.map { CGPoint(x: $0.x, y: $0.y) }, height: 1)
        var sign = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = Double((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
            if abs(cross) < 1e-6 { return false }
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return Self.area(p) > 0.002
    }

    /// The rectified work's size in pixels on a photo of `source`: as large as the longest edges, so nothing is
    /// thrown away, then stretched to the proportions along the shorter side.
    public func outputSize(source: CGSize) -> CGSize {
        Self.outputSize(Self.ordered(corners.map { CGPoint(x: $0.x * source.width, y: $0.y * source.height) }, height: source.height), proportion: proportion)
    }
    static func outputSize(_ p: [CGPoint], proportion: PerspectiveProportion) -> CGSize {
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        var across = max(length(p[0], p[1]), length(p[3], p[2])), down = max(length(p[1], p[2]), length(p[0], p[3]))
        if let ratio = proportion.ratio {
            // The work lies as it was photographed: wider than tall, or taller than wide.
            let wanted = across >= down ? 1 / ratio : ratio
            if across / down < wanted { across = down * wanted } else { down = across / wanted }
        }
        return CGSize(width: max(1, across.rounded()), height: max(1, down.rounded()))
    }

    struct Rectification {
        /// Top left, top right, bottom right, bottom left in source pixels, y up.
        let corners: [CGPoint]
        let size: CGSize
        /// Source pixels to the rectified work's pixels.
        let map: ProjectiveMap
    }
    func rectification(source: CGSize) throws -> Rectification {
        guard isValid else { throw EditorError.invalidDocument(L10n.tr("The four corners must form a quadrilateral that doesn’t fold over itself.")) }
        let p = Self.ordered(corners.map { CGPoint(x: $0.x * source.width, y: $0.y * source.height) }, height: source.height)
        let size = Self.outputSize(p, proportion: proportion)
        // Unit square (bottom left, bottom right, top right, top left) to the quadrilateral, inverted, then to the rectangle.
        let (p0, p1, p2, p3) = (p[3], p[2], p[1], p[0])
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, sx = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, sy = p0.y - p1.y + p2.y - p3.y
        let den = dx1 * dy2 - dx2 * dy1
        guard abs(den) > 1e-9 else { throw EditorError.invalidDocument(L10n.tr("The four corners must form a quadrilateral that doesn’t fold over itself.")) }
        let g = (sx * dy2 - dx2 * sy) / den, h = (dx1 * sy - sx * dy1) / den
        let square = ProjectiveMap(m: [p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x,
                                       p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y, g, h, 1])
        let map = try square.inverted().followed(by: ProjectiveMap(m: [size.width, 0, 0, 0, size.height, 0, 0, 0, 1]))
        return Rectification(corners: p, size: size, map: map)
    }

    /// Where to start: the largest rectangle Vision sees that fills a fair part of `image`, else its document
    /// outline, in fractions of the image from its bottom left. Nil when there is neither.
    public static func detect(in image: CGImage) -> [MaskPoint]? {
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 12; rectangles.minimumAspectRatio = 0.2; rectangles.minimumSize = 0.05
        rectangles.quadratureTolerance = 40; rectangles.minimumConfidence = 0.3
        let document = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([rectangles, document])
        func points(_ r: VNRectangleObservation) -> [CGPoint] { ordered([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft], height: 1) }
        let candidates = (rectangles.results ?? []).map(points).filter { area($0) >= 0.08 }.sorted { area($0) > area($1) }
        let found = candidates.first ?? document.results?.first.map(points).flatMap { area($0) >= 0.08 ? $0 : nil }
        return found?.map { MaskPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
    }
}
