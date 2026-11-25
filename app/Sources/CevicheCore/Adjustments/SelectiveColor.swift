import Foundation
import simd

public struct SelectiveColorAdjustment: Codable, Equatable, Sendable {
    public var hue = 0.0
    public var saturation = 0.0
    public var luminance = 0.0
    public var range = 1.0
    public init() {}
    public var isIdentity: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

public enum SelectiveColor {
    public static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    public static var defaults: [SelectiveColorAdjustment] { Array(repeating: SelectiveColorAdjustment(), count: 8) }

    /// `rgb` is sRGB-encoded.
    public static func transform(_ rgb: SIMD3<Double>, adjustments: [SelectiveColorAdjustment]) -> SIMD3<Double> {
        guard let mixer = ColorMixerTables(adjustments) else { return rgb }
        return mixed(rgb, mixer)
    }
    static func mixed(_ rgb: SIMD3<Double>, _ mixer: ColorMixerTables) -> SIMD3<Double> {
        let linear = FilmMath.decode(rgb), out = mixer.apply(linear)
        return out == linear ? rgb : FilmMath.encode(FilmMath.clamp(out))
    }
    /// How much each band affects a pixel of this hue (0..<1), normalized so the nearest band is 1.
    /// The same falloff as `transform` at Range 1, so a targeted drag moves exactly the bands that render that color.
    public static func bandWeights(hue: Double) -> [Double] {
        let h = hue - floor(hue), centers = FilmMath.hueCenters
        let weights = centers.indices.map { index -> Double in
            let center = centers[index], distance = abs(h - center), circular = min(distance, 1 - distance)
            let delta = h - center - (h - center + 0.5).rounded(.down)
            let neighbor = centers[(index + (delta < 0 ? 7 : 1)) % 8]
            let gap = delta < 0 ? center - neighbor : neighbor - center
            let t = max(0, 1 - circular / (gap > 0 ? gap : gap + 1))
            return t * t * (3 - 2 * t)
        }
        guard let peak = weights.max(), peak > 0 else { return weights }
        return weights.map { $0 / peak }
    }
    /// HSV hue in 0..<1 of a sampled color (0 for neutral colors).
    public static func hue(_ rgb: [Double]) -> Double {
        guard rgb.count >= 3 else { return 0 }
        let r = rgb[0], g = rgb[1], b = rgb[2], high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 1e-6 else { return 0 }
        var h: Double
        if high == r { h = (g - b) / delta } else if high == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
        h /= 6
        return h < 0 ? h + 1 : h
    }
    /// The band whose center hue is circularly closest.
    public static func nearestBand(hue: Double) -> Int {
        let centers = [0.0, 30, 60, 120, 180, 240, 270, 300]
        let degrees = hue * 360
        return centers.indices.min { a, b in
            func distance(_ c: Double) -> Double { let d = abs(degrees - c).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
            return distance(centers[a]) < distance(centers[b])
        } ?? 0
    }
    public static func cubeData(_ adjustments: [SelectiveColorAdjustment], dimension: Int = 64) -> Data {
        let mixer = ColorMixerTables(adjustments)
        return FilmMath.cube(dimension: dimension) { rgb in mixer.map { mixed(rgb, $0) } ?? rgb }
    }
}

/// The Color Mixer property a targeted drag on the photo adjusts.
public enum MixerProperty: String, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case hue = "Hue", saturation = "Saturation", luminance = "Luminance"
    public var key: WritableKeyPath<SelectiveColorAdjustment, Double> {
        switch self { case .hue: return \.hue; case .saturation: return \.saturation; case .luminance: return \.luminance }
    }
    public var range: ClosedRange<Double> { self == .hue ? -60...60 : -100...100 }
    /// Units per dragged point: 200 points span saturation or luminance, 240 points span hue.
    public var unitsPerPoint: Double { self == .hue ? 0.5 : 1 }
    /// A targeted drag of `points` from the bands as they were at its start: each band moves by its weight
    /// (`SelectiveColor.bandWeights`), within the property's range.
    public func apply(points: Double, weights: [Double], from start: [SelectiveColorAdjustment], to bands: inout [SelectiveColorAdjustment]) {
        let delta = points * unitsPerPoint
        for index in bands.indices where index < start.count && index < weights.count && weights[index] > 0 {
            let moved = start[index][keyPath: key] + delta * weights[index]
            bands[index][keyPath: key] = min(range.upperBound, max(range.lowerBound, moved)).rounded()
        }
    }
}

public enum AdjustmentGroup: String, Codable, CaseIterable, Sendable {
    case defringe, pointColor, light, curve, color, selectiveColor, detail, vignette, parametricCurve, splitToning, calibration, blackWhite, grain
    /// Portrait's groups: the face spots, its measured corrections (not Whole Photo, which is the photo's own white
    /// balance) and Facial Features.
    case faceSpots, portraitLight, facialFeatures
    /// Portrait › Details: teeth, eyes, lips and brows.
    case portraitDetails
    /// Detail's own switches: `detail` is Presence (texture, clarity, dehaze and a mask's blur), these the sharpening and
    /// the noise reduction.
    case sharpening, noiseReduction
    public var keys: [WritableKeyPath<Adjustments, Double>] {
        switch self {
        case .light: return [\.exposure, \.contrast, \.highlights, \.shadows, \.whites, \.blacks]
        case .defringe, .pointColor, .curve, .selectiveColor, .parametricCurve, .splitToning, .calibration, .blackWhite, .grain,
             .faceSpots, .portraitLight, .facialFeatures, .portraitDetails: return []
        case .sharpening: return [\.sharpness, \.sharpenRadius, \.sharpenDetail, \.sharpenMasking]
        case .noiseReduction: return [\.noiseReduction]
        case .color: return [\.temperature, \.tint, \.vibrance, \.saturation]
        case .detail: return [\.clarity, \.texture, \.dehaze]
        case .vignette: return [\.vignette, \.vignetteRadius, \.vignetteSoftness]
        }
    }
}
