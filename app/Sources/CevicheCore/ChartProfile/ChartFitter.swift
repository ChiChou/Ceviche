import Foundation

// MARK: - Small dense linear algebra

/// Solves A x = b (n × n, row-major) by Gaussian elimination with partial pivoting; nil when singular.
func chartSolveLinear(_ a: [Double], _ b: [Double], _ n: Int) -> [Double]? {
    var m = a, x = b
    for col in 0..<n {
        var pivot = col
        for r in col + 1..<n where abs(m[r * n + col]) > abs(m[pivot * n + col]) { pivot = r }
        guard abs(m[pivot * n + col]) > 1e-300 else { return nil }
        if pivot != col {
            for c in 0..<n { m.swapAt(col * n + c, pivot * n + c) }
            x.swapAt(col, pivot)
        }
        let d = m[col * n + col]
        for r in col + 1..<n {
            let f = m[r * n + col] / d
            if f == 0 { continue }
            for c in col..<n { m[r * n + c] -= f * m[col * n + c] }
            x[r] -= f * x[col]
        }
    }
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = x[r]
        for c in r + 1..<n { s -= m[r * n + c] * x[c] }
        x[r] = s / m[r * n + r]
    }
    return x
}

/// Weighted linear least squares: rows of `a` (each `n` long) against `b`.
func chartLeastSquares(_ rows: [[Double]], _ b: [Double], weights: [Double]? = nil, ridge: Double = 0) -> [Double]? {
    guard let n = rows.first?.count else { return nil }
    var ata = [Double](repeating: 0, count: n * n), atb = [Double](repeating: 0, count: n)
    for (k, row) in rows.enumerated() {
        let w = weights?[k] ?? 1
        for i in 0..<n {
            atb[i] += w * row[i] * b[k]
            for j in 0..<n { ata[i * n + j] += w * row[i] * row[j] }
        }
    }
    for i in 0..<n { ata[i * n + i] += ridge }
    return chartSolveLinear(ata, atb, n)
}

/// Levenberg–Marquardt with a forward-difference Jacobian. Small problems only (parameters ≲ 200).
func chartLevenberg(_ start: [Double], iterations: Int = 60, _ residuals: ([Double]) -> [Double]) -> [Double] {
    var x = start, r = residuals(x)
    var cost = r.reduce(0) { $0 + $1 * $1 }
    var lambda = 1e-3
    let n = x.count
    for _ in 0..<iterations {
        let m = r.count
        var jac = [Double](repeating: 0, count: m * n)
        for j in 0..<n {
            var xp = x
            let h = 1e-6 * max(1, abs(x[j]))
            xp[j] += h
            let rp = residuals(xp)
            for i in 0..<m { jac[i * n + j] = (rp[i] - r[i]) / h }
        }
        var jtj = [Double](repeating: 0, count: n * n), jtr = [Double](repeating: 0, count: n)
        for i in 0..<m {
            let ri = r[i]
            for a in 0..<n {
                let ja = jac[i * n + a]
                if ja == 0 { continue }
                jtr[a] += ja * ri
                for b in a..<n { jtj[a * n + b] += ja * jac[i * n + b] }
            }
        }
        for a in 0..<n { for b in 0..<a { jtj[a * n + b] = jtj[b * n + a] } }
        var improved = false
        for _ in 0..<10 {
            var damped = jtj
            for a in 0..<n { damped[a * n + a] += lambda * max(jtj[a * n + a], 1e-9) }
            guard let step = chartSolveLinear(damped, jtr.map { -$0 }, n) else { lambda *= 10; continue }
            let candidate = zip(x, step).map { $0 + $1 }
            let rc = residuals(candidate)
            let cc = rc.reduce(0) { $0 + $1 * $1 }
            if cc.isFinite && cc < cost {
                let gain = (cost - cc) / max(cost, 1e-12)
                x = candidate; r = rc; cost = cc; lambda = max(lambda / 3, 1e-9); improved = true
                if gain < 1e-7 { return x }
                break
            }
            lambda *= 8
        }
        if !improved { break }
    }
    return x
}

