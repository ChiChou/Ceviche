import Foundation
import CoreImage
import DustRemoval

/// Finds dust on the Visualize Spots map (a black top-hat of log luminance) at three scales, so a large soft spot is
/// searched on a frame small enough for it to look like a small one. A spot is a round patch that stands out from the
/// map around it: noise, texture and the edges of dark subjects light up their surroundings as well.
extension DustFinder {
    struct MapLevel: Sendable {
        /// Of the searched frame; the blur and closing below are in pixels at this scale.
        var scale: Double
        /// How many times the spot's peak must exceed the map's median on a ring around it.
        var minScore: Float
    }
    /// Tuned on a tripod stack of 18 frames at f/22 (dust confirmed by the mean of their maps) and a single frame with
    /// spots of radius 25–35 px. The finest level only lets through very distinct spots; noise blobs are its size.
    static let mapLevels = [MapLevel(scale: 1, minScore: 20), MapLevel(scale: 0.5, minScore: 10), MapLevel(scale: 0.25, minScore: 12)]
    static let mapSmoothing = 1.5, mapClosing = 24.0
    /// A find's equivalent radius, in pixels of its level: smaller is noise.
    static let mapMinRadius = 3.5
    /// The faintest darkening worth healing at sensitivity 0.5, in stops below the surroundings (about 2.5 %): dust
    /// fainter than this hardly shows, even on a clear sky. Sensitivity scales it like the scores.
    static let mapVisiblePeak: Float = 0.035
    /// Dust darkens softly; a find this many stops below its surroundings is a dark subject.
    static let mapMaxPeak: Float = 1

    struct MapFind: Equatable { var x: Double; var y: Double; var radius: Double; var peak: Float; var score: Float }

    /// Spots found on the map, on an image in the retouch frame (row 0 at the top).
    static func mapSpots(in image: RGBAImage, options: Options, context: CIContext) -> [DustSpot] {
        guard image.width > 0, image.height > 0,
              let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let source = CIImage(cgImage: cg)
        // Sensitivity 0.5 is the tuned threshold; 0 asks half again as much, 1 two thirds of it.
        let factor = Float(pow(1.5, 1 - 2 * min(1, max(0, options.sensitivity))))
        var finds: [MapFind] = []
        for level in mapLevels {
            guard let map = topHatMap(source, scale: level.scale, minPeak: DustFinder.mapVisiblePeak * factor, context: context) else { continue }
            let f = Double(image.width) / Double(map.width)
            finds += mapFinds(map, minScore: level.minScore * factor, minPeak: DustFinder.mapVisiblePeak * factor)
                .map { MapFind(x: $0.x * f, y: $0.y * f, radius: $0.radius * f, peak: $0.peak, score: $0.score) }
        }
        // Largest first: a smaller find inside an accepted one is the same spot seen on a finer level.
        var kept: [MapFind] = []
        for find in finds.sorted(by: { $0.radius > $1.radius }) where !kept.contains(where: { hypot($0.x - find.x, $0.y - find.y) < $0.radius + 2 }) {
            kept.append(find)
        }
        let w = Double(image.width), h = Double(image.height), shorter = min(w, h)
        return kept.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map {
            // The find is where the map clears the lower threshold; the soft edge of the spot reaches further.
            DustSpot(center: MaskPoint(x: $0.x / w, y: 1 - $0.y / h), radius: max($0.radius * 1.4 + 2, options.spotSize) / shorter)
        }
    }

    /// A searched level: per pixel the map (stops below the closing), the blurred log2 luminance, the map's mean over
    /// `mapLocalRadius` and the log2 of the brightest channel, interleaved, row 0 at the top; and where a spot may
    /// start (nonzero), which the GPU works out so the search skips straight to them.
    struct MapPlanes {
        var pixels: [Float]; var width: Int; var height: Int
        var seeds: [UInt8]? = nil
        var values: [Float] { (0..<(width * height)).map { pixels[$0 * 4] } }
        var luminance: [Float] { (0..<(width * height)).map { pixels[$0 * 4 + 1] } }
    }
    static let mapLocalRadius = 40.0
    /// Dust worth healing shows on a bright, clear background (sky, a wall, a backdrop); darker tones hide it and are
    /// mostly texture. Log2 of the brightest linear channel (a deep blue sky is dark in luminance alone): about 12 %.
    static let mapBrightFloor: Float = -3

