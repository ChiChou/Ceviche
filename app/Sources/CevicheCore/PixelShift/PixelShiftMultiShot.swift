// Pixel Shift is the Mac app's alone: a sixteen-shot set peaks at 13.8 GB, more than iOS gives an app, so the iPad and
// iPhone build leaves the whole tool out (docs/development/ios.md).
#if os(macOS)
import Foundation
import Metal
import simd
import CameraRaw

/// Hasselblad's six-shot multi-shot: six exposures on a grid of twice the sensor's resolution, each at the half-pixel
/// position the file records. A point of the grid takes the colours measured there; a colour no exposure measured there
/// is the average of its measurements nearby, weighted by distance. The file's own colour matrix and white balance take
/// the result to linear sRGB, as the prototype the photographer checked against Hasselblad's own TIFF does.
final class PixelShiftMultiShot: @unchecked Sendable {
    let url: URL
    let shot: HasselbladMultiShot
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var planes: MTLBuffer?

    init(url: URL, shot: HasselbladMultiShot) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw EditorError.noGPU }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "multishot")!)
        self.url = url; self.shot = shot; self.device = device; self.queue = queue
    }

    /// Mirrors `Params` in the shader.
    private struct Parameters {
        var planeWidth: UInt32, planeHeight: UInt32, width: UInt32, height: UInt32
        var x0: Int32, y0: Int32, step: Int32, pad: Int32 = 0
        var dx: (Int32, Int32, Int32, Int32, Int32, Int32), dy: (Int32, Int32, Int32, Int32, Int32, Int32)
        var black: Float, scale: Float, pad1: Float = 0, pad2: Float = 0
        var matrix: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    }

    /// White-balanced camera RGB to linear sRGB: the inverse of the camera's response to sRGB primaries (its XYZ matrix
    /// times sRGB's), each row scaled so white stays white, after the as-shot neutral is divided out.
    var matrix: simd_float3x3 {
        let c = shot.colourMatrix
        let cameraFromXYZ = simd_double3x3(rows: [SIMD3(c[0], c[1], c[2]), SIMD3(c[3], c[4], c[5]), SIMD3(c[6], c[7], c[8])])
        let xyzFromSRGB = simd_double3x3(rows: [SIMD3(0.4124564, 0.3575761, 0.1804375), SIMD3(0.2126729, 0.7151522, 0.0721750),
                                                SIMD3(0.0193339, 0.1191920, 0.9503041)])
        var cameraFromRGB = cameraFromXYZ * xyzFromSRGB
        let t = cameraFromRGB.transpose
        cameraFromRGB = simd_double3x3(rows: [t[0] / t[0].sum(), t[1] / t[1].sum(), t[2] / t[2].sum()])
        let balance = simd_double3x3(diagonal: SIMD3(1 / shot.neutral[0], 1 / shot.neutral[1], 1 / shot.neutral[2]))
        let m = cameraFromRGB.inverse * balance
        return simd_float3x3(SIMD3<Float>(m[0]), SIMD3<Float>(m[1]), SIMD3<Float>(m[2]))
    }

    func analyze(progress: @escaping @Sendable (Double, String) -> Void) throws -> PixelShiftAnalysis {
        progress(0.1, L10n.tr("Reading \(url.lastPathComponent)"))
        if planes == nil {
            let samples: [UInt16]
            do { samples = try shot.planes(url) } catch let error as CameraRawError { throw error.pixelShift(url) }
            if Task.isCancelled { throw CancellationError() }
            planes = samples.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard planes != nil else { throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos.")) }
        }
        return PixelShiftAnalysis(frames: shot.places.indices.map { k in
            PixelShiftFrameInfo(index: k, filename: url.lastPathComponent, shift: SIMD2(Double(shot.places[k].x) / 2, Double(shot.places[k].y) / 2), stops: 0)
        }, width: shot.crop.width, height: shot.crop.height, orientation: shot.orientation, camera: shot.model)
    }

    /// Every `step`-th point of the merge, `width × height` of them from the grid point (x0, y0).
    private func render(x0: Int, y0: Int, width: Int, height: Int, step: Int, into target: UnsafeMutablePointer<Float>) throws {
        guard let planes, let output = device.makeBuffer(length: width * height * 16, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos."))
        }
        let p = shot.places.map { (Int32($0.x), Int32($0.y)) }, m = matrix
        var parameters = Parameters(planeWidth: UInt32(shot.width), planeHeight: UInt32(shot.height), width: UInt32(width), height: UInt32(height),
                                    x0: Int32(x0), y0: Int32(y0), step: Int32(step),
                                    dx: (p[0].0, p[1].0, p[2].0, p[3].0, p[4].0, p[5].0), dy: (p[0].1, p[1].1, p[2].1, p[3].1, p[4].1, p[5].1),
                                    black: shot.black, scale: 1 / (shot.white - shot.black),
                                    matrix: (m[0][0], m[1][0], m[2][0], 0, m[0][1], m[1][1], m[2][1], 0, m[0][2], m[1][2], m[2][2], 0))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(planes, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        memcpy(target, output.contents(), width * height * 16)
    }

    /// Every eighth point: the merge at a size to look at.
    func preview() throws -> PixelShiftPreview {
        let step = 8, crop = shot.crop, width = crop.width / step, height = crop.height / step
        var raster = PanoramaRaster(width: width, height: height, rgba: [Float](repeating: 0, count: width * height * 4))
        try raster.rgba.withUnsafeMutableBufferPointer { try render(x0: crop.x, y0: crop.y, width: width, height: height, step: step, into: $0.baseAddress!) }
        guard let picture = HDRMergeFinishing.picture(raster) else { throw PanoramaError.message(L10n.tr("The preview couldn’t be made.")) }
        return PixelShiftPreview(image: picture, source: nil, motion: nil, motionCoverage: 0)
    }

    func mergedRaster(progress: @escaping @Sendable (Double, String) -> Void) throws -> PanoramaRaster {
        let crop = shot.crop
        progress(0.1, L10n.tr("Combining \(shot.places.count) photos"))
        var raster = PanoramaRaster(width: crop.width, height: crop.height, rgba: [Float](repeating: 0, count: crop.width * crop.height * 4))
        let rows = 512
        try raster.rgba.withUnsafeMutableBufferPointer { out in
            for row in stride(from: 0, to: crop.height, by: rows) {
                if Task.isCancelled { throw CancellationError() }
                progress(0.1 + 0.85 * Double(row) / Double(crop.height), L10n.tr("Combining \(shot.places.count) photos"))
                try render(x0: crop.x, y0: crop.y + row, width: crop.width, height: min(rows, crop.height - row), step: 1,
                           into: out.baseAddress! + row * crop.width * 4)
            }
        }
        return raster
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint planeWidth, planeHeight, width, height;
        int x0, y0, step, pad;
        int dx[6]; int dy[6];
        float black, scale, pad1, pad2;
        float m[12];
    };
    inline int floordiv(int a, int b) { return a >= 0 ? a / b : -((-a + b - 1) / b); }

    // Each exposure's pixel (px, py) is at (2px + dx, 2py + dy) on the grid, red, green, green, blue from (0,0).
    kernel void multishot(device const ushort *planes [[buffer(0)]], constant Params &P [[buffer(1)]],
                          device float4 *out [[buffer(2)]], uint2 g [[thread_position_in_grid]]) {
        if (g.x >= P.width || g.y >= P.height) return;
        int X = P.x0 + int(g.x) * P.step, Y = P.y0 + int(g.y) * P.step;
        float3 exact = 0, measured = 0, sum = 0, weight = 0;
        ulong size = ulong(P.planeWidth) * P.planeHeight;
        for (int k = 0; k < 6; k++) {
            // Samples within three grid points, weighted (4 - |dx|)(4 - |dy|).
            int py0 = max(floordiv(Y - P.dy[k] - 2, 2), 0), py1 = min(floordiv(Y - P.dy[k] + 3, 2), int(P.planeHeight) - 1);
            int px0 = max(floordiv(X - P.dx[k] - 2, 2), 0), px1 = min(floordiv(X - P.dx[k] + 3, 2), int(P.planeWidth) - 1);
            device const ushort *plane = planes + ulong(k) * size;
            for (int py = py0; py <= py1; py++) {
                int oy = 2 * py + P.dy[k] - Y;
                float wy = 4 - abs(oy);
                for (int px = px0; px <= px1; px++) {
                    int ox = 2 * px + P.dx[k] - X;
                    int c = (py & 1) + (px & 1);
                    float3 channel = float3(c == 0, c == 1, c == 2);
                    float v = float(plane[ulong(py) * P.planeWidth + ulong(px)]);
                    float w = wy * (4 - abs(ox));
                    sum += channel * (w * v); weight += channel * w;
                    if (ox == 0 && oy == 0) { exact += channel * v; measured += channel; }
                }
            }
        }
        float3 camera = select(sum / max(weight, 1e-6f), exact / max(measured, 1.0f), measured > 0);
        camera = (camera - P.black) * P.scale;
        float3 rgb = float3(dot(float3(P.m[0], P.m[1], P.m[2]), camera), dot(float3(P.m[4], P.m[5], P.m[6]), camera),
                            dot(float3(P.m[8], P.m[9], P.m[10]), camera));
        out[g.y * P.width + g.x] = float4(clamp(rgb, 0.0f, 1.0f), 1.0f);
    }
    """
}
#endif
