import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// World rays to canvas coordinates at unit focal length. y points down, x right, z forward.
enum PanoramaProjector {
    static func project(_ ray: SIMD3<Double>, _ projection: PanoramaProjection) -> SIMD2<Double>? {
        let r = simd_normalize(ray)
        switch projection {
        case .cylindrical:
            let radius = hypot(r.x, r.z)
            guard radius > 0.05 else { return nil }
            return SIMD2(atan2(r.x, r.z), r.y / radius)
        case .spherical:
            return SIMD2(atan2(r.x, r.z), asin(max(-1, min(1, r.y))))
        case .perspective:
            guard r.z > 0.15 else { return nil }
            return SIMD2(r.x / r.z, r.y / r.z)
        }
    }

    /// The canvas rectangle (unit focal) covering every photo, or nil when the projection can't show them all.
    static func bounds(cameras: [PanoramaCamera], rotations: [simd_double3x3], members: [Int], projection: PanoramaProjection) -> (low: SIMD2<Double>, high: SIMD2<Double>)? {
        var low = SIMD2<Double>(repeating: .infinity), high = SIMD2<Double>(repeating: -.infinity)
        for i in members {
            let camera = cameras[i]
            var previous: Double?
            for step in 0...256 {
                // Walk the frame's outline so the curved edges of the warped photo are covered too.
                let t = Double(step % 64) / 64, side = step / 64
                let point: SIMD2<Double>
                switch side {
                case 0: point = SIMD2(t * camera.width, 0)
                case 1: point = SIMD2(camera.width, t * camera.height)
                case 2: point = SIMD2((1 - t) * camera.width, camera.height)
                default: point = SIMD2(0, (1 - t) * camera.height)
                }
                guard let p = project(rotations[i] * camera.ray(point), projection) else { return nil }
                // A photo straddling the seam behind the viewer would wrap around the canvas.
                if projection != .perspective, let previous, abs(p.x - previous) > .pi { return nil }
                previous = p.x
                low = simd_min(low, p); high = simd_max(high, p)
            }
        }
        if projection != .perspective && high.x - low.x > 1.95 * .pi { return nil }
        return (low, high)
    }
}

/// Where the canvas sits in projection space and how many pixels it has. A transposed canvas runs the projection's
/// horizontal axis down the picture (a vertical sweep); a flipped one runs it the other way.
struct PanoramaLayout {
    var projection: PanoramaProjection
    var origin: SIMD2<Double>
    var focal: Double
    var width: Int
    var height: Int
    var transposed = false
    var flipped = false
    init?(cameras: [PanoramaCamera], rotations: [simd_double3x3], members: [Int], projection: PanoramaProjection, focal: Double, maxPixels: Double,
          transposed: Bool = false, flipped: Bool = false) {
        guard var (low, high) = PanoramaProjector.bounds(cameras: cameras, rotations: rotations, members: members, projection: projection) else { return nil }
        if flipped { (low.x, high.x) = (-high.x, -low.x) }
        var focal = focal
        let area = (high.x - low.x) * (high.y - low.y) * focal * focal
        if area > maxPixels { focal *= sqrt(maxPixels / area) }
        self.projection = projection; self.focal = focal; self.transposed = transposed; self.flipped = flipped
        origin = SIMD2(floor(low.x * focal), floor(low.y * focal))
        let along = Int(ceil(high.x * focal) - origin.x), across = Int(ceil(high.y * focal) - origin.y)
        (width, height) = transposed ? (across, along) : (along, across)
        guard width > 0, height > 0, width <= 65_000, height <= 65_000 else { return nil }
    }
}

private struct WarpParameters {
    var inverseRotation: simd_float3x3
    var camera: SIMD4<Float>   // cx, cy, focal, k1
    var canvas: SIMD4<Float>   // origin x, origin y, canvas focal, exposure gain
    var frame: SIMD4<Float>    // width, height, feather, projection
    var layout: SIMD4<Float>   // transposed, horizontal sign, unused, k2
    var size: SIMD2<UInt32>
}

