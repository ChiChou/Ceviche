import Foundation
import CoreImage
import Accelerate
import Metal
import simd

/// The full-size render of a plan, one photo at a time: each photo is developed at full size, its sky sampled onto the
/// base photo's sky through the alignments found at analysis size, and added to running sums of sky, ground and peak;
/// the sums are then composed by the sky probability and the plan's lines restored from their own photos. The GPU does
/// this with each photo staying in GPU memory from development to the sums; the CPU path is the same arithmetic, kept
/// as the reference tests compare it with.
extension NightSkyAnalyzer {
    enum Engine { case cpu, gpu }

    /// The arithmetic both engines share, per photo.
    struct Contribution {
        var index: Int
        var gain: Float
        var weight: Float
        var sky: Bool, ground: Bool, peak: Bool
        /// The peak keeps the brightest photo's color whole instead of each channel's brightest.
        var peakColor: Bool
        var skyLines: [NightSkyLine]
        var peakLines: [NightSkyLine]
        /// Maps base sky points onto this photo's pixels (analysis pixels); nil for the anchor.
        var alignment: NightSkyAlignment?
        /// The peak takes the photo's detail above its local background, for trails over a chosen photo's sky.
        var detail = false
        /// This photo's sky is the one the trails are drawn over.
        var isSkyPhoto = false
        /// Drawing the pause after this photo: its own map, the next photo's, and the fractions of the motion to draw.
        var gap: (own: NightSkyAlignment?, next: NightSkyAlignment?, steps: [Float])?
    }

    func contributions(_ plan: Plan) -> [Contribution] {
        let photo = plan.regions.isEmpty ? plan.peakOverPhoto : plan.peakOverPhoto ?? plan.regionPhoto
        return Array(plan.sky.union(plan.ground).union(plan.peak).union(photo.map { [$0] } ?? [])).sorted().map { i in
            Contribution(index: i, gain: gains[i], weight: weights[i], sky: plan.sky.contains(i), ground: plan.ground.contains(i), peak: plan.peak.contains(i), peakColor: plan.peakMode == .color,
                         skyLines: plan.skyExclusions[i] ?? [], peakLines: plan.peakExclusions[i] ?? [], alignment: i == anchor ? nil : alignments[i],
                         detail: plan.peakOverPhoto != nil && plan.peak.contains(i), isSkyPhoto: photo == i,
                         gap: plan.gapFill[i].map { (i == anchor ? nil : alignments[i], $0.next == anchor ? nil : alignments[$0.next], $0.steps) })
        }
    }

