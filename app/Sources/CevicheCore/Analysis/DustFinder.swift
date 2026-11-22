import Foundation
import CoreImage
import DustRemoval

/// A dust spot under review: found by a locator or placed by hand, moved and resized on the photo, then healed.
public struct DustSpot: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// Normalized, in the retouch coordinate frame (before geometry; y up).
    public var center: MaskPoint
    /// Radius of the heal footprint as a fraction of the shorter image side, like a retouch brush.
    public var radius: Double
    public init(center: MaskPoint, radius: Double) {
        self.center = center; self.radius = DustFinder.clampedRadius(radius)
    }
}

public enum DustFinder {
    public struct Options: Equatable, Sendable {
        /// Expected dust radius in pixels at `classicSize`; every detector size derives from it.
        public var spotSize = 6.0
        /// 0 finds only strong spots, 1 also faint ones.
        public var sensitivity = 0.5
        /// For high ISO and night skies, smooth first and drop the dark-structure guard (the sky is the darkest thing).
        public var nightSky = false
        /// Search the Visualize Spots map (`mapSpots`), at every spot size and only on bright, clear backgrounds;
        /// otherwise the classic detector.
        public var onMap = false
        public init(spotSize: Double = 6, sensitivity: Double = 0.5, nightSky: Bool = false, onMap: Bool = false) {
            self.spotSize = spotSize; self.sensitivity = sensitivity; self.nightSky = nightSky; self.onMap = onMap
        }
        var classicParameters: DustRemovalParameters {
            // Sensitivity 0.5 is the reference implementation's offset of 10 grey levels (15 for night frames, above their noise).
            let offset = Int(((nightSky ? 21 : 16) - 12 * min(1, max(0, sensitivity))).rounded())
            var p = DustRemovalParameters(dustRadius: spotSize, sensitivity: offset)
            if nightSky { p.smoothingRadius = 2; p.globalDarkRatio = 0 }
            return p
        }
    }
    /// The classic detector's sizes were tuned on 10 MP frames; larger photos are scanned at this long side.
    public static let classicSize = 4000.0
    /// Source choice needs only coarse tone and texture.
    static let sourceSize = 2000.0
    /// Strokes the retouch list holds (`Adjustments.validated`).
    public static let strokeLimit = 200
    static func clampedRadius(_ radius: Double) -> Double { min(0.25, max(0.001, radius)) }

    /// Spots from the classic detector, on an image in the retouch frame (row 0 at the top).
    static func classicSpots(in image: RGBAImage, options: Options) throws -> [DustSpot] {
        let detection = try DustRemover().detect(in: image, parameters: options.classicParameters)
        let w = Double(image.width), h = Double(image.height), shorter = min(w, h)
        return detection.blobs.map { blob in
            // The seeds are the spot's dark core; the blob around them is grown by the dilation.
            let cx = Double(blob.seedMinX + blob.seedMaxX + 1) / 2, cy = Double(blob.seedMinY + blob.seedMaxY + 1) / 2
            let core = Double(max(blob.seedMaxX - blob.seedMinX, blob.seedMaxY - blob.seedMinY) + 1) / 2
            return DustSpot(center: MaskPoint(x: cx / w, y: 1 - cy / h), radius: max(core * 1.6 + 2, options.spotSize) / shorter)
        }
    }

    /// A suggested heal stroke per spot, each sampling the nearby clean patch whose tone best matches the ring around
    /// the spot and which overlaps no other spot. `luminance` is linear, row 0 at the top.
    public static func strokes(for spots: [DustSpot], luminance y: [Float], width w: Int, height h: Int) -> [RetouchStroke] {
        guard let finder = RetouchSourceFinder(luminance: y, width: w, height: h) else { return [] }
        return strokes(for: spots, finder: finder)
    }
    static func strokes(for spots: [DustSpot], finder: RetouchSourceFinder) -> [RetouchStroke] {
        let footprints = spots.map { RetouchSourceFinder.Footprint(points: [$0.center], radius: $0.radius) }
        return spots.indices.map { index in
            let others = footprints.indices.filter { $0 != index }.map { footprints[$0] }
            let source = finder.source(for: [spots[index].center], radius: spots[index].radius, avoiding: others)
            var stroke = RetouchStroke(mode: .heal, source: source, target: spots[index].center, radius: clampedRadius(spots[index].radius), softness: 0.4, opacity: 1)
            stroke.suggested = true
            return stroke
        }
    }

    static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        for row in 0..<h {
            var sum: Float = 0; let base = row * w
            for x in 0..<min(w, r) { sum += src[base + x] }
            for x in 0..<w {
                let hi = x + r, lo = x - r - 1
                if hi < w { sum += src[base + hi] }
                if lo >= 0 { sum -= src[base + lo] }
                tmp[base + x] = sum / Float(min(w - 1, x + r) - max(0, x - r) + 1)
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for row in 0..<min(h, r) { sum += tmp[row * w + x] }
            for row in 0..<h {
                let hi = row + r, lo = row - r - 1
                if hi < h { sum += tmp[hi * w + x] }
                if lo >= 0 { sum -= tmp[lo * w + x] }
                out[row * w + x] = sum / Float(min(h - 1, row + r) - max(0, row - r) + 1)
            }
        }
        return out
    }
}

extension RawRenderer {
    /// Finds dust in the photo as developed and already retouched (so healed spots are not found again), without masks
    /// or geometry so the spots land in the retouch frame: on the Visualize Spots map when `options.onMap`, otherwise
    /// with the classic detector.
    public func findDust(_ settings: Adjustments, options: DustFinder.Options) throws -> [DustSpot] {
        let image = try dustImage(settings, maxDimension: DustFinder.classicSize)
        if options.onMap { return DustFinder.mapSpots(in: image, options: options, context: context) }
        return try DustFinder.classicSpots(in: image, options: options)
    }
    /// Heal strokes for reviewed spots, with sources chosen on the photo as developed.
    public func dustStrokes(_ spots: [DustSpot], settings: Adjustments, tonal: Bool = false) throws -> [RetouchStroke] {
        guard !spots.isEmpty else { return [] }
        guard let finder = try retouchSourceFinder(settings) else { return [] }
        if tonal {
            return spots.map { spot in
                var stroke = RetouchStroke(mode: .tone, source: spot.center, target: spot.center,
                                           radius: DustFinder.clampedRadius(spot.radius), softness: 0.9, opacity: 1)
                stroke.exposure = finder.spotDepth(at: spot.center, radius: spot.radius)
                stroke.suggested = true
                return stroke
            }
        }
        return DustFinder.strokes(for: spots, finder: finder)
    }
    /// The photo in the retouch frame as 8-bit sRGB, row 0 at the top.
    func dustImage(_ settings: Adjustments, maxDimension: Double) throws -> RGBAImage {
        var base = settings
        base.masks = []; base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.postCropVignette = PostCropVignette()
        let image = try pipeline(base, maxDimension: maxDimension)
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw EditorError.render }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return RGBAImage(width: w, height: h, pixels: pixels)
    }
}
