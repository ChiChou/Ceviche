import Foundation
import CoreImage
import Metal
import simd

/// Stacks photos of one scene into a linear DNG: the median removes people and traffic that move through the frame,
/// the mean smooths water and lowers noise, the maximum and minimum keep the brightest or darkest value. Analyze once
/// (develop reduced copies, align them to the middle photo, even out exposure), preview each choice from that, then
/// stack at full size. Use from one task at a time; long steps check `Task.isCancelled`.
///
/// At full size each photo is developed, aligned and stored in half floats, then the stack is reduced band by band
/// so memory holds the photos once rather than a sorted copy of them. Both steps run on the GPU; the CPU path does the
/// same arithmetic where Metal is unavailable and draws the preview.
public final class PhotoStacker: @unchecked Sendable {
    public let urls: [URL]
    /// Each photo's own retouching, AI fills included, burnt into it when the result is rendered at full size. The
    /// photos are aligned and analysed without it, so a fill or patch never moves what alignment matches.
    public var retouch: [URL: [RetouchStroke]] = [:]
    public private(set) var analysis: PhotoStackAnalysis?

    /// A Core Image context for one decode or render, in half floats (frames are stored as Float16): one kept for the
    /// whole stack held every RAW decoder surface it had used until the stack ended. Callers that decode side by side take
    /// one and share it.
    private var context: CIContext {
        let options: [CIContextOption: Any] = [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        return device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }
    private let device: MTLDevice?
    private lazy var gpu: PhotoStackGPU? = device.flatMap { try? PhotoStackGPU(device: $0) }
    private var metadata: [HDRMergeFrameMetadata] = []
    private var whiteBalance = (temperature: 5000.0, tint: 0.0)
    private var reference = 0
    /// Per photo, in the order of `urls`: multiplier onto the reference's exposure.
    private var gains: [Float] = []
    private var transforms: [HDRSimilarity] = []
    /// Whether each photo's movement could be measured; the others are used as framed.
    private var measured: [Bool] = []
    /// Reduced copies warped onto the reference, RGBA with coverage in alpha.
    private var aligned: [[Float]] = []
    private var analysisWidth = 0, analysisHeight = 0

    static let analysisLongEdge = 1600
    /// The GPU reduce keeps every photo's sample of a pixel in registers; larger stacks reduce on the CPU.
    static let gpuFrameLimit = 128

    public init(urls: [URL]) throws {
        guard urls.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose at least two photos to stack.")) }
        self.urls = urls
        device = MTLCreateSystemDefaultDevice()
    }

    // MARK: Analysis

    public func analyze(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PhotoStackAnalysis {
        let count = urls.count
        let frames = try urls.map { try HDRMergeDecoder.metadata($0) }
        if Set(frames.map(\.isRAW)).count > 1 {
            throw PanoramaError.message(L10n.tr("Stack RAW photos or processed photos, not both."))
        }
        if Set(frames.map { "\($0.width)×\($0.height)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos have different sizes. A stack needs photos of the same size and orientation."))
        }
        let reference = count / 2
        let whiteBalance = (temperature: frames[reference].temperature, tint: frames[reference].tint)
        var decoded = [PanoramaFrame?](repeating: nil, count: count)
        var failures = [String?](repeating: nil, count: count)
        let lock = NSLock()
        var done = 0
        let urls = self.urls, context = self.context
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard !Task.isCancelled else { return }
            do {
                let frame = try HDRMergeDecoder.decode(urls[i], metadata: frames[i], longEdge: Self.analysisLongEdge, whiteBalance: whiteBalance, context: context)
                let finished = lock.withLock { decoded[i] = frame; done += 1; return done }
                progress(0.6 * Double(finished) / Double(count), L10n.tr("Reading \(frames[i].filename)"))
            } catch { lock.withLock { failures[i] = error.localizedDescription } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure = failures.compactMap({ $0 }).first { throw PanoramaError.message(failure) }
        let sources = decoded.map { $0! }
        // Aligned on the photos as shot; shown and stacked with their retouching.
        let shown = sources.indices.map { PanoramaDecoder.retouched(sources[$0], retouch[urls[$0]] ?? []) }
        let width = sources.map(\.width).min()!, height = sources.map(\.height).min()!

        progress(0.65, L10n.tr("Aligning photos"))
        let planes = sources.map { LuminancePlane($0, longEdge: Self.analysisLongEdge) }
        let floor: Float = frames[0].isRAW ? 0.002 : 0.004
        var features = [[PanoramaFeature]](repeating: [], count: count)
        features.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out[i] = PanoramaFeatures.detect(HDRMergeAlignment.equalized(planes[i], floor: floor), limit: 2000)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        var transforms = [HDRSimilarity](repeating: .identity, count: count)
        var measured = [Bool](repeating: true, count: count)
        // Directly onto the reference, or else through the neighbour toward it: in a long series the scene drifts.
        var direct = [HDRSimilarity?](repeating: nil, count: count)
        direct.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                if i != reference { out[i] = HDRMergeAlignment.estimate(frame: features[i], reference: features[reference])?.0 }
            }
        }
        var solved: [Int: HDRSimilarity?] = [reference: .identity]
        func transform(_ i: Int) -> HDRSimilarity? {
            if let known = solved[i] { return known }
            var result = direct[i]
            if result == nil {
                let neighbour = i < reference ? i + 1 : i - 1
                if neighbour != reference, let link = HDRMergeAlignment.estimate(frame: features[i], reference: features[neighbour])?.0,
                   let rest = transform(neighbour) { result = rest.after(link) }
            }
            solved[i] = result
            return result
        }
        // Nearest the reference first, so chains find their links already solved.
        for i in (0..<count).sorted(by: { abs($0 - reference) < abs($1 - reference) }) where i != reference {
            if let model = transform(i) {
                // From a tripod a sub-pixel estimate is noise, and resampling would only soften the photo.
                transforms[i] = model.displacement(width: Double(width), height: Double(height)) < 0.3 ? .identity : model
            } else { measured[i] = false }
        }

        progress(0.85, L10n.tr("Matching exposure"))
        var aligned = [[Float]](repeating: [], count: count)
        aligned.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = HDRMerger.warp(shown[i], transforms[i].inverse, width: width, height: height) }
        }
        let gains = (0..<count).map { Self.gain(aligned[$0], onto: aligned[reference], isRAW: frames[0].isRAW) }

        let scale = Double(frames[0].width) / Double(width)
        let infos = (0..<count).map { i in
            PhotoStackFrameInfo(index: i, filename: frames[i].filename, stops: -Double(log2(gains[i])),
                                shift: measured[i] ? transforms[i].translation * scale : nil,
                                rotationDegrees: measured[i] ? transforms[i].rotationDegrees : nil,
                                thumbnail: PanoramaFinishing.picture(PanoramaRaster(width: sources[i].width, height: sources[i].height, rgba: shown[i].pixels), maxDimension: 240))
        }
        let analysis = PhotoStackAnalysis(frames: infos, reference: reference, width: frames[0].width, height: frames[0].height)
        self.metadata = frames; self.whiteBalance = whiteBalance; self.reference = reference; self.gains = gains
        self.transforms = transforms; self.measured = measured; self.aligned = aligned; analysisWidth = width; analysisHeight = height; self.analysis = analysis
        progress(1, "")
        return analysis
    }

    /// Makes photo `index` the one the others are aligned to and whose exposure the stack keeps, without analysing
    /// again: each transform is followed by the inverse of the new reference's, the gains are divided by its gain, and
    /// the reduced copies are warped once more for the preview (the full-size stack develops from the originals).
    /// Not while a preview or stack is running.
    @discardableResult
    public func setReference(_ index: Int) -> PhotoStackAnalysis? {
        guard let analysis, urls.indices.contains(index), index != reference else { return self.analysis }
        let back = transforms[index].inverse, gain = gains[index]
        let width = analysisWidth, height = analysisHeight
        // Photos used as framed stay as framed against the new reference too.
        let moved = urls.indices.map { i in i == index || !measured[i] ? HDRSimilarity.identity : back.after(transforms[i]) }
        let pull = transforms[index]
        var warped = aligned
        warped.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                // Where the new reference sits in the old one's frame: every reduced copy is sampled there.
                out[i] = measured[i] ? Self.resample(aligned[i], width: width, height: height, at: pull) : aligned[i]
            }
        }
        aligned = warped
        weightCache = nil; regionCache = nil; noiseCache = nil; skyCache = nil
        transforms = moved
        gains = gains.map { $0 / gain }
        reference = index
        let scale = Double(analysis.width) / Double(width)
        let frames = analysis.frames.map { frame in
            let i = frame.index
            return PhotoStackFrameInfo(index: i, filename: frame.filename, stops: -Double(log2(gains[i])),
                                       shift: measured[i] ? transforms[i].translation * scale : nil,
                                       rotationDegrees: measured[i] ? transforms[i].rotationDegrees : nil, thumbnail: frame.thumbnail)
        }
        let updated = PhotoStackAnalysis(frames: frames, reference: index, width: analysis.width, height: analysis.height)
        self.analysis = updated
        return updated
    }

    /// RGBA with coverage in alpha, sampled at `transform` of each output pixel: colour bilinear among covered
    /// neighbours, coverage bilinear, nothing outside.
    static func resample(_ pixels: [Float], width: Int, height: Int, at transform: HDRSimilarity) -> [Float] {
        var out = [Float](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let p = transform.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
                        guard p.x >= -0.5, p.y >= -0.5, p.x <= Double(width) - 0.5, p.y <= Double(height) - 0.5 else { continue }
                        let x0 = max(0, min(width - 1, Int(p.x.rounded(.down)))), y0 = max(0, min(height - 1, Int(p.y.rounded(.down))))
                        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
                        let fx = Float(max(0, min(1, p.x - Double(x0)))), fy = Float(max(0, min(1, p.y - Double(y0))))
                        var colour = SIMD3<Float>.zero, cover: Float = 0, weight: Float = 0
                        for (sx, sy, w) in [(x0, y0, (1 - fx) * (1 - fy)), (x1, y0, fx * (1 - fy)), (x0, y1, (1 - fx) * fy), (x1, y1, fx * fy)] {
                            let i = (sy * width + sx) * 4, a = source[i + 3]
                            cover += a * w
                            if a > 0 { colour += SIMD3(source[i], source[i + 1], source[i + 2]) * w; weight += w }
                        }
                        let o = (y * width + x) * 4
                        if weight > 0 { colour /= weight }
                        out[o] = colour.x; out[o + 1] = colour.y; out[o + 2] = colour.z; out[o + 3] = cover
                    }
                }
            }
        }
        return out
    }

    /// The multiplier bringing `frame` onto `reference`'s exposure: the median luminance ratio where both are well
    /// exposed. Auto exposure and changing light drift by fractions of a stop through a series; left in, the median
    /// would switch between photos of different brightness pixel by pixel.
    static func gain(_ frame: [Float], onto reference: [Float], isRAW: Bool) -> Float {
        guard frame != reference else { return 1 }
        let floor: Float = isRAW ? 0.01 : 0.03, shoulder: Float = isRAW ? 0.8 : 0.9
        var ratios: [Float] = []
        ratios.reserveCapacity(frame.count / 16)
        for p in stride(from: 0, to: frame.count, by: 4 * 3) where frame[p + 3] > 0.999 && reference[p + 3] > 0.999 {
            let a = HDRMerger.luminance(frame, p), b = HDRMerger.luminance(reference, p)
            guard a > floor, b > floor, a < shoulder, b < shoulder else { continue }
            ratios.append(log2(b / a))
        }
        guard ratios.count >= 200 else { return 1 }
        ratios.sort()
        // Within a stop either way: a larger difference is a different scene, not drift, and is left alone.
        return exp2(max(-1, min(1, ratios[ratios.count / 2])))
    }

    private func members(_ settings: PhotoStackSettings) throws -> [Int] {
        guard analysis != nil else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let included = urls.indices.filter { !settings.excluded.contains($0) }
        guard included.count >= 2 else { throw PanoramaError.message(L10n.tr("Include at least two photos.")) }
        return included
    }

    // MARK: Preview

    public func preview(_ settings: PhotoStackSettings) throws -> PhotoStackPreview {
        let raster = try previewRaster(settings)
        guard let image = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview could not be drawn.")) }
        let included = try members(settings)
        var chosen = try weights(settings, included: included)
        if settings.mode.blendsOverBase { chosen = .init(planes: hidden(settings.strokes, included: included)) }
        var opaque = raster
        for p in stride(from: 3, to: opaque.rgba.count, by: 4) { opaque.rgba[p] = 1 }
        let source = MergePreviewSource(raster: opaque, writer: ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata[reference].panorama, kind: .stack,
            source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.stack.rawValue)), source: urls[reference]), base: reference)
        return PhotoStackPreview(image: image, painted: chosen.planes.compactMapValues { HDRMergeFinishing.gray($0, width: analysisWidth, height: analysisHeight) },
                                 leftOut: chosen.leftOut, settings: settings, source: source)
    }

    /// One photo as the stack sees it, aligned and evened out, for choosing what to brush in.
    public func picture(of index: Int) -> CGImage? {
        guard analysis != nil, aligned.indices.contains(index) else { return nil }
        var rgba = aligned[index]
        let gain = gains[index]
        for p in stride(from: 0, to: rgba.count, by: 4) { rgba[p] *= gain; rgba[p + 1] *= gain; rgba[p + 2] *= gain; rgba[p + 3] = 1 }
        return HDRMergeFinishing.picture(PanoramaRaster(width: analysisWidth, height: analysisHeight, rgba: rgba))
    }

    /// The last weights, for what they were made from.
    private var weightCache: (strokes: [PhotoStackStroke], regions: PhotoStackOverlap?, ground: PhotoStackGround, included: [Int], chosen: PhotoStackRegions.Choice)?
    private var regionCache: (overlap: PhotoStackOverlap, included: [Int], chosen: PhotoStackRegions.Choice)?

    /// Where single photos show instead of the stack, as one soft weight per photo at the preview's size: Action
    /// Sequence's regions, then the frame brush over them. Painting a photo raises its weight and lowers the others',
    /// so they never sum past 1. Weights, not a map of which photo: a soft weight is what scales up cleanly to the
    /// full size.
    func weights(_ settings: PhotoStackSettings, included: [Int]) throws -> PhotoStackRegions.Choice {
        let usable = settings.mode.blendsOverBase ? [] : settings.strokes.filter { $0.hides == nil && ($0.photo.map(included.contains) ?? true) }
        let regions = settings.mode == .sequence ? settings.overlap : nil
        let ground = settings.mode.keepsGround ? settings.ground : .stack
        guard regions != nil || ground != .stack || usable.contains(where: { $0.photo != nil }) else { return .init() }
        if let cache = weightCache, cache.strokes == usable, cache.regions == regions, cache.ground == ground, cache.included == included { return cache.chosen }
        let width = analysisWidth, height = analysisHeight, unit = Double(width)
        var chosen = PhotoStackRegions.Choice()
        if let regions {
            // Kept from one stroke to the next: finding the regions is the slow part.
            if let cache = regionCache, cache.overlap == regions, cache.included == included { chosen = cache.chosen }
            else {
                chosen = PhotoStackRegions.choose(frames: included.map { aligned[$0] }, gains: included.map { gains[$0] }, photos: included,
                                                  background: reduced(.median, included: included), width: width, height: height, overlap: regions)
                regionCache = (regions, included, chosen)
            }
        }
        var planes = chosen.planes
        // Below the sky the median or the base photo, before the brush has its say.
        if ground != .stack { planes[ground == .base ? reference : PhotoStackRegions.median] = try sky().map { 1 - $0 } }
        for stroke in usable {
            // Fractions of the width to pixel indices, whose centres lie at whole numbers.
            let dab = HDRMerger.softDisc(SIMD2(stroke.x, stroke.y) * unit - 0.5, radius: stroke.radius * unit, width: width, height: height)
            if let photo = stroke.photo, planes[photo] == nil { planes[photo] = [Float](repeating: 0, count: width * height) }
            for key in planes.keys {
                planes[key]!.withUnsafeMutableBufferPointer { plane in
                    if key == stroke.photo { for (k, a) in dab { plane[k] = a + (1 - a) * plane[k] } }
                    else { for (k, a) in dab { plane[k] *= 1 - a } }
                }
            }
        }
        chosen.planes = planes.filter { $0.value.contains { $0 > 0.002 } }
        weightCache = (usable, regions, ground, included, chosen)
        return chosen
    }

    private var skyCache: [Float]?

    /// Where the base photo shows sky, 0…1 at the preview's size: the Sky model, refined against the photo as Sky
    /// masks are. The series' own motion can't stand in for it: where people walk, 71 % of what moves is the ground.
    private func sky() throws -> [Float] {
        if let skyCache { return skyCache }
        let width = analysisWidth, height = analysisHeight
        let image = CIImage(bitmapData: aligned[reference].withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        let small = try SkyMaskModel.loadBundled().coarseMask(for: image, context: context)
        let refined = MaskRefinement.sky.apply(small, guide: image).applyingFilter("CISRGBToneCurveToLinear")
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(refined, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        }
        let plane = (0..<(width * height)).map { max(0, min(1, pixels[$0 * 4])) }
        skyCache = plane
        return plane
    }

    /// Lighten and Darken's brush: per photo, where its light is brushed out, 1 where wholly, at the preview's size.
    func hidden(_ strokes: [PhotoStackStroke], included: [Int]) -> [Int: [Float]] {
        let width = analysisWidth, height = analysisHeight, unit = Double(width)
        var planes: [Int: [Float]] = [:]
        for stroke in strokes {
            guard let hides = stroke.hides, let photo = stroke.photo, included.contains(photo), hides || planes[photo] != nil else { continue }
            let dab = HDRMerger.softDisc(SIMD2(stroke.x, stroke.y) * unit - 0.5, radius: stroke.radius * unit, width: width, height: height)
            var plane = planes[photo] ?? [Float](repeating: 0, count: width * height)
            if hides { for (k, a) in dab { plane[k] = a + (1 - a) * plane[k] } } else { for (k, a) in dab { plane[k] *= 1 - a } }
            planes[photo] = plane
        }
        return planes.filter { $0.value.contains { $0 > 0.002 } }
    }

    private var noiseCache: (included: [Int], full: Bool, noise: PhotoStackBlend.Noise)?

    /// Lighten or Darken over the base photo. `rows` reads frame k of `order` (the base first) at the size blended;
    /// the noise is measured at that size, since reducing a photo lowers it.
    private func blend(_ settings: PhotoStackSettings, order: [Int], rows: PhotoStackBlend.Rows, width: Int, height: Int, full: Bool,
                       into out: UnsafeMutablePointer<Float>) {
        let radius = PhotoStackBlend.radius(width: width, fullWidth: analysis?.width ?? width)
        let noise: PhotoStackBlend.Noise
        if let cache = noiseCache, cache.included == order, cache.full == full { noise = cache.noise }
        else {
            noise = PhotoStackBlend.noise(frames: order.count, rows: rows, width: width, height: height, radius: radius)
            noiseCache = (order, full, noise)
        }
        let brushed = hidden(settings.strokes, included: order)
        let passes = order.dropFirst().map { photo in
            PhotoStackBlend.Pass(strength: Float(max(0, min(1, settings.strengths[photo] ?? 1))), hidden: brushed[photo], hiddenWidth: analysisWidth)
        }
        PhotoStackBlend.blend(passes: passes, rows: rows, width: width, height: height, radius: radius, noise: noise, darken: settings.mode == .darken,
                              strokesOnly: settings.strokesOnly, into: out, cancelled: { Task.isCancelled })
    }

    /// The base photo first, then the others in capture order.
    private func blendOrder(_ included: [Int]) -> [Int] { [reference] + included.filter { $0 != reference } }

    /// The photo with the least light (or the most): Lighten's natural base is the ambient frame, Darken's the
    /// brightest.
    public func extreme(brightest: Bool) -> Int? {
        guard analysis != nil else { return nil }
        let means = aligned.map { frame -> Float in
            var sum: Float = 0
            for p in stride(from: 0, to: frame.count, by: 4 * 7) { sum += HDRMerger.luminance(frame, p) }
            return sum
        }
        return brightest ? means.indices.max { means[$0] < means[$1] } : means.indices.min { means[$0] < means[$1] }
    }

    /// The photos reduced to one at the preview's size, RGBA.
    private func reduced(_ mode: PhotoStackMode, included: [Int]) -> [Float] {
        let width = analysisWidth, height = analysisHeight
        var out = [Float](repeating: 0, count: width * height * 4)
        let frames = included.map { aligned[$0] }, gains = included.map { self.gains[$0] }
        frames.withUnsafeBufferPointer { frames in
            out.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var scratch = PhotoStackReduce.Scratch(count: frames.count)
                    for x in 0..<width {
                        let p = (y * width + x) * 4
                        let value = PhotoStackReduce.pixel(mode, count: frames.count, scratch: &scratch) { k in
                            frames[k][p + 3] > 0.999 ? SIMD3(frames[k][p], frames[k][p + 1], frames[k][p + 2]) * gains[k] : nil
                        }
                        out[p] = value.x; out[p + 1] = value.y; out[p + 2] = value.z; out[p + 3] = 1
                    }
                }
            }
        }
        return out
    }

    func previewRaster(_ settings: PhotoStackSettings) throws -> PanoramaRaster {
        let included = try members(settings)
        let width = analysisWidth, height = analysisHeight
        if settings.mode.blendsOverBase {
            // As exposed: a lighting pass is brighter because of its light, which evening out would take away.
            var out = [Float](repeating: 0, count: width * height * 4)
            let order = blendOrder(included), frames = order.map { aligned[$0] }
            out.withUnsafeMutableBufferPointer { out in
                blend(settings, order: order, rows: { k, y, row in
                    frames[k].withUnsafeBufferPointer { row.update(from: $0.baseAddress! + y * width * 4, count: width * 4) }
                }, width: width, height: height, full: false, into: out.baseAddress!)
            }
            if Task.isCancelled { throw CancellationError() }
            return PanoramaRaster(width: width, height: height, rgba: out)
        }
        var out = reduced(settings.mode, included: included)
        if Task.isCancelled { throw CancellationError() }
        // The regions', the ground's and the brushed photos over the stack, each by its share.
        let planes = try weights(settings, included: included).planes
        guard !planes.isEmpty else { return PanoramaRaster(width: width, height: height, rgba: out) }
        var total = [Float](repeating: 0, count: width * height), sum = [Float](repeating: 0, count: width * height * 3)
        for (photo, plane) in planes {
            let isMedian = photo == PhotoStackRegions.median
            let frame = isMedian ? reduced(.median, included: included) : aligned[photo], gain = isMedian ? 1 : self.gains[photo]
            for i in 0..<(width * height) {
                let w = plane[i]
                guard w > 0, frame[i * 4 + 3] > 0.999 else { continue }
                total[i] += w
                for c in 0..<3 { sum[i * 3 + c] += frame[i * 4 + c] * gain * w }
            }
        }
        for i in 0..<(width * height) where total[i] > 0 {
            let share = min(1, total[i]), scale = share / total[i]
            for c in 0..<3 { out[i * 4 + c] = out[i * 4 + c] * (1 - share) + sum[i * 3 + c] * scale }
        }
        return PanoramaRaster(width: width, height: height, rgba: out)
    }

    /// Lays the photos that show alone (Action Sequence's regions, the frame brush) over the full-size stack. Each photo's weight is scaled up from the preview's size
    /// edge-aware against the stack itself, so the boundary follows the picture's edges: scaled up as blocks it leaves
    /// 3.75-pixel steps and fragments of passers-by (residue 4.9 % against 1.2 %, seams 1.66 times the photo's own).
    private func composite(_ planes: [Int: [Float]], over raster: inout PanoramaRaster, included: [Int], store: PhotoStackStore, median: PanoramaRaster?) throws {
        guard !planes.isEmpty else { return }
        let width = raster.width, height = raster.height, pixels = width * height
        var total = [Float](repeating: 0, count: pixels), sum = [Float](repeating: 0, count: pixels * 3)
        var refined = [Float](repeating: 0, count: pixels)
        for (photo, plane) in planes.sorted(by: { $0.key < $1.key }) {
            let k = included.firstIndex(of: photo)
            guard k != nil || (photo == PhotoStackRegions.median && median != nil) else { continue }
            if Task.isCancelled { throw CancellationError() }
            raster.rgba.withUnsafeMutableBytes { bytes in
                let guide = CIImage(bitmapData: Data(bytesNoCopy: bytes.baseAddress!, count: bytes.count, deallocator: .none), bytesPerRow: width * 16,
                                    size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
                var small = [Float](repeating: 1, count: plane.count * 4)
                for i in plane.indices { small[i * 4] = plane[i]; small[i * 4 + 1] = plane[i]; small[i * 4 + 2] = plane[i] }
                let weights = CIImage(bitmapData: small.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: analysisWidth * 16,
                                      size: CGSize(width: analysisWidth, height: analysisHeight), format: .RGBAf, colorSpace: nil)
                let image = MaskRefinement.edgeAware.apply(weights, guide: guide)
                // In bands of rows, top down, so the four-channel render stays small; Core Image counts rows from the bottom.
                let rows = max(1, min(height, (64 << 20) / (width * 16)))
                var band = [Float](repeating: 0, count: rows * width * 4)
                let context = context
                for top in stride(from: 0, to: height, by: rows) {
                    let count = min(rows, height - top)
                    band.withUnsafeMutableBytes {
                        context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: height - top - count, width: width, height: count), format: .RGBAf, colorSpace: nil)
                    }
                    for i in 0..<(count * width) { refined[top * width + i] = band[i * 4] }
                }
            }
            let frame = k.map { UnsafePointer(store.pointer($0).assumingMemoryBound(to: Float16.self)) }
            total.withUnsafeMutableBufferPointer { total in sum.withUnsafeMutableBufferPointer { sum in refined.withUnsafeBufferPointer { refined in
                let total = total, sum = sum
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        let w = refined[i]
                        guard w > 0.001, w.isFinite else { continue }
                        if let frame {
                            guard frame[i * 4 + 3] > 0.5 else { continue }
                            for c in 0..<3 { sum[i * 3 + c] += Float(frame[i * 4 + c]) * w }
                        } else { for c in 0..<3 { sum[i * 3 + c] += median!.rgba[i * 4 + c] * w } }
                        total[i] += w
                    }
                }
            } } }
        }
        raster.rgba.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for i in (y * width)..<((y + 1) * width) {
                    let t = total[i]
                    guard t > 0 else { continue }
                    // Scaling up can push the weights a little past 1.
                    let share = min(1, t), scale = share / t
                    for c in 0..<3 { out[i * 4 + c] = out[i * 4 + c] * (1 - share) + sum[i * 3 + c] * scale }
                }
            }
        }
    }

    // MARK: Stack

    public func stack(_ settings: PhotoStackSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        let raster = try stackedRaster(settings, progress: progress)
        if Task.isCancelled { throw CancellationError() }
        let included = try members(settings)
        var anchor = metadata[reference].panorama
        anchor.captureTime = PanoramaFrameMetadata.captureTime(after: included.map { metadata[$0].captureTime }) ?? anchor.captureTime
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: anchor, kind: .stack, preview: HDRMergeFinishing.picture(raster, maxDimension: 1024),
                                                             source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.stack.rawValue)), source: urls[reference])
        let size = "\(raster.width.formatted()) × \(raster.height.formatted())", format = url.pathExtension.uppercased()
        try writer.write(raster, to: url, progress: { progress(0.85 + 0.15 * $0, L10n.tr("Writing \(size) \(format)")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }

    /// The full-size stack before it is written; `engine` nil picks the GPU when there is one.
    func stackedRaster(_ settings: PhotoStackSettings, engine: HDRMerger.Engine? = nil,
                       progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> PanoramaRaster {
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let included = try members(settings)
        let width = analysis.width, height = analysis.height, pixels = width * height
        let gpu = engine == .cpu ? nil : self.gpu
        // Half-float RGBA per photo, plus the float result and one developed photo.
        let needed = Double(pixels) * (8 * Double(included.count) + 16 + 32)
        let store = try PhotoStackStore(device: gpu?.device, count: included.count, bytesPerFrame: pixels * 8, fileBacked: MappedBuffer.enabled || needed > 0.6 * MemoryBudget.bytes)
        let scale = Double(width) / Double(analysisWidth)
        // Lighten and Darken keep each photo as exposed.
        let gains = settings.mode.blendsOverBase ? [Float](repeating: 1, count: self.gains.count) : self.gains
        for (k, i) in included.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            progress(0.75 * Double(k) / Double(included.count), L10n.tr("Developing \(metadata[i].filename) (\(k + 1) of \(included.count))"))
            let inverse = transforms[i].scaled(by: scale).inverse
            try autoreleasepool {
                if let gpu {
                    let image = try HDRMergeDecoder.developedImage(urls[i], metadata: metadata[i], longEdge: nil, whiteBalance: whiteBalance, retouch: retouch[urls[i]] ?? [])
                    try gpu.store(image, into: store.buffer(k)!, offset: store.offset(k), width: width, height: height, context: context, inverse: inverse, gain: gains[i])
                } else {
                    let frame = try HDRMergeDecoder.decode(urls[i], metadata: metadata[i], longEdge: nil, whiteBalance: whiteBalance, context: context, retouch: retouch[urls[i]] ?? [])
                    let warped = HDRMerger.warp(frame, inverse, width: width, height: height)
                    let target = store.pointer(k).assumingMemoryBound(to: Float16.self)
                    let gain = gains[i]
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        for x in y * width..<(y + 1) * width {
                            for c in 0..<3 { target[x * 4 + c] = Float16(warped[x * 4 + c] * gain) }
                            target[x * 4 + 3] = Float16(warped[x * 4 + 3])
                        }
                    }
                }
            }
        }
        progress(0.75, L10n.tr("Stacking \(included.count) photos"))
        if Task.isCancelled { throw CancellationError() }
        if settings.mode.blendsOverBase {
            var out = [Float](repeating: 0, count: pixels * 4)
            let order = blendOrder(included)
            let frames = order.map { UnsafePointer(store.pointer(included.firstIndex(of: $0)!).assumingMemoryBound(to: Float16.self)) }
            out.withUnsafeMutableBufferPointer { out in
                blend(settings, order: order, rows: { k, y, row in
                    let source = frames[k] + y * width * 4
                    for i in 0..<(width * 4) { row[i] = Float(source[i]) }
                }, width: width, height: height, full: true, into: out.baseAddress!)
            }
            if Task.isCancelled { throw CancellationError() }
            return PanoramaRaster(width: width, height: height, rgba: out)
        }
        let planes = try weights(settings, included: included).planes
        func reduce(_ mode: PhotoStackMode) throws -> PanoramaRaster {
            if let gpu, included.count <= Self.gpuFrameLimit {
                return try gpu.reduce(store, width: width, height: height, mode: mode,
                                      progress: { progress(0.75 + 0.1 * $0, L10n.tr("Stacking \(included.count) photos")) }, cancelled: { Task.isCancelled })
            }
            var out = [Float](repeating: 0, count: pixels * 4)
            let frames = (0..<included.count).map { UnsafePointer(store.pointer($0).assumingMemoryBound(to: Float16.self)) }
            out.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    var scratch = PhotoStackReduce.Scratch(count: frames.count)
                    for x in 0..<width {
                        let p = (y * width + x) * 4
                        let value = PhotoStackReduce.pixel(mode, count: frames.count, scratch: &scratch) { k in
                            frames[k][p + 3] > 0.5 ? SIMD3(Float(frames[k][p]), Float(frames[k][p + 1]), Float(frames[k][p + 2])) : nil
                        }
                        out[p] = value.x; out[p + 1] = value.y; out[p + 2] = value.z; out[p + 3] = 1
                    }
                }
            }
            return PanoramaRaster(width: width, height: height, rgba: out)
        }
        var raster = try reduce(settings.mode)
        // The ground from the median needs the median at full size too.
        let median = planes[PhotoStackRegions.median] != nil ? try reduce(.median) : nil
        try composite(planes, over: &raster, included: included, store: store, median: median)
        return raster
    }
}

