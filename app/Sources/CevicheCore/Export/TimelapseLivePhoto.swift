import Foundation
import CoreGraphics
import CoreMedia
import ImageIO

/// A timelapse made as a Live Photo: the plan's frames as the movie, forward or with Bounce's way back, and one photo
/// as the still. The apps give each photo developed; the order, the still's moment and the writing are here.
public enum TimelapseLivePhoto {
    /// The movie's frames as plan frame numbers: each once, or with `bounce` forward and back again.
    public static func frames(count: Int, bounce: Bool) -> [Int] {
        bounce && count > 1 ? Array(0..<count) + (0..<(count - 1)).reversed() : Array(0..<count)
    }

    /// The movie's size for a frame of `ratio` cut by `crop`, and the still's, as `preset` has them and no larger than
    /// the photo's cut allows.
    public static func sizes(ratio: Double, crop: TimelapseCrop, preset: LivePhotoSize, photo: CGSize?) -> (movie: CGSize, still: CGSize) {
        let limit = photo.map { size in let cut = crop.rect(in: size, aspect: ratio); return Double(max(cut.width, cut.height)) }
        return (LivePhoto.size(ratio: ratio, longEdge: preset.movieLongEdge, limit: limit),
                LivePhoto.size(ratio: ratio, longEdge: preset.stillLongEdge, limit: limit))
    }
    public static func sizes(ratio: Double, settings: TimelapseSettings, photo: CGSize?) -> (movie: CGSize, still: CGSize) {
        sizes(ratio: ratio, crop: settings.crop, preset: settings.livePhotoSize, photo: photo)
    }

    /// The still's moment, as a position in `order`: the first frame that shows photo `key` most, else the one
    /// nearest it. `dominant` is the photo each plan frame shows most.
    public static func stillFrame(order: [Int], dominant: [Int], key: Int) -> Int {
        order.firstIndex { dominant[$0] == key }
            ?? order.indices.min { abs(dominant[order[$0]] - key) < abs(dominant[order[$1]] - key) } ?? 0
    }

    /// Writes a Live Photo's two files: first photo `key` as the still, with the capture tags of `source`; then the
    /// movie of `plan`'s frames in `order` at `frameDuration`. `developStill` makes the still and `developPhoto` each
    /// photo cut to the movie's frame; a photo is kept only while this frame or the next shows it, so Bounce develops
    /// the way back again. `progress` hears each frame written and how many there are.
    public static func write(plan: TimelapsePlan, order: [Int], key: Int, movieSize: CGSize, frameDuration: CMTime,
                             stillURL: URL, movieURL: URL, source: URL?,
                             developStill: () async throws -> CGImage, developPhoto photo: (Int) async throws -> TimelapsePhoto,
                             progress: (Int, Int) -> Void = { _, _ in },
                             isolation: isolated (any Actor)? = #isolation) async throws {
        let identifier = UUID().uuidString
        let picture = try await developStill()
        try await Task.detached(priority: .userInitiated) { try LivePhoto.writeStill(picture, to: stillURL, identifier: identifier, source: source) }.value
        let shown = stillFrame(order: order, dominant: plan.frames.map(\.dominant), key: key)
        let writer = try LivePhotoWriter(url: movieURL, size: movieSize, frameDuration: frameDuration, stillFrame: shown, identifier: identifier)
        do {
            let compositor = TimelapseCompositor()
            var ready: [Int: TimelapsePhoto] = [:]
            for (position, index) in order.enumerated() {
                try Task.checkCancellation()
                let frame = plan.frames[index], next = order.indices.contains(position + 1) ? plan.frames[order[position + 1]].photos : []
                for number in frame.photos where ready[number] == nil { ready[number] = try await photo(number) }
                try Task.checkCancellation()
                let buffer = try writer.makeBuffer(), inputs = ready
                try await Task.detached(priority: .userInitiated) { try autoreleasepool { try compositor.compose(frame, photos: inputs, into: buffer) } }.value
                try await writer.append(buffer)
                ready = ready.filter { frame.photos.contains($0.key) || next.contains($0.key) }
                progress(position + 1, order.count)
            }
            ready = [:]
            try await writer.finish()
        } catch { writer.cancel(); throw error }
    }
}

extension TimelapseStabilizer {
    /// Measures the frames from their catalog thumbnails (JPEG or HEIC data, in playing order), decoding each one only
    /// as the stabilizer asks for it.
    public static func stabilize(thumbnails: [Data?], times: [Date?] = [], isCancelled: () -> Bool = { false }) -> TimelapseStabilization {
        stabilize(count: thumbnails.count, times: times, isCancelled: isCancelled) { index in
            autoreleasepool {
                thumbnails[index].flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
        }
    }
}
