import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Finds frames where the camera moved, from the Library's thumbnails: Vision registers each frame on the one before,
/// which takes a few milliseconds a pair at this size. A frame knocked out of line and back, and a camera that moved
/// and stayed, both show; a steady pan or slide does not, since only changes from the neighbors' motion count.
public enum TimelapseAlignment {
    public enum Mark: Sendable, Equatable {
        /// Out of line with the frames around it, as when the tripod was knocked or a frame was shot by hand.
        case unaligned
        /// The view moved here and stayed moved.
        case cameraMoved
    }
    /// The long edge registration works at.
    public static let size = 320
    /// A shift counts at this fraction of the frame's width: about 38 pixels of a 4K video.
    public static let threshold = 0.01

    /// A thumbnail cut down for registration.
    public static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                                                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// How far `next` lies from `previous`, as fractions of the width and height; nil when the two don't register,
    /// as in the dark or across a scene change.
    public static func shift(from previous: CGImage, to next: CGImage) -> CGVector? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: next)
        do { try VNImageRequestHandler(cgImage: previous).perform([request]) } catch { return nil }
        guard let observation = request.results?.first, observation.confidence > 0.3 else { return nil }
        let transform = observation.alignmentTransform
        return CGVector(dx: transform.tx / CGFloat(previous.width), dy: transform.ty / CGFloat(previous.height))
    }

    /// Each frame's mark from the shifts between neighbors: `shifts[i]` is frame i from frame i − 1, nil where unknown.
    /// Each step is compared with the steps around it, so a steady pan or slide counts as still. A step the next one
    /// undoes is a frame out of line; a step that stays is the camera moving.
    public static func marks(_ shifts: [CGVector?]) -> [Mark?] {
        let count = shifts.count
        guard count >= 3 else { return Array(repeating: nil, count: count) }
        func median(_ values: [CGFloat]) -> CGFloat { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        // How far each step strays from the steps around it.
        let deviations: [CGVector?] = (0..<count).map { index in
            guard index > 0, let step = shifts[index] else { return nil }
            let around = (max(1, index - 3)...min(count - 1, index + 3)).filter { $0 != index }.compactMap { shifts[$0] }
            guard !around.isEmpty else { return nil }
            return CGVector(dx: step.dx - median(around.map(\.dx)), dy: step.dy - median(around.map(\.dy)))
        }
        func size(_ vector: CGVector) -> Double { Double(hypot(vector.dx, vector.dy)) }
        func returns(_ index: Int) -> Bool {
            guard index + 1 < count, let out = deviations[index], let back = deviations[index + 1], size(out) > threshold, size(back) > threshold else { return false }
            return size(CGVector(dx: out.dx + back.dx, dy: out.dy + back.dy)) < size(out) / 2
        }
        return (0..<count).map { index in
            guard let deviation = deviations[index], size(deviation) > threshold else { return nil }
            if returns(index) { return .unaligned }
            // The step back from a frame out of line is no move of its own.
            if index > 0 && returns(index - 1) { return nil }
            return .cameraMoved
        }
    }
}
