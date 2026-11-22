import Accelerate
import CoreImage
import Foundation
import simd

/// The ACES 2 output transform (SDR, 100 nits, P3 D65 limit) on the scene's linear light, from a table OpenColorIO
/// baked from its ACES studio config (`scripts/aces-data.py`): the working space goes to ACEScg and ACEScct, the table
/// gives Display P3 code values, which are decoded back to linear light in the working space. Colors outside P3 stay
/// in the extended range for wide-gamut exports.
enum ACESRenderer {
    static let size = 65
    struct Table { let toACEScg: simd_double3x3; let values: [Float]; let image: CIImage }

    /// The baked table, read once; nil when the resource is missing or damaged.
    static let table: Table = {
        let count = size * size * size * 3
        let compressed = try! Data(contentsOf: Bundle.module.url(forResource: "ACESOutput", withExtension: "zlib")!)
        let data = try! (compressed as NSData).decompressed(using: .zlib) as Data
        precondition(data.count == 36 + count * 2, "ACESOutput.zlib has the wrong size")
        let m = data.prefix(36).withUnsafeBytes { raw in (0..<9).map { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))) } }
        var values = [Float](repeating: 0, count: count)
        data.dropFirst(36).withUnsafeBytes { source in
            values.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var output = vImage_Buffer(data: target.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&input, &output, 0)
            }
        }
        // The atlas the film kernels read: blue slices side by side, green up the rows, red along each slice.
        let n = size, width = n * n
        var atlas = [Float](repeating: 1, count: width * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let source = ((b * n + g) * n + r) * 3, target = ((n - 1 - g) * width + r + n * b) * 4
            atlas[target] = values[source]; atlas[target + 1] = values[source + 1]; atlas[target + 2] = values[source + 2]
        } } }
        let image = CIImage(bitmapData: atlas.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: n), format: .RGBAf, colorSpace: nil)
        return Table(toACEScg: simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])]), values: values, image: image)
    }()

    /// Linear Display P3 to linear Rec. 709, both D65.
    static let p3ToRec709: simd_double3x3 = rgbToXYZ(red: SIMD2(0.64, 0.33), green: SIMD2(0.30, 0.60), blue: SIMD2(0.15, 0.06)).inverse * rgbToXYZ(red: SIMD2(0.680, 0.320), green: SIMD2(0.265, 0.690), blue: SIMD2(0.150, 0.060))

    static func apply(to image: CIImage) -> CIImage {
        let m = table.toACEScg, o = p3ToRec709
        func row(_ matrix: simd_double3x3, _ i: Int) -> CIVector { CIVector(x: matrix[0][i], y: matrix[1][i], z: matrix[2][i]) }
        return kernel.apply(extent: image.extent, roiCallback: { index, rect in index == 0 ? rect : table.image.extent },
                            arguments: [image, table.image, row(m, 0), row(m, 1), row(m, 2), Float(size), row(o, 0), row(o, 1), row(o, 2)])!
    }

    /// The CPU form of the kernel, with a trilinear lookup, for tests.
    static func render(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let ap1 = table.toACEScg * rgb
        let cct = SIMD3((0..<3).map { c -> Double in ap1[c] <= 0.0078125 ? 10.5402377416545 * ap1[c] + 0.0729055341958355 : (log2(ap1[c]) + 9.72) / 17.52 })
        let n = size, u = simd_clamp(cct, .zero, .one) * Double(n - 1)
        let i = SIMD3<Int>((0..<3).map { min(n - 2, Int(u[$0])) }), f = u - SIMD3(Double(i.x), Double(i.y), Double(i.z))
        var code = SIMD3<Double>.zero
        for corner in 0..<8 {
            let d = SIMD3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
            let weight = (d.x == 1 ? f.x : 1 - f.x) * (d.y == 1 ? f.y : 1 - f.y) * (d.z == 1 ? f.z : 1 - f.z)
            let o = (((i.z + d.z) * n + i.y + d.y) * n + i.x + d.x) * 3
            code += weight * SIMD3(Double(table.values[o]), Double(table.values[o + 1]), Double(table.values[o + 2]))
        }
        code = simd_clamp(code, .zero, .one)
        let p3 = SIMD3((0..<3).map { c in code[c] <= 0.04045 ? code[c] / 12.92 : pow((code[c] + 0.055) / 1.055, 2.4) })
        return p3ToRec709 * p3
    }

    private static func rgbToXYZ(red: SIMD2<Double>, green: SIMD2<Double>, blue: SIMD2<Double>) -> simd_double3x3 {
        func xyz(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
        let primaries = simd_double3x3(columns: (xyz(red), xyz(green), xyz(blue)))
        let scale = primaries.inverse * SIMD3(0.95047, 1, 1.08883)
        return simd_double3x3(columns: (primaries.columns.0 * scale.x, primaries.columns.1 * scale.y, primaries.columns.2 * scale.z))
    }

    private static let kernel = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        extern "C" [[ stitchable ]] float4 acesOutput(coreimage::sampler source, coreimage::sampler table, float3 m0, float3 m1, float3 m2, float n, float3 o0, float3 o1, float3 o2) {
            float4 s = source.sample(source.coord());
            float3 c = s.rgb / max(s.a, 0.000001);
            float3 ap1 = float3(dot(m0, c), dot(m1, c), dot(m2, c));
            // ACEScct: linear below 0.0078125, log2 above.
            float3 cct = select((log2(max(ap1, 1e-10)) + 9.72) / 17.52, 10.5402377416545 * ap1 + 0.0729055341958355, ap1 <= 0.0078125);
            float3 u = clamp(cct, 0.0, 1.0) * (n - 1.0);
            float z = min(floor(u.z), n - 2.0), f = u.z - z;
            float3 a = table.sample(table.transform(float2(u.x + n * z + 0.5, u.y + 0.5))).rgb;
            float3 b = table.sample(table.transform(float2(u.x + n * (z + 1.0) + 0.5, u.y + 0.5))).rgb;
            float3 code = clamp(mix(a, b, f), 0.0, 1.0);
            float3 p3 = select(pow((code + 0.055) / 1.055, 2.4), code / 12.92, code <= 0.04045);
            return float4(float3(dot(o0, p3), dot(o1, p3), dot(o2, p3)) * s.a, s.a);
        }
        """)[0]
}
