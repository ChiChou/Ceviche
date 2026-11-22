import CoreImage
import Foundation
import Vision

extension RawRenderer {
    /// Remove strokes over the object at `point` (normalized, bottom-left origin, in the retouch frame).
    public func objectStrokes(_ settings: Adjustments, at point: MaskPoint, tolerance: Double = 0.006) async throws -> [RetouchStroke] {
        try await objectPicker(settings).strokes(at: point, tolerance: tolerance)
    }

    /// The photo as Remove › Object looks at it: developed once (geometry and masks left out, as strokes are placed
    /// before them), for any number of points.
    public func objectPicker(_ settings: Adjustments) throws -> ObjectPicker {
        let base = ObjectPicker.basis(settings)
        let input = try pipeline(base, maxDimension: ObjectRemoval.pixelSize)
        guard let image = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditorError.render }
        return ObjectPicker(image: image, basis: base)
    }
}

/// What a click with Remove › Object would take out, found on one developing of the photo: the line map for wires is
/// made once, so each point costs only its trace and Vision's segmentation (about 70 ms), quick enough to follow the
/// pointer.
public final class ObjectPicker: @unchecked Sendable {
    /// The settings it was developed with, as `basis` gives them: a picker is stale once these change.
    public let basis: Adjustments
    let input: CIImage
    let W: Int, H: Int
    let lines: [Float]
    let context = CIContext(options: [.cacheIntermediates: false])

    init(image: CGImage, basis: Adjustments) {
        self.basis = basis
        input = CIImage(cgImage: image)
        W = image.width; H = image.height
        lines = ObjectRemoval.lines(input, context: context)
    }

    /// The settings that matter to what is picked: the photo before geometry and masks.
    public static func basis(_ settings: Adjustments) -> Adjustments {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        return base
    }

    /// Remove strokes over the object at `point`, as if painted by hand: a wire or a cable near the point followed
    /// along its length as one stroke; otherwise the object's outline from Vision, widened a little for its soft edge,
    /// walked by the same brush path Find People uses. AI fill when its model is installed. The strokes are ordinary
    /// drawn strokes, to edit or delete. `tolerance`: how far off a wire the point may be, a fraction of the long side.
    public func strokes(at point: MaskPoint, tolerance: Double = 0.006) async throws -> [RetouchStroke] {
        try await pick(at: point, tolerance: tolerance).strokes
    }

    /// What a click at `point` takes out. With `refining`, the seed points of an object picked before, the point is
    /// added to them (or, `excluding`, taken away) and that object is outlined again; wires are never refined.
    public func pick(at point: MaskPoint, tolerance: Double = 0.006, refining: ObjectSeeds? = nil, excluding: Bool = false) async throws -> ObjectPick {
        let generative = BundledModel.inpaint.isAvailable
        if refining == nil, let wire = ObjectRemoval.traceLine(lines, width: W, height: H, from: point, tolerance: tolerance) {
            var stroke = RetouchStroke(mode: .remove, source: wire.points[0], target: wire.points[0], radius: wire.radius, softness: 0.5, opacity: 1)
            stroke.points = wire.points
            stroke.generative = generative
            return ObjectPick(strokes: [stroke], seeds: nil, aspect: Double(W) / Double(H))
        }
        var seeds = refining ?? ObjectSeeds(included: [])
        if excluding { seeds.excluded.append(point) } else { seeds.included.append(point) }
        let matte = try await ObjectRemoval.matte(input, seeds: seeds, context: context)
        try Task.checkCancellation()
        var area = ObjectRemoval.mask(matte, extent: input.extent, context: context)
        guard !area.isEmpty, area.area > 0 else { throw EditorError.invalidDocument(L10n.tr("No object was found at that point.")) }
        // Something this big, or running along much of the frame's edge, is the scene (the sky around a wire missed by a
        // few pixels), not something to take out.
        guard Double(area.area) < 0.15 * Double(W * H), ObjectRemoval.borderShare(area, width: W, height: H) < 0.12 else {
            throw EditorError.invalidDocument(L10n.tr("That is too much of the photo to remove."))
        }
        let box = area.tightRect
        // A margin for the soft edge and the halo sharpening leaves: what the outline misses shows once the rest is gone.
        // A wire or a pole is sized by how thick it is, not by its length.
        let side = Double(max(box.width, box.height)), half = ObjectRemoval.halfThickness(area)
        let margin: Double = 2 + min(0.03 * side, half)
        area = area.dilated(Int(margin.rounded()), width: W, height: H)
        let byLength: Double = 3 + 0.02 * side + 0.002 * Double(min(W, H))
        let radius = min(byLength, 3 + 1.5 * half)
        let strokes = PeopleFinder.strokes(covering: area, radius: radius, protect: PeopleFinder.Mask(), width: W, height: H)
        return ObjectPick(strokes: strokes.map { var s = $0; s.person = false; s.generative = generative; return s }, seeds: seeds, aspect: Double(W) / Double(H))
    }

