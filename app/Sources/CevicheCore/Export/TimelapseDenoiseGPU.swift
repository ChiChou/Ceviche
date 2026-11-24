#if os(macOS)
import CoreImage
import CoreVideo
import Metal
import simd

/// Serially owned by TimelapseDenoiser. Half-float sources/means/masks; float accumulation. No recursive history.
final class TimelapseDenoiseGPU {
    struct Frame {
        let pixels: MTLTexture
        let means: MTLTexture
        let sky: MTLTexture
        let stars: [NightSkyStar]
        let sigma: SIMD3<Float>
    }
    struct Neighbor {
        let frame: Frame
        let alignment: NightSkyAlignment
    }
    let device: MTLDevice
    let context: CIContext
    let width: Int, height: Int
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    private var workspace: (sums: MTLTexture, result: MTLTexture)?

    init(size: CGSize) throws {
        guard size.width >= 16, size.height >= 16, size.width <= 8192, size.height <= 8192,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw EditorError.render }
        width = Int(size.width); height = Int(size.height)
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.workingColorSpace: TimelapsePhoto.space,
                                                       .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let options = MTLCompileOptions(); options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.source, options: options)
        var pipelines: [String: MTLComputePipelineState] = [:]
        for name in ["means", "analysis", "noise", "initialize", "accumulate", "finish"] {
            guard let function = library.makeFunction(name: name) else { throw EditorError.render }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
    }

    func texture(width: Int? = nil, height: Int? = nil, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width ?? self.width,
                                                                 height: height ?? self.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EditorError.render }
        return texture
    }
    private func encode(_ name: String, _ commands: MTLCommandBuffer, _ textures: [MTLTexture], parameters: [Float] = [], size: (Int, Int)? = nil) throws {
        guard let encoder = commands.makeComputeCommandEncoder(), let pipeline = pipelines[name] else { throw EditorError.render }
        encoder.setComputePipelineState(pipeline)
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        if !parameters.isEmpty { encoder.setBytes(parameters, length: parameters.count * MemoryLayout<Float>.stride, index: 0) }
        encoder.dispatchThreads(MTLSize(width: size?.0 ?? width, height: size?.1 ?? height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
    private func run(_ commands: MTLCommandBuffer) throws {
        try Task.checkCancellation()
        GPUForeground.wait(); commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        try Task.checkCancellation()
    }
    private var flip: CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(height)) }
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// skyOverride is a numeric mask for deterministic tests. Production always uses the installed Sky model.
    func prepare(_ photo: TimelapsePhoto, skyOverride: CIImage? = nil, skyCache: TimelapseSkyCache? = nil, maskKey: String = "") throws -> Frame {
        try Task.checkCancellation()
        guard CVPixelBufferGetWidth(photo.pixels) == width, CVPixelBufferGetHeight(photo.pixels) == height else { throw EditorError.render }
        let image = photo.image
        let skyImage: CIImage
        if let skyOverride { skyImage = skyOverride.cropped(to: bounds) }
        else {
            let makeMask = { [self] () throws -> CIImage in
                // The model sees a brightened small image; its mask is refined against the actual skyline. Erode the
                // uncertain edge before merging, leaving thin branches and skyline pixels to the current photo.
                let guide = RawRenderer.scaled(image, limit: 1280)
                var sample = [Float](repeating: 0, count: 32 * 32 * 4)
                sample.withUnsafeMutableBytes {
                    context.render(SkyMaskModel.resample(guide, to: CGSize(width: 32, height: 32)), toBitmap: $0.baseAddress!,
                                   rowBytes: 32 * 16, bounds: CGRect(x: 0, y: 0, width: 32, height: 32), format: .RGBAf, colorSpace: TimelapsePhoto.space)
                }
                let median = NightSkyStars.median(stride(from: 0, to: sample.count, by: 4).map { Double(max(0, sample[$0 + 1])) })
                let bright = guide.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: max(-2, min(6, log2(0.12 / max(1e-6, median))))])
                let coarse = try SkyMaskModel.loadBundled().coarseMask(for: bright, context: context)
                let refined = MaskRefinement.sky.apply(coarse, guide: bright).applyingFilter("CISRGBToneCurveToLinear")
                    .clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3]).cropped(to: guide.extent)
                return refined
            }
            let refined = try skyCache.map { try $0.mask(key: maskKey, context: context, make: makeMask) } ?? makeMask()
            skyImage = SkyMaskModel.resample(refined, to: bounds.size)
        }
        let pixels = try texture(), means = try texture(), sky = try texture(format: .r16Float)
        // Keep at least 3200 pixels on the long edge for star registration (4K therefore uses the full frame).
        let step = max(1, max(width, height) / 3200), aw = width / step, ah = height / step
        let analysis = try texture(width: aw, height: ah, format: .rgba32Float)
        let analysisSky = try texture(width: aw, height: ah, format: .rgba32Float)
        let nw = (width - 7) / 7 + 1, nh = (height - 7) / 7 + 1
        let noise = try texture(width: nw, height: nh, format: .rgba32Float)
        guard let commands = queue.makeCommandBuffer() else { throw EditorError.render }
        context.render(image.transformed(by: flip), to: pixels, commandBuffer: commands, bounds: bounds, colorSpace: TimelapsePhoto.space)
        context.render(skyImage.transformed(by: flip), to: sky, commandBuffer: commands, bounds: bounds,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        try encode("means", commands, [pixels, means])
        try encode("analysis", commands, [pixels, analysis], parameters: [Float(step)], size: (aw, ah))
        try encode("analysis", commands, [sky, analysisSky], parameters: [Float(step)], size: (aw, ah))
        try encode("noise", commands, [pixels, noise], size: (nw, nh))
        try run(commands)
        let values = readFloat(analysis), skyValues = readFloat(analysisSky), noiseValues = readFloat(noise)
        let mask = stride(from: 0, to: skyValues.count, by: 4).map { skyValues[$0] }
        let luminance = stride(from: 0, to: values.count, by: 4).map { values[$0] * 0.2627 + values[$0 + 1] * 0.6780 + values[$0 + 2] * 0.0593 }
        let detected = try NightSkyStars.detect(luminance, width: aw, height: ah, mask: mask, limit: 500)
        let stars = detected.map { star -> NightSkyStar in
            var star = star
            star.point = (star.point + SIMD2<Double>(repeating: 0.5)) * Double(step) - SIMD2<Double>(repeating: 0.5)
            star.radius *= Double(step); star.flux *= Double(step * step)
            return star
        }
        var sigma = SIMD3<Float>(repeating: 1e-7)
        let valid = (0..<(nw * nh)).filter { p in
            mask[min(ah - 1, (p / nw * 7 + 3) / step) * aw + min(aw - 1, (p % nw * 7 + 3) / step)] > 0.98
        }
        for c in 0..<3 {
            let samples = valid.map { Double(noiseValues[$0 * 4 + c]) }.filter { $0.isFinite }
            let median = NightSkyStars.median(samples)
            sigma[c] = Float(max(1e-7, 1.4826 * NightSkyStars.median(samples.map { abs($0 - median) }) / sqrt(20)))
        }
        return Frame(pixels: pixels, means: means, sky: sky, stars: stars, sigma: sigma)
    }

    private func readFloat(_ texture: MTLTexture) -> [Float] {
        var result = [Float](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 16,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    /// No neighbor gain is applied: saved exposure ramps and grading belong to the current frame. Mismatching
    /// brightness/colour is rejected instead of dragging the reference toward another photo's edit.
    func merge(reference: Frame, neighbors: [Neighbor]) throws -> MTLTexture {
        guard !neighbors.isEmpty else { return reference.pixels }
        if workspace == nil { workspace = (try texture(format: .rgba32Float), try texture()) }
        let (sums, result) = workspace!
        guard let commands = queue.makeCommandBuffer() else { throw EditorError.render }
        try encode("initialize", commands, [reference.pixels, sums])
        for neighbor in neighbors {
            try Task.checkCancellation()
            var p = [Float](repeating: 0, count: 40)
            p[0] = Float(height); p[1] = 1; p[2] = 1
            let variance = reference.sigma * reference.sigma + neighbor.frame.sigma * neighbor.frame.sigma
            p[3] = variance.x; p[4] = variance.y; p[5] = variance.z
            let inverse = neighbor.alignment.inverse.normalized
            for k in 0..<9 { p[10 + k] = Float(inverse.m[k]) }
            if let morph = neighbor.alignment.morph {
                p[6] = 1; p[7] = Float(morph.scale)
                for k in 0..<10 { p[20 + k] = Float(morph.x[k]); p[30 + k] = Float(morph.y[k]) }
            }
            try encode("accumulate", commands, [reference.pixels, reference.means, neighbor.frame.pixels, neighbor.frame.means,
                                               sums, reference.sky, neighbor.frame.sky], parameters: p)
        }
        try encode("finish", commands, [sums, result]); try run(commands)
        return result
    }

    /// Materialize before reusing the merge workspace, including when capture-time blending holds two results.
    func photo(_ texture: MTLTexture) throws -> TimelapsePhoto {
        guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: TimelapsePhoto.space]) else { throw EditorError.render }
        return try TimelapsePhoto.render(image.transformed(by: flip), size: bounds.size, context: context)
    }
    func preview(_ photo: TimelapsePhoto, size: CGSize) throws -> CGImage {
        let image = SkyMaskModel.resample(photo.image, to: size)
        guard let result = context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw EditorError.render }
        return result
    }
    func clear() { workspace = nil; context.clearCaches() }
}

