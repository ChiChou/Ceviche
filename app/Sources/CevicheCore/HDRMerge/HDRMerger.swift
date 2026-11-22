import Foundation
import CoreImage
import Metal
import simd

/// Merges exposure brackets into one linear HDR DNG. Analyze once (develop reduced copies, align them to the middle
/// exposure, measure each one's exposure from the pixels), preview each choice of options from that, then merge at full
/// size one photo at a time. Use from one task at a time; long steps check `Task.isCancelled`.
///
/// Radiance is estimated in scene-linear light: each bracket is divided by its measured exposure, samples near clipping or
/// in the noise floor are rejected, and the rest are averaged with weights proportional to exposure (more light, less
/// noise). One weight per pixel serves all three channels so clipped channels can't shift hues. Where a bracket disagrees
/// with the reference photo beyond what noise explains, something moved, and the reference supplies that area alone.
/// The result keeps the reference's exposure with highlights above 1; tone mapping is left to Develop.
public final class HDRMerger: @unchecked Sendable {
    public let urls: [URL]
    /// Each photo's own retouching, AI fills included, burnt into it when the result is rendered at full size. The
    /// photos are aligned and analysed without it, so a fill or patch never moves what alignment matches.
    public var retouch: [URL: [RetouchStroke]] = [:]
    public private(set) var analysis: HDRMergeAnalysis?

    let context: CIContext
    let device: MTLDevice
    /// The full-size blend's GPU engine.
    lazy var gpu = HDRMergeGPU(device: device)
    var metadata: [HDRMergeFrameMetadata] = []
    var whiteBalance = (temperature: 5000.0, tint: 0.0)
    /// The photo whose framing the result keeps: the middle exposure.
    var anchor = 0
    /// Per photo, in the order of `urls`.
    var stops: [Double] = []
    var clips: [Float] = []
    var transforms: [HDRSimilarity] = []
    /// Reduced copies warped onto the anchor, RGBA with coverage in alpha.
    var aligned: [[Float]] = []
    var analysisWidth = 0, analysisHeight = 0
    var consistency: [String: [Int: [Float]]] = [:]
    /// Per reference, each other photo's response relative to it.
    var responses: [Int: [Int: HDRResponse]] = [:]
    /// The last layer painting, for the dabs it was painted from.
    var paintCache: (strokes: [HDRMergeStroke], painting: Painting)?

    static let analysisLongEdge = 1600
    /// The white balance to develop with instead of the middle photo's as shot: an HDR panorama's brackets share one,
    /// since each bracket's own steps the seams. Set before `analyze`.
    var sharedWhiteBalance: (temperature: Double, tint: Double)?

    public init(urls: [URL]) throws {
        guard urls.count >= 2 else { throw PanoramaError.message(L10n.tr("Choose at least two exposures to merge.")) }
        self.urls = urls
        guard let device = MTLCreateSystemDefaultDevice() else { throw EditorError.noGPU }
        self.device = device
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    }

    // MARK: Analysis

