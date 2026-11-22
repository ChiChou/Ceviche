import Foundation

/// A picture the chart is looked for in: RGBA floats, linear, with alpha above a half where a sample can't be trusted.
struct ChartImage {
    var width: Int, height: Int
    var pixels: [Float]
    @inline(__always) func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
    }
    @inline(__always) func clipped(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 0.5 }
}

/// Plane projective map, row-major 3 × 3.
struct ChartHomography {
    var h: [Double]
    func map(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        return SIMD2<Double>((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }
    var inverse: ChartHomography { ChartHomography(h: ChartMatrix(h).inverse.m) }
    func scaled(_ s: Double, offset: Double) -> ChartHomography {
        // p' = s p + offset applied after the map.
        let m = ChartMatrix([s, 0, offset, 0, s, offset, 0, 0, 1]) * ChartMatrix(h)
        return ChartHomography(h: m.m)
    }
    /// Least-squares fit through ≥ 4 correspondences (normalized DLT with h33 = 1); affine for 3.
    static func fit(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>]) -> ChartHomography? {
        guard src.count >= 3, src.count == dst.count else { return nil }
        func normalizer(_ pts: [SIMD2<Double>]) -> ChartMatrix {
            let c = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
            let d = pts.reduce(0) { $0 + (($1 - c) * ($1 - c)).sum().squareRoot() } / Double(pts.count)
            let s = d > 0 ? 2.0.squareRoot() / d : 1
            return ChartMatrix([s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1])
        }
        let ns = normalizer(src), nd = normalizer(dst)
        let a = src.map { let v = ns * SIMD3<Double>($0.x, $0.y, 1); return SIMD2<Double>(v.x, v.y) }
        let b = dst.map { let v = nd * SIMD3<Double>($0.x, $0.y, 1); return SIMD2<Double>(v.x, v.y) }
        var rows: [[Double]] = [], rhs: [Double] = []
        if src.count < 4 { // affine
            for (p, q) in zip(a, b) {
                rows.append([p.x, p.y, 1, 0, 0, 0]); rhs.append(q.x)
                rows.append([0, 0, 0, p.x, p.y, 1]); rhs.append(q.y)
            }
            guard let x = chartLeastSquares(rows, rhs) else { return nil }
            let m = nd.inverse * ChartMatrix([x[0], x[1], x[2], x[3], x[4], x[5], 0, 0, 1]) * ns
            return ChartHomography(h: m.m.map { $0 / m.m[8] })
        }
        for (p, q) in zip(a, b) {
            rows.append([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y]); rhs.append(q.x)
            rows.append([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y]); rhs.append(q.y)
        }
        guard let x = chartLeastSquares(rows, rhs, ridge: src.count == 4 ? 0 : 1e-9) else { return nil }
        let m = nd.inverse * ChartMatrix(x + [1]) * ns
        return ChartHomography(h: m.m.map { $0 / m.m[8] })
    }
}

/// Where the chart is and how its 24 cells map to the image.
struct ChartDetection {
    /// Grid (column 0…5, row 0…3 in chart order: dark skin top left, black bottom right) → image pixels.
    var grid: ChartHomography
    /// Centres of patches 1, 6, 24, 19 in image pixels.
    var corners: [Double]
    /// Patch pitch in image pixels.
    var pitch: Double
    var candidates = 0, lattices = 0, windows = 0
    /// Grid cells where a square region was found (out of 24).
    var cellsFound = 24
    /// Trimmed mean ΔE76 after a free 3×3 fit of the 24 cells to the reference, for the chosen order and the runner-up.
    var colourCost = 0.0, runnerUpCost = 0.0
    var mirrored = false
    var rotation = 0
    var confidence = 0.0
}

struct ChartDetector {
    let image: ChartImage
    /// The image's neutral, for a picture that isn't white-balanced yet.
    var neutralGuess = SIMD3<Double>(1, 1, 1)

    struct Candidate { var c: SIMD2<Double>; var size: Double; var area: Int }

