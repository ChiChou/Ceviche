import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Glow on linear light: what lies above the threshold spreads and is added back as light, so bright sources glow and
/// the shadows around them lift a little. Each style spreads it its own way (see `Glow.Style`). The spread is worked
/// at a quarter of the size, and sized from the long side, so previews and exports match.
enum GlowRenderer {
    private static let quarter = 0.25

    static func apply(_ glow: Glow?, to image: CIImage) -> CIImage {
        guard let glow, glow.enabled, glow.amount > 0 else { return image }
        let extent = image.extent, longSide = max(extent.width, extent.height)
        guard longSide > 8 else { return image }
        let amount = glow.amount / 100, threshold = glow.threshold / 100
        // Spread lengths in quarter-size pixels.
        let small = longSide * quarter
        let angle = glow.angle * .pi / 180
        func up(_ halo: CIImage) -> CIImage { halo.transformed(by: CGAffineTransform(scaleX: 1 / quarter, y: 1 / quarter)).cropped(to: extent) }

        switch glow.style {
        case .halo:
            // A short core and a long tail.
            let bright = above(threshold, image), radius = glow.radius * small
            let halo = sum([(blurred(bright, radius * 0.35), 0.7), (blurred(bright, radius), 0.3)])
            return add(image, up(halo), gain: amount * 1.5)
        case .mist:
            // A mist filter starts lower and reaches further, and the highlights themselves soften: half of the light it
            // spreads leaves them, so they lose their edge as well as glow.
            let start = threshold * 0.75, bright = above(start, image), radius = glow.radius * small
            let halo = sum([(blurred(bright, radius * 0.5), 0.4), (blurred(bright, radius), 0.35), (blurred(bright, radius * 2), 0.25)])
            return add(image, up(halo), gain: amount * 1.1, removing: amount * 0.5, above: start)
        case .halation:
            // Light that reaches the film base reflects back into the red-sensitive layer, so the fringe follows
            // brightness, not colour: a blue sign gets a red halo. A tight red core and a wider orange tail.
            let bright = luminance(above(threshold, image)), radius = glow.radius * small
            let halo = sum([(tinted(blurred(bright, radius * 0.25), 1, 0.2, 0.04), 0.75), (tinted(blurred(bright, radius * 0.7), 1, 0.45, 0.15), 0.25)])
            return add(image, up(halo), gain: amount * 2)
        case .motion:
            // The lights smear the most; the scene leaves a faint ghost along the same path, light moved rather than added.
            let length = small * Glow.reach(.motion, size: glow.size)
            let ghost = up(smeared(image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: quarter, y: quarter)), length, angle))
            let moved = ghost.applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: image, kCIInputAmountKey: min(1, amount * 0.3)])
            let bright = above(threshold, image, keepingHue: true)
            let trails = sum([(smeared(bright, length, angle), 0.5), (smeared(bright, length / 3, angle), 0.5)])
            return add(moved, up(trails), gain: amount)
        case .streak:
            // Only the brightest points streak. Lines of a third, a ninth and a 27th of the length on top of the full
            // one make each streak brightest at its source and fade along it.
            let start = threshold + (1 - threshold) * 0.6, bright = above(start, image, keepingHue: true)
            let length = small * Glow.reach(.streak, size: glow.size)
            let lines = sum([1.0, 3, 9, 27].enumerated().map { (smeared(bright, length / $1, angle), [0.15, 0.2, 0.3, 0.35][$0]) })
            return add(image, up(lines), gain: amount * 2)
        }
    }

    /// The light above `threshold`, on a clamped quarter-size copy. Per channel, or `keepingHue`, by the brightest
    /// channel, so a warm light high above the threshold still smears warm rather than only in red.
    private static func above(_ threshold: Double, _ image: CIImage, keepingHue: Bool = false) -> CIImage {
        if keepingHue {
            return hueKept.apply(extent: image.extent, arguments: [image, Float(threshold)])!
                .clampedToExtent().transformed(by: CGAffineTransform(scaleX: quarter, y: quarter))
        }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -threshold, y: -threshold, z: -threshold, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1)])
            .clampedToExtent().transformed(by: CGAffineTransform(scaleX: quarter, y: quarter))
    }
    private static func blurred(_ image: CIImage, _ sigma: Double) -> CIImage { image.applyingGaussianBlur(sigma: max(0.5, sigma)) }
    /// Spread evenly along a line through each point, `length` either side, `angle` in radians.
    private static func smeared(_ image: CIImage, _ length: Double, _ angle: Double) -> CIImage {
        image.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: max(1, length), kCIInputAngleKey: angle])
    }
    private static func sum(_ layers: [(CIImage, Double)]) -> CIImage {
        layers.map { tinted($0.0, $0.1, $0.1, $0.1) }.reduce(nil) { (total: CIImage?, layer) in
            total.map { layer.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? layer
        }!
    }
    private static func tinted(_ image: CIImage, _ r: Double, _ g: Double, _ b: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    /// Each channel set to the light's Rec. 709 luminance.
    private static func luminance(_ image: CIImage) -> CIImage {
        let y = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": y, "inputGVector": y, "inputBVector": y, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    /// Adds the halo's light to the photo, keeping the photo's coverage; `removing` takes that share of the light
    /// above `above` out of the photo first, for a style that moves light rather than only adding it.
    private static func add(_ image: CIImage, _ halo: CIImage, gain: Double, removing: Double = 0, above threshold: Double = 0) -> CIImage {
        kernel.apply(extent: image.extent, arguments: [image, halo, Float(gain), Float(removing), Float(threshold)])!
    }
    private static let hueKept = try! CIColorKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 glowAboveKeepingHue(coreimage::sample_t photo, float threshold) {
            float peak = max(max(photo.r, photo.g), photo.b);
            return float4(max(photo.rgb, 0.0) * (max(peak - threshold, 0.0) / max(peak, 1e-6)), photo.a);
        }
        """)[0] as! CIColorKernel
    private static let kernel = try! CIColorKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 glowAdd(coreimage::sample_t photo, coreimage::sample_t halo, float gain, float removing, float threshold) {
            float3 bright = max(photo.rgb - threshold * photo.a, 0.0);
            return float4(photo.rgb - bright * removing + halo.rgb * gain * photo.a, photo.a);
        }
        """)[0] as! CIColorKernel
}