    /// The plan at full size, linear extended sRGB with alpha 1. `timing` receives each stage's name and seconds.
    func render(_ plan: Plan, engine: Engine, progress: @escaping @Sendable (Double, String) -> Void,
                timing: (String, Double) -> Void = { _, _ in }) throws -> PanoramaRaster {
        let w = width, h = height
        guard Double(w) * Double(h) * 64 < MemoryBudget.bytes else {
            throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos."))
        }
        try setSky(plan.skyShape)
        let list = contributions(plan)
        let restoring = Array(Set(plan.restore.map(\.frame))).sorted()
        // The robust sky's second pass visits the sky photos again, for the sky alone.
        let clipped = plan.rejectOutliers ? list.filter(\.sky).map { c -> Contribution in
            var c = c; c.ground = false; c.peak = false; c.peakLines = []; return c
        } : []
        var clipping = Clipping(plan, weights: weights)
        let steps = Double(list.count + clipped.count + restoring.count)
        var clock = Date()
        func lap(_ name: String) { let now = Date(); timing(name, now.timeIntervalSince(clock)); clock = now }
        func step(_ done: Int, _ i: Int, _ total: Int) {
            progress(Double(done) / steps, L10n.tr("Developing \(metadata[i].filename) (\(done + 1) of \(total))"))
        }
        let minimumSkyWeight = min(3, plan.sky.reduce(Float(0)) { $0 + weights[$1] })
        let baseAlignment = plan.base == anchor ? nil : alignments[plan.base]
        switch engine {
        case .gpu:
            let gpu = NightSkyGPU(device: device)
            guard let sums = gpu.sums(width: w, height: h, sky: !plan.sky.isEmpty, peak: !plan.peak.isEmpty) else {
                throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
            }
            let maps = try gpu.maps(probability: skyProbability, valid: skyValid)
            if plan.peakOverPhoto != nil || !plan.regions.isEmpty {
                guard let photo = gpu.buffer(width: w, height: h, channels: 4) else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos.")) }
                sums.photo = photo
            }
            let squares = plan.rejectOutliers ? gpu.buffer(width: w, height: h, channels: 1) : nil
            if plan.rejectOutliers, squares == nil { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos.")) }
            for (done, c) in list.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, c.index, list.count + clipped.count + restoring.count)
                try autoreleasepool {
                    let image = try developedForGPU(c.index)
                    try gpu.accumulate(image, into: sums, maps: maps, context: context, contribution: c, base: baseAlignment, analysis: (analysisWidth, analysisHeight),
                                       squares: squares)
                }
                lap("develop + accumulate")
            }
            if let squares, let first = sums.sky {
                clipping.measureFloor(sums: UnsafeBufferPointer(start: first.contents().bindMemory(to: Float.self, capacity: w * h * 4), count: w * h * 4),
                                      squares: UnsafeBufferPointer(start: squares.contents().bindMemory(to: Float.self, capacity: w * h), count: w * h))
                // The second pass, into a fresh sky sum, against the first pass's statistics.
                guard let second = gpu.buffer(width: w, height: h, channels: 4) else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos.")) }
                sums.sky = second
                for (done, c) in clipped.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    step(list.count + done, c.index, list.count + clipped.count + restoring.count)
                    try autoreleasepool {
                        let image = try developedForGPU(c.index)
                        try gpu.accumulate(image, into: sums, maps: maps, context: context, contribution: c, base: baseAlignment, analysis: (analysisWidth, analysisHeight),
                                           clip: (first, squares, clipping))
                    }
                    lap("develop + clip")
                }
            }
            try gpu.compose(sums, maps: maps, analysis: (analysisWidth, analysisHeight), minimumSkyWeight: minimumSkyWeight, keepClean: !plan.restore.isEmpty)
            lap("compose")
            for (done, i) in restoring.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(list.count + clipped.count + done, i, list.count + clipped.count + restoring.count)
                try autoreleasepool {
                    let image = try developedForGPU(i)
                    let lines = plan.restore.filter { $0.frame == i }
                    try gpu.restore(image, lines: lines, regions: lines.map { restoreRegion($0, plan: plan) }, into: sums, maps: maps, context: context, gain: gains[i],
                                    alignment: i == anchor || plan.restoreAsCaptured ? nil : alignments[i], base: plan.restoreAsCaptured ? nil : baseAlignment,
                                    analysis: (analysisWidth, analysisHeight))
                }
                lap("restore")
            }
            if !plan.regions.isEmpty {
                try gpu.applyRegions(sums, map: Self.regionMap(plan.regions, width: analysisWidth, height: analysisHeight), analysis: (analysisWidth, analysisHeight))
            }
            var raster = try gpu.output(sums)
            repairHotPixels(&raster)
            lap("copy out and repair hot pixels")
            return raster
        case .cpu:
            var sky = [Float](repeating: 0, count: plan.sky.isEmpty ? 0 : w * h * 4)
            var ground = [Float](repeating: 0, count: w * h * 4)
            var peak = [Float](repeating: -.infinity, count: plan.peak.isEmpty ? 0 : w * h * 4)
            var squares = [Float](repeating: 0, count: plan.rejectOutliers ? w * h : 0)
            var photo: [Float] = [], regionPhotoPixels: [Float] = []
            for (done, c) in list.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, c.index, list.count + clipped.count + restoring.count)
                try autoreleasepool {
                    let frame = try HDRMergeDecoder.decode(urls[c.index], metadata: metadata[c.index].base, longEdge: nil, whiteBalance: whiteBalance, context: context)
                    if c.isSkyPhoto { photo = frame.pixels.enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element * c.gain } }
                    if c.isSkyPhoto, !plan.regions.isEmpty { regionPhotoPixels = photo }
                    let background = c.detail ? localBackground(frame) : nil
                    accumulate(frame, contribution: c, base: baseAlignment, sky: &sky, ground: &ground, peak: &peak, squares: &squares, clip: nil, background: background)
                }
                lap("develop + accumulate")
            }
            if plan.rejectOutliers {
                let first = sky, firstSquares = squares
                first.withUnsafeBufferPointer { sums in firstSquares.withUnsafeBufferPointer { clipping.measureFloor(sums: sums, squares: $0) } }
                sky = [Float](repeating: 0, count: w * h * 4); squares = []
                for (done, c) in clipped.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    step(list.count + done, c.index, list.count + clipped.count + restoring.count)
                    try autoreleasepool {
                        let frame = try HDRMergeDecoder.decode(urls[c.index], metadata: metadata[c.index].base, longEdge: nil, whiteBalance: whiteBalance, context: context)
                        accumulate(frame, contribution: c, base: baseAlignment, sky: &sky, ground: &ground, peak: &peak, squares: &squares,
                                   clip: (first, firstSquares, clipping), background: nil)
                    }
                    lap("develop + clip")
                }
            }
            let probability = fullSizeProbability()
            var out = Self.compose(sky: sky, ground: ground, peak: peak, probability: probability, count: w * h, minimumSkyWeight: minimumSkyWeight,
                                   photo: plan.peakOverPhoto == nil ? [] : photo)
            sky = []; ground = []; peak = []; photo = []
            lap("compose")
            if !restoring.isEmpty {
                let clean = out
                var score = [Float](repeating: -.infinity, count: w * h)
                for (done, i) in restoring.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    step(list.count + clipped.count + done, i, list.count + clipped.count + restoring.count)
                    try autoreleasepool {
                        let frame = try HDRMergeDecoder.decode(urls[i], metadata: metadata[i].base, longEdge: nil, whiteBalance: whiteBalance, context: context)
                        for line in plan.restore where line.frame == i {
                            restore(frame, line: line, region: restoreRegion(line, plan: plan), base: plan.restoreAsCaptured ? nil : baseAlignment,
                                    alignment: line.frame == anchor || plan.restoreAsCaptured ? nil : alignments[line.frame], clean: clean, out: &out, score: &score)
                        }
                    }
                    lap("restore")
                }
            }
            if !plan.regions.isEmpty, !regionPhotoPixels.isEmpty {
                let regions = fullSize(Self.regionMap(plan.regions, width: analysisWidth, height: analysisHeight))
                for p in 0..<(w * h) where regions[p] > 0 {
                    for c in 0..<3 { out[p * 3 + c] += regions[p] * (regionPhotoPixels[p * 4 + c] - out[p * 3 + c]) }
                }
            }
            var rgba = [Float](repeating: 1, count: w * h * 4)
            for p in 0..<(w * h) { rgba[p * 4] = out[p * 3]; rgba[p * 4 + 1] = out[p * 3 + 1]; rgba[p * 4 + 2] = out[p * 3 + 2] }
            var raster = PanoramaRaster(width: w, height: h, rgba: rgba)
            repairHotPixels(&raster)
            return raster
        }
    }

    /// A fixed, averaged foreground with trails accumulated in capture order. Compose overwrites the ground
    /// buffer, so restore its sums before each frame. Only one output raster is held at a time; frames `wanted`
    /// turns down are accumulated but not composed. Frames are shrunk to `longEdge` when given, and glow by `glow` when given.
    /// `fading` meteors, left out of the plan's peak, are added to each frame from their own photo's light above its sky,
    /// as strong as the fade has it that many frames on.
    func trailAnimation(_ plan: Plan, glow: Float? = nil, fading: (lines: [NightSkyLine], fade: StarTrailsMeteorFade)? = nil, longEdge: Int? = nil,
                        lastLongEdge: Int? = nil, frames wanted: (Int) -> Bool = { _ in true },
                        progress: (String) -> Void = { _ in }, frame: (Int, PanoramaRaster) async throws -> Void) async throws {
        let w = width, h = height
        guard Double(w) * Double(h) * 80 < MemoryBudget.bytes else {
            throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos."))
        }
        try setSky(plan.skyShape)
        let gpu = NightSkyGPU(device: device)
        guard let sums = gpu.sums(width: w, height: h, sky: false, peak: true) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        let maps = try gpu.maps(probability: skyProbability, valid: skyValid)
        let base = plan.base == anchor ? nil : alignments[plan.base]
        if plan.peakOverPhoto != nil || !plan.regions.isEmpty {
            guard let photo = gpu.buffer(width: w, height: h, channels: 4) else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos.")) }
            sums.photo = photo
        }
        let list = contributions(plan)
        // Ground and painted regions stay fixed throughout, including when their source is a later photo.
        let fixed = list.filter { $0.ground || $0.isSkyPhoto }
        for (done, var c) in fixed.enumerated() {
            try Task.checkCancellation()
            progress(L10n.tr("Developing \(metadata[c.index].filename) (\(done + 1) of \(fixed.count))"))
            c.peak = false; c.detail = false; c.gap = nil
            try autoreleasepool {
                try gpu.accumulate(developedForGPU(c.index), into: sums, maps: maps, context: context,
                                   contribution: c, base: base, analysis: (analysisWidth, analysisHeight))
            }
        }
        let ground = Data(bytes: sums.ground.contents(), count: sums.ground.length)
        let finish = AnimationFrameFinish(self, longEdge: longEdge, glow: glow)
        // The last frame can be larger, for a still that ends the movie; glow is measured in proportion, so it looks the same.
        let lastFinish = lastLongEdge.map { AnimationFrameFinish(self, longEdge: $0, glow: glow) } ?? finish
        let peaks = list.filter(\.peak)
        var meteors: [(start: Int, light: MeteorLight)] = []
        var previous: (contribution: Contribution, developed: MTLTexture?)?
        for (index, original) in peaks.enumerated() {
            try Task.checkCancellation()
            // A gap only appears when its next exposure has arrived; it is drawn from that photo as it was developed.
            if let previous, previous.contribution.gap != nil, let developed = previous.developed {
                var c = previous.contribution
                c.ground = false; c.isSkyPhoto = false
                sums.texture = developed
                try autoreleasepool {
                    try gpu.accumulate(nil, into: sums, maps: maps, context: context, contribution: c, base: base, analysis: (analysisWidth, analysisHeight))
                }
            }
            var c = original
            c.ground = false; c.isSkyPhoto = false; c.gap = nil
            try autoreleasepool {
                try gpu.accumulate(developedForGPU(c.index), into: sums, maps: maps, context: context,
                                   contribution: c, base: base, analysis: (analysisWidth, analysisHeight))
            }
            // Composing lets the texture go; keep it for the gap after this photo.
            previous = (original, sums.texture)
            if let fading {
                for line in fading.lines where line.frame == c.index {
                    if let light = try meteorLight(line, plan: plan, gain: c.gain) { meteors.append((index, light)) }
                }
                meteors.removeAll { index - $0.start >= fading.fade.length }
            }
            guard wanted(index) else { continue }
            // Composing a frame in a pool of its own: this loop runs on a Swift concurrency thread, where nothing else
            // drains the Metal and Core Image objects each frame autoreleases, and a few hundred frames of them
            // reached an iPad's memory limit.
            let raster = try autoreleasepool { () -> PanoramaRaster in
                ground.withUnsafeBytes { bytes in _ = memcpy(sums.ground.contents(), bytes.baseAddress!, bytes.count) }
                try gpu.compose(sums, maps: maps, analysis: (analysisWidth, analysisHeight), minimumSkyWeight: 0, keepClean: false)
                if !plan.regions.isEmpty {
                    try gpu.applyRegions(sums, map: Self.regionMap(plan.regions, width: analysisWidth, height: analysisHeight), analysis: (analysisWidth, analysisHeight))
                }
                var raster = try gpu.output(sums)
                repairHotPixels(&raster)
                if let fading {
                    for meteor in meteors { meteor.light.add(to: &raster, strength: fading.fade.strength(age: index - meteor.start)) }
                }
                try (index == peaks.count - 1 ? lastFinish : finish)?.apply(to: &raster)
                return raster
            }
            try await frame(index, raster)
        }
    }

    /// A meteor's own light in a box around it at full size: its photo's pixels above the box's sky (each channel's
    /// median), times the photo's gain, inside the line's feathered footprint.
    struct MeteorLight {
        let x0: Int, y0: Int, width: Int, height: Int
        let rgb: [Float]
        func add(to raster: inout PanoramaRaster, strength: Float) {
            guard strength > 0 else { return }
            let w = raster.width
            for y in 0..<height where y0 + y < raster.height { for x in 0..<width where x0 + x < w {
                let p = ((y0 + y) * w + x0 + x) * 4, q = (y * width + x) * 3
                for c in 0..<3 { raster.rgba[p + c] += rgb[q + c] * strength }
            }}
        }
    }

    /// `line`'s light from its photo, developed as the stack develops it; nil when nothing stands above the sky. Star
    /// trails work in the camera's frame, so the photo's pixels are the frame's.
    func meteorLight(_ line: NightSkyLine, plan: Plan, gain: Float) throws -> MeteorLight? {
        let (x0, y0, x1, y1) = restoreRegion(line, plan: plan)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        guard w > 0, h > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        // Core Image's origin is the bottom left; the bitmap's first row is the box's top.
        let image = try developedForGPU(line.frame)
        context.render(image, toBitmap: &pixels, rowBytes: w * 16, bounds: CGRect(x: x0, y: height - 1 - y1, width: w, height: h),
                       format: .RGBAf, colorSpace: PanoramaDecoder.space)
        var sky = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            let values = stride(from: c, to: pixels.count, by: 4).map { pixels[$0] }.filter(\.isFinite).sorted()
            sky[c] = values.isEmpty ? 0 : values[values.count / 2]
        }
        var rgb = [Float](repeating: 0, count: w * h * 3), any = false
        for y in 0..<h { for x in 0..<w {
            let a = SIMD2((Double(x0 + x) + 0.5) / scale - 0.5, (Double(y0 + y) + 0.5) / scale - 0.5)
            let cover = line.coverage(a)
            guard cover > 0 else { continue }
            for c in 0..<3 {
                let v = pixels[(y * w + x) * 4 + c]
                let light = v.isFinite ? max(0, v - sky[c]) * gain * cover : 0
                rgb[(y * w + x) * 3 + c] = light; any = any || light > 0
            }
        }}
        return any ? MeteorLight(x0: x0, y0: y0, width: w, height: h, rgb: rgb) : nil
    }

    /// A photo developed at full size for the GPU. RAW photos stay a Core Image recipe that renders straight into the
    /// texture. Processed photos are developed into memory first: rendered straight into a Metal texture, Core Image gets
    /// the lower tiles of a large float TIFF wrong (rows past the middle of a 22-megapixel one came out darker), while
    /// rendering the same image to memory is right.
    func developedForGPU(_ i: Int) throws -> CIImage {
        if metadata[i].base.isRAW { return try HDRMergeDecoder.developedImage(urls[i], metadata: metadata[i].base, longEdge: nil, whiteBalance: whiteBalance) }
        let frame = try HDRMergeDecoder.decode(urls[i], metadata: metadata[i].base, longEdge: nil, whiteBalance: whiteBalance, context: context)
        let data = frame.pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: frame.width * 16, size: CGSize(width: frame.width, height: frame.height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
    }

    /// A photo's local background at full size, RGBA as developed (gain not applied): each channel's mean over a square
    /// window, shrunk at the edges, as the GPU's box blur and the preview compute it.
    func localBackground(_ frame: PanoramaFrame) -> [Float] {
        let w = frame.width, h = frame.height, radius = Int(Self.backgroundRadius)
        var out = [Float](repeating: 1, count: w * h * 4)
        for c in 0..<3 {
            let blurred = HDRMerger.boxBlur((0..<(w * h)).map { frame.pixels[$0 * 4 + c] }, width: w, height: h, radius: radius)
            for i in 0..<(w * h) { out[i * 4 + c] = blurred[i] }
        }
        return out
    }

    /// Full-size pixels around a line where the plan restores it: x0, y0, x1, y1 inclusive.
    func restoreRegion(_ line: NightSkyLine, plan: Plan) -> (Int, Int, Int, Int) {
        let s = scale
        let ends = [line.start, line.end].map { ((plan.restoreAsCaptured ? $0 : pointOnBase($0, base: plan.base)) + 0.5) * s - 0.5 }
        let margin = (line.radius + 3) * s
        return (max(0, Int(min(ends[0].x, ends[1].x) - margin)), max(0, Int(min(ends[0].y, ends[1].y) - margin)),
                min(width - 1, Int(max(ends[0].x, ends[1].x) + margin)), min(height - 1, Int(max(ends[0].y, ends[1].y) + margin)))
    }

    /// The sky probability at full size, bilinear, as the GPU samples it.
    func fullSizeProbability() -> [Float] { fullSize(skyProbability) }

    /// An analysis-size map at full size, bilinear, as the GPU samples it.
    func fullSize(_ map: [Float]) -> [Float] {
        let w = width, h = height, s = scale, aw = analysisWidth, ah = analysisHeight
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { out in
            map.withUnsafeBufferPointer { probability in
                let out = out
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let a = simd_clamp(SIMD2((Double(x) + 0.5) / s - 0.5, (Double(y) + 0.5) / s - 0.5), .zero, SIMD2(Double(aw - 1), Double(ah - 1)))
                        out[y * w + x] = Self.bilinear(probability, aw, ah, a, channels: 1)?.x ?? 0
                    }
                }
            }
        }
        return out
    }

    /// Where an output pixel's sky lies on the anchor's sky, in analysis pixels.
    @inline(__always) func anchorPoint(_ x: Int, _ y: Int, base: NightSkyAlignment?) -> SIMD2<Double> {
        let a = SIMD2((Double(x) + 0.5) / scale - 0.5, (Double(y) + 0.5) / scale - 0.5)
        return base?.apply(a) ?? a
    }

    /// One photo into the CPU sums. With `squares`, also Σ weight × luminance² of its sky samples; with `clip`, only the
    /// sky samples the first pass's statistics keep.
    private func accumulate(_ frame: PanoramaFrame, contribution c: Contribution, base: NightSkyAlignment?, sky: inout [Float], ground: inout [Float], peak: inout [Float],
                            squares: inout [Float], clip: (first: [Float], squares: [Float], clipping: Clipping)?, background: [Float]?) {
        let w = width, h = height, s = scale
        let probability = skyProbability, aw = analysisWidth, ah = analysisHeight
        frame.pixels.withUnsafeBufferPointer { pixels in
            sky.withUnsafeMutableBufferPointer { sky in
                ground.withUnsafeMutableBufferPointer { ground in
                    peak.withUnsafeMutableBufferPointer { peak in
                      squares.withUnsafeMutableBufferPointer { squares in
                        let sky = sky, ground = ground, peak = peak, squares = squares
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w {
                                let p = y * w + x, q = p * 4
                                let v = SIMD3(pixels[q], pixels[q + 1], pixels[q + 2]) * c.gain
                                let camera = SIMD2((Double(x) + 0.5) / s - 0.5, (Double(y) + 0.5) / s - 0.5)
                                if c.ground { ground[q] += v.x * c.weight; ground[q + 1] += v.y * c.weight; ground[q + 2] += v.z * c.weight; ground[q + 3] += c.weight }
                                // With a background, the peak takes the detail above it, as the GPU does.
                                func detail(_ value: SIMD3<Float>, _ s: SIMD2<Double>) -> SIMD3<Float>? {
                                    guard let background else { return value }
                                    guard let b = background.withUnsafeBufferPointer({ Self.bilinear($0, w, h, (s + 0.5) * scale - 0.5, channels: 4) }) else { return nil }
                                    return value - b * c.gain
                                }
                                if c.peak, !c.peakLines.contains(where: { $0.distance(camera) <= $0.radius }) {
                                    let b = background.map { SIMD3($0[q], $0[q + 1], $0[q + 2]) * c.gain } ?? .zero
                                    Self.raise(peak, q, v - b, mode: c.peakColor ? .color : .channels)
                                }
                                if c.peak, let gap = c.gap {
                                    // The motion toward the next photo, as the GPU computes it: this photo's map, then the next one's inverse.
                                    let a = gap.own?.apply(camera) ?? camera
                                    let d = (gap.next?.sourcePoint(a) ?? a) - camera
                                    for t in gap.steps {
                                        let s = camera - Double(t) * d
                                        guard isSky(s), !c.peakLines.contains(where: { $0.distance(s) <= $0.radius }),
                                              let sample = Self.bilinear(pixels, w, h, (s + 0.5) * scale - 0.5, channels: 4),
                                              let value = detail(sample * c.gain, s) else { continue }
                                        Self.raise(peak, q, value, mode: c.peakColor ? .color : .channels)
                                    }
                                }
                                guard c.sky, Self.sample(probability, aw, ah, camera) > 0.01 else { continue }
                                let a = base?.apply(camera) ?? camera
                                guard !c.skyLines.contains(where: { $0.distance(a) <= $0.radius }) else { continue }
                                let source = c.alignment?.sourcePoint(a) ?? a
                                guard isSky(source), let sample = Self.bilinear(pixels, w, h, (source + 0.5) * s - 0.5, channels: 4) else { continue }
                                let l = simd_dot(sample * c.gain, SIMD3(0.2126, 0.7152, 0.0722))
                                if let clip {
                                    if clip.clipping.agreeWithBase {
                                        // The ground is the base photo alone, summed in the first pass.
                                        if ground[q + 3] > 0, !clip.clipping.agrees(l, base: simd_dot(SIMD3(ground[q], ground[q + 1], ground[q + 2]), SIMD3(0.2126, 0.7152, 0.0722)) / ground[q + 3]) { continue }
                                    } else if !clip.clipping.keeps(l, weight: c.weight, sum: SIMD4(clip.first[q], clip.first[q + 1], clip.first[q + 2], clip.first[q + 3]), squares: clip.squares[p]) { continue }
                                }
                                let value = sample * c.gain * c.weight
                                sky[q] += value.x; sky[q + 1] += value.y; sky[q + 2] += value.z; sky[q + 3] += c.weight
                                if !squares.isEmpty { squares[p] += c.weight * l * l }
                            }
                        }
                      }
                    }
                }
            }
        }
    }

    /// One line from its photo into the CPU result: the photo's own pixels inside the feathered footprint, the most
    /// prominent line winning where lines overlap.
    private func restore(_ frame: PanoramaFrame, line: NightSkyLine, region: (Int, Int, Int, Int), base: NightSkyAlignment?, alignment: NightSkyAlignment?,
                         clean: [Float], out: inout [Float], score: inout [Float]) {
        let w = width, h = height, s = scale, gain = gains[line.frame]
        guard region.2 >= region.0, region.3 >= region.1 else { return }
        frame.pixels.withUnsafeBufferPointer { pixels in
            for y in region.1...region.3 { for x in region.0...region.2 {
                let p = y * w + x
                let a = anchorPoint(x, y, base: base)
                let alpha = line.coverage(a)
                guard alpha > 0 else { continue }
                let source = alignment?.sourcePoint(a) ?? a
                guard isSky(source), let sample = Self.bilinear(pixels, w, h, (source + 0.5) * s - 0.5, channels: 4) else { continue }
                let value = sample * gain, background = SIMD3(clean[p * 3], clean[p * 3 + 1], clean[p * 3 + 2])
                // The line's light above its own photo's sky beside it; without enough sky to read there, above the result's.
                let probes = line.skyProbes(a).compactMap { probe -> SIMD3<Float>? in
                    let from = alignment?.sourcePoint(probe) ?? probe
                    guard isSky(from) else { return nil }
                    return Self.bilinear(pixels, w, h, (from + 0.5) * s - 0.5, channels: 4).map { $0 * gain }
                }
                let light = value - (NightSkyLine.localSky(probes) ?? background)
                // A meteor only adds light: a darker sample is the photo's own noise or edge, never restored.
                let candidate = alpha * simd_dot(light, SIMD3(0.2126, 0.7152, 0.0722))
                guard candidate > max(0, score[p]) else { continue }
                score[p] = candidate
                let v = background + alpha * light
                out[p * 3] = v.x; out[p * 3 + 1] = v.y; out[p * 3 + 2] = v.z
            }}
        }
    }
}

