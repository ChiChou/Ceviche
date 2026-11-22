import Foundation
import CoreGraphics
import Metal
import MetalKit
import simd

/// Measured focus position (capture order, not distance) and confidence on the exact preview grid.
/// The shared texture is written once by Metal and remains immutable after publication.
public final class FocusStackInspection: @unchecked Sendable {
    public let field: MTLTexture
    init(field: MTLTexture) { self.field = field }
}

public enum FocusStackInspectionMode: UInt32, CaseIterable, Sendable {
    case image, sources, depth, confidence, relief
    public var requiresInspection: Bool { self == .depth || self == .confidence || self == .relief }
}

public struct FocusStackInspectionCamera: Sendable {
    public var yaw: Float = -0.35
    public var pitch: Float = 0.65
    public var zoom: Float = 1
    public var relief: Float = 0.22
    public var inverted = false
    public init() {}
}

/// Native GPU measurement and rendering shared by the live canvas and offscreen visual checks.
/// Call from one task at a time. No CPU renderer or third-party geometry code is used.
public final class FocusStackInspectionRenderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let reduce: MTLComputePipelineState
    private let crop: MTLComputePipelineState
    private let flat: MTLRenderPipelineState
    private let surface: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var photo: MTLTexture?
    private var sourceColors: MTLTexture?
    private var inspection: FocusStackInspection?
    private var depthTarget: MTLTexture?

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Self.failure() }
        self.queue = queue
        let options = MTLCompileOptions(); options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.shader, options: options)
        reduce = try device.makeComputePipelineState(function: library.makeFunction(name: "inspect_reduce")!)
        crop = try device.makeComputePipelineState(function: library.makeFunction(name: "inspect_crop")!)
        func pipeline(_ vertex: String, _ fragment: String, depth: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            if depth { descriptor.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        flat = try pipeline("inspect_flat", "inspect_overlay", depth: false)
        surface = try pipeline("inspect_surface", "inspect_texture", depth: true)
        let descriptor = MTLDepthStencilDescriptor(); descriptor.depthCompareFunction = .less; descriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: descriptor) else { throw Self.failure() }
        self.depthState = depthState
    }

    private static func failure() -> NSError { NSError(domain: "FocusStackInspection", code: 1) }
    private func buffer(_ length: Int) throws -> MTLBuffer {
        guard let result = device.makeBuffer(length: max(16, length), options: .storageModeShared) else { throw Self.failure() }
        return result
    }
    private func dispatch(_ pipeline: MTLComputePipelineState, _ width: Int, _ height: Int,
                          _ body: (MTLComputeCommandEncoder) -> Void) throws {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { throw Self.failure() }
        encoder.setComputePipelineState(pipeline); body(encoder)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding(); commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }

    /// Stream one focus plane at a time: GPU scratch does not grow with the bracket length.
    func measure(focus: [[Float]], included: [Int], width: Int, height: Int,
                 outputWidth: Int, outputHeight: Int, offset: SIMD2<Double>, scale: Double) throws -> FocusStackInspection {
        let n = width * height
        precondition(!included.isEmpty && included.allSatisfy { focus[$0].count == n })
        let input = try buffer(n * 4), state = try buffer(n * 16)
        for (pass, index) in included.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            focus[index].withUnsafeBytes { bytes in input.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
            var p = SIMD4<UInt32>(UInt32(n), UInt32(index), UInt32(pass), UInt32(focus.count))
            try dispatch(reduce, n, 1) { encoder in
                encoder.setBuffer(input, offset: 0, index: 0); encoder.setBuffer(state, offset: 0, index: 1)
                encoder.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 2)
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: outputWidth, height: outputHeight, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Self.failure() }
        var dimensions = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(outputWidth), UInt32(outputHeight))
        var mapping = SIMD4<Float>(Float(offset.x), Float(offset.y), Float(scale), Float(max(1, focus.count - 1)))
        try dispatch(crop, outputWidth, outputHeight) { encoder in
            encoder.setBuffer(state, offset: 0, index: 0)
            encoder.setBytes(&dimensions, length: MemoryLayout.size(ofValue: dimensions), index: 1)
            encoder.setBytes(&mapping, length: MemoryLayout.size(ofValue: mapping), index: 2)
            encoder.setTexture(texture, index: 0)
        }
        return FocusStackInspection(field: texture)
    }

    public func setPreview(_ preview: FocusStackPreview) throws {
        guard let inspection = preview.inspection else { throw Self.failure() }
        try setContent(inspection: inspection, image: preview.image, sources: preview.sources)
    }

    /// Also used by deterministic offscreen checks; texture uploads happen only when the preview changes.
    public func setContent(inspection: FocusStackInspection, image: CGImage, sources: CGImage) throws {
        guard inspection.field.device.registryID == device.registryID else { throw Self.failure() }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                                                       .textureUsage: MTLTextureUsage.shaderRead.rawValue]
        let photo = try loader.newTexture(cgImage: image, options: options)
        let sourceColors = try loader.newTexture(cgImage: sources, options: options)
        self.photo = photo; self.sourceColors = sourceColors; self.inspection = inspection
    }

    private struct Uniforms {
        var matrix: simd_float4x4
        var imageAspect: Float, viewAspect: Float, relief: Float, opacity: Float
        var mode: UInt32, inverted: UInt32, columns: UInt32, rows: UInt32
    }

    /// Returns an uncommitted command buffer so the caller can present its drawable without a CPU wait.
    public func render(target: MTLTexture, mode: FocusStackInspectionMode, camera: FocusStackInspectionCamera = .init(),
                       opacity: Float = 0.65) throws -> MTLCommandBuffer {
        guard let inspection, let photo, let sourceColors, let commands = queue.makeCommandBuffer() else { throw Self.failure() }
        let aspect = Float(inspection.field.width) / Float(inspection.field.height)
        let viewAspect = Float(target.width) / Float(target.height)
        let columns = min(320, max(2, inspection.field.width - 1)), rows = min(320, max(2, inspection.field.height - 1))
        let cy = cos(camera.yaw), sy = sin(camera.yaw), cp = cos(camera.pitch), sp = sin(camera.pitch)
        let rotationY = simd_float4x4(columns: (SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1)))
        let rotationX = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cp, sp, 0), SIMD4(0, -sp, cp, 0), SIMD4(0, 0, 0, 1)))
        let fit = 0.78 * max(0.3, min(4, camera.zoom))
        // Orthographic inspection: keep image geometry and Z scale stable as the camera rotates.
        let sx = fit * min(1, 1 / viewAspect), syView = fit * min(1, viewAspect)
        let projection = simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, syView, 0, 0), SIMD4(0, 0, -0.2, 0), SIMD4(0, 0, 0.5, 1)))
        var p = Uniforms(matrix: projection * rotationX * rotationY, imageAspect: aspect, viewAspect: viewAspect,
                         relief: camera.relief, opacity: min(1, max(0, opacity)), mode: mode.rawValue,
                         inverted: camera.inverted ? 1 : 0, columns: UInt32(columns), rows: UInt32(rows))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.045, green: 0.045, blue: 0.045, alpha: 1)
        if mode == .relief {
            if depthTarget?.width != target.width || depthTarget?.height != target.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: target.width, height: target.height, mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = .renderTarget
                depthTarget = device.makeTexture(descriptor: descriptor)
            }
            guard let depthTarget else { throw Self.failure() }
            pass.depthAttachment.texture = depthTarget; pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        }
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw Self.failure() }
        encoder.setRenderPipelineState(mode == .relief ? surface : flat)
        if mode == .relief { encoder.setDepthStencilState(depthState) }
        encoder.setVertexBytes(&p, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&p, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexTexture(inspection.field, index: 0)
        encoder.setFragmentTexture(inspection.field, index: 0)
        encoder.setFragmentTexture(photo, index: 1); encoder.setFragmentTexture(sourceColors, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mode == .relief ? columns * rows * 6 : 3)
        encoder.endEncoding()
        return commands
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void inspect_reduce(device const float *focus [[buffer(0)]], device float4 *state [[buffer(1)]],
                               constant uint4 &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        uint i = gid.x; if (i >= p.x) return;
        float4 s = p.z == 0 ? float4(-INFINITY, -INFINITY, -1, 0) : state[i];
        float f = focus[i];
        if (isfinite(f)) {
            if (f > s.x) { s.y = s.x; s.x = f; s.z = float(p.y); }
            else if (f > s.y) s.y = f;
        }
        state[i] = s;
    }
    kernel void inspect_crop(device const float4 *state [[buffer(0)]], constant uint4 &size [[buffer(1)]],
                             constant float4 &map [[buffer(2)]], texture2d<float, access::write> field [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (any(gid >= size.zw)) return;
        float2 point = (float2(gid) + 0.5 + map.xy) * map.z - 0.5;
        uint2 q = uint2(clamp(round(point), float2(0), float2(size.xy - 1)));
        float4 s = state[q.y * size.x + q.x];
        float confidence = isfinite(s.x) ? clamp((s.x - (isfinite(s.y) ? s.y : 0.0)) * 0.5, 0.0, 1.0)
                                                   * clamp(s.x - 1.0, 0.0, 1.0) : 0.0;
        // No clear focus evidence is missing geometry, never an invented reference-plane height.
        float position = s.x > 1.0 && s.z >= 0 ? s.z / map.w : -1.0;
        field.write(float4(position, confidence, 0, 1), gid);
    }
    struct Params {
        float4x4 matrix;
        float imageAspect, viewAspect, relief, opacity;
        uint mode, inverted, columns, rows;
    };
    struct Vertex { float4 position [[position]]; float2 uv; float valid; };
    constexpr sampler sampleLinear(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler sampleNearest(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 depthColor(float d) { return mix(float3(0.03, 0.20, 0.80), float3(1.0, 0.83, 0.08), clamp(d, 0.0, 1.0)); }
    vertex Vertex inspect_flat(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
        return {float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5), 1};
    }
    fragment float4 inspect_overlay(Vertex in [[stage_in]], constant Params &p [[buffer(0)]],
                                    texture2d<float> field [[texture(0)]], texture2d<float> photo [[texture(1)]],
                                    texture2d<float> sources [[texture(2)]]) {
        float2 uv = in.uv;
        float imageAspect = p.imageAspect / p.viewAspect;
        float2 fit = imageAspect > 1 ? float2(1, 1 / imageAspect) : float2(imageAspect, 1);
        uv = (uv - 0.5) / fit + 0.5;
        if (any(uv < 0) || any(uv > 1)) return float4(0.045, 0.045, 0.045, 1);
        float4 base = photo.sample(sampleLinear, uv);
        if (p.mode == 0) return base;
        float2 measured = field.sample(sampleNearest, uv).xy;
        if (p.mode == 1) return float4(mix(base.rgb, sources.sample(sampleNearest, uv).rgb, p.opacity), 1);
        float3 tint = p.mode == 2 ? depthColor(measured.x) : mix(float3(0.95, 0.15, 0.04), float3(0.08, 0.85, 0.45), measured.y);
        if (measured.x < 0) {
            float stripe = fmod(floor(in.position.x / 6) + floor(in.position.y / 6), 2.0);
            tint = mix(float3(0.15), float3(0.65), stripe);
        }
        return float4(mix(base.rgb, tint, p.opacity), 1);
    }
    float2 gridUV(uint2 q, constant Params &p) { return float2(q) / float2(p.columns, p.rows); }
    vertex Vertex inspect_surface(uint id [[vertex_id]], constant Params &p [[buffer(0)]], texture2d<float> field [[texture(0)]]) {
        uint cell = id / 6, corner = id % 6;
        uint2 origin = uint2(cell % p.columns, cell / p.columns);
        uint2 offsets[6] = {uint2(0,0), uint2(0,1), uint2(1,0), uint2(1,0), uint2(0,1), uint2(1,1)};
        float2 uv = gridUV(origin + offsets[corner], p);
        uint tri = corner < 3 ? 0 : 3;
        float a = field.sample(sampleNearest, gridUV(origin + offsets[tri], p)).x;
        float b = field.sample(sampleNearest, gridUV(origin + offsets[tri + 1], p)).x;
        float c = field.sample(sampleNearest, gridUV(origin + offsets[tri + 2], p)).x;
        float valid = min(a, min(b, c)) >= 0 && max(a, max(b, c)) - min(a, min(b, c)) <= 0.2 ? 1.0 : 0.0;
        float d = field.sample(sampleNearest, uv).x;
        if (p.inverted) d = 1 - d;
        float2 extent = p.imageAspect > 1 ? float2(1, 1 / p.imageAspect) : float2(p.imageAspect, 1);
        float3 pos = float3((uv.x * 2 - 1) * extent.x, (1 - uv.y * 2) * extent.y, (d - 0.5) * p.relief * 2);
        return {p.matrix * float4(pos, 1), uv, valid};
    }
    fragment float4 inspect_texture(Vertex in [[stage_in]], texture2d<float> field [[texture(0)]], texture2d<float> photo [[texture(1)]]) {
        if (in.valid < 0.99) discard_fragment();
        float confidence = field.sample(sampleNearest, in.uv).y;
        float3 color = photo.sample(sampleLinear, in.uv).rgb;
        // Dim ambiguous patches; leave holes where no frame supplied measurable focus.
        color = mix(float3(dot(color, float3(0.2126, 0.7152, 0.0722))) * 0.55, color, 0.35 + 0.65 * confidence);
        return float4(color, 1);
    }
    """
}