    /// The map of `source` scaled by `scale`, with its luminance and local mean, all made on the GPU.
    static func topHatMap(_ source: CIImage, scale: Double, minPeak: Float = 0.012, context: CIContext) -> MapPlanes? {
        var image = source
        if scale < 1 { image = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1]) }
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 8, h > 8 else { return nil }
        image = image.clampedToExtent().cropped(to: extent)
        let hat = DustVisualizer.topHat(image, smoothing: mapSmoothing, radius: mapClosing)
        let local = hat.clampedToExtent().applyingFilter("CIBoxBlur", parameters: ["inputRadius": mapLocalRadius * 2 + 1]).cropped(to: extent)
        let planes = mapKernels.planes.apply(extent: extent, arguments: [hat, local, image])!
        let seeds = mapKernels.seeds.apply(extent: extent, arguments: [planes, mapBrightFloor, max(0.012, minPeak)])!
        var pixels = [Float](repeating: 0, count: w * h * 4), flags = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { context.render(planes, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil) }
        flags.withUnsafeMutableBytes { context.render(seeds, toBitmap: $0.baseAddress!, rowBytes: w, bounds: extent, format: .R8, colorSpace: nil) }
        return MapPlanes(pixels: pixels, width: w, height: h, seeds: flags)
    }
    private static let mapKernels: (planes: CIColorKernel, seeds: CIColorKernel) = {
        let all = try! CIColorKernel.kernels(withMetalString: """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            extern "C" [[ stitchable ]] float4 dustMapPlanes(coreimage::sample_t hat, coreimage::sample_t local, coreimage::sample_t image) {
                return float4(hat.r, hat.g, local.r, log2(max(max(max(image.r, image.g), image.b), 1e-4)));
            }
            extern "C" [[ stitchable ]] float4 dustMapSeeds(coreimage::sample_t p, float floor, float minPeak) {
                // A spot's peak must reach minPeak, so only such pixels need to start one.
                float seed = p.r >= max(minPeak, 4.0 * p.b) && p.a >= floor ? 1.0 : 0.0;
                return float4(seed, seed, seed, 1);
            }
            """) as! [CIColorKernel]
        return (all.first { $0.name == "dustMapPlanes" }!, all.first { $0.name == "dustMapSeeds" }!)
    }()

    /// Round patches of a map that stand out from their surroundings, in pixels of the map. Seeds are where the map
    /// exceeds four times its local mean (and `minPeak`) on a bright background; each grows down to half of that.
    static func mapFinds(_ planes: MapPlanes, minScore: Float, minPeak: Float) -> [MapFind] {
        let w = planes.width, h = planes.height
        let seeds = planes.seeds ?? (0..<(w * h)).map { i in
            let v = planes.pixels[i * 4]
            return v >= max(0.012, minPeak) && v >= 4 * planes.pixels[i * 4 + 2] && planes.pixels[i * 4 + 3] >= mapBrightFloor ? 255 : 0
        }
        return planes.pixels.withUnsafeBufferPointer { p in seeds.withUnsafeBufferPointer { seedFlags in
            var visited = [Bool](repeating: false, count: w * h)
            return visited.withUnsafeMutableBufferPointer { visited in
                let maxRadius = mapClosing * 0.8
                // A fill past the largest spot is texture or a subject: stop it there rather than flood the facade.
                let maxArea = Int(Double.pi * maxRadius * maxRadius) + 1
                var stack: [Int] = []
                var finds: [MapFind] = []
                /// Means of the map and the luminance over a box, clipped to the frame.
                func boxMeans(_ cx: Int, _ cy: Int, _ half: Int) -> (map: Float, luminance: Float, brightest: Float)? {
                    let x0 = max(0, cx - half), y0 = max(0, cy - half), x1 = min(w - 1, cx + half), y1 = min(h - 1, cy + half)
                    guard x1 >= x0, y1 >= y0 else { return nil }
                    var m: Float = 0, l: Float = 0, b: Float = 0
                    for y in y0...y1 { var i = (y * w + x0) * 4; for _ in x0...x1 { m += p[i]; l += p[i + 1]; b += p[i + 3]; i += 4 } }
                    let n = Float((x1 - x0 + 1) * (y1 - y0 + 1))
                    return (m / n, l / n, b / n)
                }
                // memchr walks the seed flags far faster than a loop would, and seeds are rare.
                let base = seedFlags.baseAddress!, count = w * h
                var next = 0
                while next < count, let hit = memchr(base + next, 255, count - next) {
                    let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    next = start + 1
                    guard !visited[start] else { continue }
                    let low = max(0.006, 2 * p[start * 4 + 2])
                    visited[start] = true; stack.removeAll(keepingCapacity: true); stack.append(start)
                    var area = 0, minX = w, minY = h, maxX = 0, maxY = 0
                    var peak: Float = 0, peakIndex = start, sum = 0.0, sx = 0.0, sy = 0.0
                    var tooLarge = false
                    while let i = stack.popLast() {
                        if area > maxArea { tooLarge = true; break }
                        let x = i % w, y = i / w, v = p[i * 4]
                        area += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        if v > peak { peak = v; peakIndex = i }
                        sum += Double(v); sx += Double(v) * Double(x); sy += Double(v) * Double(y)
                        for ny in max(0, y - 1)...min(h - 1, y + 1) {
                            for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                let j = ny * w + nx
                                if !visited[j] && p[j * 4] >= low { visited[j] = true; stack.append(j) }
                            }
                        }
                    }
                    guard !tooLarge else { continue }
                    let r = (Double(area) / .pi).squareRoot()
                    guard r >= mapMinRadius, r <= maxRadius, peak >= minPeak, peak <= mapMaxPeak else { continue }
                    let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
                    guard max(bw, bh) / min(bw, bh) <= 2.2, Double(area) / (bw * bh) >= 0.45 else { continue }
                    // The surroundings as medians of small box means on two circles, so a bright subject on one side (which
                    // lifts the map there) does not hide a spot beside it.
                    let cx = sx / sum, cy = sy / sum, half = max(1, Int(r / 2))
                    var ring: [Float] = [], ringLuminance: [Float] = [], ringBrightest: [Float] = []
                    for (radius, phase) in [(2.5 * r + 2, 0.0), (3.5 * r + 3, Double.pi / 8)] {
                        for k in 0..<8 {
                            let px = Int(cx + radius * cos(Double(k) * .pi / 4 + phase)), py = Int(cy + radius * sin(Double(k) * .pi / 4 + phase))
                            if let means = boxMeans(px, py, half) { ring.append(means.map); ringLuminance.append(means.luminance); ringBrightest.append(means.brightest) }
                        }
                    }
                    guard ring.count >= 8 else { continue }
                    let surround = ring.sorted()[ring.count / 2], background = ringLuminance.sorted()[ringLuminance.count / 2]
                    // Dust is darker than the tone around it, and that tone is bright. Sky in a narrow gap between bright
                    // subjects lights the map (the closing bridges the gap) but is no darker than the sky beside it.
                    guard ringBrightest.sorted()[ringBrightest.count / 2] >= mapBrightFloor, background - p[peakIndex * 4 + 1] >= 0.5 * peak else { continue }
                    let score = peak / max(0.002, surround)
                    guard score >= minScore else { continue }
                    finds.append(MapFind(x: cx + 0.5, y: cy + 0.5, radius: r, peak: peak, score: score))
                }
                return finds
            }
        } }
    }
}