/// The last steps of an animation frame: shrunk to the size the video needs, then, for Smooth, a slight glow around
/// stars and trails in the sky only: their light well above the local sky, blurred a little and added back, as a
/// lens's own bloom would. The glow is sized to the photo, so it reads the same at any video size.
struct AnimationFrameFinish {
    let context: CIContext
    let width: Int, height: Int
    /// Sky probability at the frame's size, top row first; empty without glow.
    private let sky: [Float]
    /// The halo's Gaussian sigma in output pixels; the local sky is measured over eight times that.
    private let sigma: Double
    /// How much of the halo is added back.
    private let strength: Float
    /// Only light this many times the local sky glows, so the sky's own noise doesn't lift it.
    static let floor: Float = 1.5

    /// Nil when the frame stays as stacked: full size and no glow.
    init?(_ analyzer: NightSkyAnalyzer, longEdge: Int?, glow: Float?) {
        let full = max(analyzer.width, analyzer.height)
        let scale = min(1, Double(longEdge ?? full) / Double(full))
        guard scale < 1 || glow != nil else { return nil }
        strength = glow ?? 0
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        width = max(1, Int((Double(analyzer.width) * scale).rounded()))
        height = max(1, Int((Double(analyzer.height) * scale).rounded()))
        sigma = max(0.75, Double(full) / 2000 * scale)
        sky = glow != nil ? Self.resample(analyzer.skyProbability, from: (analyzer.analysisWidth, analyzer.analysisHeight), to: (width, height)) : []
    }

