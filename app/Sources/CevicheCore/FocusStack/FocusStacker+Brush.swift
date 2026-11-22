import Foundation
import CoreImage
import Metal
import simd

/// The layer brush, and the automatic repair that paints with it.
extension FocusStacker {
    /// Each photo onto the anchor, the alignment frame the brush paints in, as `prepare` uses them.
    func anchorTransform(_ index: Int, breathing: Bool) -> HDRSimilarity {
        breathing ? transforms[index] : FocusStackAlignment.withoutScale(transforms[index], width: analysisWidth, height: analysisHeight)
    }

    /// `weights` with the brush's dabs applied in order on the reference's analysis grid, and how fully the brush decided
    /// each pixel. A dab that adds takes its area from its photo alone; one that removes takes its photo out and gives
    /// its share to the others in proportion, or to the next sharpest where no other had any. Edges are softened over
    /// about a pixel and a half of the analysis grid, which the full-size merge widens as it scales the weights up.
    func painted(_ base: Weights, strokes: [FocusStackStroke], prepared: Prepared, reference: Int, included: [Int],
                         breathing: Bool, key: String) -> (Weights, [Float]) {
        if let cache = paintCache, cache.key == key, cache.strokes == strokes { return (cache.weights, cache.painted) }
        let width = analysisWidth, height = analysisHeight, n = width * height
        var weights = base.weights, coverage = [Float](repeating: 0, count: n)
        let fromAnchor = anchorTransform(reference, breathing: breathing).inverse
        let scale = fromAnchor.scale, unit = Double(width)
        let members = Set(included), others = included
        let usable = strokes.filter { $0.repair != true && members.contains($0.photo) }
        // Each plain dab is a disc; a smart selection's dabs go together, as the area they pick.
        var groups: [(stroke: FocusStackStroke, mask: [(Int, Float)])] = []
        var start = 0
        while start < usable.count {
            let first = usable[start]
            var end = start + 1
            if let selection = first.selection {
                while end < usable.count, usable[end].selection == selection { end += 1 }
            }
            let discs = usable[start..<end].map { stroke in
                (centre: fromAnchor.apply(SIMD2(stroke.x, stroke.y) * unit), radius: stroke.radius * unit * scale)
            }
            if first.selection != nil {
                groups.append((first, Self.smartSelection(discs, prepared: prepared, reference: reference, width: width, height: height)))
            } else {
                groups.append((first, Self.disc(discs[0].centre, radius: discs[0].radius, width: width, height: height)))
            }
            start = end
        }
        for (stroke, mask) in groups {
            for (k, a) in mask {
                coverage[k] = max(coverage[k], a)
                if stroke.add {
                    for i in others where i != stroke.photo && weights[i]![k] > 0 { weights[i]![k] *= 1 - a }
                    weights[stroke.photo]![k] = a + (1 - a) * weights[stroke.photo]![k]
                } else {
                    let removed = weights[stroke.photo]![k] * a
                    guard removed > 0 else { continue }
                    weights[stroke.photo]![k] -= removed
                    var rest: Float = 0
                    for i in others where i != stroke.photo { rest += weights[i]![k] }
                    if rest > 0 {
                        for i in others where i != stroke.photo && weights[i]![k] > 0 { weights[i]![k] += removed * weights[i]![k] / rest }
                    } else if let next = others.filter({ $0 != stroke.photo && prepared.focus[$0][k].isFinite })
                                .max(by: { prepared.focus[$0][k] < prepared.focus[$1][k] }) {
                        weights[next]![k] += removed
                    } else {
                        weights[stroke.photo]![k] += removed
                    }
                }
            }
        }
        var sources = base.sources
        for k in 0..<n where coverage[k] > 0 {
            var top: Float = -1
            for i in included where weights[i]![k] > top { top = weights[i]![k]; sources[k] = i }
        }
        let result = Weights(weights: weights, sources: sources, uncertain: base.uncertain)
        paintCache = (key, strokes, result, coverage)
        return (result, coverage)
    }

    /// A dab's disc on the analysis grid, its edge softened over a pixel and a half, as (pixel, coverage).
    static func disc(_ centre: SIMD2<Double>, radius: Double, width: Int, height: Int) -> [(Int, Float)] {
        let feather = 1.5
        let x0 = max(0, Int(centre.x - radius - feather)), x1 = min(width - 1, Int(centre.x + radius + feather))
        let y0 = max(0, Int(centre.y - radius - feather)), y1 = min(height - 1, Int(centre.y + radius + feather))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var mask: [(Int, Float)] = []
        for y in y0...y1 { for x in x0...x1 {
            let d = hypot(Double(x) - centre.x, Double(y) - centre.y)
            let a = Float(max(0, min(1, (radius - d) / feather + 0.5)))
            if a > 0 { mask.append((y * width + x, a)) }
        } }
        return mask
    }

