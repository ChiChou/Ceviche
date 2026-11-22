import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Every face in a photo, looked for harder than the culling measure does, for Check Faces. The measure runs Vision once
/// on the camera preview (1616 pixels for a Sony RAW), where the faces of a group at night are 30 pixels across and
/// most are missed: two of nine on one frame. Here the photo is read larger, both face detectors run on the whole of it
/// and on overlapping tiles, and each person the person detector or the scene model finds has their head looked at on
/// its own. Eyes are measured on each face cut out and enlarged, so small faces are judged too.
public enum FaceFinder {
    /// Long edge the photo is read at.
    static let pixelSize = 3072
    /// Faces narrower than this, in pixels of that reading, are too small for their eyes to be measured.
    static let eyePixels = 40.0
    /// Each face is enlarged to this before its landmarks are found.
    static let cropPixels = 384.0

    /// The faces in the photo at `url`, left to right, in fractions of the upright photo from its top left.
    /// `scene` adds the people only the scene model sees (small, defocused, turned away); it is the slowest part.
    public static func faces(at url: URL, scene: Bool = true) throws -> [PhotoQualityReport.Face] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ImageDecode.analysisImage(source, url: url, pixelSize: pixelSize, minimum: pixelSize)
        else { throw CocoaError(.fileReadCorruptFile) }
        return try faces(in: image, scene: scene ? try? BundledModelCache.shared.model(.scene) : nil)
    }

    static func faces(in image: CGImage, scene: MLModel?) throws -> [PhotoQualityReport.Face] {
        let W = image.width, H = image.height
        var boxes: [CGRect] = []   // pixels, top-left origin
        func add(_ found: [VNFaceObservation], in crop: CGRect, scale: Double) {
            for face in found {
                let r = PeopleFinder.pixelRect(face.boundingBox, Int(crop.width * scale), Int(crop.height * scale))
                let box = CGRect(x: crop.minX + r.minX / scale, y: crop.minY + r.minY / scale, width: r.width / scale, height: r.height / scale)
                if !boxes.contains(where: { FaceDetection.same($0, box) }) { boxes.append(box) }
            }
        }
        /// Both detectors on a part of the photo, enlarged to `edge` when it is smaller, so small faces reach the size
        /// Vision finds them at.
        func look(_ crop: CGRect, edge: Double = 1600) throws {
            let crop = crop.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard crop.width >= 16, crop.height >= 16, let piece = image.cropping(to: crop) else { return }
            let scale = max(1, edge / max(crop.width, crop.height))
            let input = scale > 1 ? (resized(piece, scale: scale) ?? piece) : piece
            add(try FaceDetection.faces(cgImage: input), in: crop, scale: Double(input.width) / crop.width)
        }

        try look(CGRect(x: 0, y: 0, width: W, height: H))
        // Overlapping tiles of about half the photo.
        for crop in PeopleFinder.tiles(W, H, side: Double(min(W, H)) * 0.6, shift: false) { try Task.checkCancellation(); try look(crop) }
        // The head of each person found: the person detector on the photo and on tiles, and the scene model's people.
        var people: [CGRect] = []
        func humans(_ crop: CGRect) throws {
            guard let piece = image.cropping(to: crop) else { return }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            try VNImageRequestHandler(cgImage: piece, options: [:]).perform([request])
            for o in request.results ?? [] where o.confidence > 0.3 {
                var r = PeopleFinder.pixelRect(o.boundingBox, piece.width, piece.height)
                r.origin.x += crop.minX; r.origin.y += crop.minY
                if !people.contains(where: { PeopleFinder.iou($0, r) > 0.5 }) { people.append(r) }
            }
        }
        try humans(CGRect(x: 0, y: 0, width: W, height: H))
        for crop in PeopleFinder.tiles(W, H, side: Double(min(W, H)) / 2, shift: false) { try Task.checkCancellation(); try humans(crop) }
        if let scene {
            for region in try PeopleFinder.personRegions(image, model: scene) {
                let r = region.tightRect
                if !r.isNull, r.height >= 24, !people.contains(where: { PeopleFinder.iou($0, r) > 0.3 }) { people.append(r) }
            }
        }
        for person in people where !boxes.contains(where: { person.contains(CGPoint(x: $0.midX, y: $0.midY)) }) {
            try Task.checkCancellation()
            // The top of a standing person, or most of someone seated or cut off by the frame.
            let side = min(person.width * 1.2, person.height)
            try look(CGRect(x: person.midX - side / 2, y: person.minY - side * 0.15, width: side, height: side * 0.9), edge: 640)
        }

        let pixels = try? Luminance(image)
        let measured: [PhotoQualityReport.Face] = boxes.compactMap { box in
            guard let face = measure(box, in: image) else { return nil }
            let bounds = CGRect(x: box.minX / Double(W), y: box.minY / Double(H), width: box.width / Double(W), height: box.height / Double(H))
            let small = box.width < eyePixels
            let mesh = small ? nil : FaceMeshEyes.openness(in: image, face: box)
            return PhotoQualityReport.Face(bounds: bounds, quality: face.quality, leftEye: small ? nil : face.left, rightEye: small ? nil : face.right,
                                           sharpness: pixels.flatMap { $0.sharpness(in: bounds) ?? $0.sharpness(in: bounds, best: true) },
                                           meshLeftEye: mesh?.left, meshRightEye: mesh?.right)
        }
        return measured.sorted { $0.bounds.midX < $1.bounds.midX }
    }

    /// The face's eyes and capture quality, from its landmarks on the face cut out and enlarged; nil when the landmarks
    /// don't fit a face (Vision boxes faces in dark rock with full confidence; their landmarks give them away).
    private static func measure(_ box: CGRect, in image: CGImage) -> (left: Double?, right: Double?, quality: Double?)? {
        let side = max(box.width, box.height) * 2
        let crop = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard crop.width >= 8, crop.height >= 8, let piece = image.cropping(to: crop) else { return nil }
        let scale = max(1, cropPixels / max(crop.width, crop.height))
        guard let input = scale > 1 ? resized(piece, scale: scale) : piece else { return nil }
        let size = CGSize(width: input.width, height: input.height)
        // The face, where it lies in the enlarged crop, Vision's way up.
        let local = CGRect(x: (box.minX - crop.minX) / crop.width, y: 1 - (box.maxY - crop.minY) / crop.height,
                           width: box.width / crop.width, height: box.height / crop.height)
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: local)]
        guard (try? handler.perform([landmarks])) != nil, let face = landmarks.results?.first,
              (face.landmarks?.confidence ?? 0) >= 0.75 else { return nil }
        let capture = VNDetectFaceCaptureQualityRequest()
        capture.inputFaceObservations = [face]
        try? handler.perform([capture])
        return (face.landmarks?.leftEye.flatMap { PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) },
                face.landmarks?.rightEye.flatMap { PhotoQualityAnalyzer.openness($0.pointsInImage(imageSize: size)) },
                capture.results?.first?.faceCaptureQuality.map(Double.init))
    }

    private static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