// MARK: - Measurements and white balance

/// The 24 patch means and which ones may be used.
struct ChartMeasurement {
    var rgb: [SIMD3<Double>]
    var valid: [Bool]
}

/// White balance from the neutral patches (their summed camera RGB, so brighter patches weigh more), as the camera
/// neutral normalized to green = 1.
func chartNeutral(_ m: ChartMeasurement, excluding: Set<Int> = []) -> SIMD3<Double>? {
    let use = ColorChecker.balanceNeutrals.filter { m.valid[$0] && !excluding.contains($0) }
    guard !use.isEmpty else { return nil }
    let sum = use.reduce(SIMD3<Double>(0, 0, 0)) { $0 + m.rgb[$1] }
    return sum / sum.y
}

// MARK: - Colour models

/// A camera colour model: white-balanced camera RGB → XYZ (D50). All of them map (1,1,1) to D50 white and are
/// homogeneous of degree one, so exposure and white balance are separate from the fit.
protocol ChartColourModel {
    var name: String { get }
    func xyz(_ balanced: SIMD3<Double>) -> SIMD3<Double>
}

struct ChartMatrixModel: ChartColourModel {
    var name: String
    var forward: ChartMatrix   // white-balanced camera RGB → XYZ D50 (a DNG ForwardMatrix)
    func xyz(_ c: SIMD3<Double>) -> SIMD3<Double> { forward * c }
}

/// A DNG HueSatMap with one value division, applied in linear ProPhoto after the matrix: per hue × saturation node a
/// hue shift (degrees), a saturation scale and a value scale. Saturation 0 is held at identity so greys stay grey.
struct ChartHueSatMap: Codable {
    var hueDivisions: Int, satDivisions: Int
    var data: [Float]   // (hue × sat) × 3, hue-major as in a DCP

