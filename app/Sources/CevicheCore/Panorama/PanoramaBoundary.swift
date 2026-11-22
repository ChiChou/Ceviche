import Foundation
import CoreML

/// Which pixels of a panorama the photos cover, on a coarse grid of square cells laid along its long side.
struct PanoramaCoverageGrid {
    /// Pixels a cell is across; cells at the far ends may be cut short.
    let step: Int
    /// Cells along the long side (`u`) and across it (`v`).
    let along: Int, across: Int
    let longSide: Int, shortSide: Int
    /// The long side runs down the picture.
    let transposed: Bool
    /// `covered[u * across + v]`: every pixel of the cell is covered.
    var covered: [Bool]

    static let longEdge = 1024, threshold: Float = 0.99

    init(_ image: PanoramaRaster) {
        let w = image.width, h = image.height
        transposed = h > w
        longSide = max(w, h); shortSide = min(w, h)
        step = max(1, Int((Double(longSide) / Double(Self.longEdge)).rounded(.up)))
        along = (longSide + step - 1) / step; across = (shortSide + step - 1) / step
        var covered = [Bool](repeating: false, count: along * across)
        let (step, along, across, longSide, shortSide, transposed) = (step, along, across, longSide, shortSide, transposed)
        covered.withUnsafeMutableBufferPointer { out in
            let out = out
            image.rgba.withUnsafeBufferPointer { rgba in
                DispatchQueue.concurrentPerform(iterations: along) { u in
                    for v in 0..<across {
                        var all = true
                        scan: for a in u * step..<min(longSide, (u + 1) * step) {
                            for b in v * step..<min(shortSide, (v + 1) * step) {
                                let (x, y) = transposed ? (b, a) : (a, b)
                                if rgba[(y * w + x) * 4 + 3] < Self.threshold { all = false; break scan }
                            }
                        }
                        out[u * across + v] = all
                    }
                }
            }
        }
        self.covered = covered
    }
    subscript(u: Int, v: Int) -> Bool { covered[u * across + v] }
}