/// One pixel's reduction on the CPU, the same arithmetic as the GPU kernel.
enum PhotoStackReduce {
    struct Scratch {
        var r: [Float], g: [Float], b: [Float], work: [Float]
        init(count: Int) { r = .init(repeating: 0, count: count); g = r; b = r; work = r }
    }

    /// Sigma clipping keeps the samples within this many robust standard deviations of the median.
    static let clip: Float = 2.5
    /// The noise floor sigma clipping assumes, relative to the median's luminance plus a small absolute floor, so a
    /// perfectly still pixel (identical samples) still averages instead of rejecting the slightest noise.
    static let clipFloor: Float = 0.02, clipAbsolute: Float = 0.002

    @inline(__always) static func luminance(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }

    /// Reduces the samples `sample(k)` returns for k in 0..<count; nil samples (outside a photo) are skipped. Black where
    /// no photo covers the pixel.
    @inline(__always) static func pixel(_ mode: PhotoStackMode, count: Int, scratch: inout Scratch, sample: (Int) -> SIMD3<Float>?) -> SIMD3<Float> {
        var n = 0
        var sum = SIMD3<Float>.zero, high = SIMD3<Float>(repeating: -.infinity), low = SIMD3<Float>(repeating: .infinity)
        for k in 0..<count {
            guard let v = sample(k) else { continue }
            switch mode {
            case .mean: sum += v
            case .maximum: high = simd_max(high, v)
            case .minimum: low = simd_min(low, v)
            case .median, .clippedMean, .sequence, .lighten, .darken: scratch.r[n] = v.x; scratch.g[n] = v.y; scratch.b[n] = v.z
            }
            n += 1
        }
        guard n > 0 else { return .zero }
        switch mode {
        case .mean: return sum / Float(n)
        case .maximum: return high
        case .minimum: return low
        // Sequence's background is the median; its photos are laid over it by region (`PhotoStackRegions`).
        case .median, .sequence, .lighten, .darken: return SIMD3(median(&scratch.r, n), median(&scratch.g, n), median(&scratch.b, n))
        case .clippedMean:
            // The samples stay in order in r, g and b; each channel's median is selected on a copy.
            var middle = SIMD3<Float>.zero
            for c in 0..<3 {
                for k in 0..<n { scratch.work[k] = c == 0 ? scratch.r[k] : c == 1 ? scratch.g[k] : scratch.b[k] }
                middle[c] = median(&scratch.work, n)
            }
            let base = luminance(middle)
            // Robust spread: 1.4826 × the median absolute luminance deviation, no less than the noise floor.
            for k in 0..<n { scratch.work[k] = abs(luminance(SIMD3(scratch.r[k], scratch.g[k], scratch.b[k])) - base) }
            let spread = max(1.4826 * median(&scratch.work, n), clipFloor * base + clipAbsolute)
            var kept = SIMD3<Float>.zero, count: Float = 0
            for k in 0..<n {
                let v = SIMD3(scratch.r[k], scratch.g[k], scratch.b[k])
                if abs(luminance(v) - base) <= clip * spread { kept += v; count += 1 }
            }
            return count > 0 ? kept / count : middle
        }
    }

