import Foundation
import CoreImage
import Metal
import simd

/// Measuring where each photo is sharp.
extension FocusStacker {
    /// Everything that depends on the reference: transforms, exposure matching and each photo's sharpness on the
    /// reference's grid.
    struct Prepared {
        /// Each photo onto the reference at analysis size.
        var transforms: [HDRSimilarity]
        var gains: [Float]
        /// Noise variance of each aligned photo's proxy at analysis size, after its gain.
        var noise: [Float]
        var focus: [[Float]]
        /// Each aligned photo's sharpness proxy, which guides the label spreading.
        var proxies: [[Float]]
        /// Relative depth (0 far, 1 near) on the reference's grid, where the depth model is installed.
        var depth: [Float]? { didSet { depthRanks = depth.map(Self.ranks) } }
        /// Each pixel's depth as its rank among all pixels, 0 to 1, so tolerances mean the same near and far.
        private(set) var depthRanks: [Float]?
        init(transforms: [HDRSimilarity], gains: [Float], noise: [Float], focus: [[Float]], proxies: [[Float]], depth: [Float]?) {
            self.transforms = transforms; self.gains = gains; self.noise = noise; self.focus = focus; self.proxies = proxies
            self.depth = depth; depthRanks = depth.map(Self.ranks)
        }
        static func ranks(_ values: [Float]) -> [Float] {
            // From a 4096-bin histogram, which is plenty for a model that sees 518 × 392.
            guard let low = values.min(), let high = values.max(), high > low else { return values.map { _ in 0.5 } }
            let bins = 4096, scale = Float(bins - 1) / (high - low)
            var histogram = [Int](repeating: 0, count: bins)
            for v in values { histogram[Int((v - low) * scale)] += 1 }
            var cumulative = [Float](repeating: 0, count: bins), running = 0
            for b in 0..<bins { cumulative[b] = (Float(running) + 0.5 * Float(histogram[b])) / Float(values.count); running += histogram[b] }
            return values.map { cumulative[Int(($0 - low) * scale)] }
        }
    }

    func prepare(reference: Int, breathing: Bool) throws -> Prepared {
        let key = "\(reference)-\(breathing)-\(usesDepth)"
        if let cached = prepared[key] { return cached }
        let width = analysisWidth, height = analysisHeight, count = sources.count
        let base = transforms.map { breathing ? $0 : FocusStackAlignment.withoutScale($0, width: width, height: height) }
        let toReference = base[reference].inverse
        let relative = base.map { toReference.after($0) }
        if analysisEngine == .gpu {
            let measured = try analysisGPU.prepare(sources: sources, inverses: relative.map(\.inverse), reference: reference, clips: clips,
                                                   width: width, height: height, cancelled: { Task.isCancelled })
            let depth = usesDepth ? relativeDepth(measured.composite, width: width, height: height) : nil
            let result = Prepared(transforms: relative, gains: measured.gains, noise: measured.noise, focus: measured.focus,
                                  proxies: measured.proxies, depth: depth)
            prepared[key] = result
            return result
        }
        if Task.isCancelled { throw CancellationError() }
        var aligned = [[Float]](repeating: [], count: count)
        aligned.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out[i] = FocusStackCPUFusion.warp(sources[i], relative[i].inverse, gain: 1, width: width, height: height)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let gains = (0..<count).map { i in i == reference ? 1 : Self.exposureGain(aligned[i], onto: aligned[reference], clip: min(clips[i], clips[reference])) }
        var noise = [Float](repeating: 0, count: count)
        var focus = [[Float]](repeating: [], count: count), proxies = focus
        for i in 0..<count {
            proxies[i] = FocusStackFocus.proxy(aligned[i], gain: gains[i])
            noise[i] = FocusStackFocus.noise(proxies[i], width: width, height: height)
        }
        let typical = noise.sorted()[count / 2]
        focus.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out[i] = FocusStackFocus.measure(aligned[i], gain: gains[i], clip: clips[i], width: width, height: height, noise: noise[i], reference: typical)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let depth = usesDepth ? relativeDepth(Self.composite(aligned, gains: gains, focus: focus, reference: reference), width: width, height: height) : nil
        let result = Prepared(transforms: relative, gains: gains, noise: noise, focus: focus, proxies: proxies, depth: depth)
        prepared[key] = result
        return result
    }

