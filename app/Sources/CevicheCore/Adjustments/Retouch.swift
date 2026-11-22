import Foundation
import CoreImage

/// How a stroke fills its footprint. Remove blends like Heal but always takes its source automatically, so it has no
/// source to show or move.
public enum RetouchMode: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }
    public var hasSourceHandle: Bool { self == .heal || self == .clone }
    case remove = "Remove", heal = "Heal", clone = "Clone", tone = "Dodge/Burn"
}
public struct RetouchStroke: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var mode: RetouchMode
    public var source: MaskPoint
    public var points: [MaskPoint]
    public var radius: Double
    public var softness: Double
    public var opacity: Double
    public var exposure = 0.0
    public var enabled = true
    /// Added by the dust finder rather than drawn; listed as "Dust" so it can be reviewed.
    public var suggested = false
    /// Made in Portrait (found as a blemish or painted there). It renders like any stroke; the tag only keeps
    /// face retouching in a list of its own, apart from the photo's other strokes.
    public var face = false
    /// For a face spot in a group picture, whose face it is (Vision's box, as Portrait's people have it); nil is
    /// everyone's.
    public var faceBox: CGRect?
    /// Made by Distraction Removal's People finder over someone who is not the subject; listed as People.
    public var person = false
    /// A dust spot's Dodge/Burn: it brings the spot's own shading back to its surroundings pixel by pixel, so an
    /// approximate circle lightens only the spot, as deep as each part of it is; `exposure` is how far it may go.
    public var matchesTone: Bool { mode == .tone && suggested && points.count == 1 }
    /// The list a stroke belongs to.
    public enum Group: Sendable { case drawn, dust, face, people }
    public var group: Group { suggested ? .dust : face ? .face : person ? .people : .drawn }
    /// Remove only: fill the footprint with the inpainting model rather than a patch. Kept everywhere the stroke goes, XMP
    /// and pasted edits included, so a stroke whose `fill` is missing or out of date can have it made again.
    public var generative = false
    /// Remove only: the AI fill made for this stroke, if any.
    public var fill: RetouchFill?
    public init(mode: RetouchMode, source: MaskPoint, target: MaskPoint, radius: Double, softness: Double, opacity: Double) {
        self.mode = mode; self.source = source; points = [target]; self.radius = radius; self.softness = softness; self.opacity = opacity
    }
    enum CodingKeys: String, CodingKey { case id, mode, source, points, radius, softness, opacity, exposure, enabled, suggested, face, faceBox, person, generative, fill }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); mode = try c.decode(RetouchMode.self, forKey: .mode)
        source = try c.decode(MaskPoint.self, forKey: .source); points = try c.decode([MaskPoint].self, forKey: .points)
        radius = try c.decode(Double.self, forKey: .radius); softness = try c.decode(Double.self, forKey: .softness); opacity = try c.decode(Double.self, forKey: .opacity)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        suggested = try c.decodeIfPresent(Bool.self, forKey: .suggested) ?? false
        face = try c.decodeIfPresent(Bool.self, forKey: .face) ?? false
        faceBox = try c.decodeIfPresent(CGRect.self, forKey: .faceBox)
        person = try c.decodeIfPresent(Bool.self, forKey: .person) ?? false
        generative = try c.decodeIfPresent(Bool.self, forKey: .generative) ?? false
        fill = try c.decodeIfPresent(RetouchFill.self, forKey: .fill)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(mode, forKey: .mode); try c.encode(source, forKey: .source); try c.encode(points, forKey: .points)
        try c.encode(radius, forKey: .radius); try c.encode(softness, forKey: .softness); try c.encode(opacity, forKey: .opacity); try c.encode(enabled, forKey: .enabled)
        if mode == .tone { try c.encode(exposure, forKey: .exposure) }
        if suggested { try c.encode(true, forKey: .suggested) }
        if face { try c.encode(true, forKey: .face) }
        try c.encodeIfPresent(faceBox, forKey: .faceBox)
        if person { try c.encode(true, forKey: .person) }
        if generative { try c.encode(true, forKey: .generative) }
        try c.encodeIfPresent(fill, forKey: .fill)
    }
    func validate() throws {
        guard (-2...2).contains(exposure), source.isValid, !points.isEmpty, points.count <= 100000, points.allSatisfy(\.isValid),
              radius.isFinite, (0.001...0.25).contains(radius), softness.isFinite, (0...1).contains(softness), opacity.isFinite, (0...1).contains(opacity) else { throw EditorError.invalidDocument(L10n.tr("Invalid retouch stroke.")) }
        try fill?.validate()
    }
}
final class RetouchRenderer {
    private let masks: MaskRenderer
    /// Each AI fill's ratio, decoded once, for the stroke geometry it was checked against (nil when it no longer fits).
    private var fills: [UUID: (fill: RetouchFill, points: [MaskPoint], radius: Double, softness: Double, ratio: CIImage?)] = [:]
    init(context: CIContext) { masks = MaskRenderer(context: context) }
    private static let kernels: [String: CIKernel] = {
        let list = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        // The target's low frequencies come from the ring around the stroke (a normalized blur weighted away from the
        // footprint, the weight carried as premultiplied alpha), so healing removes a blemish's own tone instead of
        // keeping a blurred copy of it. Out of the ring's reach the plain blur of the target is used.
        extern "C" [[ stitchable ]] float4 heal(coreimage::sample_t src, coreimage::sample_t lowSource, coreimage::sample_t lowRing, coreimage::sample_t lowTarget) {
            float w = lowRing.a;
            float3 low = mix(lowTarget.rgb, lowRing.rgb / max(w, 1e-4), clamp(w / 0.02, 0.0, 1.0));
            return float4(max(src.rgb + low - lowSource.rgb, float3(0.0)), src.a);
        }
        // A one-dab stroke's footprint, as the brush raster draws it: full inside the soft edge, linear to zero at the radius.
        extern "C" [[ stitchable ]] float4 retouchDisc(coreimage::sample_t s, float4 disc, coreimage::destination dest) {
            float v = clamp((disc.w - distance(dest.coord(), disc.xy)) / max(disc.w - disc.z, 1e-3), 0.0, 1.0);
            return float4(v, v, v, 1.0);
        }
        // The target weighted by how far outside the footprint each pixel is, premultiplied.
        extern "C" [[ stitchable ]] float4 outside(coreimage::sample_t s, coreimage::sample_t footprint) {
            float w = 1.0 - footprint.r;
            return float4(s.rgb * w, w);
        }
        // The ring's normalized blur, as `heal` takes it.
        extern "C" [[ stitchable ]] float4 surround(coreimage::sample_t lowRing, coreimage::sample_t lowTarget) {
            float w = lowRing.a;
            return float4(mix(lowTarget.rgb, lowRing.rgb / max(w, 1e-4), clamp(w / 0.02, 0.0, 1.0)), 1.0);
        }
        // A dust spot's matched Dodge/Burn: the blurred photo brought to the surroundings' brightness by a smooth gain,
        // within `limits`, so grain and texture stay and pixels the spot doesn't shade keep a gain of 1. The colour may
        // follow the surroundings a little, as a spot's shadow is rarely quite neutral.
        extern "C" [[ stitchable ]] float4 matchTone(coreimage::sample_t s, coreimage::sample_t low, coreimage::sample_t around, float2 limits) {
            float3 w = float3(0.2126, 0.7152, 0.0722);
            float l = max(dot(low.rgb, w), 1e-5), b = max(dot(around.rgb, w), 0.0);
            float g = clamp(b / l, limits.x, limits.y);
            float3 channel = (around.rgb / max(low.rgb, float3(1e-5))) / max(b / l, 1e-5);
            return float4(s.rgb * g * clamp(channel, 0.92, 1.08), s.a);
        }
        // An AI fill: its stored ratio times the surroundings, plus the source's grain finer than the stored ratio. The
        // ratio's edge samples are unpremultiplied; past its edge it is neutral.
        extern "C" [[ stitchable ]] float4 aiFill(coreimage::sample_t ratio, coreimage::sample_t around, coreimage::sample_t src, coreimage::sample_t lowSource, float grain) {
            float3 r = ratio.a > 1e-3 ? ratio.rgb / ratio.a : float3(1.0);
            return float4(max(r * around.rgb + grain * (src.rgb - lowSource.rgb), float3(0.0)), 1.0);
        }
        """)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()
    func apply(_ strokes: [RetouchStroke], to input: CIImage) throws -> CIImage {
        let painted = strokes.filter { $0.points.count > 1 }
        masks.prune(painted.map { stroke in var mask = PhotoMask(kind: .brush); mask.id = stroke.id; return mask })
        fills = fills.filter { id, _ in strokes.contains { $0.id == id } }
        let extent = input.extent, side = min(extent.width, extent.height)
        // Each stroke changes only its footprint and reads only around it and its source (plus the heal blur, or an AI
        // fill's surroundings and grain blur).
        struct Area { var stroke: RetouchStroke; var footprint: CGRect; var reads: CGRect }
        var pending: [Area] = strokes.compactMap { stroke in
            guard stroke.enabled, !stroke.points.isEmpty else { return nil }
            let radius = max(1, stroke.radius * side), footprint = Self.bounds(of: stroke, in: extent)
            guard !footprint.isEmpty else { return nil }
            if stroke.matchesTone { let margin = ceil(radius * 3) + 2; return Area(stroke: stroke, footprint: footprint, reads: footprint.insetBy(dx: -margin, dy: -margin)) }
            if stroke.mode == .tone { return Area(stroke: stroke, footprint: footprint, reads: footprint) }
            let shift = CGPoint(x: (stroke.points[0].x - stroke.source.x) * extent.width, y: (stroke.points[0].y - stroke.source.y) * extent.height)
            var margin = stroke.mode != .clone ? ceil(max(1, radius * 0.6) * 3) + 2 : 1
            if let (fill, ratio) = fillRatio(stroke) { margin = max(margin, ceil(max(1, fill.reach * side) * 3) + 2, ceil(1.8 * fill.width * extent.width / ratio.extent.width) + 2) }
            return Area(stroke: stroke, footprint: footprint, reads: footprint.union(footprint.offsetBy(dx: -shift.x, dy: -shift.y)).insetBy(dx: -margin, dy: -margin))
        }
        // Strokes that neither read nor cover each other's footprints are applied together from the same input, which gives
        // the same result as one after another but keeps a hundred dust spots from becoming a hundred nested graphs. A stroke
        // that touches an earlier one waits for a later pass, as does anything touching a stroke that waits.
        var image = input
        while !pending.isEmpty {
            var layer: [Area] = [], deferred: [Area] = []
            for area in pending {
                func touches(_ other: Area) -> Bool { area.footprint.intersects(other.reads) || area.reads.intersects(other.footprint) }
                if layer.contains(where: touches) || deferred.contains(where: touches) { deferred.append(area) } else { layer.append(area) }
            }
            let base = image.insertingIntermediate(cache: true)
            for area in layer { image = try patch(area.stroke, footprint: area.footprint, from: base).composited(over: image) }
            pending = deferred
        }
        return image
    }
    /// The pixels a stroke can cover in `extent`.
    static func bounds(of stroke: RetouchStroke, in extent: CGRect) -> CGRect {
        let radius = max(1, stroke.radius * min(extent.width, extent.height)), xs = stroke.points.map { extent.minX + $0.x * extent.width }, ys = stroke.points.map { extent.minY + $0.y * extent.height }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX - radius, y: minY - radius, width: maxX - minX + 2 * radius, height: maxY - minY + 2 * radius).integral.intersection(extent)
    }
    /// A Remove stroke's AI fill and its decoded ratio, unless it has none or was made for a different footprint.
    private func fillRatio(_ stroke: RetouchStroke) -> (fill: RetouchFill, ratio: CIImage)? {
        guard stroke.mode == .remove, let fill = stroke.fill else { return nil }
        if let cached = fills[stroke.id], cached.fill == fill, cached.points == stroke.points, cached.radius == stroke.radius, cached.softness == stroke.softness {
            return cached.ratio.map { (fill, $0) }
        }
        let ratio = RetouchFill.footprint(of: stroke) == fill.footprint ? try? RetouchFillRaster.image(fill.raster) : nil
        fills[stroke.id] = (fill, stroke.points, stroke.radius, stroke.softness, ratio)
        return ratio.map { (fill, $0) }
    }
    /// The stroke's coverage over `image`'s extent, 0 to 1 in every channel.
    func footprint(_ stroke: RetouchStroke, in image: CIImage) throws -> CIImage {
        let disc = Self.kernels["retouchDisc"]!
        guard let first = stroke.points.first else { throw EditorError.render }
        let extent = image.extent
        if stroke.points.count == 1 {
            // A single dab (every dust spot) needs no raster: the disc is computed in place.
            let radius = max(1, stroke.radius * min(extent.width, extent.height))
            let center = CGPoint(x: extent.minX + first.x * extent.width, y: extent.minY + first.y * extent.height)
            guard let output = disc.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, CIVector(x: center.x, y: center.y, z: radius * max(0, 1 - stroke.softness), w: radius)]) else { throw EditorError.render }
            return output
        }
        var mask = PhotoMask(kind: .brush); mask.id = stroke.id; mask.feather = 0
        mask.strokes = [MaskStroke(points: stroke.points, radius: stroke.radius, softness: stroke.softness, erase: false)]
        return try masks.image(for: mask, source: image)
    }
    /// What an AI fill is relative to: `image` blurred over `reach` pixels, weighted away from the footprint so the
    /// hole's own content leaves it, as `heal` takes its tone.
    func surroundings(_ image: CIImage, footprint: CIImage, reach: Double) throws -> CIImage {
        let outside = Self.kernels["outside"]!, surround = Self.kernels["surround"]!
        func low(_ value: CIImage) -> CIImage { value.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(1, reach)]) }
        guard let ring = outside.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [image, footprint]),
              let output = surround.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [low(ring), low(image)]) else { throw EditorError.render }
        return output
    }
    /// The blur `surroundings` uses for a stroke `thickness` pixels from its middle to its edge (`InpaintPlan.thickness`):
    /// wide enough that the middle of the hole still sees past its edge, which is the brush radius across a line, however
    /// long, and a little over half the way from a blob's middle to its edge.
    static func reach(radius: Double, thickness: Double) -> Double { max(radius, 0.6 * thickness) }
    /// One stroke's result inside its footprint rectangle, sampling `image`.
    private func patch(_ stroke: RetouchStroke, footprint bounds: CGRect, from image: CIImage) throws -> CIImage {
        let heal = Self.kernels["heal"]!, outside = Self.kernels["outside"]!, aiFill = Self.kernels["aiFill"]!
        guard let first = stroke.points.first else { throw EditorError.render }
        let extent = image.extent, side = min(extent.width, extent.height)
        let radius = max(1, stroke.radius * side)
        // Never feed a stroke back into itself.
        let shifted = image.transformed(by: CGAffineTransform(translationX: (first.x - stroke.source.x) * extent.width, y: (first.y - stroke.source.y) * extent.height))
        let footprint = try self.footprint(stroke, in: image)
        var patch = shifted, edge = footprint
        if stroke.matchesTone {
            // The circle is only roughly drawn: full strength over most of it, since the gain itself stays at 1 off the
            // spot, and the surroundings measured outside it.
            let center = CGPoint(x: extent.minX + first.x * extent.width, y: extent.minY + first.y * extent.height)
            guard let disc = Self.kernels["retouchDisc"]!.apply(extent: extent, roiCallback: { _, rect in rect },
                                                                 arguments: [image, CIVector(x: center.x, y: center.y, z: radius * 0.8, w: radius)]) else { throw EditorError.render }
            let around = try surroundings(image, footprint: disc, reach: radius)
            let low = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.8, radius * 0.05)])
            let reach = exp2(abs(stroke.exposure) * 1.5 + 0.25)
            let limits = stroke.exposure >= 0 ? CIVector(x: 1, y: reach) : CIVector(x: 1 / reach, y: 1)
            guard let output = Self.kernels["matchTone"]!.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, low, around, limits]) else { throw EditorError.render }
            patch = output; edge = disc
        } else if stroke.mode == .tone {
            patch = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: stroke.exposure])
        } else if let (fill, ratio) = fillRatio(stroke) {
            // The network filled every pixel the footprint touches, matched to what is around, so the fill covers the
            // brush's whole width and blends only where the soft edge has nearly faded out: whatever lies under the brush
            // goes, even in the edge a patch fades into.
            edge = footprint.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 8, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 8, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 8, w: 0)]).applyingFilter("CIColorClamp")
            // The stored ratio placed on this render's pixels. Where they are finer than it (an export of a fill made
            // scaled down), the source's grain finer than the ratio is added, so the fill is not smoother than the photo.
            let target = CGRect(x: extent.minX + fill.x * extent.width, y: extent.minY + fill.y * extent.height, width: fill.width * extent.width, height: fill.height * extent.height)
            let magnification = target.width / ratio.extent.width
            let placed = ratio.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY).scaledBy(x: magnification, y: target.height / ratio.extent.height), highQualityDownsample: magnification < 1)
            let around = try surroundings(image, footprint: footprint, reach: fill.reach * side)
            let lowSource = shifted.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(0.5, 0.6 * magnification)])
            // A source over the stroke's own footprint would put back the fine detail of what was removed (a sign's
            // arrows, embossed in the fill): no grain then.
            let area = Self.bounds(of: stroke, in: extent)
            let dx = (first.x - stroke.source.x) * extent.width, dy = (first.y - stroke.source.y) * extent.height
            let ownArea = abs(dx) < area.width && abs(dy) < area.height
            let grain = ownArea ? 0 : min(1, max(0, magnification - 1))
            guard let output = aiFill.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [placed, around, shifted, lowSource, grain]) else { throw EditorError.render }
            patch = output
        } else if stroke.mode != .clone {
            let blur = max(1, radius * 0.6)
            func low(_ value: CIImage) -> CIImage { value.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur]) }
            guard let ring = outside.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [image, footprint]) else { throw EditorError.render }
            guard let output = heal.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [shifted, low(shifted), low(ring), low(image)]) else { throw EditorError.render }
            patch = output
        }
        let coverage = edge.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: stroke.opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: stroke.opacity, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: stroke.opacity, w: 0)])
        // Only the footprint changes, so the result is cropped to it and Core Image evaluates nothing else.
        return patch.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: coverage]).cropped(to: stroke.mode == .tone ? bounds : bounds.intersection(shifted.extent))
    }
}
