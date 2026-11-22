import Foundation
import CoreImage
import ImageIO

public struct MCPPreview: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let fullWidth: Int
    public let fullHeight: Int
    public let region: [Double]
    public let scale: Double
    public let statistics: MCPStatistics
}

/// What an MCP preview shows: the developed photograph, one mask's matte (white = full effect) in the
/// same developed coordinates, or the photograph with that matte tinted red.
public enum MCPPreviewContent: Sendable {
    case image
    case matte(PhotoMask)
    case overlay(PhotoMask)
}

extension RawRenderer {
    /// Crop developed source-resolution pixels, never magnify the interactive preview.
    public func mcpPreview(_ adjustments: Adjustments, scale: Double = 1, maxEdge: Int = 1600, scope: [Double] = [0, 0, 1, 1], content: MCPPreviewContent = .image) throws -> MCPPreview {
        guard scale.isFinite, scale > 0, scale <= 1, (64...4096).contains(maxEdge), scope.count == 4,
              scope.allSatisfy({ $0.isFinite && (0...1).contains($0) }), scope[2] > 0, scope[3] > 0,
              scope[0] + scope[2] <= 1, scope[1] + scope[3] <= 1 else {
            throw MCPFailure("invalid_scope", "Scope must be inside the image with positive area, and scale must be in (0,1].")
        }
        try Task.checkCancellation()
        var image: CIImage
        switch content {
        case .image: image = try pipeline(adjustments, maxDimension: nil)
        case .matte(let mask): image = try developedMatte(mask, adjustments: adjustments)
        case .overlay(let mask):
            let matte = try developedMatte(mask, adjustments: adjustments)
            let photograph = try pipeline(adjustments, maxDimension: nil)
            let tint = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.1, alpha: 1)).cropped(to: photograph.extent)
            let marked = tint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: photograph, kCIInputMaskImageKey: matte])
            image = marked.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: photograph, kCIInputTimeKey: 0.55])
        }
        let full = image.extent
        let x = floor(scope[0] * full.width), top = floor(scope[1] * full.height)
        let width = max(1, min(full.width - x, ceil(scope[2] * full.width)))
        let height = max(1, min(full.height - top, ceil(scope[3] * full.height)))
        let rect = CGRect(x: full.minX + x, y: full.maxY - top - height, width: width, height: height)
        image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let factor = min(1, scale, Double(maxEdge) / max(width, height))
        let w = max(1, Int(floor(width * factor))), h = max(1, Int(floor(height * factor)))
        if factor < 1 {
            image = image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if adjustments.hdr.enabled, case .image = content { image = HDRRenderer.output(image, settings: adjustments.hdr, context: context, sdr: true) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: space) else { throw EditorError.render }
        guard let statistics = MCPStatistics(image: cg) else { throw EditorError.render }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw EditorError.render }
        CGImageDestinationAddImage(encoder, cg, nil)
        guard CGImageDestinationFinalize(encoder) else { throw EditorError.render }
        return MCPPreview(png: data as Data, width: w, height: h, fullWidth: Int(full.width), fullHeight: Int(full.height), region: [x, top, width, height], scale: factor, statistics: statistics)
    }
    /// A mask's selection evaluated on the global development, then moved through crop and rotation so it
    /// lines up with the developed photograph that previews and scopes describe.
    private func developedMatte(_ mask: PhotoMask, adjustments: Adjustments) throws -> CIImage {
        var global = adjustments; global.masks = []; global.quarterTurns = 0; global.geometry = GeometryAdjustments()
        let source = try pipeline(global, maxDimension: nil)
        var matte = try maskRenderer.image(for: mask, source: source, hdr: adjustments.hdr.enabled)
        if adjustments.geometry != GeometryAdjustments() || adjustments.quarterTurns != 0 {
            matte = try GeometryPlan(size: matte.extent.size, settings: adjustments.geometry, quarterTurns: adjustments.quarterTurns).apply(to: matte)
        }
        return matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
    }
}
