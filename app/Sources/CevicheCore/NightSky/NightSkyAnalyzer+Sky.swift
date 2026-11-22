import Foundation
import CoreGraphics
import CoreImage
import Metal
import simd

/// Finding the sky, and the warps that align each frame to it.
extension NightSkyAnalyzer {
    /// The typical distance from a star to its nearest neighbor.
    static func spacing(_ points: [SIMD2<Double>]) -> Double {
        var grid: [Int: [SIMD2<Double>]] = [:]
        for p in points { grid[Int(p.y / 32) * 10_000 + Int(p.x / 32), default: []].append(p) }
        let nearest = points.prefix(2000).map { p -> Double in
            var best = 96.0
            for dy in -3...3 { for dx in -3...3 { for q in grid[(Int(p.y / 32) + dy) * 10_000 + Int(p.x / 32) + dx] ?? [] where q != p { best = min(best, simd_distance(p, q)) } } }
            return best
        }
        return max(8, min(96, NightSkyStars.median(nearest)))
    }

    /// A quarter-size map of where `points` reach: 1 within 1.5 star spacings of one, softened, as a Core Image map.
    static func reach(of points: [SIMD2<Double>], width: Int, height: Int) -> CIImage {
        let gw = max(1, width / 4), gh = max(1, height / 4), radius = 1.5 * spacing(points) / 4
        var map = [Float](repeating: 0, count: gw * gh)
        let r = Int(radius.rounded(.up))
        for p in points {
            let cx = p.x / 4, cy = p.y / 4
            for y in max(0, Int(cy) - r)...min(gh - 1, max(0, Int(cy) + r)) { for x in max(0, Int(cx) - r)...min(gw - 1, max(0, Int(cx) + r)) {
                if hypot(Double(x) - cx, Double(y) - cy) <= radius { map[y * gw + x] = 1 }
            }}
        }
        map = HDRMerger.boxBlur(map, width: gw, height: gh, radius: max(1, r / 2))
        return CIImage(bitmapData: map.withUnsafeBytes { Data($0) }, bytesPerRow: gw * 4, size: CGSize(width: gw, height: gh), format: .Rf, colorSpace: nil)
    }

    /// Each list without the sources that have a counterpart within a pixel in the other.
    static func withoutStill(_ a: [NightSkyStar], _ b: [NightSkyStar]) -> ([NightSkyStar], [NightSkyStar]) {
        func grid(_ stars: [NightSkyStar]) -> [Int: [SIMD2<Double>]] {
            var grid: [Int: [SIMD2<Double>]] = [:]
            for star in stars { grid[Int(star.point.y / 8) * 10_000 + Int(star.point.x / 8), default: []].append(star.point) }
            return grid
        }
        func moving(_ stars: [NightSkyStar], against grid: [Int: [SIMD2<Double>]]) -> [NightSkyStar] {
            stars.filter { star in
                let gx = Int(star.point.x / 8), gy = Int(star.point.y / 8)
                for dy in -1...1 { for dx in -1...1 { for p in grid[(gy + dy) * 10_000 + gx + dx] ?? [] where simd_distance(p, star.point) < 1 { return false } } }
                return true
            }
        }
        return (moving(a, against: grid(b)), moving(b, against: grid(a)))
    }

