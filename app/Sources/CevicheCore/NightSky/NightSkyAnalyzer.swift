import Foundation
import CoreGraphics
import ImageIO
import CoreImage
import Metal
import simd

/// The analysis the night-sky tools share, run once per sequence. Each photo is developed once at about 3200 pixels
/// (Core Image on the GPU), where stars are found and, for tools that align the sky, the photo's sky is registered on the
/// anchor (the middle photo) by its star pattern, tracking outward from the anchor with each prediction extrapolated in
/// capture time. Lines (meteors, aircraft, satellites) are found against the median of the two photos on either side, so
/// stars cancel and an event never hides in its own background. Small copies of every photo, as shot and, when aligned,
/// on the anchor's sky, go to a temporary file the previews are drawn from.
///
/// The camera is assumed to stand still: the ground, and the sky mask found on the anchor, keep their place in every
/// photo. Use from one task at a time; long steps check `Task.isCancelled`.
final class NightSkyAnalyzer: @unchecked Sendable {
    enum Space { case camera, sky }

    private(set) var urls: [URL]
    let space: Space
    private(set) var metadata: [NightSkyFrameMetadata] = []
    private(set) var width = 0, height = 0
    private(set) var analysisWidth = 0, analysisHeight = 0
    private(set) var previewWidth = 0, previewHeight = 0
    /// The photo every alignment maps onto.
    private(set) var anchor = 0
    private(set) var whiteBalance = (temperature: 5000.0, tint: 0.0)
    /// Multiplies a photo's pixels to the anchor's ISO and exposure.
    private(set) var gains: [Float] = []
    /// Proportional to the light each photo gathered (shutter time over f-number squared).
    private(set) var weights: [Float] = []
    /// The anchor's sky probability at analysis size, refined against the photo; the camera's sky in every photo.
    var skyProbability: [Float] = []
    /// Eroded probability: a sample counts as sky only where this is above 0.8, so the ground never warps into the sky.
    var skyValid: [Float] = []
    var previewProbability: [Float] = []
    /// The sky as analysis found it; the maps above are it shaped by `skyShape`.
    var foundSkyProbability: [Float] = []
    /// The maps the aligned preview copies were last warped with: where the shaped sky reaches past them, they are
    /// warped again.
    var warpedPreviewProbability: [Float] = [], warpedValid: [Float] = []
    /// Full-size pixels the sky's boundary is moved by: out into the ground when positive, in toward the sky when negative.
    var skyShape = SkyShape()
    /// Corrections to the sky analysis finds, used for finding and aligning stars and searching for lines; set before
    /// `analyze`. Its edge is left to `setSky`.
    var skyCorrection = SkyShape()
    /// The sky finder's own result, kept so analyzing again with another correction doesn't look for the sky again.
    private var finderSky: [Float]?
    private(set) var alignments: [NightSkyAlignment?] = []
    private(set) var failures: [String?] = []
    private(set) var starCounts: [Int] = []
    /// Median radius of each photo's stars, in analysis pixels: larger when the camera moved or focus drifted.
    private(set) var starRadii: [Double] = []
    /// Median sky luminance at the anchor's exposure.
    private(set) var backgrounds: [Float] = []
    /// Every line found, with what it probably is.
    private(set) var lines: [NightSkyLine] = []
    private(set) var thumbnails: [CGImage?] = []
    /// Full-size pixel indices of hot pixels: single-pixel spikes at the same place in photos far apart in time.
    private(set) var hotPixels: [Int] = []
    private var hotPixelsFound = false
    /// Brightening for pictures of this sequence.
    private(set) var displayExposure: Float = 1
    /// False when the sky model isn't installed: everything counts as sky.
    var skyModelInstalled = true
    private(set) var cache: NightSkyCache?

