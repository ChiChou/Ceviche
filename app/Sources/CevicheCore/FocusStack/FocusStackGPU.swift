import Foundation
import CoreImage
import Metal
import simd

/// The full-size merge on the GPU: each photo is developed by Core Image straight into a texture, then compute passes
/// warp it onto the reference, measure its fine-band sharpness and blend it into running sums in GPU memory, so no photo
/// is copied back to the CPU; only the finished merge is. The arithmetic is `FocusStackCPUFusion`'s, in 32-bit float.
final class FocusStackGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]

    init(device: MTLDevice) {
        let queue = device.makeCommandQueue()!
        let options = MTLCompileOptions()
        // Precise exp and log keep the blend within float rounding of the CPU's.
        options.mathMode = .safe
        // Fixed source: a kernel that doesn't compile is a bug.
        let library = try! device.makeLibrary(source: Self.source, options: options)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["fs_warp", "fs_proxy", "fs_blur", "fs_band", "fs_labels", "fs_normalize", "fs_weigh", "fs_reduce", "fs_pyramid", "fs_collapse"] {
            pipelines[name] = try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        self.device = device; self.queue = queue; self.pipelines = pipelines
    }

    /// Mirrors `Warp` in the shader.
    private struct Warp {
        var width: UInt32, height: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
        var m00: Float, m01: Float, m10: Float, m11: Float, tx: Float, ty: Float, gain: Float
    }
    /// Mirrors `Blend` in the shader.
    private struct Blend {
        var width: UInt32, height: UInt32, priorWidth: UInt32, priorHeight: UInt32
        var priorOffsetX: Float, priorOffsetY: Float, priorScale: Float
        var noise: Float, reference: Float, noiseGain: Float, clip: Float, floorWeight: Float, refinement: Float, isReference: UInt32
        var hasPainted: UInt32
    }
    /// Mirrors `Blur` in the shader.
    private struct Blur { var width: UInt32, height: UInt32, radius: UInt32, horizontal: UInt32 }

    /// The running state of one merge.
    final class Fusion {
        let layout: FocusStackLayout
        fileprivate var texture: MTLTexture?
        /// The warped photo; for multiscale, its Gaussian pyramid, finest first, then the collapsed result.
        fileprivate var levels: [(width: Int, height: Int, buffer: MTLBuffer)] = []
        /// Labels: RGB × weight and weight, and the running peak logit. Multiscale: per level, RGB × weight and weight.
        fileprivate var sums: [MTLBuffer] = []
        fileprivate var peak: MTLBuffer?
        fileprivate var planes: [MTLBuffer] = []
        /// The layer brush's coverage on the prior grid, or one zero where nothing is painted.
        fileprivate var painted: MTLBuffer?

        fileprivate init?(device: MTLDevice, layout: FocusStackLayout) {
            self.layout = layout
            func buffer(_ length: Int) -> MTLBuffer? { device.makeBuffer(length: max(16, length), options: .storageModeShared) }
            var w = layout.width, h = layout.height
            let count = layout.blending == .labels ? 1 : layout.levels
            for _ in 0..<count {
                guard let level = buffer(w * h * 16), let sum = buffer(w * h * 16) else { return nil }
                memset(sum.contents(), 0, sum.length)
                levels.append((w, h, level)); sums.append(sum)
                w = (w + 1) / 2; h = (h + 1) / 2
            }
            if layout.blending == .labels {
                let n = layout.width * layout.height
                guard let peak = buffer(n * 4) else { return nil }
                let p = peak.contents().bindMemory(to: Float.self, capacity: n)
                for i in 0..<n { p[i] = -.infinity }
                self.peak = peak
                // Proxy, blurred proxy, squared band, scratch and energy.
                for _ in 0..<5 { guard let plane = buffer(n * 4) else { return nil }; planes.append(plane) }
                let coverage = layout.painted ?? [0]
                guard let painted = device.makeBuffer(bytes: coverage, length: coverage.count * 4, options: .storageModeShared) else { return nil }
                self.painted = painted
            }
        }
    }

    /// Buffers for one merge; throws when the GPU can't hold them.
    func fusion(_ layout: FocusStackLayout) throws -> Fusion {
        guard let fusion = Fusion(device: device, layout: layout) else { throw fail() }
        return fusion
    }

    private func fail() -> Error { PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }

    /// One aligned, exposure-matched source for the repair brush. Uses the fusion's exact cubic sampler.
    func aligned(_ image: CIImage, layout: FocusStackLayout, step: FocusStackFrameStep, context: CIContext) throws -> MTLBuffer {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor), let commands = queue.makeCommandBuffer(),
              let out = device.makeBuffer(length: layout.width * layout.height * 16, options: .storageModeShared) else { throw fail() }
        let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h)))
        context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: PanoramaDecoder.space)
        let l = step.inverse.linear
        var warp = Warp(width: UInt32(layout.width), height: UInt32(layout.height), sourceWidth: UInt32(w), sourceHeight: UInt32(h),
                        m00: Float(l[0][0]), m01: Float(l[1][0]), m10: Float(l[0][1]), m11: Float(l[1][1]),
                        tx: Float(step.inverse.translation.x), ty: Float(step.inverse.translation.y), gain: step.gain)
        try dispatch(commands, "fs_warp", layout.width, layout.height) { e in
            e.setTexture(texture, index: 0); e.setBuffer(out, offset: 0, index: 0); e.setBytes(&warp, length: MemoryLayout<Warp>.stride, index: 1)
        }
        GPUForeground.wait(); commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        return out
    }

    /// Develops `image` into the fusion's frame texture and blends it in.
    func add(_ image: CIImage, to fusion: Fusion, context: CIContext, step: FocusStackFrameStep, isReference: Bool) throws {
        let layout = fusion.layout
        let sourceWidth = Int(image.extent.width.rounded(.down)), sourceHeight = Int(image.extent.height.rounded(.down))
        if fusion.texture == nil || fusion.texture!.width != sourceWidth || fusion.texture!.height != sourceHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: sourceWidth, height: sourceHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            fusion.texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = fusion.texture, let commands = queue.makeCommandBuffer(),
              let prior = device.makeBuffer(bytes: step.prior, length: step.prior.count * 4) else { throw fail() }
        // Core Image's origin is the bottom left; flip so texture row 0 is the photo's top row, as on the CPU.
        let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(sourceHeight)))
        context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                       colorSpace: PanoramaDecoder.space)
        let l = step.inverse.linear
        var warp = Warp(width: UInt32(layout.width), height: UInt32(layout.height), sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
                        m00: Float(l[0][0]), m01: Float(l[1][0]), m10: Float(l[0][1]), m11: Float(l[1][1]),
                        tx: Float(step.inverse.translation.x), ty: Float(step.inverse.translation.y), gain: step.gain)
        var blend = Blend(width: UInt32(layout.width), height: UInt32(layout.height), priorWidth: UInt32(layout.priorWidth), priorHeight: UInt32(layout.priorHeight),
                          priorOffsetX: Float(layout.priorOffset.x), priorOffsetY: Float(layout.priorOffset.y), priorScale: Float(layout.priorScale),
                          noise: step.noise, reference: layout.noise, noiseGain: FocusStackFocus.noiseGains[0], clip: step.clip * step.gain,
                          floorWeight: FocusStackLayout.floorWeight, refinement: FocusStackLayout.refinement, isReference: isReference ? 1 : 0,
                          hasPainted: layout.painted == nil ? 0 : 1)
        let frame = fusion.levels[0].buffer
        try dispatch(commands, "fs_warp", layout.width, layout.height) { e in
            e.setTexture(texture, index: 0); e.setBuffer(frame, offset: 0, index: 0); e.setBytes(&warp, length: MemoryLayout<Warp>.stride, index: 1)
        }
        switch layout.blending {
        case .labels:
            let (proxy, blurred, squares, scratch, energy) = (fusion.planes[0], fusion.planes[1], fusion.planes[2], fusion.planes[3], fusion.planes[4])
            var count = UInt32(layout.width * layout.height)
            try dispatch(commands, "fs_proxy", layout.width, layout.height) { e in
                e.setBuffer(frame, offset: 0, index: 0); e.setBuffer(proxy, offset: 0, index: 1); e.setBytes(&count, length: 4, index: 2)
            }
            try blur(commands, proxy, into: blurred, scratch: scratch, sigma: FocusStackFocus.sigmas[0], layout: layout)
            try dispatch(commands, "fs_band", layout.width, layout.height) { e in
                e.setBuffer(proxy, offset: 0, index: 0); e.setBuffer(blurred, offset: 0, index: 1); e.setBuffer(squares, offset: 0, index: 2)
                e.setBytes(&count, length: 4, index: 3)
            }
            try blur(commands, squares, into: energy, scratch: scratch, sigma: FocusStackFocus.windows[0], layout: layout)
            try dispatch(commands, "fs_labels", layout.width, layout.height) { e in
                e.setBuffer(frame, offset: 0, index: 0); e.setBuffer(energy, offset: 0, index: 1); e.setBuffer(prior, offset: 0, index: 2)
                e.setBuffer(fusion.sums[0], offset: 0, index: 3); e.setBuffer(fusion.peak!, offset: 0, index: 4)
                e.setBytes(&blend, length: MemoryLayout<Blend>.stride, index: 5); e.setBuffer(fusion.painted!, offset: 0, index: 6)
            }
        case .multiscale:
            try dispatch(commands, "fs_weigh", layout.width, layout.height) { e in
                e.setBuffer(frame, offset: 0, index: 0); e.setBuffer(prior, offset: 0, index: 1)
                e.setBytes(&blend, length: MemoryLayout<Blend>.stride, index: 2)
            }
            for l in fusion.levels.indices {
                let level = fusion.levels[l], coarser = l + 1 < fusion.levels.count ? fusion.levels[l + 1] : nil
                if let coarser {
                    var sizes = SIMD4<UInt32>(UInt32(level.width), UInt32(level.height), UInt32(coarser.width), UInt32(coarser.height))
                    try dispatch(commands, "fs_reduce", coarser.width, coarser.height) { e in
                        e.setBuffer(level.buffer, offset: 0, index: 0); e.setBuffer(coarser.buffer, offset: 0, index: 1)
                        e.setBytes(&sizes, length: 16, index: 2)
                    }
                }
                var sizes = SIMD4<UInt32>(UInt32(level.width), UInt32(level.height), UInt32(coarser?.width ?? 1), UInt32(coarser?.height ?? 1))
                var hasCoarse = UInt32(coarser == nil ? 0 : 1)
                try dispatch(commands, "fs_pyramid", level.width, level.height) { e in
                    e.setBuffer(level.buffer, offset: 0, index: 0); e.setBuffer((coarser ?? level).buffer, offset: 0, index: 1)
                    e.setBuffer(fusion.sums[l], offset: 0, index: 2); e.setBytes(&sizes, length: 16, index: 3); e.setBytes(&hasCoarse, length: 4, index: 4)
                }
            }
        }
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    /// A separable Gaussian, rows into `scratch`, then columns into `output`.
    private func blur(_ commands: MTLCommandBuffer, _ input: MTLBuffer, into output: MTLBuffer, scratch: MTLBuffer, sigma: Float, layout: FocusStackLayout) throws {
        let weights = FocusStackFilters.gaussianWeights(sigma: sigma)
        for horizontal in [true, false] {
            var parameters = Blur(width: UInt32(layout.width), height: UInt32(layout.height), radius: UInt32(weights.count - 1), horizontal: horizontal ? 1 : 0)
            try dispatch(commands, "fs_blur", layout.width, layout.height) { e in
                e.setBuffer(horizontal ? input : scratch, offset: 0, index: 0); e.setBuffer(horizontal ? scratch : output, offset: 0, index: 1)
                e.setBytes(&parameters, length: MemoryLayout<Blur>.stride, index: 2)
                e.setBytes(weights, length: weights.count * 4, index: 3)
            }
        }
    }

    /// Normalizes (labels) or collapses (multiscale) on the GPU and copies the result out.
    func finish(_ fusion: Fusion) throws -> PanoramaRaster {
        fusion.texture = nil
        guard let commands = queue.makeCommandBuffer() else { throw fail() }
        let layout = fusion.layout
        let result: MTLBuffer
        switch layout.blending {
        case .labels:
            var size = SIMD2<UInt32>(UInt32(layout.width), UInt32(layout.height))
            try dispatch(commands, "fs_normalize", layout.width, layout.height) { e in
                e.setBuffer(fusion.sums[0], offset: 0, index: 0); e.setBytes(&size, length: 8, index: 1)
            }
            result = fusion.sums[0]
        case .multiscale:
            // Each level's result replaces that level of the photo pyramid, which is no longer needed.
            for l in stride(from: fusion.levels.count - 1, through: 0, by: -1) {
                let level = fusion.levels[l], previous = l + 1 < fusion.levels.count ? fusion.levels[l + 1] : nil
                var sizes = SIMD4<UInt32>(UInt32(level.width), UInt32(level.height), UInt32(previous?.width ?? 1), UInt32(previous?.height ?? 1))
                var top = UInt32(previous == nil ? 1 : 0)
                try dispatch(commands, "fs_collapse", level.width, level.height) { e in
                    e.setBuffer(fusion.sums[l], offset: 0, index: 0); e.setBuffer((previous ?? level).buffer, offset: 0, index: 1)
                    e.setBuffer(level.buffer, offset: 0, index: 2); e.setBytes(&sizes, length: 16, index: 3); e.setBytes(&top, length: 4, index: 4)
                }
            }
            result = fusion.levels[0].buffer
        }
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        let count = layout.width * layout.height * 4
        let rgba = [Float](unsafeUninitializedCapacity: count) { out, initialized in
            memcpy(out.baseAddress!, result.contents(), count * 4); initialized = count
        }
        return PanoramaRaster(width: layout.width, height: layout.height, rgba: rgba)
    }

    /// One pass in its own encoder, so passes run in order.
    private func dispatch(_ commands: MTLCommandBuffer, _ name: String, _ width: Int, _ height: Int, _ setup: (MTLComputeCommandEncoder) -> Void) throws {
        guard let pipeline = pipelines[name], let encoder = commands.makeComputeCommandEncoder() else { throw fail() }
        encoder.setComputePipelineState(pipeline)
        setup(encoder)
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Warp {
        uint width, height, sourceWidth, sourceHeight;
        float m00, m01, m10, m11, tx, ty, gain;
    };
    struct Blend {
        uint width, height, priorWidth, priorHeight;
        float priorOffsetX, priorOffsetY, priorScale;
        float noise, reference, noiseGain, clip, floorWeight, refinement; uint isReference;
        uint hasPainted;
    };
    struct Blur { uint width, height, radius, horizontal; };

    static float3 texel(texture2d<float, access::read> source, int x, int y) {
        float3 v = source.read(uint2(x, y)).rgb;
        return select(v, float3(0), isnan(v) || isinf(v));
    }

    static float4 cubicWeights(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-t3 + 2 * t2 - t, 3 * t3 - 5 * t2 + 2, -3 * t3 + 4 * t2 + t, t3 - t2) * 0.5f;
    }

    // Catmull-Rom, with points beyond the edge clamped to it and marked uncovered in alpha.
    kernel void fs_warp(texture2d<float, access::read> source [[texture(0)]], device float4 *out [[buffer(0)]],
                        constant Warp &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        float qx = float(gid.x) + 0.5f, qy = float(gid.y) + 0.5f;
        float sx = p.m00 * qx + p.m01 * qy + p.tx - 0.5f, sy = p.m10 * qx + p.m11 * qy + p.ty - 0.5f;
        int sw = int(p.sourceWidth), sh = int(p.sourceHeight);
        bool inside = sx >= -0.5f && sy >= -0.5f && sx <= float(sw) - 0.5f && sy <= float(sh) - 0.5f;
        sx = clamp(sx, 0.0f, float(sw - 1)); sy = clamp(sy, 0.0f, float(sh - 1));
        int x0 = int(sx), y0 = int(sy);
        float4 wx = cubicWeights(sx - float(x0)), wy = cubicWeights(sy - float(y0));
        float3 sum = 0;
        for (int j = 0; j < 4; j++) {
            int y = clamp(y0 - 1 + j, 0, sh - 1);
            float3 line = 0;
            for (int i = 0; i < 4; i++) line += wx[i] * texel(source, clamp(x0 - 1 + i, 0, sw - 1), y);
            sum += wy[j] * line;
        }
        out[gid.y * p.width + gid.x] = float4(max(sum, float3(0)) * p.gain, inside ? 1.0f : 0.0f);
    }

    kernel void fs_proxy(device const float4 *rgba [[buffer(0)]], device float *out [[buffer(1)]], constant uint &count [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]], uint2 size [[threads_per_grid]]) {
        uint i = gid.y * size.x + gid.x;
        if (i >= count) return;
        out[i] = sqrt(max(0.0f, dot(rgba[i].rgb, float3(0.2126f, 0.7152f, 0.0722f))) + 1e-6f);
    }

    kernel void fs_blur(device const float *input [[buffer(0)]], device float *output [[buffer(1)]], constant Blur &p [[buffer(2)]],
                        constant float *weights [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        int x = int(gid.x), y = int(gid.y), w = int(p.width), h = int(p.height);
        float sum = weights[0] * input[y * w + x];
        for (int k = 1; k <= int(p.radius); k++) {
            if (p.horizontal != 0) sum += weights[k] * (input[y * w + max(0, x - k)] + input[y * w + min(w - 1, x + k)]);
            else sum += weights[k] * (input[max(0, y - k) * w + x] + input[min(h - 1, y + k) * w + x]);
        }
        output[y * w + x] = sum;
    }

    kernel void fs_band(device const float *proxy [[buffer(0)]], device const float *blurred [[buffer(1)]], device float *out [[buffer(2)]],
                        constant uint &count [[buffer(3)]], uint2 gid [[thread_position_in_grid]], uint2 size [[threads_per_grid]]) {
        uint i = gid.y * size.x + gid.x;
        if (i >= count) return;
        float d = proxy[i] - blurred[i];
        out[i] = d * d;
    }

    static float prior(device const float *map, constant Blend &p, uint2 gid) {
        int pw = int(p.priorWidth), ph = int(p.priorHeight);
        float mx = clamp((float(gid.x) + 0.5f + p.priorOffsetX) * p.priorScale - 0.5f, 0.0f, float(pw - 1));
        float my = clamp((float(gid.y) + 0.5f + p.priorOffsetY) * p.priorScale - 0.5f, 0.0f, float(ph - 1));
        int a0 = int(mx), b0 = int(my), a1 = min(pw - 1, a0 + 1), b1 = min(ph - 1, b0 + 1);
        float gx = mx - float(a0), gy = my - float(b0);
        float upper = map[b0 * pw + a0] * (1 - gx) + map[b0 * pw + a1] * gx;
        float lower = map[b1 * pw + a0] * (1 - gx) + map[b1 * pw + a1] * gx;
        return upper * (1 - gy) + lower * gy;
    }

    // A streaming softmax over photos of log(analysis weight) + fine-band signal-to-noise.
    kernel void fs_labels(device const float4 *rgba [[buffer(0)]], device const float *energy [[buffer(1)]], device const float *map [[buffer(2)]],
                          device float4 *sum [[buffer(3)]], device float *peak [[buffer(4)]], constant Blend &p [[buffer(5)]],
                          device const float *painted [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint i = gid.y * p.width + gid.x;
        float4 v = rgba[i];
        if (!(v.a > 0.999f)) return;
        float lock = p.hasPainted != 0 ? prior(painted, p, gid) : 0.0f;
        float value = log(max(prior(map, p, gid), p.floorWeight))
            + p.refinement * (1 - lock) * log(1 + max(0.0f, energy[i] - 2 * p.noise * p.noiseGain) / (p.reference * p.noiseGain + 1e-8f));
        if (max(v.r, max(v.g, v.b)) > 0.95f * p.clip) value -= 2;
        float best = peak[i];
        float4 s = sum[i];
        if (value > best) {
            s *= isinf(best) ? 0.0f : exp(best - value);
            best = value; peak[i] = value;
        }
        float w = exp(value - best);
        sum[i] = s + float4(v.rgb * w, w);
    }

    kernel void fs_normalize(device float4 *sum [[buffer(0)]], constant uint2 &size [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.x || gid.y >= size.y) return;
        uint i = gid.y * size.x + gid.x;
        float4 s = sum[i];
        sum[i] = s.w > 0 ? float4(s.rgb / s.w, 1) : float4(0, 0, 0, 1);
    }

    kernel void fs_weigh(device float4 *rgba [[buffer(0)]], device const float *map [[buffer(1)]], constant Blend &p [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint i = gid.y * p.width + gid.x;
        float w = prior(map, p, gid);
        rgba[i].a *= p.isReference != 0 ? max(w, 1e-6f) : w;
    }

    kernel void fs_reduce(device const float4 *input [[buffer(0)]], device float4 *output [[buffer(1)]], constant uint4 &s [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= s.z || gid.y >= s.w) return;
        const float taps[4] = { 0.125f, 0.375f, 0.375f, 0.125f };
        int w = int(s.x), h = int(s.y);
        float4 sum = 0;
        for (int j = 0; j < 4; j++) {
            int sy = clamp(2 * int(gid.y) - 1 + j, 0, h - 1);
            for (int i = 0; i < 4; i++) {
                int sx = clamp(2 * int(gid.x) - 1 + i, 0, w - 1);
                sum += taps[i] * taps[j] * input[sy * w + sx];
            }
        }
        output[gid.y * s.z + gid.x] = sum;
    }

    static float4 expand(device const float4 *coarse, int w, int h, uint2 gid) {
        float cx = clamp((float(gid.x) + 0.5f) / 2 - 0.5f, 0.0f, float(w - 1)), cy = clamp((float(gid.y) + 0.5f) / 2 - 0.5f, 0.0f, float(h - 1));
        int x0 = int(cx), y0 = int(cy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1);
        float fx = cx - float(x0), fy = cy - float(y0);
        return (coarse[y0 * w + x0] * (1 - fx) + coarse[y0 * w + x1] * fx) * (1 - fy) + (coarse[y1 * w + x0] * (1 - fx) + coarse[y1 * w + x1] * fx) * fy;
    }

    kernel void fs_pyramid(device const float4 *level [[buffer(0)]], device const float4 *coarse [[buffer(1)]], device float4 *sum [[buffer(2)]],
                           constant uint4 &s [[buffer(3)]], constant uint &hasCoarse [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= s.x || gid.y >= s.y) return;
        uint i = gid.y * s.x + gid.x;
        float4 v = level[i];
        if (!(v.a > 0)) return;
        float3 detail = v.rgb;
        if (hasCoarse != 0) detail -= expand(coarse, int(s.z), int(s.w), gid).rgb;
        sum[i] += float4(detail * v.a, v.a);
    }

    kernel void fs_collapse(device const float4 *sum [[buffer(0)]], device const float4 *previous [[buffer(1)]], device float4 *out [[buffer(2)]],
                            constant uint4 &s [[buffer(3)]], constant uint &top [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= s.x || gid.y >= s.y) return;
        uint i = gid.y * s.x + gid.x;
        float4 v = sum[i];
        float3 value = v.w > 0 ? v.rgb / v.w : float3(0);
        if (top == 0) value += expand(previous, int(s.z), int(s.w), gid).rgb;
        out[i] = float4(value, 1);
    }
    """
}
