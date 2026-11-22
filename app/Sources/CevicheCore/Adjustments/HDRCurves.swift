import CoreImage
import Foundation

/// Tone curves over the extended HDR range. Each channel is encoded to the curve domain (sRGB up to SDR
/// white, then 1 + log2 v in stops), mapped through a lookup table and decoded, so curve points beyond
/// SDR white shape HDR highlights instead of only scaling them.
enum HDRCurves {
    /// Half the table covers SDR (0…1), half the HDR stops, matching the curve graph and HDR histogram.
    static let samples = 1024
    static let stops = ToneCurve.maximumStops
    static func input(at position: Double) -> Double { position <= 0.5 ? position * 2 : 1 + (position - 0.5) * 2 * stops }

    static let rows = 5
    /// Rows: the parametric curve (SDR range only), master, then red, green and blue.
    static func table(_ settings: Adjustments) -> CIImage {
        let parametric = settings.parametricCurve
        let rows: [(Double) -> Double] = [
            { d in d <= 1 ? parametric.value(at: d) : d }, { settings.curve.value(at: $0) },
            { settings.redCurve.value(at: $0) }, { settings.greenCurve.value(at: $0) }, { settings.blueCurve.value(at: $0) }
        ]
        var data = [Float](); data.reserveCapacity(samples * Self.rows * 4)
        // Core Image puts the first bitmap row at the top, so rows are written last-first: row r sits at y = r.
        for row in rows.reversed() {
            for i in 0..<samples { let v = Float(row(input(at: Double(i) / Double(samples - 1)))); data += [v, v, v, 1] }
        }
        return CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: samples * 16, size: CGSize(width: samples, height: Self.rows), format: .RGBAf, colorSpace: nil)
    }

    static func apply(_ image: CIImage, table: CIImage, saturation: Double) -> CIImage {
        kernel.apply(extent: image.extent, roiCallback: { index, rect in index == 0 ? rect : table.extent },
                     arguments: [image, table, Float(samples), Float(stops), Float(saturation)])!
    }
    static let kernel: CIKernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    static float toCurve(float v) {
        return v <= 1.0 ? (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055) : 1.0 + log2(v);
    }
    static float fromCurve(float d) {
        return d <= 1.0 ? (d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)) : exp2(d - 1.0);
    }
    static float lookup(coreimage::sampler table, float d, float row, float n, float stops) {
        float top = 1.0 + stops;
        float s = d <= 1.0 ? d * 0.5 : 0.5 + (min(d, top) - 1.0) / (2.0 * stops);
        float value = table.sample(table.transform(float2(clamp(s, 0.0, 1.0) * (n - 1.0) + 0.5, row + 0.5))).r;
        // Beyond the table, continue at slope 1 like the curve itself.
        return value + max(0.0, d - top);
    }
    static float3 hueTone(coreimage::sampler table, float3 p, float row, float n, float stops) {
        float lo = min(p.r, min(p.g, p.b)), hi = max(p.r, max(p.g, p.b));
        float a = lookup(table, lo, row, n, stops), b = lookup(table, hi, row, n, stops);
        return hi - lo > 1e-8 ? a + (b - a) * (p - lo) / (hi - lo) : float3(a);
    }
    // Curves run on curve-encoded ProPhoto RGB: the parametric and master curves the DNG RGBTone way
    // (darkest and brightest channels curved, the middle one keeping its relative place), then each channel's own.
    extern "C" [[ stitchable ]] float4 hdrToneCurves(coreimage::sampler source, coreimage::sampler table, float n, float stops, float saturation) {
        const float3x3 toPro = float3x3(float3(0.529345, 0.098374, 0.016883), float3(0.330072, 0.873462, 0.117673), float3(0.140583, 0.028164, 0.865444));
        const float3x3 fromPro = float3x3(float3(2.034075, -0.228813, -0.00857), float3(-0.727334, 1.231731, -0.153286), float3(-0.306742, -0.002918, 1.161856));
        float4 s = source.sample(source.coord());
        float3 c = s.rgb / max(s.a, 0.000001);
        float3 negative = min(c, 0.0);
        float3 linear = max(toPro * max(c, 0.0), 0.0);
        float3 p = float3(toCurve(linear.r), toCurve(linear.g), toCurve(linear.b));
        p = hueTone(table, p, 0.0, n, stops);
        float3 m = hueTone(table, p, 1.0, n, stops);
        if (saturation < 0.999) {
            // Refine saturation: keep the channel differences from before the master curve around its new
            // Rec. 601 luma, scaled down only as far as staying above black needs, then blend.
            float target = dot(m, float3(0.299, 0.587, 0.114));
            float3 offset = p - dot(p, float3(0.299, 0.587, 0.114));
            float low = min(offset.r, min(offset.g, offset.b));
            float scale = low < -1e-6 ? clamp(target / -low, 0.0, 1.0) : 1.0;
            float3 kept = target + offset * scale;
            m = kept + (m - kept) * saturation;
        }
        float3 out = float3(fromCurve(lookup(table, m.r, 2.0, n, stops)), fromCurve(lookup(table, m.g, 3.0, n, stops)), fromCurve(lookup(table, m.b, 4.0, n, stops)));
        return float4((fromPro * out + negative) * s.a, s.a);
    }
    """)[0]
}
