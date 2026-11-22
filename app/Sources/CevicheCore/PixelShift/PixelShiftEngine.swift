import Foundation
import Metal

/// Mirrors `Params` in the shader; plain scalars and tuples so both layouts agree.
struct PixelShiftParameters {
    var width: UInt32 = 0, height: UInt32 = 0, frames: UInt32 = 4, pad: UInt32 = 0
    var ox: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var oy: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var gain: (Float, Float, Float, Float) = (1, 1, 1, 1)
    var sigma: (Float, Float, Float, Float) = (1, 1, 1, 1)
    var black: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var scale: (Float, Float, Float, Float) = (1, 1, 1, 1)
    var cfa: (UInt32, UInt32, UInt32, UInt32) = (0, 1, 1, 2)
    /// Motion is judged in noise units between `zLow` and `zHigh`.
    var floorValue: Float = PixelShiftAligner.readFloor, zLow: Float = 4, zHigh: Float = 8
    /// Relative difference allowed for light that changes unevenly between shots.
    var tolerance: Float = 0.02
    /// The level above which a block is clipped and can't be compared.
    var clip: Float = 0.97, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
    var wb: (Float, Float, Float, Float) = (1, 1, 1, 0)
    /// White-balanced camera RGB to linear sRGB, three rows of four.
    var matrix: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0)

    func floats<T>(_ tuple: T) -> [Float] { withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self)) } }
    func ints<T>(_ tuple: T) -> [Int] { withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Int32.self)).map(Int.init) } }
}

/// The merge of one 4-shot set: at each pixel every shot contributes the colour its CFA had there, so red, both greens
/// and blue are measured rather than interpolated. Where a shot disagrees with the first beyond noise (something moved,
/// the light changed) a soft mask falls back to the first shot demosaiced (Malvar-He-Cutler).
/// Returns width × height RGBA: linear sRGB, and in alpha how much of the pixel is the fallback.
protocol PixelShiftEngine {
    func merge(frames: [UnsafePointer<UInt16>], parameters: PixelShiftParameters, dilate: Int, blur: Int) throws -> [Float]
}

