import Foundation
import CoreImage
import Metal
import simd

/// The full-size stack on the GPU. Each photo is developed by Core Image into a texture, warped onto the reference and
/// stored in half floats; the reduce then reads every photo's band of rows and writes one float result per pixel. The
/// arithmetic is `PhotoStackReduce`'s.
final class PhotoStackGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let storePipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState
    private var texture: MTLTexture?

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw EditorError.noGPU }
        // The thresholds are PhotoStackReduce's, so both paths reduce alike.
        let constants = """
        constant float CLIP = \(PhotoStackReduce.clip)f, CLIP_FLOOR = \(PhotoStackReduce.clipFloor)f, CLIP_ABSOLUTE = \(PhotoStackReduce.clipAbsolute)f;
        """
        let source = Self.source.replacingOccurrences(of: "// CONSTANTS", with: constants)
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState { try device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
        self.device = device; self.queue = queue
        storePipeline = try pipeline("stack_store"); reducePipeline = try pipeline("stack_reduce")
    }

    /// Mirrors `StoreParameters` in the shader.
    private struct StoreParameters {
        var width: UInt32, height: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
        var m00: Float, m01: Float, m10: Float, m11: Float, tx: Float, ty: Float, gain: Float
    }
    /// Mirrors `ReduceParameters` in the shader.
    private struct ReduceParameters {
        var pixels: UInt32, frames: UInt32, frameStride: UInt32, mode: UInt32
    }

    /// Develops `image`, warps it with `inverse` (output points to image pixels, top-left origin), scales it by `gain`
    /// and writes width × height half-float RGBA at `offset` in `buffer`, coverage in alpha.
    func store(_ image: CIImage, into buffer: MTLBuffer, offset: Int, width: Int, height: Int, context: CIContext,
               inverse: HDRSimilarity, gain: Float) throws {
        let sourceWidth = Int(image.extent.width.rounded(.down)), sourceHeight = Int(image.extent.height.rounded(.down))
        if texture == nil || texture!.width != sourceWidth || texture!.height != sourceHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: sourceWidth, height: sourceHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture, let commands = queue.makeCommandBuffer() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
        let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(sourceHeight)))
        context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                       colorSpace: PanoramaDecoder.space)
        let l = inverse.linear
        var parameters = StoreParameters(width: UInt32(width), height: UInt32(height), sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
                                         m00: Float(l[0][0]), m01: Float(l[1][0]), m10: Float(l[0][1]), m11: Float(l[1][1]),
                                         tx: Float(inverse.translation.x), ty: Float(inverse.translation.y), gain: gain)
        guard let encoder = commands.makeComputeCommandEncoder() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
        encoder.setComputePipelineState(storePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: offset, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<StoreParameters>.stride, index: 1)
        dispatch(encoder, storePipeline, width: width, height: height)
        encoder.endEncoding()
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    /// Reduces the stored photos band by band: each band's rows of every photo are gathered into one buffer (photo-major),
    /// reduced into the result and the next band follows, so the reduce never needs every photo's whole frame at once.
    func reduce(_ store: PhotoStackStore, width: Int, height: Int, mode: PhotoStackMode,
                progress: (Double) -> Void, cancelled: () -> Bool) throws -> PanoramaRaster {
        texture = nil
        let frames = store.count, rowBytes = width * 8
        let bandRows = max(1, min(height, (256 << 20) / max(1, rowBytes * frames)))
        guard let band = device.makeBuffer(length: bandRows * rowBytes * frames, options: .storageModeShared),
              let result = device.makeBuffer(length: bandRows * width * 16, options: .storageModeShared) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        var row = 0
        while row < height {
            if cancelled() { throw CancellationError() }
            let rows = min(bandRows, height - row), pixels = rows * width
            for k in 0..<frames {
                memcpy(band.contents() + k * pixels * 8, store.pointer(k) + row * rowBytes, pixels * 8)
            }
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
                throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
            }
            var parameters = ReduceParameters(pixels: UInt32(pixels), frames: UInt32(frames), frameStride: UInt32(pixels), mode: mode.code)
            encoder.setComputePipelineState(reducePipeline)
            encoder.setBuffer(band, offset: 0, index: 0)
            encoder.setBuffer(result, offset: 0, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<ReduceParameters>.stride, index: 2)
            let w = reducePipeline.maxTotalThreadsPerThreadgroup
            encoder.dispatchThreads(MTLSize(width: pixels, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            encoder.endEncoding()
            GPUForeground.wait(); commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
            rgba.withUnsafeMutableBytes { memcpy($0.baseAddress! + row * width * 16, result.contents(), pixels * 16) }
            row += rows
            progress(Double(row) / Double(height))
        }
        return PanoramaRaster(width: width, height: height, rgba: rgba)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct StoreParameters {
        uint width, height, sourceWidth, sourceHeight;
        float m00, m01, m10, m11, tx, ty, gain;
    };
    struct ReduceParameters { uint pixels, frames, frameStride, mode; };
    constant float3 LUMA = float3(0.2126f, 0.7152f, 0.0722f);
    // CONSTANTS

    static float3 texel(texture2d<float, access::read> source, int x, int y) {
        float3 v = source.read(uint2(x, y)).rgb;
        return select(v, float3(0), isnan(v) || isinf(v));
    }

    kernel void stack_store(texture2d<float, access::read> source [[texture(0)]], device half4 *out [[buffer(0)]],
                            constant StoreParameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint i = gid.y * p.width + gid.x;
        float qx = float(gid.x) + 0.5f, qy = float(gid.y) + 0.5f;
        float sx = p.m00 * qx + p.m01 * qy + p.tx - 0.5f, sy = p.m10 * qx + p.m11 * qy + p.ty - 0.5f;
        int sw = int(p.sourceWidth), sh = int(p.sourceHeight);
        if (sx < -0.5f || sy < -0.5f || sx > float(sw) - 0.5f || sy > float(sh) - 0.5f) { out[i] = half4(0); return; }
        int x0 = clamp(int(floor(sx)), 0, sw - 1), y0 = clamp(int(floor(sy)), 0, sh - 1);
        int x1 = min(sw - 1, x0 + 1), y1 = min(sh - 1, y0 + 1);
        float fx = clamp(sx - float(x0), 0.0f, 1.0f), fy = clamp(sy - float(y0), 0.0f, 1.0f);
        float3 top = texel(source, x0, y0) * (1 - fx) + texel(source, x1, y0) * fx;
        float3 bottom = texel(source, x0, y1) * (1 - fx) + texel(source, x1, y1) * fx;
        float3 rgb = min((top * (1 - fy) + bottom * fy) * p.gain, float3(65000));
        out[i] = half4(half3(rgb), 1);
    }

    // Hoare's selection over v[0..<n]: afterwards v[k] is the k-th smallest, smaller ones before it.
    static float median(thread float *v, int n) {
        int k = n / 2, left = 0, right = n - 1;
        while (left < right) {
            float pivot = v[(left + right) / 2];
            int i = left, j = right;
            while (i <= j) {
                while (v[i] < pivot) i++;
                while (v[j] > pivot) j--;
                if (i <= j) { float t = v[i]; v[i] = v[j]; v[j] = t; i++; j--; }
            }
            if (k <= j) right = j; else if (k >= i) left = i; else break;
        }
        float upper = v[k];
        if (n % 2 == 1) return upper;
        float lower = -INFINITY;
        for (int i = 0; i < k; i++) lower = max(lower, v[i]);
        return (lower + upper) * 0.5f;
    }

    kernel void stack_reduce(device const half4 *band [[buffer(0)]], device float4 *out [[buffer(1)]],
                             constant ReduceParameters &p [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= p.pixels) return;
        float r[128], g[128], b[128], work[128];
        float3 sum = 0, high = -INFINITY, low = INFINITY;
        int n = 0;
        for (uint k = 0; k < p.frames; k++) {
            half4 s = band[k * p.frameStride + gid];
            if (s.a < 0.5h) continue;
            float3 v = float3(s.rgb);
            sum += v; high = max(high, v); low = min(low, v);
            if (p.mode == 0 || p.mode == 4) { r[n] = v.r; g[n] = v.g; b[n] = v.b; }
            n++;
        }
        float3 value = 0;
        if (n > 0) {
            if (p.mode == 0) value = float3(median(r, n), median(g, n), median(b, n));
            else if (p.mode == 1) value = sum / float(n);
            else if (p.mode == 2) value = high;
            else if (p.mode == 3) value = low;
            else {
                // Clipped mean (4): each channel's median on a copy, the samples kept in order.
                float3 middle;
                for (int k = 0; k < n; k++) work[k] = r[k]; middle.r = median(work, n);
                for (int k = 0; k < n; k++) work[k] = g[k]; middle.g = median(work, n);
                for (int k = 0; k < n; k++) work[k] = b[k]; middle.b = median(work, n);
                float base = dot(middle, LUMA);
                for (int k = 0; k < n; k++) work[k] = abs(dot(float3(r[k], g[k], b[k]), LUMA) - base);
                float spread = max(1.4826f * median(work, n), CLIP_FLOOR * base + CLIP_ABSOLUTE);
                float3 kept = 0; float count = 0;
                for (int k = 0; k < n; k++) {
                    float3 v = float3(r[k], g[k], b[k]);
                    if (abs(dot(v, LUMA) - base) <= CLIP * spread) { kept += v; count += 1; }
                }
                value = count > 0 ? kept / count : middle;
            }
        }
        out[gid] = float4(value, 1);
    }
    """
}
