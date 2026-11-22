import Foundation
import CoreGraphics
import CoreImage
import Metal
import simd

/// The previews the night sky tools show while their options change.
extension NightSkyAnalyzer {
    /// Where each preview pixel of `base`'s sky lies on the anchor's, in anchor analysis pixels; nil when `base` is the anchor.
    func baseMapping(_ base: Int) -> [SIMD2<Float>]? {
        guard space == .sky, base != anchor, let alignment = alignments[base] else { return nil }
        let w = previewWidth, h = previewHeight, k = previewScale
        var out = [SIMD2<Float>](repeating: .zero, count: w * h)
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let a = alignment.apply(SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5))
                    out[y * w + x] = SIMD2(Float(a.x), Float(a.y))
                }
            }
        }
        return out
    }

    enum Peak: Sendable { case channels, color }

    /// What to add up at preview size; the same plan drives the full-size render.
    struct Plan: Sendable {
        var base: Int
        var sky: Set<Int> = []
        var ground: Set<Int> = []
        var peak: Set<Int> = []
        var peakMode = Peak.channels
        /// Per photo, lines whose footprint the photo doesn't contribute to the sky (anchor analysis pixels).
        var skyExclusions: [Int: [NightSkyLine]] = [:]
        /// Per photo, lines left out of the peak (camera analysis pixels).
        var peakExclusions: [Int: [NightSkyLine]] = [:]
        /// Lines restored from their own photos over the result (anchor analysis pixels, or camera pixels as captured).
        var restore: [NightSkyLine] = []
        /// Restores lines where the camera recorded them instead of moving them with the stars to the base sky.
        var restoreAsCaptured = false
        /// Averages the sky a second time, leaving out samples far from each pixel's mean.
        var rejectOutliers = false
        /// With `rejectOutliers`, leaves out samples far from the base photo's own pixel instead of from the mean: what the
        /// average adds must agree with the photo the result shows. The ground must be the base photo alone, as its sum is
        /// the reference.
        var agreeWithBase = false
        /// Full-size pixels to move the sky's boundary by.
        var skyShape = SkyShape()
        /// Areas taken from `regionPhoto` alone, over everything else.
        var regions: [NightSkyStroke] = []
        var regionPhoto: Int?
        /// Per photo, the next photo and the fractions of the sky's motion toward it that fall in the pause between them:
        /// the photo's peak is also drawn shifted by each, filling the pause. Drawn, not captured.
        var gapFill: [Int: (next: Int, steps: [Float])] = [:]
        /// Trails over one photo's sky: the peak takes each photo's detail above its own local background (stars, not
        /// glow or aurora), and the sky is this photo's plus that peak.
        var peakOverPhoto: Int?
    }

    /// Leave-one-out sigma clipping for the robust sky mean, from the first pass's weighted sums: a sample whose luminance
    /// lies more than three standard deviations from the mean of the pixel's other samples is left out of the second
    /// pass. Leaving the sample out of its own statistics matters: an outlier inflates a deviation it is part of, and among
    /// N samples can never stray more than √(N − 1) of it. The statistics cover every photo at once, never independently
    /// clipped batches; with fewer than four other photos at a pixel nothing is rejected there, so a short stack can't
    /// clip away faint stars. A deviation estimated from a handful of samples is often too small, so it never goes below
    /// `floor`, the sky's typical deviation; noise is symmetric, so the few samples beyond that don't bias the mean.
    ///
    /// Agreeing with the base works for a few photos around one moment, where a mean has too few samples to stand on: a
    /// sample stays when it lies within k standard deviations of a difference between two photos (√2 times one photo's)
    /// from the base photo's own pixel. Noise grows with the light, so the deviation grows as the square root of the
    /// base's level over the sky's typical level. A skyline detail the sky finder took for sky, such as a treetop, then
    /// stays the base photo's own instead of averaging with the sky beside it, and the other photos' copies of it, moved
    /// with the stars, don't ghost into the sky.
    struct Clipping {
        var k: Float = 3
        /// Weight of the other samples below which a pixel keeps every sample.
        var minimumWeight: Float
        var floor: Float = 0
        /// Compares with the base photo's pixel instead of the mean of the others.
        var agreeWithBase = false
        /// The sky's typical luminance, which `floor` is the deviation at.
        var level: Float = 0
        /// One photo's weight on average, for correcting a deviation measured over a few photos.
        private var meanWeight: Float
        init(_ plan: Plan, weights: [Float]) {
            meanWeight = plan.sky.isEmpty ? 1 : plan.sky.reduce(Float(0)) { $0 + weights[$1] } / Float(plan.sky.count)
            minimumWeight = 3.5 * meanWeight
            agreeWithBase = plan.agreeWithBase
        }
        /// Whether a sample of luminance `l` stays beside the base photo's luminance `base` at its pixel.
        @inline(__always) func agrees(_ l: Float, base: Float) -> Bool {
            abs(l - base) <= k * Float(2).squareRoot() * floor * max(1, base / max(level, 1e-6)).squareRoot()
        }
        /// Whether a sample of luminance `l` and weight `w` stays, given the pixel's first-pass sum (RGB × weight, weight)
        /// and Σ weight × l², both including the sample.
        @inline(__always) func keeps(_ l: Float, weight w: Float, sum: SIMD4<Float>, squares: Float) -> Bool {
            let others = sum.w - w
            guard others >= minimumWeight else { return true }
            let mean = (simd_dot(SIMD3(sum.x, sum.y, sum.z), SIMD3(0.2126, 0.7152, 0.0722)) - w * l) / others
            let deviation = max(floor, max(0, (squares - w * l * l) / others - mean * mean).squareRoot())
            return abs(l - mean) <= k * deviation
        }

        /// Sets `floor` to the median deviation of sky pixels with enough samples, from the first pass's sums, and `level`
        /// to their median luminance. Agreeing with the base needs only two photos at a pixel; the deviation of a few is
        /// corrected for being measured about their own mean.
        mutating func measureFloor(sums: UnsafeBufferPointer<Float>, squares: UnsafeBufferPointer<Float>) {
            var deviations: [Double] = [], levels: [Double] = []
            let enough = agreeWithBase ? 1.5 * meanWeight : minimumWeight + 1
            for p in stride(from: 0, to: squares.count, by: max(1, squares.count / 200_000)) where sums[p * 4 + 3] >= enough {
                let w = sums[p * 4 + 3]
                let mean = simd_dot(SIMD3(sums[p * 4], sums[p * 4 + 1], sums[p * 4 + 2]), SIMD3(0.2126, 0.7152, 0.0722)) / w
                let correction = agreeWithBase ? w / max(1e-6, w - meanWeight) : 1
                deviations.append(Double(max(0, (squares[p] / w - mean * mean) * correction).squareRoot()))
                levels.append(Double(mean))
            }
            floor = Float(NightSkyStars.median(deviations))
            level = Float(NightSkyStars.median(levels))
        }
    }

    /// A pause's steps thinned to about one per preview pixel: the full-size steps are one per full-size pixel.
    private func previewSteps(_ steps: [Float]) -> [Float] {
        let stride = max(1, Int((scale * previewScale).rounded(.down)))
        return steps.enumerated().filter { $0.offset % stride == stride / 2 || steps.count < stride && $0.offset == steps.count / 2 }.map(\.element)
    }

    /// The sky probability the finder gives the anchor: the sky network refined by which sources moved with the stars
    /// between the anchor and a photo far from it in time.
    func findSky(_ anchorImage: CIImage, luminance anchorLuminance: [Float], frames: [NightSkyFrameMetadata]) throws -> [Float] {
        let aw = analysisWidth, ah = analysisHeight
        if let known = Self.skyOverride { return known(aw, ah) }
        // A photo far in time from the anchor, to tell what moves with the stars from what stands still: the farthest
        // whose stars still match the anchor's, trying nearer ones when the sky has turned too far to match.
        func offset(_ i: Int) -> Double { abs((frames[i].midpoint ?? Double(i) * 30) - (frames[anchor].midpoint ?? Double(anchor) * 30)) }
        let farthest = frames.indices.filter { $0 != anchor }.max { offset($0) < offset($1) }!
        var candidates = [farthest]
        for fraction in [0.5, 0.25] {
            let target = offset(farthest) * fraction
            if let near = frames.indices.filter({ $0 != anchor && !candidates.contains($0) }).min(by: { abs(offset($0) - target) < abs(offset($1) - target) }) { candidates.append(near) }
        }
        let anchorSources = try NightSkyStars.detect(anchorLuminance, width: aw, height: ah, mask: nil, limit: .max, gpu: gpu)
        var comparison: (sources: [NightSkyStar], motion: NightSkyAlignment?)?
        for candidate in candidates {
            if Task.isCancelled { throw CancellationError() }
            let luminance = Self.luminance(try developAnalysis(candidate).1, gain: gains[candidate])
            let sources = try NightSkyStars.detect(luminance, width: aw, height: ah, mask: nil, limit: .max, gpu: gpu)
            // Fitted on the sources that moved: the brightest are often lights on the ground, which would pin the fit still.
            let (anchorMoved, otherMoved) = Self.withoutStill(anchorSources, sources)
            let motion = try? NightSkyRegistration.align(source: Array(otherMoved.prefix(700)), reference: Array(anchorMoved.prefix(700)), width: aw)
            if comparison == nil || motion != nil { comparison = (sources, motion) }
            if motion != nil { break }
        }
        return try skyMask(anchorImage, luminance: anchorLuminance, sources: anchorSources, others: comparison!.sources, motion: comparison!.motion)
    }

    /// What counts as sky, from the sky analysis found: its boundary moved by `edge` full-size pixels (out into the ground
    /// when positive), or `everything`, then the painted `strokes` in order.
    struct SkyShape: Codable, Equatable, Sendable {
        var edge = 0
        var everything = false
        var strokes: [NightSkyStroke] = []
    }

    /// Shapes the sky for this and later previews and renders: a maximum of the found sky probability to grow it, a
    /// minimum to shrink it, then the strokes adding and taking away sky. Where the sky now reaches past what the aligned
    /// preview copies were warped for, they are warped again; lines are still those analysis found inside its own sky.
    func setSky(_ shape: SkyShape) throws {
        guard shape != skyShape, !foundSkyProbability.isEmpty else { return }
        let aw = analysisWidth, ah = analysisHeight
        let moved = try shaped(foundSkyProbability, shape)
        skyProbability = moved
        skyValid = try minFilter(moved, width: aw, height: ah, radius: max(3, aw / 400))
        previewProbability = Self.downsample(moved, channels: 1, width: aw, height: ah, to: previewWidth, previewHeight)
        skyShape = shape
        if space == .sky { try warpAgainWhereSkyGrew() }
    }

    /// `found` (analysis size) shaped as `shape` says.
    func shaped(_ found: [Float], _ shape: SkyShape) throws -> [Float] {
        let aw = analysisWidth, ah = analysisHeight, radius = Int((Double(abs(shape.edge)) / scale).rounded())
        var moved = found
        if shape.everything {
            moved = [Float](repeating: 1, count: aw * ah)
        } else if radius > 0 {
            moved = try shape.edge > 0 ? minFilter(moved.map { 1 - $0 }, width: aw, height: ah, radius: radius).map { 1 - $0 }
                                   : minFilter(moved, width: aw, height: ah, radius: radius)
        }
        for stroke in shape.strokes {
            guard let sky = stroke.sky else { continue }
            Self.cover(stroke, width: aw, height: ah) { i, c in moved[i] = sky ? max(moved[i], c) : min(moved[i], 1 - c) }
        }
        return moved
    }

    /// Warps the aligned preview copies again with maps that reach as far as both the current and the previous ones, so
    /// a later step back within either needs no new warp.
    private func warpAgainWhereSkyGrew() throws {
        guard let cache, warpedValid.count == skyValid.count, warpedPreviewProbability.count == previewProbability.count else { return }
        let grew = zip(previewProbability, warpedPreviewProbability).contains { $0 > 0.01 && $1 <= 0.01 }
            || zip(skyValid, warpedValid).contains { $0 > 0.8 && $1 <= 0.8 }
        guard grew else { return }
        let mask = zip(previewProbability, warpedPreviewProbability).map { max($0, $1) }, valid = zip(skyValid, warpedValid).map { max($0, $1) }
        let warper = try gpu.map { try NightSkyAnalysisGPU.Warper($0, width: previewWidth, height: previewHeight, mask: mask, threshold: 0.01,
                                                                valid: valid, analysis: (analysisWidth, analysisHeight)) }
        let alignments = self.alignments
        try cache.rewrite(alignments.indices.filter { alignments[$0] != nil }, slot: 1) { i, rgb in
            if Task.isCancelled { throw CancellationError() }
            return try warper?.warp(rgb, channels: 3, alignment: alignments[i]!) ?? warpPreview(rgb, alignments[i]!, mask: mask, valid: valid)
        }
        warpedPreviewProbability = mask; warpedValid = valid
    }

    /// The plan drawn at preview size, linear RGB.
    func preview(_ plan: Plan) throws -> [Float] {
        guard let cache else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        try setSky(plan.skyShape)
        let w = previewWidth, h = previewHeight, k = previewScale
        let mapping = baseMapping(plan.base)
        let frames = Array(plan.sky.union(plan.ground).union(plan.peak)).sorted()
        var sky = [Float](repeating: 0, count: plan.sky.isEmpty ? 0 : w * h * 4)
        var squares = [Float](repeating: 0, count: plan.rejectOutliers ? w * h : 0)
        var ground = [Float](repeating: 0, count: w * h * 4)
        var peak = [Float](repeating: -.infinity, count: plan.peak.isEmpty ? 0 : w * h * 4)
        let gains = self.gains, weights = self.weights, probability = previewProbability
        try cache.read { reader in
            /// Photo `i`'s sky sample at preview pixel (x, y) on the base sky, unless it has none or is on a left-out line.
            func skySample(_ i: Int, _ x: Int, _ y: Int, _ excluded: [NightSkyLine]) -> SIMD3<Float>? {
                let p = y * w + x
                guard probability[p] > 0.01 else { return nil }
                let value: SIMD3<Float>?, a: SIMD2<Double>
                if let mapping {
                    a = SIMD2(Double(mapping[p].x), Double(mapping[p].y))
                    value = reader.bilinear(i, 1, (a + 0.5) / k - 0.5)
                } else {
                    a = SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5)
                    let v = reader.pixel(reader.copy(i, 1), p)
                    value = v.x.isFinite ? v : nil
                }
                guard let value, !excluded.contains(where: { $0.distance(a) <= $0.radius }) else { return nil }
                return value * gains[i]
            }
            sky.withUnsafeMutableBufferPointer { sky in
                squares.withUnsafeMutableBufferPointer { squares in
                    ground.withUnsafeMutableBufferPointer { ground in
                        peak.withUnsafeMutableBufferPointer { peak in
                            let sky = sky, squares = squares, ground = ground, peak = peak
                            DispatchQueue.concurrentPerform(iterations: h) { y in
                                for i in frames {
                                    let g = gains[i], wt = weights[i]
                                    let unwarped = reader.copy(i, 0)
                                    let inGround = plan.ground.contains(i), inPeak = plan.peak.contains(i) && plan.peakOverPhoto == nil, inSky = plan.sky.contains(i)
                                    let skyExcluded = plan.skyExclusions[i] ?? [], peakExcluded = plan.peakExclusions[i] ?? []
                                    for x in 0..<w {
                                        let p = y * w + x, q = p * 4
                                        if inGround || inPeak {
                                            let v = reader.pixel(unwarped, p) * g
                                            let camera = SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5)
                                            if inGround { ground[q] += v.x * wt; ground[q + 1] += v.y * wt; ground[q + 2] += v.z * wt; ground[q + 3] += wt }
                                            if inPeak, !peakExcluded.contains(where: { $0.distance(camera) <= $0.radius }) { Self.raise(peak, q, v, mode: plan.peakMode) }
                                        }
                                        guard inSky, let value = skySample(i, x, y, skyExcluded) else { continue }
                                        sky[q] += value.x * wt; sky[q + 1] += value.y * wt; sky[q + 2] += value.z * wt; sky[q + 3] += wt
                                        if plan.rejectOutliers { let l = simd_dot(value, SIMD3(0.2126, 0.7152, 0.0722)); squares[p] += wt * l * l }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if plan.peakOverPhoto != nil {
                // Each photo's detail above its own local background. Photos are spread over the cores in groups, each
                // raising its own peak, merged at the end; a group holds one photo's background at a time.
                let radius = max(1, Int((Self.backgroundRadius / (scale * k)).rounded()))
                let frames = plan.peak.sorted(), groups = min(frames.count, max(1, ProcessInfo.processInfo.activeProcessorCount))
                var partial = [[Float]](repeating: [], count: groups)
                let partialLock = NSLock()
                DispatchQueue.concurrentPerform(iterations: groups) { group in
                    var local = [Float](repeating: -.infinity, count: w * h * 4)
                    local.withUnsafeMutableBufferPointer { local in
                        for (n, i) in frames.enumerated() where n % groups == group {
                            let copy = reader.copy(i, 0), g = gains[i], excluded = plan.peakExclusions[i] ?? []
                            var values = [Float](repeating: 0, count: w * h * 3)
                            for k in values.indices { values[k] = Float(copy[k]) * g }
                            let background = Self.background(values, width: w, height: h, radius: radius)
                            for k in values.indices { values[k] -= background[k] }
                            let field = plan.gapFill[i].map { fill in gapField(from: i, to: fill.next) }
                            let steps = plan.gapFill[i].map { previewSteps($0.steps) }
                            values.withUnsafeBufferPointer { detail in
                                for y in 0..<h { for x in 0..<w {
                                    let p = y * w + x
                                    let camera = SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5)
                                    if excluded.isEmpty || !excluded.contains(where: { $0.distance(camera) <= $0.radius }) {
                                        Self.raise(local, p * 4, SIMD3(detail[p * 3], detail[p * 3 + 1], detail[p * 3 + 2]), mode: plan.peakMode)
                                    }
                                    guard let steps, let field else { continue }
                                    let d = field(camera)
                                    for t in steps {
                                        let s = camera - Double(t) * d
                                        guard isSky(s), !excluded.contains(where: { $0.distance(s) <= $0.radius }),
                                              let v = Self.bilinear(detail, w, h, (s + 0.5) / k - 0.5, channels: 3) else { continue }
                                        Self.raise(local, p * 4, v, mode: plan.peakMode)
                                    }
                                }}
                            }
                        }
                    }
                    partialLock.withLock { partial[group] = local }
                }
                peak.withUnsafeMutableBufferPointer { peak in
                    let peak = peak
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for local in partial { for x in 0..<w {
                            let q = (y * w + x) * 4
                            if local[q].isFinite { Self.raise(peak, q, SIMD3(local[q], local[q + 1], local[q + 2]), mode: plan.peakMode) }
                        }}
                    }
                }
            } else if !plan.gapFill.isEmpty {
                // Pauses drawn by each photo's peak shifted along the sky's motion toward the next photo.
                peak.withUnsafeMutableBufferPointer { peak in
                    let peak = peak
                    for (i, fill) in plan.gapFill {
                        let field = gapField(from: i, to: fill.next), steps = previewSteps(fill.steps)
                        let g = gains[i], excluded = plan.peakExclusions[i] ?? []
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w {
                                let camera = SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5)
                                let d = field(camera)
                                for t in steps {
                                    let s = camera - Double(t) * d
                                    guard isSky(s), !excluded.contains(where: { $0.distance(s) <= $0.radius }),
                                          let v = reader.bilinear(i, 0, (s + 0.5) / k - 0.5) else { continue }
                                    Self.raise(peak, (y * w + x) * 4, v * g, mode: plan.peakMode)
                                }
                            }
                        }
                    }
                }
            }
            guard plan.rejectOutliers else { return }
            // The second pass: the sky again, without samples the first pass's statistics call outliers.
            let first = sky, reference = ground
            var clipping = Clipping(plan, weights: weights)
            first.withUnsafeBufferPointer { sums in squares.withUnsafeBufferPointer { clipping.measureFloor(sums: sums, squares: $0) } }
            sky = [Float](repeating: 0, count: w * h * 4)
            sky.withUnsafeMutableBufferPointer { sky in
                let sky = sky
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for i in plan.sky.sorted() {
                        let wt = weights[i], excluded = plan.skyExclusions[i] ?? []
                        for x in 0..<w {
                            let p = y * w + x, q = p * 4
                            guard let value = skySample(i, x, y, excluded) else { continue }
                            let l = simd_dot(value, SIMD3(0.2126, 0.7152, 0.0722))
                            if clipping.agreeWithBase {
                                if reference[q + 3] > 0, !clipping.agrees(l, base: simd_dot(SIMD3(reference[q], reference[q + 1], reference[q + 2]), SIMD3(0.2126, 0.7152, 0.0722)) / reference[q + 3]) { continue }
                            } else if !clipping.keeps(l, weight: wt, sum: SIMD4(first[q], first[q + 1], first[q + 2], first[q + 3]), squares: squares[p]) { continue }
                            sky[q] += value.x * wt; sky[q + 1] += value.y * wt; sky[q + 2] += value.z * wt; sky[q + 3] += wt
                        }
                    }
                }
            }
        }
        var photo: [Float] = []
        if let chosen = plan.peakOverPhoto {
            try cache.read { reader in
                let copy = reader.copy(chosen, 0)
                photo = [Float](repeating: 0, count: w * h * 4)
                for p in 0..<(w * h) { for c in 0..<3 { photo[p * 4 + c] = Float(copy[p * 3 + c]) * gains[chosen] } }
            }
        }
        var out = Self.compose(sky: sky, ground: ground, peak: peak, probability: probability, count: w * h,
                               minimumSkyWeight: min(3, plan.sky.reduce(Float(0)) { $0 + weights[$1] }), photo: photo)
        if !plan.restore.isEmpty { try restorePreview(&out, plan: plan, mapping: mapping) }
        if !plan.regions.isEmpty, let chosen = plan.regionPhoto {
            let regions = Self.regionMap(plan.regions, width: w, height: h)
            try cache.read { reader in
                let copy = reader.copy(chosen, 0), g = gains[chosen]
                for p in 0..<(w * h) where regions[p] > 0 {
                    for c in 0..<3 { out[p * 3 + c] += regions[p] * (Float(copy[p * 3 + c]) * g - out[p * 3 + c]) }
                }
            }
        }
        return out
    }

    /// How much of each pixel the painted strokes take: 1 within 70% of a dab's radius, fading to 0 at its edge.
    static func regionMap(_ strokes: [NightSkyStroke], width w: Int, height h: Int) -> [Float] {
        var map = [Float](repeating: 0, count: w * h)
        for stroke in strokes { cover(stroke, width: w, height: h) { map[$0] = max(map[$0], $1) } }
        return map
    }

    /// Each pixel a dab reaches, with how much of it the dab takes.
    static func cover(_ stroke: NightSkyStroke, width w: Int, height h: Int, _ body: (Int, Float) -> Void) {
        let cx = stroke.x * Double(w) - 0.5, cy = stroke.y * Double(h) - 0.5, r = max(0.5, stroke.radius * Double(w))
        let x0 = max(0, Int(cx - r)), x1 = min(w - 1, Int(cx + r) + 1), y0 = max(0, Int(cy - r)), y1 = min(h - 1, Int(cy + r) + 1)
        guard x1 >= x0, y1 >= y0 else { return }
        for y in y0...y1 { for x in x0...x1 {
            let c = smoothstep(Float(r), Float(0.7 * r), Float(hypot(Double(x) - cx, Double(y) - cy)))
            if c > 0 { body(y * w + x, c) }
        }}
    }

    /// Restores the plan's lines into a preview from the photos' aligned copies: inside each line's feathered footprint
    /// the photo's own pixels replace the background, and where lines overlap the one standing out most wins.
    private func restorePreview(_ out: inout [Float], plan: Plan, mapping: [SIMD2<Float>]?) throws {
        guard let cache else { return }
        let w = previewWidth, h = previewHeight, k = previewScale
        let clean = out
        var score = [Float](repeating: -.infinity, count: w * h)
        try cache.read { reader in
            for line in plan.restore {
                let g = gains[line.frame]
                // Only the preview pixels near the line, found through the base framing's inverse.
                let ends = [line.start, line.end].map { ((plan.restoreAsCaptured ? $0 : pointOnBase($0, base: plan.base)) + 0.5) / k - 0.5 }
                let margin = line.radius / k + 3
                let x0 = max(0, Int(min(ends[0].x, ends[1].x) - margin)), x1 = min(w - 1, Int(max(ends[0].x, ends[1].x) + margin))
                let y0 = max(0, Int(min(ends[0].y, ends[1].y) - margin)), y1 = min(h - 1, Int(max(ends[0].y, ends[1].y) + margin))
                guard x1 >= x0, y1 >= y0 else { continue }
                for y in y0...y1 { for x in x0...x1 {
                    let p = y * w + x
                    let camera = SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5)
                    let a = plan.restoreAsCaptured ? camera : mapping.map { SIMD2(Double($0[p].x), Double($0[p].y)) } ?? camera
                    let alpha = line.coverage(a)
                    // As captured, the photo's own pixel at the same place; otherwise its sky on the anchor's.
                    let sample = plan.restoreAsCaptured ? (isSky(camera) ? reader.bilinear(line.frame, 0, SIMD2(Double(x), Double(y))) : nil)
                                                        : reader.bilinear(line.frame, 1, (a + 0.5) / k - 0.5)
                    guard alpha > 0, let s = sample else { continue }
                    let source = s * g, base = SIMD3(clean[p * 3], clean[p * 3 + 1], clean[p * 3 + 2])
                    // A meteor only adds light: a darker sample is the photo's own noise or edge, never restored.
                    let candidate = alpha * simd_dot(source - base, SIMD3(0.2126, 0.7152, 0.0722))
                    guard candidate > max(0, score[p]) else { continue }
                    score[p] = candidate
                    let v = base + alpha * (source - base)
                    out[p * 3] = v.x; out[p * 3 + 1] = v.y; out[p * 3 + 2] = v.z
                }}
            }
        }
    }

    @inline(__always) static func raise(_ s: UnsafeMutableBufferPointer<Float>, _ q: Int, _ v: SIMD3<Float>, mode: Peak) {
        switch mode {
        case .channels:
            s[q] = max(s[q], v.x); s[q + 1] = max(s[q + 1], v.y); s[q + 2] = max(s[q + 2], v.z)
        case .color:
            // The brightest photo's color, kept whole, rather than each channel's brightest.
            let l = simd_dot(v, SIMD3(0.2126, 0.7152, 0.0722))
            if l > s[q + 3] { s[q] = v.x; s[q + 1] = v.y; s[q + 2] = v.z; s[q + 3] = l }
        }
    }

    /// Sky over ground by the sky probability. The sky is the peak when there is one, else the aligned mean, which fades to
    /// the ground's own pixels where fewer photos than `minimumSkyWeight` saw that sky. RGB out.
    /// The radius, in full-size pixels, of the local background a photo's stellar detail is measured above: wide against
    /// a star, narrow against glow and aurora.
    static let backgroundRadius = 10.0

    /// Each channel of an interleaved RGB image box-blurred.
    static func background(_ rgb: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rgb.count)
        for c in 0..<3 {
            let blurred = HDRMerger.boxBlur((0..<(width * height)).map { rgb[$0 * 3 + c] }, width: width, height: height, radius: radius)
            for i in 0..<(width * height) { out[i * 3 + c] = blurred[i] }
        }
        return out
    }

    static func compose(sky: [Float], ground: [Float], peak: [Float], probability: [Float], count: Int, minimumSkyWeight: Float, photo: [Float] = []) -> [Float] {
        var out = [Float](repeating: 0, count: count * 3)
        for p in 0..<count {
            let q = p * 4
            let groundWeight = ground[q + 3]
            let g = groundWeight > 0 ? SIMD3(ground[q], ground[q + 1], ground[q + 2]) / groundWeight : .zero
            // Trails reach into the uncertain band along the skyline: still trees stay themselves under a maximum, and
            // trails really do pass behind tree tips; an averaged ground there would draw a halo along the skyline.
            var a = peak.isEmpty ? smoothstep(0.35, 0.65, probability[p]) : smoothstep(0.05, 0.3, probability[p])
            var s = g
            if !peak.isEmpty, !photo.isEmpty {
                // Trails over the chosen photo's sky.
                let detail = peak[q].isFinite ? simd_max(SIMD3(peak[q], peak[q + 1], peak[q + 2]), .zero) : .zero
                s = SIMD3(photo[q], photo[q + 1], photo[q + 2]) + detail
            } else if !peak.isEmpty {
                s = peak[q].isFinite ? SIMD3(peak[q], peak[q + 1], peak[q + 2]) : g
            } else if !sky.isEmpty {
                let weight = sky[q + 3]
                if weight > 0 { s = SIMD3(sky[q], sky[q + 1], sky[q + 2]) / weight }
                a *= min(1, weight / max(1e-6, minimumSkyWeight))
            }
            let v = a * s + (1 - a) * g
            out[p * 3] = v.x; out[p * 3 + 1] = v.y; out[p * 3 + 2] = v.z
        }
        return out
    }

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// A crop of a photo around a line on the anchor's sky, for reviewing it.
    func linePicture(_ line: NightSkyLine, size: Int) throws -> CGImage? {
        guard let cache else { return nil }
        let k = previewScale, w = previewWidth, h = previewHeight
        let center = ((line.start + line.end) / 2 + 0.5) / k - 0.5
        // A long line's middle part, so it stays more than a hairline at list size.
        let half = min(64, max(24, line.length / k * 0.65 + 8))
        let x0 = max(0, Int(center.x - half)), y0 = max(0, Int(center.y - half))
        let x1 = min(w, Int(center.x + half)), y1 = min(h, Int(center.y + half))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }
        let cw = x1 - x0, ch = y1 - y0
        var values = [Float](repeating: 0, count: cw * ch * 3)
        try cache.read { reader in
            let source = reader.copy(line.frame, space == .sky ? 1 : 0)
            for y in 0..<ch { for x in 0..<cw { for c in 0..<3 {
                let v = Float(source[((y + y0) * w + x + x0) * 3 + c])
                values[(y * cw + x) * 3 + c] = v.isFinite ? v : 0
            }}}
        }
        // Stretched so the line reads at list size: the sky, a tilted plane per channel for the glow toward the horizon,
        // goes to black, and the line's brighter parts (a blinking aircraft's flashes, not the gaps between them) to near
        // white. Stars brighter than the line clip.
        let mx = Float(cw - 1) / 2, my = Float(ch - 1) / 2
        var sxx: Float = 0, syy: Float = 0
        for y in 0..<ch { syy += Float(cw) * (Float(y) - my) * (Float(y) - my) }
        for x in 0..<cw { sxx += Float(ch) * (Float(x) - mx) * (Float(x) - mx) }
        var tilt = [SIMD2<Float>](repeating: .zero, count: 3), level = SIMD3<Float>.zero
        for c in 0..<3 {
            var sx: Float = 0, sy: Float = 0
            for y in 0..<ch { for x in 0..<cw { let v = values[(y * cw + x) * 3 + c]; sx += (Float(x) - mx) * v; sy += (Float(y) - my) * v } }
            tilt[c] = SIMD2(sx / max(1, sxx), sy / max(1, syy))
            var rest = [Float](); rest.reserveCapacity(cw * ch)
            for y in 0..<ch { for x in 0..<cw { rest.append(values[(y * cw + x) * 3 + c] - tilt[c].x * (Float(x) - mx) - tilt[c].y * (Float(y) - my)) } }
            rest.sort()
            level[c] = rest[rest.count / 2]
        }
        var flat = values
        for y in 0..<ch { for x in 0..<cw { for c in 0..<3 {
            flat[(y * cw + x) * 3 + c] = max(0, values[(y * cw + x) * 3 + c] - level[c] - tilt[c].x * (Float(x) - mx) - tilt[c].y * (Float(y) - my))
        }}}
        func luminance(_ x: Int, _ y: Int) -> Float {
            let p = (y * cw + x) * 3
            return 0.2126 * flat[p] + 0.7152 * flat[p + 1] + 0.0722 * flat[p + 2]
        }
        let a = (line.start + 0.5) / k - 0.5 - SIMD2(Double(x0), Double(y0)), b = (line.end + 0.5) / k - 0.5 - SIMD2(Double(x0), Double(y0))
        let steps = max(2, Int(simd_distance(a, b)))
        var along: [Float] = []
        for i in 0...steps {
            let p = a + (b - a) * Double(i) / Double(steps), px = Int(p.x.rounded()), py = Int(p.y.rounded())
            // A long line runs on past the crop.
            guard px >= 0, px < cw, py >= 0, py < ch else { continue }
            var peak: Float = 0
            for y in max(0, py - 1)...min(ch - 1, py + 1) { for x in max(0, px - 1)...min(cw - 1, px + 1) { peak = max(peak, luminance(x, y)) } }
            along.append(peak)
        }
        along.sort()
        let lineLevel = along.isEmpty ? 0 : along[min(along.count - 1, along.count * 9 / 10)]
        let scale = lineLevel > 0 ? 0.85 / lineLevel : displayExposure * gains[line.frame]
        // Upsampled with nearest neighbors so a thin line stays visible in the list.
        let factor = max(1, size / max(cw, ch))
        var big = [Float](repeating: 0, count: cw * factor * ch * factor * 3)
        for y in 0..<(ch * factor) { for x in 0..<(cw * factor) { for c in 0..<3 {
            big[(y * cw * factor + x) * 3 + c] = flat[((y / factor) * cw + x / factor) * 3 + c] * scale
        }}}
        return NightSkyFinishing.picture(big, channels: 3, width: cw * factor, height: ch * factor, exposure: 1)
    }

    /// Maps a point on the anchor's sky (analysis pixels) to `base`'s, for drawing lines over a preview in base framing.
    func pointOnBase(_ a: SIMD2<Double>, base: Int) -> SIMD2<Double> {
        guard space == .sky, base != anchor, let alignment = alignments[base] else { return a }
        return alignment.sourcePoint(a)
    }
}
