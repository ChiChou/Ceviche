import Foundation
import CoreImage
import Metal
import simd

/// The preview and the merged result.
extension FocusStacker {
    public func preview(_ settings: FocusStackSettings) throws -> FocusStackPreview {
        let (layout, steps, reference, crop, weights) = try plan(settings, fullSize: false)
        var plain = settings; plain.strokes.removeAll { $0.repair == true }
        let base: PanoramaRaster
        if let cache = repairBaseCache, cache.settings == plain, cache.depth == usesDepth { base = cache.raster }
        else {
            base = try fuse(layout, steps, reference: reference) { i in sources[i] }
            repairBaseCache = (plain, usesDepth, base); repairAlignedCache = nil
        }
        let raster = try repaired(base, settings: settings, layout: layout, steps: steps, fullSize: false)
        guard let image = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview could not be drawn.")) }
        // The source map and its statistics over the cropped area.
        let order = analysis?.frames.map(\.index) ?? []
        var bytes = [UInt8](repeating: 255, count: layout.width * layout.height * 4)
        var counts = [Int: Int](), uncertain = 0
        let palette = order.indices.map { FocusStackPreview.color(position: $0, count: order.count) }
        for y in 0..<layout.height { for x in 0..<layout.width {
            let (px, py) = layout.priorPoint(x, y)
            let k = max(0, min(analysisHeight - 1, Int(py.rounded()))) * analysisWidth + max(0, min(analysisWidth - 1, Int(px.rounded())))
            let source = weights.sources[k]
            counts[source, default: 0] += 1
            if weights.uncertain[k] { uncertain += 1 }
            let color = palette[order.firstIndex(of: source) ?? 0], o = (y * layout.width + x) * 4
            bytes[o] = UInt8(color.red * 255); bytes[o + 1] = UInt8(color.green * 255); bytes[o + 2] = UInt8(color.blue * 255)
        } }
        let total = Double(layout.width * layout.height)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let sources = CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: layout.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PanoramaError.message(L10n.tr("The preview could not be drawn."))
        }
        // Preview fractions → the reference's analysis pixels → the anchor's, in fractions of its width.
        let toAnchor = anchorTransform(reference, breathing: settings.correctBreathing)
        let l = toAnchor.linear, t = toAnchor.translation, unit = Double(analysisWidth)
        let w = Double(layout.width), h = Double(layout.height), o = layout.priorOffset
        let toBrush = CGAffineTransform(a: l[0][0] * w / unit, b: l[0][1] * w / unit, c: l[1][0] * h / unit, d: l[1][1] * h / unit,
                                        tx: (l[0][0] * o.x + l[1][0] * o.y + t.x) / unit, ty: (l[0][1] * o.x + l[1][1] * o.y + t.y) / unit)
        // Ordinary previews only look up a cached field. They never initialize inspection pipelines or measure maps.
        let key = InspectionKey(reference: reference, breathing: settings.correctBreathing, included: steps.map(\.index),
                                width: layout.width, height: layout.height, offset: layout.priorOffset)
        let inspection = inspectionCache.flatMap { $0.key == key ? $0.value : nil }
        if Task.isCancelled { throw CancellationError() }
        let source = MergePreviewSource(raster: raster, writer: ToolResultWriter(dng: PanoramaDNGWriter(metadata: metadata[reference].panorama, kind: .focusStack,
            source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.focusStack.rawValue)), source: urls[reference]), base: reference)
        return FocusStackPreview(inspection: inspection, image: image, source: source, sources: sources, contributions: counts.mapValues { Double($0) / total },
                                 uncertainCoverage: Double(uncertain) / total,
                                 outputWidth: Int(crop.width), outputHeight: Int(crop.height), settings: settings,
                                 toBrushSpace: toBrush, brushScale: toAnchor.scale * w / unit)
    }

    /// Requested only when an inspection view is first shown. Reuses analysis without fusing the photograph again.
    /// The last grid is cached across all inspection modes, blend changes and layer painting.
    public func inspection(_ settings: FocusStackSettings) throws -> FocusStackInspection? {
        guard let analysis else { return nil }
        let (reference, included) = try members(settings)
        let prepared = try prepare(reference: reference, breathing: settings.correctBreathing)
        let crop = crop(settings, transforms: prepared.transforms, included: included)
        let scale = Double(analysisWidth) / Double(analysis.width)
        let offset = SIMD2(Double(crop.minX), Double(crop.minY)) * scale
        let width = max(1, Int((Double(crop.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(crop.height) * scale).rounded(.down)))
        let key = InspectionKey(reference: reference, breathing: settings.correctBreathing, included: included,
                                width: width, height: height, offset: offset)
        if let cached = inspectionCache, cached.key == key { return cached.value }
        guard let inspectionGPU else { return nil }
        let value = try inspectionGPU.measure(focus: prepared.focus, included: included, width: analysisWidth, height: analysisHeight,
                                              outputWidth: width, outputHeight: height, offset: offset, scale: 1)
        if Task.isCancelled { throw CancellationError() }
        inspectionCache = (key, value)
        return value
    }

    /// The merge at analysis size, the same blend as `merge` at full size.
    func previewRaster(_ settings: FocusStackSettings) throws -> PanoramaRaster {
        let (layout, steps, reference, _, _) = try plan(settings, fullSize: false)
        return try fuse(layout, steps, reference: reference) { i in sources[i] }
    }

    /// The photos as the merge sees them at analysis size: aligned, exposure-matched and cropped, by index, with the
    /// source map on the same grid and the grid's origin in the reference's pixels.
    func alignedRasters(_ settings: FocusStackSettings) throws -> (frames: [Int: PanoramaRaster], sources: [Int], origin: SIMD2<Double>) {
        let (layout, steps, _, _, weights) = try plan(settings, fullSize: false)
        var frames: [Int: PanoramaRaster] = [:]
        for step in steps {
            frames[step.index] = PanoramaRaster(width: layout.width, height: layout.height,
                                                rgba: FocusStackCPUFusion.warp(sources[step.index], step.inverse, gain: step.gain, width: layout.width, height: layout.height))
        }
        var map = [Int](repeating: 0, count: layout.width * layout.height)
        for y in 0..<layout.height { for x in 0..<layout.width {
            let (px, py) = layout.priorPoint(x, y)
            map[y * layout.width + x] = weights.sources[max(0, min(analysisHeight - 1, Int(py.rounded()))) * analysisWidth + max(0, min(analysisWidth - 1, Int(px.rounded())))]
        } }
        return (frames, map, layout.priorOffset)
    }

    func fuse(_ layout: FocusStackLayout, _ steps: [FocusStackFrameStep], reference: Int, frame: (Int) throws -> PanoramaFrame) throws -> PanoramaRaster {
        // The merge's GPU engine blends the reduced photos too.
        if analysisEngine == .gpu {
            let fusion = try gpu.fusion(layout), context = self.context
            for step in steps {
                if Task.isCancelled { throw CancellationError() }
                let source = try frame(step.index)
                let image = CIImage(bitmapData: source.pixels.withUnsafeBytes { Data($0) }, bytesPerRow: source.width * 16,
                                    size: CGSize(width: source.width, height: source.height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
                try gpu.add(image, to: fusion, context: context, step: step, isReference: step.index == reference)
            }
            return try gpu.finish(fusion)
        }
        let fusion = FocusStackCPUFusion(layout: layout)
        for step in steps {
            if Task.isCancelled { throw CancellationError() }
            fusion.add(try frame(step.index), step, isReference: step.index == reference)
        }
        return fusion.finish()
    }

    /// Where a merge runs: the GPU, or the CPU reference tests compare it with.
    enum Engine { case cpu, gpu }

    /// Develops each photo at full size, one at a time, blends it in and writes the DNG to `url`. The blend runs on the
    /// GPU: each photo stays in GPU memory from development to the running sums.
    public func merge(_ settings: FocusStackSettings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) throws {
        let (raster, reference, included) = try mergedRaster(settings, engine: .gpu, progress: progress)
        if Task.isCancelled { throw CancellationError() }
        var referenceMetadata = metadata[reference].panorama
        referenceMetadata.captureTime = included.compactMap { metadata[$0].captureTime }.max() ?? referenceMetadata.captureTime
        let writer = ToolResultWriter(dng: PanoramaDNGWriter(metadata: referenceMetadata, kind: .focusStack, preview: HDRMergeFinishing.picture(raster, maxDimension: 1024),
                                                             source: .merge(urls[reference], process: PanoramaDNGWriter.Kind.focusStack.rawValue)), source: urls[reference])
        let size = "\(raster.width.formatted()) × \(raster.height.formatted())", format = url.pathExtension.uppercased()
        try writer.write(raster, to: url, progress: { progress(0.82 + 0.18 * $0, L10n.tr("Writing \(size) \(format)")) }, cancelled: { Task.isCancelled })
        progress(1, L10n.tr("Saved"))
    }

    /// The full-size merge before it is written. `timing` receives each stage's name and seconds.
    func mergedRaster(_ settings: FocusStackSettings, engine: Engine, progress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
                      timing: (String, Double) -> Void = { _, _ in }) throws -> (PanoramaRaster, Int, [Int]) {
        var clock = Date()
        func lap(_ name: String) { let now = Date(); timing(name, now.timeIntervalSince(clock)); clock = now }
        let (layout, steps, reference, _, _) = try plan(settings, fullSize: true)
        lap("plan")
        guard Double(layout.width) * Double(layout.height) * 96 < MemoryBudget.bytes else {
            throw PanoramaError.message(L10n.tr("Not enough memory to stack \(layout.width) × \(layout.height) photos."))
        }
        func step(_ done: Int, _ s: FocusStackFrameStep) {
            progress(0.8 * Double(done) / Double(steps.count), L10n.tr("Developing \(metadata[s.index].filename) (\(done + 1) of \(steps.count))"))
        }
        let included = steps.map(\.index)
        switch engine {
        case .cpu:
            let fusion = FocusStackCPUFusion(layout: layout)
            for (done, s) in steps.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, s)
                try autoreleasepool {
                    let frame = try HDRMergeDecoder.decode(urls[s.index], metadata: metadata[s.index], longEdge: nil, whiteBalance: whiteBalance, context: context, retouch: retouch[urls[s.index]] ?? [])
                    lap("develop")
                    fusion.add(frame, s, isReference: s.index == reference)
                    lap("blend")
                }
            }
            let raster = fusion.finish()
            lap("finish")
            return (try repaired(raster, settings: settings, layout: layout, steps: steps, fullSize: true), reference, included)
        case .gpu:
            let fusion = try gpu.fusion(layout)
            lap("allocate")
            for (done, s) in steps.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                step(done, s)
                try autoreleasepool {
                    let image = try HDRMergeDecoder.developedImage(urls[s.index], metadata: metadata[s.index], longEdge: nil, whiteBalance: whiteBalance, retouch: retouch[urls[s.index]] ?? [])
                    try gpu.add(image, to: fusion, context: context, step: s, isReference: s.index == reference)
                    lap("develop + blend")
                }
            }
            let raster = try gpu.finish(fusion)
            lap("finish + copy out")
            return (try repaired(raster, settings: settings, layout: layout, steps: steps, fullSize: true), reference, included)
        }
    }
}