    /// The area a smart selection's dabs pick, as (pixel, coverage): every pixel connected to the dabs whose relative
    /// depth lies within the range they touched (its 5th to 95th percentile, widened by 3% of the scene's depth ranks),
    /// or without the depth model whose tone does. The depth model sees the scene at 518 × 392, so the region's edge is
    /// then fitted to the picture by a guided filter on the sharpest photo's proxy; the dabs themselves stay selected.
    private static func smartSelection(_ discs: [(centre: SIMD2<Double>, radius: Double)], prepared: Prepared, reference: Int,
                               width: Int, height: Int) -> [(Int, Float)] {
        let n = width * height
        var seeds = [Float](repeating: 0, count: n)
        for disc in discs { for (k, a) in Self.disc(disc.centre, radius: disc.radius, width: width, height: height) { seeds[k] = max(seeds[k], a) } }
        // The sharpest photo's proxy at each pixel: what the region's edge should follow.
        var guide = [Float](repeating: 0, count: n)
        for k in 0..<n {
            var top = -Float.infinity, index = reference
            for i in prepared.focus.indices where prepared.focus[i][k] > top { top = prepared.focus[i][k]; index = i }
            guide[k] = prepared.proxies[index][k]
        }
        let key: [Float], tolerance: Float
        if let ranks = prepared.depthRanks {
            key = ranks; tolerance = 0.03
        } else {
            key = guide
            let touched = (0..<n).filter { seeds[$0] > 0.5 }.map { guide[$0] }
            let mean = touched.reduce(0, +) / Float(max(1, touched.count))
            let spread = (touched.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(1, touched.count))).squareRoot()
            tolerance = max(0.02, 0.5 * spread)
        }
        let touched = (0..<n).filter { seeds[$0] > 0.5 }.map { key[$0] }.sorted()
        guard !touched.isEmpty else { return [] }
        let low = touched[touched.count / 20] - tolerance, high = touched[touched.count * 19 / 20] + tolerance
        // Flood fill from the dabs through pixels in range.
        var region = [Float](repeating: 0, count: n), queue: [Int] = []
        queue.reserveCapacity(n / 4)
        for k in 0..<n where seeds[k] > 0.5 { region[k] = 1; queue.append(k) }
        var head = 0
        while head < queue.count {
            let k = queue[head]; head += 1
            let x = k % width, y = k / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let j = ny * width + nx
                if region[j] == 0, key[j] >= low, key[j] <= high { region[j] = 1; queue.append(j) }
            }
        }
        let refined = FocusStackFilters.guided(region, guide: guide, width: width, height: height, radius: max(2, width / 200), epsilon: 1e-3)
        var mask: [(Int, Float)] = []
        for k in 0..<n {
            // Steepened around one half, so the filtered edge is a narrow transition, not a wide ramp.
            let a = max(seeds[k], max(0, min(1, (refined[k] - 0.5) * 3 + 0.5)))
            if a > 0.01 { mask.append((k, a)) }
        }
        return mask
    }

    /// One photo's share of each pixel of the preview, white where the result comes from it alone: its layer's mask.
    public func layerMask(_ settings: FocusStackSettings, photo: Int) throws -> CGImage {
        let (layout, _, _, _, weights) = try plan(settings, fullSize: false)
        guard let plane = weights.weights[photo] else { throw PanoramaError.message(L10n.tr("Include the photo to see its layer.")) }
        var bytes = [UInt8](repeating: 0, count: layout.width * layout.height)
        for y in 0..<layout.height { for x in 0..<layout.width {
            let (px, py) = layout.priorPoint(x, y)
            bytes[y * layout.width + x] = UInt8(max(0, min(1, HDRMerger.sampleMap(plane, analysisWidth, analysisHeight, x: px, y: py))) * 255)
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: layout.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw PanoramaError.message(L10n.tr("The preview could not be drawn."))
        }
        return image
    }

    /// Resolve one source per stroke from coherent edge sharpness, then composite only its spill side. Source choices
    /// use the aligned analysis grid; the full merge re-detects the actual contour in full-size source pixels.
    func repaired(_ raster: PanoramaRaster, settings: FocusStackSettings, layout: FocusStackLayout,
                          steps: [FocusStackFrameStep], fullSize: Bool) throws -> PanoramaRaster {
        let strokes = settings.strokes.filter { $0.repair == true }
        guard !strokes.isEmpty else { return raster }
        if repairGPU == nil { repairGPU = try FocusStackRepairGPU(device: device) }
        let renderer = repairGPU!
        var plain = settings; plain.strokes.removeAll { $0.repair == true }
        let reduced = try plan(plain, fullSize: false)
        let base: PanoramaRaster
        if !fullSize { base = raster }
        else if let cache = repairBaseCache, cache.settings == plain, cache.depth == usesDepth { base = cache.raster }
        else {
            base = try fuse(reduced.layout, reduced.steps, reference: reduced.reference) { sources[$0] }
            repairBaseCache = (plain, usesDepth, base)
        }
        let prepared = try prepare(reference: reduced.reference, breathing: settings.correctBreathing)
        let fromAnchor = anchorTransform(reduced.reference, breathing: settings.correctBreathing).inverse
        let unit = Double(analysisWidth)
        var result = raster, start = 0
        while start < strokes.count {
            if Task.isCancelled { throw CancellationError() }
            var end = start + 1
            if let id = strokes[start].selection { while end < strokes.count, strokes[end].selection == id { end += 1 } }
            let group = Array(strokes[start..<end]); start = end
            let original = group.map { stroke -> SIMD4<Float> in
                let q = fromAnchor.apply(SIMD2(stroke.x, stroke.y) * unit) - reduced.layout.priorOffset
                return SIMD4(Float(q.x), Float(q.y), Float(stroke.radius * unit * fromAnchor.scale), 0)
            }
            // Dense samples follow curved contours without extending the painted footprint. No global segmentation.
            var dabs: [SIMD4<Float>] = []
            for dab in original {
                if let last = dabs.last {
                    let distance = simd_length(SIMD2(dab.x - last.x, dab.y - last.y))
                    let count = max(1, Int(ceil(distance / 2)))
                    for i in 1...count { dabs.append(last + (dab - last) * (Float(i) / Float(count))) }
                } else { dabs.append(dab) }
            }
            guard !dabs.isEmpty else { continue }
            let hints: [SIMD4<Float>], photo: Int
            if let cached = repairSelections.first(where: { $0.settings == plain && $0.depth == usesDepth && $0.strokes == group }) {
                hints = cached.hints; photo = cached.photo
            } else {
                hints = try renderer.hints(base, dabs: dabs)
                let offset = reduced.layout.priorOffset
                // Source proxies are already aligned and exposure matched by analysis. Only scalar stroke scores leave Metal.
                let gridDabs = dabs.map { SIMD4($0.x + Float(offset.x), $0.y + Float(offset.y), $0.z, 0) }
                var best: Float = 0.003, chosen = -1
                for step in reduced.steps {
                    let score = try renderer.score(proxy: prepared.proxies[step.index], width: analysisWidth, height: analysisHeight,
                                                   dabs: gridDabs, hints: hints)
                    if score > best { best = score; chosen = step.index }
                }
                photo = chosen
                repairSelections.append((plain, usesDepth, group, photo, hints))
                if repairSelections.count > 64 { repairSelections.removeFirst() }
            }
            guard let step = steps.first(where: { $0.index == photo }) else { continue }
            let source: MTLBuffer
            if !fullSize, let cache = repairAlignedCache, cache.settings == plain, cache.photo == photo { source = cache.buffer }
            else {
                let image: CIImage
                if fullSize { image = try HDRMergeDecoder.developedImage(urls[photo], metadata: metadata[photo], longEdge: nil, whiteBalance: whiteBalance, retouch: retouch[urls[photo]] ?? []) }
                else {
                    let frame = sources[photo]
                    image = CIImage(bitmapData: frame.pixels.withUnsafeBytes { Data($0) }, bytesPerRow: frame.width * 16,
                                    size: CGSize(width: frame.width, height: frame.height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
                }
                source = try gpu.aligned(image, layout: layout, step: step, context: context)
                if !fullSize { repairAlignedCache = (plain, photo, source) }
            }
            let scale = Float(1 / layout.priorScale)
            let offset = reduced.layout.priorOffset * Double(scale) - layout.priorOffset
            let outputDabs = dabs.map { SIMD4($0.x * scale + Float(offset.x), $0.y * scale + Float(offset.y), $0.z * scale, 0) }
            result = try renderer.apply(result, source: source, dabs: outputDabs, hints: hints, scale: scale)
        }
        return result
    }
}
