import CoreImage
import simd
import Foundation

/// Actor-confined caches. The cube's encoded sRGB domain matches the existing curve editor.
final class FilmRenderer {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private var curveKey: [ToneCurve] = []
    private var parametricKey = ParametricCurve()
    private var curveData: Data?
    private var curveSaturationKey = 100.0
    private var hdrCurveKey: (curves: [ToneCurve], parametric: ParametricCurve)?
    private var hdrCurveTable: CIImage?
    private var calibrationKey = PrimaryCalibration()
    private var calibrationData: Data?
    private var toningKey = SplitToning()
    private var toningData: Data?
    private var mixerKey = BlackWhiteMixer()
    private var mixerData: Data?
    private var grainKey: UInt32?
    private var grainImage: CIImage?

    private func cube(_ image: CIImage, _ data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 64, "inputCubeData": data, "inputColorSpace": space])
    }
    func calibrate(_ image: CIImage, settings: PrimaryCalibration) -> CIImage {
        guard !settings.isIdentity else { return image }
        if calibrationData == nil || calibrationKey != settings {
            calibrationKey = settings; calibrationData = FilmMath.cube(transform: settings.transform)
        }
        return cube(image, calibrationData!)
    }
    func curves(_ image: CIImage, settings: Adjustments) -> CIImage {
        let curves = [settings.curve, settings.redCurve, settings.greenCurve, settings.blueCurve]
        guard curves.contains(where: { !$0.isIdentity }) || !settings.parametricCurve.isIdentity else { return image }
        if curveData == nil || curveKey != curves || parametricKey != settings.parametricCurve || curveSaturationKey != settings.curveSaturation {
            curveKey = curves; parametricKey = settings.parametricCurve; curveSaturationKey = settings.curveSaturation
            // The SDR cube clips at SDR white; HDR uses `hdrCurves`. Curves run on sRGB-encoded ProPhoto RGB:
            // the parametric and master curves hue-preserving, then each channel's own curve.
            let parametric = settings.parametricCurve, saturation = settings.curveSaturation / 100
            let tables = curves.map { $0.table() }
            curveData = FilmMath.cube { rgb in
                let p = FilmMath.encode(FilmMath.clamp(FilmMath.toProPhoto * FilmMath.decode(rgb)))
                let shaped = parametric.isIdentity ? p : FilmMath.huePreserving(p) { parametric.value(at: $0) }
                let master = FilmMath.refineSaturation(shaped, FilmMath.huePreserving(shaped) { FilmMath.lookup(tables[0], $0) }, amount: saturation)
                let channels = SIMD3(FilmMath.lookup(tables[1], master.x), FilmMath.lookup(tables[2], master.y), FilmMath.lookup(tables[3], master.z))
                return FilmMath.encode(FilmMath.clamp(FilmMath.fromProPhoto * FilmMath.decode(channels)))
            }
        }
        return cube(image, curveData!)
    }
    /// Curves over the extended range, including points beyond SDR white.
    func hdrCurves(_ image: CIImage, settings: Adjustments) -> CIImage {
        let curves = [settings.curve, settings.redCurve, settings.greenCurve, settings.blueCurve]
        guard curves.contains(where: { !$0.isIdentity }) || !settings.parametricCurve.isIdentity else { return image }
        if hdrCurveTable == nil || hdrCurveKey?.curves != curves || hdrCurveKey?.parametric != settings.parametricCurve {
            hdrCurveKey = (curves, settings.parametricCurve); hdrCurveTable = HDRCurves.table(settings)
        }
        return HDRCurves.apply(image, table: hdrCurveTable!, saturation: settings.curveSaturation / 100)
    }
    func monochrome(_ image: CIImage, settings: BlackWhiteMixer) -> CIImage {
        if mixerData == nil || mixerKey != settings {
            mixerKey = settings; mixerData = FilmMath.cube(transform: settings.transform)
        }
        return cube(image, mixerData!)
    }
    func tone(_ image: CIImage, settings: SplitToning) -> CIImage {
        guard !settings.isIdentity else { return image }
        if toningData == nil || toningKey != settings {
            toningKey = settings
            let curves = ColorGradeCurves(settings)
            toningData = FilmMath.cube { curves?.transform($0) ?? $0 }
        }
        return cube(image, toningData!)
    }

    private static let textureKernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 texturePixel(coreimage::sample_t s, coreimage::sample_t fine, coreimage::sample_t coarse, float gain) {
        const float3 weights = float3(0.2126, 0.7152, 0.0722);
        float y = dot(s.rgb, weights);
        if (y <= 0.00001) return s;
        // The band is taken on gamma-encoded luminance so shadows and highlights carry detail alike; large differences
        // are edges rather than texture, and are limited so they do not halo.
        float band = pow(max(dot(fine.rgb, weights), 0.0), 1.0 / 2.2) - pow(max(dot(coarse.rgb, weights), 0.0), 1.0 / 2.2);
        band = 0.04 * tanh(band / 0.04);
        // As a ratio, so pixels without detail come back exactly as they were.
        float ratio = pow(max(0.0, 1.0 + gain * band / pow(y, 1.0 / 2.2)), 2.2);
        return float4(s.rgb * ratio, s.a);
    }
    """)[0]
    /// Contrast in medium-fine detail, between noise and the broad local contrast of clarity, on luminance only so colors
    /// keep their hue. Negative values smooth that detail, as for skin, and keep the finest grain. The scales follow the
    /// image's width, so a preview and the export show the same structures.
    static func texture(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        func blurred(_ radius: Double) -> CIImage {
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: image.extent)
        }
        let width = image.extent.width
        let gain = amount > 0 ? amount / 100 : amount / 100 * 0.85
        return textureKernel.apply(extent: image.extent, roiCallback: { _, r in r },
                                   arguments: [image, blurred(max(0.3, width * 0.00025)), blurred(max(1, width * 0.0012)), gain])!
    }
    private static let dehazeKernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 dehazePixel(coreimage::sample_t s, coreimage::sample_t veil, coreimage::sample_t haze, float strength) {
        float3 c = pow(max(s.rgb, 0.0), 1.0 / 2.2);
        if (strength > 0.0) {
            // Haze is light added over the scene, so it is taken off as a lifted black point that keeps white; deep
            // shadows hold little of it and are spared.
            float v = max(veil.r, 0.0);
            float k = min(0.9, strength * v * smoothstep(0.05, 0.6, v));
            c = max(0.0, (c - k) / (1.0 - k));
        } else {
            c = mix(c, float3(0.35 + 0.5 * max(haze.r, 0.0)), -strength);
        }
        return float4(pow(c, 2.2), s.a);
    }
    """)[0]
    /// Removes or adds atmospheric haze. The haze at each point is estimated from the darkest channel nearby, which
    /// clear scenes keep near black, and follows the photo's edges so skylines do not halo. Its scales follow the image's
    /// width, so a preview, the export and a zoomed region agree; nothing is measured over the whole photo.
    static func dehaze(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        // The haze map is built on gamma-encoded values, where a dark sky's edges are as distinct as a bright one's.
        let width = image.extent.width, encoded = image.applyingFilter("CILinearToSRGBToneCurve"), source = encoded.clampedToExtent()
        let veil: CIImage, haze: CIImage
        if amount > 0 {
            // An opening: the minimum takes small bright details for scene rather than haze, and the maximum after it
            // returns large regions such as sky to their own edges, so the sky beside a dark skyline keeps its haze.
            let spread = max(1, width * 0.0075)
            let darkest = source.applyingFilter("CIMinimumComponent").applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": spread])
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": spread])
            let radius = max(2, width * 0.03)
            // The guided filter needs finite inputs, and given infinite ones returns an empty image; they reach past the
            // photo by twice its radius, repeating the border, so the edges are not filtered against transparency.
            let padded = image.extent.insetBy(dx: -2 * radius, dy: -2 * radius)
            veil = darkest.cropped(to: padded).applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": source.cropped(to: padded), "inputRadius": radius, "inputEpsilon": 0.001])
            haze = veil
        } else {
            haze = source.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0]).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(2, width * 0.02)])
            veil = haze
        }
        let strength = amount > 0 ? amount / 100 * 0.7 : amount / 100 * 0.55
        return dehazeKernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image, veil.cropped(to: image.extent), haze.cropped(to: image.extent), strength])!
    }
    /// Negative clarity blends a broad blur; positive clarity retains the existing local contrast.
    static func clarity(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let radius = max(2, image.extent.width * 0.006)
        if amount > 0 {
            return image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": radius, "inputIntensity": amount / 100]).cropped(to: image.extent)
        }
        let soft = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius]).cropped(to: image.extent)
        return blend(soft, over: image, amount: -amount / 150)
    }
    static func blend(_ image: CIImage, over background: CIImage, amount: Double) -> CIImage {
        let mask = CIImage(color: CIColor(red: amount, green: amount, blue: amount)).cropped(to: background.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
    }
    static func sharpen(_ image: CIImage, settings: Adjustments, scale: Double) -> CIImage {
        guard settings.sharpness > 0 else { return image }
        let base = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": settings.sharpness / 100]).cropped(to: image.extent)
        var sharpened = base
        // Extra controls vary continuously around the legacy defaults.
        if settings.sharpenRadius != 1 {
            let broad = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(0.1, settings.sharpenRadius * scale), "inputIntensity": settings.sharpness / 100]).cropped(to: image.extent)
            sharpened = blend(broad, over: base, amount: min(1, abs(settings.sharpenRadius - 1)))
        }
        if settings.sharpenDetail > 25 {
            sharpened = sharpened.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(0.1, 0.4 * scale), "inputIntensity": settings.sharpness / 100 * (settings.sharpenDetail - 25) / 75]).cropped(to: image.extent)
        } else if settings.sharpenDetail < 25 {
            sharpened = blend(image, over: sharpened, amount: (25 - settings.sharpenDetail) / 50)
        }
        guard settings.sharpenMasking > 0 else { return sharpened }
        let threshold = settings.sharpenMasking / 125
        let mask = image.applyingFilter("CIEdges", parameters: ["inputIntensity": 3])
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
            .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 5, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 5, w: 0), "inputBiasVector": CIVector(x: -threshold, y: -threshold, z: -threshold, w: 0)])
            .applyingFilter("CIColorClamp").cropped(to: image.extent)
        let masked = sharpened.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        return blend(masked, over: sharpened, amount: settings.sharpenMasking / 100)
    }
    func grain(_ image: CIImage, settings: FilmGrain, scale: Double) -> CIImage {
        guard settings.amount > 0 else { return image }
        if grainKey != settings.seed || grainImage == nil {
            grainKey = settings.seed
            // Fixed, persisted seed: previews, exports, undo and reopen use the same texture.
            var state = UInt64(settings.seed) + 1
            var bytes = [UInt8](); bytes.reserveCapacity(512 * 512 * 4)
            for _ in 0..<(512 * 512) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let value = UInt8(truncatingIfNeeded: state >> 32)
                bytes.append(contentsOf: [value, value, value, 255])
            }
            grainImage = CIImage(bitmapData: Data(bytes), bytesPerRow: 512 * 4, size: CGSize(width: 512, height: 512), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        var noise = grainImage!.applyingFilter("CIAffineTile")
        let blur = (100 - settings.roughness) / 100 * 1.1
        if blur > 0 { noise = noise.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blur]) }
        let size = (0.6 + settings.size / 20) * scale
        noise = noise.transformed(by: CGAffineTransform(scaleX: size, y: size)).cropped(to: image.extent)
        let opaque = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let textured = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: opaque])
        let result = Self.blend(textured, over: opaque, amount: settings.amount / 100)
        // Noise is opaque; restore the original alpha, including cutouts and transparent source pixels.
        return result.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: image])
    }
}