    static func identity(hue: Int, sat: Int) -> ChartHueSatMap {
        ChartHueSatMap(hueDivisions: hue, satDivisions: sat, data: (0..<hue * sat).flatMap { _ in [Float(0), 1, 1] })
    }
    /// Extremes of the table and how many neighbouring hue nodes swap order (a fold makes hues cross over).
    var stats: [String: Double] {
        var maxShift = 0.0, sat = (Double.infinity, -Double.infinity), val = (Double.infinity, -Double.infinity), folds = 0.0
        for h in 0..<hueDivisions {
            for k in 1..<satDivisions {
                let i = (h * satDivisions + k) * 3, j = (((h + 1) % hueDivisions) * satDivisions + k) * 3
                maxShift = max(maxShift, abs(Double(data[i])))
                sat = (min(sat.0, Double(data[i + 1])), max(sat.1, Double(data[i + 1])))
                val = (min(val.0, Double(data[i + 2])), max(val.1, Double(data[i + 2])))
                if 360 / Double(hueDivisions) + Double(data[j] - data[i]) <= 0 { folds += 1 }
            }
        }
        return ["maxHueShift": (maxShift * 10).rounded() / 10, "minSatScale": (sat.0 * 1000).rounded() / 1000, "maxSatScale": (sat.1 * 1000).rounded() / 1000,
                "minValScale": (val.0 * 1000).rounded() / 1000, "maxValScale": (val.1 * 1000).rounded() / 1000, "hueFolds": folds]
    }
    static func hsv(_ c: SIMD3<Double>) -> (Double, Double, Double) {
        let v = max(c.x, max(c.y, c.z)), gap = v - min(c.x, min(c.y, c.z))
        guard gap > 0, v > 0 else { return (0, 0, v) }
        var h: Double
        if c.x == v { h = (c.y - c.z) / gap; if h < 0 { h += 6 } } else if c.y == v { h = 2 + (c.z - c.x) / gap } else { h = 4 + (c.x - c.y) / gap }
        return (h, gap / v, v)
    }
    func hsvToRGB(_ hIn: Double, _ s: Double, _ val: Double) -> SIMD3<Double> {
        guard s > 0 else { return SIMD3<Double>(val, val, val) }
        var h = hIn
        if h < 0 { h += 6 }
        if h >= 6 { h -= 6 }
        let i = min(5, Int(h)), f = h - Double(i)
        let p = val * (1 - s), q = val * (1 - s * f), u = val * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3<Double>(val, u, p)
        case 1: return SIMD3<Double>(q, val, p)
        case 2: return SIMD3<Double>(p, val, u)
        case 3: return SIMD3<Double>(p, q, val)
        case 4: return SIMD3<Double>(u, p, val)
        default: return SIMD3<Double>(val, p, q)
        }
    }
    /// The DNG SDK's bilinear formula.
    func applyDouble(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let v = max(c.x, max(c.y, c.z)), gap = v - min(c.x, min(c.y, c.z))
        guard gap > 0 else { return c }
        var h: Double
        if c.x == v { h = (c.y - c.z) / gap; if h < 0 { h += 6 } } else if c.y == v { h = 2 + (c.z - c.x) / gap } else { h = 4 + (c.x - c.y) / gap }
        var s = gap / v, val = v
        let hScaled = h * Double(hueDivisions) / 6, sScaled = s * Double(satDivisions - 1)
        var h0 = Int(hScaled), h1 = h0 + 1
        let s0 = min(Int(sScaled), satDivisions - 2)
        if h0 >= hueDivisions - 1 { h0 = hueDivisions - 1; h1 = 0 }
        let hf = hScaled - Double(h0), sf = sScaled - Double(s0)
        func e(_ hi: Int, _ si: Int) -> SIMD3<Double> { let i = (hi * satDivisions + si) * 3; return SIMD3<Double>(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) }
        let lo = (1 - hf) * e(h0, s0) + hf * e(h1, s0), hi = (1 - hf) * e(h0, s0 + 1) + hf * e(h1, s0 + 1)
        let t = (1 - sf) * lo + sf * hi
        h += t.x * 6 / 360; s = min(s * t.y, 1); val *= t.z
        guard s > 0 else { return SIMD3<Double>(val, val, val) }
        if h < 0 { h += 6 }
        if h >= 6 { h -= 6 }
        let i = min(5, Int(h)), f = h - Double(i)
        let p = val * (1 - s), q = val * (1 - s * f), u = val * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3<Double>(val, u, p)
        case 1: return SIMD3<Double>(q, val, p)
        case 2: return SIMD3<Double>(p, val, u)
        case 3: return SIMD3<Double>(p, q, val)
        case 4: return SIMD3<Double>(u, p, val)
        default: return SIMD3<Double>(val, p, q)
        }
    }
}

/// Second-order root-polynomial regression (Finlayson, Mackiewicz, Hurlbert 2015): R, G, B, √RG, √GB, √RB.
struct ChartRootPolynomialModel: ChartColourModel {
    var name = "root-polynomial"
    var coefficients: [Double]   // 3 × 6, row-major
    static func terms(_ c: SIMD3<Double>) -> [Double] {
        let r = max(c.x, 0), g = max(c.y, 0), b = max(c.z, 0)
        return [c.x, c.y, c.z, (r * g).squareRoot(), (g * b).squareRoot(), (r * b).squareRoot()]
    }
    func xyz(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let t = Self.terms(c)
        func row(_ r: Int) -> Double { (0..<6).reduce(0) { $0 + coefficients[r * 6 + $1] * t[$1] } }
        return SIMD3<Double>(row(0), row(1), row(2))
    }
}

/// Predicts every patch's XYZ (D50): white balance from this chart's neutrals, the model, then exposure scaled so the
/// neutrals' luminance matches the reference.
func chartPredict(_ model: ChartColourModel, _ m: ChartMeasurement, excluding: Set<Int> = []) -> [SIMD3<Double>]? {
    guard let n = chartNeutral(m, excluding: excluding) else { return nil }
    let raw = m.rgb.map { model.xyz(SIMD3<Double>($0.x / n.x, $0.y / n.y, $0.z / n.z)) }
    let use = ColorChecker.balanceNeutrals.filter { m.valid[$0] && !excluding.contains($0) }
    let k = use.reduce(0) { $0 + ColorChecker.xyz[$1].y } / use.reduce(0) { $0 + raw[$1].y }
    return raw.map { $0 * k }
}