/// Boundary Warp: bends the panorama so its ragged edge reaches the frame. Each position along the long side is
/// stretched across it to the photos' extent there, then each line across the result is stretched along it; both
/// extents are smoothed, so straight lines bend gently rather than following every frame's corner. `amount` between 0
/// and 1 moves the extents part of the way from the frame, leaving the rest for Auto Crop or Fill Edges.
enum PanoramaWarp {
    static func warp(_ image: PanoramaRaster, amount: Double) -> PanoramaRaster {
        let amount = min(1, max(0, amount))
        guard amount > 0 else { return image }
        let grid = PanoramaCoverageGrid(image)
        let step = grid.step, along = grid.along, across = grid.across, longSide = grid.longSide, shortSide = grid.shortSide
        // Smoothed over a quarter of the short side.
        let smoothing = Double(across) / 4
        // Across: the extent across the long side at each cell along it.
        // Ends that cover less than 80 % of the height are left to the second pass: a frame tilted at the end cuts its
        // corners diagonally, and stretching those few columns across would bend the horizon; along, it's a small stretch.
        guard let first = extents(count: along, length: across, step: step, total: shortSide, smoothing: smoothing, full: 0.8,
                                  covered: { grid[$0, $1] }) else { return image }
        let lo1 = first.lo.map { $0 * amount }, hi1 = first.hi.map { $0 * amount + Double(shortSide) * (1 - amount) }
        // Along: the extent along the long side on each line across, once the first pass is applied.
        var warped = [Bool](repeating: false, count: along * across)
        for u in 0..<along {
            let lo = lo1[u], hi = hi1[u]
            for v in 0..<across {
                let source = lo + (Double(v) + 0.5) * Double(step) / Double(shortSide) * (hi - lo)
                warped[u * across + v] = grid[u, min(across - 1, max(0, Int(source) / step))]
            }
        }
        let second = extents(count: across, length: along, step: step, total: longSide, smoothing: smoothing, full: 0.5, outer: true,
                             covered: { warped[$1 * across + $0] })
        let lo2 = second.map { $0.lo.map { $0 * amount } } ?? [Double](repeating: 0, count: across)
        let hi2 = second.map { $0.hi.map { $0 * amount + Double(longSide) * (1 - amount) } } ?? [Double](repeating: Double(longSide), count: across)

        let w = image.width, h = image.height, transposed = grid.transposed
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            image.rgba.withUnsafeBufferPointer { rgba in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let (u, v) = transposed ? (Double(y) + 0.5, Double(x) + 0.5) : (Double(x) + 0.5, Double(y) + 0.5)
                        let left = sample(lo2, at: v, step: step), right = sample(hi2, at: v, step: step)
                        let su = left + u / Double(longSide) * (right - left)
                        let top = sample(lo1, at: su, step: step), bottom = sample(hi1, at: su, step: step)
                        let sv = top + v / Double(shortSide) * (bottom - top)
                        let (sx, sy) = transposed ? (sv, su) : (su, sv)
                        bilinear(rgba, width: w, height: h, x: sx - 0.5, y: sy - 0.5, into: out, at: (y * w + x) * 4)
                    }
                }
            }
        }
        return PanoramaRaster(width: w, height: h, rgba: out)
    }

    /// For each of `count` lines of `length` cells, the longest covered run, in pixels of the `total` the cells span,
    /// smoothed. The lines at either end whose run is under `full` of the longest (90th percentile) are the ragged ends:
    /// they take the extent of the first full line. `outer` takes the first to the last covered cell instead of the
    /// longest run: after a partial first pass the lines near the top and bottom still cross the frames' dips, and
    /// their longest piece would jump from line to line.
    static func extents(count: Int, length: Int, step: Int, total: Int, smoothing: Double, full fraction: Double, outer: Bool = false,
                        covered: (Int, Int) -> Bool) -> (lo: [Double], hi: [Double])? {
        var lo = [Double](repeating: 0, count: count), hi = lo, runs = [Int](repeating: 0, count: count)
        for i in 0..<count {
            var best = (start: 0, length: 0), start = -1
            for j in 0...length {
                if j < length && covered(i, j) { if start < 0 { start = j } }
                else if start >= 0 { if j - start > best.length { best = (start, j - start) }; start = -1 }
            }
            if outer, let first = (0..<length).first(where: { covered(i, $0) }), let last = (0..<length).last(where: { covered(i, $0) }) {
                best = (first, last - first + 1)
            }
            runs[i] = best.length
            // Linear between cell centres, so the extent is moved a cell in from each end of the run.
            lo[i] = Double(min(total, (best.start + 1) * step))
            hi[i] = Double(min(total, (best.start + best.length - 1) * step))
        }
        let longest = runs.sorted()[min(count - 1, count * 9 / 10)]
        guard longest > 2 else { return nil }
        let enough = max(3, Int((Double(longest) * fraction).rounded(.up)))
        guard let first = runs.firstIndex(where: { $0 >= enough }), let last = runs.lastIndex(where: { $0 >= enough }) else { return nil }
        for i in 0..<first { lo[i] = lo[first]; hi[i] = hi[first] }
        for i in last + 1..<count { lo[i] = lo[last]; hi[i] = hi[last] }
        return (smoothed(lo, inside: { max($0, $1) }, sigma: smoothing), smoothed(hi, inside: { min($0, $1) }, sigma: smoothing))
    }

    /// `raw` blurred, then lifted back inside it near the points the blur moved outside: the shortfall is spread by a
    /// maximum over twice the blur radius and blurred again, so the curve passes smoothly over each frame's corner.
    /// `inside` picks the inner of two values.
    static func smoothed(_ raw: [Double], inside: (Double, Double) -> Double, sigma: Double) -> [Double] {
        guard raw.count > 2, sigma >= 0.5 else { return raw }
        let sign = inside(0, 1) == 1 ? 1.0 : -1.0
        let blurred = blur(raw, sigma: sigma)
        let shortfall = zip(raw, blurred).map { max(0, sign * ($0 - $1)) }
        let reach = Int(2 * sigma)
        var spread = shortfall
        for i in raw.indices { for j in max(0, i - reach)...min(raw.count - 1, i + reach) { spread[i] = max(spread[i], shortfall[j]) } }
        let lift = blur(spread, sigma: sigma)
        return raw.indices.map { inside(raw[$0], blurred[$0] + sign * lift[$0]) }
    }

    /// Three box blurs, about a Gaussian of `sigma`, edges held.
    static func blur(_ values: [Double], sigma: Double) -> [Double] {
        let radius = max(1, Int((sqrt(4 * sigma * sigma + 1) - 1) / 2 + 0.5)), n = values.count
        var current = values
        for _ in 0..<3 {
            var prefix = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { prefix[i + 1] = prefix[i] + current[i] }
            current = (0..<n).map { i in
                var total = prefix[min(n, i + radius + 1)] - prefix[max(0, i - radius)]
                // Held edges: the missing neighbours repeat the end value.
                if i - radius < 0 { total += Double(radius - i) * current[0] }
                if i + radius >= n { total += Double(i + radius - n + 1) * current[n - 1] }
                return total / Double(2 * radius + 1)
            }
        }
        return current
    }

    /// A per-cell value at `position` pixels, linear between cell centres.
    @inline(__always) static func sample(_ values: [Double], at position: Double, step: Int) -> Double {
        let t = position / Double(step) - 0.5
        guard t > 0 else { return values[0] }
        let i = Int(t)
        guard i + 1 < values.count else { return values[values.count - 1] }
        let f = t - Double(i)
        return values[i] * (1 - f) + values[i + 1] * f
    }

    /// Bilinear, weighted by coverage so uncovered neighbours don't darken the edge; colour is straight, not premultiplied.
    @inline(__always) static func bilinear(_ rgba: UnsafeBufferPointer<Float>, width: Int, height: Int, x: Double, y: Double,
                                           into out: UnsafeMutableBufferPointer<Float>, at p: Int) {
        let x = min(Double(width - 1), max(0, x)), y = min(Double(height - 1), max(0, y))
        let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
        @inline(__always) func add(_ q: Int, _ w: Float) {
            let weight = w * rgba[q + 3]
            r += rgba[q] * weight; g += rgba[q + 1] * weight; b += rgba[q + 2] * weight; a += weight
        }
        add((y0 * width + x0) * 4, (1 - fx) * (1 - fy)); add((y0 * width + x1) * 4, fx * (1 - fy))
        add((y1 * width + x0) * 4, (1 - fx) * fy); add((y1 * width + x1) * 4, fx * fy)
        guard a > 1e-6 else { return }
        out[p] = r / a; out[p + 1] = g / a; out[p + 2] = b / a; out[p + 3] = min(1, a)
    }
}

