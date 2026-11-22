import Foundation

/// Shared, neutral pixel controls for global development and masked adjustment layers.
public struct PixelAdjustments: Codable, Equatable, Sendable {
    public var exposure: Double = 0.0
    public var contrast: Double = 0.0
    public var highlights: Double = 0.0
    public var shadows: Double = 0.0
    public var whites: Double = 0.0
    public var blacks: Double = 0.0
    public var tint: Double = 0.0
    public var vibrance: Double = 0.0
    public var saturation: Double = 0.0
    public var clarity: Double = 0.0
    public var texture: Double = 0.0
    public var dehaze: Double = 0.0
    public var sharpness: Double = 0.0
    public var noiseReduction: Double = 0.0
    public var vignette: Double = 0.0
    public var vignetteRadius: Double = 0.5
    public var vignetteSoftness: Double = 0.5
    public var selectiveColors: [SelectiveColorAdjustment] = SelectiveColor.defaults
    public var disabledSections: Set<AdjustmentGroup> = []
    public var monochrome: Bool = false
    public var curve: ToneCurve = ToneCurve()
    public var redCurve: ToneCurve = ToneCurve()
    public var greenCurve: ToneCurve = ToneCurve()
    public var blueCurve: ToneCurve = ToneCurve()
    public var parametricCurve: ParametricCurve = ParametricCurve()
    public var splitToning: SplitToning = SplitToning()
    public var calibration: PrimaryCalibration = PrimaryCalibration()
    public var blackWhiteMixer: BlackWhiteMixer = BlackWhiteMixer()
    public var grain: FilmGrain = FilmGrain()
    public var sharpenRadius: Double = 1.0
    public var sharpenDetail: Double = 25.0
    public var sharpenMasking: Double = 0.0
    public var colorNoiseReduction: Double? = 0
    public var warmth: Double = 0.0
    public var blur: Double = 0.0
    public var curveSaturation: Double = 100
    public var colorNoiseDetail: Double = 50
    public var colorNoiseSmoothness: Double = 50
    public var defringe: Defringe = Defringe()
    public var postCropVignette: PostCropVignette = PostCropVignette()
    public var pointColors: [PointColor] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case curveSaturation, colorNoiseDetail, colorNoiseSmoothness, defringe, postCropVignette, pointColors, exposure, contrast, highlights, shadows, whites, blacks, tint, vibrance, saturation, clarity, texture, dehaze, sharpness, noiseReduction, vignette, vignetteRadius, vignetteSoftness, selectiveColors, disabledSections, monochrome, curve, redCurve, greenCurve, blueCurve, parametricCurve, splitToning, calibration, blackWhiteMixer, grain, sharpenRadius, sharpenDetail, sharpenMasking, colorNoiseReduction, warmth, blur }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? blacks
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? clarity
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? texture
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? dehaze
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? sharpness
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? noiseReduction
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        vignetteRadius = try c.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? vignetteRadius
        vignetteSoftness = try c.decodeIfPresent(Double.self, forKey: .vignetteSoftness) ?? vignetteSoftness
        selectiveColors = try c.decodeIfPresent([SelectiveColorAdjustment].self, forKey: .selectiveColors) ?? selectiveColors
        disabledSections = try c.decodeIfPresent([String].self, forKey: .disabledSections).map { Set($0.compactMap(AdjustmentGroup.init(rawValue:))) } ?? disabledSections
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? monochrome
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve) ?? curve
        redCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .redCurve) ?? redCurve
        greenCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .greenCurve) ?? greenCurve
        blueCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .blueCurve) ?? blueCurve
        parametricCurve = try c.decodeIfPresent(ParametricCurve.self, forKey: .parametricCurve) ?? parametricCurve
        splitToning = try c.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? splitToning
        calibration = try c.decodeIfPresent(PrimaryCalibration.self, forKey: .calibration) ?? calibration
        blackWhiteMixer = try c.decodeIfPresent(BlackWhiteMixer.self, forKey: .blackWhiteMixer) ?? blackWhiteMixer
        grain = try c.decodeIfPresent(FilmGrain.self, forKey: .grain) ?? grain
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? sharpenRadius
        sharpenDetail = try c.decodeIfPresent(Double.self, forKey: .sharpenDetail) ?? sharpenDetail
        sharpenMasking = try c.decodeIfPresent(Double.self, forKey: .sharpenMasking) ?? sharpenMasking
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? warmth
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? blur
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        curveSaturation = try c.decodeIfPresent(Double.self, forKey: .curveSaturation) ?? 100
        colorNoiseDetail = try c.decodeIfPresent(Double.self, forKey: .colorNoiseDetail) ?? 50
        colorNoiseSmoothness = try c.decodeIfPresent(Double.self, forKey: .colorNoiseSmoothness) ?? 50
        defringe = try c.decodeIfPresent(Defringe.self, forKey: .defringe) ?? Defringe()
        postCropVignette = try c.decodeIfPresent(PostCropVignette.self, forKey: .postCropVignette) ?? PostCropVignette()
        pointColors = try c.decodeIfPresent([PointColor].self, forKey: .pointColors) ?? []
    }
    public mutating func resetValues(for group: AdjustmentGroup) {
        var value = applying(to: Adjustments())
        value.resetValues(for: group, to: Adjustments())
        self = value.pixels
        if group == .color { warmth = 0 }
        if group == .detail { blur = 0 }
    }
    public func effective() -> Self {
        var result = self
        for group in disabledSections { result.resetValues(for: group) }
        return result
    }
    public func applying(to base: Adjustments) -> Adjustments {
        var value = base; value.pixels = self; return value
    }
    public func validated() throws -> Self {
        let ranges: [(Double, ClosedRange<Double>)] = [
            (exposure, -5...5), (contrast, -100...100), (highlights, -100...100),
            (shadows, -100...100), (whites, -100...100), (blacks, -100...100),
            (tint, -150...150), (vibrance, -100...100),
            (saturation, -100...100), (clarity, -100...100), (texture, -100...100), (dehaze, -100...100), (sharpness, -100...100),
            (noiseReduction, 0...100), (colorNoiseReduction ?? noiseReduction, 0...100),
            (sharpenRadius, 0.5...3), (sharpenDetail, 0...100), (sharpenMasking, 0...100), (vignette, 0...100),
            (vignetteRadius, 0...1), (vignetteSoftness, 0...1)
        ]
        guard ranges.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }),
              warmth.isFinite, (-100...100).contains(warmth), blur.isFinite, (0...100).contains(blur) else {
            throw EditorError.invalidDocument(L10n.tr("Adjustment values are out of range."))
        }
        guard selectiveColors.count == 8, selectiveColors.allSatisfy({
            $0.hue.isFinite && (-60...60).contains($0.hue) && $0.saturation.isFinite && (-100...100).contains($0.saturation)
            && $0.luminance.isFinite && (-100...100).contains($0.luminance) && $0.range.isFinite && (0.2...2).contains($0.range)
        }) else { throw EditorError.invalidDocument(L10n.tr("Invalid selective color adjustments.")) }
        try curve.validate(); try redCurve.validate(); try greenCurve.validate(); try blueCurve.validate()
        try parametricCurve.validate(); try splitToning.validate(); try calibration.validate()
        try blackWhiteMixer.validate(); try grain.validate()
        try check([curveSaturation, colorNoiseDetail, colorNoiseSmoothness], in: 0...100)
        try defringe.validate(); try postCropVignette.validate()
        guard pointColors.count <= 16 else { throw EditorError.invalidDocument(L10n.tr("Too many point colors.")) }
        for point in pointColors { try point.validate() }
        return self
    }
}

public typealias LocalAdjustments = PixelAdjustments