    // MARK: Preview

    struct Preview {
        var width: Int, height: Int, factor: Int
        var linear: [SIMD3<Float>]  // white-balanced, normalized
        var gamma: [SIMD3<Float>]
    }

    func preview(longEdge: Int = 1600) -> Preview {
        let f = max(1, Int((Double(max(image.width, image.height)) / Double(longEdge)).rounded()))
        let w = image.width / f, h = image.height / f
        let wb = SIMD3<Float>(Float(1 / neutralGuess.x), Float(1 / neutralGuess.y), Float(1 / neutralGuess.z))
        var lin = [SIMD3<Float>](repeating: .zero, count: w * h)
        lin.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var s = SIMD3<Float>(0, 0, 0)
                    for dy in 0..<f { for dx in 0..<f { s += image.rgb(x * f + dx, y * f + dy) } }
                    out[y * w + x] = s / Float(f * f) * wb
                }
            }
        }
        var lum = lin.map { ($0.x + $0.y + $0.z) / 3 }
        lum.sort()
        let top = max(lum[min(lum.count - 1, Int(Double(lum.count) * 0.995))], 1e-6)
        let gam = lin.map { v -> SIMD3<Float> in
            let n = v / top
            return SIMD3(pow(min(max(n.x, 0), 1), 1 / 2.2), pow(min(max(n.y, 0), 1), 1 / 2.2), pow(min(max(n.z, 0), 1), 1 / 2.2))
        }
        return Preview(width: w, height: h, factor: f, linear: lin.map { $0 / top }, gamma: gam)
    }

    // MARK: Square regions

    func candidates(_ p: Preview) -> [Candidate] {
        let w = p.width, h = p.height
        var grad = [Float](repeating: 1, count: w * h)
        for y in 1..<h - 1 {
            for x in 1..<w - 1 {
                let i = y * w + x
                let right: SIMD3<Float> = p.gamma[i + 1], left: SIMD3<Float> = p.gamma[i - 1]
                let down: SIMD3<Float> = p.gamma[i + w], up: SIMD3<Float> = p.gamma[i - w]
                let dx: SIMD3<Float> = right - left, dy: SIMD3<Float> = down - up
                let gx: Float = max(abs(dx.x), max(abs(dx.y), abs(dx.z))), gy: Float = max(abs(dy.x), max(abs(dy.y), abs(dy.z)))
                grad[i] = max(gx, gy)
            }
        }
        var sorted = grad
        sorted.sort()
        let threshold = max(0.03, min(0.08, 6 * sorted[sorted.count / 5]))
        var label = [Int32](repeating: -1, count: w * h)
        var out: [Candidate] = []
        var stack: [Int] = []
        let maxArea = Int(Double(w * h) * 0.03)
        for start in 0..<(w * h) where grad[start] < threshold && label[start] < 0 {
            var n = 0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            stack.append(start); label[start] = 0
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                n += 1; let fx = Double(x), fy = Double(y)
                sx += fx; sy += fy; sxx += fx * fx; syy += fy * fy; sxy += fx * fy
                for j in [i - 1, i + 1, i - w, i + w] where j >= 0 && j < w * h && label[j] < 0 && grad[j] < threshold {
                    if (j == i - 1 && x == 0) || (j == i + 1 && x == w - 1) { continue }
                    label[j] = 0; stack.append(j)
                }
            }
            guard n >= 20, n <= maxArea else { continue }
            let mx = sx / Double(n), my = sy / Double(n)
            let cxx = sxx / Double(n) - mx * mx, cyy = syy / Double(n) - my * my, cxy = sxy / Double(n) - mx * my
            let tr = cxx + cyy, det = cxx * cyy - cxy * cxy
            let disc = max(0, tr * tr / 4 - det).squareRoot()
            let l1 = tr / 2 + disc, l2 = tr / 2 - disc
            guard l2 > 0, l1 / l2 < 2.2 else { continue }
            let fill = Double(n) / (12 * (l1 * l2).squareRoot())
            guard fill > 0.8, fill < 1.15 else { continue }
            out.append(Candidate(c: SIMD2<Double>(mx, my), size: Double(n).squareRoot(), area: n))
        }
        return out
    }

    // MARK: Lattices

    struct Lattice { var cells: [SIMD2<Int>: Int]; var map: ChartHomography; var pitch: Double }

    func lattices(_ cands: [Candidate]) -> [Lattice] {
        // Spatial hash for nearest-candidate lookups.
        let cell = 24.0
        var buckets: [SIMD2<Int>: [Int]] = [:]
        for (i, c) in cands.enumerated() { buckets[SIMD2(Int(c.c.x / cell), Int(c.c.y / cell)), default: []].append(i) }
        func nearest(_ p: SIMD2<Double>, within r: Double, size: Double) -> Int? {
            var best: Int?, bestD = r * r
            let x0 = Int((p.x - r) / cell), x1 = Int((p.x + r) / cell), y0 = Int((p.y - r) / cell), y1 = Int((p.y + r) / cell)
            guard x1 >= x0, y1 >= y0, x1 - x0 < 64, y1 - y0 < 64 else { return nil }
            for by in y0...y1 { for bx in x0...x1 {
                for i in buckets[SIMD2(bx, by)] ?? [] {
                    let d = ((cands[i].c - p) * (cands[i].c - p)).sum()
                    let ratio = cands[i].size / size
                    if d < bestD && ratio > 0.6 && ratio < 1.67 { bestD = d; best = i }
                }
            } }
            return best
        }
        var used = Set<Int>()
        var result: [Lattice] = []
        for i in cands.indices where !used.contains(i) {
            let ci = cands[i]
            var neighbours: [(Int, Double)] = []
            for (j, cj) in cands.enumerated() where j != i {
                let ratio = cj.size / ci.size
                guard ratio > 0.7, ratio < 1.43 else { continue }
                let d = ((cj.c - ci.c) * (cj.c - ci.c)).sum().squareRoot()
                if d > 1.0 * ci.size && d < 2.3 * ci.size { neighbours.append((j, d)) }
            }
            neighbours.sort { $0.1 < $1.1 }
            neighbours = Array(neighbours.prefix(8))
            var best: Lattice?
            for a in 0..<neighbours.count {
                for b in a + 1..<neighbours.count {
                    let u = cands[neighbours[a].0].c - ci.c, v = cands[neighbours[b].0].c - ci.c
                    let lu = (u * u).sum().squareRoot(), lv = (v * v).sum().squareRoot()
                    guard lu / lv > 0.7, lu / lv < 1.43, abs((u * v).sum()) / (lu * lv) < 0.35 else { continue }
                    var map = ChartHomography(h: [u.x, v.x, ci.c.x, u.y, v.y, ci.c.y, 0, 0, 1])
                    var cells: [SIMD2<Int>: Int] = [:]
                    let pitch = (lu + lv) / 2
                    for pass in 0..<3 {
                        cells = [:]
                        let tolerance = (pass == 0 ? 0.3 : 0.25) * pitch
                        for gy in -7...7 { for gx in -7...7 {
                            if let k = nearest(map.map(SIMD2<Double>(Double(gx), Double(gy))), within: tolerance, size: ci.size) { cells[SIMD2(gx, gy)] = k }
                        } }
                        guard cells.count >= 6 else { break }
                        let keys = Array(cells.keys)
                        guard let fitted = ChartHomography.fit(keys.map { SIMD2<Double>(Double($0.x), Double($0.y)) }, keys.map { cands[cells[$0]!].c }) else { break }
                        map = fitted
                    }
                    // A candidate claimed twice means the lattice is too fine.
                    if Set(cells.values).count < cells.count { continue }
                    if cells.count >= 8, cells.count > (best?.cells.count ?? 0) { best = Lattice(cells: cells, map: map, pitch: pitch) }
                }
            }
            if let best {
                result.append(best)
                if best.cells.count >= 10 { used.formUnion(best.cells.values) }
            }
        }
        return result
    }

    // MARK: Order

    /// Linear camera colour (white-balanced preview) at a grid cell: mean over the inner part of the cell.
    func sampleCell(_ p: Preview, _ map: ChartHomography, _ g: SIMD2<Double>) -> SIMD3<Double> {
        var s = SIMD3<Float>(0, 0, 0), n: Float = 0
        for dy in stride(from: -0.15, through: 0.15, by: 0.05) { for dx in stride(from: -0.15, through: 0.15, by: 0.05) {
            let q = map.map(g + SIMD2<Double>(dx, dy))
            let x = Int(q.x.rounded()), y = Int(q.y.rounded())
            guard x >= 0, y >= 0, x < p.width, y < p.height else { continue }
            s += p.linear[y * p.width + x]; n += 1
        } }
        guard n > 0 else { return SIMD3<Double>(0, 0, 0) }
        return SIMD3<Double>(Double(s.x / n), Double(s.y / n), Double(s.z / n))
    }

    /// For colours in chart cell order, the cost of each of the four ways to lay the reference over the 6 × 4 cells
    /// (as is, columns reversed, rows reversed, both): trimmed mean ΔE76 after a free 3 × 3 fit.
    static func orderCosts(_ colours: [SIMD3<Double>]) -> [Double] {
        (0..<4).map { flip in
            let index = (0..<24).map { k -> Int in
                let col = k % 6, row = k / 6
                return (flip & 2 != 0 ? 3 - row : row) * 6 + (flip & 1 != 0 ? 5 - col : col)
            }
            var m = [Double]()
            for r in 0..<3 {
                let rows = (0..<24).map { [colours[$0].x, colours[$0].y, colours[$0].z] }
                let b = (0..<24).map { ColorChecker.xyz[index[$0]][r] }
                let w = (0..<24).map { 1 / pow(max(ColorChecker.xyz[index[$0]].y, 0.02), 2) }
                m += chartLeastSquares(rows, b, weights: w, ridge: 1e-9) ?? [0, 0, 0]
            }
            let mat = ChartMatrix(m)
            var errors = (0..<24).map { k -> Double in
                let lab = ChartColour.lab(mat * colours[k]), ref = ColorChecker.lab[index[k]]
                return ((lab - ref) * (lab - ref)).sum().squareRoot()
            }
            errors.sort()
            return errors.prefix(20).reduce(0, +) / 20
        }
    }

    /// Re-expresses a grid map so cell (col,row) is in chart order for `flip`.
    static func reorder(_ map: ChartHomography, flip: Int) -> ChartHomography {
        let a = flip & 1 != 0 ? ChartMatrix([-1, 0, 5, 0, 1, 0, 0, 0, 1]) : ChartMatrix.identity
        let b = flip & 2 != 0 ? ChartMatrix([1, 0, 0, 0, -1, 3, 0, 0, 1]) : ChartMatrix.identity
        return ChartHomography(h: (ChartMatrix(map.h) * a * b).m)
    }

    // MARK: Detect

    static let maximumCost = 12.0

    func detect() throws -> ChartDetection {
        let p = preview()
        let cands = candidates(p)
        let lats = lattices(cands)
        var best: (score: Double, cost: Double, second: Double, map: ChartHomography, found: Int, outside: Int)?
        var windows = 0
        for lat in lats {
            let xs = lat.cells.keys.map(\.x), ys = lat.cells.keys.map(\.y)
            for transpose in [false, true] {
                let (cols, rows) = transpose ? (4, 6) : (6, 4)
                for x0 in (xs.min()! - cols + 1)...xs.max()! {
                    for y0 in (ys.min()! - rows + 1)...ys.max()! {
                        var inside = 0, outside = 0
                        for key in lat.cells.keys {
                            let ix = key.x >= x0 && key.x < x0 + cols, iy = key.y >= y0 && key.y < y0 + rows
                            if ix && iy { inside += 1 } else if key.x >= x0 - 1 && key.x <= x0 + cols && key.y >= y0 - 1 && key.y <= y0 + rows { outside += 1 }
                        }
                        guard inside >= 8 else { continue }
                        windows += 1
                        // Cell (col,row) of a 6 × 4 window → lattice coordinates.
                        let toLattice = transpose ? ChartMatrix([0, 1, Double(x0), 1, 0, Double(y0), 0, 0, 1]) : ChartMatrix([1, 0, Double(x0), 0, 1, Double(y0), 0, 0, 1])
                        let map = ChartHomography(h: (ChartMatrix(lat.map.h) * toLattice).m)
                        let colours = (0..<24).map { sampleCell(p, map, SIMD2<Double>(Double($0 % 6), Double($0 / 6))) }
                        let costs = Self.orderCosts(colours)
                        let order = costs.indices.sorted { costs[$0] < costs[$1] }
                        let cost = costs[order[0]]
                        let score = cost + 3 * Double(outside) + 0.5 * Double(24 - inside)
                        if best == nil || score < best!.score {
                            best = (score, cost, costs[order[1]], Self.reorder(map, flip: order[0]), inside, outside)
                        }
                    }
                }
            }
        }
        // A real chart fits the reference to a few ΔE after a free 3 × 3; anything far off is some other grid.
        guard let found = best, found.cost < Self.maximumCost else { throw ChartProfileError.noChart }
        let f = Double(p.factor)
        // Preview pixel centres → image pixel centres.
        var d = makeDetection(found.map.scaled(f, offset: (f - 1) / 2))
        d.candidates = cands.count; d.lattices = lats.count; d.windows = windows
        d.cellsFound = found.found; d.colourCost = found.cost; d.runnerUpCost = found.second
        d.confidence = confidence(d)
        return d
    }

    func makeDetection(_ map: ChartHomography) -> ChartDetection {
        let corners = [SIMD2<Double>(0, 0), SIMD2<Double>(5, 0), SIMD2<Double>(5, 3), SIMD2<Double>(0, 3)].flatMap { g -> [Double] in let q = map.map(g); return [q.x, q.y] }
        let a = map.map(SIMD2<Double>(0, 0)), b = map.map(SIMD2<Double>(5, 0)), c = map.map(SIMD2<Double>(0, 3))
        let pitch = (((b - a) * (b - a)).sum().squareRoot() / 5 + ((c - a) * (c - a)).sum().squareRoot() / 3) / 2
        // Image y points down: an unmirrored chart has columns turning clockwise into rows.
        let u = b - a, v = c - a
        let cross = u.x * v.y - u.y * v.x
        let angle = atan2(u.y, u.x) * 180 / .pi
        var d = ChartDetection(grid: map, corners: corners, pitch: pitch)
        d.mirrored = cross < 0
        d.rotation = Int((angle / 90).rounded()) * 90 % 360
        if d.rotation < 0 { d.rotation += 360 }
        return d
    }

    /// 0…1: how many cells were found as squares, how well the colours fit the reference, and how clearly the chosen
    /// order beats the runner-up.
    func confidence(_ d: ChartDetection) -> Double {
        let coverage = (Double(d.cellsFound) / 24).squareRoot()
        let fit = exp(-d.colourCost / 12)
        let margin = min(1, max(0, (d.runnerUpCost / max(d.colourCost, 0.1) - 1) / 1.5))
        return coverage * fit * margin * (d.mirrored ? 0.5 : 1)
    }
}