func chartDeltaEs(_ xyz: [SIMD3<Double>]) -> [Double] {
    xyz.enumerated().map { ChartColour.deltaE2000(ChartColour.lab($0.element), ColorChecker.lab[$0.offset]) }
}

// MARK: - Fitting

enum ChartFitter {
    /// Patches the fit may use: valid ones in `use`.
    static func balanced(_ m: ChartMeasurement, use: [Int]) -> (SIMD3<Double>, [SIMD3<Double>])? {
        guard let n = chartNeutral(m, excluding: Set((0..<24).filter { !use.contains($0) })) else { return nil }
        return (n, m.rgb.map { SIMD3<Double>($0.x / n.x, $0.y / n.y, $0.z / n.z) })
    }

    /// √ΔE00 residuals, so least squares minimizes the mean ΔE2000 of the patches in `use`.
    static func residuals(_ model: ChartColourModel, _ m: ChartMeasurement, use: [Int]) -> [Double] {
        let excluded = Set((0..<24).filter { !use.contains($0) })
        guard let xyz = chartPredict(model, m, excluding: excluded) else { return use.map { _ in 1e3 } }
        return use.map { (ChartColour.deltaE2000(ChartColour.lab(xyz[$0]), ColorChecker.lab[$0]) + 1e-4).squareRoot() }
    }

    /// 3 × 3 matrix with (1,1,1) → D50 white: weighted least squares in XYZ, then refined on mean ΔE2000 if `refine`.
    static func matrix(_ m: ChartMeasurement, use: [Int], refine: Bool) -> ChartMatrixModel? {
        guard let (_, c) = balanced(m, use: use) else { return nil }
        let neutrals = ColorChecker.balanceNeutrals.filter { use.contains($0) }
        let k = neutrals.reduce(0) { $0 + ColorChecker.xyz[$1].y } / neutrals.reduce(0) { $0 + (c[$1].x + c[$1].y + c[$1].z) / 3 }
        var params: [Double] = []
        for r in 0..<3 {
            // XYZ_r = p (c1 − c3) + q (c2 − c3) + W_r c3, weighted for relative error.
            let rows = use.map { [k * (c[$0].x - c[$0].z), k * (c[$0].y - c[$0].z)] }
            let b = use.map { ColorChecker.xyz[$0][r] - ChartColour.d50[r] * k * c[$0].z }
            let w = use.map { 1 / pow(max(ColorChecker.xyz[$0].y, 0.02), 2) }
            guard let pq = chartLeastSquares(rows, b, weights: w) else { return nil }
            params += pq
        }
        func model(_ p: [Double]) -> ChartMatrixModel {
            var m = [Double]()
            for r in 0..<3 {
                let a: Double = p[r * 2], b: Double = p[r * 2 + 1]
                m += [a, b, ChartColour.d50[r] - a - b]
            }
            return ChartMatrixModel(name: refine ? "matrix" : "matrix (least squares)", forward: ChartMatrix(m))
        }
        if refine { params = chartLevenberg(params) { residuals(model($0), m, use: use) } }
        return model(params)
    }

