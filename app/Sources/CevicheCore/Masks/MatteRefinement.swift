import Foundation
import CoreImage

/// How a stored model output becomes a full-resolution matte. Masks keep the small model output and
/// refine it against the photo when rendering, so storage stays tiny and every output size (preview,
/// zoomed detail, export) gets edges refined at its own resolution.
public enum MaskRefinement: Codable, Equatable, Sendable {
    /// Joint bilateral upsampling guided by the photo (Depth, Scene).
    case edgeAware
    /// A He et al. guided filter on the encoded sRGB blue channel;
    /// `radius` is a fraction of the long edge. The result is sRGB-encoded, like the
    /// full-resolution mattes, so every Sky mask selects alike.
    case guided(radius: Double, epsilon: Double)

    /// Sky masks: 20 px box radius at a 3000-pixel long edge, ε = 0.01. It puts the network's low-resolution edge on
    /// the photo's skyline at whatever size the mask renders.
    public static let sky = MaskRefinement.guided(radius: 20.0 / 3000, epsilon: 0.01)

    func apply(_ small: CIImage, guide: CIImage) -> CIImage {
        let extent = guide.extent
        let origin = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        switch self {
        case .edgeAware:
            return guide.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: ["inputSmallImage": origin, "inputSpatialSigma": 3, "inputLumaSigma": 0.15])
                .applyingFilter("CIColorClamp").cropped(to: extent)
        case .guided(let radiusFraction, let epsilon):
            let p = origin.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: extent.height / origin.extent.height, kCIInputAspectRatioKey: (extent.width / extent.height) / (origin.extent.width / origin.extent.height)])
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
            // The guide is the encoded (sRGB curve) blue channel, as the model's input was.
            let blue = guide.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let radius = max(1, radiusFraction * max(extent.width, extent.height))
            // CIBoxBlur's "radius" is the box's full width (rounded down to odd: 12 → 11 taps, 13 → 13), so a
            // half-width r takes 2r + 1.
            func box(_ image: CIImage) -> CIImage { image.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: 2 * radius.rounded() + 1]).cropped(to: extent) }
            // Alpha stays 1 throughout (Core Image premultiplies by alpha between filters), and the kernels declare
            // four-channel float output: with a single-channel input, Core Image would otherwise keep one channel.
            let moments = Self.statistics.apply(extent: extent, roiCallback: { _, r in r }, arguments: [blue, p])!     // I, I², p
            let product = Self.cross.apply(extent: extent, roiCallback: { _, r in r }, arguments: [blue, p])!          // I·p
            let ab = Self.coefficients.apply(extent: extent, roiCallback: { _, r in r }, arguments: [box(moments), box(product), epsilon])!
            let refined = Self.output.apply(extent: extent, roiCallback: { _, r in r }, arguments: [blue, box(ab)])!
            return refined.applyingFilter("CILinearToSRGBToneCurve").applyingFilter("CIColorClamp").cropped(to: extent)
        }
    }
    /// Each kernel is compiled from its own source: Core Image's intermediate cache can confuse kernels that
    /// share one library and receive identical inputs, returning one's blurred result for the other.
    /// Fixed source: a kernel that doesn't compile is a bug.
    private static func compile(_ name: String, _ signature: String, _ body: String) -> CIKernel {
        try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 \(name)(\(signature)) { \(body) }
        """)[0]
    }
    private static let statistics = compile("guidedStatistics", "coreimage::sample_t guide, coreimage::sample_t p", "float i = guide.b; return float4(i, i * i, p.r, 1.0);")
    private static let cross = compile("guidedCross", "coreimage::sample_t guide, coreimage::sample_t p", "return float4(float3(guide.b * p.r), 1.0);")
    private static let coefficients = compile("guidedCoefficients", "coreimage::sample_t m, coreimage::sample_t ip, float epsilon",
                                              "float variance = max(0.0, m.g - m.r * m.r), covariance = ip.r - m.r * m.b; float a = covariance / (variance + epsilon); return float4(a, m.b - a * m.r, 0.0, 1.0);")
    private static let output = compile("guidedOutput", "coreimage::sample_t guide, coreimage::sample_t ab", "return float4(float3(clamp(ab.r * guide.b + ab.g, 0.0, 1.0)), 1.0);")
}