// MARK: - Patch sampling

struct ChartPatchSample {
    /// Why a patch is left out of the fit.
    enum Rejection { case outside, clipped, noSignal, notUniform, uneven }
    var patch: Int
    var centre: [Double]          // image pixels
    var rgb: [Double]
    var std: [Double]
    var pixels: Int
    var clipped: Double           // fraction of pixels flagged as not to be trusted
    var unevenness: Double        // spread of the four quadrant means relative to the mean
    var rejection: Rejection?
    var valid: Bool { rejection == nil }
}

/// Samples the inner 40 % of each cell (≈ 50 % of the patch side; patches fill about 80 % of the pitch).
func chartSamplePatches(_ image: ChartImage, _ d: ChartDetection, inner: Double = 0.2) -> [ChartPatchSample] {
    let inverse = d.grid.inverse
    return (0..<24).map { k in
        let g = SIMD2<Double>(Double(k % 6), Double(k / 6))
        let quad = [SIMD2<Double>(-1, -1), SIMD2<Double>(1, -1), SIMD2<Double>(1, 1), SIMD2<Double>(-1, 1)].map { d.grid.map(g + $0 * inner) }
        let x0 = max(0, Int(quad.map(\.x).min()!.rounded(.down))), x1 = min(image.width - 1, Int(quad.map(\.x).max()!.rounded(.up)))
        let y0 = max(0, Int(quad.map(\.y).min()!.rounded(.down))), y1 = min(image.height - 1, Int(quad.map(\.y).max()!.rounded(.up)))
        var values: [(SIMD3<Float>, Int)] = [], clipped = 0
        if x1 >= x0 && y1 >= y0 {
            for y in y0...y1 { for x in x0...x1 {
                let q = inverse.map(SIMD2<Double>(Double(x), Double(y))) - g
                guard abs(q.x) <= inner, abs(q.y) <= inner else { continue }
                if image.clipped(x, y) { clipped += 1 }
                values.append((image.rgb(x, y), (q.x < 0 ? 0 : 1) + (q.y < 0 ? 0 : 2)))
            } }
        }
        let centre = d.grid.map(g)
        guard values.count >= 4 else {
            return ChartPatchSample(patch: k + 1, centre: [centre.x, centre.y], rgb: [0, 0, 0], std: [0, 0, 0], pixels: values.count,
                                    clipped: 0, unevenness: 0, rejection: .outside)
        }
        // Trimmed mean: drop 5 % at each end by brightness (dust, specks, a stray edge).
        let sorted = values.sorted { ($0.0.x + $0.0.y + $0.0.z) < ($1.0.x + $1.0.y + $1.0.z) }
        let cut = sorted.count / 20
        let kept = sorted[cut..<sorted.count - cut]
        var sum = SIMD3<Double>(0, 0, 0), sq = SIMD3<Double>(0, 0, 0)
        var quads = [SIMD3<Double>](repeating: .zero, count: 4), quadN = [Double](repeating: 0, count: 4)
        for (v, q) in kept {
            let dv = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            sum += dv; sq += dv * dv; quads[q] += dv; quadN[q] += 1
        }
        let n = Double(kept.count)
        let mean = sum / n
        let std = ((sq / n) - mean * mean).replacing(with: 0, where: (sq / n) - mean * mean .< 0)
        let sd = SIMD3(std.x.squareRoot(), std.y.squareRoot(), std.z.squareRoot())
        let level = mean.sum()
        let quadLevels = (0..<4).filter { quadN[$0] > 0 }.map { quads[$0].sum() / quadN[$0] }
        let uneven = level > 0 ? (quadLevels.max()! - quadLevels.min()!) / (level / 1) : 0
        var rejection: ChartPatchSample.Rejection?
        let clippedFraction = Double(clipped) / Double(values.count)
        if clippedFraction > 0 { rejection = .clipped }
        else if level <= 0 { rejection = .noSignal }
        else if sd.y / max(mean.y, 1e-6) > 0.12 && sd.y > 0.002 { rejection = .notUniform }
        else if uneven > 0.06 { rejection = .uneven }
        return ChartPatchSample(patch: k + 1, centre: [centre.x, centre.y], rgb: [mean.x, mean.y, mean.z], std: [sd.x, sd.y, sd.z],
                                pixels: values.count, clipped: clippedFraction, unevenness: uneven, rejection: rejection)
    }
}