    /// The anchor's sky probability. The base is the editor's sky mask: the sky network on a copy brightened so the
    /// night sky sits near mid-gray, refined against the photo by the guided filter. It finds landscape silhouettes well
    /// but was trained mostly on daylight, so what moves with the stars overrides it: the anchor's point sources are compared with those of `others`, a photo taken a while
    /// apart whose sky `motion` maps onto the anchor's, and every 64-pixel cell is scored by how many sources moved,
    /// against the starriest cells. A cell dense with moving stars is sky whatever the network says; a cell with more
    /// still lights than moving stars is ground. Near the celestial pole stars barely move, and there the network decides.
    func skyMask(_ image: CIImage, luminance: [Float], sources: [NightSkyStar], others: [NightSkyStar], motion: NightSkyAlignment?) throws -> [Float] {
        let aw = analysisWidth, ah = analysisHeight, cell = 64
        let cw = (aw + cell - 1) / cell, ch = (ah + cell - 1) / cell
        var moving = [Float](repeating: 0, count: cw * ch), still = [Float](repeating: 0, count: cw * ch)
        var movers: [SIMD2<Double>] = []
        func moved(_ p: SIMD2<Double>) -> Double { motion.map { simd_distance($0.sourcePoint(p), p) } ?? 0 }
        var grid: [Int: [SIMD2<Double>]] = [:]
        for star in others { grid[Int(star.point.y / 8) * 10_000 + Int(star.point.x / 8), default: []].append(star.point) }
        for star in sources {
            var fixed = false
            let gx = Int(star.point.x / 8), gy = Int(star.point.y / 8)
            // Where the sky barely moved (near the pole, or over a short sequence) a source can't be told either way.
            guard moved(star.point) > 3 else { continue }
            for dy in -1...1 { for dx in -1...1 { for p in grid[(gy + dy) * 10_000 + gx + dx] ?? [] where simd_distance(p, star.point) < 1 { fixed = true } } }
            let k = min(ch - 1, Int(star.point.y) / cell) * cw + min(cw - 1, Int(star.point.x) / cell)
            if fixed { still[k] += 1 } else { moving[k] += 1; movers.append(star.point) }
        }
        let density = HDRMerger.boxBlur(moving, width: cw, height: ch, radius: 1)
        let reference = max(1, density.sorted()[density.count * 19 / 20])
        let starry = density.map { Self.smoothstep(0.3, 0.6, $0 / reference) }
        let lit = (0..<(cw * ch)).map { Float(still[$0] >= max(2, moving[$0]) ? 1 : 0) }
        func upsample(_ cells: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: aw * ah)
            cells.withUnsafeBufferPointer { cells in
                out.withUnsafeMutableBufferPointer { out in
                    let out = out
                    DispatchQueue.concurrentPerform(iterations: ah) { y in
                        for x in 0..<aw {
                            let p = SIMD2((Double(x) + 0.5) / Double(cell) - 0.5, (Double(y) + 0.5) / Double(cell) - 0.5)
                            out[y * aw + x] = Self.bilinear(cells, cw, ch, simd_clamp(p, .zero, SIMD2(Double(cw - 1), Double(ch - 1))), channels: 1)?.x ?? 0
                        }
                    }
                }
            }
            return out
        }

