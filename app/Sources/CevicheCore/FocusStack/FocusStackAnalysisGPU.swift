import Foundation
import Metal
import simd

/// Analysis's dense work on the GPU, the same arithmetic as the CPU path in 32-bit float: each reduced photo warped onto
/// the reference, its exposure matched, its sharpness proxy, noise and per-pixel sharpness measured (`FocusStackFocus`),
/// the sharpest-photo composite the depth model reads, and the edge-aware blend's guided spreading of each photo's
/// label. Buffers are shared, so the CPU reads results without copies through the GPU.
final class FocusStackAnalysisGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]

    init(device: MTLDevice) {
        let queue = device.makeCommandQueue()!
        let options = MTLCompileOptions()
        options.mathMode = .safe
        // Fixed source: a kernel that doesn't compile is a bug.
        let library = try! device.makeLibrary(source: Self.source, options: options)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["fa_warp", "fa_proxy", "fa_blur", "fa_square_difference", "fa_block_variance", "fa_focus", "fa_composite",
                     "fa_box", "fa_multiply", "fa_coefficients", "fa_combine", "fa_label", "fa_weight"] {
            pipelines[name] = try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        self.device = device; self.queue = queue; self.pipelines = pipelines
    }

    private struct Warp {
        var width: UInt32, height: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
        var m00: Float, m01: Float, m10: Float, m11: Float, tx: Float, ty: Float
    }
    private struct Plane { var width: UInt32, height: UInt32, radius: UInt32, horizontal: UInt32 }
    private struct Focus {
        var count: UInt32, gain: Float, clip: Float
        var expected0: Float, expected1: Float, expected2: Float, scale0: Float, scale1: Float, scale2: Float
    }

    struct Prepared {
        var gains: [Float]
        var noise: [Float]
        var focus: [[Float]]
        var proxies: [[Float]]
        /// The sharpest photo at each pixel, exposure matched, RGBA.
        var composite: [Float]
    }

    /// `FocusStacker.prepare`'s measurements: `inverses[i]` maps the reference's analysis pixels into photo `i`.
    func prepare(sources: [PanoramaFrame], inverses: [HDRSimilarity], reference: Int, clips: [Float], width: Int, height: Int,
                 cancelled: () -> Bool) throws -> Prepared {
        let n = width * height, count = sources.count
        func buffer(_ length: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared) else { throw fail() }
            return b
        }
        let aligned = try buffer(n * 16), referenceAligned = try buffer(n * 16), composite = try buffer(n * 16), best = try buffer(n * 4)
        let proxy = try buffer(n * 4), b1 = try buffer(n * 4), b2 = try buffer(n * 4), b3 = try buffer(n * 4)
        let squares = try buffer(n * 4), scratch = try buffer(n * 4), e0 = try buffer(n * 4), e1 = try buffer(n * 4), e2 = try buffer(n * 4)
        let focusBuffer = try buffer(n * 4)
        let blocksX = max(0, (width - 12 - 4 + 7) / 8), blocksY = max(0, (height - 12 - 4 + 7) / 8)
        let variances = try buffer(blocksX * blocksY * 4)
        var texture: MTLTexture?

        func upload(_ frame: PanoramaFrame) throws -> MTLTexture {
            if texture == nil || texture!.width != frame.width || texture!.height != frame.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: frame.width, height: frame.height, mipmapped: false)
                descriptor.usage = [.shaderRead]; descriptor.storageMode = .shared
                texture = device.makeTexture(descriptor: descriptor)
            }
            guard let texture else { throw fail() }
            frame.pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: frame.width * 16)
            }
            return texture
        }
        func warp(_ commands: MTLCommandBuffer, _ i: Int, into output: MTLBuffer) throws {
            let source = try upload(sources[i])
            let l = inverses[i].linear, t = inverses[i].translation
            var p = Warp(width: UInt32(width), height: UInt32(height), sourceWidth: UInt32(sources[i].width), sourceHeight: UInt32(sources[i].height),
                         m00: Float(l[0][0]), m01: Float(l[1][0]), m10: Float(l[0][1]), m11: Float(l[1][1]), tx: Float(t.x), ty: Float(t.y))
            try dispatch(commands, "fa_warp", width, height) { e in
                e.setTexture(source, index: 0); e.setBuffer(output, offset: 0, index: 0); e.setBytes(&p, length: MemoryLayout<Warp>.stride, index: 1)
            }
        }
        func run(_ body: (MTLCommandBuffer) throws -> Void) throws {
            guard let commands = queue.makeCommandBuffer() else { throw fail() }
            try body(commands)
            GPUForeground.wait(); commands.commit(); commands.waitUntilCompleted()
            if let error = commands.error { throw error }
        }
        var countValue = UInt32(n)
        func proxyPass(_ commands: MTLCommandBuffer, gain: Float) throws {
            var g = gain
            try dispatch(commands, "fa_proxy", n, 1) { e in
                e.setBuffer(aligned, offset: 0, index: 0); e.setBuffer(proxy, offset: 0, index: 1)
                e.setBytes(&countValue, length: 4, index: 2); e.setBytes(&g, length: 4, index: 3)
            }
        }

        // Pass one: warp, exposure gain against the reference, proxy and noise.
        try run { try warp($0, reference, into: referenceAligned) }
        let referencePixels = UnsafeBufferPointer(start: referenceAligned.contents().assumingMemoryBound(to: Float.self), count: n * 4)
        var gains = [Float](repeating: 1, count: count), noise = [Float](repeating: 0, count: count)
        var proxies = [[Float]](repeating: [], count: count)
        for i in 0..<count {
            if cancelled() { throw CancellationError() }
            try run { commands in try warp(commands, i, into: aligned) }
            let pixels = UnsafeBufferPointer(start: aligned.contents().assumingMemoryBound(to: Float.self), count: n * 4)
            gains[i] = i == reference ? 1 : FocusStacker.exposureGain(pixels, onto: referencePixels, clip: min(clips[i], clips[reference]))
            try run { commands in
                try proxyPass(commands, gain: gains[i])
                try blur(commands, proxy, into: b1, scratch: scratch, sigma: FocusStackFocus.sigmas[0], width: width, height: height)
                var p = Plane(width: UInt32(width), height: UInt32(height), radius: UInt32(blocksX), horizontal: UInt32(blocksY))
                try dispatch(commands, "fa_block_variance", blocksX, blocksY) { e in
                    e.setBuffer(proxy, offset: 0, index: 0); e.setBuffer(b1, offset: 0, index: 1); e.setBuffer(variances, offset: 0, index: 2)
                    e.setBytes(&p, length: MemoryLayout<Plane>.stride, index: 3)
                }
            }
            proxies[i] = Array(UnsafeBufferPointer(start: proxy.contents().assumingMemoryBound(to: Float.self), count: n))
            var blockVariances = Array(UnsafeBufferPointer(start: variances.contents().assumingMemoryBound(to: Float.self), count: blocksX * blocksY))
            if !blockVariances.isEmpty {
                blockVariances.sort()
                noise[i] = blockVariances[blockVariances.count / 10] / 0.6 / FocusStackFocus.noiseGains[0]
            }
        }
        let typical = noise.sorted()[count / 2]

        // Pass two: sharpness against each photo's noise, and the sharpest-photo composite.
        memcpy(composite.contents(), referenceAligned.contents(), n * 16)
        let bestPointer = best.contents().assumingMemoryBound(to: Float.self)
        for k in 0..<n { bestPointer[k] = -.infinity }
        var focus = [[Float]](repeating: [], count: count)
        for i in 0..<count {
            if cancelled() { throw CancellationError() }
            try run { commands in
                try warp(commands, i, into: aligned)
                try proxyPass(commands, gain: gains[i])
                let s = FocusStackFocus.sigmas
                try blur(commands, proxy, into: b1, scratch: scratch, sigma: s[0], width: width, height: height)
                try blur(commands, b1, into: b2, scratch: scratch, sigma: (s[1] * s[1] - s[0] * s[0]).squareRoot(), width: width, height: height)
                try blur(commands, b2, into: b3, scratch: scratch, sigma: (s[2] * s[2] - s[1] * s[1]).squareRoot(), width: width, height: height)
                for (band, (a, b, energy)) in [(proxy, b1, e0), (b1, b2, e1), (b2, b3, e2)].enumerated() {
                    try dispatch(commands, "fa_square_difference", n, 1) { e in
                        e.setBuffer(a, offset: 0, index: 0); e.setBuffer(b, offset: 0, index: 1); e.setBuffer(squares, offset: 0, index: 2)
                        e.setBytes(&countValue, length: 4, index: 3)
                    }
                    try blur(commands, squares, into: energy, scratch: scratch, sigma: FocusStackFocus.windows[band], width: width, height: height)
                }
                let g = FocusStackFocus.noiseGains
                var p = Focus(count: UInt32(n), gain: gains[i], clip: clips[i],
                              expected0: 2 * noise[i] * g[0], expected1: 2 * noise[i] * g[1], expected2: 2 * noise[i] * g[2],
                              scale0: typical * g[0] + 1e-8, scale1: typical * g[1] + 1e-8, scale2: typical * g[2] + 1e-8)
                try dispatch(commands, "fa_focus", n, 1) { e in
                    e.setBuffer(aligned, offset: 0, index: 0); e.setBuffer(e0, offset: 0, index: 1); e.setBuffer(e1, offset: 0, index: 2)
                    e.setBuffer(e2, offset: 0, index: 3); e.setBuffer(focusBuffer, offset: 0, index: 4)
                    e.setBytes(&p, length: MemoryLayout<Focus>.stride, index: 5)
                }
                try dispatch(commands, "fa_composite", n, 1) { e in
                    e.setBuffer(aligned, offset: 0, index: 0); e.setBuffer(focusBuffer, offset: 0, index: 1); e.setBuffer(best, offset: 0, index: 2)
                    e.setBuffer(composite, offset: 0, index: 3); e.setBytes(&p, length: MemoryLayout<Focus>.stride, index: 4)
                }
            }
            focus[i] = Array(UnsafeBufferPointer(start: focusBuffer.contents().assumingMemoryBound(to: Float.self), count: n))
        }
        let mixed = Array(UnsafeBufferPointer(start: composite.contents().assumingMemoryBound(to: Float.self), count: n * 4))
        return Prepared(gains: gains, noise: noise, focus: focus, proxies: proxies, composite: mixed)
    }

    /// The edge-aware blend's spreading (`FocusStacker.weights`, labels): for each included photo, its confidence-
    /// weighted label guided by `guide`, with a wide average where no confident choice is near, squared. Not normalized.
    func spread(best: [Int], confidence: [Float], guide: [Float], focus: [[Float]], included: [Int], width: Int, height: Int,
                radius: Int, wide: Int, epsilon: Float, blend: Float) throws -> [Int: [Float]] {
        let n = width * height
        func buffer(_ length: Int) throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared) else { throw fail() }
            return b
        }
        func upload(_ values: [Float]) throws -> MTLBuffer {
            guard let b = device.makeBuffer(bytes: values, length: max(16, values.count * 4), options: .storageModeShared) else { throw fail() }
            return b
        }
        let guideBuffer = try upload(guide), confidenceBuffer = try upload(confidence)
        let bestBuffer = try buffer(n * 4)
        let bestPointer = bestBuffer.contents().assumingMemoryBound(to: Int32.self)
        for k in 0..<n { bestPointer[k] = Int32(best[k]) }
        let meanI = try buffer(n * 4), corrII = try buffer(n * 4), denominator = try buffer(n * 4), wideDenominator = try buffer(n * 4)
        let label = try buffer(n * 4), product = try buffer(n * 4), meanP = try buffer(n * 4), corrIP = try buffer(n * 4)
        let a = try buffer(n * 4), b = try buffer(n * 4), meanA = try buffer(n * 4), meanB = try buffer(n * 4), local = try buffer(n * 4)
        let broad = try buffer(n * 4), scratch = try buffer(n * 4), scratch2 = try buffer(n * 4), weight = try buffer(n * 4)
        let focusBuffer = try buffer(n * 4)
        var countValue = UInt32(n), eps = epsilon

        func box(_ commands: MTLCommandBuffer, _ input: MTLBuffer, into output: MTLBuffer, radius r: Int) throws {
            for horizontal in [true, false] {
                var p = Plane(width: UInt32(width), height: UInt32(height), radius: UInt32(r), horizontal: horizontal ? 1 : 0)
                try dispatch(commands, "fa_box", horizontal ? height : width, 1) { e in
                    e.setBuffer(horizontal ? input : scratch2, offset: 0, index: 0); e.setBuffer(horizontal ? scratch2 : output, offset: 0, index: 1)
                    e.setBytes(&p, length: MemoryLayout<Plane>.stride, index: 2)
                }
            }
        }
        func multiply(_ commands: MTLCommandBuffer, _ x: MTLBuffer, _ y: MTLBuffer, into output: MTLBuffer) throws {
            try dispatch(commands, "fa_multiply", n, 1) { e in
                e.setBuffer(x, offset: 0, index: 0); e.setBuffer(y, offset: 0, index: 1); e.setBuffer(output, offset: 0, index: 2)
                e.setBytes(&countValue, length: 4, index: 3)
            }
        }
        /// He's guided filter of `input` (already in `meanP`'s source) into `output`.
        func guided(_ commands: MTLCommandBuffer, _ input: MTLBuffer, into output: MTLBuffer) throws {
            try box(commands, input, into: meanP, radius: radius)
            try multiply(commands, guideBuffer, input, into: product)
            try box(commands, product, into: corrIP, radius: radius)
            try dispatch(commands, "fa_coefficients", n, 1) { e in
                e.setBuffer(meanI, offset: 0, index: 0); e.setBuffer(corrII, offset: 0, index: 1); e.setBuffer(meanP, offset: 0, index: 2)
                e.setBuffer(corrIP, offset: 0, index: 3); e.setBuffer(a, offset: 0, index: 4); e.setBuffer(b, offset: 0, index: 5)
                e.setBytes(&countValue, length: 4, index: 6); e.setBytes(&eps, length: 4, index: 7)
            }
            try box(commands, a, into: meanA, radius: radius)
            try box(commands, b, into: meanB, radius: radius)
            try dispatch(commands, "fa_combine", n, 1) { e in
                e.setBuffer(meanA, offset: 0, index: 0); e.setBuffer(meanB, offset: 0, index: 1); e.setBuffer(guideBuffer, offset: 0, index: 2)
                e.setBuffer(output, offset: 0, index: 3); e.setBytes(&countValue, length: 4, index: 4)
            }
        }
        func run(_ body: (MTLCommandBuffer) throws -> Void) throws {
            guard let commands = queue.makeCommandBuffer() else { throw fail() }
            try body(commands)
            GPUForeground.wait(); commands.commit(); commands.waitUntilCompleted()
            if let error = commands.error { throw error }
        }

        try run { commands in
            try box(commands, guideBuffer, into: meanI, radius: radius)
            try multiply(commands, guideBuffer, guideBuffer, into: product)
            try box(commands, product, into: corrII, radius: radius)
            try guided(commands, confidenceBuffer, into: denominator)
            try box(commands, confidenceBuffer, into: scratch, radius: wide)
            try box(commands, scratch, into: wideDenominator, radius: wide)
        }
        var weights: [Int: [Float]] = [:]
        for i in included {
            memcpy(focusBuffer.contents(), focus[i], n * 4)
            try run { commands in
                var index = Int32(i)
                try dispatch(commands, "fa_label", n, 1) { e in
                    e.setBuffer(bestBuffer, offset: 0, index: 0); e.setBuffer(confidenceBuffer, offset: 0, index: 1); e.setBuffer(label, offset: 0, index: 2)
                    e.setBytes(&countValue, length: 4, index: 3); e.setBytes(&index, length: 4, index: 4)
                }
                try guided(commands, label, into: local)
                try box(commands, label, into: scratch, radius: wide)
                try box(commands, scratch, into: broad, radius: wide)
                var parameters = SIMD4<Float>(blend, 1 / Float(included.count), 0, 0)
                try dispatch(commands, "fa_weight", n, 1) { e in
                    e.setBuffer(local, offset: 0, index: 0); e.setBuffer(broad, offset: 0, index: 1); e.setBuffer(denominator, offset: 0, index: 2)
                    e.setBuffer(wideDenominator, offset: 0, index: 3); e.setBuffer(focusBuffer, offset: 0, index: 4); e.setBuffer(weight, offset: 0, index: 5)
                    e.setBytes(&countValue, length: 4, index: 6); e.setBytes(&parameters, length: 16, index: 7)
                }
            }
            weights[i] = Array(UnsafeBufferPointer(start: weight.contents().assumingMemoryBound(to: Float.self), count: n))
        }
        return weights
    }

    /// A separable Gaussian, rows into `scratch`, then columns into `output`.
    private func blur(_ commands: MTLCommandBuffer, _ input: MTLBuffer, into output: MTLBuffer, scratch: MTLBuffer, sigma: Float, width: Int, height: Int) throws {
        let weights = FocusStackFilters.gaussianWeights(sigma: sigma)
        for horizontal in [true, false] {
            var p = Plane(width: UInt32(width), height: UInt32(height), radius: UInt32(weights.count - 1), horizontal: horizontal ? 1 : 0)
            try dispatch(commands, "fa_blur", width, height) { e in
                e.setBuffer(horizontal ? input : scratch, offset: 0, index: 0); e.setBuffer(horizontal ? scratch : output, offset: 0, index: 1)
                e.setBytes(&p, length: MemoryLayout<Plane>.stride, index: 2)
                e.setBytes(weights, length: weights.count * 4, index: 3)
            }
        }
    }

    /// One pass in its own encoder, so passes run in order.
    private func dispatch(_ commands: MTLCommandBuffer, _ name: String, _ width: Int, _ height: Int, _ setup: (MTLComputeCommandEncoder) -> Void) throws {
        guard width > 0, height > 0 else { return }
        guard let pipeline = pipelines[name], let encoder = commands.makeComputeCommandEncoder() else { throw fail() }
        encoder.setComputePipelineState(pipeline)
        setup(encoder)
        let w = pipeline.threadExecutionWidth, h = height == 1 ? 1 : max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    private func fail() -> Error { PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Warp {
        uint width, height, sourceWidth, sourceHeight;
        float m00, m01, m10, m11, tx, ty;
    };
    struct Plane { uint width, height, radius, horizontal; };
    struct Focus {
        uint count; float gain, clip;
        float expected0, expected1, expected2, scale0, scale1, scale2;
    };

    static float3 texel(texture2d<float, access::read> source, int x, int y) {
        float3 v = source.read(uint2(x, y)).rgb;
        return select(v, float3(0), isnan(v) || isinf(v));
    }
    static float4 cubicWeights(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-t3 + 2 * t2 - t, 3 * t3 - 5 * t2 + 2, -3 * t3 + 4 * t2 + t, t3 - t2) * 0.5f;
    }

    // Catmull-Rom, as the merge's fs_warp, without a gain.
    kernel void fa_warp(texture2d<float, access::read> source [[texture(0)]], device float4 *out [[buffer(0)]],
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
        out[gid.y * p.width + gid.x] = float4(max(sum, float3(0)), inside ? 1.0f : 0.0f);
    }

    kernel void fa_proxy(device const float4 *rgba [[buffer(0)]], device float *out [[buffer(1)]], constant uint &count [[buffer(2)]],
                         constant float &gain [[buffer(3)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float3 v = rgba[gid].rgb * gain;
        out[gid] = sqrt(max(0.0f, 0.2126f * v.r + 0.7152f * v.g + 0.0722f * v.b) + 1e-6f);
    }

    kernel void fa_blur(device const float *input [[buffer(0)]], device float *output [[buffer(1)]], constant Plane &p [[buffer(2)]],
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

    kernel void fa_square_difference(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *out [[buffer(2)]],
                                     constant uint &count [[buffer(3)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float d = a[gid] - b[gid];
        out[gid] = d * d;
    }

    // The finest band's variance in an 8 × 8 block from (4, 4) on: radius and horizontal carry the block grid's size.
    kernel void fa_block_variance(device const float *proxy [[buffer(0)]], device const float *blurred [[buffer(1)]],
                                  device float *out [[buffer(2)]], constant Plane &p [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.radius || gid.y >= p.horizontal) return;
        int w = int(p.width), bx = 4 + int(gid.x) * 8, by = 4 + int(gid.y) * 8;
        float sum = 0, squares = 0;
        for (int y = by; y < by + 8; y++) for (int x = bx; x < bx + 8; x++) {
            float d = proxy[y * w + x] - blurred[y * w + x];
            sum += d; squares += d * d;
        }
        out[gid.y * p.radius + gid.x] = max(0.0f, squares / 64 - (sum / 64) * (sum / 64));
    }

    kernel void fa_focus(device const float4 *rgba [[buffer(0)]], device const float *e0 [[buffer(1)]], device const float *e1 [[buffer(2)]],
                         device const float *e2 [[buffer(3)]], device float *out [[buffer(4)]], constant Focus &p [[buffer(5)]],
                         uint gid [[thread_position_in_grid]]) {
        if (gid >= p.count) return;
        float4 v = rgba[gid];
        if (v.a < 0.999f) { out[gid] = -INFINITY; return; }
        float f = log(1 + max(0.0f, e0[gid] - p.expected0) / p.scale0)
                + log(1 + max(0.0f, e1[gid] - p.expected1) / p.scale1)
                + log(1 + max(0.0f, e2[gid] - p.expected2) / p.scale2);
        if (max(v.r, max(v.g, v.b)) > 0.95f * p.clip) f *= 0.3f;
        out[gid] = f;
    }

    kernel void fa_composite(device const float4 *rgba [[buffer(0)]], device const float *focus [[buffer(1)]], device float *best [[buffer(2)]],
                             device float4 *composite [[buffer(3)]], constant Focus &p [[buffer(4)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= p.count) return;
        if (focus[gid] > best[gid]) { best[gid] = focus[gid]; composite[gid] = float4(rgba[gid].rgb * p.gain, 1); }
    }

    // A box mean over a clamped window along one line per thread, a running sum like HDRMerger.boxBlur.
    kernel void fa_box(device const float *input [[buffer(0)]], device float *output [[buffer(1)]], constant Plane &p [[buffer(2)]],
                       uint line [[thread_position_in_grid]]) {
        int count, step, base, r = int(p.radius);
        if (p.horizontal != 0) { if (line >= p.height) return; count = int(p.width); step = 1; base = int(line) * int(p.width); }
        else { if (line >= p.width) return; count = int(p.height); step = int(p.width); base = int(line); }
        float sum = 0;
        for (int j = 0; j <= min(count - 1, r); j++) sum += input[base + j * step];
        for (int i = 0; i < count; i++) {
            int low = max(0, i - r), high = min(count - 1, i + r);
            output[base + i * step] = sum / float(high - low + 1);
            if (i + r + 1 < count) sum += input[base + (i + r + 1) * step];
            if (i - r >= 0) sum -= input[base + (i - r) * step];
        }
    }

    kernel void fa_multiply(device const float *a [[buffer(0)]], device const float *b [[buffer(1)]], device float *out [[buffer(2)]],
                            constant uint &count [[buffer(3)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        out[gid] = a[gid] * b[gid];
    }

    kernel void fa_coefficients(device const float *meanI [[buffer(0)]], device const float *corrII [[buffer(1)]], device const float *meanP [[buffer(2)]],
                                device const float *corrIP [[buffer(3)]], device float *a [[buffer(4)]], device float *b [[buffer(5)]],
                                constant uint &count [[buffer(6)]], constant float &epsilon [[buffer(7)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float variance = corrII[gid] - meanI[gid] * meanI[gid], covariance = corrIP[gid] - meanI[gid] * meanP[gid];
        a[gid] = covariance / (variance + epsilon);
        b[gid] = meanP[gid] - a[gid] * meanI[gid];
    }

    kernel void fa_combine(device const float *meanA [[buffer(0)]], device const float *meanB [[buffer(1)]], device const float *guide [[buffer(2)]],
                           device float *out [[buffer(3)]], constant uint &count [[buffer(4)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        out[gid] = meanA[gid] * guide[gid] + meanB[gid];
    }

    kernel void fa_label(device const int *best [[buffer(0)]], device const float *confidence [[buffer(1)]], device float *out [[buffer(2)]],
                         constant uint &count [[buffer(3)]], constant int &index [[buffer(4)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        out[gid] = best[gid] == index ? confidence[gid] : 0.0f;
    }

    // parameters: blend, 1 / photos.
    kernel void fa_weight(device const float *local [[buffer(0)]], device const float *broad [[buffer(1)]], device const float *denominator [[buffer(2)]],
                          device const float *wideDenominator [[buffer(3)]], device const float *focus [[buffer(4)]], device float *out [[buffer(5)]],
                          constant uint &count [[buffer(6)]], constant float4 &parameters [[buffer(7)]], uint gid [[thread_position_in_grid]]) {
        if (gid >= count) return;
        float blend = parameters.x;
        float fallback = wideDenominator[gid] > 1e-4f ? broad[gid] / wideDenominator[gid] : parameters.y;
        float value = (max(0.0f, local[gid]) + blend * fallback) / (max(0.0f, denominator[gid]) + blend);
        out[gid] = isfinite(focus[gid]) ? value * value : 0.0f;
    }
    """
}
