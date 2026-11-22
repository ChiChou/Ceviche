import CoreImage
import Foundation

/// A chart profile's correction as the RAW decoder's linear-space filter: the decoder runs it on scene-linear light in
/// the context's working space (extended linear sRGB here), before its own tone, so the correction is the same
/// whatever the tone response that follows.
///
/// Linear sRGB → linear ProPhoto → the profile's 3 × 3 → its hue/saturation map → linear sRGB. The map has one value
/// division, so it scales with the light: it is baked into a cube over colours normalized to their largest channel,
/// and the pixel's level is put back afterwards. Highlights above 1 pass through like any other level.
final class ChartCalibrationFilter: CIFilter {
    @objc dynamic var inputImage: CIImage?
    private let profile: CameraProfile

    init?(profile: CameraProfile) {
        guard profile.hasCalibration, profile.amount > 0 else { return nil }
        self.profile = profile
        super.init()
    }
    required init?(coder: NSCoder) { nil }

    static let dimension = 64
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (map: Data, dimensions: [Int], cube: Data)?

    override var outputImage: CIImage? {
        guard let input = inputImage, let values = profile.calibrationMatrix else { return inputImage }
        let toProphoto = ChartColour.prophotoToSRGB.inverse, matrix = ChartMatrix(values)
        var image = Self.transformed(input, by: matrix * toProphoto)
        if let map = profile.calibrationMap, let dimensions = profile.calibrationDimensions {
            let normalized = Self.normalize.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image])!
            let mapped = normalized.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.dimension, "inputCubeData": Self.cube(map, dimensions)])
            image = Self.restore.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [mapped, image])!
        }
        image = Self.transformed(image, by: ChartColour.prophotoToSRGB)
        guard profile.amount < 1 else { return image }
        return image.applyingFilter("CIMix", parameters: [kCIInputBackgroundImageKey: input, kCIInputAmountKey: profile.amount])
    }

    private static func transformed(_ image: CIImage, by m: ChartMatrix) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0, 0], y: m[0, 1], z: m[0, 2], w: 0), "inputGVector": CIVector(x: m[1, 0], y: m[1, 1], z: m[1, 2], w: 0),
            "inputBVector": CIVector(x: m[2, 0], y: m[2, 1], z: m[2, 2], w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    /// The map over colours whose largest channel is 1, which is every colour once its level is taken out.
    private static func cube(_ map: Data, _ dimensions: [Int]) -> Data {
        if let cached = lock.withLock({ cache }), cached.map == map, cached.dimensions == dimensions { return cached.cube }
        let table = ChartHueSatMap(hueDivisions: dimensions[0], satDivisions: dimensions[1], data: CameraProfile.floats(map))
        let n = dimension
        var values = [Float](repeating: 1, count: n * n * n * 4)
        values.withUnsafeMutableBufferPointer { values in
            let values = values
            DispatchQueue.concurrentPerform(iterations: n) { b in
                for g in 0..<n { for r in 0..<n {
                    let out = table.applyDouble(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
                    let i = ((b * n + g) * n + r) * 4
                    values[i] = Float(out.x); values[i + 1] = Float(out.y); values[i + 2] = Float(out.z)
                } }
            }
        }
        let cube = values.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { cache = (map, dimensions, cube) }
        return cube
    }

    private static func compile(_ name: String, _ signature: String, _ body: String) -> CIKernel {
        try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 \(name)(\(signature)) { \(body) }
        """)[0]
    }
    /// A colour over its largest channel; black and negative light stay as they are.
    private static let normalize = compile("chartNormalize", "coreimage::sample_t s",
                                           "float3 c = max(s.rgb, float3(0.0)); float m = max(c.r, max(c.g, c.b)); return float4(m > 0.0 ? c / m : c, 1.0);")
    private static let restore = compile("chartRestore", "coreimage::sample_t mapped, coreimage::sample_t s",
                                         "float3 c = max(s.rgb, float3(0.0)); float m = max(c.r, max(c.g, c.b)); return float4(m > 0.0 ? mapped.rgb * m : s.rgb, s.a);")
}
