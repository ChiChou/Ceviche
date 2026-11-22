import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Portrait's Even tone: for each face, the blend layer the skin-tone network predicted, applied as soft light,
/// `out = (1 − 2m)·I² + 2m·I` on encoded values, where `m` is 0.5 + (layer − 0.5) × the face's amount. The layer is a 512 × 512
/// picture of the face's low frequencies, so blotches and redness even out while pores and hair keep the photo's own
/// detail at any resolution. It is made once, from the photo as developed, and stored in the edit like an AI fill.
public struct SkinTone: Codable, Equatable, Sendable {
    public var faces: [Face]
    /// Each face's layer and strength: every person is evened on their own.
    public struct Face: Codable, Equatable, Sendable {
        /// The square around the face the layer covers, normalized to the retouch frame with a bottom-left origin.
        public var x: Double, y: Double, width: Double, height: Double
        /// The layer as an 8-bit RGB PNG, faded to neutral at its border.
        public var layer: Data
        public var amount: Double
        public init(x: Double, y: Double, width: Double, height: Double, layer: Data, amount: Double = 0.7) {
            self.x = x; self.y = y; self.width = width; self.height = height; self.layer = layer; self.amount = amount
        }
        public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    public init(faces: [Face]) { self.faces = faces }
    static let side = 512
    func validate() throws {
        guard faces.count <= 64, faces.allSatisfy({ face in
            face.amount.isFinite && (0...1).contains(face.amount) && [face.x, face.y, face.width, face.height].allSatisfy(\.isFinite) && face.width > 0 && face.height > 0
                && face.x >= -1 && face.y >= -1 && face.x + face.width <= 2 && face.y + face.height <= 2
                && face.layer.count <= 4_000_000 && face.layer.starts(with: [0x89, 0x50, 0x4E, 0x47])
        }) else { throw EditorError.invalidDocument(L10n.tr("Invalid Even tone.")) }
    }
}

/// Applies the stored layers; each one is decoded once.
final class SkinToneRenderer {
    private var layers: [Data: CIImage] = [:]
    private static let kernel: CIKernel = {
        try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        float encode(float x) { return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055; }
        float decode(float x) { return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4); }
        // Soft light with the layer on encoded values, as the network was trained; past white (HDR) is carried over.
        // Where no face's layer lies the pixel passes through untouched.
        extern "C" [[ stitchable ]] float4 skinTone(coreimage::sample_t s, coreimage::sample_t layer, float amount) {
            if (layer.a <= 0.0) { return s; }
            float3 m = 0.5 + (mix(float3(0.5), layer.rgb / max(layer.a, 1e-4), layer.a) - 0.5) * amount;
            float3 c = clamp(s.rgb, 0.0, 1.0);
            float3 v = float3(encode(c.r), encode(c.g), encode(c.b));
            float3 o = (1.0 - 2.0 * m) * v * v + 2.0 * m * v;
            return float4(float3(decode(o.r), decode(o.g), decode(o.b)) + (s.rgb - c), s.a);
        }
        """).first!
    }()
    func apply(_ tone: SkinTone?, to image: CIImage) -> CIImage {
        guard let tone, tone.faces.contains(where: { $0.amount > 0 }) else { layers.removeAll(); return image }
        layers = layers.filter { key, _ in tone.faces.contains { $0.layer == key } }
        let extent = image.extent
        var output = image
        // One face at a time, each at its own strength.
        for face in tone.faces where face.amount > 0 {
            guard let layer = layer(face.layer) else { continue }
            let target = CGRect(x: extent.minX + face.x * extent.width, y: extent.minY + face.y * extent.height,
                                width: face.width * extent.width, height: face.height * extent.height)
            guard !target.intersection(extent).isEmpty else { continue }
            let placed = layer.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY)
                .scaledBy(x: target.width / layer.extent.width, y: target.height / layer.extent.height))
            output = Self.kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: [output, placed, Float(face.amount)]) ?? output
        }
        return output
    }
    private func layer(_ data: Data) -> CIImage? {
        if let cached = layers[data] { return cached }
        // Raw values: the layer is not a picture to colour-manage.
        guard let image = CIImage(data: data, options: [.colorSpace: NSNull()]) else { return nil }
        layers[data] = image
        return image
    }
}

extension RawRenderer {
    /// Each face's even-tone layer, from the photo as developed without Even tone: faces over 100 pixels (the network's
    /// floor), a square 1.5 times the face around each, as the upstream pipeline crops them.
    /// `only`, when given, keeps the layers of those faces (Vision face boxes).
    public func skinToneFaces(_ settings: Adjustments, only: [CGRect]? = nil) throws -> [SkinTone.Face] {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette(); base.skinTone = nil
        let input = try pipeline(base, maxDimension: 6000)
        guard let photo = context.createCGImage(input, from: input.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditorError.render }
        let W = Double(photo.width), H = Double(photo.height), full = Double(info.width) / W
        // Faces on a 2400 px copy: Vision misses faces on large frames.
        let scale = min(1, 2400 / max(W, H))
        let small = CIImage(cgImage: photo).transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: true)
        guard let preview = context.createCGImage(small, from: small.extent) else { throw EditorError.render }
        let observations = try FaceDetection.faces(cgImage: preview)
        let model = try VNCoreMLModel(for: BundledModelCache.shared.model(.skinTone))
        var faces: [SkinTone.Face] = []
        for observation in observations {
            try Task.checkCancellation()
            let b = observation.boundingBox
            let box = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
            guard box.width * full >= 100 else { continue }
            let side = 1.5 * max(box.width, box.height)
            let crop = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side).integral
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard let piece = photo.cropping(to: crop) else { continue }
            let network = VNCoreMLRequest(model: model)
            network.imageCropAndScaleOption = .scaleFill
            try VNImageRequestHandler(cgImage: piece, options: [:]).perform([network])
            guard let array = (network.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
                  let layer = Self.skinToneLayer(array) else { continue }
            let made = SkinTone.Face(x: crop.minX / W, y: 1 - crop.maxY / H, width: crop.width / W, height: crop.height / H, layer: layer)
            if let only, !only.contains(where: { $0.contains(CGPoint(x: made.x + made.width / 2, y: made.y + made.height / 2)) }) { continue }
            faces.append(made)
        }
        return faces
    }
    /// The network's blend layer as a PNG, faded to neutral over the outer 4 % as the upstream pipeline does, so the
    /// square's edge never shows.
    static func skinToneLayer(_ array: MLMultiArray) -> Data? {
        let n = SkinTone.side
        guard array.shape.count == 4, array.shape[1].intValue == 3, array.shape[2].intValue == n, array.shape[3].intValue == n else { return nil }
        let s = array.strides.map(\.intValue), pointer = array.dataPointer
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            let fy = min(1, Double(min(y, n - 1 - y)) / (Double(n) * 0.04))
            for x in 0..<n {
                let fade = min(fy, min(1, Double(min(x, n - 1 - x)) / (Double(n) * 0.04)))
                for c in 0..<3 {
                    let i = c * s[1] + y * s[2] + x * s[3]
                    let v = array.dataType == .float16 ? Double(pointer.assumingMemoryBound(to: Float16.self)[i]) : Double(pointer.assumingMemoryBound(to: Float.self)[i])
                    bytes[(y * n + x) * 4 + c] = UInt8(max(0, min(255, ((v - 0.5) * fade + 0.5) * 255 + 0.5)))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