extension TimelapseDenoiseGPU {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);
    bool outside(uint2 p, texture2d<float, access::read> t) { return p.x >= t.get_width() || p.y >= t.get_height(); }
    kernel void analysis(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]],
                         constant float *v [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=output.get_width() || p.y>=output.get_height()) return;
        uint step=uint(v[0]);float3 sum=0;
        for(uint y=0;y<step;y++) for(uint x=0;x<step;x++) sum+=input.read(p*step+uint2(x,y)).rgb;
        output.write(float4(sum/float(step*step),1),p);
    }
    kernel void noise(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if(p.x>=output.get_width() || p.y>=output.get_height()) return;
        uint2 q=p*7+3;
        float3 high=4*input.read(q).rgb-input.read(q-uint2(1,0)).rgb-input.read(q+uint2(1,0)).rgb-input.read(q-uint2(0,1)).rgb-input.read(q+uint2(0,1)).rgb;
        output.write(float4(high,1),p);
    }
    kernel void means(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (outside(p, input)) return;
        float3 sum = 0;
        for (int y = -2; y <= 2; ++y) for (int x = -2; x <= 2; ++x) {
            uint2 q = uint2(clamp(int2(p) + int2(x,y), int2(0), int2(input.get_width()-1,input.get_height()-1)));
            sum += input.read(q).rgb;
        }
        output.write(float4(sum / 25, 1), p);
    }
    kernel void initialize(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> sums [[texture(1)]],
                           uint2 p [[thread_position_in_grid]]) {
        if (outside(p, input)) return;
        sums.write(float4(input.read(p).rgb, 1), p);
    }
    float2 inverseMap(float2 x, constant float *p) {
        float z = p[16]*x.x + p[17]*x.y + p[18];
        return float2(p[10]*x.x + p[11]*x.y + p[12], p[13]*x.x + p[14]*x.y + p[15]) / z;
    }
    float polynomial(float2 x, constant float *a) {
        float u=x.x,v=x.y;
        return a[0]+u*(a[1]+u*(a[3]+u*a[6])+v*(a[4]+u*a[7]+v*a[8]))+v*(a[2]+v*(a[5]+v*a[9]));
    }
    float2 sourcePoint(float2 target, constant float *p) {
        float2 q=inverseMap(target,p);
        if (p[6]>0) for(int i=0;i<5;i++) {
            float2 v=q/p[7]-float2(.5,.35);
            q=inverseMap(target-float2(polynomial(v,p+20),polynomial(v,p+30)),p);
        }
        return q;
    }
    kernel void accumulate(texture2d<float, access::read> reference [[texture(0)]], texture2d<float, access::read> refMean [[texture(1)]],
                           texture2d<float, access::sample> other [[texture(2)]], texture2d<float, access::sample> otherMean [[texture(3)]],
                           texture2d<float, access::read_write> sums [[texture(4)]], texture2d<float, access::read> referenceSky [[texture(5)]],
                           texture2d<float, access::sample> otherSky [[texture(6)]],
                           constant float *v [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if(outside(p, reference) || p.y>=v[0]) return;
        float2 q=sourcePoint(float2(p),v);
        // No edge clamping as evidence, and no warping the excluded foreground into the sky.
        if(!all(isfinite(q)) || q.x<2 || q.y<2 || q.x>=other.get_width()-3 || q.y>=v[0]-3) return;
        float3 a=reference.read(p).rgb, b=other.sample(linearSampler,q+.5).rgb*v[2];
        if(!all(isfinite(b))) return;
        float weight=smoothstep(.95f,.995f,referenceSky.read(p).r)*smoothstep(.95f,.995f,otherSky.sample(linearSampler,q+.5).r);
        if(weight<=0) return;
        if(v[1]>0) {
            float3 variance=max(float3(v[3],v[4],v[5]),float3(1e-14));
            float3 delta=refMean.read(p).rgb-otherMean.sample(linearSampler,q+.5).rgb*v[2];
            // Four effective samples rather than 25: conservative allowance for correlated demosaic/resize noise.
            float score=max(max(delta.x*delta.x/variance.x,delta.y*delta.y/variance.y),delta.z*delta.z/variance.z)*4;
            weight*=exp(-max(0.0f,score-3)/4);
            // A transient can be thin enough to disappear in the local mean. Reject gross pixel disagreement too.
            float3 diff=abs(a-b)/sqrt(variance);
            float worst=max(max(diff.x,diff.y),diff.z);
            weight*=1-smoothstep(4.0f,7.0f,worst);
        }
        sums.write(sums.read(p)+float4(b*weight,weight),p);
    }
    kernel void finish(texture2d<float, access::read> sums [[texture(0)]], texture2d<float, access::write> result [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if(outside(p,sums)) return;
        float4 s=sums.read(p); result.write(float4(s.rgb/s.a,1),p);
    }
    """
}
#endif
