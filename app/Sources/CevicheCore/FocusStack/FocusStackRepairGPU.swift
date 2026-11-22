import Foundation
import Metal
import simd

/// A local source repair, separate from fusion weights. Only the painted halo side of an observed edge is replaced;
/// the opposite side keeps the stack's pixels. All dense measurements and composition run in Metal, on demand.
final class FocusStackRepairGPU {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private struct Parameters {
        var width: UInt32, height: UInt32, count: UInt32, unused: UInt32 = 0
        var scale: Float, side: Float = 0
        var x0: UInt32 = 0, y0: UInt32 = 0, regionWidth: UInt32 = 0, regionHeight: UInt32 = 0
    }
    private struct Edge {
        var geometry: SIMD4<Float>
        var evidence: SIMD4<Float>
    }
    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Self.failure() }
        self.queue = queue
        let options = MTLCompileOptions(); options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.shader, options: options)
        for name in ["repair_hints", "repair_score", "repair_edges", "repair_stabilize", "repair_compose"] {
            pipelines[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
    }
    private static func failure() -> Error { PanoramaError.message(L10n.tr("The GPU couldn’t stack these photos.")) }
    private func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        guard !values.isEmpty else { throw Self.failure() }
        let result = values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let result else { throw Self.failure() }; return result
    }
    private func run(_ name: String, count: Int, buffers: [MTLBuffer], parameters: Parameters) throws {
        if Task.isCancelled { throw CancellationError() }
        guard let commands = queue.makeCommandBuffer(), let e = commands.makeComputeCommandEncoder() else { throw Self.failure() }
        let pipeline = pipelines[name]!; e.setComputePipelineState(pipeline)
        for (i,b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i) }
        var p = parameters; e.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: buffers.count)
        e.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        e.endEncoding(); commands.commit(); commands.waitUntilCompleted()
        if let error = commands.error { throw error }
        if Task.isCancelled { throw CancellationError() }
    }
    func hints(_ raster: PanoramaRaster, dabs: [SIMD4<Float>]) throws -> [SIMD4<Float>] {
        let out = try buffer([SIMD4<Float>](repeating: .zero, count: dabs.count))
        try run("repair_hints", count: dabs.count, buffers: [try buffer(raster.rgba), try buffer(dabs), out],
                parameters: Parameters(width: UInt32(raster.width), height: UInt32(raster.height), count: UInt32(dabs.count), scale: 1))
        return Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: dabs.count))
    }
    func score(proxy: [Float], width: Int, height: Int, dabs: [SIMD4<Float>], hints: [SIMD4<Float>]) throws -> Float {
        let out = try buffer([Float](repeating: 0, count: dabs.count))
        try run("repair_score", count: dabs.count, buffers: [try buffer(proxy), try buffer(dabs), try buffer(hints), out],
                parameters: Parameters(width: UInt32(width), height: UInt32(height), count: UInt32(dabs.count), scale: 1))
        let values = UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: dabs.count)
        return values.reduce(0, +) / Float(dabs.count)
    }
    func apply(_ raster: PanoramaRaster, source: MTLBuffer, dabs: [SIMD4<Float>], hints: [SIMD4<Float>], scale: Float) throws -> PanoramaRaster {
        let base = try buffer(raster.rgba), discs = try buffer(dabs)
        let edges = try buffer([Edge](repeating: Edge(geometry: .zero, evidence: .zero), count: dabs.count))
        var p = Parameters(width: UInt32(raster.width), height: UInt32(raster.height), count: UInt32(dabs.count), scale: scale)
        try run("repair_edges", count: dabs.count, buffers: [base, source, discs, try buffer(hints), edges], parameters: p)
        let stable = try buffer([Edge](repeating: Edge(geometry: .zero, evidence: .zero), count: dabs.count))
        try run("repair_stabilize", count: dabs.count, buffers: [discs, edges, stable], parameters: p)
        let measured = UnsafeBufferPointer(start: stable.contents().assumingMemoryBound(to: Edge.self), count: dabs.count)
        let minus = measured.reduce(Float(0)) { $0 + max(0, $1.evidence.x) }
        let plus = measured.reduce(Float(0)) { $0 + max(0, $1.evidence.y) }
        // A repair must have visible spill on one side. Flat/tied evidence leaves the image alone.
        guard max(minus, plus) > Float(dabs.count) * 0.001, abs(minus - plus) > max(minus, plus) * 0.15 else { return raster }
        p.side = minus > plus ? -1 : 1
        let x0 = max(0, Int(floor(dabs.map { $0.x-$0.z }.min()!))), y0 = max(0, Int(floor(dabs.map { $0.y-$0.z }.min()!)))
        let x1 = min(raster.width, Int(ceil(dabs.map { $0.x+$0.z }.max()!))+1), y1 = min(raster.height, Int(ceil(dabs.map { $0.y+$0.z }.max()!))+1)
        guard x1 > x0, y1 > y0 else { return raster }
        p.x0 = UInt32(x0); p.y0 = UInt32(y0); p.regionWidth = UInt32(x1-x0); p.regionHeight = UInt32(y1-y0)
        let out = try buffer(raster.rgba)
        try run("repair_compose", count: (x1-x0) * (y1-y0), buffers: [base, source, discs, stable, out], parameters: p)
        return PanoramaRaster(width: raster.width, height: raster.height,
                              rgba: Array(UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: raster.rgba.count)))
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct P { uint w,h,count,unused; float scale,side; uint x0,y0,regionWidth,regionHeight; };
    struct Edge { float4 geometry; float4 evidence; };
    float lum(float4 c) { return sqrt(max(0.f,dot(c.rgb,float3(.2126f,.7152f,.0722f)))+1e-6f); }
    uint at(int2 q, constant P &p) { q=clamp(q,int2(0),int2(p.w-1,p.h-1)); return uint(q.y)*p.w+uint(q.x); }
    float pixel(device const float4 *a,float2 q,constant P &p) { return lum(a[at(int2(round(q)),p)]); }
    float smooth(device const float4 *a,float2 q,constant P &p) {
        float v=0; for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) v+=pixel(a,q+float2(x,y),p); return v/9;
    }
    float2 gradient(device const float4 *a,float2 q,constant P &p) {
        return .5f*float2(smooth(a,q+float2(1,0),p)-smooth(a,q-float2(1,0),p),smooth(a,q+float2(0,1),p)-smooth(a,q-float2(0,1),p));
    }
    float value(device const float *a,float2 q,constant P &p) {
        float v=0;for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++)v+=a[at(int2(round(q))+int2(x,y),p)];return v/9;
    }
    kernel void repair_hints(device const float4 *base [[buffer(0)]],device const float4 *dabs [[buffer(1)]],device float4 *out [[buffer(2)]],constant P &p [[buffer(3)]],uint i [[thread_position_in_grid]]) {
        if(i>=p.count)return;float4 d=dabs[i];float best=0;float2 n=0;float xx=0,yy=0,xy=0;
        float r=min(d.z*.8f,48.f),step=max(1.f,r/12.f);
        for(float y=-r;y<=r;y+=step)for(float x=-r;x<=r;x+=step){
            if(x*x+y*y>r*r)continue;float2 g=gradient(base,d.xy+float2(x,y),p);float s=length(g);
            xx+=g.x*g.x;yy+=g.y*g.y;xy+=g.x*g.y;
            if(s>best){best=s;n=g/max(s,1e-8f);}
        }
        float angle=.5f*atan2(2*xy,xx-yy);float2 axis=float2(cos(angle),sin(angle));
        if(dot(axis,n)<0)axis=-axis;
        float coherence=length(float2(xx-yy,2*xy))/max(xx+yy,1e-8f);
        out[i]=float4(axis,coherence>.35f?best:0,0);
    }
    kernel void repair_score(device const float *proxy [[buffer(0)]],device const float4 *dabs [[buffer(1)]],device const float4 *hints [[buffer(2)]],device float *out [[buffer(3)]],constant P &p [[buffer(4)]],uint i [[thread_position_in_grid]]) {
        if(i>=p.count)return;float2 n=hints[i].xy;float2 t=float2(-n.y,n.x);float r=min(dabs[i].z*.8f,48.f),best=0;
        if(hints[i].z<.003f){out[i]=0;return;}
        for(float k=-r;k<=r;k+=1){float g=0;
            for(int j=-2;j<=2;j++){float2 q=dabs[i].xy+n*k+t*float(j);g+=(value(proxy,q+n,p)-value(proxy,q-n,p))*.1f;}
            best=max(best,g);
        }out[i]=best;
    }
    float edgeStrength(device const float4 *a,float2 q,float2 n,constant P &p){
        float2 t=float2(-n.y,n.x);float g=0;
        for(int j=-2;j<=2;j++)g+=(smooth(a,q+n+t*float(j),p)-smooth(a,q-n+t*float(j),p))*.1f;
        return g;
    }
    kernel void repair_edges(device const float4 *base [[buffer(0)]],device const float4 *src [[buffer(1)]],device const float4 *dabs [[buffer(2)]],device const float4 *hints [[buffer(3)]],device Edge *out [[buffer(4)]],constant P &p [[buffer(5)]],uint i [[thread_position_in_grid]]) {
        if(i>=p.count)return;float4 d=dabs[i];float2 n=hints[i].xy;float r=min(d.z*.8f,48.f*p.scale),best=0,peak=0;
        for(float k=-r;k<=r;k+=1){float g=edgeStrength(src,d.xy+n*k,n,p);if(g>best){best=g;peak=k;}}
        float a=edgeStrength(src,d.xy+n*(peak-1),n,p),c=edgeStrength(src,d.xy+n*(peak+1),n,p);
        float den=a-2*best+c;if(abs(den)>1e-7f)peak+=clamp(.5f*(a-c)/den,-.5f,.5f);
        float2 q=d.xy+n*peak;
        float minus=0,plus=0;
        for(int j=2;j<=8;j++){float k=float(j)*p.scale;minus+=pixel(base,q-n*k,p)-pixel(src,q-n*k,p);plus+=pixel(base,q+n*k,p)-pixel(src,q+n*k,p);}
        out[i].geometry=float4(q,n);out[i].evidence=float4(minus/7,plus/7,best,0);
    }
    kernel void repair_stabilize(device const float4 *dabs [[buffer(0)]],device const Edge *edges [[buffer(1)]],device Edge *out [[buffer(2)]],constant P &p [[buffer(3)]],uint i [[thread_position_in_grid]]) {
        if(i>=p.count)return;float2 n=edges[i].geometry.zw;float offsets[7];
        for(int j=-3;j<=3;j++) {uint k=uint(clamp(int(i)+j,0,int(p.count)-1));offsets[j+3]=dot(edges[k].geometry.xy-dabs[i].xy,n);}
        for(int a=1;a<7;a++){float v=offsets[a];int b=a-1;while(b>=0 && offsets[b]>v){offsets[b+1]=offsets[b];b--;}offsets[b+1]=v;}
        out[i]=edges[i];out[i].geometry.xy=dabs[i].xy+n*offsets[3];
    }
    kernel void repair_compose(device const float4 *base [[buffer(0)]],device const float4 *src [[buffer(1)]],device const float4 *dabs [[buffer(2)]],device const Edge *edges [[buffer(3)]],device float4 *out [[buffer(4)]],constant P &p [[buffer(5)]],uint index [[thread_position_in_grid]]) {
        if(index>=p.regionWidth*p.regionHeight)return;uint2 xy=uint2(index%p.regionWidth+p.x0,index/p.regionWidth+p.y0);uint k=xy.y*p.w+xy.x;float2 q=float2(xy);float nearest=1;uint chosen=0;float fraction=0;
        for(uint i=0;i<p.count;i++){
            uint j=min(i+1,p.count-1);float2 v=dabs[j].xy-dabs[i].xy;
            float t=clamp(dot(q-dabs[i].xy,v)/max(dot(v,v),1e-6f),0.f,1.f);
            float4 d=mix(dabs[i],dabs[j],t);float r=max(d.z,1.f);float2 delta=q-d.xy;float distance=dot(delta,delta)/(r*r);
            if(distance<nearest){nearest=distance;chosen=i;fraction=t;}
        }
        uint next=min(chosen+1,p.count-1);
        if(nearest>=1 || src[k].a<.99f || mix(edges[chosen].evidence.z,edges[next].evidence.z,fraction)<.003f/max(1.f,p.scale)){out[k]=base[k];return;}
        float4 e=mix(edges[chosen].geometry,edges[next].geometry,fraction);float signedDistance=dot(q-e.xy,normalize(e.zw))*p.side;
        // A subpixel transition at the observed contour, and a soft outer brush rim. The opposite side is protected.
        float mask=smoothstep(-.4f,.4f,signedDistance)*(1-smoothstep(.65f,1.f,sqrt(nearest)));
        out[k]=mask>0?mix(base[k],src[k],mask):base[k];
    }
    """#
}
