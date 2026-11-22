import Foundation
import CoreGraphics
import CoreImage
import Metal
import simd

/// Hot pixels, and the gaps a series of exposures leaves between frames.
extension NightSkyAnalyzer {
    /// Sensor defects, found before anything is resampled: a pixel standing well above its neighbors in the first, the
    /// middle and the last photo alike. Stars move between those, a hot pixel doesn't. Needs the sky to have moved a few
    /// pixels between them, so a sequence shorter than a minute is left alone.
    func findHotPixels(checked: (Int) -> Void) throws -> [Int] {
        let picks = Array(Set([0, anchor, count - 1])).sorted()
        guard picks.count == 3, let first = metadata[picks[0]].midpoint, let last = metadata[picks[2]].midpoint, last - first >= 60 else { return [] }
        var persistent: Set<Int>?
        for i in picks {
            if Task.isCancelled { throw CancellationError() }
            let found = try autoreleasepool { () -> Set<Int> in
                if let gpu {
                    let image = try HDRMergeDecoder.developedImage(urls[i], metadata: metadata[i].base, longEdge: nil, whiteBalance: whiteBalance)
                    // Nil when the frame is too noisy to have a sensor's few defects: it then marks nothing.
                    return Set(try gpu.spikes(image, context: context) ?? [])
                }
                let frame = try HDRMergeDecoder.decode(urls[i], metadata: metadata[i].base, longEdge: nil, whiteBalance: whiteBalance, context: context)
                return Set(Self.spikes(frame.pixels, width: frame.width, height: frame.height))
            }
            persistent = persistent.map { $0.intersection(found) } ?? found
            checked(picks.firstIndex(of: i)! + 1)
            if persistent?.isEmpty == true { return [] }
        }
        return Array(persistent ?? []).sorted().prefix(100_000).map { $0 }
    }

