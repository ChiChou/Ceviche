import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Output headroom is in stops above SDR white, independent of the display.
public struct HDRSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var headroom = 4.0
    public var sdrExposure = 0.0
    public init() {}
    public func validate() throws {
        guard headroom.isFinite, (0...10).contains(headroom), sdrExposure.isFinite, (-5...5).contains(sdrExposure) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid HDR settings."))
        }
    }
}

/// Kernels operate in the context's extended linear working space. Bounded color
/// operators receive a hue-preserving normalization and regain the original headroom.
/// This is Ceviche's HDR extension of SDR operators, not another converter's process version.
enum HDRRenderer {
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    /// Each kernel is compiled from a Metal source of its own. Core Image keys the programs it stitches (a scale, the
    /// kernel, a crop) by their library and shape, not by the function's name, so two kernels of one library with
    /// the same shape around them shared one program: `measureHDR` could run as `lightHDR` ("Argument count
    /// mismatch for program (ci_affine_measureHDR_crop)"), measure nonsense and tone map the photo to black.
    private static func kernel(_ source: String) -> CIKernel {
        try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        \(source)
        """)[0]
    }
    private static let measure = kernel("""
    extern "C" [[ stitchable ]] float4 measureHDR(coreimage::sample_t s) {
        return float4(s.a > 0.000001 ? s.rgb / s.a : float3(0.0), 1.0);
    }
    """)
    private static let normalize = kernel("""
    extern "C" [[ stitchable ]] float4 normalizeHDR(coreimage::sample_t s) {
        float3 c = s.rgb / max(s.a, 0.000001);
        float peak = max(1.0, max(c.r, max(c.g, c.b)));
        return float4(c / peak * s.a, s.a);
    }
    """)
    private static let restore = kernel("""
    extern "C" [[ stitchable ]] float4 restoreHDR(coreimage::sample_t s, coreimage::sample_t original) {
        float3 c = original.rgb / max(original.a, 0.000001);
        float peak = max(1.0, max(c.r, max(c.g, c.b)));
        return float4(s.rgb * peak, s.a);
    }
    """)
    private static let lighten = kernel("""
    extern "C" [[ stitchable ]] float4 lightHDR(coreimage::sample_t s, float4 tones, float contrast, float saturation) {
        float3 c = s.rgb / max(s.a, 0.000001);
        float y = max(0.0, dot(c, float3(0.2126, 0.7152, 0.0722)));
        float hi = smoothstep(0.18, 1.0, y), white = smoothstep(0.7, 4.0, y);
        float shadow = 1.0 - smoothstep(0.0, 0.25, y);
        float black = 1.0 - smoothstep(0.0, 0.06, y);
        float ev = tones.x * hi + tones.y * shadow + tones.z * white + tones.w * black;
        // Contrast pivots about middle gray without channel-wise clipping.
        ev += contrast * clamp(log2(max(y, 0.000001) / 0.18), -8.0, 8.0);
        c = mix(float3(y), c, saturation) * exp2(ev);
        return float4(c * s.a, s.a);
    }
    """)
    static func normalized(_ image: CIImage) -> CIImage {
        normalize.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])!
    }
    static func bounded(_ image: CIImage, enabled: Bool, operation: (CIImage) -> CIImage) -> CIImage {
        guard enabled else { return operation(image) }
        let normalized = normalized(image)
        let edited = operation(normalized)
        if edited === normalized { return image }
        return restore.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [edited, image])!
    }
    static func light(_ image: CIImage, settings a: PixelAdjustments) -> CIImage {
        lighten.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image,
            CIVector(x: a.highlights / 50, y: a.shadows / 50, z: a.whites / 50, w: a.blacks / 50),
            a.contrast / 200, a.monochrome ? 1 : 1 + a.saturation / 100])!
    }
    /// Measure developed pixels, not the source's stale metadata: exposure, masks and
    /// curves can all change headroom. The reduction avoids a full CPU image readback.
    static func headroom(_ image: CIImage, context: CIContext) -> Float {
        let opaque = measure.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])!
        let maximum = opaque.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            context.render(maximum, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return max(1, pixel.prefix(3).filter(\.isFinite).max() ?? 1)
    }
    static func histogram(_ image: CIImage, context: CIContext, stops: Double) -> [[Double]] {
        let small = RawRenderer.scaled(image, limit: 256), width = Int(small.extent.width), height = Int(small.extent.height)
        guard width > 0, height > 0 else { return [] }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        var bins = Array(repeating: Array(repeating: 0.0, count: 128), count: 4)
        func bin(_ v: Double) -> Int? {
            guard v.isFinite else { return nil }
            let position = v <= 1 ? (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) * 0.5 : 0.5 + log2(v) / max(1, stops) * 0.5
            return min(127, max(0, Int(position * 127)))
        }
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0.000001 {
            var linear = SIMD3<Double>()
            for channel in 0..<3 {
                let v = Double(pixels[i + channel] / pixels[i + 3])
                linear[channel] = v
                if let index = bin(v) { bins[channel][index] += 1 }
            }
            if let index = bin(0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z) { bins[3][index] += 1 }
        }
        return RawRenderer.normalizedHistogram(bins)
    }
    static func toneMap(_ image: CIImage, source: Float, target: Float = 1) -> CIImage {
        guard source > target else { return tagged(image, headroom: max(1, source)) }
        let filter = CIFilter.toneMapHeadroom()
        filter.inputImage = image; filter.sourceHeadroom = source; filter.targetHeadroom = target
        return tagged(filter.outputImage ?? image, headroom: target)
    }
    /// The image carrying `headroom` as its `contentHeadroom`. A `CIImage` can only be tagged on macOS 26; before that
    /// the headroom is measured again from the pixels when the image is rendered (`CIContext.cgImage(_:from:format:colorSpace:hdr:)`).
    private static func tagged(_ image: CIImage, headroom: Float) -> CIImage {
        if #available(macOS 26, *) { return image.settingContentHeadroom(headroom) }
        return image
    }
    static func output(_ image: CIImage, settings: HDRSettings, context: CIContext, sdr: Bool) -> CIImage {
        let limited = toneMap(image, source: headroom(image, context: context), target: Float(pow(2, settings.headroom)))
        guard sdr else { return limited }
        let exposed = limited.applyingFilter("CIExposureAdjust", parameters: ["inputEV": settings.sdrExposure])
        return toneMap(exposed, source: headroom(exposed, context: context))
    }
}
