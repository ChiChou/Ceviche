import Foundation
import simd

public enum CurveChannel: String, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    public var key: WritableKeyPath<Adjustments, ToneCurve> {
        switch self { case .rgb: return \.curve; case .red: return \.redCurve; case .green: return \.greenCurve; case .blue: return \.blueCurve }
    }
}

/// Four smooth tonal regions. Splits are percentages in the curve's encoded RGB domain.
/// These are Ceviche's curves, not the undocumented process-version algorithms of other converters.
public struct ParametricCurve: Codable, Equatable, Sendable {
    public var shadows = 0.0, darks = 0.0, lights = 0.0, highlights = 0.0
    public var shadowSplit = 25.0, midtoneSplit = 50.0, highlightSplit = 75.0
    public init() {}
    public var isIdentity: Bool { shadows == 0 && darks == 0 && lights == 0 && highlights == 0 }
    public func value(at x: Double) -> Double {
        guard !isIdentity, x > 0, x < 1 else { return x }
        let s = shadowSplit / 100, m = midtoneSplit / 100, h = highlightSplit / 100
        let centers = [s / 2, (s + m) / 2, (m + h) / 2, (h + 1) / 2]
        let amounts = [shadows, darks, lights, highlights]
        var amount = amounts[0]
        if x >= centers[3] { amount = amounts[3] }
        else if x > centers[0] {
            let i = (1..<4).first { x <= centers[$0] }!
            let t = FilmMath.smooth((x - centers[i - 1]) / (centers[i] - centers[i - 1]))
            amount = amounts[i - 1] * (1 - t) + amounts[i] * t
        }
        // A monotonic endpoint-preserving lift/drop for each local amount.
        let power = pow(2, -amount / 100)
        return pow(x, power)
    }
    func validate() throws {
        guard [shadows, darks, lights, highlights].allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              [shadowSplit, midtoneSplit, highlightSplit].allSatisfy({ $0.isFinite && (1...99).contains($0) }),
              shadowSplit + 1 <= midtoneSplit, midtoneSplit + 1 <= highlightSplit else {
            throw EditorError.invalidDocument(L10n.tr("Invalid parametric curve or split order."))
        }
    }
}

public struct SplitToning: Codable, Equatable, Sendable {
    public var shadowHue = 0.0, shadowSaturation = 0.0
    public var highlightHue = 0.0, highlightSaturation = 0.0, balance = 0.0
    public var shadowLuminance = 0.0
    public var midtoneHue = 0.0
    public var midtoneSaturation = 0.0
    public var midtoneLuminance = 0.0
    public var highlightLuminance = 0.0
    public var globalHue = 0.0
    public var globalSaturation = 0.0
    public var globalLuminance = 0.0
    public var blending = 50.0
    public init() {}
    public var isIdentity: Bool { shadowSaturation == 0 && highlightSaturation == 0 && midtoneSaturation == 0 && globalSaturation == 0 && [shadowLuminance, midtoneLuminance, highlightLuminance, globalLuminance].allSatisfy { $0 == 0 } }
    /// `rgb` is sRGB-encoded.
    public func transform(_ rgb: SIMD3<Double>) -> SIMD3<Double> { ColorGradeCurves(self)?.transform(rgb) ?? rgb }
    enum CodingKeys: String, CodingKey { case shadowHue, shadowSaturation, highlightHue, highlightSaturation, balance, shadowLuminance, midtoneHue, midtoneSaturation, midtoneLuminance, highlightLuminance, globalHue, globalSaturation, globalLuminance, blending }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        shadowHue = try c.decodeIfPresent(Double.self, forKey: .shadowHue) ?? 0
        shadowSaturation = try c.decodeIfPresent(Double.self, forKey: .shadowSaturation) ?? 0
        highlightHue = try c.decodeIfPresent(Double.self, forKey: .highlightHue) ?? 0
        highlightSaturation = try c.decodeIfPresent(Double.self, forKey: .highlightSaturation) ?? 0
        balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        shadowLuminance = try c.decodeIfPresent(Double.self, forKey: .shadowLuminance) ?? 0
        midtoneHue = try c.decodeIfPresent(Double.self, forKey: .midtoneHue) ?? 0
        midtoneSaturation = try c.decodeIfPresent(Double.self, forKey: .midtoneSaturation) ?? 0
        midtoneLuminance = try c.decodeIfPresent(Double.self, forKey: .midtoneLuminance) ?? 0
        highlightLuminance = try c.decodeIfPresent(Double.self, forKey: .highlightLuminance) ?? 0
        globalHue = try c.decodeIfPresent(Double.self, forKey: .globalHue) ?? 0
        globalSaturation = try c.decodeIfPresent(Double.self, forKey: .globalSaturation) ?? 0
        globalLuminance = try c.decodeIfPresent(Double.self, forKey: .globalLuminance) ?? 0
        blending = try c.decodeIfPresent(Double.self, forKey: .blending) ?? 50
    }
    func validate() throws {
        try check([midtoneHue, globalHue], in: 0...360)
        try check([midtoneSaturation, globalSaturation, blending], in: 0...100)
        try check([shadowLuminance, midtoneLuminance, highlightLuminance, globalLuminance], in: -100...100)
        guard [shadowHue, highlightHue].allSatisfy({ $0.isFinite && (0...360).contains($0) }),
              [shadowSaturation, highlightSaturation].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              balance.isFinite, (-100...100).contains(balance) else { throw EditorError.invalidDocument(L10n.tr("Invalid split toning.")) }
    }
}

