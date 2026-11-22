import CoreGraphics
import CoreImage

/// Shows sensor dust the way Visualize Spots does in other RAW editors: a black map with what is darker than its
/// surroundings in white, so soft spots in a sky stand out as dots. Dust only ever darkens, so this is a black
/// top-hat on log luminance (a morphological closing, less the image), which leaves no halo along a bright subject's
/// edge as a blurred background would.
public enum DustVisualizer {
    /// What the map shows: how strongly, which spots, and how much noise is smoothed away first.
    public struct Options: Equatable, Sendable {
        /// 0 to 1: from a 7 % darkening showing as mid-gray at 0 to a 0.4 % one at 1.
        public var strength = 0.5
        /// The largest spot radius shown whole, in pixels on a frame whose long edge is
        /// `DustFinder.classicSize`; bigger ones show
        /// only their edge, and broad shading not at all.
        public var size = 80.0
        /// Blur before measuring, in pixels on that frame: more hides noise and the smallest spots.
        public var smoothing = 5.0
        public init(strength: Double = 0.5, size: Double = 80, smoothing: Double = 5) {
            self.strength = strength; self.size = size; self.smoothing = smoothing
        }
    }

    /// The map for an image showing the photo, or part of it, with the whole photo's long edge `photoSize` pixels.
    public static func render(_ image: CGImage, photoSize: Double, options: Options, context: CIContext) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = photoSize / DustFinder.classicSize
        let source = CIImage(cgImage: image), extent = source.extent
        let hat = topHat(source, smoothing: options.smoothing * scale, radius: max(1, options.size * scale))
        let gain = 5 * pow(2, min(1, max(0, options.strength)) * 4)
        let map = kernels.display.apply(extent: extent, arguments: [hat, gain])!
        return context.createCGImage(map, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// How far each pixel lies below the morphological closing of its neighbourhood, in stops (red channel), after a
    /// Gaussian blur of `smoothing` and with a closing of `radius`, both in pixels of `source`; green holds the blurred
    /// log2 luminance itself. `DustFinder` searches it.
    static func topHat(_ source: CIImage, smoothing: Double, radius: Double) -> CIImage {
        let extent = source.extent
        var smoothed = kernels.luminance.apply(extent: extent, arguments: [source])!.clampedToExtent()
        if smoothing >= 0.3 { smoothed = smoothed.applyingGaussianBlur(sigma: smoothing) }
        let closed = smoothed.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius])
        return kernels.difference.apply(extent: extent, arguments: [closed.cropped(to: extent), smoothed.cropped(to: extent)])!
    }

    private static let kernels: (luminance: CIColorKernel, difference: CIColorKernel, display: CIColorKernel) = {
        let all = try! CIColorKernel.kernels(withMetalString: """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            extern "C" [[ stitchable ]] float4 dustLogLuminance(coreimage::sample_t s) {
                float l = log2(max(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-4));
                return float4(l, l, l, 1);
            }
            extern "C" [[ stitchable ]] float4 dustTopHat(coreimage::sample_t closed, coreimage::sample_t image) {
                return float4(max(closed.r - image.r, 0.0), image.r, 0, 1);
            }
            extern "C" [[ stitchable ]] float4 dustDisplay(coreimage::sample_t hat, float gain) {
                // Raised to 2.2 to undo the sRGB encoding (roughly), so gray on screen follows the darkening.
                float v = pow(clamp(gain * hat.r, 0.0, 1.0), 2.2);
                return float4(v, v, v, 1);
            }
            """) as! [CIColorKernel]
        return (all.first { $0.name == "dustLogLuminance" }!, all.first { $0.name == "dustTopHat" }!, all.first { $0.name == "dustDisplay" }!)
    }()
}