    /// Each pixel from the photo sharpest there, exposure matched: the picture the depth model reads.
    static func composite(_ aligned: [[Float]], gains: [Float], focus: [[Float]], reference: Int) -> [Float] {
        let n = focus[reference].count
        var composite = [Float](repeating: 1, count: n * 4)
        for k in 0..<n {
            var index = reference, top = -Float.infinity
            for i in focus.indices where focus[i][k] > top { top = focus[i][k]; index = i }
            for c in 0..<3 { composite[k * 4 + c] = aligned[index][k * 4 + c] * gains[index] }
        }
        return composite
    }

    /// Depth Anything's relative depth of `composite` on the reference's analysis grid, or nil where the model isn't
    /// installed or fails. The model works at 518 × 392, so this only says roughly how far each area is.
    private func relativeDepth(_ composite: [Float], width: Int, height: Int) -> [Float]? {
        guard BundledModel.depth.isAvailable else { return nil }
        let n = width * height
        let image = CIImage(bitmapData: Data(bytes: composite, count: n * 16), bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        let context = self.context
        guard let depth = try? RawRenderer.relativeDepth(image, context: context) else { return nil }
        let scaled = depth.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / depth.extent.width, y: CGFloat(height) / depth.extent.height))
        var values = [Float](repeating: 0, count: n)
        values.withUnsafeMutableBytes {
            context.render(scaled, toBitmap: $0.baseAddress!, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .Rf, colorSpace: nil)
        }
        return values
    }

    /// Low-texture pixels take a weak vote for the photo that confident pixels at the same relative depth chose, so flat
    /// areas follow the scene's depth instead of noise. Depth bins are quantiles, as the model compresses far distances;
    /// a bin's vote is as strong as its confident pixels agree. A photo that confident pixels at that depth almost never
    /// chose loses an unconfident pixel to the bin's choice. Returns how many pixels changed photo.
    @discardableResult
    static func depthVotes(_ depth: [Float], best: inout [Int], confidence: inout [Float], focus: [[Float]], included: [Int],
                           bins: Int = 32, confident: Float = 0.25, weak: Float = 0.1, strength: Float = 0.15) -> Int {
        let n = depth.count
        let sample = stride(from: 0, to: n, by: 7).map { depth[$0] }.sorted()
        guard sample.count >= bins * 8 else { return 0 }
        let edges = (1..<bins).map { sample[$0 * sample.count / bins] }
        func bin(_ v: Float) -> Int {
            var low = 0, high = edges.count
            while low < high { let m = (low + high) / 2; if edges[m] <= v { low = m + 1 } else { high = m } }
            return low
        }
        let slot = Dictionary(uniqueKeysWithValues: included.enumerated().map { ($1, $0) })
        var votes = [[Float]](repeating: [Float](repeating: 0, count: included.count), count: bins)
        var voters = [Int](repeating: 0, count: bins), binOf = [Int](repeating: 0, count: n)
        for k in 0..<n {
            let b = bin(depth[k]); binOf[k] = b
            if confidence[k] >= confident, let s = slot[best[k]] { votes[b][s] += confidence[k]; voters[b] += 1 }
        }
        let totals = votes.map { $0.reduce(0, +) }
        let winners: [(photo: Int, purity: Float)?] = votes.indices.map { b in
            let v = votes[b]
            guard voters[b] >= 50, totals[b] > 0, let m = v.indices.max(by: { v[$0] < v[$1] }) else { return nil }
            return (included[m], v[m] / totals[b])
        }
        var changed = 0
        for k in 0..<n where confidence[k] < confident {
            let b = binOf[k]
            guard let winner = winners[b], focus[winner.photo][k].isFinite else { continue }
            // A choice that confident pixels at this depth almost never make is replaced outright; elsewhere a flat
            // pixel only takes the bin's vote where its own measurement is weaker.
            let implausible = slot[best[k]].map { votes[b][$0] < 0.02 * totals[b] } ?? true
            let vote = implausible ? strength : strength * winner.purity
            guard implausible || (confidence[k] < weak && vote > confidence[k]) else { continue }
            if best[k] != winner.photo { changed += 1 }
            best[k] = winner.photo; confidence[k] = vote
        }
        return changed
    }

    /// The factor bringing `frame` to `reference`'s exposure: the median luminance ratio where both are well exposed.
    /// A focus bracket normally shares one exposure; this absorbs flicker and small aperture changes.
    static func exposureGain(_ frame: [Float], onto reference: [Float], clip: Float) -> Float {
        frame.withUnsafeBufferPointer { f in reference.withUnsafeBufferPointer { r in exposureGain(f, onto: r, clip: clip) } }
    }
    /// The median is read from a histogram of log ratios a thousandth of a stop wide, within the ±2 stops the gain is
    /// clamped to, so it costs one pass instead of a sort.
    static func exposureGain(_ frame: UnsafeBufferPointer<Float>, onto reference: UnsafeBufferPointer<Float>, clip: Float) -> Float {
        let bins = 4000, low: Float = -2, width: Float = 4 / Float(bins)
        var histogram = [Int](repeating: 0, count: bins), total = 0
        func luminance(_ v: UnsafeBufferPointer<Float>, _ p: Int) -> Float { 0.2126 * v[p] + 0.7152 * v[p + 1] + 0.0722 * v[p + 2] }
        for p in stride(from: 0, to: frame.count, by: 4 * 3) where frame[p + 3] > 0.999 {
            let a = luminance(frame, p), b = luminance(reference, p)
            guard a > 0.01, b > 0.01, a < 0.9 * clip, b < 0.9 * clip else { continue }
            histogram[max(0, min(bins - 1, Int((log2(b / a) - low) / width)))] += 1; total += 1
        }
        guard total >= 200 else { return 1 }
        var seen = 0
        for (k, n) in histogram.enumerated() {
            seen += n
            if 2 * seen > total { return exp2(low + (Float(k) + 0.5) * width) }
        }
        return 1
    }

    /// Per included photo, its weight at each analysis pixel of the reference's grid, summing to 1, and the photo that
    /// supplies most of each pixel.
    struct Weights {
        var weights: [Int: [Float]]
        var sources: [Int]
        /// Where no photo shows detail above its noise.
        var uncertain: [Bool]
    }

    func weights(_ prepared: Prepared, reference: Int, included: [Int], blending: FocusStackBlending, key: String) throws -> Weights {
        if let cached = weightCache[key] { return cached }
        let width = analysisWidth, height = analysisHeight, n = width * height
        var best = [Int](repeating: reference, count: n), confidence = [Float](repeating: 0, count: n), uncertain = [Bool](repeating: false, count: n)
        for k in 0..<n {
            var top = -Float.infinity, second = -Float.infinity, index = reference
            for i in included {
                let f = prepared.focus[i][k]
                if f > top { second = top; top = f; index = i } else if f > second { second = f }
            }
            best[k] = index
            confidence[k] = top.isFinite ? max(0, min(1, (top - (second.isFinite ? second : 0)) / 2)) : 0
            uncertain[k] = !(top > 1)
        }
        if blending == .labels, let depth = prepared.depth {
            Self.depthVotes(depth, best: &best, confidence: &confidence, focus: prepared.focus, included: included)
        }
        var weights: [Int: [Float]] = [:]
        switch blending {
        case .labels:
            // Confident choices spread along the picture's own edges: a guided filter of each photo's (confidence-
            // weighted) label against the sharpest proxy, normalized by the filtered confidence. Where no confident
            // choice is near, a much wider average decides; weights are then squared so transitions stay narrow.
            var guide = [Float](repeating: 0, count: n)
            for k in 0..<n { guide[k] = prepared.proxies[best[k]][k] }
            let radius = max(2, width / 160), wide = max(8, width / 25), epsilon: Float = 1e-4, blend: Float = 0.02
            if analysisEngine == .gpu {
                weights = try analysisGPU.spread(best: best, confidence: confidence, guide: guide, focus: prepared.focus, included: included,
                                                 width: width, height: height, radius: radius, wide: wide, epsilon: epsilon, blend: blend)
                break
            }
            let denominator = FocusStackFilters.guided(confidence, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon)
            let wideDenominator = HDRMerger.boxBlur(HDRMerger.boxBlur(confidence, width: width, height: height, radius: wide), width: width, height: height, radius: wide)
            var spread = [Int: [Float]]()
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: included.count) { m in
                let i = included[m]
                var label = [Float](repeating: 0, count: n)
                for k in 0..<n where best[k] == i { label[k] = confidence[k] }
                let local = FocusStackFilters.guided(label, guide: guide, width: width, height: height, radius: radius, epsilon: epsilon)
                let broad = HDRMerger.boxBlur(HDRMerger.boxBlur(label, width: width, height: height, radius: wide), width: width, height: height, radius: wide)
                var w = [Float](repeating: 0, count: n)
                for k in 0..<n {
                    let fallback = wideDenominator[k] > 1e-4 ? broad[k] / wideDenominator[k] : 1 / Float(included.count)
                    let value = (max(0, local[k]) + blend * fallback) / (max(0, denominator[k]) + blend)
                    w[k] = prepared.focus[i][k].isFinite ? value * value : 0
                }
                lock.withLock { spread[i] = w }
            }
            weights = spread
        case .multiscale:
            for i in included {
                var w = [Float](repeating: 0, count: n)
                for k in 0..<n {
                    let f = prepared.focus[i][k], top = prepared.focus[best[k]][k]
                    w[k] = f.isFinite && top.isFinite ? exp(f - top) : 0
                }
                weights[i] = w
            }
        }
        // Normalize, drop traces under 1% (they only blur), and give the reference any pixel nothing else covers.
        // Rows in parallel, through raw pointers: this runs on every change of options.
        var planes = included.map { weights[$0]! }
        let referenceSlot = included.firstIndex(of: reference)!, members = included.count
        var pointers = [UnsafeMutablePointer<Float>](), buffers = [UnsafeMutableBufferPointer<Float>]()
        for m in planes.indices {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: n)
            _ = buffer.initialize(from: planes[m]); buffers.append(buffer); pointers.append(buffer.baseAddress!)
        }
        best.withUnsafeMutableBufferPointer { best in
            let best = best, planes = pointers
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for k in (y * width)..<((y + 1) * width) {
                    var total: Float = 0
                    for m in 0..<members { total += planes[m][k] }
                    var kept: Float = 0
                    for m in 0..<members {
                        var v = total > 0 ? planes[m][k] / total : 0
                        if v < 0.01 { v = 0 }
                        planes[m][k] = v; kept += v
                    }
                    if kept > 0 {
                        for m in 0..<members { planes[m][k] /= kept }
                    } else { planes[referenceSlot][k] = 1 }
                    var top: Float = -1
                    for m in 0..<members where planes[m][k] > top { top = planes[m][k]; best[k] = included[m] }
                }
            }
        }
        for (m, i) in included.enumerated() { weights[i] = Array(buffers[m]); buffers[m].deallocate() }
        planes = []
        let result = Weights(weights: weights, sources: best, uncertain: uncertain)
        weightCache[key] = result
        return result
    }
}
