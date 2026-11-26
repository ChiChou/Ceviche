import Foundation
import CoreImage
import Metal
import simd

/// Merges a focus bracket into one linear DNG that is sharp from near to far. Analyze once (develop reduced copies,
/// correct focus breathing, measure where each photo is sharp), preview each choice of options from that, then merge at
/// full size one photo at a time. Use from one task at a time; long steps check `Task.isCancelled`.
///
/// Alignment comes first and is frozen: every photo gets one similarity transform onto the reference (see
/// `FocusStackAlignment`), and every later stage samples the original linear pixels through it once. Sharpness is
/// measured per photo after alignment, against that photo's own noise (`FocusStackFocus`). The edge-aware blend picks a
/// source photo per region from confident measurements, spreads those choices into low-texture areas with a guided
/// filter whose edges follow the picture, and keeps transitions narrow, so blur isn't averaged back into detail; the
/// multiscale blend is the classical baseline for comparison. The result keeps the reference's framing and exposure,
/// cropped to what every photo covers.
public final class FocusStacker: @unchecked Sendable {
    public let urls: [URL]
    /// Each photo's own retouching, AI fills included, burnt into it when the result is rendered at full size. The
    /// photos are aligned and analysed without it, so a fill or patch never moves what alignment matches.
    public var retouch: [URL: [RetouchStroke]] = [:]
    public private(set) var analysis: FocusStackAnalysis?
    /// Whether the edge-aware blend may ask the depth model, where it's installed, which photo suits low-texture areas.
    public var usesDepth = true