    /// A Core Image context for one render or decode. Core Image keeps every surface a context has used, the RAW
    /// decoder's working surfaces among them, until the context goes: one kept for the whole analysis grew by every
    /// photo decoded (4 GB after the first few at 22 MP). A fresh one each time lets them go with it.
    var context: CIContext {
        CIContext(mtlDevice: device, options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }
    /// The same for a merge's full-size decodes, in half floats unless `mergesInFloat`: the sums stay 32-bit, and a photo's
    /// development needs nothing finer than 1/2000 before averaging, while its working surfaces take half the memory.
    var mergeContext: CIContext {
        CIContext(mtlDevice: device, options: [.workingColorSpace: PanoramaDecoder.space,
                                               .workingFormat: Self.mergesInFloat ? CIFormat.RGBAf : CIFormat.RGBAh, .cacheIntermediates: false])
    }
    /// Tests compare a merge decoded in half floats with one in full floats.
    nonisolated(unsafe) static var mergesInFloat = false
    let device: MTLDevice
    /// Warps and the hot-pixel search; nil only when a test runs the CPU reference (`analyzesOnGPU`).
    let gpu: NightSkyAnalysisGPU?

    static let analysisLongEdge = 3200
    /// Tests turn the sky network off so synthetic scenes depend on the star evidence alone.
    nonisolated(unsafe) static var usesSkyModel = true
    /// Tests give the known sky of a synthetic scene: probability per analysis pixel for a width and height.
    nonisolated(unsafe) static var skyOverride: ((Int, Int) -> [Float])?
    /// Tests turn the analysis kernels off to compare them with the CPU reference.
    nonisolated(unsafe) static var analyzesOnGPU = true

    init(urls: [URL], space: Space) throws {
        guard urls.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose at least two photos of the night sky.")) }
        self.urls = urls
        self.space = space
        guard let device = MTLCreateSystemDefaultDevice() else { throw EditorError.noGPU }
        self.device = device
        gpu = Self.analyzesOnGPU ? NightSkyAnalysisGPU(device: device) : nil
    }

    var count: Int { urls.count }
    var scale: Double { Double(width) / Double(analysisWidth) }
    var previewScale: Double { Double(analysisWidth) / Double(previewWidth) }

    // MARK: Analysis

    func analyze(progress: @escaping @Sendable (Double, String) -> Void) throws {
        // The sequence first, in a function of its own, so its decodes, planes and GPU maps are let go before the
        // hot-pixel search decodes three photos at full size.
        try analyzeSequence(progress: progress)
        // Hot pixels don't depend on the sky: analyzing again with another correction keeps them.
        if !hotPixelsFound {
            progress(0.94, L10n.tr("Finding hot pixels…"))
            hotPixels = try autoreleasepool { try findHotPixels { progress(0.94 + 0.02 * Double($0), L10n.tr("Finding hot pixels…")) } }
            hotPixelsFound = true
        }
        progress(1, "")
    }

    private func analyzeSequence(progress: @escaping @Sendable (Double, String) -> Void) throws {
        progress(0, L10n.tr("Reading photos…"))
        var read = [NightSkyFrameMetadata?](repeating: nil, count: urls.count)
        var failure: Error?
        let lock = NSLock(), urls = self.urls
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            do { let m = try NightSkyFrameMetadata.read(urls[i]); lock.withLock { read[i] = m } } catch { lock.withLock { failure = error } }
        }
        if let failure { throw failure }
        // Capture order, with fractional seconds; file names wrap on many cameras, so they only break ties.
        let order = read.indices.sorted { (read[$0]!.time ?? .infinity, read[$0]!.filename) < (read[$1]!.time ?? .infinity, read[$1]!.filename) }
        let frames = order.map { read[$0]! }
        self.urls = order.map { urls[$0] }
        if Set(frames.map(\.base.isRAW)).count > 1 {
            throw PanoramaError.message(L10n.tr("Stack RAW photos or processed photos, not both. A night sequence needs photos of one kind."))
        }
        // Processed files often lose the camera on the way through an editor; only the ones that name it count.
        if Set(frames.map { "\($0.base.make) \($0.base.model)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos come from different cameras. A night sequence needs photos from one camera."))
        }
        if Set(frames.map { "\($0.base.width)×\($0.base.height)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos have different sizes. A night sequence needs photos of the same size and orientation."))
        }
        metadata = frames
        width = frames[0].base.width; height = frames[0].base.height
        let count = frames.count
        anchor = count / 2
        whiteBalance = (frames[anchor].base.temperature, frames[anchor].base.tint)
        // ISO is gain: photos at another ISO or shutter are brought to the anchor's brightness; the weight follows the
        // light actually gathered, so a change of ISO alone doesn't change how much a photo counts.
        let stops = frames.map { m -> Double? in
            guard let light = m.light else { return nil }
            return log2(light * (m.iso ?? 100))
        }
        gains = stops.allSatisfy({ $0 != nil }) ? stops.map { Float(exp2(stops[anchor]! - $0!)) } : Array(repeating: 1, count: count)
        let lights = frames.map(\.light)
        weights = lights.allSatisfy({ $0 != nil }) ? lights.map { Float($0! / lights[anchor]!) } : Array(repeating: 1, count: count)

        progress(0.01, L10n.tr("Finding the sky…"))
        let (anchorImage, anchorRGBA) = try developAnalysis(anchor)
        analysisWidth = Int(anchorImage.extent.width.rounded(.down)); analysisHeight = Int(anchorImage.extent.height.rounded(.down))
        let aw = analysisWidth, ah = analysisHeight
        let anchorLuminance = Self.luminance(anchorRGBA, gain: 1)
        progress(0.02, L10n.tr("Finding the sky…"))
        if finderSky?.count != aw * ah { finderSky = try findSky(anchorImage, luminance: anchorLuminance, frames: frames) }
        let finder = finderSky!
        progress(0.04, L10n.tr("Finding the sky…"))
        let correction = SkyShape(everything: skyCorrection.everything, strokes: skyCorrection.strokes)
        skyProbability = try shaped(finder, correction)
        skyValid = try minFilter(skyProbability, width: aw, height: ah, radius: max(3, aw / 400))
        // Lines are searched for well inside the sky: lights, glow and branches along the skyline make lines of their own.
        let skyBinary = skyProbability.map { Float($0 > 0.9 ? 1 : 0) }
        let interior = try boxBlur(skyBinary, width: aw, height: ah, radius: max(15, aw * 3 / 200)).map { Float($0 > 0.999 ? 1 : 0) }
        progress(0.06, L10n.tr("Finding the sky…"))

        // Preview copies stay under about 3 GB for long sequences.
        let slots = space == .sky ? 2 : 1, ratio = Double(min(aw, ah)) / Double(max(aw, ah))
        let edge = max(960, min(1600, Int((3e9 / (Double(count) * 6 * Double(slots)) / ratio).squareRoot())))
        let shrink = min(1, Double(edge) / Double(max(aw, ah)))
        previewWidth = max(1, Int((Double(aw) * shrink).rounded())); previewHeight = max(1, Int((Double(ah) * shrink).rounded()))
        foundSkyProbability = finder; skyShape = correction
        previewProbability = Self.downsample(skyProbability, channels: 1, width: aw, height: ah, to: previewWidth, previewHeight)
        let cache = try NightSkyCache(count: count, width: previewWidth, height: previewHeight, slots: slots)
        self.cache = cache
        warpedPreviewProbability = previewProbability; warpedValid = skyValid
        // The sky maps stay in GPU memory for every photo's warps.
        let warpers = try space == .sky ? gpu.map { gpu in
            (plane: try NightSkyAnalysisGPU.Warper(gpu, width: aw, height: ah, mask: skyProbability, threshold: 0.2, valid: skyValid, analysis: (aw, ah)),
             preview: try NightSkyAnalysisGPU.Warper(gpu, width: previewWidth, height: previewHeight, mask: previewProbability, threshold: 0.01,
                                                     valid: skyValid, analysis: (aw, ah)))
        } : nil

        alignments = Array(repeating: nil, count: count); failures = Array(repeating: nil, count: count)
        starCounts = Array(repeating: 0, count: count); backgrounds = Array(repeating: 0, count: count)
        starRadii = Array(repeating: 0, count: count)
        thumbnails = Array(repeating: nil, count: count)
        var found: [NightSkyLine] = []
        let anchorDeveloped = try develop(anchor, rgba: anchorRGBA, interior: interior)
        displayExposure = NightSkyFinishing.exposure(skyMedian: anchorDeveloped.background)

        // Outward from the anchor, so each photo's sky is predicted from aligned neighbors. Star trails align too: they
        // don't resample the sky, but drawing the stars' motion through a pause needs it.
        let processing = [anchor] + Array((anchor + 1)..<count) + Array((0..<anchor).reversed())
        var planes: [Int: [Float]] = [:], processed = Set<Int>(), searched = Set<Int>()
        let anchorStars = anchorDeveloped.stars
        // Each photo counts twice, once developed and once aligned, so the bar moves while a chunk develops; the label names
        // the photo developed last.
        var steps = 0, developedCount = 0, label = ""
        func advance(_ message: String? = nil) {
            let fraction = lock.withLock { () -> Double in
                steps += 1
                if let message { label = message }
                return 0.06 + 0.88 * Double(steps) / Double(2 * count)
            }
            progress(fraction, lock.withLock { label })
        }
        for chunk in stride(from: 0, to: processing.count, by: 6).map({ Array(processing[$0..<min(processing.count, $0 + 6)]) }) { try autoreleasepool {
            // Each chunk's Core Image and Metal objects go when it ends, not when the analysis does: otherwise the last
            // chunk's decodes were still held through the hot-pixel search (3.4 GB at 22 MP).
            if Task.isCancelled { throw CancellationError() }
            var developed = [Developed?](repeating: nil, count: chunk.count)
            var errors = [Error?](repeating: nil, count: chunk.count)
            // One context for the chunk: its photos decode side by side and share the decoder's surfaces, which go with it.
            let chunkContext = context
            DispatchQueue.concurrentPerform(iterations: chunk.count) { k in
                let i = chunk[k]
                if i == anchor {
                    let n = lock.withLock { developed[k] = anchorDeveloped; developedCount += 1; return developedCount }
                    advance(L10n.tr("Analyzing \(frames[i].filename) (\(n) of \(count))"))
                    return
                }
                do {
                    let (_, rgba) = try developAnalysis(i, context: chunkContext)
                    let result = try develop(i, rgba: rgba, interior: interior)
                    let n = lock.withLock { developed[k] = result; developedCount += 1; return developedCount }
                    advance(L10n.tr("Analyzing \(frames[i].filename) (\(n) of \(count))"))
                } catch { lock.withLock { errors[k] = error } }
            }
            if let error = errors.compactMap({ $0 }).first { throw error }
            for (k, i) in chunk.enumerated() {
                let frame = developed[k]!
                starCounts[i] = frame.stars.count; backgrounds[i] = frame.background
                starRadii[i] = NightSkyStars.median(frame.stars.prefix(300).map(\.radius))
                thumbnails[i] = NightSkyFinishing.picture(frame.preview, channels: 3, width: previewWidth, height: previewHeight,
                                                          exposure: displayExposure * gains[i], maxDimension: 220)
                try cache.write(frame.preview, frame: i, slot: 0)
                if i == anchor {
                    alignments[i] = .identity
                } else {
                    do { alignments[i] = try NightSkyRegistration.align(source: frame.stars, reference: anchorStars, width: aw, initial: prediction(for: i)) }
                    catch NightSkyRegistrationError.failed(let reason) { failures[i] = reason }
                }
                switch space {
                case .camera:
                    planes[i] = frame.luminance
                case .sky:
                    if let alignment = alignments[i] {
                        planes[i] = try warpers.map { try $0.plane.warp(frame.luminance, channels: 1, alignment: alignment) } ?? warpPlane(frame.luminance, alignment)
                        let preview = try warpers.map { try $0.preview.warp(frame.preview, channels: 3, alignment: alignment) }
                            ?? warpPreview(frame.preview, alignment, mask: previewProbability, valid: skyValid)
                        try cache.write(preview, frame: i, slot: 1)
                    } else {
                        try cache.write([Float](repeating: .nan, count: previewWidth * previewHeight * 3), frame: i, slot: 1)
                    }
                }
                processed.insert(i)
                advance()
            }
            // Search each photo whose window is all in; then let go of planes no window still needs.
            let ready = processed.subtracting(searched).filter { i in Self.window(i, count: count).allSatisfy(processed.contains) }.sorted()
            var results = [[NightSkyLine]](repeating: [], count: ready.count), lineErrors = [Error?](repeating: nil, count: ready.count)
            let planesNow = planes
            DispatchQueue.concurrentPerform(iterations: ready.count) { k in
                let i = ready[k]
                guard let plane = planesNow[i] else { return }
                let neighbors = Self.window(i, count: count).filter { $0 != i }.compactMap { planesNow[$0] }
                // On the anchor's sky the stars hold still, so their cores are kept out of the search. In the camera's frame
                // they move, leave only round residuals of their own size, and a photo's own detections would include
                // bumps along a bright line, so nothing is kept out.
                let cores = space == .sky ? anchorStars.map(\.point) : []
                do {
                    let lines = try NightSkyTransients.detect(frame: plane, neighbors: neighbors, interior: interior, stars: cores, width: aw, height: ah, index: i, gpu: gpu)
                    lock.withLock { results[k] = lines }
                } catch { lock.withLock { lineErrors[k] = error } }
            }
            if let error = lineErrors.compactMap({ $0 }).first { throw error }
            found += results.joined()
            searched.formUnion(ready)
            for j in planes.keys where (0..<count).filter({ Self.window($0, count: count).contains(j) }).allSatisfy(searched.contains) { planes[j] = nil }
        } }
        lines = NightSkyTransients.groupTracks(found, size: max(aw, ah)).sorted { ($0.frame, $0.start.x) < ($1.frame, $1.start.x) }
        try cache.finish()
    }
}