    static func rootPolynomial(_ m: ChartMeasurement, use: [Int]) -> ChartRootPolynomialModel? {
        guard let (_, c) = balanced(m, use: use) else { return nil }
        let neutrals = ColorChecker.balanceNeutrals.filter { use.contains($0) }
        let k = neutrals.reduce(0) { $0 + ColorChecker.xyz[$1].y } / neutrals.reduce(0) { $0 + (c[$1].x + c[$1].y + c[$1].z) / 3 }
        var params: [Double] = []
        for r in 0..<3 {
            // Five free terms per row; the sixth (√RB) takes up the white constraint.
            let rows: [[Double]] = use.map { i in let t = ChartRootPolynomialModel.terms(c[i] * k); return (0..<5).map { t[$0] - t[5] } }
            let b = use.map { ColorChecker.xyz[$0][r] - ChartColour.d50[r] * ChartRootPolynomialModel.terms(c[$0] * k)[5] }
            let w = use.map { 1 / pow(max(ColorChecker.xyz[$0].y, 0.02), 2) }
            guard let five = chartLeastSquares(rows, b, weights: w, ridge: 1e-6) else { return nil }
            params += five
        }
        func model(_ p: [Double]) -> ChartRootPolynomialModel {
            ChartRootPolynomialModel(coefficients: (0..<3).flatMap { r -> [Double] in
                let five = Array(p[r * 5..<r * 5 + 5]); return five + [ChartColour.d50[r] - five.reduce(0, +)]
            })
        }
        params = chartLevenberg(params) { residuals(model($0), m, use: use) }
        return model(params)
    }
}

/// Samples a model into a DNG HueSatMap on top of `base`: at each node (hue, saturation) of the base matrix's linear
/// ProPhoto output, the hue shift and saturation/value scales that turn the base into the model. Exact at the nodes
/// for models that, like the base, are homogeneous of degree one (root-polynomial is); bilinear in between.
///
/// Beyond the chart the polynomial extrapolates, so the table fades to identity (the matrix alone) above the most
/// saturated patch near each hue (within 90°, weighted down with distance): full strength up to it, none 0.35 further out. `patches` are the chart's patches as
/// white-balanced camera RGB.
func chartBake(_ model: ChartColourModel, base: ChartMatrix, patches: [SIMD3<Double>], hue: Int = 90, sat: Int = 30, fade: Bool = true) -> ChartHueSatMap {
    var map = ChartHueSatMap.identity(hue: hue, sat: sat)
    let toCamera = base.inverse * ChartColour.prophotoToXYZ50
    let chart = patches.map { ChartHueSatMap.hsv(ChartColour.xyz50ToProphoto * (base * $0)) }.filter { $0.1 > 0.05 }
    func limit(_ hv: Double) -> Double {
        var best = 0.25
        for p in chart {
            var d = abs(p.0 - hv); if d > 3 { d = 6 - d }
            if d < 1.5 { best = max(best, p.1 * (1 - d * d / 2.25)) }   // within 90°, falling off smoothly
        }
        return best
    }
    for h in 0..<hue {
        let hv = Double(h) * 6 / Double(hue)
        let edge = limit(hv)
        for k in 1..<sat {
            let sv = Double(k) / Double(sat - 1)
            let w = fade ? min(1, max(0, 1 - (sv - edge) / 0.35)) : 1
            let pp = ChartHueSatMap.identity(hue: 1, sat: 2).hsvToRGB(hv, sv, 1)
            let target = ChartColour.xyz50ToProphoto * model.xyz(toCamera * pp)
            let (h2, s2, v2) = ChartHueSatMap.hsv(target)
            var shift = (h2 - hv) * 60
            if shift > 180 { shift -= 360 } else if shift < -180 { shift += 360 }
            let i = (h * sat + k) * 3
            // Targets outside ProPhoto (a negative channel) have no HSV; keep the hue and cap the saturation.
            map.data[i] = Float(w * shift)
            map.data[i + 1] = Float(1 + w * (min(4, max(0, s2 / sv)) - 1))
            map.data[i + 2] = Float(1 + w * (min(4, max(0.25, v2)) - 1))
        }
    }
    return map
}

// MARK: - Scores

struct ChartScores: Codable {
    var mean: Double, median: Double, max: Double, maxPatch: Int, count: Int
    var perPatch: [Double?]
    init(_ values: [Double?]) {
        perPatch = values.map { $0.map { ($0 * 100).rounded() / 100 } }
        let v = values.compactMap { $0 }
        count = v.count
        mean = v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
        let sorted = v.sorted()
        median = sorted.isEmpty ? .nan : (sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
        let best = values.enumerated().compactMap { e in e.element.map { (e.offset, $0) } }.max { $0.1 < $1.1 }
        max = best?.1 ?? .nan; maxPatch = (best?.0 ?? -1) + 1
    }
}