    /// A fresh context each time it's asked for: Core Image keeps every surface a context used until the context goes,
    /// so a full-size photo developed through one shared context stays in memory to the end. Half floats, as the merge
    /// textures are.
    var context: CIContext {
        CIContext(mtlDevice: device, options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    }
    let device: MTLDevice
    /// The full-size merge's GPU engine.
    lazy var gpu = FocusStackGPU(device: device)
    /// Analysis's GPU engine.
    lazy var analysisGPU = FocusStackAnalysisGPU(device: device)
    lazy var inspectionGPU = try? FocusStackInspectionRenderer(device: device)
    struct InspectionKey: Equatable {
        var reference: Int, breathing: Bool, included: [Int], width: Int, height: Int, offset: SIMD2<Double>
    }
    var inspectionCache: (key: InspectionKey, value: FocusStackInspection)?
    /// Where analysis's dense stages run: the GPU, or the CPU reference tests compare it with.
    var analysisEngine = Engine.gpu
    var metadata: [HDRMergeFrameMetadata] = []
    var whiteBalance = (temperature: 5000.0, tint: 0.0)
    /// The photo the alignment was solved against: the middle one.
    var anchor = 0
    /// Reduced developed photos, as shot.
    var sources: [PanoramaFrame] = []
    var clips: [Float] = []
    /// Each photo onto the anchor at analysis size; identity where alignment failed.
    var transforms: [HDRSimilarity] = []
    private var measured: [Bool] = []
    /// White-noise variance of each photo's sharpness proxy at full size, before exposure matching.
    private var fullNoise: [Float] = []
    var analysisWidth = 0, analysisHeight = 0
    var prepared: [String: Prepared] = [:]
    var weightCache: [String: Weights] = [:]
    /// The last weights the layer brush changed, for the strokes and weights they were painted from.
    var paintCache: (key: String, strokes: [FocusStackStroke], weights: Weights, painted: [Float])?

    var repairGPU: FocusStackRepairGPU?
    var repairBaseCache: (settings: FocusStackSettings, depth: Bool, raster: PanoramaRaster)?
    var repairAlignedCache: (settings: FocusStackSettings, photo: Int, buffer: MTLBuffer)?
    var repairSelections: [(settings: FocusStackSettings, depth: Bool, strokes: [FocusStackStroke], photo: Int, hints: [SIMD4<Float>])] = []

    static let analysisLongEdge = 1600

    public init(urls: [URL]) throws {
        guard urls.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose at least two photos to focus stack.")) }
        self.urls = urls
        guard let device = MTLCreateSystemDefaultDevice() else { throw EditorError.noGPU }
        self.device = device
    }

    // MARK: Analysis

    public func analyze(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> FocusStackAnalysis {
        let count = urls.count
        let frames = try urls.map { try HDRMergeDecoder.metadata($0) }
        if Set(frames.map(\.isRAW)).count > 1 {
            throw PanoramaError.message(L10n.tr("Stack RAW photos or processed photos, not both. A focus bracket needs to be one kind of file."))
        }
        if frames[0].isRAW, Set(frames.map { "\($0.make) \($0.model)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos come from different cameras. A focus bracket needs photos from one camera."))
        }
        if Set(frames.map { "\($0.width)×\($0.height)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos have different sizes. A focus bracket needs photos of the same size and orientation."))
        }
        let anchor = count / 2
        let whiteBalance = (temperature: frames[anchor].temperature, tint: frames[anchor].tint)
        var decoded = [PanoramaFrame?](repeating: nil, count: count)
        var noise = [Float](repeating: 0, count: count)
        var failures = [String?](repeating: nil, count: count)
        let lock = NSLock()
        var done = 0
        let urls = self.urls, context = self.context
        // Developing a full-size crop costs as much as the reduced copy, so where the photos were taken alike (a bracket
        // normally is) the noise is measured on the first, middle and last only and their median serves every photo.
        let stops = frames.compactMap(\.recordedStops)
        let alike = stops.count == count && (stops.max()! - stops.min()!) < 0.1
        let measuredNoise = alike ? Set([0, anchor, count - 1]) : Set(0..<count)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            guard !Task.isCancelled else { return }
            do {
                let frame = try HDRMergeDecoder.decode(urls[i], metadata: frames[i], longEdge: Self.analysisLongEdge, whiteBalance: whiteBalance, context: context)
                let level = measuredNoise.contains(i) ? try Self.fullSizeNoise(urls[i], metadata: frames[i], whiteBalance: whiteBalance, context: context) : -1
                let finished = lock.withLock { decoded[i] = frame; noise[i] = level; done += 1; return done }
                progress(0.5 * Double(finished) / Double(count), L10n.tr("Reading \(frames[i].filename)"))
            } catch { lock.withLock { failures[i] = error.localizedDescription } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure = failures.compactMap({ $0 }).first { throw PanoramaError.message(failure) }
        if measuredNoise.count < count {
            let shared = measuredNoise.map { noise[$0] }.sorted()[measuredNoise.count / 2]
            for i in 0..<count where !measuredNoise.contains(i) { noise[i] = shared }
        }
        let sources = decoded.map { $0! }
        // Aligned on the photos as shot; shown and stacked with their retouching.
        let shown = sources.indices.map { PanoramaDecoder.retouched(sources[$0], retouch[urls[$0]] ?? []) }
        let width = sources.map(\.width).min()!, height = sources.map(\.height).min()!
        let clips = sources.enumerated().map { HDRMerger.clipLevel($0.element, metadata: frames[$0.offset]) }

        progress(0.55, L10n.tr("Correcting focus breathing"))
        var pyramids = [[LuminancePlane]](repeating: [], count: count)
        pyramids.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in out[i] = FocusStackAlignment.pyramid(sources[i]) }
        }
        if Task.isCancelled { throw CancellationError() }
        // Each photo against its neighbour in capture order, where focus differs least, and directly against the anchor.
        var pairs = (0..<(count - 1)).map { ($0, $0 + 1) }
        for i in 0..<count where i != anchor && abs(i - anchor) > 1 { pairs.append((i, anchor)) }
        var links = [FocusStackAlignment.Link?](repeating: nil, count: pairs.count)
        let factor = Double(width) / Double(pyramids[anchor][0].width)
        links.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: pairs.count) { k in
                guard !Task.isCancelled else { return }
                let (from, to) = pairs[k]
                if let (model, confidence) = FocusStackAlignment.register(pyramids[from], onto: pyramids[to]), confidence > 0.3 {
                    out[k] = FocusStackAlignment.Link(from: from, to: to, transform: model.scaled(by: factor), confidence: confidence)
                }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        let solved = FocusStackAlignment.solve(links: links.compactMap { $0 }, count: count, anchor: anchor, order: Array(0..<count),
                                               width: width, height: height)
        let measured = solved.map { $0 != nil }
        let transforms = solved.map { $0 ?? .identity }
        var confidence = [Double](repeating: 0, count: count)
        for link in links.compactMap({ $0 }) {
            confidence[link.from] = max(confidence[link.from], link.confidence); confidence[link.to] = max(confidence[link.to], link.confidence)
        }
        confidence[anchor] = 1

        let scale = Double(frames[0].width) / Double(width), centre = SIMD2(Double(width), Double(height)) / 2
        let infos = (0..<count).map { i in
            FocusStackFrameInfo(index: i, filename: frames[i].filename,
                                scale: measured[i] ? transforms[i].scale : nil,
                                shift: measured[i] ? (transforms[i].apply(centre) - centre) * scale : nil,
                                rotationDegrees: measured[i] ? transforms[i].rotationDegrees : nil,
                                confidence: confidence[i],
                                thumbnail: PanoramaFinishing.picture(PanoramaRaster(width: sources[i].width, height: sources[i].height, rgba: shown[i].pixels), maxDimension: 240))
        }
        let analysis = FocusStackAnalysis(frames: infos, suggestedReference: anchor, width: frames[0].width, height: frames[0].height)
        self.metadata = frames; self.whiteBalance = whiteBalance; self.anchor = anchor; self.sources = shown; self.clips = clips
        self.transforms = transforms; self.measured = measured; self.fullNoise = noise
        self.analysisWidth = width; self.analysisHeight = height
        self.prepared = [:]; self.weightCache = [:]; self.inspectionCache = nil; self.analysis = analysis
        repairBaseCache = nil; repairAlignedCache = nil; repairSelections = []
        progress(0.7, L10n.tr("Measuring sharpness"))
        _ = try prepare(reference: anchor, breathing: true)
        progress(1, "")
        return analysis
    }

    /// The noise of a photo at full size, from a crop of its centre: developing only the crop keeps this cheap.
    private static func fullSizeNoise(_ url: URL, metadata: HDRMergeFrameMetadata, whiteBalance: (temperature: Double, tint: Double),
                                      context: CIContext) throws -> Float {
        try autoreleasepool {
            let image = try HDRMergeDecoder.developedImage(url, metadata: metadata, longEdge: nil, whiteBalance: whiteBalance)
            let side = min(768, Int(image.extent.width), Int(image.extent.height))
            guard side >= 32 else { return 0 }
            let bounds = CGRect(x: (Int(image.extent.width) - side) / 2, y: (Int(image.extent.height) - side) / 2, width: side, height: side)
            var pixels = [Float](repeating: 0, count: side * side * 4)
            pixels.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: bounds, format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            for i in pixels.indices where !pixels[i].isFinite { pixels[i] = 0 }
            return FocusStackFocus.noise(FocusStackFocus.proxy(pixels), width: side, height: side)
        }
    }

    // MARK: Members and crop

    func members(_ settings: FocusStackSettings) throws -> (reference: Int, included: [Int]) {
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let included = analysis.frames.map(\.index).filter { !settings.excluded.contains($0) }
        guard included.count >= 2 else { throw PanoramaError.message(L10n.tr("Include at least two photos.")) }
        var reference = settings.reference ?? anchor
        if !included.contains(reference) { reference = included[(included.count - 1) / 2] }
        return (reference, included)
    }

    /// The largest upright rectangle (in the reference's full-size pixels) that every included photo covers, or the
    /// whole frame without the crop.
    func crop(_ settings: FocusStackSettings, transforms: [HDRSimilarity], included: [Int]) -> CGRect {
        guard let analysis else { return .zero }
        let width = Double(analysis.width), height = Double(analysis.height)
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        guard settings.cropToCoverage else { return frame }
        let factor = width / Double(analysisWidth)
        let corners = [SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height)]
        let quads = included.map { i in corners.map { transforms[i].scaled(by: factor).apply($0) } } + [corners]
        func inside(_ p: SIMD2<Double>) -> Bool {
            quads.allSatisfy { quad in
                (0..<4).allSatisfy { k in
                    let a = quad[k], b = quad[(k + 1) % 4], e = b - a, d = p - a
                    // Clockwise in a y-down image, so inside is to the right of each edge.
                    return e.x * d.y - e.y * d.x >= -1e-6
                }
            }
        }
        func fits(_ r: (x0: Double, y0: Double, x1: Double, y1: Double)) -> Bool {
            inside(SIMD2(r.x0, r.y0)) && inside(SIMD2(r.x1, r.y0)) && inside(SIMD2(r.x0, r.y1)) && inside(SIMD2(r.x1, r.y1))
        }
        // The largest rectangle of the photo's shape about the covered area's centre, then each side pushed outward.
        let centre = quads.flatMap { $0 }.reduce(SIMD2<Double>.zero, +) / Double(quads.count * 4)
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let s = (low + high) / 2
            if fits((centre.x - s * width / 2, centre.y - s * height / 2, centre.x + s * width / 2, centre.y + s * height / 2)) { low = s } else { high = s }
        }
        var r = (x0: centre.x - low * width / 2, y0: centre.y - low * height / 2, x1: centre.x + low * width / 2, y1: centre.y + low * height / 2)
        for side in 0..<4 {
            var a = 0.0, b = max(width, height)
            for _ in 0..<40 {
                let m = (a + b) / 2
                var t = r
                switch side { case 0: t.x0 -= m; case 1: t.y0 -= m; case 2: t.x1 += m; default: t.y1 += m }
                if fits(t) { a = m } else { b = m }
            }
            switch side { case 0: r.x0 -= a; case 1: r.y0 -= a; case 2: r.x1 += a; default: r.y1 += a }
        }
        let x0 = max(0, ceil(r.x0 - 1e-6)), y0 = max(0, ceil(r.y0 - 1e-6))
        let x1 = min(width, floor(r.x1 + 1e-6)), y1 = min(height, floor(r.y1 + 1e-6))
        guard x1 - x0 >= 16, y1 - y0 >= 16 else { return frame }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The merge's layout and per-photo steps, at analysis size for the preview or at full size for the merge.
    func plan(_ settings: FocusStackSettings, fullSize: Bool) throws
        -> (layout: FocusStackLayout, steps: [FocusStackFrameStep], reference: Int, crop: CGRect, weights: Weights) {
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let (reference, included) = try members(settings)
        let prepared = try prepare(reference: reference, breathing: settings.correctBreathing)
        let key = "\(reference)-\(settings.correctBreathing)-\(usesDepth)-\(settings.blending.rawValue)-\(included.map(String.init).joined(separator: ","))"
        var weights = try weights(prepared, reference: reference, included: included, blending: settings.blending, key: key)
        var painted: [Float]?
        if settings.strokes.contains(where: { $0.repair != true && included.contains($0.photo) }) {
            let result = self.painted(weights, strokes: settings.strokes, prepared: prepared, reference: reference, included: included,
                                      breathing: settings.correctBreathing, key: key)
            weights = result.0; painted = result.1
        }
        let crop = crop(settings, transforms: prepared.transforms, included: included)
        let resolution = fullSize ? Double(analysis.width) / Double(analysisWidth) : 1
        let toResolution = fullSize ? 1 : Double(analysisWidth) / Double(analysis.width)
        let offset = SIMD2(Double(crop.minX), Double(crop.minY)) * toResolution
        let width = max(1, Int((Double(crop.width) * toResolution).rounded(.down)))
        let height = max(1, Int((Double(crop.height) * toResolution).rounded(.down)))
        let shift = HDRSimilarity(linear: matrix_identity_double2x2, translation: offset)
        let steps = included.map { i in
            let noise = fullSize ? fullNoise[i] * prepared.gains[i] : prepared.noise[i]
            return FocusStackFrameStep(index: i, inverse: prepared.transforms[i].scaled(by: resolution).inverse.after(shift),
                                       gain: prepared.gains[i], clip: clips[i], noise: noise, prior: weights.weights[i]!)
        }
        let typical = steps.map(\.noise).sorted()[steps.count / 2]
        let layout = FocusStackLayout(width: width, height: height, blending: settings.blending, noise: typical,
                                      priorWidth: analysisWidth, priorHeight: analysisHeight, priorOffset: offset,
                                      priorScale: 1 / resolution, painted: painted)
        return (layout, steps, reference, crop, weights)
    }
}