        var coarse: [Float]
        let samples = stride(from: 0, to: luminance.count, by: 31).map { Double(max(0, luminance[$0])) }
        let brightened = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: max(-2, min(6, log2(0.12 / max(1e-6, NightSkyStars.median(samples)))))])
        /// A small map refined against the photo by the editor's guided filter, as probabilities at analysis size.
        func refine(_ small: CIImage, radius: Double? = nil) -> [Float] {
            // The refinement hands back the encoded values masks are stored with; undo that to keep probabilities.
            let refinement = radius.map { MaskRefinement.guided(radius: $0 / Double(max(aw, ah)), epsilon: 0.01) } ?? .sky
            let refined = refinement.apply(small, guide: brightened).applyingFilter("CISRGBToneCurveToLinear")
            var rgba = [Float](repeating: 0, count: aw * ah * 4)
            rgba.withUnsafeMutableBytes {
                context.render(refined, toBitmap: $0.baseAddress!, rowBytes: aw * 16, bounds: CGRect(x: 0, y: 0, width: aw, height: ah), format: .RGBAf, colorSpace: nil)
            }
            return (0..<(aw * ah)).map { max(0, min(1, rgba[4 * $0].isFinite ? rgba[4 * $0] : 0)) }
        }
        if Self.usesSkyModel, let model = try? SkyMaskModel.loadBundled() {
            coarse = refine(try model.coarseMask(for: brightened, context: context))
        } else {
            // Without the network the moving stars alone draw the sky: a disc about one star spacing wide around each, then
            // the guided filter, with a window as wide, finds the edge in the photo.
            skyModelInstalled = !Self.usesSkyModel
            coarse = refine(Self.reach(of: movers, width: aw, height: ah), radius: Self.spacing(movers))
        }
        let starryUp = upsample(starry), litUp = upsample(lit)
        // Stars override the network unless it is certain of ground, where moving sources are more likely foliage in wind.
        let network = coarse, blurred = try skyModelInstalled ? boxBlur(network, width: aw, height: ah, radius: cell / 2) : network
        for i in coarse.indices { coarse[i] = max(network[i], starryUp[i] * Self.smoothstep(0.01, 0.05, blurred[i])) * (1 - litUp[i]) }
        return try Self.snappedToSkyline(coarse, luminance: luminance, starry: starryUp, width: aw, height: ah,
                                         boxBlur: { try boxBlur($0, width: aw, height: ah, radius: $1) }, minFilter: { try minFilter($0, width: aw, height: ah, radius: $1) })
    }

    /// The sky probability with its edge found in the photo. The network sees a 320-pixel copy and the star evidence
    /// comes in 64-pixel cells, so their boundary can lie tens of pixels inside a ridge, where averaging the aligned sky
    /// draws the rock's ghost. At night the skyline is a strong step in brightness: in a band along the boundary, each
    /// cell's window, on a copy with the stars taken out, is split into a darker and a brighter group, and where the two
    /// are far apart and the probability already leans differently in them, the threshold between them decides, the sky
    /// on the side the probability favors. Cells that see one side only take their neighbors' threshold. The threshold
    /// may always take sky away; it adds sky only where nothing dark is near and the sure sky is reached through more of
    /// the same, so lit rock inside the silhouette and a tree's crown stay ground. Beyond the band, what the network
    /// called ground or wasn't sure of becomes sky the same way when it is clearly on the sky's side of the threshold, or,
    /// where moving stars say sky, plainly brighter than the ground: star fields the daylight-trained network calls
    /// ground. Last, bare branches and wires reaching up from the ground, too fine for any of this, are found as lines
    /// darker than the sky around them and made ground, so they stay sharp instead of washing out in the averaged sky.
    /// `boxBlur` and `minFilter` take values at this size and a radius.
    static func snappedToSkyline(_ prior: [Float], luminance: [Float], starry: [Float], width w: Int, height h: Int,
                                 boxBlur: ([Float], Int) throws -> [Float], minFilter: ([Float], Int) throws -> [Float]) rethrows -> [Float] {
        let reach = max(16, w / 50), cell = reach / 2
        let samples = stride(from: 0, to: luminance.count, by: 37).map { Double(max(0, luminance[$0])) }
        let level = Float(max(1e-6, NightSkyStars.median(samples)))
        // Encoded like the photo is seen, the median near 0.39, with a toe so the noise in black ground isn't stretched;
        // a minimum then maximum over 5 pixels removes the stars.
        let encoded = luminance.map { pow((max(0, min(1, $0 / (8 * level))) + 0.01) / 1.01, 1 / 2.2) }
        let opened = try minFilter(minFilter(encoded, 2).map { 1 - $0 }, 2).map { 1 - $0 }
        let guide = try boxBlur(opened, 2)
        // The darkest a pixel's surroundings get, stars and all. In open sky that dips below the star-free brightness by
        // the noise alone, as far as measured in the surest sky; deeper, something dark is near: bare branches and wires,
        // too fine and faint for the threshold to see, which sky is never added over.
        let smooth = try boxBlur(encoded, 1), floor = try minFilter(smooth, 3)
        let near = try boxBlur(prior.map { $0 > 0.5 ? 1 : 0 }, reach)
        var dips: [Float] = []
        for i in stride(from: 0, to: w * h, by: 7) where prior[i] > 0.99 && near[i] > 0.999 { dips.append(guide[i] - floor[i]) }
        dips.sort()
        let noiseDip = dips.isEmpty ? Float.infinity : dips[dips.count / 2] + 1.25 * (dips[dips.count * 98 / 100] - dips[dips.count / 2])
        @inline(__always) func clear(_ i: Int) -> Bool { guide[i] - floor[i] <= noiseDip }
        @inline(__always) func inBand(_ i: Int) -> Bool { near[i] > 0.002 && near[i] < 0.998 }

        /// A cell's split: the threshold, how sharply to step across it, +1 where the sky is the brighter side, the
        /// brightness between the groups, and how many cells away the split was found.
        struct Split { var threshold: Float, spread: Float, polarity: Float, contrast: Float, distance = 0 }
        let cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
        var splits = [Split?](repeating: nil, count: cw * ch)
        splits.withUnsafeMutableBufferPointer { splits in
            let splits = splits
            DispatchQueue.concurrentPerform(iterations: cw * ch) { k in
                let cx = (k % cw) * cell + cell / 2, cy = (k / cw) * cell + cell / 2
                guard inBand(min(h - 1, cy) * w + min(w - 1, cx)) else { return }
                var values: [Float] = [], priors: [Float] = []
                values.reserveCapacity(4 * reach * reach); priors.reserveCapacity(4 * reach * reach)
                for y in max(0, cy - reach)..<min(h, cy + reach) {
                    for x in max(0, cx - reach)..<min(w, cx + reach) { values.append(guide[y * w + x]); priors.append(prior[y * w + x]) }
                }
                let sorted = values.sorted()
                var dark = sorted[sorted.count / 10], bright = sorted[sorted.count * 9 / 10], t = (dark + bright) / 2
                for _ in 0..<12 {
                    var s0: Float = 0, n0: Float = 0, s1: Float = 0, n1: Float = 0
                    for v in values { if v < t { s0 += v; n0 += 1 } else { s1 += v; n1 += 1 } }
                    guard n0 > 0, n1 > 0 else { return }
                    dark = s0 / n0; bright = s1 / n1; t = (dark + bright) / 2
                }
                var v0: Float = 0, v1: Float = 0, n0: Float = 0, n1: Float = 0, p0: Float = 0, p1: Float = 0
                for (v, p) in zip(values, priors) {
                    if v < t { v0 += (v - dark) * (v - dark); n0 += 1; p0 += p } else { v1 += (v - bright) * (v - bright); n1 += 1; p1 += p }
                }
                let n = n0 + n1, deviation = max((v0 / max(1, n0)).squareRoot(), (v1 / max(1, n1)).squareRoot())
                // Both groups real, far apart against their own spread and in ratio (not a band of airglow), and already
                // told apart by the probability.
                guard n0 > 0.08 * n, n1 > 0.08 * n, bright - dark > 3 * deviation, dark < 0.6 * bright, abs(p1 / n1 - p0 / n0) > 0.2 else { return }
                splits[k] = Split(threshold: t, spread: max(deviation, (bright - dark) / 8), polarity: p1 / n1 > p0 / n0 ? 1 : -1, contrast: bright - dark)
            }
        }
        guard splits.contains(where: { $0 != nil }) else { return prior }
        // Every cell takes the split of found cells around it, spreading outward until all have one.
        for step in 1...(cw + ch) {
            var next = splits, missing = false
            for k in 0..<(cw * ch) where splits[k] == nil {
                let cx = k % cw, cy = k / cw
                var sum = Split(threshold: 0, spread: 0, polarity: 0, contrast: 0, distance: step), n: Float = 0
                for y in max(0, cy - 1)...min(ch - 1, cy + 1) {
                    for x in max(0, cx - 1)...min(cw - 1, cx + 1) {
                        guard let s = splits[y * cw + x] else { continue }
                        sum.threshold += s.threshold; sum.spread += s.spread; sum.polarity += s.polarity; sum.contrast += s.contrast; n += 1
                    }
                }
                guard n > 0, sum.polarity != 0 else { missing = true; continue }
                next[k] = Split(threshold: sum.threshold / n, spread: sum.spread / n, polarity: sum.polarity > 0 ? 1 : -1, contrast: sum.contrast / n, distance: step)
            }
            splits = next
            if !missing { break }
        }

        /// How sky-like a brightness `g` at the pixel is by the splits of the four nearest cells found within `within`
        /// cells, whether the sky is the brighter side there, and how far `g` lies from the ground's brightness toward the
        /// sky's (0 at the ground, 1 at the sky).
        func classified(_ x: Int, _ y: Int, _ g: Float, within: Int) -> (sky: Float, brighter: Bool, lift: Float)? {
            let fx = (Float(x) + 0.5) / Float(cell) - 0.5, fy = (Float(y) + 0.5) / Float(cell) - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            var sky: Float = 0, weight: Float = 0, sign: Float = 0, lift: Float = 0
            for cy in y0...(y0 + 1) {
                for cx in x0...(x0 + 1) {
                    let a = (1 - abs(fx - Float(cx))) * (1 - abs(fy - Float(cy)))
                    guard a > 0, let s = splits[max(0, min(ch - 1, cy)) * cw + max(0, min(cw - 1, cx))], s.distance <= within else { continue }
                    let above = s.polarity * (g - s.threshold)
                    sky += a * max(0, min(1, 0.5 + 0.5 * above / s.spread)); lift += a * (0.5 + above / s.contrast)
                    sign += a * s.polarity; weight += a
                }
            }
            return weight > 0 ? (sky / weight, sign > 0, lift / weight) : nil
        }
        // Brightness may always take sky away: averaging less is safe. It adds sky only where nothing dark is near and
        // the sure sky is reached through more of the same, so lit rock inside the silhouette and a tree's crown stay
        // ground; `target` is what such a pixel becomes when reached, 0 for none.
        var out = prior, target = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { out in
            target.withUnsafeMutableBufferPointer { target in
                let out = out, target = target
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        if inBand(i), let c = classified(x, y, guide[i], within: 4) {
                            if c.sky <= prior[i] { out[i] = c.sky; continue }
                            if c.brighter, clear(i) { target[i] = c.sky }
                        } else if prior[i] < 0.9, let c = classified(x, y, guide[i], within: .max), c.brighter,
                                  c.sky > 0.6 || (starry[i] > 0.5 && c.lift > 0.25) {
                            target[i] = 1
                        }
                    }
                }
            }
        }
        // Flooded from the sure sky through the candidates.
        var queue: [Int] = []
        func arrive(_ i: Int) { out[i] = max(out[i], target[i]); target[i] = 0; queue.append(i) }
        for i in out.indices where target[i] > 0 {
            let x = i % w, y = i / w
            if (x > 0 && out[i - 1] >= 0.9) || (x + 1 < w && out[i + 1] >= 0.9) || (y > 0 && out[i - w] >= 0.9) || (y + 1 < h && out[i + w] >= 0.9) { arrive(i) }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1] where j >= 0 && target[j] > 0 { arrive(j) }
        }

        // Bare branches and wires reaching up from the ground are too fine for any of the above, so the averaged sky
        // would wash them out. Filling in dark lines up to 7 pixels wide gives the sky around them; what lies darker than
        // that by more than the noise does in the surest sky, and reaches the ground through more of the same, is ground.
        let filled = try minFilter(minFilter(opened.map { 1 - $0 }, 3).map { 1 - $0 }, 3)
        let darker = (0..<(w * h)).map { filled[$0] - smooth[$0] }
        var depths: [Float] = []
        for i in stride(from: 0, to: w * h, by: 7) where prior[i] > 0.99 && near[i] > 0.999 { depths.append(darker[i]) }
        depths.sort()
        guard !depths.isEmpty else { return out }
        // How far the open sky's own noise reaches above its usual depth.
        let usual = depths[depths.count / 2], noiseDepth = usual + 1.25 * (depths[depths.count * 995 / 1000] - usual)
        var branch = [Bool](repeating: false, count: w * h)
        // A branch starts within 4 pixels of the ground: right above it the filled-in sky takes the ground's darkness.
        let groundNear = try minFilter(out.map { $0 >= 0.5 ? 1 : 0 }, 4)
        // The frame's outer pixels are left alone: the filters' clamped edges darken them.
        @inline(__always) func darkLine(_ i: Int) -> Bool {
            let x = i % w, y = i / w
            return x >= 2 && y >= 2 && x < w - 2 && y < h - 2 && out[i] >= 0.5 && darker[i] > noiseDepth
        }
        queue = []
        for i in out.indices where groundNear[i] < 1 && darkLine(i) { branch[i] = true; queue.append(i) }
        head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for j in [x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1]
            where j >= 0 && !branch[j] && darkLine(j) {
                branch[j] = true; queue.append(j)
            }
        }
        guard !queue.isEmpty else { return out }
        // A pixel's margin goes with it: the sky right beside a branch carries its edge.
        let kept = try minFilter(branch.map { $0 ? 0 : 1 }, 1)
        for i in out.indices where kept[i] < 1 { out[i] = 0 }
        return out
    }

    @inline(__always) static func sample(_ values: [Float], _ width: Int, _ height: Int, _ p: SIMD2<Double>) -> Float {
        values.withUnsafeBufferPointer { sample($0, width, height, p) }
    }

    @inline(__always) static func sample(_ values: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ p: SIMD2<Double>) -> Float {
        let x = Int(p.x.rounded()), y = Int(p.y.rounded())
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return values[y * width + x]
    }

    /// Whether a sample at `p` (analysis pixels, camera coordinates) is sky.
    @inline(__always) func isSky(_ p: SIMD2<Double>) -> Bool { Self.sample(skyValid, analysisWidth, analysisHeight, p) > 0.8 }

    /// A plane on the anchor's sky, NaN where the photo has no sky sample.
    func warpPlane(_ plane: [Float], _ alignment: NightSkyAlignment) -> [Float] {
        let w = analysisWidth, h = analysisHeight, map = NightSkyAlignment.SourceMap(alignment)
        var out = [Float](repeating: .nan, count: w * h)
        out.withUnsafeMutableBufferPointer { out in
            plane.withUnsafeBufferPointer { plane in
                skyProbability.withUnsafeBufferPointer { probability in
                    skyValid.withUnsafeBufferPointer { valid in
                        let out = out
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w where probability[y * w + x] > 0.2 {
                                let p = map(SIMD2(Double(x), Double(y)))
                                guard Self.sample(valid, w, h, p) > 0.8, let v = Self.bilinear(plane, w, h, p, channels: 1) else { continue }
                                out[y * w + x] = v.x
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// A preview copy on the anchor's sky, NaN where the photo has no sky sample.
    func warpPreview(_ rgb: [Float], _ alignment: NightSkyAlignment, mask: [Float], valid: [Float]) -> [Float] {
        let w = previewWidth, h = previewHeight, k = previewScale, aw = analysisWidth, ah = analysisHeight
        let map = NightSkyAlignment.SourceMap(alignment)
        var out = [Float](repeating: .nan, count: w * h * 3)
        out.withUnsafeMutableBufferPointer { out in
            rgb.withUnsafeBufferPointer { rgb in
                mask.withUnsafeBufferPointer { probability in
                    valid.withUnsafeBufferPointer { valid in
                        let out = out
                        DispatchQueue.concurrentPerform(iterations: h) { y in
                            for x in 0..<w where probability[y * w + x] > 0.01 {
                                let a = map(SIMD2((Double(x) + 0.5) * k - 0.5, (Double(y) + 0.5) * k - 0.5))
                                guard Self.sample(valid, aw, ah, a) > 0.8, let v = Self.bilinear(rgb, w, h, (a + 0.5) / k - 0.5, channels: 3) else { continue }
                                let o = (y * w + x) * 3
                                out[o] = v.x; out[o + 1] = v.y; out[o + 2] = v.z
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Bilinear sample of the first (up to three) of `channels` interleaved channels at `p` (pixel centers at integers);
    /// nil outside or where a corner is NaN.
    @inline(__always) static func bilinear(_ values: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ p: SIMD2<Double>, channels: Int) -> SIMD3<Float>? {
        guard p.x >= 0, p.y >= 0, p.x <= Double(width - 1), p.y <= Double(height - 1) else { return nil }
        let x0 = min(width - 2, Int(p.x)), y0 = min(height - 2, Int(p.y))
        let fx = Float(p.x - Double(x0)), fy = Float(p.y - Double(y0))
        var result = SIMD3<Float>.zero
        for c in 0..<min(3, channels) {
            let a = values[(y0 * width + x0) * channels + c], b = values[(y0 * width + x0 + 1) * channels + c]
            let d = values[((y0 + 1) * width + x0) * channels + c], e = values[((y0 + 1) * width + x0 + 1) * channels + c]
            let v = (a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy
            guard v.isFinite else { return nil }
            result[c] = v
        }
        return result
    }
}