    /// The median of values[0..<n], reordering them: the middle one, or the mean of the middle two.
    static func median(_ values: inout [Float], _ n: Int) -> Float {
        let k = n / 2
        select(&values, n, k)
        let upper = values[k]
        guard n % 2 == 0 else { return upper }
        var lower = -Float.infinity
        for i in 0..<k { lower = max(lower, values[i]) }
        return (lower + upper) / 2
    }

    /// Hoare's selection: afterwards values[k] is the k-th smallest of values[0..<n], smaller ones before it.
    static func select(_ values: inout [Float], _ n: Int, _ k: Int) {
        var left = 0, right = n - 1
        while left < right {
            let pivot = values[(left + right) / 2]
            var i = left, j = right
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j { values.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { right = j } else if k >= i { left = i } else { return }
        }
    }
}

/// The aligned photos at full size, half-float RGBA each: in memory, or in temporary files mapped into memory when the
/// stack is larger than the Mac's memory comfortably holds. GPU buffers wrap the same pages either way.
final class PhotoStackStore {
    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let stride: Int
    private let file: (descriptor: Int32, url: URL)?
    private var buffers: [MTLBuffer] = []
    /// Photos per GPU buffer: Metal limits one buffer's length.
    private var perBuffer = 1
    let count: Int, bytesPerFrame: Int

