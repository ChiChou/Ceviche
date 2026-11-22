import CoreGraphics
import CoreML
import Foundation
import Vision

/// How open each eye is, from the face mesh's eyelid points: the gap between the lids over the eye's width, averaged
/// over three places along the eye. Vision's 76 landmarks draw the eye as a coarse outline whose height reads a laughing
/// squint as a blink; the mesh's lids follow the lashes. Nil without the model or when the mesh doesn't see a face.
public enum FaceMeshEyes {
    /// Each eye's corners, then upper and lower lid points paired across the eye (MediaPipe's face mesh numbering).
    private static let eyes: [(corners: (Int, Int), lids: [(Int, Int)])] = [
        ((33, 133), [(160, 144), (159, 145), (158, 153)]),
        ((362, 263), [(385, 380), (386, 374), (387, 373)]),
    ]

    /// Open is about 0.25–0.35, a blink under about 0.1; a laughing squint stays near 0.15.
    public static func openness(in image: CGImage, face: CGRect) -> (left: Double, right: Double)? {
        guard let points = points(in: image, face: face) else { return nil }
        let values = eyes.map { eye -> Double in
            let width = distance(points[eye.corners.0], points[eye.corners.1])
            guard width > 0 else { return 0 }
            return eye.lids.map { distance(points[$0.0], points[$0.1]) }.reduce(0, +) / Double(eye.lids.count) / width
        }
        // The mesh's first eye is the person's right, on the viewer's left.
        return (left: values[1], right: values[0])
    }

    /// The mesh's 478 points in `image`'s pixels, top-left origin, for the face boxed at `face` (pixels, top-left origin):
    /// a square crop with a quarter of the face's size around it, as the model was trained.
    static func points(in image: CGImage, face: CGRect) -> [CGPoint]? {
        guard BundledModel.faceMesh.isAvailable, let model = try? BundledModelCache.shared.visionModel(.faceMesh) else { return nil }
        let side = max(face.width, face.height) * 1.5
        let crop = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
        let inside = crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard inside.width >= 8, inside.height >= 8, let piece = image.cropping(to: inside) else { return nil }
        // Outside the photo the crop is black, so the face keeps its place and scale in the model's input.
        let n = 256
        guard let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: n, height: n))
        context.interpolationQuality = .high
        let k = Double(n) / side
        context.draw(piece, in: CGRect(x: (inside.minX - crop.minX) * k, y: (crop.maxY - inside.maxY) * k, width: inside.width * k, height: inside.height * k))
        guard let input = context.makeImage() else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        guard (try? VNImageRequestHandler(cgImage: input, options: [:]).perform([request])) != nil else { return nil }
        let outputs = (request.results as? [VNCoreMLFeatureValueObservation]) ?? []
        guard let points = outputs.first(where: { $0.featureName == "landmarks" })?.featureValue.multiArrayValue, points.count == 478 * 3 else { return nil }
        if let score = outputs.first(where: { $0.featureName == "score" })?.featureValue.multiArrayValue, score.count > 0, score[0].doubleValue < 0 { return nil }
        let s = points.strides.map(\.intValue)
        return (0..<478).map { i in
            // x, y in the 256 crop with rows top down.
            CGPoint(x: crop.minX + points[i * s[0]].doubleValue / Double(n) * side, y: crop.minY + points[i * s[0] + s[1]].doubleValue / Double(n) * side)
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

/// Whether a face's eyes are closed, from Vision's eye outlines and, when it ran, the face mesh's lids. Each errs its own
/// way on a group at night: Vision reads a laughing squint as a blink (0.15 where the mesh sees 0.2), the mesh misreads
/// one eye behind glasses (0.17 for an eye shut tight). So the eyes are closed when the mesh finds both closed, or when
/// Vision does and the mesh agrees on at least one eye; without the mesh, Vision alone decides.
public enum EyeState {
    public static func closed(vision: (Double, Double)?, mesh: (Double, Double)?, below threshold: Double) -> Bool {
        if let mesh {
            if max(mesh.0, mesh.1) < threshold { return true }
            guard let vision else { return false }
            return max(vision.0, vision.1) < threshold && min(mesh.0, mesh.1) < threshold
        }
        guard let vision else { return false }
        return max(vision.0, vision.1) < threshold
    }
}
