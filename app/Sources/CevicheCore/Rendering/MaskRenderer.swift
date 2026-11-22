import Foundation
import CoreImage
import CoreGraphics

/// All masks are evaluated before output rotation, in source coordinates.
final class MaskRenderer {
    private let context: CIContext
    init(context: CIContext = CIContext()) { self.context = context }
    private var renderers: [UUID: PixelRenderer] = [:]
    /// One matte per image size a mask was last used at, so previews and source-resolution tiles can alternate
    /// without recomputing each other's refinement.
    private var cache: [UUID: [(PhotoMask, CGRect, Bool, CIImage)]] = [:]
    func prune(_ masks: [PhotoMask]) { let ids = Set(masks.map(\.id)); cache = cache.filter { ids.contains($0.key) }; renderers = renderers.filter { ids.contains($0.key) } }
    func image(for mask: PhotoMask, source: CIImage, hdr: Bool = false) throws -> CIImage {
        let extent = source.extent
        var geometry = mask; geometry.adjustments = LocalAdjustments(); geometry.name = ""; geometry.enabled = true; geometry.cutsOutBackground = false
        let cacheable = mask.kind != .color && !mask.components.contains { $0.selection.kind == .color }
        if cacheable, let entry = cache[mask.id]?.first(where: { $0.0 == geometry && $0.1 == extent && $0.2 == hdr }) { return entry.3 }
        let selectionSource = hdr ? HDRRenderer.normalized(source) : source
        let base = mask.selection
        var result = try selectionImage(base, source: selectionSource)
        for component in mask.components where component.enabled {
            let part = try selectionImage(component.selection, source: selectionSource)
            switch component.operation {
            case .add: result = result.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: part])
            case .subtract: result = result.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: part.applyingFilter("CIColorInvert")])
            case .intersect: result = result.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: part])
            }
        }
        if mask.inverted { result = result.applyingFilter("CIColorInvert") }
        if mask.opacity < 1 { result = result.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: mask.opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: mask.opacity, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: mask.opacity, w: 0)]) }
        result = result.cropped(to: extent)
        if cacheable {
            var entries = (cache[mask.id] ?? []).filter { $0.0 == geometry && ($0.1 != extent || $0.2 != hdr) }
            entries.append((geometry, extent, hdr, result)); cache[mask.id] = Array(entries.suffix(3))
        }
        return result
    }
    private func selectionImage(_ mask: MaskSelection, source: CIImage) throws -> CIImage {
        let extent = source.extent
        let black = CIImage(color: .black).cropped(to: extent)
        var result = black
        let start = CGPoint(x: mask.start.x * extent.width, y: mask.start.y * extent.height)
        let end = CGPoint(x: mask.end.x * extent.width, y: mask.end.y * extent.height)
        switch mask.kind {
        case .subject, .background, .sky, .object, .scene, .depth, .people:
            if let data = mask.raster {
                guard let raster = MaskRaster.image(from: data), raster.extent.width > 0 else { throw EditorError.invalidDocument(L10n.tr("The saved selection mask is damaged.")) }
                if let refinement = mask.refinement { result = refinement.apply(raster, guide: source) }
                else { result = raster.transformed(by: CGAffineTransform(scaleX: extent.width / raster.extent.width, y: extent.height / raster.extent.height)).cropped(to: extent) }
            }
        case .brush: break
        case .linear:
            let target = hypot(end.x - start.x, end.y - start.y) < 1 ? CGPoint(x: start.x, y: start.y + 1) : end
            result = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(cgPoint: start), "inputPoint1": CIVector(cgPoint: target), "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: extent)
        case .radial:
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let rx = max(1, abs(end.x - start.x) / 2), ry = max(1, abs(end.y - start.y) / 2)
            // A unit gradient scaled to the half-extents, turned by the rotation, then placed at the center.
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: (mask.rotation ?? 0) * .pi / 180).scaledBy(x: rx, y: ry)
            result = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputRadius0": max(0, 1 - mask.feather * 2), "inputRadius1": 1, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!
                .transformed(by: transform).cropped(to: extent)
        case .color:
            let n = 32
            var values = [Float](); values.reserveCapacity(n * n * n * 4)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let distance = sqrt(pow(Double(r) / Double(n - 1) - mask.color[0], 2) + pow(Double(g) / Double(n - 1) - mask.color[1], 2) + pow(Double(b) / Double(n - 1) - mask.color[2], 2)) / sqrt(3)
                let t = min(1, max(0, (distance - mask.tolerance * 0.5) / max(0.001, mask.tolerance * 0.5)))
                let v = Float(1 - t * t * (3 - 2 * t)); values += [v, v, v, 1]
            } } }
            result = source.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": n, "inputCubeData": values.withUnsafeBytes { Data($0) }, "inputColorSpace": RGBProfile.sRGB.space])
        }
        if mask.kind == .depth { result = Self.depthBand(result, range: mask.depthRange ?? [0.5, 1], softness: mask.tolerance) }
        if mask.kind != .radial, mask.feather > 0 {
            result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": mask.feather * min(extent.width, extent.height)]).cropped(to: extent)
        }
        // Brush refinements apply to any mask, including a saved machine-generated selection.
        if !mask.strokes.isEmpty { result = try refine(mask.strokes, base: result, extent: extent) }
        if mask.inverted { result = result.applyingFilter("CIColorInvert") }
        result = result.cropped(to: extent)
        return result
    }
    /// Keeps depths inside [far, near] with smooth shoulders `softness` wide; the raster stores depth in red.
    static func depthBand(_ depth: CIImage, range: [Double], softness: Double) -> CIImage {
        let n = 64, far = range[0], near = range[1], width = max(0.002, softness * 0.5)
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        var values = [Float](); values.reserveCapacity(n * n * n * 4)
        for _ in 0..<n { for _ in 0..<n { for r in 0..<n {
            let d = Double(r) / Double(n - 1)
            let rising = far <= 0 ? 1 : smooth((d - (far - width)) / width), falling = near >= 1 ? 1 : smooth(((near + width) - d) / width)
            let v = Float(rising * falling); values += [v, v, v, 1]
        } } }
        return depth.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": n, "inputCubeData": values.withUnsafeBytes { Data($0) }])
    }
    private func refine(_ strokes: [MaskStroke], base: CIImage, extent: CGRect) throws -> CIImage {
        let width = Int(extent.width.rounded()), height = Int(extent.height.rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let buffer = ctx.data else { throw EditorError.render }
        // A single bounded raster holds all brush refinements, avoiding one full-size texture per stroke.
        context.render(base, toBitmap: buffer, rowBytes: ctx.bytesPerRow, bounds: extent, format: .L8, colorSpace: nil)
        for stroke in strokes {
            let radius = max(1, stroke.radius * min(extent.width, extent.height))
            let locations: [CGFloat] = [0, CGFloat(min(0.999, max(0.001, 1 - stroke.softness))), 1]
            let components: [CGFloat] = stroke.erase ? [0, 1, 0, 1, 1, 1] : [1, 1, 1, 1, 0, 1]
            guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components, locations: locations, count: 3) else { throw EditorError.render }
            ctx.setBlendMode(stroke.erase ? .darken : .lighten)
            var previous: CGPoint?
            for p in stroke.points {
                let point = CGPoint(x: p.x * extent.width, y: p.y * extent.height)
                let from = previous ?? point
                let steps = max(1, Int(ceil(hypot(point.x - from.x, point.y - from.y) / max(1, radius * 0.2))))
                for i in 1...steps {
                    let t = Double(i) / Double(steps), center = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                    ctx.saveGState(); ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)); ctx.clip()
                    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                    ctx.restoreGState()
                }
                previous = point
            }
        }
        guard let cg = ctx.makeImage() else { throw EditorError.render }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }
    func apply(_ masks: [PhotoMask], to source: CIImage, scale: Double = 1, hdr: Bool = false) throws -> CIImage {
        var image = try applyLayers(masks[...], to: source, scale: scale, hdr: hdr)
        for mask in masks where mask.enabled && mask.cutsOutBackground {
            let matte = try self.image(for: mask, source: source, hdr: hdr)
            image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent), kCIInputMaskImageKey: matte])
        }
        return image
    }
    func defringeInput(_ id: UUID, masks: [PhotoMask], source: CIImage, scale: Double, hdr: Bool) throws -> CIImage? {
        guard let index = masks.firstIndex(where: { $0.id == id }) else { return nil }
        let image = try applyLayers(masks[..<index], to: source, scale: scale, hdr: hdr)
        return renderer(for: id).defringeInput(masks[index].adjustments, from: image, local: true, hdr: hdr)
    }
    private func renderer(for id: UUID) -> PixelRenderer {
        if let renderer = renderers[id] { return renderer }
        let renderer = PixelRenderer()
        renderers[id] = renderer
        return renderer
    }
    private func applyLayers(_ masks: ArraySlice<PhotoMask>, to source: CIImage, scale: Double, hdr: Bool) throws -> CIImage {
        var image = source
        // Color-range selections always use the same global development, independent of other masks.
        for mask in masks where mask.enabled {
            let matte = try self.image(for: mask, source: source, hdr: hdr)
            let edited = renderer(for: mask.id).apply(mask.renderedAdjustments, to: image, scale: scale, local: true, hdr: hdr)
            image = edited.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: matte])
        }
        return image
    }
}
