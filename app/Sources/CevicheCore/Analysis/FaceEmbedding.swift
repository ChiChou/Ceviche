import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Who a face is, as 128 numbers: SFace (`BundledModel.faceIdentity`) on the face aligned to OpenCV's 112 × 112
/// template by five points Vision finds. Two embeddings of the same person have a cosine similarity of about 0.5 or more
/// (`PeopleGrouping`). Made from the Faces wall tile (`FaceCrops.wallTiles`), the face with room around it at 256 pixels,
/// so a library already analysed needs no original read again. Measured on 3,060 wall tiles of a real catalog: Vision
/// found the five points on 94.5 %; the others (profiles, blur, faces in artwork) get no embedding.
public enum FaceEmbedding {
    /// Embeddings of different revisions are never compared: a new model or alignment raises it, and the backfill
    /// embeds every face again.
    public static let revision = 1
    public static let count = 128
    static let side = 112
    /// OpenCV's FaceRecognizerSF template: eye centres (image left first), nose tip, mouth corners, in the 112 crop.
    static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
                                      CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)]

    public static var isAvailable: Bool { BundledModel.faceIdentity.isAvailable }

    /// The embedding of the face nearest the middle of a wall tile, unit length; nil when Vision finds no face with
    /// eyes, nose and mouth in it. Throws when the model is missing or fails.
    public static func embed(tile: CGImage) throws -> [Float]? {
        guard let points = landmarks(in: tile) else { return nil }
        let pixels = aligned(tile, points: points)
        return try embed(aligned: pixels)
    }
    /// `embed(tile:)` from encoded tile data, as the previews database keeps it.
    public static func embed(tileData data: Data) throws -> [Float]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try embed(tile: image)
    }

    /// Eye centres (image left first), nose tip and mouth corners of the face nearest the middle, in the image's
    /// pixels, top-left origin.
    static func landmarks(in image: CGImage) -> [CGPoint]? {
        let request = VNDetectFaceLandmarksRequest()
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        guard let face = request.results?.min(by: { hypot($0.boundingBox.midX - 0.5, $0.boundingBox.midY - 0.5) < hypot($1.boundingBox.midX - 0.5, $1.boundingBox.midY - 0.5) }),
              let marks = face.landmarks else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: size.height - $0.y) }
        }
        func mean(_ p: [CGPoint]) -> CGPoint { CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)) }
        let eyes = [points(marks.leftEye), points(marks.rightEye)]
        let lips = points(marks.outerLips)
        guard eyes.allSatisfy({ !$0.isEmpty }), let tip = points(marks.noseCrest).max(by: { $0.y < $1.y }),
              let left = lips.min(by: { $0.x < $1.x }), let right = lips.max(by: { $0.x < $1.x }) else { return nil }
        return eyes.map(mean).sorted { $0.x < $1.x } + [tip, left, right]
    }

    /// The least-squares similarity (scale, rotation, shift; no reflection) taking `source` onto `target`: the
    /// Umeyama estimate OpenCV aligns with, in closed form for two dimensions.
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(source.count)
        let sm = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let tm = CGPoint(x: target.map(\.x).reduce(0, +) / n, y: target.map(\.y).reduce(0, +) / n)
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for (s, t) in zip(source, target) {
            let sx = s.x - sm.x, sy = s.y - sm.y, tx = t.x - tm.x, ty = t.y - tm.y
            dot += sx * tx + sy * ty; cross += sx * ty - sy * tx; norm += sx * sx + sy * sy
        }
        guard norm > 0 else { return .identity }
        let a = dot / norm, b = cross / norm
        // x' = a x - b y + tx, y' = b x + a y + ty
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tm.x - (a * sm.x - b * sm.y), ty: tm.y - (b * sm.x + a * sm.y))
    }

    /// The face warped onto the template, as planar RGB in 0…255 (`side`² values a plane): bilinear, black outside the
    /// tile, pixel centres on whole coordinates as OpenCV's warpAffine has them.
    static func aligned(_ image: CGImage, points: [CGPoint]) -> [Float] {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        // The tile's own values, as OpenCV reads a file: no colour conversion.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let inverse = similarity(from: points, to: template).inverted()
        let plane = side * side
        var out = [Float](repeating: 0, count: plane * 3)
        for y in 0..<side {
            for x in 0..<side {
                let p = CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(inverse)
                let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                let fx = Float(p.x) - Float(x0), fy = Float(p.y) - Float(y0)
                var rgb: (Float, Float, Float) = (0, 0, 0)
                for (dx, dy, w) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] where w > 0 {
                    let sx = x0 + dx, sy = y0 + dy
                    guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                    let i = (sy * width + sx) * 4
                    rgb.0 += w * Float(rgba[i]); rgb.1 += w * Float(rgba[i + 1]); rgb.2 += w * Float(rgba[i + 2])
                }
                let o = y * side + x
                out[o] = rgb.0; out[plane + o] = rgb.1; out[2 * plane + o] = rgb.2
            }
        }
        return out
    }

    /// The unit-length embedding of an aligned crop from `aligned`.
    static func embed(aligned pixels: [Float]) throws -> [Float] {
        let model = try BundledModelCache.shared.model(.faceIdentity)
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        pixels.withUnsafeBufferPointer { source in
            input.withUnsafeMutableBytes { target, _ in target.copyMemory(from: UnsafeRawBufferPointer(source)) }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["data": input]))
        guard let values = output.featureValue(for: "embedding")?.multiArrayValue, values.count == count else {
            throw EditorError.invalidDocument(L10n.tr("The People model gave an unexpected result."))
        }
        var vector = (0..<count).map { Float(truncating: values[$0]) }
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return vector }
        for i in vector.indices { vector[i] /= length }
        return vector
    }

    /// Stored form: `count` Float16 values.
    public static func data(_ vector: [Float]) -> Data {
        vector.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    public static func vector(_ data: Data) -> [Float]? {
        guard data.count == count * 2 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)).map(Float.init) }
    }
}
