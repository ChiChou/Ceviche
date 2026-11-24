import Foundation
import CoreImage
import Metal
import simd

/// The analysis's per-pixel work on the GPU: warping each photo's planes onto the anchor's sky, and the search for hot
/// pixels at full size. Registration itself stays on the CPU: it works on a few hundred stars, one step after another.
/// The kernels mirror the CPU code in `NightSkyAnalyzer` in 32-bit float, compiled without fast math.
/// Each call drains its own autorelease pool: a command buffer is autoreleased and keeps its buffers alive, and the
/// analysis calls these hundreds of times from one thread, which would hold every photo's planes until it ends.
final class NightSkyAnalysisGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLComputePipelineState
    private let excessPipeline: MTLComputePipelineState
    private let spikesPipeline: MTLComputePipelineState
    private let residualPipeline: MTLComputePipelineState
    private let boxPipeline: MTLComputePipelineState
    private let highPipeline: MTLComputePipelineState
    /// One line search on the GPU at a time: each holds a few hundred megabytes of planes.
    private let lineLock = NSLock()

    init(device: MTLDevice) {
        let queue = device.makeCommandQueue()!
        let options = MTLCompileOptions()
        options.mathMode = .safe
        // Fixed source: a kernel that doesn't compile is a bug.
        let library = try! device.makeLibrary(source: Self.source, options: options)
        func pipeline(_ name: String) -> MTLComputePipelineState { try! device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
        self.device = device; self.queue = queue
        warpPipeline = pipeline("night_warp"); excessPipeline = pipeline("night_excess"); spikesPipeline = pipeline("night_spikes")
        residualPipeline = pipeline("night_residual"); boxPipeline = pipeline("night_box_line"); highPipeline = pipeline("night_high")
    }

    /// Out of GPU memory, or a command the GPU couldn't run.
    private static func failure() -> Error { PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }

    // MARK: Warps

    /// Warps planes of one size onto the anchor's sky, keeping the sky maps in GPU memory between photos.
    final class Warper {
        private let gpu: NightSkyAnalysisGPU
        let width: Int, height: Int
        private let analysis: (Int, Int)
        private let mask: MTLBuffer, valid: MTLBuffer
        private let threshold: Float

        /// `mask` is at this size and gates which pixels are warped (above `threshold`); `valid` is at analysis size.
        init(_ gpu: NightSkyAnalysisGPU, width: Int, height: Int, mask: [Float], threshold: Float, valid: [Float], analysis: (Int, Int)) throws {
            guard mask.count == width * height, valid.count == analysis.0 * analysis.1,
                  let maskBuffer = gpu.device.makeBuffer(bytes: mask, length: mask.count * 4, options: .storageModeShared),
                  let validBuffer = gpu.device.makeBuffer(bytes: valid, length: valid.count * 4, options: .storageModeShared) else { throw NightSkyAnalysisGPU.failure() }
            self.gpu = gpu; self.width = width; self.height = height; self.analysis = analysis
            self.mask = maskBuffer; self.valid = validBuffer; self.threshold = threshold
        }

        /// `plane` (`channels` interleaved, at this size) on the anchor's sky, NaN where the photo has no sky sample.
        func warp(_ plane: [Float], channels: Int, alignment: NightSkyAlignment) throws -> [Float] {
            try autoreleasepool {
                let count = width * height * channels
                guard plane.count == count, let source = gpu.device.makeBuffer(bytes: plane, length: count * 4, options: .storageModeShared),
                      let out = gpu.device.makeBuffer(length: count * 4, options: .storageModeShared),
                      let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw NightSkyAnalysisGPU.failure() }
                var p = [Float](repeating: 0, count: 40)
                p[0] = Float(width); p[1] = Float(height); p[2] = Float(analysis.0); p[3] = Float(analysis.1)
                p[4] = Float(Double(analysis.0) / Double(width)); p[5] = Float(channels); p[6] = threshold
                let inverse = alignment.inverse.normalized
                for k in 0..<9 { p[11 + k] = Float(inverse.m[k]) }
                if let morph = alignment.morph {
                    p[7] = 1; p[10] = Float(morph.scale)
                    for k in 0..<10 { p[20 + k] = Float(morph.x[k]); p[30 + k] = Float(morph.y[k]) }
                }
                encoder.setComputePipelineState(gpu.warpPipeline)
                encoder.setBuffer(out, offset: 0, index: 0)
                encoder.setBuffer(source, offset: 0, index: 1)
                encoder.setBuffer(mask, offset: 0, index: 2)
                encoder.setBuffer(valid, offset: 0, index: 3)
                encoder.setBytes(p, length: p.count * 4, index: 4)
                gpu.dispatch(encoder, gpu.warpPipeline, width: width, height: height)
                encoder.endEncoding()
                try gpu.finish(commands)
                return [Float](UnsafeBufferPointer(start: out.contents().bindMemory(to: Float.self, capacity: count), count: count))
            }
        }
    }

    // MARK: Hot pixels

    /// `NightSkyAnalyzer.spikes` of a photo developed straight into GPU memory; nil when there are too many to be defects.
    func spikes(_ image: CIImage, context: CIContext) throws -> [Int]? {
        try autoreleasepool {
            let w = Int(image.extent.width.rounded(.down)), h = Int(image.extent.height.rounded(.down))
            guard w > 8, h > 8 else { return [] }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Self.failure() }
            // The CPU's noise sample: every 41st column and 37th row, four pixels in from the edges.
            let columns = (w - 8 + 40) / 41, rows = (h - 8 + 36) / 37
            guard let samples = device.makeBuffer(length: columns * rows * 4, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer() else { throw Self.failure() }
            // Core Image's origin is the bottom left; flip so texture row 0 is the photo's top row, as on the CPU.
            let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h)))
            context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: PanoramaDecoder.space)
            guard let encoder = commands.makeComputeCommandEncoder() else { throw Self.failure() }
            encoder.setComputePipelineState(excessPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(samples, offset: 0, index: 0)
            dispatch(encoder, excessPipeline, width: columns, height: rows)
            encoder.endEncoding()
            try finish(commands)
            let sample = UnsafeBufferPointer(start: samples.contents().bindMemory(to: Float.self, capacity: columns * rows), count: columns * rows).map(Double.init)
            var sigma = NightSkyAnalyzer.spikeNoise(sample)

            // Far more than a sensor has defects: a frame this noisy is left alone, as on the CPU it would match nothing.
            let capacity = 1 << 22
            guard let found = device.makeBuffer(length: capacity * 4, options: .storageModeShared),
                  let counter = device.makeBuffer(length: 4, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Self.failure() }
            memset(counter.contents(), 0, 4)
            var limit = UInt32(capacity)
            encoder.setComputePipelineState(spikesPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(found, offset: 0, index: 0)
            encoder.setBuffer(counter, offset: 0, index: 1)
            encoder.setBytes(&sigma, length: 4, index: 2)
            encoder.setBytes(&limit, length: 4, index: 3)
            dispatch(encoder, spikesPipeline, width: w, height: h)
            encoder.endEncoding()
            try finish(commands)
            let n = Int(counter.contents().load(as: UInt32.self))
            guard n <= capacity else { return nil }
            return UnsafeBufferPointer(start: found.contents().bindMemory(to: Int32.self, capacity: n), count: n).map(Int.init).sorted()
        }
    }

    // MARK: Filters

    /// `HDRMerger.boxBlur`, or `minFilter` with `minimum`: rows, then columns, the window clamped at the edges.
    func filter(_ values: [Float], width w: Int, height h: Int, radius: Int, minimum: Bool = false) throws -> [Float] {
        try autoreleasepool {
            let count = w * h, bytes = count * 4
            guard values.count == count, count > 0, let input = device.makeBuffer(bytes: values, length: bytes, options: .storageModeShared),
                  let scratch = device.makeBuffer(length: bytes, options: .storageModeShared), let output = device.makeBuffer(length: bytes, options: .storageModeShared),
                  let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Self.failure() }
            encodeFilter(encoder, from: input, through: scratch, to: output, width: w, height: h, radius: radius, minimum: minimum)
            encoder.endEncoding()
            try finish(commands)
            return [Float](UnsafeBufferPointer(start: output.contents().bindMemory(to: Float.self, capacity: count), count: count))
        }
    }

    private func encodeFilter(_ encoder: MTLComputeCommandEncoder, from input: MTLBuffer, through scratch: MTLBuffer, to output: MTLBuffer,
                              width w: Int, height h: Int, radius: Int, minimum: Bool) {
        for (from, to, vertical) in [(input, scratch, UInt32(0)), (scratch, output, UInt32(1))] {
            var settings = SIMD4<UInt32>(UInt32(w), UInt32(h), UInt32(max(0, radius)), vertical | (minimum ? 2 : 0))
            encoder.setComputePipelineState(boxPipeline)
            encoder.setBuffer(from, offset: 0, index: 0)
            encoder.setBuffer(to, offset: 0, index: 1)
            encoder.setBytes(&settings, length: 16, index: 2)
            dispatch(encoder, boxPipeline, width: w, height: h)
        }
    }

    // MARK: Lines

    /// `NightSkyTransients.highPass`: the residual against the neighbors' median, less its local mean, and where it is
    /// measured on all sides.
    func lineHighPass(frame: [Float], neighbors: [[Float]], interior: [Float], width w: Int, height h: Int) throws -> (high: [Float], inside: [Float]) {
        let count = w * h, bytes = count * 4
        precondition(frame.count == count && interior.count == count && (1...8).contains(neighbors.count) && neighbors.allSatisfy { $0.count == count })
        return try lineLock.withLock { try autoreleasepool {
            func make() throws -> MTLBuffer {
                guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { throw Self.failure() }
                return buffer
            }
            guard let frameBuffer = device.makeBuffer(bytes: frame, length: bytes, options: .storageModeShared),
                  let interiorBuffer = device.makeBuffer(bytes: interior, length: bytes, options: .storageModeShared),
                  let neighborBuffer = device.makeBuffer(length: bytes * neighbors.count, options: .storageModeShared) else { throw Self.failure() }
            for (k, plane) in neighbors.enumerated() { plane.withUnsafeBytes { (neighborBuffer.contents() + k * bytes).copyMemory(from: $0.baseAddress!, byteCount: bytes) } }
            let residual = try make(), valid = try make(), scratch = try make(), background = try make(), support = try make(), inside = try make(), high = try make()
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Self.failure() }
            var size = SIMD4<UInt32>(UInt32(w), UInt32(h), UInt32(neighbors.count), 0)
            encoder.setComputePipelineState(residualPipeline)
            for (index, buffer) in [frameBuffer, neighborBuffer, interiorBuffer, residual, valid].enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.setBytes(&size, length: 16, index: 5)
            dispatch(encoder, residualPipeline, width: w, height: h)
            for (input, output, radius) in [(residual, background, 12), (valid, support, 12), (valid, inside, 6)] {
                encodeFilter(encoder, from: input, through: scratch, to: output, width: w, height: h, radius: radius, minimum: false)
            }
            encoder.setComputePipelineState(highPipeline)
            for (index, buffer) in [residual, valid, background, support, high].enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.setBytes(&size, length: 16, index: 5)
            dispatch(encoder, highPipeline, width: w, height: h)
            encoder.endEncoding()
            try finish(commands)
            func array(_ buffer: MTLBuffer) -> [Float] { [Float](UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count)) }
            return (array(high), array(inside))
        } }
    }

    // MARK: Dispatch

    fileprivate func finish(_ commands: MTLCommandBuffer) throws {
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    fileprivate func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    \(NightSkyGPU.mappingSource)

    // p: 0 width, 1 height, 2 analysis width, 3 analysis height, 4 analysis pixels per pixel, 5 channels, 6 mask threshold,
    // 7 morph, 10 morph scale, 11-19 inverse homography, 20-39 morph x and y.

    /// `NightSkyAlignment.sourcePoint`: the anchor's sky point to the photo's pixels, by fixed-point iteration.
    static float2 warpSource(float2 a, device const float *p) {
        float2 q = project(a, p + 11);
        if (p[7] == 0) return q;
        for (int k = 0; k < 5; k++) {
            float2 next = project(a - displacement(q, p + 20, p + 30, p[10]), p + 11);
            if (distance(q, next) < 0.0001f) return next;
            q = next;
        }
        return q;
    }

    /// `NightSkyAnalyzer.warpPlane` and `warpPreview`: each pixel the mask lets through takes the photo's bilinear sample
    /// where its sky lands, if that is valid sky; NaN otherwise.
    kernel void night_warp(device float *out [[buffer(0)]], device const float *plane [[buffer(1)]], device const float *mask [[buffer(2)]],
                           device const float *valid [[buffer(3)]], device const float *p [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
        int w = int(p[0]), h = int(p[1]), aw = int(p[2]), ah = int(p[3]), channels = int(p[5]);
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        uint i = gid.y * uint(w) + gid.x;
        for (int c = 0; c < channels; c++) out[i * channels + c] = NAN;
        if (!(mask[i] > p[6])) return;
        float k = p[4];
        float2 a = warpSource((float2(gid) + 0.5f) * k - 0.5f, p);
        int vx = int(round(a.x)), vy = int(round(a.y));
        if (vx < 0 || vy < 0 || vx >= aw || vy >= ah || !(valid[vy * aw + vx] > 0.8f)) return;
        float2 f = (a + 0.5f) / k - 0.5f;
        if (f.x < 0 || f.y < 0 || f.x > float(w - 1) || f.y > float(h - 1)) return;
        int x0 = min(w - 2, int(f.x)), y0 = min(h - 2, int(f.y));
        float fx = f.x - float(x0), fy = f.y - float(y0);
        float values[3];
        for (int c = 0; c < min(3, channels); c++) {
            float s = plane[(y0 * w + x0) * channels + c], t = plane[(y0 * w + x0 + 1) * channels + c];
            float d = plane[((y0 + 1) * w + x0) * channels + c], e = plane[((y0 + 1) * w + x0 + 1) * channels + c];
            float v = (s * (1 - fx) + t * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy;
            if (!isfinite(v)) return;
            values[c] = v;
        }
        for (int c = 0; c < min(3, channels); c++) out[i * channels + c] = values[c];
    }

    static float spikeLuminance(texture2d<float, access::read> t, int x, int y) {
        float3 v = t.read(uint2(x, y)).rgb;
        v = select(v, float3(0), isnan(v) || isinf(v));
        return 0.2126f * v.r + 0.7152f * v.g + 0.0722f * v.b;
    }

    /// A pixel's luminance above the median of the ring two pixels out.
    static float spikeExcess(texture2d<float, access::read> t, int x, int y) {
        const int2 ring[16] = { int2(-2, -2), int2(-1, -2), int2(0, -2), int2(1, -2), int2(2, -2), int2(-2, 2), int2(-1, 2), int2(0, 2),
                                int2(1, 2), int2(2, 2), int2(-2, -1), int2(-2, 0), int2(-2, 1), int2(2, -1), int2(2, 0), int2(2, 1) };
        float values[16];
        for (int k = 0; k < 16; k++) {
            float v = spikeLuminance(t, x + ring[k].x, y + ring[k].y);
            int j = k;
            while (j > 0 && values[j - 1] > v) { values[j] = values[j - 1]; j--; }
            values[j] = v;
        }
        return spikeLuminance(t, x, y) - (values[7] + values[8]) / 2;
    }

    kernel void night_excess(texture2d<float, access::read> t [[texture(0)]], device float *out [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int w = int(t.get_width()), h = int(t.get_height());
        int columns = (w - 8 + 40) / 41, rows = (h - 8 + 36) / 37;
        if (int(gid.x) >= columns || int(gid.y) >= rows) return;
        out[gid.y * uint(columns) + gid.x] = spikeExcess(t, 4 + int(gid.x) * 41, 4 + int(gid.y) * 37);
    }

    kernel void night_spikes(texture2d<float, access::read> t [[texture(0)]], device int *found [[buffer(0)]], device atomic_uint *count [[buffer(1)]],
                             constant float &sigma [[buffer(2)]], constant uint &limit [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
        int w = int(t.get_width()), h = int(t.get_height()), x = int(gid.x), y = int(gid.y);
        if (x < 2 || y < 2 || x >= w - 2 || y >= h - 2) return;
        float v = spikeLuminance(t, x, y);
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            if ((dx != 0 || dy != 0) && !(v > spikeLuminance(t, x + dx, y + dy))) return;
        }
        if (!(spikeExcess(t, x, y) > 8 * sigma)) return;
        uint k = atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
        if (k < limit) found[k] = y * w + x;
    }

    /// The frame less the median of its neighbors (planes one after another), where the frame and every neighbor have a
    /// sample inside the search area; `valid` is 1 there.
    kernel void night_residual(device const float *frame [[buffer(0)]], device const float *neighbors [[buffer(1)]], device const float *interior [[buffer(2)]],
                               device float *residual [[buffer(3)]], device float *valid [[buffer(4)]], constant uint4 &size [[buffer(5)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint w = size.x, h = size.y, n = size.z;
        if (gid.x >= w || gid.y >= h) return;
        uint i = gid.y * w + gid.x;
        residual[i] = 0; valid[i] = 0;
        float v = frame[i];
        if (!isfinite(v) || !(interior[i] > 0.5f)) return;
        float values[8];
        for (uint k = 0; k < n; k++) {
            float u = neighbors[k * w * h + i];
            if (!isfinite(u)) return;
            uint j = k;
            while (j > 0 && values[j - 1] > u) { values[j] = values[j - 1]; j--; }
            values[j] = u;
        }
        float m = n % 2 == 0 ? (values[n / 2 - 1] + values[n / 2]) / 2 : values[n / 2];
        residual[i] = v - m; valid[i] = 1;
    }

    /// One direction of `HDRMerger.boxBlur` (the mean over the window, clamped at the edges) or, with bit 2 of
    /// `settings.w`, of `minFilter`; bit 1 is the vertical direction.
    kernel void night_box_line(device const float *input [[buffer(0)]], device float *output [[buffer(1)]], constant uint4 &settings [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int w = int(settings.x), h = int(settings.y), r = int(settings.z);
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        bool vertical = (settings.w & 1) != 0, minimum = (settings.w & 2) != 0;
        int at = vertical ? int(gid.y) : int(gid.x), end = vertical ? h : w;
        int low = max(0, at - r), high = min(end - 1, at + r);
        float sum = 0, least = INFINITY;
        for (int k = low; k <= high; k++) {
            float v = vertical ? input[k * w + int(gid.x)] : input[int(gid.y) * w + k];
            sum += v; least = min(least, v);
        }
        output[int(gid.y) * w + int(gid.x)] = minimum ? least : sum / float(high - low + 1);
    }

    kernel void night_high(device const float *residual [[buffer(0)]], device const float *valid [[buffer(1)]], device const float *background [[buffer(2)]],
                           device const float *support [[buffer(3)]], device float *high [[buffer(4)]], constant uint4 &size [[buffer(5)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.x || gid.y >= size.y) return;
        uint i = gid.y * size.x + gid.x;
        high[i] = valid[i] > 0 ? residual[i] - (support[i] > 0 ? background[i] / support[i] : 0.0f) : 0.0f;
    }
    """
}