    init(device: MTLDevice?, count: Int, bytesPerFrame: Int, fileBacked: Bool) throws {
        let page = Int(getpagesize())
        stride = (bytesPerFrame + page - 1) / page * page
        length = stride * count
        self.count = count; self.bytesPerFrame = bytesPerFrame
        if fileBacked {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Stack \(UUID().uuidString)")
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            // Nameless from the start: the space comes back when the descriptor closes, even if the app is stopped.
            unlink(url.path)
            guard descriptor >= 0, ftruncate(descriptor, off_t(length)) == 0,
                  let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), mapped != MAP_FAILED else {
                if descriptor >= 0 { close(descriptor) }
                throw PanoramaError.message(L10n.tr("There isn’t enough disk space to stack these photos."))
            }
            base = mapped; file = (descriptor, url)
        } else {
            guard let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), mapped != MAP_FAILED else {
                throw PanoramaError.message(L10n.tr("Not enough memory to stack these photos."))
            }
            base = mapped; file = nil
        }
        if let device {
            perBuffer = max(1, min(count, device.maxBufferLength / stride))
            var start = 0
            while start < count {
                let frames = min(perBuffer, count - start)
                guard let buffer = device.makeBuffer(bytesNoCopy: base + start * stride, length: frames * stride, options: .storageModeShared, deallocator: nil) else {
                    throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
                }
                buffers.append(buffer)
                start += frames
            }
        }
    }

    deinit {
        buffers = []
        munmap(base, length)
        if let file { close(file.descriptor) }
    }

    func pointer(_ k: Int) -> UnsafeMutableRawPointer { base + k * stride }
    func buffer(_ k: Int) -> MTLBuffer? { buffers.isEmpty ? nil : buffers[k / perBuffer] }
    func offset(_ k: Int) -> Int { (k % perBuffer) * stride }
}
