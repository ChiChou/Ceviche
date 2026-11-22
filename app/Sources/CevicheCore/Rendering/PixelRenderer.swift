import CoreImage

/// Shared post-decode processing. RAW development remains in RawRenderer.
final class PixelRenderer {
    /// Luminance noise reduction, then chroma-only smoothing over the current luminance; `chroma` nil means the one
    /// slider smooths both. Shared by the RAW development and local adjustments.
    static func noiseReduced(_ image: CIImage, luma: Double, chroma: Double?, hdr: Bool) -> CIImage {
        guard luma > 0 || (chroma ?? 0) > 0 else { return image }
        return HDRRenderer.bounded(image, enabled: hdr) { source in
            var result = source
            if luma > 0 {
                let smooth = source.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": luma / 1000, "inputSharpness": 0])
                result = chroma == nil ? smooth : smooth.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: source])
            }
            if let chroma, chroma > 0 {
                let smooth = result.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": chroma / 1000, "inputSharpness": 0])
                result = smooth.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: result])
            }
            return result
        }
    }
    private let filmRenderer = FilmRenderer()
    private let extendedRenderer = ExtendedRenderer()
    private var cachedSelective: ([SelectiveColorAdjustment], Data)?
    private let colorSpace = RGBProfile.sRGB.space
    func apply(_ settings: PixelAdjustments, to input: CIImage, scale: Double, local: Bool, hdr: Bool = false) -> CIImage {
        let a = settings.effective()
        let film = a.applying(to: Adjustments())
        var image = beforeDefringe(a, film: film, input: input, local: local, hdr: hdr)
        image = ExtendedRenderer.defringe(image, settings: a.defringe, scale: scale)
        image = HDRRenderer.bounded(image, enabled: hdr) { filmRenderer.tone($0, settings: a.splitToning) }
        let extent = image.extent
        image = FilmRenderer.texture(image, amount: a.texture)
        image = FilmRenderer.clarity(image, amount: a.clarity)
        if local { image = Self.noiseReduced(image, luma: a.noiseReduction, chroma: a.colorNoiseReduction, hdr: hdr) }
        if a.sharpness < 0 {
            let softened = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(1, input.extent.width * 0.001)]).cropped(to: input.extent)
            image = FilmRenderer.blend(softened, over: image, amount: -a.sharpness / 100)
        }
        image = FilmRenderer.sharpen(image, settings: film, scale: scale)
        if a.vignette > 0 {
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY), "inputIntensity": a.vignette / 50,
                "inputRadius": min(extent.width, extent.height) * (0.05 + a.vignetteRadius * 0.8),
                "inputFalloff": max(0.01, a.vignetteSoftness)
            ])
        }
        image = HDRRenderer.bounded(image, enabled: hdr) { filmRenderer.grain($0, settings: a.grain, scale: scale) }
        if a.blur > 0 { image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": a.blur / 100 * min(input.extent.width, input.extent.height) * 0.03]).cropped(to: input.extent) }
        if local { image = ExtendedRenderer.vignette(image, settings: a.postCropVignette) }
        return image
    }
    func defringeInput(_ settings: PixelAdjustments, from input: CIImage, local: Bool, hdr: Bool) -> CIImage {
        let a = settings.effective()
        return beforeDefringe(a, film: a.applying(to: Adjustments()), input: input, local: local, hdr: hdr)
    }
    private func beforeDefringe(_ a: PixelAdjustments, film: Adjustments, input: CIImage, local: Bool, hdr: Bool) -> CIImage {
        var image = input
        if local {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": a.exposure])
            if a.warmth != 0 || a.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500 + a.warmth * 30, y: a.tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
            }
        }
        image = HDRRenderer.bounded(image, enabled: hdr) { filmRenderer.calibrate($0, settings: a.calibration) }
        // Before the tone controls, as haze is part of the scene they then shape.
        image = FilmRenderer.dehaze(image, amount: a.dehaze)
        if hdr { image = HDRRenderer.light(image, settings: a) } else {
            if a.shadows != 0 {
                image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1, "inputShadowAmount": a.shadows / 100, "inputRadius": 0])
            }
            if a.highlights != 0 || a.whites != 0 {
                // CIHighlightShadowAdjust can only pull highlights down, so both sliders use a tone curve. The curve
                // runs on sRGB-encoded values (Apple's own transfer filters) so its points sit where the eye sees them;
                // in the linear working space the top three points would all lie above 54% gray.
                let h = a.highlights / 100, w = a.whites / 100
                let upper = 0.75 + 0.14 * h + 0.08 * w
                let points = [0, 0.25, 0.5 + 0.06 * h, upper, max(upper + 0.02, 1 + 0.25 * w)]
                image = image.applyingFilter("CILinearToSRGBToneCurve")
                    .applyingFilter("CIToneCurve", parameters: Self.curveParameters(points))
                    .applyingFilter("CISRGBToneCurveToLinear")
            }
            if a.blacks != 0 {
                let black = a.blacks / 500
                image = image.applyingFilter("CIToneCurve", parameters: Self.curveParameters([black, 0.25 + black * 0.4, 0.5, 0.75, 1]))
            }
            if a.contrast != 0 {
                // An S-curve about middle gray, as RAW editors do it. CIToneCurve evaluates its points on sRGB-encoded
                // values, so 0.5 is perceptual middle gray; CIColorControls would pivot on linear 0.5 (sRGB 74%) and
                // crush every shadow below it. Positive values keep black and white in place; negative values also
                // lift black and lower white, since a flat rendering only reads as less contrast when the endpoints move.
                let c = a.contrast / 100
                let points = c > 0 ? [0, 0.25 - 0.11 * c, 0.5, 0.75 + 0.11 * c, 1]
                                   : [-0.06 * c, 0.25 - 0.07 * c, 0.5, 0.75 + 0.07 * c, 1 + 0.06 * c]
                image = image.applyingFilter("CIToneCurve", parameters: Self.curveParameters(points))
            }
            if a.saturation != 0 && !a.monochrome {
                image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 1 + a.saturation / 100])
            }
        }
        if a.vibrance != 0 && !a.monochrome { image = HDRRenderer.bounded(image, enabled: hdr) { $0.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100]) } }
        image = hdr ? filmRenderer.hdrCurves(image, settings: film) : filmRenderer.curves(image, settings: film)
        if a.monochrome { image = HDRRenderer.bounded(image, enabled: hdr) { filmRenderer.monochrome($0, settings: a.blackWhiteMixer) } }
        if a.selectiveColors.contains(where: { !$0.isIdentity }) {
            if cachedSelective?.0 != a.selectiveColors { cachedSelective = (a.selectiveColors, SelectiveColor.cubeData(a.selectiveColors)) }
            image = HDRRenderer.bounded(image, enabled: hdr) { $0.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 64, "inputCubeData": cachedSelective!.1, "inputColorSpace": colorSpace
            ]) }
        }
        image = HDRRenderer.bounded(image, enabled: hdr) { extendedRenderer.pointColors($0, settings: a.pointColors) }
        return image
    }
    private static func curveParameters(_ values: [Double]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: values.enumerated().map { ("inputPoint\($0.offset)", CIVector(x: Double($0.offset) / 4, y: $0.element)) })
    }
}