    func apply(to raster: inout PanoramaRaster) throws {
        if raster.width != width || raster.height != height { raster = try resized(raster) }
        guard !sky.isEmpty else { return }
        let w = raster.width, h = raster.height, count = w * h
        // The local sky, then what stands well above it in the sky alone, then that blurred into a halo.
        var buffer = try render(raster.rgba, w, h, to: (w, h)) { $0.clampedToExtent().applyingGaussianBlur(sigma: sigma * 8) }
        buffer.withUnsafeMutableBufferPointer { detail in
            raster.rgba.withUnsafeBufferPointer { image in
                sky.withUnsafeBufferPointer { sky in
                    let detail = detail
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for p in (y * w)..<((y + 1) * w) {
                            for c in 0..<3 { detail[p * 4 + c] = max(0, image[p * 4 + c] - Self.floor * detail[p * 4 + c]) * sky[p] }
                            detail[p * 4 + 3] = 1
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        var halo = try render(buffer, w, h, to: (w, h)) { $0.clampedToExtent().applyingGaussianBlur(sigma: sigma) }
        var strength = strength, one: Float = 1
        halo.withUnsafeMutableBufferPointer { halo in
            raster.rgba.withUnsafeBufferPointer { vDSP_vsma(halo.baseAddress!, 1, &strength, $0.baseAddress!, 1, halo.baseAddress!, 1, vDSP_Length(count * 4)) }
            vDSP_vfill(&one, halo.baseAddress! + 3, 4, vDSP_Length(count))
        }
        raster = PanoramaRaster(width: w, height: h, rgba: halo)
    }

    private func resized(_ raster: PanoramaRaster) throws -> PanoramaRaster {
        let scale = Double(height) / Double(raster.height), aspect = Double(width) / Double(raster.width) / scale
        let rgba = try render(raster.rgba, raster.width, raster.height, to: (width, height)) {
            $0.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect])
        }
        return PanoramaRaster(width: width, height: height, rgba: rgba)
    }

    /// `rgba` (`w` × `h`, top row first) through `filter`, rendered at `size`. The pixels are read in place.
    private func render(_ rgba: [Float], _ w: Int, _ h: Int, to size: (Int, Int), filter: (CIImage) -> CIImage) throws -> [Float] {
        let bounds = CGRect(x: 0, y: 0, width: size.0, height: size.1)
        var out = [Float](repeating: 0, count: size.0 * size.1 * 4)
        try rgba.withUnsafeBytes { bytes in
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none)
            let image = filter(CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil))
            try out.withUnsafeMutableBytes { target in
                context.render(image.cropped(to: bounds), toBitmap: target.baseAddress!, rowBytes: size.0 * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
                if Task.isCancelled { throw CancellationError() }
            }
        }
        return out
    }

    /// A map resampled bilinearly about pixel centers, edges extended.
    static func resample(_ map: [Float], from: (Int, Int), to: (Int, Int)) -> [Float] {
        let (aw, ah) = from, (w, h) = to
        let sx = Double(aw) / Double(w), sy = Double(ah) / Double(h)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { out in
            map.withUnsafeBufferPointer { map in
                let out = out
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let fy = min(max(0, (Double(y) + 0.5) * sy - 0.5), Double(ah - 1))
                    let y0 = Int(fy), y1 = min(ah - 1, y0 + 1), ty = Float(fy - Double(y0))
                    for x in 0..<w {
                        let fx = min(max(0, (Double(x) + 0.5) * sx - 0.5), Double(aw - 1))
                        let x0 = Int(fx), x1 = min(aw - 1, x0 + 1), tx = Float(fx - Double(x0))
                        let top = map[y0 * aw + x0] * (1 - tx) + map[y0 * aw + x1] * tx
                        let bottom = map[y1 * aw + x0] * (1 - tx) + map[y1 * aw + x1] * tx
                        out[y * w + x] = top * (1 - ty) + bottom * ty
                    }
                }
            }
        }
        return out
    }
}