    public func analyze(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws -> HDRMergeAnalysis {
        let count = urls.count
        // Brackets give their own range: a processed photo's gain map is left out.
        let frames = try urls.map { try HDRMergeDecoder.metadata($0, hdr: false) }
        if Set(frames.map(\.isRAW)).count > 1 {
            throw PanoramaError.message(L10n.tr("Merge RAW photos or processed photos, not both. Brackets need to be the same kind of file."))
        }
        if frames[0].isRAW, Set(frames.map { "\($0.make) \($0.model)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos come from different cameras. HDR brackets need photos from one camera."))
        }
        if Set(frames.map { "\($0.width)×\($0.height)" }).count > 1 {
            throw PanoramaError.message(L10n.tr("These photos have different sizes. HDR brackets need photos of the same size and orientation."))
        }
        let whiteBalance = sharedWhiteBalance ?? (temperature: frames[count / 2].temperature, tint: frames[count / 2].tint)
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
                progress(0.5 * Double(finished) / Double(count), L10n.tr("Reading \(frames[i].filename)"))
            } catch { lock.withLock { failures[i] = error.localizedDescription } }
        }
        if Task.isCancelled { throw CancellationError() }
        if let failure = failures.compactMap({ $0 }).first { throw PanoramaError.message(failure) }
        let sources = decoded.map { $0! }
        // Aligned on the photos as shot; shown and merged with their retouching.
        let shown = sources.indices.map { PanoramaDecoder.retouched(sources[$0], retouch[urls[$0]] ?? []) }
        let width = sources.map(\.width).min()!, height = sources.map(\.height).min()!
        let clips = sources.enumerated().map { Self.clipLevel($0.element, metadata: frames[$0.offset]) }

        // Rough brightness order picks the anchor; exposures are measured properly once the photos are aligned.
        let planes = sources.map { LuminancePlane($0, longEdge: Self.analysisLongEdge) }
        let brightness = planes.map { plane in plane.values.reduce(0.0) { $0 + log(Double(max($1, 1e-4))) } / Double(plane.values.count) }
        let rough = brightness.indices.sorted { brightness[$0] < brightness[$1] }
        let anchor = rough[count / 2]

        progress(0.55, L10n.tr("Aligning photos"))
        // Two matching proxies per photo: equalized as is, and with the noise floor held flat. The first keeps the
        // shadow detail a bright bracket shows; the second stops a dark bracket's noise from becoming corners.
        let floor: Float = frames[0].isRAW ? 0.002 : 0.004
        var features = [[[PanoramaFeature]]](repeating: [], count: count)
        features.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out[i] = [1e-6, floor].map { PanoramaFeatures.detect(HDRMergeAlignment.equalized(planes[i], floor: $0), limit: 2000) }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        func pair(_ i: Int, _ j: Int) -> HDRSimilarity? {
            (0..<2).compactMap { HDRMergeAlignment.estimate(frame: features[i][$0], reference: features[j][$0]) }.max { $0.inliers < $1.inliers }?.0
        }
        // Directly onto the anchor, or else through the neighbouring exposure toward it, which shares more tones.
        var solved: [Int: HDRSimilarity?] = [anchor: .identity]
        func transform(_ i: Int) -> HDRSimilarity? {
            if let known = solved[i] { return known }
            var result = pair(i, anchor)
            if result == nil, let k = rough.firstIndex(of: i), let a = rough.firstIndex(of: anchor) {
                let neighbour = rough[k < a ? k + 1 : k - 1]
                if neighbour != anchor, let link = pair(i, neighbour), let rest = transform(neighbour) { result = rest.after(link) }
            }
            solved[i] = result
            return result
        }
        var transforms = [HDRSimilarity](repeating: .identity, count: count)
        var measured = [Bool](repeating: true, count: count)
        for i in 0..<count where i != anchor {
            if let model = transform(i) {
                // Brackets from a tripod: a sub-pixel estimate is noise, and resampling would only soften the photo.
                transforms[i] = model.displacement(width: Double(width), height: Double(height)) < 0.3 ? .identity : model
            } else { measured[i] = false }
        }

        progress(0.75, L10n.tr("Measuring exposures"))
        var aligned = [[Float]](repeating: [], count: count)
        aligned.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: count) { i in
                out[i] = Self.warp(shown[i], transforms[i].inverse, width: width, height: height)
            }
        }
        let stops = try Self.measureStops(aligned, width: width, height: height, clips: clips, isRAW: frames[0].isRAW,
                                          order: rough, recorded: frames.map(\.recordedStops), filenames: frames.map(\.filename))

        let order = stops.indices.sorted { stops[$0] < stops[$1] }
        let lowest = stops.min()!, recordedLowest = frames.compactMap(\.recordedStops).min()
        let scale = Double(frames[0].width) / Double(width)
        let infos = order.map { i in
            HDRMergeFrameInfo(index: i, filename: frames[i].filename, stops: stops[i] - lowest,
                              recordedStops: frames.allSatisfy { $0.recordedStops != nil } ? frames[i].recordedStops! - recordedLowest! : nil,
                              shift: measured[i] ? transforms[i].translation * scale : nil,
                              rotationDegrees: measured[i] ? transforms[i].rotationDegrees : nil,
                              thumbnail: PanoramaFinishing.picture(PanoramaRaster(width: sources[i].width, height: sources[i].height, rgba: shown[i].pixels), maxDimension: 240))
        }
        let analysis = HDRMergeAnalysis(frames: infos, suggestedReference: anchor, width: frames[0].width, height: frames[0].height)
        self.metadata = frames; self.whiteBalance = whiteBalance; self.anchor = anchor; self.stops = stops; self.clips = clips
        self.transforms = transforms; self.aligned = aligned; self.analysisWidth = width; self.analysisHeight = height
        self.consistency = [:]; self.responses = [:]; self.paintCache = nil; self.analysis = analysis
        progress(1, "")
        return analysis
    }

    /// The level a photo clips at. Processed photos clip at white, or with a gain map at its headroom. Developed RAW photos clip where their brightest channel
    /// piles up: highlight recovery lets a few reconstructed pixels run past that pile, so it is found as a spike in the
    /// histogram near the top rather than at the very top. Without one, nothing clipped and the level is above it all.
    static func clipLevel(_ frame: PanoramaFrame, metadata: HDRMergeFrameMetadata) -> Float {
        guard metadata.isRAW else { return metadata.headroom ?? 1 }
        var top: Float = 0, total = 0
        for p in stride(from: 0, to: frame.pixels.count, by: 16) { top = max(top, frame.pixels[p], frame.pixels[p + 1], frame.pixels[p + 2]); total += 1 }
        guard top > 0 else { return 1 }
        let bins = 200
        var histogram = [Int](repeating: 0, count: bins)
        for p in stride(from: 0, to: frame.pixels.count, by: 16) {
            let peak = max(frame.pixels[p], frame.pixels[p + 1], frame.pixels[p + 2])
            histogram[max(0, min(bins - 1, Int(peak / top * Float(bins))))] += 1
        }
        // From the top down, the first bin holding 0.1% of the pixels and standing well above the bins just below it.
        // Highlight reconstruction leaves some values above a real plateau, but never most of the frame: without that
        // test, the sharp edge of a bright, even background's peak passed for a plateau (a focus bracket on a beige
        // backdrop had 93 % of its pixels "clipped" at 28 % of its maximum, which skewed exposure gains and focus).
        var above = 0
        for k in stride(from: bins - 1, through: bins / 4, by: -1) {
            defer { above += histogram[k] }
            guard histogram[k] * 1000 >= total else { continue }
            let below = histogram[(k - 8)..<(k - 2)].sorted()[3]
            if histogram[k] >= 4 * max(below, 1) && 2 * above < total { return 0.98 * Float(k) / Float(bins) * top }
        }
        return 1.25 * top
    }

    /// Exposure in stops for each photo (arbitrary origin) from the luminance ratio of neighbouring brackets where both are
    /// well exposed; the camera's record bridges a pair that shares too little usable tone.
    static func measureStops(_ aligned: [[Float]], width: Int, height: Int, clips: [Float], isRAW: Bool, order: [Int],
                             recorded: [Double?], filenames: [String]) throws -> [Double] {
        var stops = [Double](repeating: 0, count: aligned.count)
        let floor: Float = isRAW ? 0.006 : 0.02, shoulder: Float = isRAW ? 0.8 : 0.6
        for k in 1..<order.count {
            let a = order[k - 1], b = order[k]
            var ratios: [Float] = []
            ratios.reserveCapacity(width * height / 4)
            for p in stride(from: 0, to: width * height * 4, by: 4 * 2) where aligned[a][p + 3] > 0.999 && aligned[b][p + 3] > 0.999 {
                let ma = max(aligned[a][p], aligned[a][p + 1], aligned[a][p + 2]), mb = max(aligned[b][p], aligned[b][p + 1], aligned[b][p + 2])
                guard ma > floor, mb > floor, ma < shoulder * clips[a], mb < shoulder * clips[b] else { continue }
                ratios.append(log2(luminance(aligned[b], p) / max(luminance(aligned[a], p), 1e-6)))
            }
            let difference: Double
            if ratios.count >= 500 {
                ratios.sort()
                difference = Double(ratios[ratios.count / 2])
            } else if let ra = recorded[a], let rb = recorded[b] {
                difference = rb - ra
            } else {
                throw PanoramaError.message(L10n.tr("\(filenames[a]) and \(filenames[b]) share too little detail to measure their exposures. Brackets more than about 3 stops apart need exposure information in the files."))
            }
            stops[b] = stops[a] + difference
        }
        return stops
    }

    @inline(__always) static func luminance(_ rgba: [Float], _ p: Int) -> Float {
        0.2126 * rgba[p] + 0.7152 * rgba[p + 1] + 0.0722 * rgba[p + 2]
    }

    /// Resamples `frame` onto a width × height grid, bilinearly; `inverse` maps grid points into the frame. Alpha is 1
    /// where the frame covers the point.
    static func warp(_ frame: PanoramaFrame, _ inverse: HDRSimilarity, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        let identity = inverse == .identity && frame.width == width && frame.height == height
        frame.pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                let out = out
                if identity {
                    for i in 0..<width * height * 4 { out[i] = source[i] }
                    for i in 0..<width * height { out[i * 4 + 3] = 1 }
                    return
                }
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let p = inverse.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
                        let o = (y * width + x) * 4
                        guard let sample = bilinear(source, frame.width, frame.height, p) else { continue }
                        out[o] = sample.x; out[o + 1] = sample.y; out[o + 2] = sample.z; out[o + 3] = 1
                    }
                }
            }
        }
        return out
    }

    @inline(__always) static func bilinear(_ pixels: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ p: SIMD2<Double>) -> SIMD3<Float>? {
        guard p.x >= -0.5, p.y >= -0.5, p.x <= Double(width) - 0.5, p.y <= Double(height) - 0.5 else { return nil }
        let x0 = max(0, min(width - 1, Int(p.x.rounded(.down)))), y0 = max(0, min(height - 1, Int(p.y.rounded(.down))))
        let x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = Float(max(0, min(1, p.x - Double(x0)))), fy = Float(max(0, min(1, p.y - Double(y0))))
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> { let i = (y * width + x) * 4; return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2]) }
        let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx, bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: Layer brush

    /// What the layer brush decided on the analysis grid: per photo, a multiplier on its weight in the automatic blend
    /// (`keep`) and the share of the result it supplies on its own (`forced`); `automatic` is the share left to the blend.
    struct Painting {
        var keep: [Int: [Float]] = [:]
        var forced: [Int: [Float]] = [:]
        var automatic: [Float]
    }

    /// The dabs on included photos applied in order; nil without any. A dab that adds gives its photo that share of each
    /// pixel outright, taken in proportion from the blend and from earlier dabs. One that removes hands its photo's
    /// painted share back to the blend and keeps the photo out of the blend there.
    func painting(_ strokes: [HDRMergeStroke], included: [Int]) -> Painting? {
        let usable = strokes.filter { included.contains($0.photo) }
        guard !usable.isEmpty else { return nil }
        if let cache = paintCache, cache.strokes == usable { return cache.painting }
        let width = analysisWidth, height = analysisHeight, n = width * height, unit = Double(width)
        var painting = Painting(automatic: [Float](repeating: 1, count: n))
        for stroke in usable {
            // Fractions of the width to pixel indices, whose centres lie at whole numbers.
            let mask = Self.softDisc(SIMD2(stroke.x, stroke.y) * unit - 0.5, radius: stroke.radius * unit, width: width, height: height)
            let photo = stroke.photo
            if stroke.add {
                if painting.forced[photo] == nil { painting.forced[photo] = [Float](repeating: 0, count: n) }
                let others = painting.forced.keys.filter { $0 != photo }
                for (k, a) in mask {
                    painting.automatic[k] *= 1 - a
                    for i in others { painting.forced[i]![k] *= 1 - a }
                    painting.forced[photo]![k] = a + (1 - a) * painting.forced[photo]![k]
                }
            } else {
                if painting.keep[photo] == nil { painting.keep[photo] = [Float](repeating: 1, count: n) }
                for (k, a) in mask {
                    painting.keep[photo]![k] *= 1 - a
                    if let share = painting.forced[photo]?[k], share > 0 {
                        painting.forced[photo]![k] -= share * a
                        painting.automatic[k] += share * a
                    }
                }
            }
        }
        paintCache = (usable, painting)
        return painting
    }

    /// A dab as (pixel, coverage): whole within half its radius, fading smoothly to nothing at its edge, so neighbouring
    /// dabs build an even stroke and exposures that differ a little (moving cloud, noise) meet without a seam.
    static func softDisc(_ centre: SIMD2<Double>, radius: Double, width: Int, height: Int) -> [(Int, Float)] {
        let outer = max(radius, 1.5), inner = 0.5 * outer
        let x0 = max(0, Int(centre.x - outer)), x1 = min(width - 1, Int(centre.x + outer) + 1)
        let y0 = max(0, Int(centre.y - outer)), y1 = min(height - 1, Int(centre.y + outer) + 1)
        guard x0 <= x1, y0 <= y1 else { return [] }
        var mask: [(Int, Float)] = []
        for y in y0...y1 { for x in x0...x1 {
            let a = 1 - smoothstep(Float(inner), Float(outer), Float(hypot(Double(x) - centre.x, Double(y) - centre.y)))
            if a > 0.002 { mask.append((y * width + x, a)) }
        }}
        return mask
    }
}

