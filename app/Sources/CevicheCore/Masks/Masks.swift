import Foundation
import CoreImage

public enum MaskKind: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case subject = "Subject", background = "Background", sky = "Sky", object = "Object"
    case brush = "Brush", linear = "Linear gradient", radial = "Radial gradient", color = "Color range"
    case depth = "Depth", scene = "Scene", people = "People"
}

/// What of one person a People mask covers: the whole person (Vision's person mask), skin, hair and clothes from the
/// people-parts model's classes cut to that person, or the features of their face drawn from Vision's landmarks.
public enum PersonPart: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case entire = "Entire Person", faceSkin = "Facial Skin", bodySkin = "Body Skin", eyebrows = "Eyebrows", sclera = "Eye Sclera"
    case iris = "Iris and Pupil", lips = "Lips", teeth = "Teeth", hair = "Hair", clothes = "Clothes"
    /// The people-parts model's output channel (background, hair, body skin, face skin, clothes, others); nil for the
    /// parts that need no model.
    public var channel: Int? {
        switch self {
        case .hair: return 1; case .bodySkin: return 2; case .faceSkin: return 3; case .clothes: return 4
        case .entire, .eyebrows, .sclera, .iris, .lips, .teeth: return nil
        }
    }
    /// Drawn from the face's landmarks.
    public var isFacial: Bool { [.eyebrows, .sclera, .iris, .lips, .teeth].contains(self) }
}

/// The person a People mask was made for, and which of them.
public struct PeopleSelection: Codable, Equatable, Sendable {
    /// The person's box when the mask was made, normalized with a bottom-left origin: how they are found again.
    public var x: Double, y: Double, width: Double, height: Double
    public var parts: [PersonPart]
    public init(box: CGRect, parts: [PersonPart]) {
        x = box.minX; y = box.minY; width = box.width; height = box.height; self.parts = parts
    }
    public var box: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Scene regions recognized by the bundled DETR panoptic model (COCO stuff and thing classes).
public enum SceneCategory: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case vegetation = "Vegetation", water = "Water", mountains = "Mountains", buildings = "Buildings", ground = "Ground", people = "People", sky = "Sky"
    /// Label names from the model's metadata that make up each region.
    public var labels: Set<String> {
        switch self {
        case .vegetation: return ["tree", "grass", "flower", "potted plant"]
        case .water: return ["river", "sea", "water (other)"]
        case .mountains: return ["mountain", "rock", "snow"]
        case .buildings: return ["house", "building (other)", "roof", "bridge", "tent", "wall (brick)", "wall (stone)", "wall (wood)", "wall (other)", "window (other)", "door", "fence"]
        case .ground: return ["road", "pavement", "dirt", "gravel", "sand", "playingfield", "railroad", "platform", "stairs", "floor (other)", "floor (wood)", "rug"]
        case .people: return ["person"]
        case .sky: return ["sky (other)"]
        }
    }
}

/// Normalized coordinates in the unrotated, oriented source image; origin at bottom left.
public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func rotated(_ turns: Int) -> Self {
        switch turns % 4 {
        case 1: return Self(x: y, y: 1 - x)
        case 2: return Self(x: 1 - x, y: 1 - y)
        case 3: return Self(x: 1 - y, y: x)
        default: return self
        }
    }
    public func unrotated(_ turns: Int) -> Self { rotated((4 - turns % 4) % 4) }
    /// Snap to the nearest 45-degree cardinal direction from `anchor` (Shift-constrain).
    public func constrainedToCardinal(from anchor: MaskPoint) -> MaskPoint {
        let dx = x - anchor.x, dy = y - anchor.y
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return self }
        let angle = atan2(dy, dx)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        return MaskPoint(x: anchor.x + cos(snapped) * distance, y: anchor.y + sin(snapped) * distance)
    }
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    /// Gradient endpoints may sit outside the photo, so a radial mask centered near an edge can extend past it.
    var isGradientEndpoint: Bool { x.isFinite && y.isFinite && (-1...2).contains(x) && (-1...2).contains(y) }
}

public struct MaskStroke: Codable, Equatable, Sendable {
    public var points: [MaskPoint]
    public var radius: Double
    public var softness: Double
    public var erase: Bool
    public init(points: [MaskPoint], radius: Double, softness: Double, erase: Bool) {
        self.points = points; self.radius = radius; self.softness = softness; self.erase = erase
    }
}