    /// Pixels whose luminance tops their eight neighbors and stands more than eight noise deviations above the median of
    /// the ring two pixels out (demosaicing spreads a defect into its neighbors).
    static func spikes(_ rgba: [Float], width w: Int, height h: Int) -> [Int] {
        guard w > 8, h > 8 else { return [] }
        func l(_ i: Int) -> Float { 0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2] }
        let ring = [(-2, -2), (-1, -2), (0, -2), (1, -2), (2, -2), (-2, 2), (-1, 2), (0, 2), (1, 2), (2, 2), (-2, -1), (-2, 0), (-2, 1), (2, -1), (2, 0), (2, 1)]
        func excess(_ i: Int) -> Float {
            var values = ring.map { l(i + $0.1 * w + $0.0) }
            values.sort()
            return l(i) - (values[7] + values[8]) / 2
        }
        // Noise of that excess, from a sample of the whole frame.
        var sample: [Double] = []
        for y in stride(from: 4, to: h - 4, by: 37) { for x in stride(from: 4, to: w - 4, by: 41) { sample.append(Double(excess(y * w + x))) } }
        let sigma = spikeNoise(sample)
        var rows = [[Int]](repeating: [], count: h)
        rows.withUnsafeMutableBufferPointer { rows in
            let rows = rows
            DispatchQueue.concurrentPerform(iterations: h - 4) { r in
                let y = r + 2
                for x in 2..<(w - 2) {
                    let i = y * w + x, v = l(i)
                    guard v > l(i - 1), v > l(i + 1), v > l(i - w), v > l(i + w), v > l(i - w - 1), v > l(i - w + 1), v > l(i + w - 1), v > l(i + w + 1),
                          excess(i) > 8 * sigma else { continue }
                    rows[y].append(i)
                }
            }
        }
        return Array(rows.joined())
    }

    /// The deviation of the spike excess, robustly, from a sample across the frame.
    static func spikeNoise(_ sample: [Double]) -> Float {
        let center = NightSkyStars.median(sample)
        return Float(max(1e-6, 1.4826 * NightSkyStars.median(sample.map { abs($0 - center) })))
    }

    /// Repairs hot pixels in a full-size result, in place: where one still stands out, it and the neighbors it raised take
    /// the median of the ring around them. Where the result shows warped sky there, nothing stands out and nothing changes.
    func repairHotPixels(_ raster: inout PanoramaRaster) {
        let w = raster.width, h = raster.height
        guard !hotPixels.isEmpty, w == width, h == height else { return }
        let ring = [(-2, -2), (-1, -2), (0, -2), (1, -2), (2, -2), (-2, 2), (-1, 2), (0, 2), (1, 2), (2, 2), (-2, -1), (-2, 0), (-2, 1), (2, -1), (2, 0), (2, 1)]
        raster.rgba.withUnsafeMutableBufferPointer { rgba in
            func l(_ i: Int) -> Float { 0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2] }
            for i in hotPixels {
                let x = i % w, y = i / w
                guard x >= 2, y >= 2, x < w - 2, y < h - 2 else { continue }
                var median = SIMD3<Float>.zero
                for c in 0..<3 {
                    var values = ring.map { rgba[4 * (i + $0.1 * w + $0.0) + c] }
                    values.sort()
                    median[c] = (values[7] + values[8]) / 2
                }
                let base = simd_dot(median, SIMD3(0.2126, 0.7152, 0.0722))
                let spread = ring.map { abs(l(i + $0.1 * w + $0.0) - base) }.sorted()[8] * 1.4826
                let excess = l(i) - base
                guard excess > max(4 * spread, 1e-4) else { continue }
                for dy in -1...1 { for dx in -1...1 {
                    let j = i + dy * w + dx
                    guard dx == 0 && dy == 0 || l(j) - base > 0.25 * excess else { continue }
                    for c in 0..<3 { rgba[4 * j + c] = median[c] }
                }}
            }
        }
    }

    /// Where the sky at `a` (photo `i`'s pixels, analysis size) has moved to in photo `j`, minus `a`.
    func motion(from i: Int, to j: Int, at a: SIMD2<Double>) -> SIMD2<Double>? {
        guard let from = alignments[i], let to = alignments[j] else { return nil }
        return (j == anchor ? from.apply(a) : to.sourcePoint(i == anchor ? a : from.apply(a))) - a
    }

    /// The motion from photo `i` to `j` across the frame, sampled on a coarse grid and interpolated: it varies slowly.
    func gapField(from i: Int, to j: Int) -> (SIMD2<Double>) -> SIMD2<Double> {
        let gw = 17, gh = 12, aw = Double(analysisWidth - 1), ah = Double(analysisHeight - 1)
        let grid: [SIMD2<Double>] = (0..<(gw * gh)).map { g in
            motion(from: i, to: j, at: SIMD2(aw * Double(g % gw) / Double(gw - 1), ah * Double(g / gw) / Double(gh - 1))) ?? .zero
        }
        return { a in
            let u = a.x / aw * Double(gw - 1), v = a.y / ah * Double(gh - 1)
            let x0 = max(0, min(gw - 2, Int(u))), y0 = max(0, min(gh - 2, Int(v)))
            let fx = max(0, min(1, u - Double(x0))), fy = max(0, min(1, v - Double(y0)))
            return (grid[y0 * gw + x0] * (1 - fx) + grid[y0 * gw + x0 + 1] * fx) * (1 - fy)
                 + (grid[(y0 + 1) * gw + x0] * (1 - fx) + grid[(y0 + 1) * gw + x0 + 1] * fx) * fy
        }
    }

    /// The fractions of the motion from photo `i` to `j` (midpoint to midpoint) that fall in the pause between their
    /// exposures, one per full-size pixel the stars travel; empty without a pause or without both alignments.
    func gapSteps(from i: Int, to j: Int) -> [Float] {
        guard let mi = metadata[i].midpoint, let mj = metadata[j].midpoint, mj > mi else { return [] }
        let span = mj - mi
        let start = (metadata[i].exposure ?? 0) / 2 / span, end = 1 - (metadata[j].exposure ?? 0) / 2 / span
        guard end - start > 0.01 else { return [] }
        var farthest = 0.0
        for gy in 0...4 { for gx in 0...4 {
            let a = SIMD2(Double(analysisWidth - 1) * Double(gx) / 4, Double(analysisHeight - 1) * Double(gy) / 4)
            guard let d = motion(from: i, to: j, at: a) else { return [] }
            farthest = max(farthest, simd_length(d))
        }}
        let count = min(200, max(1, Int((farthest * scale * (end - start)).rounded(.up))))
        return (0..<count).map { Float(start + (end - start) * (Double($0) + 0.5) / Double(count)) }
    }

    /// The photos a photo's lines are searched against: five in a row around it, kept inside the sequence so the first
    /// and last photos also have four neighbors.
    static func window(_ i: Int, count: Int) -> ClosedRange<Int> {
        let low = max(0, min(i - 2, count - 5))
        return low...min(count - 1, low + 4)
    }

    /// The prediction for photo `i` from the nearest aligned photos between it and the anchor, extrapolated by capture time.
    func prediction(for i: Int) -> NightSkyAlignment? {
        let step = i > anchor ? -1 : 1
        var near: [Int] = []
        var j = i + step
        while near.count < 2, (min(i, anchor)...max(i, anchor)).contains(j) {
            if alignments[j] != nil { near.append(j) }
            j += step
        }
        guard let first = near.first, let a = alignments[first] else { return nil }
        guard near.count == 2, let b = alignments[near[1]], let now = metadata[i].midpoint,
              let t1 = metadata[first].midpoint, let t0 = metadata[near[1]].midpoint, abs(t1 - t0) > 0.1 else { return a }
        return a.extrapolated(from: b, factor: (now - t1) / (t1 - t0))
    }

    /// One photo developed at analysis size: RGBA top row first, and its image for the sky model.
    func developAnalysis(_ i: Int) throws -> (CIImage, [Float]) {
        try autoreleasepool {
            let image = try HDRMergeDecoder.developedImage(urls[i], metadata: metadata[i].base, longEdge: Self.analysisLongEdge, whiteBalance: whiteBalance)
            let w = Int(image.extent.width.rounded(.down)), h = Int(image.extent.height.rounded(.down))
            if analysisWidth > 0, w != analysisWidth || h != analysisHeight {
                throw PanoramaError.message(L10n.tr("\(metadata[i].filename) develops at a different size from the other photos."))
            }
            var rgba = [Float](repeating: 0, count: w * h * 4)
            rgba.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            for k in rgba.indices where !rgba[k].isFinite { rgba[k] = 0 }
            return (image, rgba)
        }
    }

    struct Developed {
        var luminance: [Float]
        /// RGB at preview size, as developed (gain not applied).
        var preview: [Float]
        var stars: [NightSkyStar]
        var background: Float
    }

    func develop(_ i: Int, rgba: [Float], interior: [Float]) throws -> Developed {
        let aw = analysisWidth, ah = analysisHeight
        let luminance = Self.luminance(rgba, gain: gains[i])
        let stars = try NightSkyStars.detect(luminance, width: aw, height: ah, mask: skyValid, gpu: gpu)
        var samples: [Double] = []
        for k in stride(from: 0, to: luminance.count, by: 37) where interior[k] > 0.5 { samples.append(Double(luminance[k])) }
        let preview = Self.downsample(rgba, channels: 4, width: aw, height: ah, to: previewWidth, previewHeight, keep: 3)
        return Developed(luminance: luminance, preview: preview, stars: stars, background: Float(NightSkyStars.median(samples)))
    }

    static func luminance(_ rgba: [Float], gain: Float) -> [Float] {
        var out = [Float](repeating: 0, count: rgba.count / 4)
        out.withUnsafeMutableBufferPointer { out in
            rgba.withUnsafeBufferPointer { rgba in
                for i in out.indices { out[i] = gain * (0.2126 * rgba[4 * i] + 0.7152 * rgba[4 * i + 1] + 0.0722 * rgba[4 * i + 2]) }
            }
        }
        return out
    }

    /// `HDRMerger.boxBlur` and `minFilter`, on the GPU when there is one.
    func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) throws -> [Float] {
        try gpu?.filter(values, width: width, height: height, radius: radius) ?? HDRMerger.boxBlur(values, width: width, height: height, radius: radius)
    }
    func minFilter(_ values: [Float], width: Int, height: Int, radius: Int) throws -> [Float] {
        try gpu?.filter(values, width: width, height: height, radius: radius, minimum: true) ?? HDRMerger.minFilter(values, width: width, height: height, radius: radius)
    }

    /// Area average to a smaller grid, keeping the first `keep` channels.
    static func downsample(_ values: [Float], channels: Int, width: Int, height: Int, to w: Int, _ h: Int, keep: Int? = nil) -> [Float] {
        let keep = keep ?? channels
        var out = [Float](repeating: 0, count: w * h * keep)
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        out.withUnsafeMutableBufferPointer { out in
            values.withUnsafeBufferPointer { values in
                let out = out
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, min(height, Int(Double(y + 1) * sy)))
                    for x in 0..<w {
                        let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, min(width, Int(Double(x + 1) * sx)))
                        // Up to four channels in one vector, each summed in the same order as one at a time.
                        var sum = SIMD4<Float>.zero
                        for yy in y0..<y1 { for xx in x0..<x1 { for c in 0..<min(4, keep) { sum[c] += values[(yy * width + xx) * channels + c] } } }
                        let n = Float((y1 - y0) * (x1 - x0))
                        for c in 0..<min(4, keep) { out[(y * w + x) * keep + c] = sum[c] / n }
                    }
                }
            }
        }
        return out
    }
}