/// A photo's tones relative to the reference's: log2 corrections per channel at log-spaced luminance, from the median of
/// measured ratios, carried flat beyond the measured range and interpolated in between.
struct HDRResponse: Sendable {
    static let bins = 40, low: Float = -12, step: Float = 0.5
    var values: [SIMD3<Float>]

    static func bin(_ luminance: Float) -> Int {
        max(0, min(bins - 1, Int((log2(max(luminance, 1e-9)) - low) / step)))
    }

    init(samples: [[SIMD3<Float>]]) {
        var measured = [SIMD3<Float>?](repeating: nil, count: Self.bins)
        for (k, list) in samples.enumerated() where list.count >= 200 {
            func median(_ values: [Float]) -> Float { let sorted = values.sorted(); return sorted[sorted.count / 2] }
            measured[k] = SIMD3(median(list.map(\.x)), median(list.map(\.y)), median(list.map(\.z)))
        }
        let known = measured.indices.filter { measured[$0] != nil }
        guard !known.isEmpty else { values = Array(repeating: .zero, count: Self.bins); return }
        // Unmeasured tones take the nearest measured one.
        var filled = measured.indices.map { k in measured[known.min { abs($0 - k) < abs($1 - k) }!]! }
        for _ in 0..<2 {
            let previous = filled
            for k in filled.indices { filled[k] = (previous[max(0, k - 1)] + 2 * previous[k] + previous[min(Self.bins - 1, k + 1)]) / 4 }
        }
        values = filled
    }

    /// Multiplier for a sample of this luminance (already in the reference's exposure).
    @inline(__always) func factor(_ luminance: Float) -> SIMD3<Float> {
        let t = max(0, min(Float(Self.bins - 1), (log2(max(luminance, 1e-9)) - Self.low) / Self.step - 0.5))
        let k = min(Self.bins - 2, Int(t)), f = t - Float(k)
        let v = values[k] * (1 - f) + values[k + 1] * f
        return SIMD3(exp2(v.x), exp2(v.y), exp2(v.z))
    }
}
