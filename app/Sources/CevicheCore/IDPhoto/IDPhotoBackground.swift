import Foundation
import CoreImage
import Vision

/// A solid background in place of the photo's: what the user chose, kept on the layout.
public struct IDPhotoBackground: Equatable, Sendable {
    /// sRGB, 0–1.
    public var red: Double, green: Double, blue: Double
    public init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }

    /// The colour the spec asks for.
    public init(for spec: IDPhotoSpec) {
        switch spec.background {
        case .white, .whiteOrLight: self.init(red: 1, green: 1, blue: 1)
        case .offWhite: self.init(red: 0.96, green: 0.96, blue: 0.94)
        case .lightGrey: self.init(red: 0.86, green: 0.86, blue: 0.86)
        case .lightBlue: self.init(red: 0.78, green: 0.87, blue: 0.96)
        }
    }
    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue, colorSpace: IDPhotoRenderer.space)! }
}

/// The person's matte for replacing the background, and the composite that puts them on a solid colour.
public enum IDPhotoMatte {
    /// The person (hair, clothes and anything held) as a grey matte the size of `image`: Vision's foreground mask,
    /// refined by colour around its edge so hair keeps its strands. White is the person.
    public static func make(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let matte: CIImage
        if let observation = request.results?.first, !observation.allInstances.isEmpty {
            // Only the instance holding the face, so a passer-by or a chair behind isn't kept.
            let instances = try instance(around: observation, handler: handler, image: image) ?? observation.allInstances
            matte = CIImage(cvPixelBuffer: try observation.generateScaledMaskForImage(forInstances: instances, from: handler))
        } else {
            // Without a foreground, Vision's person segmentation, which always finds someone in a portrait.
            let person = VNGeneratePersonSegmentationRequest()
            person.qualityLevel = .accurate
            try handler.perform([person])
            guard let buffer = person.results?.first?.pixelBuffer else { throw EditorError.render }
            let raw = CIImage(cvPixelBuffer: buffer)
            matte = raw.transformed(by: CGAffineTransform(scaleX: size.width / raw.extent.width, y: size.height / raw.extent.height))
        }
        let photo = CIImage(cgImage: image)
        let alpha = refine(matte.cropped(to: photo.extent), photo: photo)
        let grey = alpha.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
        guard let cg = context.createCGImage(grey, from: photo.extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)) else { throw EditorError.render }
        return cg
    }

    /// Vision's mask is a smooth outline: it cuts off the tips of the hair, and where it does reach into it, its soft
    /// edge is half wall. Inside a band around that outline the matte is solved from colour instead: each pixel's
    /// place between the background's local colour and the person's (each spread in from where the mask is sure),
    /// as in known-colour matting. Where the two colours are too alike to tell apart, the mask stands.
    static func refine(_ mask: CIImage, photo: CIImage) -> CIImage {
        let extent = photo.extent, size = max(extent.width, extent.height)
        func spread(_ image: CIImage, by radius: Double, grow: Bool) -> CIImage {
            image.clampedToExtent().applyingFilter(grow ? "CIMorphologyMaximum" : "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        func blur(_ image: CIImage, _ radius: Double) -> CIImage {
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        let solid = mask.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
        // Sure person: the outline pulled in. Sure background: everything past it pushed out, far enough to take in
        // the hair the mask missed.
        let person = blur(spread(solid, by: max(2, size * 0.005), grow: false), 1)
        let background = blur(spread(solid, by: max(4, size * 0.012), grow: true), 1).applyingFilter("CIColorInvert")
        let radius = max(4, size * 0.015)
        // Normalised convolution: each colour spread across the band from where it is sure.
        func local(_ weight: CIImage) -> (CIImage, CIImage) {
            (blur(photo.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight]), radius), blur(weight, radius))
        }
        let (fg, fgWeight) = local(person), (bg, bgWeight) = local(background)
        // How much the background varies around each pixel: a plain wall resolves strands, a street doesn't.
        let squared = photo.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: photo])
        let bgSquares = blur(squared.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: background]), radius)
        return matting.apply(extent: extent, roiCallback: { _, r in r }, arguments: [photo, mask, person, background, fg, fgWeight, bg, bgWeight, bgSquares])!
    }

    private static let matting = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 idPhotoMatting(coreimage::sample_t image, coreimage::sample_t mask, coreimage::sample_t sureFG,
                                                      coreimage::sample_t sureBG, coreimage::sample_t fg, coreimage::sample_t fgWeight,
                                                      coreimage::sample_t bg, coreimage::sample_t bgWeight, coreimage::sample_t bgSquares) {
        float coarse = clamp(mask.r, 0.0, 1.0);
        if (sureFG.r > 0.99) return float4(1.0);
        if (sureBG.r > 0.99 || fgWeight.r < 0.001 || bgWeight.r < 0.001) return float4(float3(sureBG.r > 0.99 ? 0.0 : coarse), 1.0);
        float3 f = fg.rgb / fgWeight.r, b = bg.rgb / bgWeight.r, d = f - b;
        float contrast = dot(d, d);
        float projected = clamp(dot(image.rgb - b, d) / max(contrast, 1e-4), 0.0, 1.0);
        // Hair a lot darker than the wall resolves to the strand; alike colours, or a busy background that one
        // colour can't stand for, keep Vision's outline.
        float3 variance = max(bgSquares.rgb / bgWeight.r - b * b, 0.0);
        float spread = sqrt(max(variance.r, max(variance.g, variance.b)));
        float trust = smoothstep(0.01, 0.06, contrast) * (1.0 - smoothstep(0.03, 0.07, spread));
        float a = mix(coarse, projected, trust);
        // Sure regions fade in over a pixel so the band has no seam.
        a = max(a, sureFG.r) * (1.0 - sureBG.r);
        return float4(float3(a), 1.0);
    }
    """)[0]

    /// The instances that hold the largest face, when there are several.
    private static func instance(around observation: VNInstanceMaskObservation, handler: VNImageRequestHandler, image: CGImage) throws -> IndexSet? {
        guard observation.allInstances.count > 1 else { return nil }
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([faces])
        guard let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly); defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
        let x = Int(face.boundingBox.midX * Double(width)), y = Int((1 - face.boundingBox.midY) * Double(height))
        let label = Int(base[min(height - 1, max(0, y)) * row + min(width - 1, max(0, x))])
        return label == 0 ? nil : IndexSet(integer: label)
    }

    /// `image` on `color` through `matte` (both in the same space), with the old background's colour taken out of
    /// the edges: each edge pixel is the person's colour mixed with the background's, so the background, estimated
    /// by spreading its colour into the edge, is removed before the new one is mixed in. `radius` is in pixels of
    /// that space, a little more than the softest edge.
    static func composite(_ image: CIImage, matte: CIImage, color: CIColor, radius: Double) -> CIImage {
        let extent = image.extent
        let alpha = matte.applyingFilter("CIColorClamp").cropped(to: extent)
        let outside = alpha.applyingFilter("CIColorInvert")
        func blur(_ input: CIImage) -> CIImage {
            input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        // Normalised convolution: the background's colour, spread into where the person covers it.
        let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside])
        let background = blur(weighted), weight = blur(outside)
        return kernel.apply(extent: extent, roiCallback: { _, r in r }, arguments: [image, alpha, background, weight, CIImage(color: color).cropped(to: extent)])!
    }

    private static let kernel = try! CIKernel.kernels(withMetalString: """
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" [[ stitchable ]] float4 idPhotoBackground(coreimage::sample_t image, coreimage::sample_t matte, coreimage::sample_t spread,
                                                         coreimage::sample_t weight, coreimage::sample_t fill) {
        float a = clamp(matte.r, 0.0, 1.0);
        float3 background = weight.r > 0.001 ? spread.rgb / weight.r : image.rgb;
        // The person's own colour at the edge; where the matte is faint it is mostly guesswork, so it is weighted by a.
        float3 person = clamp((image.rgb - (1.0 - a) * background) / max(a, 0.08), 0.0, 1.0);
        return float4(mix(fill.rgb, person, a), 1.0);
    }
    """)[0]
}
