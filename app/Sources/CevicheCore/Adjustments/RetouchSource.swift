import Foundation
import CoreImage

/// Chooses where a retouch stroke copies from: the nearby clean area whose tone best matches the ring around the
/// stroke, clear of the stroke itself and of the given footprints. Works on linear luminance, row 0 at the top.
public struct RetouchSourceFinder: Sendable {
    let width: Int, height: Int
    let small: [Float], texture: [Float]
    public init?(luminance y: [Float], width w: Int, height h: Int) {
        guard w > 8, h > 8, y.count == w * h else { return nil }
        width = w; height = h
        small = DustFinder.boxBlur(y, w, h, radius: 1)
        var deviation = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { deviation[i] = abs(y[i] - small[i]) }
        texture = DustFinder.boxBlur(deviation, w, h, radius: 2)
    }
    /// Meter the middle of a dab against a ring just outside its edge in linear light.
    /// Medians keep isolated stars or hot pixels from setting a whole spot's exposure.
    func spotExposure(at point: MaskPoint, radius: Double) -> Double {
        let cx = point.x * Double(width), cy = (1 - point.y) * Double(height)
        let r = max(2, radius * Double(min(width, height)))
        var core: [Float] = [], ring: [Float] = []
        let stride = max(1, Int(r / 16))
        for y in Swift.stride(from: max(0, Int(cy - 1.5*r)), through: min(height-1, Int(cy + 1.5*r)), by: stride) {
            for x in Swift.stride(from: max(0, Int(cx - 1.5*r)), through: min(width-1, Int(cx + 1.5*r)), by: stride) {
                let d = hypot(Double(x)+0.5-cx, Double(y)+0.5-cy) / r
                if d <= 0.4 { core.append(small[y*width+x]) }
                else if (1.1...1.5).contains(d) { ring.append(small[y*width+x]) }
            }
        }
        guard !core.isEmpty, !ring.isEmpty else { return 0 }
        let center = max(0.0001, Double(core.sorted()[core.count/2]))
        let background = max(0.0001, Double(ring.sorted()[ring.count/2]))
        return min(2, max(-2, log2(background / center)))
    }
    /// How deep a roughly drawn spot is, in stops: the darkest (or, for a bright spot, brightest) tenth of the circle
    /// against the median just outside it, for a matched Dodge/Burn to go no further.
    func spotDepth(at point: MaskPoint, radius: Double) -> Double {
        let cx = point.x * Double(width), cy = (1 - point.y) * Double(height)
        let r = max(2, radius * Double(min(width, height)))
        var inside: [Float] = [], ring: [Float] = []
        let stride = max(1, Int(r / 16))
        for y in Swift.stride(from: max(0, Int(cy - 1.5*r)), through: min(height-1, Int(cy + 1.5*r)), by: stride) {
            for x in Swift.stride(from: max(0, Int(cx - 1.5*r)), through: min(width-1, Int(cx + 1.5*r)), by: stride) {
                let d = hypot(Double(x)+0.5-cx, Double(y)+0.5-cy) / r
                if d <= 0.85 { inside.append(small[y*width+x]) } else if (1.1...1.5).contains(d) { ring.append(small[y*width+x]) }
            }
        }
        guard !inside.isEmpty, !ring.isEmpty else { return 0 }
        inside.sort(); ring.sort()
        let background = max(0.0001, Double(ring[ring.count/2]))
        let dark = max(0.0001, Double(inside[inside.count/10])), bright = max(0.0001, Double(inside[inside.count*9/10]))
        let dodge = log2(background / dark), burn = log2(background / bright)
        return min(2, max(-2, dodge >= -burn ? dodge : burn))
    }
    /// An area to stay off: points in the retouch frame and a radius as a fraction of the shorter side.
    public struct Footprint: Sendable {
        public var points: [MaskPoint], radius: Double
        public init(points: [MaskPoint], radius: Double) { self.points = points; self.radius = radius }
    }
    /// The source for the stroke's first point. `refused` are earlier sources a refresh moves away from.
    public func source(for points: [MaskPoint], radius: Double, avoiding others: [Footprint] = [], refused: [MaskPoint] = []) -> MaskPoint {
        let w = Double(width), h = Double(height), shorter = Double(min(width, height)), r = radius * shorter
        func pixel(_ p: MaskPoint) -> (x: Double, y: Double) { (p.x * w, (1 - p.y) * h) }
        func at(_ plane: [Float], _ x: Double, _ yy: Double) -> Float { plane[min(height - 1, max(0, Int(yy))) * width + min(width - 1, max(0, Int(x)))] }
        func fits(_ v: Double, _ side: Double) -> Bool { v >= r && v <= side - r }
        let path = Self.sampled(points.map(pixel), spacing: max(1, r))
        let origin = path[0]
        let blocked = others.map { other in (points: Self.sampled(other.points.map(pixel), spacing: max(1, other.radius * shorter)), r: other.radius * shorter) }
        let refusedPixels = refused.map(pixel)
        // Tone just outside the footprint, which is what the patch has to blend into.
        var ring: Float = 0, ringCount = 0
        for c in path { for k in 0..<16 {
            let a = Double(k) * .pi / 8, x = c.x + cos(a) * r * 1.3, y = c.y + sin(a) * r * 1.3
            if path.contains(where: { hypot($0.x - x, $0.y - y) < r }) { continue }
            ring += at(small, x, y); ringCount += 1
        } }
        ring = max(ringCount > 0 ? ring / Float(ringCount) : at(small, origin.x, origin.y), 0.0005)
        var best: (score: Float, x: Double, y: Double)?
        // Each direction starts where the moved path first clears the footprint (2.2 radii for a dab).
        let directions = (0..<12).map { k -> (ux: Double, uy: Double, clear: Double) in
            let a = Double(k) * .pi / 6
            return (cos(a), sin(a), Self.clearance(path, cos(a), sin(a), gap: 2.2 * r))
        }
        for distance in [2.2, 3.0, 4.0] { for (ux, uy, clear) in directions {
            let length: Double = clear + (distance - 2.2) * r
            let dx: Double = ux * length, dy: Double = uy * length
            let shifted = path.map { (x: $0.x + dx, y: $0.y + dy) }
            guard shifted.allSatisfy({ fits($0.x, w) && fits($0.y, h) }) else { continue }
            // A source covering another spot would copy that spot here.
            if blocked.contains(where: { other in shifted.contains { s in other.points.contains { hypot($0.x - s.x, $0.y - s.y) < r + other.r } } }) { continue }
            if refusedPixels.contains(where: { hypot($0.x - origin.x - dx, $0.y - origin.y - dy) < r }) { continue }
            var tone: Float = 0, detail: Float = 0
            for s in shifted {
                for (ox, oy) in [(0.0, 0.0), (0.6, 0), (-0.6, 0), (0, 0.6), (0, -0.6), (0.42, 0.42), (-0.42, 0.42), (0.42, -0.42), (-0.42, -0.42)] {
                    tone += at(small, s.x + ox * r, s.y + oy * r); detail += at(texture, s.x + ox * r, s.y + oy * r)
                }
            }
            let n = Float(9 * shifted.count)
            let score = detail / n / ring + 2 * abs(tone / n - ring) / ring + Float(distance) * 0.01
            if best == nil || score < best!.score { best = (score, origin.x + dx, origin.y + dy) }
        } }
        if let best { return MaskPoint(x: best.x / w, y: 1 - best.y / h) }
        let side = origin.x < w / 2 ? 1.0 : -1.0
        return MaskPoint(x: min(1, max(0, (origin.x + side * (Self.clearance(path, side, 0, gap: 2.2 * r) + 0.3 * r)) / w)), y: points[0].y)
    }
    /// The shortest move along the unit direction after which no point of the path is within `gap` of one where it was.
    static func clearance(_ path: [(x: Double, y: Double)], _ ux: Double, _ uy: Double, gap: Double) -> Double {
        var blocked: [(lo: Double, hi: Double)] = []
        for p in path { for q in path {
            let qx = q.x - p.x, qy = q.y - p.y, along = qx * ux + qy * uy, across = abs(qx * uy - qy * ux)
            guard across < gap else { continue }
            let half = (gap * gap - across * across).squareRoot()
            blocked.append((along - half, along + half))
        } }
        var t = 0.0
        for interval in blocked.sorted(by: { $0.lo < $1.lo }) {
            if interval.lo > t { break }
            t = max(t, interval.hi)
        }
        return t
    }
    /// The path's points no further apart than `spacing`, dropping the ones closer than that (a dab stays one point).
    static func sampled(_ points: [(x: Double, y: Double)], spacing: Double) -> [(x: Double, y: Double)] {
        guard var last = points.first else { return [] }
        var result = [last]
        for p in points.dropFirst() where hypot(p.x - last.x, p.y - last.y) >= spacing { result.append(p); last = p }
        if let end = points.last, result.count > 1 || points.count > 1, hypot(end.x - last.x, end.y - last.y) > 0 { result.append(end) }
        return result
    }
}

