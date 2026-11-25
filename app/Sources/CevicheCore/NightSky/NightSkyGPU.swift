import Foundation
import CoreImage
import Accelerate
import Metal
import simd

/// The GPU side of `NightSkyAnalyzer.render`: compute kernels compiled at run time, mirroring the CPU arithmetic in
/// 32-bit float. Photos are developed by Core Image straight into a half-float texture.
final class NightSkyGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let accumulatePipeline: MTLComputePipelineState
    private let composePipeline: MTLComputePipelineState
    private let restorePipeline: MTLComputePipelineState
    private let boxPipeline: MTLComputePipelineState
    private let regionsPipeline: MTLComputePipelineState

    init(device: MTLDevice) {
        let queue = device.makeCommandQueue()!
        // Fixed source: a kernel that doesn't compile is a bug.
        let library = try! device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) -> MTLComputePipelineState { try! device.makeComputePipelineState(function: library.makeFunction(name: name)!) }
        self.device = device; self.queue = queue
        accumulatePipeline = pipeline("night_accumulate"); composePipeline = pipeline("night_compose"); restorePipeline = pipeline("night_restore")
        boxPipeline = pipeline("night_box"); regionsPipeline = pipeline("night_regions")
    }

    final class Sums {
        let width: Int, height: Int
        /// RGB × weight and weight per pixel; after composing, `ground` holds the result.
        let ground: MTLBuffer
        var sky: MTLBuffer?
        let peak: MTLBuffer?
        var clean: MTLBuffer?
        var score: MTLBuffer?
        /// The photo trails are drawn over, RGBA.
        var photo: MTLBuffer?
        var texture: MTLTexture?
        fileprivate var background: MTLTexture?
        fileprivate var scratch: MTLTexture?
        init(width: Int, height: Int, ground: MTLBuffer, sky: MTLBuffer?, peak: MTLBuffer?) {
            self.width = width; self.height = height; self.ground = ground; self.sky = sky; self.peak = peak
        }
    }

    func sums(width: Int, height: Int, sky: Bool, peak: Bool) -> Sums? {
        func buffer(_ fill: Float) -> MTLBuffer? {
            guard let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared) else { return nil }
            let pointer = buffer.contents().bindMemory(to: Float.self, capacity: width * height * 4)
            if fill == 0 { memset(buffer.contents(), 0, buffer.length) } else { for i in 0..<(width * height * 4) { pointer[i] = fill } }
            return buffer
        }
        guard let ground = buffer(0) else { return nil }
        let skyBuffer = sky ? buffer(0) : nil, peakBuffer = peak ? buffer(-.infinity) : nil
        if (sky && skyBuffer == nil) || (peak && peakBuffer == nil) { return nil }
        return Sums(width: width, height: height, ground: ground, sky: skyBuffer, peak: peakBuffer)
    }

    /// A zeroed shared buffer of `channels` floats per pixel.
    func buffer(width: Int, height: Int, channels: Int) -> MTLBuffer? {
        guard let buffer = device.makeBuffer(length: width * height * channels * 4, options: .storageModeShared) else { return nil }
        memset(buffer.contents(), 0, buffer.length)
        return buffer
    }

    struct Maps { let probability: MTLBuffer, valid: MTLBuffer }

    func maps(probability: [Float], valid: [Float]) throws -> Maps {
        guard let p = device.makeBuffer(bytes: probability, length: probability.count * 4), let v = device.makeBuffer(bytes: valid, length: valid.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        return Maps(probability: p, valid: v)
    }

    /// Mirrors the `p` array the kernels read.
    private static func parameters(width: Int, height: Int, analysis: (Int, Int), gain: Float, weight: Float, flags: UInt32,
                                   skyLines: Int, peakLines: Int, base: NightSkyAlignment?, frame: NightSkyAlignment?, region: (Int, Int) = (0, 0)) -> [Float] {
        var p = [Float](repeating: 0, count: 80)
        p[0] = Float(width); p[1] = Float(height); p[2] = Float(analysis.0); p[3] = Float(analysis.1)
        p[4] = Float(Double(width) / Double(analysis.0)); p[5] = gain; p[6] = weight
        var flags = flags
        if base != nil { flags |= 16 }
        if base?.morph != nil { flags |= 32 }
        if frame != nil { flags |= 64 }
        if frame?.morph != nil { flags |= 128 }
        p[7] = Float(flags); p[8] = Float(skyLines); p[9] = Float(peakLines); p[10] = Float(analysis.0)
        if let base {
            for k in 0..<9 { p[11 + k] = Float(base.transform.normalized.m[k]) }
            if let morph = base.morph { for k in 0..<10 { p[20 + k] = Float(morph.x[k]); p[30 + k] = Float(morph.y[k]) } }
        }
        if let frame {
            for k in 0..<9 { p[40 + k] = Float(frame.inverse.normalized.m[k]) }
            if let morph = frame.morph { for k in 0..<10 { p[49 + k] = Float(morph.x[k]); p[59 + k] = Float(morph.y[k]) } }
        }
        p[70] = Float(region.0); p[71] = Float(region.1)
        return p
    }

    private static func lineValues(_ lines: [NightSkyLine]) -> [Float] {
        let values: [Float] = lines.flatMap { line -> [Float] in [Float(line.start.x), Float(line.start.y), Float(line.end.x), Float(line.end.y), Float(line.radius), 0, 0, 0] }
        return values.isEmpty ? [0, 0, 0, 0, 0, 0, 0, 0] : values
    }

    /// Develops `image` into the texture and adds it to the sums.
    /// With `squares`, also adds Σ weight × luminance² of the sky samples; with `clip`, adds only the sky samples the first
    /// pass's statistics keep.
    /// Adds `image` to the sums; nil adds the photo already developed into the sums' texture again.
    func accumulate(_ image: CIImage?, into sums: Sums, maps: Maps, context: CIContext, contribution c: NightSkyAnalyzer.Contribution,
                    base: NightSkyAlignment?, analysis: (Int, Int), squares: MTLBuffer? = nil,
                    clip: (first: MTLBuffer, squares: MTLBuffer, clipping: NightSkyAnalyzer.Clipping)? = nil) throws {
        guard let texture = try image.map({ try develop($0, into: sums, context: context) }) ?? sums.texture,
              let commands = queue.makeCommandBuffer() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
        if let image { render(image, to: texture, commands: commands, context: context) }
        if c.detail {
            if sums.background == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: sums.width, height: sums.height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
                sums.background = device.makeTexture(descriptor: descriptor)
            }
            if sums.scratch == nil {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: sums.width, height: sums.height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
                sums.scratch = device.makeTexture(descriptor: descriptor)
            }
            guard let background = sums.background, let scratch = sums.scratch else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(sums.width) × \(sums.height) photos.")) }
            // A separable box blur: rows into the scratch texture, then its columns into the background.
            for (input, output, vertical) in [(texture, scratch, UInt32(0)), (scratch, background, UInt32(1))] {
                guard let encoder = commands.makeComputeCommandEncoder() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
                var settings = SIMD2<UInt32>(UInt32(NightSkyAnalyzer.backgroundRadius), vertical)
                encoder.setComputePipelineState(boxPipeline)
                encoder.setTexture(input, index: 0)
                encoder.setTexture(output, index: 1)
                encoder.setBytes(&settings, length: 8, index: 0)
                dispatch(encoder, boxPipeline, width: sums.width, height: sums.height)
                encoder.endEncoding()
            }
        }
        var flags: UInt32 = 0
        if c.sky { flags |= 1 }
        if c.ground { flags |= 2 }
        if c.peak { flags |= 4 }
        if c.peak, c.peakColor { flags |= 8 }
        if squares != nil { flags |= 512 }
        if c.detail { flags |= 4096 }
        if c.isSkyPhoto { flags |= 8192 }
        if clip != nil { flags |= 1024 }
        if clip?.clipping.agreeWithBase == true { flags |= 16384 }
        var parameters = Self.parameters(width: sums.width, height: sums.height, analysis: analysis, gain: c.gain, weight: c.weight, flags: flags,
                                         skyLines: c.skyLines.count, peakLines: c.peakLines.count, base: base, frame: c.alignment)
        if let clip { parameters[73] = clip.clipping.k; parameters[74] = clip.clipping.minimumWeight; parameters[75] = clip.clipping.floor; parameters[77] = clip.clipping.level }
        let lines = Self.lineValues(c.skyLines + c.peakLines)
        guard let encoder = commands.makeComputeCommandEncoder(),
              let parameterBuffer = device.makeBuffer(bytes: parameters, length: parameters.count * 4),
              let lineBuffer = device.makeBuffer(bytes: lines, length: lines.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        encoder.setComputePipelineState(accumulatePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(sums.background ?? texture, index: 1)
        encoder.setBuffer(sums.ground, offset: 0, index: 0)
        encoder.setBuffer(sums.sky ?? sums.ground, offset: 0, index: 1)
        encoder.setBuffer(sums.peak ?? sums.ground, offset: 0, index: 2)
        encoder.setBuffer(maps.probability, offset: 0, index: 3)
        encoder.setBuffer(maps.valid, offset: 0, index: 4)
        encoder.setBuffer(parameterBuffer, offset: 0, index: 5)
        encoder.setBuffer(lineBuffer, offset: 0, index: 6)
        encoder.setBuffer(squares ?? clip?.squares ?? sums.ground, offset: 0, index: 7)
        encoder.setBuffer(sums.photo ?? sums.ground, offset: 0, index: 9)
        encoder.setBuffer(clip?.first ?? sums.ground, offset: 0, index: 8)
        dispatch(encoder, accumulatePipeline, width: sums.width, height: sums.height)
        encoder.endEncoding()
        if c.peak, let gap = c.gap, !gap.steps.isEmpty {
            // One pass per step of the pause, each the photo's peak shifted along the motion toward the next photo.
            var flags: UInt32 = 4 | 2048
            if c.peakColor { flags |= 8 }
            if c.detail { flags |= 4096 }
            for t in gap.steps {
                var p = Self.parameters(width: sums.width, height: sums.height, analysis: analysis, gain: c.gain, weight: c.weight, flags: flags,
                                        skyLines: 0, peakLines: c.peakLines.count, base: gap.own, frame: gap.next)
                p[76] = t
                let lines = Self.lineValues(c.peakLines)
                guard let encoder = commands.makeComputeCommandEncoder(), let parameterBuffer = device.makeBuffer(bytes: p, length: p.count * 4),
                      let lineBuffer = device.makeBuffer(bytes: lines, length: lines.count * 4) else {
                    throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
                }
                encoder.setComputePipelineState(accumulatePipeline)
                encoder.setTexture(texture, index: 0)
                encoder.setTexture(sums.background ?? texture, index: 1)
                encoder.setBuffer(sums.ground, offset: 0, index: 0)
                encoder.setBuffer(sums.sky ?? sums.ground, offset: 0, index: 1)
                encoder.setBuffer(sums.peak ?? sums.ground, offset: 0, index: 2)
                encoder.setBuffer(maps.probability, offset: 0, index: 3)
                encoder.setBuffer(maps.valid, offset: 0, index: 4)
                encoder.setBuffer(parameterBuffer, offset: 0, index: 5)
                encoder.setBuffer(lineBuffer, offset: 0, index: 6)
                encoder.setBuffer(sums.ground, offset: 0, index: 7)
                encoder.setBuffer(sums.ground, offset: 0, index: 8)
                encoder.setBuffer(sums.ground, offset: 0, index: 9)
                dispatch(encoder, accumulatePipeline, width: sums.width, height: sums.height)
                encoder.endEncoding()
            }
        }
        try finish(commands)
    }

    func compose(_ sums: Sums, maps: Maps, analysis: (Int, Int), minimumSkyWeight: Float, keepClean: Bool) throws {
        sums.texture = nil
        if keepClean {
            sums.clean = sums.sky ?? device.makeBuffer(length: sums.width * sums.height * 16, options: .storageModeShared)
            sums.score = device.makeBuffer(length: sums.width * sums.height * 4, options: .storageModeShared)
            guard let score = sums.score, sums.clean != nil else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(sums.width) × \(sums.height) photos.")) }
            let pointer = score.contents().bindMemory(to: Float.self, capacity: sums.width * sums.height)
            for i in 0..<(sums.width * sums.height) { pointer[i] = -.infinity }
        }
        var flags: UInt32 = 0
        if sums.sky != nil { flags |= 1 }
        if sums.peak != nil { flags |= 4 }
        if keepClean { flags |= 256 }
        if sums.photo != nil { flags |= 4096 }
        var parameters = Self.parameters(width: sums.width, height: sums.height, analysis: analysis, gain: 1, weight: 1, flags: flags,
                                         skyLines: 0, peakLines: 0, base: nil, frame: nil)
        parameters[72] = minimumSkyWeight
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder(),
              let parameterBuffer = device.makeBuffer(bytes: parameters, length: parameters.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        encoder.setComputePipelineState(composePipeline)
        encoder.setBuffer(sums.ground, offset: 0, index: 0)
        encoder.setBuffer(sums.sky ?? sums.ground, offset: 0, index: 1)
        encoder.setBuffer(sums.peak ?? sums.ground, offset: 0, index: 2)
        encoder.setBuffer(maps.probability, offset: 0, index: 3)
        encoder.setBuffer(parameterBuffer, offset: 0, index: 5)
        encoder.setBuffer(sums.clean ?? sums.ground, offset: 0, index: 6)
        encoder.setBuffer(sums.photo ?? sums.ground, offset: 0, index: 7)
        dispatch(encoder, composePipeline, width: sums.width, height: sums.height)
        encoder.endEncoding()
        try finish(commands)
    }

    func restore(_ image: CIImage, lines: [NightSkyLine], regions: [(Int, Int, Int, Int)], into sums: Sums, maps: Maps, context: CIContext,
                 gain: Float, alignment: NightSkyAlignment?, base: NightSkyAlignment?, analysis: (Int, Int), backgrounds: [NightSkyLineBackground?]) throws {
        guard let clean = sums.clean, let score = sums.score else { return }
        let texture = try develop(image, into: sums, context: context)
        guard let commands = queue.makeCommandBuffer() else { throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
        render(image, to: texture, commands: commands, context: context)
        for (index, line) in lines.enumerated() {
            let region = regions[index]
            guard region.2 >= region.0, region.3 >= region.1, let background = backgrounds[index] else { continue }
            let parameters = Self.parameters(width: sums.width, height: sums.height, analysis: analysis, gain: gain, weight: 1, flags: 0,
                                             skyLines: 1, peakLines: 0, base: base, frame: alignment, region: (region.0, region.1))
            let values = Self.lineValues([line])
            let correction = background.packed
            guard let encoder = commands.makeComputeCommandEncoder(),
                  let parameterBuffer = device.makeBuffer(bytes: parameters, length: parameters.count * 4),
                  let lineBuffer = device.makeBuffer(bytes: values, length: values.count * 4),
                  let backgroundBuffer = device.makeBuffer(bytes: correction, length: correction.count * 4) else {
                throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
            }
            encoder.setComputePipelineState(restorePipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBuffer(sums.ground, offset: 0, index: 0)
            encoder.setBuffer(clean, offset: 0, index: 1)
            encoder.setBuffer(score, offset: 0, index: 2)
            encoder.setBuffer(maps.valid, offset: 0, index: 4)
            encoder.setBuffer(parameterBuffer, offset: 0, index: 5)
            encoder.setBuffer(lineBuffer, offset: 0, index: 6)
            encoder.setBuffer(backgroundBuffer, offset: 0, index: 7)
            dispatch(encoder, restorePipeline, width: region.2 - region.0 + 1, height: region.3 - region.1 + 1)
            encoder.endEncoding()
        }
        try finish(commands)
    }

    /// Takes the painted areas from the stored photo over the composed result.
    func applyRegions(_ sums: Sums, map: [Float], analysis: (Int, Int)) throws {
        guard let photo = sums.photo else { return }
        let parameters = Self.parameters(width: sums.width, height: sums.height, analysis: analysis, gain: 1, weight: 1, flags: 0, skyLines: 0, peakLines: 0, base: nil, frame: nil)
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder(),
              let parameterBuffer = device.makeBuffer(bytes: parameters, length: parameters.count * 4),
              let mapBuffer = device.makeBuffer(bytes: map, length: map.count * 4) else {
            throw PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos."))
        }
        encoder.setComputePipelineState(regionsPipeline)
        encoder.setBuffer(sums.ground, offset: 0, index: 0)
        encoder.setBuffer(photo, offset: 0, index: 1)
        encoder.setBuffer(mapBuffer, offset: 0, index: 3)
        encoder.setBuffer(parameterBuffer, offset: 0, index: 5)
        dispatch(encoder, regionsPipeline, width: sums.width, height: sums.height)
        encoder.endEncoding()
        try finish(commands)
    }

    func output(_ sums: Sums) throws -> PanoramaRaster {
        let count = sums.width * sums.height * 4
        let rgba = [Float](unsafeUninitializedCapacity: count) { out, initialized in
            memcpy(out.baseAddress!, sums.ground.contents(), count * 4); initialized = count
        }
        return PanoramaRaster(width: sums.width, height: sums.height, rgba: rgba)
    }

    func develop(_ image: CIImage, into sums: Sums, context: CIContext) throws -> MTLTexture {
        let w = Int(image.extent.width.rounded(.down)), h = Int(image.extent.height.rounded(.down))
        guard w == sums.width, h == sums.height else { throw PanoramaError.message(L10n.tr("A photo developed at a different size from the others.")) }
        if sums.texture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            sums.texture = device.makeTexture(descriptor: descriptor)
        }
        guard let texture = sums.texture else { throw PanoramaError.message(L10n.tr("Not enough memory to stack \(w) × \(h) photos.")) }
        return texture
    }

    private func render(_ image: CIImage, to texture: MTLTexture, commands: MTLCommandBuffer, context: CIContext) {
        // Core Image's origin is the bottom left; flip so texture row 0 is the photo's top row, as on the CPU.
        let flipped = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(texture.height)))
        context.render(flipped, to: texture, commandBuffer: commands, bounds: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                       colorSpace: PanoramaDecoder.space)
    }

    private func finish(_ commands: MTLCommandBuffer) throws {
        GPUForeground.wait(); commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// A homography and the morph's polynomial, shared with the analysis kernels.
    static let mappingSource = """
    static float2 project(float2 q, device const float *h) {
        float z = h[6] * q.x + h[7] * q.y + h[8];
        return float2(h[0] * q.x + h[1] * q.y + h[2], h[3] * q.x + h[4] * q.y + h[5]) / z;
    }
    static float polynomial(float u, float v, device const float *a) {
        return a[0] + u * (a[1] + u * (a[3] + u * a[6]) + v * (a[4] + u * a[7] + v * a[8])) + v * (a[2] + v * (a[5] + v * a[9]));
    }
    static float2 displacement(float2 q, device const float *x, device const float *y, float scale) {
        float u = q.x / scale - 0.5f, v = q.y / scale - 0.35f;
        return float2(polynomial(u, v, x), polynomial(u, v, y));
    }
    """

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // p: 0 width, 1 height, 2 analysis width, 3 analysis height, 4 full pixels per analysis pixel, 5 gain, 6 weight,
    // 7 flags (1 sky, 2 ground, 4 peak, 8 peak keeps color, 16 base map, 32 base morph, 64 frame map, 128 frame morph,
    // 256 keep clean, 512 add sky luminance squares, 1024 clip the sky against the first pass), 8 sky lines, 9 peak lines,
    // 10 morph scale, 11-19 base homography, 20-39 base morph x and y, 40-48 frame inverse homography, 49-68 frame morph x
    // and y, 70-71 region origin, 72 minimum sky weight, 73 clipping deviations, 74 clipping minimum weight, 75 clipping
    // deviation floor, 76 gap step. Flags 4096 (the peak takes detail above the local background in texture 1; compose
    // adds it to the photo in buffer 7) and 8192 (this photo is that one). Flag 2048 draws a pause: the photo's peak shifted back by the step's share of the
    // motion toward the next photo (the base map is this photo's, the frame map the next one's).

    \(mappingSource)
    /// Output pixel to the anchor's sky, in analysis pixels.
    static float2 anchorPoint(uint2 gid, device const float *p) {
        float2 a = (float2(gid) + 0.5f) / p[4] - 0.5f;
        uint flags = uint(p[7]);
        if (flags & 16) {
            float2 b = project(a, p + 11);
            if (flags & 32) b += displacement(a, p + 20, p + 30, p[10]);
            a = b;
        }
        return a;
    }
    /// The anchor's sky point to the photo's pixels, inverting the photo's map by fixed-point iteration.
    static float2 sourcePoint(float2 a, device const float *p) {
        uint flags = uint(p[7]);
        if (!(flags & 64)) return a;
        float2 q = project(a, p + 40);
        if (flags & 128) {
            for (int k = 0; k < 5; k++) {
                float2 next = project(a - displacement(q, p + 49, p + 59, p[10]), p + 40);
                float delta = distance(next, q);
                q = next;
                if (delta < 0.0001f) break;
            }
        }
        return q;
    }
    static float sampleMap(device const float *map, float2 a, device const float *p, bool nearest) {
        int w = int(p[2]), h = int(p[3]);
        if (nearest) {
            int x = int(round(a.x)), y = int(round(a.y));
            if (x < 0 || y < 0 || x >= w || y >= h) return 0;
            return map[y * w + x];
        }
        a = clamp(a, float2(0), float2(w - 1, h - 1));
        int x0 = min(w - 2, int(a.x)), y0 = min(h - 2, int(a.y));
        float fx = a.x - float(x0), fy = a.y - float(y0);
        return (map[y0 * w + x0] * (1 - fx) + map[y0 * w + x0 + 1] * fx) * (1 - fy) + (map[(y0 + 1) * w + x0] * (1 - fx) + map[(y0 + 1) * w + x0 + 1] * fx) * fy;
    }
    static float lineDistance(float2 q, device const float *l) {
        float2 a = float2(l[0], l[1]), d = float2(l[2], l[3]) - a;
        float l2 = dot(d, d);
        float t = l2 > 0 ? clamp(dot(q - a, d) / l2, 0.0f, 1.0f) : 0.0f;
        return distance(q, a + t * d);
    }
    static bool onLine(float2 q, device const float *lines, int first, int count) {
        for (int k = first; k < first + count; k++) if (lineDistance(q, lines + 8 * k) <= lines[8 * k + 4]) return true;
        return false;
    }
    static float3 texel(texture2d<float, access::read> source, int x, int y) {
        float3 v = source.read(uint2(x, y)).rgb;
        return select(v, float3(0), isnan(v) || isinf(v));
    }
    /// Bilinear at a full-size point, pixel centers at integers; false outside.
    static bool bilinear(texture2d<float, access::read> source, float2 f, thread float3 &out) {
        int w = int(source.get_width()), h = int(source.get_height());
        if (f.x < 0 || f.y < 0 || f.x > float(w - 1) || f.y > float(h - 1)) return false;
        int x0 = min(w - 2, int(f.x)), y0 = min(h - 2, int(f.y));
        float fx = f.x - float(x0), fy = f.y - float(y0);
        out = (texel(source, x0, y0) * (1 - fx) + texel(source, x0 + 1, y0) * fx) * (1 - fy)
            + (texel(source, x0, y0 + 1) * (1 - fx) + texel(source, x0 + 1, y0 + 1) * fx) * fy;
        return true;
    }
    static float luminance(float3 v) { return dot(v, float3(0.2126f, 0.7152f, 0.0722f)); }
    static float smooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0f, 1.0f); return t * t * (3 - 2 * t); }

    kernel void night_accumulate(texture2d<float, access::read> source [[texture(0)]], texture2d<float, access::read> background [[texture(1)]],
                                 device float4 *ground [[buffer(0)]], device float4 *sky [[buffer(1)]], device float4 *peak [[buffer(2)]],
                                 device const float *probability [[buffer(3)]], device const float *valid [[buffer(4)]],
                                 device const float *p [[buffer(5)]], device const float *lines [[buffer(6)]],
                                 device float *squares [[buffer(7)]], device const float4 *first [[buffer(8)]], device float4 *photo [[buffer(9)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
        uint flags = uint(p[7]);
        uint i = gid.y * uint(p[0]) + gid.x;
        float gain = p[5], weight = p[6];
        float2 camera = (float2(gid) + 0.5f) / p[4] - 0.5f;
        if (flags & 2048) {
            float2 d = sourcePoint(anchorPoint(gid, p), p) - camera;
            float2 s = camera - p[76] * d;
            float3 shifted;
            if (sampleMap(valid, s, p, true) <= 0.8f || onLine(s, lines, int(p[8]), int(p[9])) || !bilinear(source, (s + 0.5f) * p[4] - 0.5f, shifted)) return;
            if (flags & 4096) {
                float3 local;
                if (!bilinear(background, (s + 0.5f) * p[4] - 0.5f, local)) return;
                shifted -= local;
            }
            shifted *= gain;
            if (flags & 8) {
                float l = luminance(shifted);
                if (l > peak[i].w) peak[i] = float4(shifted, l);
            } else {
                peak[i] = float4(max(peak[i].rgb, shifted), peak[i].w);
            }
            return;
        }
        float3 v = texel(source, int(gid.x), int(gid.y)) * gain;
        if (flags & 2) ground[i] += float4(v * weight, weight);
        if (flags & 8192) photo[i] = float4(v, 1);
        if ((flags & 4) && !onLine(camera, lines, int(p[8]), int(p[9]))) {
            // Trails over a chosen sky take the detail above the photo's local background.
            float3 u = (flags & 4096) ? v - texel(background, int(gid.x), int(gid.y)) * gain : v;
            if (flags & 8) {
                float l = luminance(u);
                if (l > peak[i].w) peak[i] = float4(u, l);
            } else {
                peak[i] = float4(max(peak[i].rgb, u), 0);
            }
        }
        if (!(flags & 1) || sampleMap(probability, camera, p, true) <= 0.01f) return;
        float2 a = anchorPoint(gid, p);
        if (onLine(a, lines, 0, int(p[8]))) return;
        float2 s = sourcePoint(a, p);
        if (sampleMap(valid, s, p, true) <= 0.8f) return;
        float3 sample;
        if (!bilinear(source, (s + 0.5f) * p[4] - 0.5f, sample)) return;
        float l = luminance(sample * gain);
        if ((flags & 1024) && (flags & 16384)) {
            // Agreeing with the base photo, whose own pixel the ground sums alone.
            float4 g = ground[i];
            if (g.w > 0) {
                float b = luminance(g.rgb) / g.w;
                if (abs(l - b) > p[73] * 1.41421356f * p[75] * sqrt(max(1.0f, b / max(p[77], 1e-6f)))) return;
            }
        } else if (flags & 1024) {
            float4 f = first[i];
            float others = f.w - weight;
            if (others >= p[74]) {
                float mean = (luminance(f.rgb) - weight * l) / others;
                float deviation = max(p[75], sqrt(max(0.0f, (squares[i] - weight * l * l) / others - mean * mean)));
                if (abs(l - mean) > p[73] * deviation) return;
            }
        }
        sky[i] += float4(sample * gain * weight, weight);
        if (flags & 512) squares[i] += weight * l * l;
    }

    /// One direction of a box mean over 2 radius + 1 pixels, the window shrunk at the edges like the CPU's.
    kernel void night_box(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]],
                          constant uint2 &settings [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int w = int(input.get_width()), h = int(input.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        int r = int(settings.x);
        bool vertical = settings.y != 0;
        int at = vertical ? int(gid.y) : int(gid.x), end = vertical ? h : w;
        int low = max(0, at - r), high = min(end - 1, at + r);
        float3 sum = float3(0);
        for (int k = low; k <= high; k++) sum += texel(input, vertical ? int(gid.x) : k, vertical ? k : int(gid.y));
        output.write(float4(sum / float(high - low + 1), 1), gid);
    }

    /// Painted areas from the stored photo, over the result.
    kernel void night_regions(device float4 *out [[buffer(0)]], device const float4 *photo [[buffer(1)]], device const float *map [[buffer(3)]],
                              device const float *p [[buffer(5)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
        float a = sampleMap(map, (float2(gid) + 0.5f) / p[4] - 0.5f, p, false);
        if (a <= 0) return;
        uint i = gid.y * uint(p[0]) + gid.x;
        out[i] = float4(mix(out[i].rgb, photo[i].rgb, a), 1);
    }

    kernel void night_compose(device float4 *ground [[buffer(0)]], device const float4 *sky [[buffer(1)]], device const float4 *peak [[buffer(2)]],
                              device const float *probability [[buffer(3)]], device const float *p [[buffer(5)]], device float4 *clean [[buffer(6)]],
                              device const float4 *photo [[buffer(7)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
        uint flags = uint(p[7]);
        uint i = gid.y * uint(p[0]) + gid.x;
        float4 g4 = ground[i];
        float3 g = g4.w > 0 ? g4.rgb / g4.w : float3(0);
        float chance = sampleMap(probability, (float2(gid) + 0.5f) / p[4] - 0.5f, p, false);
        float a = (flags & 4) ? smooth(0.05f, 0.3f, chance) : smooth(0.35f, 0.65f, chance);
        float3 s = g;
        if ((flags & 4) && (flags & 4096)) {
            float4 k = peak[i];
            s = photo[i].rgb + (isfinite(k.r) ? max(k.rgb, float3(0)) : float3(0));
        } else if (flags & 4) {
            float4 k = peak[i];
            s = isfinite(k.r) ? k.rgb : g;
        } else if (flags & 1) {
            float4 k = sky[i];
            if (k.w > 0) s = k.rgb / k.w;
            a *= min(1.0f, k.w / max(1e-6f, p[72]));
        }
        float4 out = float4(a * s + (1 - a) * g, 1);
        ground[i] = out;
        if (flags & 256) clean[i] = out;
    }

    float3 lineBackground(float2 a, device const float *line, device const float *sky) {
        float2 start = float2(line[0], line[1]), delta = float2(line[2], line[3]) - start;
        float len = length(delta), radius = line[4];
        float2 direction = delta / max(1e-6f, len), d = a - start;
        int count = int(sky[0]);
        float t = clamp((dot(d, direction) + radius) / (len + 2 * radius) * (count - 1), 0.0f, float(count - 1));
        int i = min(count - 2, int(t));
        float f = t - i, across = clamp(0.5f + dot(d, float2(-direction.y, direction.x)) / (4 * radius), 0.0f, 1.0f);
        device const float *v = sky + 1 + i * 6;
        float3 left = mix(float3(v[0], v[1], v[2]), float3(v[6], v[7], v[8]), f);
        float3 right = mix(float3(v[3], v[4], v[5]), float3(v[9], v[10], v[11]), f);
        return mix(left, right, across);
    }

    kernel void night_restore(texture2d<float, access::read> source [[texture(0)]],
                              device float4 *out [[buffer(0)]], device const float4 *clean [[buffer(1)]], device float *score [[buffer(2)]],
                              device const float *valid [[buffer(4)]], device const float *p [[buffer(5)]], device const float *lines [[buffer(6)]],
                              device const float *sky [[buffer(7)]],
                              uint2 offset [[thread_position_in_grid]]) {
        uint2 gid = offset + uint2(uint(p[70]), uint(p[71]));
        if (gid.x >= uint(p[0]) || gid.y >= uint(p[1])) return;
        uint i = gid.y * uint(p[0]) + gid.x;
        float2 a = anchorPoint(gid, p);
        float radius = lines[4];
        float alpha = clamp((radius - lineDistance(a, lines)) / max(0.5f, radius * 0.35f), 0.0f, 1.0f);
        if (alpha <= 0) return;
        float2 s = sourcePoint(a, p);
        if (sampleMap(valid, s, p, true) <= 0.8f) return;
        float3 sample;
        if (!bilinear(source, (s + 0.5f) * p[4] - 0.5f, sample)) return;
        float3 value = sample * p[5] - lineBackground(a, lines, sky), background = clean[i].rgb;
        float candidate = alpha * luminance(value - background);
        if (candidate <= max(0.0f, score[i])) return;
        score[i] = candidate;
        out[i] = float4(background + alpha * (value - background), 1);
    }
    """
}