/// Inverse-maps every canvas pixel into each photo on the GPU and blends in two bands, as in Brown and Lowe's
/// AutoStitch: each photo's low frequencies (a Gaussian blur of about 1% of its long edge) blend with weights that fall
/// to zero at its edges over a quarter of the frame, which hides differences in exposure and vignetting, while the
/// detail above that comes from one photo only: the one whose optical axis points nearest, so the seams run midway
/// between neighbouring photos' centres. Where small misalignment remains (an imperfect lens model, parallax, things
/// that moved) a seam can show a slight step, but edges never double. In float, so nothing clips; photos are developed
/// linear RGB.
final class PanoramaCompositor {
    /// Nil when the Mac has no usable GPU, or for the CPU reference in tests: then the same blend runs on the CPU.
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let accumulate: MTLComputePipelineState?
    private let normalize: MTLComputePipelineState?
    /// Bytes per canvas pixel: the low band's and detail band's sums.
    static let bytesPerPixel = 32

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct WarpParameters { float3x3 inverseRotation; float4 camera; float4 canvas; float4 frame; float4 layout; uint2 size; };
    kernel void accumulatePanorama(texture2d<float, access::sample> source [[texture(0)]], texture2d<float, access::sample> low [[texture(1)]],
                                   device float4 *lowSum [[buffer(0)]], device float4 *detailSum [[buffer(2)]],
                                   constant WarpParameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size.x || gid.y >= p.size.y) return;
        float2 c = float2(gid) + 0.5;
        float2 q = p.layout.x > 0.5 ? c.yx : c;
        float2 plane = (q + p.canvas.xy) / p.canvas.z;
        plane.x *= p.layout.y;
        float3 world;
        uint projection = uint(p.frame.w);
        if (projection == 0) world = float3(sin(plane.x), plane.y, cos(plane.x));
        else if (projection == 1) world = float3(sin(plane.x) * cos(plane.y), sin(plane.y), cos(plane.x) * cos(plane.y));
        else world = float3(plane, 1);
        float3 local = p.inverseRotation * world;
        if (local.z <= 0.001) return;
        float2 d = p.camera.z * local.xy / local.z;
        float2 size = p.frame.xy;
        // Radial distortion of a lens the decoder didn't correct, against half the diagonal.
        float r2 = dot(d, d) / (0.25f * dot(size, size));
        if (r2 > 2.25f) return;
        float2 uv = p.camera.xy + d * (1.0f + p.camera.w * r2 + p.layout.w * r2 * r2);
        // The outermost pixels of a reduced decode are darkened by its resampling; photos overlap, so they're left out.
        if (any(uv < 2.5) || any(uv > size - 2.5)) return;
        constexpr sampler linear(coord::pixel, filter::linear, address::clamp_to_edge);
        float3 value = source.sample(linear, uv).rgb * p.canvas.w;
        float3 base = low.sample(linear, uv).rgb * p.canvas.w;
        float edge = min(min(uv.x, uv.y), min(size.x - uv.x, size.y - uv.y));
        float weight = max(clamp(edge / p.frame.z, 0.0f, 1.0f), 1e-6f);
        // Detail from the photo whose axis is nearest: photos are blended one after another, so each pixel keeps the
        // nearest so far (closeness is above zero wherever a photo lands).
        float closeness = local.z / length(local);
        uint i = gid.y * p.size.x + gid.x;
        lowSum[i] += float4(base * weight, weight);
        if (closeness > detailSum[i].w) detailSum[i] = float4(value - base, closeness);
    }
    kernel void normalizePanorama(device float4 *lowSum [[buffer(0)]], device const float4 *detailSum [[buffer(2)]],
                                  constant uint &count [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        if (i >= count) return;
        float4 v = lowSum[i], d = detailSum[i];
        lowSum[i] = v.a > 0 ? float4(max(v.rgb / v.a + d.rgb, 0.0f), 1) : float4(0);
    }
    """

    init(useGPU: Bool = true) {
        var pipelines: (MTLDevice, MTLCommandQueue, MTLComputePipelineState, MTLComputePipelineState)?
        if useGPU, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
           let library = try? device.makeLibrary(source: Self.source, options: nil),
           let a = library.makeFunction(name: "accumulatePanorama").flatMap({ try? device.makeComputePipelineState(function: $0) }),
           let n = library.makeFunction(name: "normalizePanorama").flatMap({ try? device.makeComputePipelineState(function: $0) }) {
            pipelines = (device, queue, a, n)
        }
        device = pipelines?.0; queue = pipelines?.1; accumulate = pipelines?.2; normalize = pipelines?.3
    }

    /// The developed frame, optionally box-reduced to `longEdge`, as a texture on the GPU or as pixels for the CPU blend.
    func texture(_ frame: PanoramaFrame, longEdge: Int? = nil) throws -> PanoramaSource {
        let scale = longEdge.map { min(1, Double($0) / Double(max(frame.width, frame.height))) } ?? 1
        let width = max(1, Int(Double(frame.width) * scale)), height = max(1, Int(Double(frame.height) * scale))
        let reduced = scale == 1 ? frame : PanoramaFrame(width: width, height: height, pixels: Self.reduce(frame, width: width, height: height))
        guard let device else { return PanoramaSource(frame: reduced) }
        guard width <= 16384, height <= 16384 else { throw PanoramaError.message(L10n.tr("A photo is too large for the GPU.")) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw PanoramaError.message(L10n.tr("Not enough GPU memory for the panorama.")) }
        reduced.pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        return PanoramaSource(texture: texture)
    }

    /// Box-averages the frame down to width × height.
    private static func reduce(_ frame: PanoramaFrame, width: Int, height: Int) -> [Float] {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        let (sw, sh) = (frame.width, frame.height)
        frame.pixels.withUnsafeBufferPointer { pixels in
            rgba.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let y0 = y * sh / height, y1 = max(y0 + 1, (y + 1) * sh / height)
                    for x in 0..<width {
                        let x0 = x * sw / width, x1 = max(x0 + 1, (x + 1) * sw / width)
                        var sum = SIMD3<Float>(repeating: 0)
                        for sy in y0..<y1 { for sx in x0..<x1 {
                            let p = (sy * sw + sx) * 4
                            sum += SIMD3(pixels[p], pixels[p + 1], pixels[p + 2])
                        }}
                        sum /= Float((y1 - y0) * (x1 - x0))
                        for c in 0..<3 { out[(y * width + x) * 4 + c] = sum[c] }
                    }
                }
            }
        }
        return rgba
    }

    /// The photo's low band: a Gaussian blur of about 1% of its long edge.
    private func lowPass(_ source: MTLTexture) throws -> MTLTexture {
        guard let device, let queue else { throw EditorError.noGPU }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]; descriptor.storageMode = .private
        guard let low = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw PanoramaError.message(L10n.tr("Not enough GPU memory for the panorama."))
        }
        let blur = MPSImageGaussianBlur(device: device, sigma: Float(max(source.width, source.height)) * 0.01)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: low)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        return low
    }

    /// Blends the frames into the layout. `frames` hands over one texture at a time so full-size photos are never
    /// all in memory together.
    func render(layout: PanoramaLayout, cameras: [PanoramaCamera], rotations: [simd_double3x3], gains: [Double],
                frames: [Int], texture: (Int) throws -> PanoramaSource, progress: (Int) -> Void, cancelled: () -> Bool) throws -> PanoramaRaster {
        guard let device, let queue, let accumulate, let normalize else {
            return try PanoramaCPUBlend.render(layout: layout, cameras: cameras, rotations: rotations, gains: gains, frames: frames,
                                               source: { try texture($0).frame! }, progress: progress, cancelled: cancelled)
        }
        let count = layout.width * layout.height
        guard count * 16 <= device.maxBufferLength, let sum = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let detail = device.makeBuffer(length: count * 16, options: .storageModePrivate) else {
            throw PanoramaError.message(L10n.tr("Not enough GPU memory for a \(layout.width) × \(layout.height) panorama."))
        }
        memset(sum.contents(), 0, sum.length)
        if let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() {
            blit.fill(buffer: detail, range: 0..<detail.length, value: 0)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        }
        for (done, index) in frames.enumerated() {
            if cancelled() { throw CancellationError() }
            try autoreleasepool {
                let source = try texture(index).texture!
                let low = try lowPass(source)
                let camera = cameras[index].resized(width: source.width, height: source.height)
                let r = rotations[index].transpose
                var parameters = WarpParameters(
                    inverseRotation: simd_float3x3(columns: (SIMD3<Float>(r[0]), SIMD3<Float>(r[1]), SIMD3<Float>(r[2]))),
                    camera: SIMD4(Float(camera.center.x), Float(camera.center.y), Float(camera.focal), Float(camera.k1)),
                    canvas: SIMD4(Float(layout.origin.x), Float(layout.origin.y), Float(layout.focal), Float(gains[index])),
                    frame: SIMD4(Float(source.width), Float(source.height), Float(0.25 * Double(max(source.width, source.height))),
                                 Float(layout.projection.code)),
                    layout: SIMD4(layout.transposed ? 1 : 0, layout.flipped ? -1 : 1, 0, Float(camera.k2)),
                    size: SIMD2(UInt32(layout.width), UInt32(layout.height)))
                guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                    throw PanoramaError.message(L10n.tr("The GPU is unavailable."))
                }
                encoder.setComputePipelineState(accumulate)
                encoder.setTexture(source, index: 0); encoder.setTexture(low, index: 1)
                encoder.setBuffer(sum, offset: 0, index: 0); encoder.setBuffer(detail, offset: 0, index: 2)
                encoder.setBytes(&parameters, length: MemoryLayout<WarpParameters>.stride, index: 1)
                let w = accumulate.threadExecutionWidth, h = max(1, accumulate.maxTotalThreadsPerThreadgroup / w)
                encoder.dispatchThreads(MTLSize(width: layout.width, height: layout.height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
            }
            progress(done + 1)
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw PanoramaError.message(L10n.tr("The GPU is unavailable.")) }
        var total = UInt32(count)
        encoder.setComputePipelineState(normalize)
        encoder.setBuffer(sum, offset: 0, index: 0); encoder.setBuffer(detail, offset: 0, index: 2); encoder.setBytes(&total, length: 4, index: 1)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: normalize.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let rgba = Array(UnsafeBufferPointer(start: sum.contents().bindMemory(to: Float.self, capacity: count * 4), count: count * 4))
        return PanoramaRaster(width: layout.width, height: layout.height, rgba: rgba)
    }
}

/// A developed photo ready to blend: a texture for the GPU, or its pixels for the CPU.
final class PanoramaSource {
    let texture: MTLTexture?
    let frame: PanoramaFrame?
    init(texture: MTLTexture) { self.texture = texture; frame = nil }
    init(frame: PanoramaFrame) { texture = nil; self.frame = frame }
    var width: Int { texture?.width ?? frame!.width }
    var height: Int { texture?.height ?? frame!.height }
}

/// `PanoramaCompositor`'s two-band blend on the CPU, for Macs without a usable GPU: the same mapping, weights and bands,
/// with the Gaussian low pass approximated by three box passes of the same spread.
enum PanoramaCPUBlend {
    static func render(layout: PanoramaLayout, cameras: [PanoramaCamera], rotations: [simd_double3x3], gains: [Double], frames: [Int],
                       source: (Int) throws -> PanoramaFrame, progress: (Int) -> Void, cancelled: () -> Bool) throws -> PanoramaRaster {
        let count = layout.width * layout.height
        var low = [Float](repeating: 0, count: count * 4), detail = [Float](repeating: 0, count: count * 4)
        for (done, index) in frames.enumerated() {
            if cancelled() { throw CancellationError() }
            let frame = try source(index)
            let (w, h) = (frame.width, frame.height)
            // Three box passes of radius r have a standard deviation of about r, matching the GPU's sigma of 1% of the long edge.
            let radius = max(1, Int((Double(max(w, h)) * 0.01).rounded()))
            var blurred = [[Float]](repeating: [], count: 3)
            DispatchQueue.concurrentPerform(iterations: 3) { c in
                var plane = (0..<w * h).map { frame.pixels[$0 * 4 + c] }
                for _ in 0..<3 { plane = HDRMerger.boxBlur(plane, width: w, height: h, radius: radius) }
                blurred[c] = plane
            }
            let camera = cameras[index].resized(width: w, height: h)
            let inverse = rotations[index].transpose
            let gain = Float(gains[index]), feather = 0.25 * Double(max(w, h))
            let sign = layout.flipped ? -1.0 : 1.0
            func bilinear(_ read: (Int) -> Float, _ u: Double, _ v: Double) -> Float {
                let x = max(0, min(Double(w - 1), u - 0.5)), y = max(0, min(Double(h - 1), v - 0.5))
                let x0 = Int(x), y0 = Int(y), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
                let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                let top = read(y0 * w + x0) * (1 - fx) + read(y0 * w + x1) * fx
                let bottom = read(y1 * w + x0) * (1 - fx) + read(y1 * w + x1) * fx
                return top * (1 - fy) + bottom * fy
            }
            low.withUnsafeMutableBufferPointer { lowSum in
                detail.withUnsafeMutableBufferPointer { detailSum in
                    let lowSum = lowSum, detailSum = detailSum
                    DispatchQueue.concurrentPerform(iterations: layout.height) { gy in
                        for gx in 0..<layout.width {
                            let c = SIMD2(Double(gx) + 0.5, Double(gy) + 0.5)
                            let q = layout.transposed ? SIMD2(c.y, c.x) : c
                            var plane = (q + layout.origin) / layout.focal
                            plane.x *= sign
                            let world: SIMD3<Double>
                            switch layout.projection {
                            case .cylindrical: world = SIMD3(sin(plane.x), plane.y, cos(plane.x))
                            case .spherical: world = SIMD3(sin(plane.x) * cos(plane.y), sin(plane.y), cos(plane.x) * cos(plane.y))
                            case .perspective: world = SIMD3(plane.x, plane.y, 1)
                            }
                            let local = inverse * world
                            guard local.z > 0.001 else { continue }
                            guard let uv = camera.point(local) else { continue }
                            let u = uv.x, v = uv.y
                            guard u >= 2.5, v >= 2.5, u <= Double(w) - 2.5, v <= Double(h) - 2.5 else { continue }
                            let edge = min(min(u, v), min(Double(w) - u, Double(h) - v))
                            let weight = Float(max(min(edge / feather, 1), 1e-6))
                            let closeness = Float(local.z / simd_length(local))
                            let i = (gy * layout.width + gx) * 4
                            let nearest = closeness > detailSum[i + 3]
                            for ch in 0..<3 {
                                let value = bilinear({ frame.pixels[$0 * 4 + ch] }, u, v) * gain
                                let base = bilinear({ blurred[ch][$0] }, u, v) * gain
                                lowSum[i + ch] += base * weight
                                if nearest { detailSum[i + ch] = value - base }
                            }
                            lowSum[i + 3] += weight
                            if nearest { detailSum[i + 3] = closeness }
                        }
                    }
                }
            }
            progress(done + 1)
        }
        for i in stride(from: 0, to: low.count, by: 4) {
            let w = low[i + 3]
            for c in 0..<3 { low[i + c] = w > 0 ? max(0, low[i + c] / w + detail[i + c]) : 0 }
            low[i + 3] = w > 0 ? 1 : 0
        }
        return PanoramaRaster(width: layout.width, height: layout.height, rgba: low)
    }
}
