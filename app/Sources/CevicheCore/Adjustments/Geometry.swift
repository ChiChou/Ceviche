import Foundation
import CoreImage

public struct CropRect: Codable, Equatable, Sendable {
    public var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let full = CropRect()
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.01 && height >= 0.01 && x + width <= 1.000001 && y + height <= 1.000001 }
}

public enum CropAspect: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case free = "Free", original = "Original", square = "1:1", fourFive = "4:5", threeTwo = "3:2", fourThree = "4:3", sixteenNine = "16:9", fiveSeven = "5:7"
    public func ratio(original: CGSize, portrait: Bool) -> Double? {
        let value: Double
        switch self {
        case .free: return nil
        case .original: value = original.width / max(1, original.height)
        case .square: value = 1; case .fourFive: value = 4.0 / 5; case .threeTwo: value = 3.0 / 2
        case .fourThree: value = 4.0 / 3; case .sixteenNine: value = 16.0 / 9; case .fiveSeven: value = 5.0 / 7
        }
        return portrait ? min(value, 1 / value) : max(value, 1 / value)
    }
}
public enum GuideAxis: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }
 case vertical = "Vertical", horizontal = "Horizontal" }
public struct UprightGuide: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var axis: GuideAxis
    public var start: MaskPoint
    public var end: MaskPoint
    public init(axis: GuideAxis, start: MaskPoint, end: MaskPoint) { self.axis = axis; self.start = start; self.end = end }
}
/// Upright's modes. Auto, Level, Vertical and Full come from an analysis of the photo's straight edges; Guided
/// solves the guides drawn on it.
public enum UprightMode: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case off = "Off", auto = "Auto", level = "Level", vertical = "Vertical", full = "Full", guided = "Guided"
    /// Modes whose correction comes from analysing the photo rather than from guides.
    public var isAnalyzed: Bool { self != .off && self != .guided }
}
/// The corrections Upright's analysis found for every analysed mode: forward homographies in 0–1 coordinates of
/// the untransformed photo (bottom-left origin, row major, nine values), the frame the guides live in. Kept with
/// the edit so switching modes, exporting and reopening need no new analysis.
public struct UprightAnalysis: Codable, Equatable, Sendable {
    public var auto: [Double]
    public var level: [Double]
    public var vertical: [Double]
    public var full: [Double]
    /// True when no vertical lines or horizon were found, so every correction is the identity.
    public var empty: Bool
    public init(auto: [Double], level: [Double], vertical: [Double], full: [Double], empty: Bool = false) {
        self.auto = auto; self.level = level; self.vertical = vertical; self.full = full; self.empty = empty
    }
    public static let identity = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
    public func correction(for mode: UprightMode) -> [Double] {
        switch mode {
        case .auto: return auto
        case .level: return level
        case .vertical: return vertical
        case .full: return full
        case .off, .guided: return Self.identity
        }
    }
    public func validate() throws {
        for m in [auto, level, vertical, full] {
            guard m.count == 9, m.allSatisfy(\.isFinite) else { throw EditorError.invalidDocument(L10n.tr("Invalid upright analysis.")) }
            _ = try ProjectiveMap(m: m).inverted()
        }
    }
}
public struct GeometryAdjustments: Codable, Equatable, Sendable {
    public var crop = CropRect.full
    public var aspect = CropAspect.free
    public var portrait = false
    public var straighten = 0.0
    public var flipHorizontal = false, flipVertical = false
    public var guides: [UprightGuide] = []
    public var uprightMode = UprightMode.off
    /// What Update analysed; nil until an analysed mode is chosen on this photo.
    public var uprightAnalysis: UprightAnalysis?
    public var uprightEnabled = true
    public var transform = ManualTransform()
    /// A work pulled square from its four corners. It takes Upright's place: the two are never applied together.
    public var perspective: PerspectiveCrop?
    /// Keeps the crop inside the corrected photo, so straightening and upright never show empty corners (on by
    /// default, as in other RAW editors).
    public var constrainCrop = true
    /// The wide-angle stretch undone across the whole photo, before Upright and the rest.
    public var volume = VolumeCorrection()
    public init() {}
    private enum CodingKeys: String, CodingKey { case crop, aspect, portrait, straighten, flipHorizontal, flipVertical, guides, uprightMode, uprightAnalysis, uprightEnabled, constrainCrop, transform, perspective, volume }
    /// A missing setting decodes with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop) ?? crop
        aspect = try c.decodeIfPresent(CropAspect.self, forKey: .aspect) ?? aspect
        portrait = try c.decodeIfPresent(Bool.self, forKey: .portrait) ?? portrait
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? straighten
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? flipHorizontal
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? flipVertical
        guides = try c.decodeIfPresent([UprightGuide].self, forKey: .guides) ?? guides
        uprightMode = try c.decodeIfPresent(UprightMode.self, forKey: .uprightMode) ?? uprightMode
        uprightAnalysis = try c.decodeIfPresent(UprightAnalysis.self, forKey: .uprightAnalysis)
        uprightEnabled = try c.decodeIfPresent(Bool.self, forKey: .uprightEnabled) ?? uprightEnabled
        constrainCrop = try c.decodeIfPresent(Bool.self, forKey: .constrainCrop) ?? constrainCrop
        transform = try c.decodeIfPresent(ManualTransform.self, forKey: .transform) ?? transform
        perspective = try c.decodeIfPresent(PerspectiveCrop.self, forKey: .perspective)
        volume = try c.decodeIfPresent(VolumeCorrection.self, forKey: .volume) ?? volume
    }
    /// Whether the chosen mode has a correction to apply (analysed, or guides to solve).
    public var uprightActive: Bool {
        guard uprightEnabled else { return false }
        switch uprightMode {
        case .off: return false
        case .guided: return !guides.isEmpty
        default: return uprightAnalysis != nil
        }
    }
    /// An analysed mode is chosen but the photo has not been analysed yet.
    public var needsUprightAnalysis: Bool { uprightMode.isAnalyzed && uprightAnalysis == nil }
    public func validate() throws {
        try transform.validate()
        try volume.validate()
        try uprightAnalysis?.validate()
        if let perspective, !perspective.isValid { throw EditorError.invalidDocument(L10n.tr("The four corners must form a quadrilateral that doesn’t fold over itself.")) }
        guard crop.valid, straighten.isFinite, (-45...45).contains(straighten), guides.count <= 4,
              Set(guides.map(\.id)).count == guides.count,
              guides.allSatisfy({ $0.start.isValid && $0.end.isValid && hypot($0.end.x - $0.start.x, $0.end.y - $0.start.y) >= 0.02 }) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid crop or upright guides."))
        }
    }
}

