import CoreImage

/// Additional pixel operators shared by global and masked development.
final class ExtendedRenderer {
    private var pointKey: [PointColor] = []
    private var pointData: Data?
    func pointColors(_ image: CIImage, settings: [PointColor]) -> CIImage {
        guard settings.contains(where: { !$0.isIdentity }) else { return image }
        if pointData == nil || pointKey != settings {
            pointKey = settings
            pointData = FilmMath.cube { rgb in settings.reduce(rgb) { $1.transform($0) } }
        }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": 64, "inputCubeData": pointData!, "inputColorSpace": RGBProfile.sRGB.space])
    }
    private static let defringeKernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 defringePixel(coreimage::sample_t s, coreimage::sample_t high, coreimage::sample_t low, float4 purple, float4 green) {
        float3 c=s.rgb; float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo;
        if(d<0.00001) return s;
        float h=(hi==c.r ? (c.g-c.b)/d : hi==c.g ? 2.0+(c.b-c.r)/d : 4.0+(c.r-c.g)/d)*60.0;
        if(h<0.0) h+=360.0;
        float p=(h-240.0)/1.2, g=(h-60.0)/1.2;
        float pw=smoothstep(purple.y-5.0,purple.y,p)*(1.0-smoothstep(purple.z,purple.z+5.0,p));
        float gw=smoothstep(green.y-5.0,green.y,g)*(1.0-smoothstep(green.z,green.z+5.0,g));
        // Near contrast: how far the light around this pixel spreads, in perceptual light. A fringe sits beside a bright
        // edge, so the whole rim of a soft halo counts, while the inside of a large colored area does not.
        float3 spread=high.rgb-low.rgb;
        float near=smoothstep(0.06,0.2,max(spread.r,max(spread.g,spread.b)));
        float strength=clamp(max(purple.x*pw,green.x*gw)*near*2.0,0.0,1.0);
        float y=dot(c,float3(0.2126,0.7152,0.0722));
        return float4(mix(c,float3(y),strength),s.a);
    }
    """)[0]
    /// Fringe reach in source pixels. `scale` is output pixels per source pixel, so the preview and the export cover the
    /// same rim; measured in output pixels instead, a 2200 px preview removed far more than the full-size export.
    static let defringeReach = 6.0
    static func defringe(_ image: CIImage, settings: Defringe, scale: Double) -> CIImage {
        let purpleAmount = settings.purpleAmount
        guard purpleAmount > 0 || settings.greenAmount > 0 else { return image }
        let radius = max(1, defringeReach * scale)
        let perceptual = image.clampedToExtent().applyingFilter("CILinearToSRGBToneCurve")
        let high = perceptual.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius]).cropped(to: image.extent)
        let low = perceptual.applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius]).cropped(to: image.extent)
        return defringeKernel.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [image, high, low, CIVector(x: purpleAmount / 20, y: settings.purpleLow, z: settings.purpleHigh, w: 0), CIVector(x: settings.greenAmount / 20, y: settings.greenLow, z: settings.greenHigh, w: 0)])!
    }
    static func sampleDefringe(_ image: CIImage, at point: MaskPoint, band: Defringe.Band, context: CIContext) -> ClosedRange<Double>? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, point.x.isFinite, point.y.isFinite else { return nil }
        let x = min(extent.width - 1, max(0, floor(point.x * extent.width)))
        let y = min(extent.height - 1, max(0, floor(point.y * extent.height)))
        let center = CGPoint(x: extent.minX + x, y: extent.minY + y)
        // A click at fit-to-window zoom lands a few source pixels from the rim, so look around it; nearer pixels still win.
        let bounds = CGRect(x: center.x - 6, y: center.y - 6, width: 13, height: 13).intersection(extent)
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds,
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        // Prefer chromatic pixels near the click so a neutral core and sky noise do not average into the rim hue.
        let samples: [(hue: Double, score: Double)] = (0..<(width * height)).compactMap { index in
            let i = index * 4
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            let high = max(r, g, b), chroma = high - min(r, g, b)
            guard pixels[i + 3] > 0.01, chroma.isFinite, chroma >= max(0.0001, high * 0.06) else { return nil }
            let sector = high == r ? (g - b) / chroma : high == g ? 2 + (b - r) / chroma : 4 + (r - g) / chroma
            let degrees = (sector < 0 ? sector + 6 : sector) * 60
            guard let hue = band.sliderHue(degrees) else { return nil }
            let dx = bounds.minX + Double(index % width) - center.x
            let dy = bounds.maxY - 1 - Double(index / width) - center.y
            return (hue, chroma / (1 + dx * dx + dy * dy))
        }
        guard let anchor = samples.max(by: { $0.score < $1.score }) else { return nil }
        let hues = samples.compactMap { abs($0.hue - anchor.hue) <= 20 && $0.score >= anchor.score * 0.125 ? $0.hue : nil }
        return max(0, floor((hues.min() ?? anchor.hue) - 8))...min(100, ceil((hues.max() ?? anchor.hue) + 8))
    }
    private static let vignetteKernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 postCropVignette(coreimage::sample_t s, float4 rect, float4 settings, float roundness, coreimage::destination dest) {
        float2 p=abs((dest.coord()-rect.xy)/rect.zw*2.0-1.0);
        float ellipse=length(p)/sqrt(2.0), box=max(p.x,p.y);
        float circle=length((dest.coord()-rect.xy-rect.zw*0.5)/(min(rect.z,rect.w)*0.5))/sqrt(2.0);
        float distance=roundness>=0.0 ? mix(ellipse,circle,roundness) : mix(ellipse,box,-roundness);
        float inner=settings.y*0.85, outer=inner+max(0.001,settings.z*(1.0-inner));
        float coverage=smoothstep(inner,outer,distance);
        float y=dot(s.rgb,float3(0.2126,0.7152,0.0722));
        float protect=settings.x<0.0 ? 1.0-settings.w*smoothstep(0.5,1.0,y) : 1.0;
        float3 c=s.rgb*exp2(settings.x*coverage*protect*2.0);
        return float4(c,s.a);
    }
    """)[0]
    static func vignette(_ image: CIImage, settings: PostCropVignette) -> CIImage {
        guard settings.amount != 0 else { return image }
        let r = image.extent
        return vignetteKernel.apply(extent: r, roiCallback: { _, r in r }, arguments: [image, CIVector(x: r.minX, y: r.minY, z: r.width, w: r.height), CIVector(x: settings.amount / 100, y: settings.midpoint / 100, z: settings.feather / 100, w: settings.highlights / 100), settings.roundness / 100])!
    }
}