final class PixelShiftGPU: PixelShiftEngine {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private struct MaskParameters { var width: UInt32, height: UInt32, radius: Int32, pad: UInt32 = 0 }

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw EditorError.noGPU }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        for name in ["ps_merge", "ps_max_h", "ps_max_v", "ps_box_h", "ps_box_v", "ps_finish"] {
            pipelines[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ name: String, width: Int, height: Int) {
        let pipeline = pipelines[name]!
        encoder.setComputePipelineState(pipeline)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    func merge(frames: [UnsafePointer<UInt16>], parameters: PixelShiftParameters, dilate: Int, blur: Int) throws -> [Float] {
        let w = Int(parameters.width), h = Int(parameters.height), pixels = w * h
        let failed = PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos."))
        guard pixels * 16 <= device.maxBufferLength,
              let frameBuffer = device.makeBuffer(length: pixels * 2 * frames.count, options: .storageModeShared),
              let merged = device.makeBuffer(length: pixels * 8, options: .storageModePrivate),
              let mask = device.makeBuffer(length: pixels * 4, options: .storageModePrivate),
              let scratch = device.makeBuffer(length: pixels * 4, options: .storageModePrivate),
              let output = device.makeBuffer(length: pixels * 16, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw failed }
        for (k, frame) in frames.enumerated() { memcpy(frameBuffer.contents() + k * pixels * 2, frame, pixels * 2) }
        var p = parameters
        var dilateParameters = MaskParameters(width: UInt32(w), height: UInt32(h), radius: Int32(dilate))
        var blurParameters = MaskParameters(width: UInt32(w), height: UInt32(h), radius: Int32(blur))
        encoder.setBuffer(frameBuffer, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<PixelShiftParameters>.stride, index: 1)
        encoder.setBuffer(merged, offset: 0, index: 2)
        dispatch(encoder, "ps_merge", width: w, height: h)
        // The mask grown (maximum), then softened (box), both separable.
        encoder.setBuffer(merged, offset: 0, index: 0); encoder.setBuffer(scratch, offset: 0, index: 1)
        encoder.setBytes(&dilateParameters, length: MemoryLayout<MaskParameters>.stride, index: 2)
        dispatch(encoder, "ps_max_h", width: w, height: h)
        encoder.setBuffer(scratch, offset: 0, index: 0); encoder.setBuffer(mask, offset: 0, index: 1)
        dispatch(encoder, "ps_max_v", width: w, height: h)
        encoder.setBuffer(mask, offset: 0, index: 0); encoder.setBuffer(scratch, offset: 0, index: 1)
        encoder.setBytes(&blurParameters, length: MemoryLayout<MaskParameters>.stride, index: 2)
        dispatch(encoder, "ps_box_h", width: w, height: h)
        encoder.setBuffer(scratch, offset: 0, index: 0); encoder.setBuffer(mask, offset: 0, index: 1)
        dispatch(encoder, "ps_box_v", width: w, height: h)
        encoder.setBuffer(frameBuffer, offset: 0, index: 0)
        encoder.setBytes(&p, length: MemoryLayout<PixelShiftParameters>.stride, index: 1)
        encoder.setBuffer(merged, offset: 0, index: 2)
        encoder.setBuffer(mask, offset: 0, index: 3)
        encoder.setBuffer(output, offset: 0, index: 4)
        dispatch(encoder, "ps_finish", width: w, height: h)
        encoder.endEncoding()
        commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: pixels * 4))
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint width, height, frames, pad;
        int ox[4]; int oy[4];
        float gain[4]; float sigma[4]; float black[4]; float scale[4];
        uint cfa[4];
        float floorValue, zLow, zHigh, tolerance;
        float clip, pad0, pad1, pad2;
        float wb[4];
        float m[12];
    };
    struct MaskParams { uint width, height; int radius; uint pad; };

    inline float sampleN(device const ushort *f, constant Params &P, int x, int y) {
        uint pos = (uint(y) & 1) * 2 + (uint(x) & 1);
        return (float(f[uint(y) * P.width + uint(x)]) - P.black[pos]) * P.scale[pos];
    }
    inline float block(device const ushort *f, constant Params &P, int x, int y) {
        return 0.25f * (sampleN(f, P, x, y) + sampleN(f, P, x + 1, y) + sampleN(f, P, x, y + 1) + sampleN(f, P, x + 1, y + 1));
    }
    // Reflection that keeps the CFA phase (no repeated edge sample).
    inline int mirror(int v, int n) { v = v < 0 ? -v : v; return v >= n ? 2 * (n - 1) - v : v; }
    // White-balanced sample for the demosaic: its gradient corrections assume the channels share a scale.
    inline float S(device const ushort *f, constant Params &P, int x, int y) {
        int mx = mirror(x, int(P.width)), my = mirror(y, int(P.height));
        return sampleN(f, P, mx, my) * P.gain[0] * P.wb[P.cfa[(uint(my) & 1) * 2 + (uint(mx) & 1)]];
    }

    // Malvar-He-Cutler demosaic of the first shot at (x, y), white-balanced camera RGB.
    inline float3 mhc(device const ushort *f, constant Params &P, int x, int y) {
        uint c0 = P.cfa[(uint(y) & 1) * 2 + (uint(x) & 1)];
        float C = S(f, P, x, y);
        float N = S(f, P, x, y - 1), Sv = S(f, P, x, y + 1), E = S(f, P, x + 1, y), W = S(f, P, x - 1, y);
        float N2 = S(f, P, x, y - 2), S2 = S(f, P, x, y + 2), E2 = S(f, P, x + 2, y), W2 = S(f, P, x - 2, y);
        float D = S(f, P, x - 1, y - 1) + S(f, P, x + 1, y - 1) + S(f, P, x - 1, y + 1) + S(f, P, x + 1, y + 1);
        float rgb[3];
        if (c0 == 1) {
            uint hc = P.cfa[(uint(y) & 1) * 2 + (uint(x + 1) & 1)];
            float h = (5 * C + 4 * (E + W) - D - (E2 + W2) + 0.5f * (N2 + S2)) / 8;
            float v = (5 * C + 4 * (N + Sv) - D - (N2 + S2) + 0.5f * (E2 + W2)) / 8;
            rgb[1] = C; rgb[hc] = h; rgb[2 - hc] = v;
        } else {
            rgb[c0] = C;
            rgb[1] = (4 * C + 2 * (N + Sv + E + W) - (N2 + S2 + E2 + W2)) / 8;
            rgb[2 - c0] = (6 * C + 2 * D - 1.5f * (N2 + S2 + E2 + W2)) / 8;
        }
        return max(float3(rgb[0], rgb[1], rgb[2]), 0.0f);
    }

    // rgb: the measured colour; a: motion 0…1, or 2 where a colour is missing (edges).
    kernel void ps_merge(device const ushort *frames [[buffer(0)]], constant Params &P [[buffer(1)]],
                         device half4 *merged [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= P.width || gid.y >= P.height) return;
        int x = int(gid.x), y = int(gid.y), W = int(P.width), H = int(P.height);
        float sum[3] = {0, 0, 0}, count[3] = {0, 0, 0};
        float motion = 0;
        // The first shot's 2×2 blocks over the 3×3 neighbourhood: a shot whose block falls inside their range (plus
        // noise) agrees with the scene up to a pixel of misregistration, so texture and edges don't read as motion.
        bool hasBlock = x >= 1 && y >= 1 && x + 2 < W && y + 2 < H;
        float L0 = hasBlock ? block(frames, P, x, y) : 0, lo = L0, hi = L0;
        if (hasBlock) for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            float v = block(frames, P, x + dx, y + dy); lo = min(lo, v); hi = max(hi, v);
        }
        bool clipped = hi >= P.clip;
        float noise = sqrt(max(L0, 0.0f) + P.floorValue);
        for (uint k = 0; k < P.frames; k++) {
            int sx = x - P.ox[k], sy = y - P.oy[k];
            if (sx < 0 || sy < 0 || sx >= W || sy >= H) continue;
            device const ushort *f = frames + size_t(k) * size_t(W) * size_t(H);
            uint c = P.cfa[(uint(sy) & 1) * 2 + (uint(sx) & 1)];
            sum[c] += sampleN(f, P, sx, sy) * P.gain[k]; count[c] += 1;
            if (k > 0 && hasBlock && !clipped && sx + 1 < W && sy + 1 < H) {
                float raw = block(f, P, sx, sy), v = raw * P.gain[k];
                if (raw >= P.clip) continue;
                float z = max(0.0f, max(v - hi, lo - v)) / (P.sigma[k] * noise + P.tolerance * max(L0, 0.0f));
                motion = max(motion, smoothstep(P.zLow, P.zHigh, z));
            }
        }
        bool complete = count[0] > 0 && count[1] > 0 && count[2] > 0;
        float3 rgb = complete ? float3(sum[0] / count[0], sum[1] / count[1], sum[2] / count[2]) : float3(0);
        merged[gid.y * P.width + gid.x] = half4(half3(rgb), half(complete ? motion : 2.0f));
    }

    kernel void ps_max_h(device const half4 *src [[buffer(0)]], device float *dst [[buffer(1)]], constant MaskParams &M [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= M.width || gid.y >= M.height) return;
        float v = 0;
        for (int d = -M.radius; d <= M.radius; d++) {
            int x = clamp(int(gid.x) + d, 0, int(M.width) - 1);
            v = max(v, min(float(src[gid.y * M.width + uint(x)].a), 1.0f));
        }
        dst[gid.y * M.width + gid.x] = v;
    }
    kernel void ps_max_v(device const float *src [[buffer(0)]], device float *dst [[buffer(1)]], constant MaskParams &M [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= M.width || gid.y >= M.height) return;
        float v = 0;
        for (int d = -M.radius; d <= M.radius; d++) v = max(v, src[uint(clamp(int(gid.y) + d, 0, int(M.height) - 1)) * M.width + gid.x]);
        dst[gid.y * M.width + gid.x] = v;
    }
    kernel void ps_box_h(device const float *src [[buffer(0)]], device float *dst [[buffer(1)]], constant MaskParams &M [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= M.width || gid.y >= M.height) return;
        float v = 0;
        for (int d = -M.radius; d <= M.radius; d++) v += src[gid.y * M.width + uint(clamp(int(gid.x) + d, 0, int(M.width) - 1))];
        dst[gid.y * M.width + gid.x] = v / float(2 * M.radius + 1);
    }
    kernel void ps_box_v(device const float *src [[buffer(0)]], device float *dst [[buffer(1)]], constant MaskParams &M [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= M.width || gid.y >= M.height) return;
        float v = 0;
        for (int d = -M.radius; d <= M.radius; d++) v += src[uint(clamp(int(gid.y) + d, 0, int(M.height) - 1)) * M.width + gid.x];
        dst[gid.y * M.width + gid.x] = v / float(2 * M.radius + 1);
    }

    kernel void ps_finish(device const ushort *frames [[buffer(0)]], constant Params &P [[buffer(1)]],
                          device const half4 *merged [[buffer(2)]], device const float *mask [[buffer(3)]],
                          device float4 *out [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= P.width || gid.y >= P.height) return;
        uint i = gid.y * P.width + gid.x;
        float3 fallback = mhc(frames, P, int(gid.x), int(gid.y));
        half4 m = merged[i];
        float3 measured = float3(m.rgb) * float3(P.wb[0], P.wb[1], P.wb[2]);
        float t = m.a > 1.5h ? 1.0f : mask[i];
        float3 cam = clamp(mix(measured, fallback, t), 0.0f, 1.0f);
        float3 o = float3(dot(float3(P.m[0], P.m[1], P.m[2]), cam), dot(float3(P.m[4], P.m[5], P.m[6]), cam), dot(float3(P.m[8], P.m[9], P.m[10]), cam));
        out[i] = float4(o, t);
    }
    """
}

/// The same arithmetic on the CPU: the reference the GPU is tested against, and the path without a GPU.
final class PixelShiftCPU: PixelShiftEngine {
    func merge(frames pointers: [UnsafePointer<UInt16>], parameters P: PixelShiftParameters, dilate: Int, blur: Int) throws -> [Float] {
        let w = Int(P.width), h = Int(P.height), pixels = w * h
        let ox = P.ints(P.ox), oy = P.ints(P.oy)
        let gain = P.floats(P.gain), sigma = P.floats(P.sigma), black = P.floats(P.black), scale = P.floats(P.scale)
        let cfa = withUnsafeBytes(of: P.cfa) { Array($0.bindMemory(to: UInt32.self)).map(Int.init) }
        let wb = P.floats(P.wb), m = P.floats(P.matrix)
        var merged = [Float](repeating: 0, count: pixels * 4)
        var mask = [Float](repeating: 0, count: pixels), scratch = [Float](repeating: 0, count: pixels)

        @inline(__always) func sampleN(_ f: UnsafePointer<UInt16>, _ x: Int, _ y: Int) -> Float {
            let pos = (y & 1) * 2 + (x & 1)
            return (Float(f[y * w + x]) - black[pos]) * scale[pos]
        }
        @inline(__always) func block(_ f: UnsafePointer<UInt16>, _ x: Int, _ y: Int) -> Float {
            0.25 * (sampleN(f, x, y) + sampleN(f, x + 1, y) + sampleN(f, x, y + 1) + sampleN(f, x + 1, y + 1))
        }
        @inline(__always) func mirror(_ v: Int, _ n: Int) -> Int { let a = v < 0 ? -v : v; return a >= n ? 2 * (n - 1) - a : a }
        @inline(__always) func S(_ x: Int, _ y: Int) -> Float {
            let mx = mirror(x, w), my = mirror(y, h)
            return sampleN(pointers[0], mx, my) * gain[0] * wb[cfa[(my & 1) * 2 + (mx & 1)]]
        }
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        func mhc(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let c0 = cfa[(y & 1) * 2 + (x & 1)]
            let C = S(x, y), N = S(x, y - 1), Sv = S(x, y + 1), E = S(x + 1, y), W = S(x - 1, y)
            let N2 = S(x, y - 2), S2 = S(x, y + 2), E2 = S(x + 2, y), W2 = S(x - 2, y)
            let D = S(x - 1, y - 1) + S(x + 1, y - 1) + S(x - 1, y + 1) + S(x + 1, y + 1)
            var rgb = SIMD3<Float>(0, 0, 0)
            if c0 == 1 {
                let hc = cfa[(y & 1) * 2 + ((x + 1) & 1)]
                rgb[1] = C
                rgb[hc] = (5 * C + 4 * (E + W) - D - (E2 + W2) + 0.5 * (N2 + S2)) / 8
                rgb[2 - hc] = (5 * C + 4 * (N + Sv) - D - (N2 + S2) + 0.5 * (E2 + W2)) / 8
            } else {
                rgb[c0] = C
                rgb[1] = (4 * C + 2 * (N + Sv + E + W) - (N2 + S2 + E2 + W2)) / 8
                rgb[2 - c0] = (6 * C + 2 * D - 1.5 * (N2 + S2 + E2 + W2)) / 8
            }
            return rgb.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: .greatestFiniteMagnitude))
        }

        merged.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var sum = SIMD3<Float>(0, 0, 0), count = SIMD3<Float>(0, 0, 0)
                    var motion: Float = 0
                    let hasBlock = x >= 1 && y >= 1 && x + 2 < w && y + 2 < h
                    let L0 = hasBlock ? block(pointers[0], x, y) : 0
                    var lo = L0, hi = L0
                    if hasBlock { for dy in -1...1 { for dx in -1...1 { let v = block(pointers[0], x + dx, y + dy); lo = min(lo, v); hi = max(hi, v) } } }
                    let clipped = hi >= P.clip
                    let noise = (max(L0, 0) + P.floorValue).squareRoot()
                    for k in 0..<Int(P.frames) {
                        let sx = x - ox[k], sy = y - oy[k]
                        if sx < 0 || sy < 0 || sx >= w || sy >= h { continue }
                        let c = cfa[(sy & 1) * 2 + (sx & 1)]
                        sum[c] += sampleN(pointers[k], sx, sy) * gain[k]; count[c] += 1
                        if k > 0 && hasBlock && !clipped && sx + 1 < w && sy + 1 < h {
                            let raw = block(pointers[k], sx, sy), v = raw * gain[k]
                            if raw >= P.clip { continue }
                            let z = max(0, max(v - hi, lo - v)) / (sigma[k] * noise + P.tolerance * max(L0, 0))
                            motion = max(motion, smoothstep(P.zLow, P.zHigh, z))
                        }
                    }
                    let complete = count[0] > 0 && count[1] > 0 && count[2] > 0
                    let i = (y * w + x) * 4
                    // Through half floats, as the GPU stores them.
                    out[i] = Float(Float16(complete ? sum[0] / count[0] : 0)); out[i + 1] = Float(Float16(complete ? sum[1] / count[1] : 0))
                    out[i + 2] = Float(Float16(complete ? sum[2] / count[2] : 0)); out[i + 3] = complete ? motion : 2
                }
            }
        }
        func pass(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, radius: Int, horizontal: Bool, maximum: Bool) {
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var v: Float = 0
                    for d in -radius...radius {
                        let xx = horizontal ? min(max(x + d, 0), w - 1) : x, yy = horizontal ? y : min(max(y + d, 0), h - 1)
                        let s = source[yy * w + xx]
                        v = maximum ? max(v, s) : v + s
                    }
                    destination[y * w + x] = maximum ? v : v / Float(2 * radius + 1)
                }
            }
        }
        var alpha = [Float](repeating: 0, count: pixels)
        for i in 0..<pixels { alpha[i] = min(merged[i * 4 + 3], 1) }
        alpha.withUnsafeBufferPointer { a in scratch.withUnsafeMutableBufferPointer { s in pass(a.baseAddress!, s.baseAddress!, radius: dilate, horizontal: true, maximum: true) } }
        scratch.withUnsafeBufferPointer { s in mask.withUnsafeMutableBufferPointer { m in pass(s.baseAddress!, m.baseAddress!, radius: dilate, horizontal: false, maximum: true) } }
        mask.withUnsafeBufferPointer { m in scratch.withUnsafeMutableBufferPointer { s in pass(m.baseAddress!, s.baseAddress!, radius: blur, horizontal: true, maximum: false) } }
        scratch.withUnsafeBufferPointer { s in mask.withUnsafeMutableBufferPointer { m in pass(s.baseAddress!, m.baseAddress!, radius: blur, horizontal: false, maximum: false) } }

        var image = [Float](repeating: 0, count: pixels * 4)
        image.withUnsafeMutableBufferPointer { out in
            let out = out
            merged.withUnsafeBufferPointer { merged in mask.withUnsafeBufferPointer { mask in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let fallback = mhc(x, y)
                        let measured = SIMD3(merged[i * 4] * wb[0], merged[i * 4 + 1] * wb[1], merged[i * 4 + 2] * wb[2])
                        let t = merged[i * 4 + 3] > 1.5 ? 1 : mask[i]
                        let cam = (measured + (fallback - measured) * t).clamped(lowerBound: .zero, upperBound: .one)
                        out[i * 4] = m[0] * cam.x + m[1] * cam.y + m[2] * cam.z
                        out[i * 4 + 1] = m[4] * cam.x + m[5] * cam.y + m[6] * cam.z
                        out[i * 4 + 2] = m[8] * cam.x + m[9] * cam.y + m[10] * cam.z
                        out[i * 4 + 3] = t
                    }
                }
            } }
        }
        return image
    }
}