/// A projective transform shared by the renderer and canvas hit testing.
struct ProjectiveMap {
    var m: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    func point(_ p: CGPoint) -> CGPoint {
        let d = m[6] * p.x + m[7] * p.y + m[8]
        return CGPoint(x: (m[0] * p.x + m[1] * p.y + m[2]) / d, y: (m[3] * p.x + m[4] * p.y + m[5]) / d)
    }
    func followed(by b: ProjectiveMap) -> ProjectiveMap {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { out[r * 3 + c] += b.m[r * 3 + k] * m[k * 3 + c] } } }
        return ProjectiveMap(m: out)
    }
    func inverted() throws -> ProjectiveMap {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard det.isFinite, abs(det) > 1e-10 else { throw EditorError.invalidDocument(L10n.tr("Upright guides are degenerate.")) }
        return ProjectiveMap(m: [e * i - f * h, c * h - b * i, b * f - c * e, f * g - d * i, a * i - c * g, c * d - a * f, d * h - e * g, b * g - a * h, a * e - b * d].map { $0 / det })
    }
}

public struct GeometryPlan {
    public let sourceSize: CGSize
    public let uprightMessage: String?
    public let fullSize: CGSize
    public let cropPixels: CGRect
    public var outputSize: CGSize { cropPixels.size }
    /// The corrected photo's corners in full-frame pixels.
    public let imageCorners: [CGPoint]
    /// The corrected photo's outline in full-frame pixels, outside which the output is empty: its corners, or with
    /// Volume its curved edges as points.
    public let imageOutline: [CGPoint]
    /// Volume, worked out before everything else on the photo as shot.
    private let volume: VolumeProjection?
    private let transform: ProjectiveMap
    private let inverse: ProjectiveMap
    /// With a perspective crop: the work's corners in source pixels, and the map from the rectified work onward.
    private let rectified: (corners: [CGPoint], size: CGSize, onward: ProjectiveMap)?
    public init(size: CGSize, settings: GeometryAdjustments, quarterTurns: Int) throws {
        try settings.validate()
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite, (0...3).contains(quarterTurns) else { throw EditorError.render }
        sourceSize = size
        volume = VolumeProjection(settings.volume, size: size, turned: quarterTurns % 2 == 1)
        // A perspective crop rectifies first, and the rest of the plan works on the rectified work as its photo.
        let rectification = try settings.perspective?.rectification(source: size)
        let size = rectification?.size ?? size
        var upright = GuidedUpright.Solution()
        if settings.uprightEnabled, rectification == nil {
            switch settings.uprightMode {
            case .off: break
            case .guided: upright = try GuidedUpright.solve(settings.guides, size: size)
            default:
                if let analysis = settings.uprightAnalysis {
                    upright.map = ProjectiveMap(m: analysis.correction(for: settings.uprightMode))
                    if analysis.empty { upright.message = L10n.tr("No clear vertical or level edges were found; Upright leaves the photo as it is.") }
                } else { upright.message = L10n.tr("Analyzing the photo…") }
            }
        }
        uprightMessage = upright.message
        var map = upright.map
        let w = size.width, h = size.height
        map = ProjectiveMap(m: [1 / w, 0, 0, 0, 1 / h, 0, 0, 0, 1]).followed(by: map).followed(by: ProjectiveMap(m: [w, 0, 0, 0, h, 0, 0, 0, 1]))
        let radians = -settings.straighten * .pi / 180, c = cos(radians), s = sin(radians)
        map = map.followed(by: ProjectiveMap(m: [c, -s, 0, s, c, 0, 0, 0, 1]))
        // Exact quarter-turn matrices avoid rounding a 90° rotation to an extra pixel.
        let rotations: [[Double]] = [[1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 1, 0, -1, 0, 0, 0, 0, 1], [-1, 0, 0, 0, -1, 0, 0, 0, 1], [0, -1, 0, 1, 0, 0, 0, 0, 1]]
        map = map.followed(by: ProjectiveMap(m: rotations[quarterTurns]))
        map = map.followed(by: ProjectiveMap(m: [settings.flipHorizontal ? -1 : 1, 0, 0, 0, settings.flipVertical ? -1 : 1, 0, 0, 0, 1]))
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
        let denominators = corners.map { map.m[6] * $0.x + map.m[7] * $0.y + map.m[8] }
        guard denominators.allSatisfy({ $0 > 1e-6 }) || denominators.allSatisfy({ $0 < -1e-6 }) else { throw EditorError.invalidDocument(L10n.tr("Upright guides put the horizon inside the image.")) }
        let points = corners.map(map.point)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!, minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let width = ceil(maxX - minX - 1e-8), height = ceil(maxY - minY - 1e-8)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= w * 8 + h * 8, height <= w * 8 + h * 8, width * height <= w * h * 16 else { throw EditorError.invalidDocument(L10n.tr("Upright correction is too extreme.")) }
        fullSize = CGSize(width: width, height: height)
        // Keep the pre-manual canvas fixed: fitting the bounds again would undo scale and offsets.
        let corrected = map.followed(by: ProjectiveMap(m: [1, 0, -minX, 0, 1, -minY, 0, 0, 1]))
            .followed(by: settings.transform.map(size: fullSize))
        let depths = corners.map { corrected.m[6] * $0.x + corrected.m[7] * $0.y + corrected.m[8] }
        guard depths.allSatisfy({ $0 > 1e-6 }) || depths.allSatisfy({ $0 < -1e-6 }) else {
            throw EditorError.invalidDocument(L10n.tr("Transform is too extreme. Reduce Vertical, Horizontal or Rotate."))
        }
        imageCorners = corners.map(corrected.point)
        guard imageCorners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= width * 32 && abs($0.y) <= height * 32 }) else {
            throw EditorError.invalidDocument(L10n.tr("Transform is too extreme."))
        }
        transform = rectification.map { $0.map.followed(by: corrected) } ?? corrected
        imageOutline = volume.map { [transform] v in v.outline().map(transform.point) } ?? imageCorners
        rectified = rectification.map { ($0.corners, $0.size, corrected) }
        inverse = try transform.inverted()
        let x = round(settings.crop.x * width), y = round(settings.crop.y * height)
        cropPixels = CGRect(x: x, y: y, width: max(1, min(width - x, round(settings.crop.width * width))), height: max(1, min(height - y, round(settings.crop.height * height))))
    }
    public func displayPoint(_ source: MaskPoint) -> MaskPoint {
        var p = CGPoint(x: source.x * sourceSize.width, y: source.y * sourceSize.height)
        if let volume { p = volume.forward(p) }
        p = transform.point(p)
        return MaskPoint(x: (p.x - cropPixels.minX) / cropPixels.width, y: (p.y - cropPixels.minY) / cropPixels.height)
    }
    public func sourcePoint(_ display: MaskPoint) -> MaskPoint {
        var p = inverse.point(CGPoint(x: cropPixels.minX + display.x * cropPixels.width, y: cropPixels.minY + display.y * cropPixels.height))
        // Past the reprojected photo's edge there is no source point; the nearest answer is where it would be unprojected.
        if let volume { p = volume.inverse(p) ?? p }
        return MaskPoint(x: p.x / sourceSize.width, y: p.y / sourceSize.height)
    }
    public func apply(to input: CIImage) -> CIImage {
        var image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        // Volume works on the photo as shot, at the size it came: the rest then treats the reprojected photo as the photo.
        if let volume { image = volume.apply(to: image) }
        var map = transform, size = sourceSize
        if let rectified {
            // Pulled flat from its corners first: the photo's own corners may lie beyond the work's horizon, where one
            // perspective transform of the whole frame has no answer. The stretch to its proportions rides on the next warp.
            let c = rectified.corners.map { CIVector(cgPoint: $0) }
            image = image.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": c[0], "inputTopRight": c[1], "inputBottomRight": c[2], "inputBottomLeft": c[3]])
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            map = rectified.onward; size = rectified.size
        }
        func vector(_ x: Double, _ y: Double) -> CIVector { CIVector(cgPoint: map.point(CGPoint(x: x, y: y))) }
        let warped = image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputBottomLeft": vector(0, 0), "inputBottomRight": vector(size.width, 0),
            "inputTopLeft": vector(0, size.height), "inputTopRight": vector(size.width, size.height)])
        // CIImage.cropped(to:) intersects its extent; it cannot expand a scaled/offset image.
        // Supply a transparent canvas so preview, export and hit testing retain exactly the same frame.
        let canvas = CIImage(color: .clear).cropped(to: cropPixels)
        return warped.composited(over: canvas).cropped(to: cropPixels)
            .transformed(by: CGAffineTransform(translationX: -cropPixels.minX, y: -cropPixels.minY))
    }
}