/// An RGB primary adjustment after Apple decoding; this does not load DCP camera profiles.
public struct PrimaryCalibration: Codable, Equatable, Sendable {
    public var redHue = 0.0, redSaturation = 0.0, greenHue = 0.0, greenSaturation = 0.0
    public var blueHue = 0.0, blueSaturation = 0.0, shadowTint = 0.0
    public init() {}
    public var isIdentity: Bool { self == Self() }
    public func transform(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        guard !isIdentity else { return rgb }
        // Change each primary's direction and chroma. Center on gray to preserve neutrals.
        let mean = (rgb.x + rgb.y + rgb.z) / 3
        let chroma = rgb - SIMD3(repeating: mean)
        func primary(_ h: Double, _ shift: Double, _ saturation: Double) -> SIMD3<Double> {
            (FilmMath.hue(h + shift / 600) - SIMD3(repeating: 1.0 / 3)) * (1 + saturation / 100)
        }
        var result = SIMD3(repeating: mean)
        result += primary(0, redHue, redSaturation) * chroma.x
        result += primary(1.0 / 3, greenHue, greenSaturation) * chroma.y
        result += primary(2.0 / 3, blueHue, blueSaturation) * chroma.z
        let shadow = pow(1 - min(1, max(0, FilmMath.luma(rgb))), 2) * shadowTint / 500
        result += SIMD3(shadow, -shadow, shadow)
        return FilmMath.clamp(result)
    }
    func validate() throws {
        guard [redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation, shadowTint].allSatisfy({ $0.isFinite && (-100...100).contains($0) }) else { throw EditorError.invalidDocument(L10n.tr("Invalid primary calibration.")) }
    }
}

public struct BlackWhiteMixer: Codable, Equatable, Sendable {
    public var values = [Double](repeating: 0, count: 8)
    public init() {}
    public var isIdentity: Bool { values.allSatisfy { $0 == 0 } }
    public func transform(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let hsl = FilmMath.hsl(rgb)
        let weights = FilmMath.hueWeights(hsl.x)
        let delta = zip(weights, values).reduce(0) { $0 + $1.0 * $1.1 } / 100
        let gray = min(1, max(0, FilmMath.luma(rgb) + delta * hsl.y * 0.5))
        return SIMD3(repeating: gray)
    }
    func validate() throws {
        guard values.count == 8, values.allSatisfy({ $0.isFinite && (-100...100).contains($0) }) else { throw EditorError.invalidDocument(L10n.tr("Invalid black and white mixer.")) }
    }
}

public struct FilmGrain: Codable, Equatable, Sendable {
    public var amount = 0.0, size = 25.0, roughness = 50.0
    public var seed: UInt32 = 1
    public init() {}
    func validate() throws {
        guard [amount, size, roughness].allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { throw EditorError.invalidDocument(L10n.tr("Invalid film grain.")) }
    }
}