// Stored analysis holds what analysis found, a few MB: the sky finder's mask, alignments, lines and hot pixels. Every
// other mask derives from the found one, and the preview copies are decoded again at preview size, so reopening skips
// finding, aligning and searching but not decoding. Nothing stored depends on the photos' development in the catalog.
extension NightSkyAnalyzer {
    struct Results: Codable {
        var metadata: [NightSkyFrameMetadata]
        var width: Int, height: Int
        var analysisWidth: Int, analysisHeight: Int
        var previewWidth: Int, previewHeight: Int
        var anchor: Int
        var temperature: Double, tint: Double
        var gains: [Float], weights: [Float]
        /// The corrections the stars were found and aligned with; their edge is always 0.
        var skyCorrection: SkyShape
        /// The sky finder's probability at analysis size, Float32 compressed with LZFSE: mostly exact 0s and 1s.
        var foundSky: Data
        var skyModelInstalled: Bool
        var alignments: [NightSkyAlignment?]
        var failures: [String?]
        var starCounts: [Int]
        var starRadii: [Double]
        var backgrounds: [Float]
        var lines: [NightSkyLine]
        /// Full-size pixel indices as little-endian Int64.
        var hotPixels: Data
        var displayExposure: Float
    }

    func results() throws -> Results {
        try requireAnalysis()
        let found = foundSkyProbability.withUnsafeBytes { Data($0) }
        return Results(metadata: metadata, width: width, height: height, analysisWidth: analysisWidth, analysisHeight: analysisHeight,
                       previewWidth: previewWidth, previewHeight: previewHeight, anchor: anchor,
                       temperature: whiteBalance.temperature, tint: whiteBalance.tint, gains: gains, weights: weights,
                       skyCorrection: SkyShape(everything: skyCorrection.everything, strokes: skyCorrection.strokes),
                       foundSky: try (found as NSData).compressed(using: .lzfse) as Data, skyModelInstalled: skyModelInstalled,
                       alignments: alignments, failures: failures, starCounts: starCounts, starRadii: starRadii,
                       backgrounds: backgrounds, lines: lines, hotPixels: hotPixels.map { Int64($0).littleEndian }.withUnsafeBytes { Data($0) },
                       displayExposure: displayExposure)
    }
    func encodedResults() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(results())
    }
    func saveAnalysis(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encodedResults().write(to: directory.appendingPathComponent("results.plist"), options: .atomic)
    }

    /// Takes `encoded` as the analysis, checked before anything changes; the masks derive from its found sky. The
    /// preview copies are left alone.
    private func apply(_ encoded: Data) throws {
        let r = try PropertyListDecoder().decode(Results.self, from: encoded)
        let count = urls.count
        let found = try (r.foundSky as NSData).decompressed(using: .lzfse) as Data
        guard count >= 2, r.metadata.count == count, (0..<count).contains(r.anchor),
              r.width > 0, r.height > 0, r.width <= 100_000, r.height <= 100_000,
              r.analysisWidth > 1, r.analysisHeight > 1, r.analysisWidth <= Self.analysisLongEdge, r.analysisHeight <= Self.analysisLongEdge,
              r.previewWidth > 1, r.previewHeight > 1, r.previewWidth <= r.analysisWidth, r.previewHeight <= r.analysisHeight,
              [r.gains.count, r.weights.count, r.alignments.count, r.failures.count, r.starCounts.count,
               r.starRadii.count, r.backgrounds.count].allSatisfy({ $0 == count }),
              found.count == r.analysisWidth * r.analysisHeight * MemoryLayout<Float>.size,
              r.hotPixels.count % MemoryLayout<Int64>.size == 0,
              r.skyCorrection.edge == 0,
              r.lines.allSatisfy({ (0..<count).contains($0.frame) }),
              r.alignments.compactMap({ $0 }).allSatisfy({ a in
                  a.transform.m.count == 9 && a.inverse.m.count == 9 &&
                  (a.morph == nil || (a.morph!.x.count == 10 && a.morph!.y.count == 10 && a.morph!.scale > 0))
              }) else { throw LatentImage.invalid() }
        let hot = r.hotPixels.withUnsafeBytes { $0.bindMemory(to: Int64.self).map { Int(Int64(littleEndian: $0)) } }
        guard hot.allSatisfy({ $0 >= 0 && $0 < r.width * r.height }) else { throw LatentImage.invalid() }
        let finder = found.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        metadata = r.metadata
        width = r.width; height = r.height
        analysisWidth = r.analysisWidth; analysisHeight = r.analysisHeight
        previewWidth = r.previewWidth; previewHeight = r.previewHeight
        anchor = r.anchor
        whiteBalance = (r.temperature, r.tint)
        gains = r.gains; weights = r.weights
        alignments = r.alignments; failures = r.failures
        starCounts = r.starCounts; starRadii = r.starRadii; backgrounds = r.backgrounds
        lines = r.lines
        hotPixels = hot; hotPixelsFound = true
        displayExposure = r.displayExposure
        skyModelInstalled = r.skyModelInstalled
        // As analysis leaves them: the found sky shaped by the corrections the stars were aligned with.
        let aw = analysisWidth, ah = analysisHeight
        finderSky = finder; foundSkyProbability = finder
        skyCorrection = r.skyCorrection; skyShape = r.skyCorrection
        skyProbability = try shaped(finder, r.skyCorrection)
        skyValid = try minFilter(skyProbability, width: aw, height: ah, radius: max(3, aw / 400))
        previewProbability = Self.downsample(skyProbability, channels: 1, width: aw, height: ah, to: previewWidth, previewHeight)
        warpedPreviewProbability = previewProbability; warpedValid = skyValid
    }

    /// Restores a saved analysis and decodes the preview copies again, straight at preview size.
    func restoreAnalysis(from directory: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        try apply(Data(contentsOf: directory.appendingPathComponent("results.plist")))
        try rebuildPreviews(progress: progress)
    }

    /// Takes earlier results back without decoding: the copies as shot don't depend on the sky, so only the aligned
    /// copies are warped again. For keeping the lines found before analyzing again.
    func reuse(_ encoded: Data) throws {
        let earlier = try PropertyListDecoder().decode(Results.self, from: encoded)
        guard let cache, earlier.metadata.count == count, earlier.previewWidth == previewWidth, earlier.previewHeight == previewHeight else {
            throw LatentImage.invalid()
        }
        try apply(encoded)
        guard space == .sky else { return }
        let warper = try gpu.map { try NightSkyAnalysisGPU.Warper($0, width: previewWidth, height: previewHeight, mask: previewProbability, threshold: 0.01,
                                                                valid: skyValid, analysis: (analysisWidth, analysisHeight)) }
        let alignments = self.alignments, values = previewWidth * previewHeight * 3
        try cache.rewrite(Array(0..<count), slot: 1) { i, rgb in
            guard let alignment = alignments[i] else { return [Float](repeating: .nan, count: values) }
            return try warper?.warp(rgb, channels: 3, alignment: alignment) ?? warpPreview(rgb, alignment, mask: previewProbability, valid: skyValid)
        }
    }

    private func rebuildPreviews(progress: @escaping @Sendable (Double, String) -> Void) throws {
        let pw = previewWidth, ph = previewHeight, count = self.count
        let cache = try NightSkyCache(count: count, width: pw, height: ph, slots: space == .sky ? 2 : 1)
        let warper = try space == .sky ? gpu.map { try NightSkyAnalysisGPU.Warper($0, width: pw, height: ph, mask: previewProbability, threshold: 0.01,
                                                                                    valid: skyValid, analysis: (analysisWidth, analysisHeight)) } : nil
        var pictures = [CGImage?](repeating: nil, count: count)
        let lock = NSLock()
        var done = 0
        for chunk in stride(from: 0, to: count, by: 6).map({ Array($0..<min(count, $0 + 6)) }) {
            if Task.isCancelled { throw CancellationError() }
            var copies = [[Float]?](repeating: nil, count: chunk.count), errors = [Error?](repeating: nil, count: chunk.count)
            let exposure = displayExposure, gains = self.gains, chunkContext = context
            // Decoding and the thumbnail run side by side; the file is written in order after.
            DispatchQueue.concurrentPerform(iterations: chunk.count) { k in
                do {
                    let i = chunk[k], copy = try developPreview(i, context: chunkContext)
                    let picture = NightSkyFinishing.picture(copy, channels: 3, width: pw, height: ph, exposure: exposure * gains[i], maxDimension: 220)
                    let n = lock.withLock { copies[k] = copy; pictures[i] = picture; done += 1; return done }
                    progress(Double(n) / Double(count), "")
                } catch { lock.withLock { errors[k] = error } }
            }
            if let error = errors.compactMap({ $0 }).first { throw error }
            for (k, i) in chunk.enumerated() {
                let copy = copies[k]!
                try cache.write(copy, frame: i, slot: 0)
                if space == .sky {
                    if let alignment = alignments[i] {
                        try cache.write(try warper?.warp(copy, channels: 3, alignment: alignment)
                                        ?? warpPreview(copy, alignment, mask: previewProbability, valid: skyValid), frame: i, slot: 1)
                    } else {
                        try cache.write([Float](repeating: .nan, count: pw * ph * 3), frame: i, slot: 1)
                    }
                }
            }
        }
        try cache.finish()
        thumbnails = pictures
        self.cache = cache
    }

    /// Photo `i` decoded straight at preview size, linear RGB: about a third faster than decoding at analysis size
    /// and shrinking, and as close as previews need. Its exact size is pinned to the preview grid.
    private func developPreview(_ i: Int, context: CIContext? = nil) throws -> [Float] {
        let context = context ?? self.context
        return try autoreleasepool {
            let pw = previewWidth, ph = previewHeight
            var image = try HDRMergeDecoder.developedImage(urls[i], metadata: metadata[i].base, longEdge: max(pw, ph), whiteBalance: whiteBalance)
            if image.extent.size != CGSize(width: pw, height: ph) {
                image = image.transformed(by: CGAffineTransform(scaleX: Double(pw) / image.extent.width, y: Double(ph) / image.extent.height))
            }
            var rgba = [Float](repeating: 0, count: pw * ph * 4)
            rgba.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: pw * 16, bounds: CGRect(x: 0, y: 0, width: pw, height: ph), format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            var rgb = [Float](repeating: 0, count: pw * ph * 3)
            rgb.withUnsafeMutableBufferPointer { rgb in
                rgba.withUnsafeBufferPointer { rgba in
                    for p in 0..<(pw * ph) { for c in 0..<3 { let v = rgba[p * 4 + c]; rgb[p * 3 + c] = v.isFinite ? v : 0 } }
                }
            }
            return rgb
        }
    }
}