    /// Masks › Object: the mask a click at `point` makes, from Vision's matte at its own size as Select Object stores
    /// it, with its outline for drawing under the pointer.
    public func objectMask(at point: MaskPoint) async throws -> (mask: PhotoMask, outline: [(MaskPoint, MaskPoint)]) {
        let raw = try await ObjectRemoval.rawMatte(input, seeds: ObjectSeeds(included: [point]))
        try Task.checkCancellation()
        var mask = PhotoMask(kind: .object)
        mask.feather = 0
        mask.raster = try MaskRaster.encode(raw, context: context)
        return (mask, ObjectRemoval.outline(raw, context: context))
    }
}

/// The points that mark an object for Vision: clicked on it (the first is where it was picked) and taken away.
public struct ObjectSeeds: Sendable, Equatable {
    public var included: [MaskPoint]
    public var excluded: [MaskPoint] = []
}

/// What a click with Remove › Object takes out: the strokes, and for an object (not a wire) the points that marked it,
/// to grow or cut back with the next click.
public struct ObjectPick: Sendable {
    public let strokes: [RetouchStroke]
    public let seeds: ObjectSeeds?
    /// The photo's width over its height, to measure distances on it.
    public let aspect: Double

    public init(strokes: [RetouchStroke], seeds: ObjectSeeds?, aspect: Double) {
        self.strokes = strokes; self.seeds = seeds; self.aspect = aspect
    }

    /// Whether `point` lies under the strokes.
    public func contains(_ point: MaskPoint) -> Bool {
        // Normalized units to the shorter side's, which stroke radii are in.
        let sx = max(1, aspect), sy = max(1, 1 / aspect)
        return strokes.contains { stroke in
            stroke.points.contains { hypot((point.x - $0.x) * sx, (point.y - $0.y) * sy) <= stroke.radius * 1.2 }
        }
    }
}

enum ObjectRemoval {
    /// Long edge the photo is segmented at: enough for a sign or a bin, quick to find.
    static let pixelSize = 2048.0