/// Fill Edges: paints what no photo covers with the Remove brush's AI fill model (Big-LaMa). The panorama is reduced
/// until the deepest uncovered area is at most `maxDepth` network pixels from the photos, filled in overlapping
/// windows (each window sees the cells filled before it), and the fill brought back up to size under the photos.
/// Panoramas of any size are filled from the same reduced picture, so the preview shows what the merge gets.
enum PanoramaEdgeFill {
    static let maxDepth = 128.0
    static var isAvailable: Bool { BundledModel.inpaint.isAvailable }

    static func fill(_ image: PanoramaRaster, progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> PanoramaRaster {
        guard isAvailable else {
            throw PanoramaError.message(L10n.tr("The \(BundledModel.inpaint.feature) model is not installed. Install it in Settings › Models."))
        }
        let w = image.width, h = image.height
        let grid = PanoramaCoverageGrid(image)
        guard grid.covered.contains(false) else { return image }
        guard let depthCells = depth(grid) else { return image }
        let scale = min(1, maxDepth / max(1, Double(depthCells + 1) * Double(grid.step)))
        let sw = max(1, Int((Double(w) * scale).rounded(.up))), sh = max(1, Int((Double(h) * scale).rounded(.up)))
        let plane = sw * sh

        // Reduced: colour weighted by coverage; a pixel is a hole unless all it covers is covered.
        var small = [Float](repeating: 0, count: plane * 3), hole = [Float](repeating: 0, count: plane)
        small.withUnsafeMutableBufferPointer { smallOut in
            hole.withUnsafeMutableBufferPointer { holeOut in
                let smallOut = smallOut, holeOut = holeOut
                image.rgba.withUnsafeBufferPointer { rgba in
                    DispatchQueue.concurrentPerform(iterations: sh) { Y in
                        let y0 = min(h - 1, Int(Double(Y) / scale)), y1 = max(y0 + 1, min(h, Int(Double(Y + 1) / scale)))
                        for X in 0..<sw {
                            let x0 = min(w - 1, Int(Double(X) / scale)), x1 = max(x0 + 1, min(w, Int(Double(X + 1) / scale)))
                            var sum = SIMD3<Float>(repeating: 0), weight: Float = 0, least: Float = 1
                            for y in y0..<y1 { for x in x0..<x1 {
                                let p = (y * w + x) * 4, a = min(1, max(0, rgba[p + 3]))
                                sum += SIMD3(rgba[p], rgba[p + 1], rgba[p + 2]) * a; weight += a; least = min(least, a)
                            } }
                            let i = Y * sw + X
                            if weight > 1e-6 { for c in 0..<3 { smallOut[c * plane + i] = sum[c] / weight } }
                            holeOut[i] = least < PanoramaCoverageGrid.threshold ? 1 : 0
                        }
                    }
                }
            }
        }
        // Grown two pixels, so the soft edge where photos end is painted over too.
        var grown = hole
        for y in 0..<sh { for x in 0..<sw where hole[y * sw + x] > 0 {
            for yy in max(0, y - 2)...min(sh - 1, y + 2) { for xx in max(0, x - 2)...min(sw - 1, x + 2) { grown[yy * sw + xx] = 1 } }
        } }
        hole = grown
        let painted = grown

        // Cells rows top down, each filled in the window centred on it.
        let side = InpaintPlan.side, cellSide = InpaintPlan.cell, windowPlane = side * side
        var cells: [(x: Int, y: Int, w: Int, h: Int)] = []
        for cy in stride(from: 0, to: sh, by: cellSide) { for cx in stride(from: 0, to: sw, by: cellSide) {
            let cell = (x: cx, y: cy, w: min(cellSide, sw - cx), h: min(cellSide, sh - cy))
            var any = false
            for y in cell.y..<cell.y + cell.h where !any { for x in cell.x..<cell.x + cell.w where hole[y * sw + x] > 0 { any = true; break } }
            if any { cells.append(cell) }
        } }
        let model = try BundledModelCache.shared.model(.inpaint, function: "inpaint\(side)")
        for (index, cell) in cells.enumerated() {
            if cancelled() { throw CancellationError() }
            let left = min(max(0, sw - side), max(0, cell.x + cell.w / 2 - side / 2))
            let top = min(max(0, sh - side), max(0, cell.y + cell.h / 2 - side / 2))
            // Past the panorama's own edge, the window is padding the network fills and nobody keeps.
            var pixels = [Float](repeating: 0, count: windowPlane * 3), mask = [Float](repeating: 1, count: windowPlane)
            for y in 0..<min(side, sh - top) { for x in 0..<min(side, sw - left) {
                let i = y * side + x, j = (top + y) * sw + left + x
                for c in 0..<3 { pixels[c * windowPlane + i] = small[c * plane + j] }
                mask[i] = hole[j]
            } }
            let result = try InpaintJob.fill(image: pixels, hole: mask, model: model)
            for y in cell.y..<cell.y + cell.h { for x in cell.x..<cell.x + cell.w where hole[y * sw + x] > 0 {
                let i = (y - top) * side + x - left, j = y * sw + x
                for c in 0..<3 {
                    let value = result[c * windowPlane + i]
                    guard value.isFinite else { throw PanoramaError.message(L10n.tr("The edges could not be filled.")) }
                    small[c * plane + j] = value
                }
                hole[j] = 0
            } }
            progress(index + 1, cells.count)
        }

        // Back to full size under the photos: where coverage is partial, the fill shows through in proportion, and it
        // covers the grown band too, where the blend darkens the photos' last pixels.
        var out = image.rgba
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: h) { y in
                let fy = max(0, min(Double(sh - 1), (Double(y) + 0.5) * scale - 0.5))
                let y0 = Int(fy), y1 = min(sh - 1, y0 + 1), ty = Float(fy - Double(y0))
                for x in 0..<w {
                    let p = (y * w + x) * 4, a = min(1, max(0, out[p + 3]))
                    let fx = max(0, min(Double(sw - 1), (Double(x) + 0.5) * scale - 0.5))
                    let x0 = Int(fx), x1 = min(sw - 1, x0 + 1), tx = Float(fx - Double(x0))
                    let band = (painted[y0 * sw + x0] * (1 - tx) + painted[y0 * sw + x1] * tx) * (1 - ty)
                        + (painted[y1 * sw + x0] * (1 - tx) + painted[y1 * sw + x1] * tx) * ty
                    let weight = max(1 - a, band)
                    guard weight > 0 else { continue }
                    for c in 0..<3 {
                        let base = c * plane
                        let top = small[base + y0 * sw + x0] * (1 - tx) + small[base + y0 * sw + x1] * tx
                        let bottom = small[base + y1 * sw + x0] * (1 - tx) + small[base + y1 * sw + x1] * tx
                        let filled = top * (1 - ty) + bottom * ty
                        out[p + c] = a > 0 ? out[p + c] * (1 - weight) + filled * weight : filled
                    }
                    out[p + 3] = 1
                }
            }
        }
        return PanoramaRaster(width: w, height: h, rgba: out)
    }

    /// The farthest any uncovered cell is from a covered one, in cells (chamfer distance); nil when nothing is covered.
    static func depth(_ grid: PanoramaCoverageGrid) -> Int? {
        let n = grid.along, m = grid.across, far = Int.max / 4
        guard grid.covered.contains(true) else { return nil }
        var d = grid.covered.map { $0 ? 0 : far }
        // Chamfer 3-4, forward then back; distance in thirds of a cell.
        for u in 0..<n { for v in 0..<m where d[u * m + v] > 0 {
            var best = d[u * m + v]
            if u > 0 { best = min(best, d[(u - 1) * m + v] + 3); if v > 0 { best = min(best, d[(u - 1) * m + v - 1] + 4) }; if v + 1 < m { best = min(best, d[(u - 1) * m + v + 1] + 4) } }
            if v > 0 { best = min(best, d[u * m + v - 1] + 3) }
            d[u * m + v] = best
        } }
        for u in stride(from: n - 1, through: 0, by: -1) { for v in stride(from: m - 1, through: 0, by: -1) where d[u * m + v] > 0 {
            var best = d[u * m + v]
            if u + 1 < n { best = min(best, d[(u + 1) * m + v] + 3); if v > 0 { best = min(best, d[(u + 1) * m + v - 1] + 4) }; if v + 1 < m { best = min(best, d[(u + 1) * m + v + 1] + 4) } }
            if v + 1 < m { best = min(best, d[u * m + v + 1] + 3) }
            d[u * m + v] = best
        } }
        return ((d.max() ?? 0) + 2) / 3
    }
}