extension RawRenderer {
    public func spotExposures(for strokes: [RetouchStroke], settings: Adjustments) throws -> [UUID: Double] {
        guard !strokes.isEmpty else { return [:] }
        let ids = Set(strokes.map(\.id))
        var base = settings
        base.retouch.removeAll { ids.contains($0.id) }
        guard let finder = try retouchSourceFinder(base) else { throw EditorError.render }
        var result: [UUID: Double] = [:]
        for stroke in strokes {
            guard let point = stroke.points.first else { continue }
            result[stroke.id] = stroke.matchesTone ? finder.spotDepth(at: point, radius: stroke.radius) : finder.spotExposure(at: point, radius: stroke.radius)
        }
        return result
    }
    /// A source for `stroke` on the photo as developed, without the stroke itself, clear of the hand-drawn strokes.
    public func retouchSource(for stroke: RetouchStroke, settings: Adjustments, refused: [MaskPoint] = []) throws -> MaskPoint {
        guard let source = try retouchSources(for: [stroke], settings: settings, refused: [stroke.id: refused])[stroke.id] else { throw EditorError.render }
        return source
    }
    /// Sources for several strokes from one look at the photo without any of them, each clear of the other hand-drawn
    /// strokes and of the sources it was `refused`.
    public func retouchSources(for strokes: [RetouchStroke], settings: Adjustments, refused: [UUID: [MaskPoint]] = [:]) throws -> [UUID: MaskPoint] {
        let ids = Set(strokes.map(\.id))
        var base = settings
        base.retouch.removeAll { ids.contains($0.id) }
        guard let finder = try retouchSourceFinder(base) else { throw EditorError.render }
        let drawn = settings.retouch.filter { $0.enabled && !$0.suggested }
        var sources: [UUID: MaskPoint] = [:]
        for stroke in strokes {
            let others = drawn.filter { $0.id != stroke.id }.map { RetouchSourceFinder.Footprint(points: $0.points, radius: $0.radius) }
            sources[stroke.id] = finder.source(for: stroke.points, radius: stroke.radius, avoiding: others, refused: refused[stroke.id] ?? [])
        }
        return sources
    }
    func retouchSourceFinder(_ settings: Adjustments) throws -> RetouchSourceFinder? {
        let image = try dustImage(settings, maxDimension: DustFinder.sourceSize)
        var luminance = [Float](repeating: 0, count: image.width * image.height)
        let linear = (0..<256).map { v -> Float in let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        image.pixels.withUnsafeBufferPointer { p in
            for i in luminance.indices {
                luminance[i] = 0.2126 * linear[Int(p[i * 4])] + 0.7152 * linear[Int(p[i * 4 + 1])] + 0.0722 * linear[Int(p[i * 4 + 2])]
            }
        }
        return RetouchSourceFinder(luminance: luminance, width: image.width, height: image.height)
    }
}
