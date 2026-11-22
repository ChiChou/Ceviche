// ColorChecker reference data: Copyright 2013 Colour Developers, BSD-3-Clause.
// Source and adaptations: app/Sources/CevicheMac/Resources/OpenSourceLicenses/credits/colour/SOURCE.txt.
import Foundation

/// Row-major 3 × 3 matrix; small enough that clarity beats simd's column-major types.
struct ChartMatrix: Codable, Equatable {
    var m: [Double]
    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }
    static let identity = ChartMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1])
    static func diagonal(_ v: SIMD3<Double>) -> ChartMatrix { ChartMatrix([v.x, 0, 0, 0, v.y, 0, 0, 0, v.z]) }
    subscript(r: Int, c: Int) -> Double { get { m[r * 3 + c] } set { m[r * 3 + c] = newValue } }
    static func * (a: ChartMatrix, v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(a.m[0] * v.x + a.m[1] * v.y + a.m[2] * v.z, a.m[3] * v.x + a.m[4] * v.y + a.m[5] * v.z, a.m[6] * v.x + a.m[7] * v.y + a.m[8] * v.z)
    }
    static func * (a: ChartMatrix, b: ChartMatrix) -> ChartMatrix {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { out[r * 3 + c] = (0..<3).reduce(0) { $0 + a[r, $1] * b[$1, c] } } }
        return ChartMatrix(out)
    }
    var determinant: Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }
    var inverse: ChartMatrix {
        let d = determinant
        let c = [m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
                 m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
                 m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]]
        return ChartMatrix(c.map { $0 / d })
    }
}

enum ChartColour {
    /// ICC D50, the white the chart's L*a*b* values are given for and a DCP's ForwardMatrix maps to.
    static let d50 = SIMD3<Double>(0.9642, 1.0, 0.8249)
    static let d65 = SIMD3<Double>(0.95047, 1.0, 1.08883)

    static let bradford = ChartMatrix([0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296])
    /// Bradford adaptation from white `from` to white `to` (XYZ, Y = 1).
    static func adapt(from: SIMD3<Double>, to: SIMD3<Double>) -> ChartMatrix {
        let a = bradford * from, b = bradford * to
        return bradford.inverse * ChartMatrix.diagonal(SIMD3<Double>(b.x / a.x, b.y / a.y, b.z / a.z)) * bradford
    }
    static let srgbToXYZ65 = ChartMatrix([0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750, 0.0193339, 0.1191920, 0.9503041])
    static let xyz65ToSRGB = srgbToXYZ65.inverse
    static let prophotoToXYZ50 = ChartMatrix([0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0.0, 0.0, 0.8252100])
    static let xyz50ToProphoto = prophotoToXYZ50.inverse
    static let d65ToD50 = adapt(from: d65, to: d50)
    static let d50ToD65 = adapt(from: d50, to: d65)
    /// Linear ProPhoto (D50) → linear sRGB (D65), Bradford-adapted.
    static let prophotoToSRGB = xyz65ToSRGB * d50ToD65 * prophotoToXYZ50
    static let xyz50ToSRGB = xyz65ToSRGB * d50ToD65

    static func lab(_ xyz: SIMD3<Double>, white: SIMD3<Double> = d50) -> SIMD3<Double> {
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(xyz.x / white.x), fy = f(xyz.y / white.y), fz = f(xyz.z / white.z)
        return SIMD3<Double>(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
    static func xyz(lab: SIMD3<Double>, white: SIMD3<Double> = d50) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func g(_ t: Double) -> Double { t * t * t > 216.0 / 24389 ? t * t * t : (116 * t - 16) / (24389.0 / 27) }
        return SIMD3<Double>(g(fx) * white.x, g(fy) * white.y, g(fz) * white.z)
    }
    static func xy(_ xyz: SIMD3<Double>) -> (Double, Double) { let s = xyz.x + xyz.y + xyz.z; return (xyz.x / s, xyz.y / s) }
    static func xyzFrom(x: Double, y: Double) -> SIMD3<Double> { SIMD3<Double>(x / y, 1, (1 - x - y) / y) }
    /// McCamy's approximation, good to a few kelvin from 2800 K to 6500 K near the Planckian locus.
    static func cct(x: Double, y: Double) -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        return 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
    }

