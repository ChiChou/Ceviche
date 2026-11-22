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
    public static func cubeData(_ adjustments: [SelectiveColorAdjustment], dimension: Int = 64) -> Data {
        let mixer = ColorMixerTables(adjustments)
        return FilmMath.cube(dimension: dimension) { rgb in mixer.map { mixed(rgb, $0) } ?? rgb }
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
