import Foundation
import CoreImage
import Metal
import simd

/// The full-size blend on the GPU: each photo is developed by Core Image straight into a texture, then one compute pass
/// warps it onto the reference, weighs it and adds it to a running sum in GPU memory, so no photo is copied back to the
/// CPU; only the finished merge is. The arithmetic is `HDRMerger.accumulate`'s, in 32-bit float throughout.
final class HDRMergeGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let accumulatePipeline: MTLComputePipelineState
    private let normalizePipeline: MTLComputePipelineState

    init(device: MTLDevice) {
        let queue = device.makeCommandQueue()!
        // Fixed source: a kernel that doesn't compile is a bug.
        let library = try! device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) -> MTLComputePipelineState { try! device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
        self.device = device; self.queue = queue; accumulatePipeline = pipeline("hdr_accumulate"); normalizePipeline = pipeline("hdr_normalize")
    }

    /// Mirrors `Parameters` in the shader.
    private struct Parameters {
        var width: UInt32, height: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
        var m00: Float, m01: Float, m10: Float, m11: Float, tx: Float, ty: Float
        var gain: Float, exposure: Float, clip: Float, floor: Float, shoulder: Float
        var isReference: UInt32, hasResponse: UInt32, hasTrust: UInt32, hasKeep: UInt32, hasForced: UInt32, mapWidth: UInt32, mapHeight: UInt32
        var responseLow: Float, responseStep: Float, responseBins: UInt32
    }

    /// Mirrors `NormalizeParameters` in the shader.
    private struct NormalizeParameters {
        var width: UInt32, height: UInt32, hasForced: UInt32, mapWidth: UInt32, mapHeight: UInt32
    }

    /// A running sum of weighted radiance and weight, RGBW per pixel, and with layer painting a second one of the
    /// painted shares.
    final class Accumulator {
        let buffer: MTLBuffer
        let forced: MTLBuffer?
        let width: Int, height: Int
        fileprivate var texture: MTLTexture?
        init?(device: MTLDevice, width: Int, height: Int, painted: Bool) {
            // The 32-bit sum in a mapped temporary file (`MappedBuffer`), not the app's memory.
            let mapped = MappedBuffer.make(device, length: width * height * 16)
            guard let buffer = mapped ?? device.makeBuffer(length: width * height * 16, options: .storageModeShared) else { return nil }
            if mapped == nil { memset(buffer.contents(), 0, buffer.length) }
            if painted {
                guard let forced = device.makeBuffer(length: width * height * 16, options: .storageModePrivate) else { return nil }
                self.forced = forced
            } else { forced = nil }
            self.buffer = buffer; self.width = width; self.height = height
        }
    }

    func accumulator(width: Int, height: Int, painted: Bool = false) -> Accumulator? {
        guard let sum = Accumulator(device: device, width: width, height: height, painted: painted) else { return nil }
        if let forced = sum.forced, let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.fill(buffer: forced, range: 0..<forced.length, value: 0)
            blit.endEncoding(); GPUForeground.wait(); commands.commit(); commands.waitUntilCompleted()
        }
        return sum
    }

    /// Develops `image` into the accumulator's frame texture and adds it in. `inverse` maps output points into the
    /// image's pixels (top-left origin), as in `HDRMerger.warp`. `trust`, `keep` and `forced` are maps on one grid, used as
    /// in `HDRMerger.accumulate`.
    func add(_ image: CIImage, to sum: Accumulator, context: CIContext, contribution c: HDRMerger.Contribution, inverse: HDRSimilarity,
             trust: ([Float], Int, Int)?, keep: ([Float], Int, Int)? = nil, forced: ([Float], Int, Int)? = nil) throws {
        let sourceWidth = Int(image.extent.width.rounded(.down)), sourceHeight = Int(image.extent.height.rounded(.down))
        if sum.texture == nil || sum.texture!.width != sourceWidth || sum.texture!.height != sourceHeight {
            // Half floats: one photo at a time, summed in 32-bit.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: sourceWidth, height: sourceHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            sum.texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = sum.texture, let commands = queue.makeCommandBuffer() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos.")) }
        // Core Image's origin is the bottom left; flip so texture row 0 is the photo's top row, as on the CPU.
        let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(sourceHeight)))
        context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                       colorSpace: PanoramaDecoder.space)
        let l = inverse.linear
        var parameters = Parameters(width: UInt32(sum.width), height: UInt32(sum.height), sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
                                    m00: Float(l[0][0]), m01: Float(l[1][0]), m10: Float(l[0][1]), m11: Float(l[1][1]),
                                    tx: Float(inverse.translation.x), ty: Float(inverse.translation.y),
                                    gain: c.gain, exposure: c.exposure, clip: c.clip, floor: c.floor ?? -1, shoulder: c.shoulder ?? -1,
                                    isReference: c.isReference ? 1 : 0, hasResponse: c.response == nil ? 0 : 1, hasTrust: trust == nil ? 0 : 1,
                                    hasKeep: keep == nil ? 0 : 1, hasForced: forced != nil && sum.forced != nil ? 1 : 0,
                                    mapWidth: UInt32(trust?.1 ?? keep?.1 ?? forced?.1 ?? 1), mapHeight: UInt32(trust?.2 ?? keep?.2 ?? forced?.2 ?? 1),
                                    responseLow: HDRResponse.low, responseStep: HDRResponse.step, responseBins: UInt32(HDRResponse.bins))
        let response = (c.response?.values ?? [.zero]).map { SIMD4<Float>($0, 0) }
        let trustValues = trust?.0 ?? [1], keepValues = keep?.0 ?? [1], forcedValues = forced?.0 ?? [0]
        guard let encoder = commands.makeComputeCommandEncoder(),
              let responseBuffer = device.makeBuffer(bytes: response, length: response.count * 16),
              let trustBuffer = device.makeBuffer(bytes: trustValues, length: trustValues.count * 4),
              let forcedBuffer = device.makeBuffer(bytes: forcedValues, length: forcedValues.count * 4),
              let keepBuffer = device.makeBuffer(bytes: keepValues, length: keepValues.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos."))
        }
        encoder.setComputePipelineState(accumulatePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(sum.buffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 1)
        encoder.setBuffer(responseBuffer, offset: 0, index: 2)
        encoder.setBuffer(trustBuffer, offset: 0, index: 3)
        encoder.setBuffer(forcedBuffer, offset: 0, index: 4)
        encoder.setBuffer(sum.forced ?? sum.buffer, offset: 0, index: 5)
        encoder.setBuffer(keepBuffer, offset: 0, index: 6)
        dispatch(encoder, accumulatePipeline, width: sum.width, height: sum.height)
        encoder.endEncoding()
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    /// Divides the sums by their weights on the GPU and copies the result out. `automatic` is the blend's share of each
    /// pixel where the brush painted, as in `HDRMerger.normalized`.
    func normalized(_ sum: Accumulator, automatic: ([Float], Int, Int)? = nil) throws -> PanoramaRaster {
        sum.texture = nil
        let automaticValues = automatic?.0 ?? [1]
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder(),
              let automaticBuffer = device.makeBuffer(bytes: automaticValues, length: automaticValues.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t merge these photos."))
        }
        var parameters = NormalizeParameters(width: UInt32(sum.width), height: UInt32(sum.height),
                                             hasForced: automatic != nil && sum.forced != nil ? 1 : 0,
                                             mapWidth: UInt32(automatic?.1 ?? 1), mapHeight: UInt32(automatic?.2 ?? 1))
        encoder.setComputePipelineState(normalizePipeline)
        encoder.setBuffer(sum.buffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<NormalizeParameters>.stride, index: 1)
        encoder.setBuffer(sum.forced ?? sum.buffer, offset: 0, index: 2)
        encoder.setBuffer(automaticBuffer, offset: 0, index: 3)
        dispatch(encoder, normalizePipeline, width: sum.width, height: sum.height)
        encoder.endEncoding()
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        let count = sum.width * sum.height * 4
        let rgba = [Float](unsafeUninitializedCapacity: count) { out, initialized in
            memcpy(out.baseAddress!, sum.buffer.contents(), count * 4); initialized = count
        }
        return PanoramaRaster(width: sum.width, height: sum.height, rgba: rgba)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        uint width, height, sourceWidth, sourceHeight;
        float m00, m01, m10, m11, tx, ty;
        float gain, exposure, clip, floorLevel, shoulder;
        uint isReference, hasResponse, hasTrust, hasKeep, hasForced, mapWidth, mapHeight;
        float responseLow, responseStep; uint responseBins;
    };

    struct NormalizeParameters { uint width, height, hasForced, mapWidth, mapHeight; };

    /// A map on its own grid, bilinearly at output pixel `gid` of a width × height output.
    static float sampleMap(device const float *map, uint mapWidth, uint mapHeight, uint2 gid, uint width, uint height) {
        int tw = int(mapWidth), th = int(mapHeight);
        float mx = clamp((float(gid.x) + 0.5f) * float(tw) / float(width) - 0.5f, 0.0f, float(tw - 1));
        float my = clamp((float(gid.y) + 0.5f) * float(th) / float(height) - 0.5f, 0.0f, float(th - 1));
        int a0 = int(mx), b0 = int(my), a1 = min(tw - 1, a0 + 1), b1 = min(th - 1, b0 + 1);
        float gx = mx - float(a0), gy = my - float(b0);
        float upper = map[b0 * tw + a0] * (1 - gx) + map[b0 * tw + a1] * gx;
        float lower = map[b1 * tw + a0] * (1 - gx) + map[b1 * tw + a1] * gx;
        return upper * (1 - gy) + lower * gy;
    }

    static float smooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0f, 1.0f); return t * t * (3 - 2 * t); }

    static float3 texel(texture2d<float, access::read> source, uint x, uint y) {
        float3 v = source.read(uint2(x, y)).rgb;
        return select(v, float3(0), isnan(v) || isinf(v));
    }

    kernel void hdr_accumulate(texture2d<float, access::read> source [[texture(0)]],
                               device float4 *sum [[buffer(0)]],
                               constant Parameters &p [[buffer(1)]],
                               device const float4 *response [[buffer(2)]],
                               device const float *trust [[buffer(3)]],
                               device const float *forcedMap [[buffer(4)]],
                               device float4 *forcedSum [[buffer(5)]],
                               device const float *keepMap [[buffer(6)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        // The warp: bilinear, covered only where the whole footprint lies inside the photo.
        float qx = float(gid.x) + 0.5f, qy = float(gid.y) + 0.5f;
        float sx = p.m00 * qx + p.m01 * qy + p.tx - 0.5f, sy = p.m10 * qx + p.m11 * qy + p.ty - 0.5f;
        int sw = int(p.sourceWidth), sh = int(p.sourceHeight);
        if (sx < -0.5f || sy < -0.5f || sx > float(sw) - 0.5f || sy > float(sh) - 0.5f) return;
        int x0 = clamp(int(floor(sx)), 0, sw - 1), y0 = clamp(int(floor(sy)), 0, sh - 1);
        int x1 = min(sw - 1, x0 + 1), y1 = min(sh - 1, y0 + 1);
        float fx = clamp(sx - float(x0), 0.0f, 1.0f), fy = clamp(sy - float(y0), 0.0f, 1.0f);
        float3 top = texel(source, x0, y0) * (1 - fx) + texel(source, x1, y0) * fx;
        float3 bottom = texel(source, x0, y1) * (1 - fx) + texel(source, x1, y1) * fx;
        float3 rgb = top * (1 - fy) + bottom * fy;

        float peak = max(rgb.r, max(rgb.g, rgb.b));
        float w = p.exposure;
        if (p.floorLevel >= 0) w *= smooth(p.floorLevel, 4 * p.floorLevel, peak);
        if (p.shoulder >= 0) w *= 1 - smooth(p.shoulder * p.clip, 0.98f * p.clip, peak);
        if (p.isReference != 0) w = max(w, 1e-6f * p.exposure);
        if (p.hasTrust != 0) {
            float t = sampleMap(trust, p.mapWidth, p.mapHeight, gid, p.width, p.height);
            w = p.isReference != 0 ? max(w, p.exposure * t) : w * t;
        }
        if (p.hasKeep != 0) w *= max(sampleMap(keepMap, p.mapWidth, p.mapHeight, gid, p.width, p.height), 1e-4f);
        float f = p.hasForced != 0 ? sampleMap(forcedMap, p.mapWidth, p.mapHeight, gid, p.width, p.height) : 0;
        if (!(w > 0) && !(f > 0)) return;

        float3 radiance = rgb * p.gain;
        if (p.hasResponse != 0) {
            float luminance = dot(radiance, float3(0.2126f, 0.7152f, 0.0722f));
            float t = clamp((log2(max(luminance, 1e-9f)) - p.responseLow) / p.responseStep - 0.5f, 0.0f, float(p.responseBins - 1));
            int k = min(int(p.responseBins) - 2, int(t));
            float f = t - float(k);
            float3 v = response[k].xyz * (1 - f) + response[k + 1].xyz * f;
            radiance *= exp2(v);
        }
        uint i = gid.y * p.width + gid.x;
        if (w > 0) sum[i] += float4(radiance * w, w);
        if (f > 0) forcedSum[i] += float4(radiance * f, f);
    }

    kernel void hdr_normalize(device float4 *sum [[buffer(0)]], constant NormalizeParameters &p [[buffer(1)]],
                              device const float4 *forcedSum [[buffer(2)]], device const float *automatic [[buffer(3)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        uint i = gid.y * p.width + gid.x;
        float4 s = sum[i];
        float3 rgb = s.w > 0 ? s.rgb / s.w : float3(0);
        if (p.hasForced != 0) {
            float4 painted = forcedSum[i];
            if (painted.w > 0) {
                float a = s.w > 0 ? sampleMap(automatic, p.mapWidth, p.mapHeight, gid, p.width, p.height) : 0;
                rgb = (rgb * a + painted.rgb) / (a + painted.w);
            }
        }
        sum[i] = float4(rgb, 1);
    }
    """
}