    /// CIEDE2000 (Sharma, Wu, Dalal 2005), kL = kC = kH = 1.
    static func deltaE2000(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let (l1, a1, b1) = (a.x, a.y, a.z), (l2, a2, b2) = (b.x, b.y, b.z)
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let c7 = pow(cBar, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double { if a == 0 && b == 0 { return 0 }; let h = atan2(b, a) * 180 / .pi; return h < 0 ? h + 360 : h }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 { dhp = h2p - h1p; if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 } }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 360)
        let lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        var hBarP = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBarP = (h1p + h2p) / 2 } else if h1p + h2p < 360 { hBarP = (h1p + h2p + 360) / 2 } else { hBarP = (h1p + h2p - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBarP - 30) * .pi / 180) + 0.24 * cos(2 * hBarP * .pi / 180) + 0.32 * cos((3 * hBarP + 6) * .pi / 180) - 0.20 * cos((4 * hBarP - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let l50 = (lBarP - 50) * (lBarP - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot(), sc = 1 + 0.045 * cBarP, sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }

    static func srgbEncode(_ v: Double) -> Double { let c = min(1, max(0, v)); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
}

/// ColorChecker Classic, post-November 2014 formulation: X-Rite's published L*a*b* (D50, 2°), as tabulated by
/// colour-science (`DATA_COLORCHECKER24_AFTER_NOV2014_CIE_LAB`, citing X-Rite 2016, "New color specifications for
/// ColorChecker SG and Classic Charts"). Row-major from dark skin (1) to black (24).
enum ColorChecker {
    static let names = ["dark skin", "light skin", "blue sky", "foliage", "blue flower", "bluish green",
                        "orange", "purplish blue", "moderate red", "purple", "yellow green", "orange yellow",
                        "blue", "green", "red", "yellow", "magenta", "cyan",
                        "white 9.5", "neutral 8", "neutral 6.5", "neutral 5", "neutral 3.5", "black 2"]
    static let lab: [SIMD3<Double>] = [
        SIMD3<Double>(37.54, 14.37, 14.92), SIMD3<Double>(64.66, 19.27, 17.5), SIMD3<Double>(49.32, -3.82, -22.54), SIMD3<Double>(43.46, -12.74, 22.72),
        SIMD3<Double>(54.94, 9.61, -24.79), SIMD3<Double>(70.48, -32.26, -0.37), SIMD3<Double>(62.73, 35.83, 56.5), SIMD3<Double>(39.43, 10.75, -45.17),
        SIMD3<Double>(50.57, 48.64, 16.67), SIMD3<Double>(30.1, 22.54, -20.87), SIMD3<Double>(71.77, -24.13, 58.19), SIMD3<Double>(71.51, 18.24, 67.37),
        SIMD3<Double>(28.37, 15.42, -49.8), SIMD3<Double>(54.38, -39.72, 32.27), SIMD3<Double>(42.43, 51.05, 28.62), SIMD3<Double>(81.8, 2.67, 80.41),
        SIMD3<Double>(50.63, 51.28, -14.12), SIMD3<Double>(49.57, -29.71, -28.32), SIMD3<Double>(95.19, -1.03, 2.93), SIMD3<Double>(81.29, -0.57, 0.44),
        SIMD3<Double>(66.89, -0.75, -0.06), SIMD3<Double>(50.76, -0.13, 0.14), SIMD3<Double>(35.63, -0.46, -0.48), SIMD3<Double>(20.64, 0.07, -0.46),
    ]
    static let xyz: [SIMD3<Double>] = lab.map { ChartColour.xyz(lab: $0) }
    /// Neutral patches used for white balance and exposure: neutral 8, 6.5, 5 (20–22). White 9.5 is often near
    /// clipping and black 2 is noisy and flare-prone; both are still evaluated.
    static let balanceNeutrals = [19, 20, 21]
    static let neutrals = [18, 19, 20, 21, 22, 23]
    static func srgb8(_ xyz: SIMD3<Double>) -> (UInt8, UInt8, UInt8) {
        let s = ChartColour.xyz50ToSRGB * xyz
        return (UInt8((ChartColour.srgbEncode(s.x) * 255).rounded()), UInt8((ChartColour.srgbEncode(s.y) * 255).rounded()), UInt8((ChartColour.srgbEncode(s.z) * 255).rounded()))
    }
}
