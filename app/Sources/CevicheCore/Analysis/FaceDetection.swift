import CoreImage
import Vision

/// Every face in a picture. Vision's current face detector misses faces the older one finds in a lit group at night
/// (four of nine on one photo, at any size), and the older one misses some the current one finds, so both run and
/// their faces are merged: a face both found is kept once, as the current detector boxed it.
enum FaceDetection {
    static func faces(ciImage image: CIImage) throws -> [VNFaceObservation] { try faces { VNImageRequestHandler(ciImage: image) } }
    static func faces(cgImage image: CGImage) throws -> [VNFaceObservation] { try faces { VNImageRequestHandler(cgImage: image) } }
    /// `handler` makes a handler for each detector: one handler gives a second face request the first one's faces.
    private static func faces(_ handler: () -> VNImageRequestHandler) throws -> [VNFaceObservation] {
        let current = VNDetectFaceRectanglesRequest()
        try handler().perform([current])
        var found = current.results ?? []
        guard VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision2),
              current.revision != VNDetectFaceRectanglesRequestRevision2 else { return found }
        let older = VNDetectFaceRectanglesRequest()
        older.revision = VNDetectFaceRectanglesRequestRevision2
        try handler().perform([older])
        for face in older.results ?? [] where !found.contains(where: { same($0.boundingBox, face.boundingBox) }) {
            found.append(face)
        }
        return found
    }
    /// The same face: either box holds the other's centre.
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        a.contains(CGPoint(x: b.midX, y: b.midY)) || b.contains(CGPoint(x: a.midX, y: a.midY))
    }
}