enum FilmMath {
    static func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
    static func luma(_ c: SIMD3<Double>) -> Double { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
    static func clamp(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z))) }
    static let hueCenters: [Double] = [0, 30, 60, 120, 180, 240, 270, 300].map { $0 / 360 }
    static func hue(_ h: Double) -> SIMD3<Double> {
        let v = (h - floor(h)) * 6, x = 1 - abs(v.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(v) { case 0: return SIMD3(1, x, 0); case 1: return SIMD3(x, 1, 0); case 2: return SIMD3(0, 1, x); case 3: return SIMD3(0, x, 1); case 4: return SIMD3(x, 0, 1); default: return SIMD3(1, 0, x) }
    }
    static func hsl(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let hi = max(rgb.x, max(rgb.y, rgb.z)), lo = min(rgb.x, min(rgb.y, rgb.z)), d = hi - lo, l = (hi + lo) / 2
        guard d > 1e-8 else { return SIMD3(0, 0, l) }
        let h: Double
        if hi == rgb.x { h = (rgb.y - rgb.z) / d / 6 } else if hi == rgb.y { h = ((rgb.z - rgb.x) / d + 2) / 6 } else { h = ((rgb.x - rgb.y) / d + 4) / 6 }
        return SIMD3(h - floor(h), d / max(1e-8, 1 - abs(2 * l - 1)), l)
    }
    static func hueWeights(_ hue: Double) -> [Double] {
        let h = hue - floor(hue), next = hueCenters.firstIndex(where: { $0 > h }) ?? 8
        let left = next - 1, right = next % 8, start = hueCenters[left], end = next == 8 ? 1 : hueCenters[next]
        let t = smooth((h - start) / (end - start))
        var weights = [Double](repeating: 0, count: 8); weights[left] = 1 - t; weights[right] = t
        return weights
    }
    /// Linear sRGB to linear ProPhoto RGB (D65 white adapted to D50), and back.
    static let toProPhoto = simd_double3x3(rows: [SIMD3(0.529345, 0.330072, 0.140583), SIMD3(0.098374, 0.873462, 0.028164), SIMD3(0.016883, 0.117673, 0.865444)])
    static let fromProPhoto = simd_double3x3(rows: [SIMD3(2.034075, -0.727334, -0.306742), SIMD3(-0.228813, 1.231731, -0.002918), SIMD3(-0.00857, -0.153286, 1.161856)])
    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(encode(c.x), encode(c.y), encode(c.z)) }
    static func decode(_ c: SIMD3<Double>) -> SIMD3<Double> { SIMD3(decode(c.x), decode(c.y), decode(c.z)) }
    /// A curve applied the DNG RGBTone way: the darkest and brightest channels are curved and the
    /// middle one keeps its relative place between them, so hue holds.
    static func huePreserving(_ p: SIMD3<Double>, _ curve: (Double) -> Double) -> SIMD3<Double> {
        let lo = p.min(), hi = p.max(), a = curve(lo), b = curve(hi)
        guard hi - lo > 1e-8 else { return SIMD3(repeating: a) }
        return a + (b - a) * (p - lo) / (hi - lo)
    }
    /// Refine Saturation on the master point curve, in encoded values: at 0 a color keeps its channel
    /// differences from before the curve and takes its Rec. 601 luma from after it, scaled down only as far
    /// as staying inside 0…1 needs; other amounts blend linearly. Measured on another converter's renders by
    /// RAWmakase (MIT).
    static func refineSaturation(_ input: SIMD3<Double>, _ curved: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let amount = min(1, max(0, amount))
        guard amount < 1 else { return curved }
        let weights = SIMD3(0.299, 0.587, 0.114)
        let target = (curved * weights).sum(), offset = input - (input * weights).sum()
        var scale = 1.0
        if offset.max() > 1e-6 { scale = min(scale, (1 - target) / offset.max()) }
        if offset.min() < -1e-6 { scale = min(scale, target / -offset.min()) }
        let kept = target + offset * max(0, scale)
        return kept + (curved - kept) * amount
    }
    /// `table` sampled evenly over 0…1, read with linear interpolation.
    static func lookup(_ table: [Double], _ x: Double) -> Double {
        let p = min(1, max(0, x)) * Double(table.count - 1), i = min(table.count - 2, Int(p)), t = p - Double(i)
        return table[i] * (1 - t) + table[i + 1] * t
    }
    /// A 64³ table is 262,144 transforms; its blue planes are independent, so they are filled on every core.
    static func cube(dimension: Int = 64, transform: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
        let d = Double(dimension - 1), plane = dimension * dimension * 4
        var data = [Float](repeating: 1, count: dimension * plane)
        data.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: dimension) { b in
                var i = b * plane
                for g in 0..<dimension { for r in 0..<dimension {
                    let c = transform(SIMD3(Double(r) / d, Double(g) / d, Double(b) / d))
                    out[i] = Float(c.x); out[i + 1] = Float(c.y); out[i + 2] = Float(c.z); i += 4
                } }
            }
        }
        return data.withUnsafeBytes { Data($0) }
    }
}