    /// The object's matte from its seed points, over `image`'s extent.
    static func matte(_ image: CIImage, seeds: ObjectSeeds, context: CIContext) async throws -> CIImage {
        let raw = try await rawMatte(image, seeds: seeds)
        return raw.transformed(by: CGAffineTransform(scaleX: image.extent.width / raw.extent.width, y: image.extent.height / raw.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
    }

    /// Vision's matte for the object its seed points mark, at Vision's own size, from the origin: on macOS 27 the
    /// clicked object's segmentation, grown or cut back by the points added and taken away; before that the
    /// foreground instances under the points added, less those under the points taken away.
    static func rawMatte(_ image: CIImage, seeds: ObjectSeeds) async throws -> CIImage {
        guard let first = seeds.included.first else { throw EditorError.invalidDocument(L10n.tr("No object was found at that point.")) }
        if #available(macOS 27, iOS 27, *) {
            let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: first.x, y: first.y))
            for p in seeds.included.dropFirst() { try request.addIncludedPoint(NormalizedPoint(x: p.x, y: p.y)) }
            for p in seeds.excluded { try request.addExcludedPoint(NormalizedPoint(x: p.x, y: p.y)) }
            try await request.downloadAssets()
            try Task.checkCancellation()
            request.qualityLevel = .accurate
            guard let observation = try await ImageRequestHandler(image).perform(request) else {
                throw EditorError.invalidDocument(L10n.tr("No object was found at that point."))
            }
            return CIImage(cgImage: try observation.cgImage, options: [.colorSpace: NSNull()])
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw EditorError.invalidDocument(L10n.tr("No object was found at that point.")) }
        // The instances under the points, read from the label map.
        let labels = observation.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly); defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let lw = CVPixelBufferGetWidth(labels), lh = CVPixelBufferGetHeight(labels)
        guard let base = CVPixelBufferGetBaseAddress(labels) else { throw EditorError.render }
        func instance(_ p: MaskPoint) -> Int {
            let px = min(lw - 1, max(0, Int(p.x * Double(lw)))), py = min(lh - 1, max(0, Int((1 - p.y) * Double(lh))))
            return Int(base.advanced(by: py * CVPixelBufferGetBytesPerRow(labels)).assumingMemoryBound(to: UInt8.self)[px])
        }
        let wanted = IndexSet(seeds.included.map(instance).filter { $0 > 0 }).subtracting(IndexSet(seeds.excluded.map(instance)))
        guard !wanted.isEmpty else { throw EditorError.invalidDocument(L10n.tr("No object was found at that point.")) }
        return CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: wanted, from: handler))
    }

    /// The outline of where `matte` is above one half, as line segments in normalized coordinates (bottom-left
    /// origin), traced on a copy at most `size` pixels across: for drawing on the photo, not for the mask itself.
    static func outline(_ matte: CIImage, context: CIContext, size: Double = 320) -> [(MaskPoint, MaskPoint)] {
        let scale = min(1, size / max(matte.extent.width, matte.extent.height))
        let small = matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = max(2, Int(small.extent.width.rounded())), h = max(2, Int(small.extent.height.rounded()))
        var v = [UInt8](repeating: 0, count: w * h)
        v.withUnsafeMutableBytes { context.render(small, toBitmap: $0.baseAddress!, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .R8, colorSpace: nil) }
        // Marching squares on the grid of pixel centres, padded with outside so the frame's edge closes it.
        func at(_ x: Int, _ y: Int) -> Double { x < 0 || y < 0 || x >= w || y >= h ? 0 : Double(v[y * w + x]) / 255 }
        func point(_ x: Double, _ y: Double) -> MaskPoint {
            MaskPoint(x: min(1, max(0, (x + 0.5) / Double(w))), y: min(1, max(0, 1 - (y + 0.5) / Double(h))))
        }
        var segments: [(MaskPoint, MaskPoint)] = []
        for y in -1..<h { for x in -1..<w {
            let a = at(x, y), b = at(x + 1, y), c = at(x + 1, y + 1), d = at(x, y + 1)
            let code = (a > 0.5 ? 1 : 0) | (b > 0.5 ? 2 : 0) | (c > 0.5 ? 4 : 0) | (d > 0.5 ? 8 : 0)
            guard code != 0, code != 15 else { continue }
            func lerp(_ p: Double, _ q: Double) -> Double { abs(q - p) < 1e-6 ? 0.5 : (0.5 - p) / (q - p) }
            let top = point(Double(x) + lerp(a, b), Double(y)), right = point(Double(x + 1), Double(y) + lerp(b, c))
            let bottom = point(Double(x) + lerp(d, c), Double(y + 1)), left = point(Double(x), Double(y) + lerp(a, d))
            switch code {
            case 1, 14: segments.append((left, top))
            case 2, 13: segments.append((top, right))
            case 3, 12: segments.append((left, right))
            case 4, 11: segments.append((right, bottom))
            case 6, 9: segments.append((top, bottom))
            case 7, 8: segments.append((left, bottom))
            case 5: segments.append((left, top)); segments.append((right, bottom))
            case 10: segments.append((top, right)); segments.append((left, bottom))
            default: break
            }
        } }
        return segments
    }

    /// The matte as a mask in pixels of `extent`, rows from the top.
    static func mask(_ matte: CIImage, extent: CGRect, context: CIContext) -> PeopleFinder.Mask {
        let W = Int(extent.width), H = Int(extent.height)
        var v = [UInt8](repeating: 0, count: W * H)
        v.withUnsafeMutableBytes { context.render(matte, toBitmap: $0.baseAddress!, rowBytes: W, bounds: extent, format: .R8, colorSpace: nil) }
        let mask = PeopleFinder.Mask(x: 0, y: 0, w: W, h: H, v: v)
        let tight = mask.tightRect
        guard !tight.isNull, tight.width > 0 else { return PeopleFinder.Mask() }
        return crop(mask, to: tight)
    }

    /// How much of the frame's edge the mask runs along, 0 to 1.
    static func borderShare(_ mask: PeopleFinder.Mask, width W: Int, height H: Int) -> Double {
        var n = 0
        for x in 0..<W { if mask.contains(x, 0) { n += 1 }; if mask.contains(x, H - 1) { n += 1 } }
        for y in 0..<H { if mask.contains(0, y) { n += 1 }; if mask.contains(W - 1, y) { n += 1 } }
        return Double(n) / Double(2 * (W + H))
    }

    /// Half the object's thickness in pixels: the furthest any pixel inside lies from the outside (a chamfer
    /// distance, 1 across, 1.4 diagonally).
    static func halfThickness(_ mask: PeopleFinder.Mask) -> Double {
        let w = mask.w, h = mask.h
        guard w > 0, h > 0 else { return 0 }
        var d = [Float](repeating: 0, count: w * h)
        for i in d.indices where mask.v[i] > 127 { d[i] = .greatestFiniteMagnitude }
        func at(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? 0 : d[y * w + x] }
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x - 1, y) + 1, at(x, y - 1) + 1, at(x - 1, y - 1) + 1.4, at(x + 1, y - 1) + 1.4)
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            d[y * w + x] = min(d[y * w + x], at(x + 1, y) + 1, at(x, y + 1) + 1, at(x + 1, y + 1) + 1.4, at(x - 1, y + 1) + 1.4)
        } }
        return Double(d.max() ?? 0)
    }

    private static func crop(_ mask: PeopleFinder.Mask, to rect: CGRect) -> PeopleFinder.Mask {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        var v = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { v[y * w + x] = mask.v[(y0 + y) * mask.w + x0 + x] } }
        return PeopleFinder.Mask(x: x0, y: y0, w: w, h: h, v: v)
    }

    // MARK: Lines

    /// How strongly each pixel lies on a thin line darker or lighter than either side: the larger of the black and
    /// white top-hats of the luminance over a 9-pixel square, in pixels of `image`, rows from the top.
    static func lines(_ image: CIImage, context: CIContext) -> [Float] {
        let extent = image.extent
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CILinearToSRGBToneCurve")
        func morph(_ i: CIImage, _ name: String) -> CIImage {
            i.clampedToExtent().applyingFilter(name, parameters: ["inputWidth": 9, "inputHeight": 9]).cropped(to: extent)
        }
        let closed = morph(morph(luma, "CIMorphologyRectangleMaximum"), "CIMorphologyRectangleMinimum")
        let opened = morph(morph(luma, "CIMorphologyRectangleMinimum"), "CIMorphologyRectangleMaximum")
        let dark = closed.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: luma])
        let light = luma.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: opened])
        let both = dark.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: light])
        let W = Int(extent.width), H = Int(extent.height)
        var values = [Float](repeating: 0, count: W * H)
        values.withUnsafeMutableBytes { context.render(both, toBitmap: $0.baseAddress!, rowBytes: W * 4, bounds: extent, format: .Rf, colorSpace: nil) }
        return values
    }

    /// The thin line under `point` followed both ways, as a stroke's points and radius; nil when the click is not on
    /// a line, or the line is short (a twig or a window frame is an object, not a wire).
    static func traceLine(_ t: [Float], width W: Int, height H: Int, from point: MaskPoint, tolerance: Double = 0.006) -> (points: [MaskPoint], radius: Double)? {
        func at(_ x: Double, _ y: Double) -> Float {
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            return xi < 0 || yi < 0 || xi >= W || yi >= H ? 0 : t[yi * W + xi]
        }
        // Snap the click to the line under it: the nearest counts more than a stronger edge a little further off.
        let cx = point.x * Double(W), cy = (1 - point.y) * Double(H)
        let reach = max(4, Int((tolerance * Double(max(W, H))).rounded()))
        var seed = (x: cx, y: cy, v: Float(0)), bestScore = Float(0)
        for dy in -reach...reach { for dx in -reach...reach where dx * dx + dy * dy <= reach * reach {
            let v = at(cx + Double(dx), cy + Double(dy))
            let score = v * Float(1 - 0.6 * hypot(Double(dx), Double(dy)) / Double(reach))
            if v >= 0.04, score > bestScore { seed = (cx + Double(dx), cy + Double(dy), v); bestScore = score }
        } }
        guard bestScore > 0 else { return nil }
        let step = 3.0
        func along(_ x: Double, _ y: Double, _ a: Double, _ reach: Int) -> Float {
            (1...reach).reduce(Float(0)) { $0 + at(x + cos(a) * Double($1), y + sin(a) * Double($1)) }
        }
        func trace(_ best: (x: Double, y: Double, v: Float)) -> [(Double, Double)] {
            // Its direction: the angle along which the line runs furthest.
            let angles = (0..<90).map { Double($0) * .pi / 90 }
            // Read far enough that a railing's bars or a roof's tiles around the click don't outweigh it.
            func both(_ a: Double) -> Float { along(best.x, best.y, a, 40) + along(best.x, best.y, a + .pi, 40) }
            let start = angles.max { both($0) < both($1) }!
            func follow(_ direction: Double) -> [(Double, Double)] {
                var x = best.x, y = best.y, a = direction
                var path: [(Double, Double)] = [], weak = 0
                var strengths: [Float] = [best.v]
                var shifts: [Double] = []
                // Where the path last ran clean, and how long it has crossed texture since.
                var clean = 0, rough = 0
                for _ in 0..<4000 {
                    // The next point a step ahead, then centred on the line across it. A hanging wire bends gently, a
                    // fraction of a degree a step; an edge it meets (a roof, a pole) leaves at an angle, so it is not
                    // taken. Looking well ahead carries it straight past what crosses it.
                    var choice = (a: a, v: Float(-1))
                    for k in rough > 0 ? 0...0 : -3...3 {
                        let b = a + Double(k) * 0.004
                        let v = along(x, y, b, 30)
                        if v > choice.v { choice = (b, v) }
                    }
                    a = choice.a
                    var nx = x + cos(a) * step, ny = y + sin(a) * step
                    let px = -sin(a), py = cos(a)
                    var centre = (o: 0.0, v: at(nx, ny))
                    for o in [-2.0, -1, 1, 2] { let v = at(nx + px * o, ny + py * o); if v > centre.v { centre = (o, v) } }
                    // A wire runs smooth: the tracer seldom has to step sideways to stay on it. Texture (a railing, tiles,
                    // leaves) keeps pulling it sideways; there it goes straight on, and keeps that stretch only if the
                    // line runs clean again within 40 steps.
                    shifts.append(abs(centre.o))
                    let jittery = shifts.count >= 10 && shifts.suffix(10).reduce(0, +) > 10
                    if jittery {
                        if rough == 0 { clean = max(0, path.count - 9) }
                        rough += 1
                        if rough > 40 { path.removeLast(path.count - clean); weak = 0; break }
                    } else {
                        rough = 0
                        nx += px * centre.o; ny += py * centre.o
                    }
                    guard nx >= 0, ny >= 0, nx < Double(W), ny < Double(H) else { break }
                    let typical = strengths.sorted()[strengths.count / 2]
                    // Gaps where the line passes something of its own tone are bridged straight; a long one ends it.
                    if centre.v < 0.35 * typical { weak += 1; if weak > 6 { break } } else { weak = 0; if rough == 0 { strengths.append(centre.v) } }
                    x = nx; y = ny; path.append((x, y))
                }
                if rough > 0 { path.removeLast(path.count - clean); weak = 0 }
                return Array(path.dropLast(weak))
            }
            let forward = follow(start), backward = follow(start + .pi)
            return backward.reversed() + [(best.x, best.y)] + forward
        }
        let path = trace(seed)
        let length = Double(path.count) * step
        // How wide it is: across the line, where it is at least half as strong as at its middle.
        var widths: [Double] = []
        for i in stride(from: 1, to: path.count - 1, by: max(1, path.count / 40)) {
            let (x0, y0) = path[i - 1], (x1, y1) = path[i + 1]
            let len = max(1e-6, hypot(x1 - x0, y1 - y0)), px = -(y1 - y0) / len, py = (x1 - x0) / len
            let (x, y) = path[i], peak = at(x, y)
            guard peak > 0 else { continue }
            var w = 1.0
            for side in [-1.0, 1.0] { var o = 1.0; while o < 12, at(x + px * o * side, y + py * o * side) >= 0.5 * peak { o += 1 }; w += o - 1 }
            widths.append(w)
        }
        let width = widths.isEmpty ? 2 : widths.sorted()[widths.count / 2]
        guard length >= max(80, 25 * width) else { return nil }
        // A wire stands out from what lies either side of it: sky, a wall. An edge in rock, hair or foliage has more
        // of the same beside it.
        var ratios: [Float] = []
        for i in stride(from: 1, to: path.count - 1, by: max(1, path.count / 60)) {
            let (x0, y0) = path[i - 1], (x1, y1) = path[i + 1]
            let len = max(1e-6, hypot(x1 - x0, y1 - y0)), px = -(y1 - y0) / len, py = (x1 - x0) / len
            let (x, y) = path[i], off = width + 4
            let side = max(at(x + px * off, y + py * off), at(x - px * off, y - py * off))
            ratios.append(at(x, y) / max(side, 0.01))
        }
        let contrast = ratios.isEmpty ? 0 : ratios.sorted()[ratios.count / 2]
        guard contrast >= 2 else { return nil }
        // A brush a little wider than the line, its dabs close enough to stay on it.
        let radius = 2 + 0.75 * width
        var points: [MaskPoint] = [], last: (Double, Double)?
        for p in path {
            if let l = last, hypot(p.0 - l.0, p.1 - l.1) < radius * 0.7 { continue }
            points.append(MaskPoint(x: min(1, max(0, p.0 / Double(W))), y: min(1, max(0, 1 - p.1 / Double(H)))))
            last = p
        }
        if let end = path.last, let l = last, end != l { points.append(MaskPoint(x: min(1, max(0, end.0 / Double(W))), y: min(1, max(0, 1 - end.1 / Double(H))))) }
        return (points, min(0.25, radius / Double(min(W, H))))
    }
}
