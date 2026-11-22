import Foundation
import CoreImage
import Metal
import simd

/// The preview and the merged result.
extension HDRMerger {
    public func preview(_ settings: HDRMergeSettings) throws -> HDRMergePreview {
        let (raster, all, shares) = try blend(settings, layers: true)
        let reference = try members(settings).reference
        let maps = all.filter { $0.key != reference }
        let width = analysisWidth, height = analysisHeight
        guard let image = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview could not be drawn.")) }
        if Task.isCancelled { throw CancellationError() }
        var layers: [Int: CGImage] = [:], contributions: [Int: Double] = [:]
        for (i, share) in shares {
            layers[i] = HDRMergeFinishing.gray(share, width: width, height: height)
            contributions[i] = Double(share.reduce(0, +)) / Double(max(1, share.count))
        }
        var motion: CGImage?, coverage = 0.0
        if !maps.isEmpty {
            var rejected = [Float](repeating: 0, count: width * height)
            for i in 0..<width * height {
                rejected[i] = maps.values.reduce(Float(0)) { max($0, 1 - $1[i]) }
            }
            coverage = Double(rejected.filter { $0 > 0.5 }.count) / Double(rejected.count)
            motion = HDRMergeFinishing.mask(rejected, width: width, height: height)
        }
        let source = MergePreviewSource(raster: raster, writer: ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata[reference].panorama, kind: .hdr,
            source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.hdr.rawValue, exposure: false)), source: urls[reference], dropsExposure: true), base: reference)
        return HDRMergePreview(image: image, source: source, motion: motion, motionCoverage: coverage, layers: layers, contributions: contributions, settings: settings)
    }

    /// The merge at analysis size, the same blend as `merge` at full size.
    func previewRaster(_ settings: HDRMergeSettings) throws -> PanoramaRaster { try blend(settings, layers: false).0 }

    /// The merge at analysis size, the consistency maps, and with `layers` each photo's share of each pixel.
    private func blend(_ settings: HDRMergeSettings, layers: Bool) throws -> (PanoramaRaster, [Int: [Float]], [Int: [Float]]) {
        let (reference, contributions) = try members(settings)
        let maps = consistencyMaps(reference: reference, contributions: contributions, deghosting: settings.deghosting)
        let painting = painting(settings.strokes, included: contributions.map(\.index))
        if Task.isCancelled { throw CancellationError() }
        let width = analysisWidth, height = analysisHeight, n = width * height
        var sum = [Float](repeating: 0, count: n * 4)
        var forcedSum = painting?.forced.isEmpty == false ? [Float](repeating: 0, count: n * 4) : []
        var weights: [Int: (blend: [Float], forced: [Float])] = [:]
        for c in contributions {
            let recorded = Self.accumulate(&sum, forcedSum: &forcedSum, width: width, height: height, contribution: c,
                                           trust: maps[c.index].map { ($0, width, height) },
                                           keep: painting?.keep[c.index].map { ($0, width, height) },
                                           forced: painting?.forced[c.index].map { ($0, width, height) }, record: layers) { aligned[c.index] }
            if let recorded { weights[c.index] = recorded }
        }
        var shares: [Int: [Float]] = [:]
        if layers {
            // A pixel's share of each photo: its weight in the blend scaled to the blend's share, plus its own painted share.
            var blendShare = [Float](repeating: 0, count: n), total = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let w = sum[k * 4 + 3], f = forcedSum.isEmpty ? 0 : forcedSum[k * 4 + 3]
                let a: Float = w > 0 ? (painting?.automatic[k] ?? 1) : 0
                blendShare[k] = w > 0 ? a / w : 0; total[k] = a + f
            }
            for (i, recorded) in weights {
                shares[i] = (0..<n).map { k in
                    guard total[k] > 0 else { return 0 }
                    return (recorded.blend[k] * blendShare[k] + (recorded.forced.isEmpty ? 0 : recorded.forced[k])) / total[k]
                }
            }
        }
        let raster = Self.normalized(consume sum, forced: forcedSum.isEmpty ? nil : (forcedSum, painting!.automatic, width, height),
                                     width: width, height: height)
        return (raster, maps, shares)
    }

    /// Adds one photo's weighted radiance and weight into `sum` (RGB × weight, weight), and where the brush gave the photo
    /// a share of its own, that share's radiance and weight into `forcedSum`. `trust` is the photo's consistency map (for
    /// the reference, how strongly it takes over), `keep` what the brush left of its weight, `forced` its painted share:
    /// maps at their own resolution, sampled bilinearly. With `record`, returns the weight and painted share it used at
    /// each pixel. A photo painted out keeps a trace of weight, so it still supplies areas no other photo has light for.
    @discardableResult
    static func accumulate(_ sum: inout [Float], forcedSum: inout [Float], width: Int, height: Int, contribution c: Contribution,
                           trust: ([Float], Int, Int)?, keep: ([Float], Int, Int)? = nil, forced: ([Float], Int, Int)? = nil, record: Bool = false,
                           pixels: () -> [Float]) -> (blend: [Float], forced: [Float])? {
        let source = pixels()
        var recordedBlend = record ? [Float](repeating: 0, count: width * height) : []
        var recordedForced = record && forced != nil ? [Float](repeating: 0, count: width * height) : []
        source.withUnsafeBufferPointer { source in
            sum.withUnsafeMutableBufferPointer { sum in
                forcedSum.withUnsafeMutableBufferPointer { forcedSum in
                    recordedBlend.withUnsafeMutableBufferPointer { recordedBlend in
                        recordedForced.withUnsafeMutableBufferPointer { recordedForced in
                            let sum = sum, forcedSum = forcedSum, recordedBlend = recordedBlend, recordedForced = recordedForced
                            DispatchQueue.concurrentPerform(iterations: height) { y in
                                let my = (Double(y) + 0.5) * Double(trust?.2 ?? keep?.2 ?? forced?.2 ?? height) / Double(height) - 0.5
                                for x in 0..<width {
                                    let p = (y * width + x) * 4
                                    guard source[p + 3] > 0.999 else { continue }
                                    var w = c.weight(max(source[p], source[p + 1], source[p + 2]))
                                    let mx = (Double(x) + 0.5) * Double(trust?.1 ?? keep?.1 ?? forced?.1 ?? width) / Double(width) - 0.5
                                    if let (map, mw, mh) = trust {
                                        let t = sampleMap(map, mw, mh, x: mx, y: my)
                                        if c.isReference { w = max(w, c.exposure * t) } else { w *= t }
                                    }
                                    if let (map, mw, mh) = keep { w *= max(sampleMap(map, mw, mh, x: mx, y: my), 1e-4) }
                                    var f: Float = 0
                                    if let (map, mw, mh) = forced {
                                        f = sampleMap(map, mw, mh, x: mx, y: my)
                                    }
                                    guard w > 0 || f > 0 else { continue }
                                    let radiance = c.radiance(SIMD3(source[p], source[p + 1], source[p + 2]))
                                    if w > 0 {
                                        sum[p] += radiance.x * w; sum[p + 1] += radiance.y * w; sum[p + 2] += radiance.z * w; sum[p + 3] += w
                                        if record { recordedBlend[p / 4] = w }
                                    }
                                    if f > 0 {
                                        forcedSum[p] += radiance.x * f; forcedSum[p + 1] += radiance.y * f; forcedSum[p + 2] += radiance.z * f
                                        forcedSum[p + 3] += f
                                        if record { recordedForced[p / 4] = f }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return record ? (recordedBlend, recordedForced) : nil
    }

    @inline(__always) static func sampleMap(_ map: [Float], _ width: Int, _ height: Int, x: Double, y: Double) -> Float {
        let cx = max(0, min(Double(width - 1), x)), cy = max(0, min(Double(height - 1), y))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = Float(cx - Double(x0)), fy = Float(cy - Double(y0))
        let top = map[y0 * width + x0] * (1 - fx) + map[y0 * width + x1] * fx
        let bottom = map[y1 * width + x0] * (1 - fx) + map[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Divides the weighted sums by their weights in place, so the full-size merge needs no second copy. With `forced`
    /// (the painted sums and the blend's share on its map), the blend gets its share and the painted photos theirs; where
    /// a painted photo doesn't cover a pixel, the rest are scaled up to fill it.
    static func normalized(_ sum: consuming [Float], forced: ([Float], [Float], Int, Int)? = nil, width: Int, height: Int) -> PanoramaRaster {
        var rgba = sum
        rgba.withUnsafeMutableBufferPointer { rgba in
            let rgba = rgba
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let my = forced.map { (Double(y) + 0.5) * Double($0.3) / Double(height) - 0.5 } ?? 0
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    let w = rgba[p + 3]
                    var rgb = w > 0 ? SIMD3(rgba[p], rgba[p + 1], rgba[p + 2]) / w : .zero
                    if let (painted, automatic, mw, mh) = forced, painted[p + 3] > 0 {
                        let a = w > 0 ? sampleMap(automatic, mw, mh, x: (Double(x) + 0.5) * Double(mw) / Double(width) - 0.5, y: my) : 0
                        rgb = (rgb * a + SIMD3(painted[p], painted[p + 1], painted[p + 2])) / (a + painted[p + 3])
                    }
                    rgba[p] = rgb.x; rgba[p + 1] = rgb.y; rgba[p + 2] = rgb.z; rgba[p + 3] = 1
                }
            }
        }
        return PanoramaRaster(width: width, height: height, rgba: rgba)
    }

    /// Where the full-size blend runs: always the GPU; the CPU blend is the reference tests compare it with.
    enum Engine { case cpu, gpu }

    /// Develops each photo at full size, one at a time, blends it in and writes the DNG. The blend runs on the GPU:
    /// each photo stays in GPU memory from development to the sum, about a quarter faster than
    /// copying it back to warp and weigh it on the CPU (4.8 s → 3.6 s for eight 33-megapixel RAW photos), with the
    /// same result to within float rounding.
    public func merge(_ settings: HDRMergeSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        let (raster, reference, contributions) = try mergedRaster(settings, engine: .gpu, progress: progress)
        if Task.isCancelled { throw CancellationError() }
        var anchorMetadata = metadata[reference].panorama
        anchorMetadata.captureTime = PanoramaFrameMetadata.captureTime(after: contributions.map { metadata[$0.index].captureTime }) ?? anchorMetadata.captureTime
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: anchorMetadata, kind: .hdr, preview: HDRMergeFinishing.picture(raster, maxDimension: 1024),
                                                             source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.hdr.rawValue, exposure: false)),
                                      source: urls[reference], dropsExposure: true)
        let size = "\(raster.width.formatted()) × \(raster.height.formatted())", format = url.pathExtension.uppercased()
        try writer.write(raster, to: url, progress: { progress(0.82 + 0.18 * $0, L10n.tr("Writing \(size) \(format)")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }

    /// The full-size merge before it is written. `timing` receives each stage's name and seconds.
    func mergedRaster(_ settings: HDRMergeSettings, engine: Engine, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
                      timing: (String, Double) -> Void = { _, _ in }) throws -> (PanoramaRaster, Int, [Contribution]) {
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        var clock = Date()
        func lap(_ name: String) { let now = Date(); timing(name, now.timeIntervalSince(clock)); clock = now }
        let (reference, contributions) = try members(settings)
        let maps = consistencyMaps(reference: reference, contributions: contributions, deghosting: settings.deghosting)
        let painting = painting(settings.strokes, included: contributions.map(\.index))
        let keepMaps = painting?.keep ?? [:], forcedMaps = painting?.forced ?? [:]
        lap("weights")
        let width = analysis.width, height = analysis.height
        guard Double(width) * Double(height) * (forcedMaps.isEmpty ? 64 : 80) < MemoryBudget.bytes else {
            throw PanoramaError.message(L10n.tr("Not enough memory to merge \(width) × \(height) photos."))
        }
        let scale = Double(width) / Double(analysisWidth)
        func step(_ done: Int, _ c: Contribution) {
            progress(0.8 * Double(done) / Double(contributions.count),
                     L10n.tr("Developing \(metadata[c.index].filename) (\(done + 1) of \(contributions.count))"))
        }
        switch engine {
        case .cpu:
            var sum = [Float](repeating: 0, count: width * height * 4)
            var forcedSum = forcedMaps.isEmpty ? [] : [Float](repeating: 0, count: width * height * 4)
            lap("allocate")
            for (done, c) in contributions.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, c)
                try autoreleasepool {
                    let frame = try HDRMergeDecoder.decode(urls[c.index], metadata: metadata[c.index], longEdge: nil, whiteBalance: whiteBalance, context: context, retouch: retouch[urls[c.index]] ?? [])
                    lap("develop")
                    let transform = transforms[c.index].scaled(by: scale)
                    Self.accumulate(&sum, forcedSum: &forcedSum, width: width, height: height, contribution: c,
                                    trust: maps[c.index].map { ($0, analysisWidth, analysisHeight) },
                                    keep: keepMaps[c.index].map { ($0, analysisWidth, analysisHeight) },
                                    forced: forcedMaps[c.index].map { ($0, analysisWidth, analysisHeight) }) {
                        let warped = Self.warp(frame, transform.inverse, width: width, height: height)
                        lap("warp")
                        return warped
                    }
                    lap("accumulate")
                }
            }
            let raster = Self.normalized(consume sum, forced: forcedSum.isEmpty ? nil : (forcedSum, painting!.automatic, analysisWidth, analysisHeight),
                                         width: width, height: height)
            lap("normalize")
            return (raster, reference, contributions)
        case .gpu:
            guard let sum = gpu.accumulator(width: width, height: height, painted: !forcedMaps.isEmpty) else {
                throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos."))
            }
            lap("allocate")
            for (done, c) in contributions.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, c)
                try autoreleasepool {
                    let image = try HDRMergeDecoder.developedImage(urls[c.index], metadata: metadata[c.index], longEdge: nil, whiteBalance: whiteBalance, retouch: retouch[urls[c.index]] ?? [])
                    try gpu.add(image, to: sum, context: context, contribution: c, inverse: transforms[c.index].scaled(by: scale).inverse,
                                trust: maps[c.index].map { ($0, analysisWidth, analysisHeight) },
                                keep: keepMaps[c.index].map { ($0, analysisWidth, analysisHeight) },
                                forced: forcedMaps[c.index].map { ($0, analysisWidth, analysisHeight) })
                    lap("develop + accumulate")
                }
            }
            let raster = try gpu.normalized(sum, automatic: painting.flatMap { forcedMaps.isEmpty ? nil : ($0.automatic, analysisWidth, analysisHeight) })
            lap("normalize + copy out")
            return (raster, reference, contributions)
        }
    }
}