/// A nonrecursive mask shape; components combine these in source coordinates.
public struct MaskSelection: Codable, Equatable, Sendable {
    public var kind: MaskKind
    public var inverted = false
    public var feather = 0.01
    public var start = MaskPoint(x: 0.3, y: 0.3)
    public var end = MaskPoint(x: 0.7, y: 0.7)
    /// Radial gradients: the ellipse's rotation about its center in degrees, counterclockwise in source coordinates.
    public var rotation: Double?
    public var strokes: [MaskStroke] = []
    public var color: [Double] = [0.5, 0.5, 0.5]
    public var tolerance = 0.2
    public var raster: Data?
    /// Depth masks: the selected band of relative depth, as [far, near] limits where 1 is nearest.
    public var depthRange: [Double]?
    /// Scene masks: the region the raster was generated for.
    public var scene: SceneCategory?
    /// People masks: the person and parts the raster was generated for.
    public var people: PeopleSelection?
    /// Set when `raster` is a small model output to refine against the photo at render time;
    /// nil for full-resolution rasters.
    public var refinement: MaskRefinement?
    public init(kind: MaskKind) { self.kind = kind }
    public func validate() throws {
        let endpoints = kind == .linear || kind == .radial ? start.isGradientEndpoint && end.isGradientEndpoint : start.isValid && end.isValid
        guard endpoints, feather.isFinite, (0...0.5).contains(feather), rotation.map({ $0.isFinite && (-360...360).contains($0) }) ?? true,
              tolerance.isFinite, (0.001...1).contains(tolerance), color.count == 3,
              color.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              strokes.count <= 10000, strokes.allSatisfy({ stroke in
                  stroke.radius.isFinite && (0.001...0.5).contains(stroke.radius) && stroke.softness.isFinite && (0...1).contains(stroke.softness) && stroke.points.count <= 100000 && stroke.points.allSatisfy(\.isValid)
              }), (raster?.count ?? 0) <= 64 * 1024 * 1024,
              depthRange.map({ $0.count == 2 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) && $0[0] <= $0[1] }) ?? true else { throw EditorError.invalidDocument(L10n.tr("Invalid mask selection.")) }
    }
}
public enum MaskOperation: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case add = "Add", subtract = "Subtract", intersect = "Intersect"
}
public struct MaskComponent: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var operation: MaskOperation
    public var selection: MaskSelection
    public var enabled = true
    public init(operation: MaskOperation, selection: MaskSelection) { self.operation = operation; self.selection = selection }
}
public struct PhotoMask: Codable, Equatable, Identifiable, Sendable {
    /// The most masks a photo holds, and the most components one mask combines.
    public static let maxCount = 100, maxComponents = 32
    public var id = UUID()
    public var portraitCorrection: PortraitCorrection?
    /// Portrait: the face (normalized, origin bottom left) the correction was made for, so a later run or slider for
    /// some people leaves the others' alone. Nil for a mask that belongs to everyone.
    public var face: CGRect?
    /// Portrait › Details: how strongly the measured correction applies, 0 to 2 (1 as measured), so a correction
    /// Auto measured as small can still be pushed.
    public var strength = 1.0
    /// The adjustments as rendered: the measured ones scaled by `strength`.
    public var renderedAdjustments: LocalAdjustments {
        guard strength != 1 else { return adjustments }
        var a = adjustments
        for path in [\LocalAdjustments.exposure, \.saturation, \.vibrance, \.clarity, \.dehaze, \.highlights, \.contrast] {
            a[keyPath: path] *= strength
        }
        return a
    }
    public var name: String
    public var enabled = true
    public var opacity = 1.0
    public var cutsOutBackground = false
    public var adjustments = LocalAdjustments()
    public var selection: MaskSelection
    public var components: [MaskComponent] = []
    public var kind: MaskKind { get { selection.kind } set { selection.kind = newValue } }
    public var inverted = false
    public var feather: Double { get { selection.feather } set { selection.feather = newValue } }
    public var start: MaskPoint { get { selection.start } set { selection.start = newValue } }
    public var end: MaskPoint { get { selection.end } set { selection.end = newValue } }
    public var rotation: Double? { get { selection.rotation } set { selection.rotation = newValue } }
    public var strokes: [MaskStroke] { get { selection.strokes } set { selection.strokes = newValue } }
    public var color: [Double] { get { selection.color } set { selection.color = newValue } }
    public var tolerance: Double { get { selection.tolerance } set { selection.tolerance = newValue } }
    public var raster: Data? { get { selection.raster } set { selection.raster = newValue } }
    public var depthRange: [Double]? { get { selection.depthRange } set { selection.depthRange = newValue } }
    public var scene: SceneCategory? { get { selection.scene } set { selection.scene = newValue } }
    public var people: PeopleSelection? { get { selection.people } set { selection.people = newValue } }
    public var refinement: MaskRefinement? { get { selection.refinement } set { selection.refinement = newValue } }
    public init(kind: MaskKind) { selection = MaskSelection(kind: kind); name = kind.localizedTitle }
    enum CodingKeys: String, CodingKey { case id, name, portraitCorrection, face, strength, enabled, opacity, cutsOutBackground, adjustments, components, baseInverted, kind, inverted, feather, start, end, rotation, strokes, color, tolerance, raster, depthRange, scene, people, refinement }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(MaskKind.self, forKey: .kind))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        // A correction Portrait no longer makes (Face exposure) leaves an ordinary mask that still renders.
        portraitCorrection = (try? c.decodeIfPresent(PortraitCorrection.self, forKey: .portraitCorrection)) ?? nil
        face = try c.decodeIfPresent(CGRect.self, forKey: .face)
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        cutsOutBackground = try c.decodeIfPresent(Bool.self, forKey: .cutsOutBackground) ?? cutsOutBackground
        adjustments = try c.decodeIfPresent(LocalAdjustments.self, forKey: .adjustments) ?? adjustments
        components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? components
        inverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? inverted
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? feather
        start = try c.decodeIfPresent(MaskPoint.self, forKey: .start) ?? start
        end = try c.decodeIfPresent(MaskPoint.self, forKey: .end) ?? end
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation)
        strokes = try c.decodeIfPresent([MaskStroke].self, forKey: .strokes) ?? strokes
        color = try c.decodeIfPresent([Double].self, forKey: .color) ?? color
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? tolerance
        raster = try c.decodeIfPresent(Data.self, forKey: .raster)
        depthRange = try c.decodeIfPresent([Double].self, forKey: .depthRange)
        scene = try c.decodeIfPresent(SceneCategory.self, forKey: .scene)
        people = try c.decodeIfPresent(PeopleSelection.self, forKey: .people)
        refinement = try c.decodeIfPresent(MaskRefinement.self, forKey: .refinement)
        selection.inverted = try c.decodeIfPresent(Bool.self, forKey: .baseInverted) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selection.inverted, forKey: .baseInverted)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(portraitCorrection, forKey: .portraitCorrection)
        try c.encodeIfPresent(face, forKey: .face)
        if strength != 1 { try c.encode(strength, forKey: .strength) }
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(cutsOutBackground, forKey: .cutsOutBackground)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encode(components, forKey: .components)
        try c.encode(kind, forKey: .kind)
        try c.encode(inverted, forKey: .inverted)
        try c.encode(feather, forKey: .feather)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(rotation, forKey: .rotation)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(color, forKey: .color)
        try c.encode(tolerance, forKey: .tolerance)
        try c.encode(raster, forKey: .raster)
        try c.encodeIfPresent(depthRange, forKey: .depthRange)
        try c.encodeIfPresent(scene, forKey: .scene)
        try c.encodeIfPresent(people, forKey: .people)
        try c.encodeIfPresent(refinement, forKey: .refinement)
    }
    public func validate() throws {
        _ = try adjustments.validated(); try selection.validate()
        guard name.count <= 200, opacity.isFinite, (0...1).contains(opacity), strength.isFinite, (0...2).contains(strength), components.count <= Self.maxComponents,
              Set(components.map(\.id)).count == components.count else { throw EditorError.invalidDocument(L10n.tr("Invalid mask settings.")) }
        var rasterBytes = raster?.count ?? 0
        for component in components { try component.selection.validate(); rasterBytes += component.selection.raster?.count ?? 0 }
        guard rasterBytes <= 128 * 1024 * 1024 else { throw EditorError.invalidDocument(L10n.tr("Mask selections are too large.")) }
    }
}
