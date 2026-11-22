import AppKit
import CoreMedia
import CevicheCore

extension CatalogModel {
    /// The trails building up, one frame per included photo, as a video. Every frame takes `development`, the one the
    /// preview shows, so exposure and white balance hold still; nil develops them as the stack's DNG opens.
    func startStarTrailVideo(_ merger: StarTrailsMerger, settings: StarTrailsSettings, trails: StarTrailsVideoTrails, glow: StarTrailsVideoGlow, meteorFade: StarTrailsMeteorFade?,
                             video: TimelapseSettings, photo: CGSize, frames count: Int,
                             development: Adjustments?, metadata: TimelapseMetadata?, access: [URL], pending: Task<Void, Never>?, to url: URL) {
        let size = video.outputSize(photo: photo), ratio = video.ratio(photo: photo)
        // Frames are stacked at full size but handed over only as large as the video's frame needs: a 42-megapixel DNG per
        // frame would take far longer to write and develop than the video takes to encode.
        let cut = video.crop.rect(in: photo, aspect: ratio)
        let longEdge = Int((max(photo.width, photo.height) * min(1, size.width / max(1, cut.width))).rounded(.up))
        startVideoJob(to: url, settings: video, size: size, frames: count, metadata: metadata,
                      finally: { access.forEach { $0.stopAccessingSecurityScopedResource() } }) { pass in
            // Preview and video share an analyzer; wait for any cancelled preview to finish using it.
            await pending?.value
            // Every pass stacks from the first photo, but only writes the frames the encoder asks for.
            let work = Task.detached(priority: .userInitiated) {
                try await merger.animation(settings, trails: trails, glow: glow, meteorFade: meteorFade, longEdge: longEdge, frames: pass.wants, progress: { detail in
                    Task { @MainActor in ActivityCenter.shared.update(pass.job, detail: detail) }
                }) { index, file in
                    let renderer = try RawRenderer(sourceURL: file)
                    let buffer = try pass.writer.makeBuffer()
                    try await renderer.renderTimelapseFrame(development ?? renderer.info.defaults, crop: video.crop, ratio: ratio, into: buffer)
                    try await pass.writer.append(buffer, at: index)
                    await pass.wrote(index)
                }
            }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
    }

    /// The trails building up squeezed into a 3-second Live Photo movie, the finished trails as its still, added to
    /// Photos, which the caller has leave to add to. Up to 90 of the frames are shown, spread from the first photo to
    /// the last, at the `preset` size. `named` gives the files their name and `source` the still's
    /// capture tags.
    func startStarTrailLivePhoto(_ merger: StarTrailsMerger, settings: StarTrailsSettings, trails: StarTrailsVideoTrails, glow: StarTrailsVideoGlow,
                                 meteorFade: StarTrailsMeteorFade?, crop: TimelapseCrop, ratio: Double, size preset: LivePhotoSize, photo: CGSize, frames count: Int,
                                 development: Adjustments?, source: URL, named: String, access: [URL], pending: Task<Void, Never>?) {
        let cut = crop.rect(in: photo, aspect: ratio)
        // Only the last frame, which is the still, is handed over at the still's size.
        let sizes = Self.livePhotoSizes(ratio: ratio, crop: crop, preset: preset, photo: photo)
        func longEdge(_ size: CGSize) -> Int { Int((max(photo.width, photo.height) * min(1, size.width / max(1, cut.width))).rounded(.up)) }
        let shown = LivePhoto.sample(count), wanted = Set(shown), last = count - 1
        activity.start(.exporting, title: L10n.tr("Creating Live Photo"), detail: named, total: shown.count + 1) { job in
            defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhoto-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let stillURL = staging.appendingPathComponent("\(named).heic"), movieURL = staging.appendingPathComponent("\(named).mov")
                let identifier = UUID().uuidString
                let writer = try LivePhotoWriter(url: movieURL, size: sizes.movie, frameDuration: LivePhoto.sampleDuration(shown.count),
                                                 stillFrame: shown.count - 1, identifier: identifier)
                // Preview and movie share an analyzer; wait for any cancelled preview to finish using it.
                await pending?.value
                let work = Task.detached(priority: .userInitiated) {
                    try await merger.animation(settings, trails: trails, glow: glow, meteorFade: meteorFade, longEdge: longEdge(sizes.movie),
                                               lastLongEdge: longEdge(sizes.still), frames: { wanted.contains($0) },
                                               progress: { detail in Task { @MainActor in ActivityCenter.shared.update(job, detail: detail) } }) { index, file in
                        let renderer = try RawRenderer(sourceURL: file)
                        let adjustments = development ?? renderer.info.defaults
                        let buffer = try writer.makeBuffer()
                        try await renderer.renderTimelapseFrame(adjustments, crop: crop, ratio: ratio, into: buffer)
                        try await writer.append(buffer)
                        let done = (shown.firstIndex(of: index) ?? 0) + 1
                        await MainActor.run { ActivityCenter.shared.update(job, completed: done, detail: L10n.tr("Frame \(done) of \(shown.count)")) }
                        // The finished trails, cut as the movie is, are the still.
                        if index == last {
                            let still = try await renderer.livePhotoStill(adjustments, crop: crop, ratio: ratio, size: sizes.still)
                            try LivePhoto.writeStill(still, to: stillURL, identifier: identifier, source: source)
                        }
                    }
                    try await writer.finish()
                }
                do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } } catch { writer.cancel(); throw error }
                try Task.checkCancellation()
                ActivityCenter.shared.update(job, completed: shown.count + 1, detail: L10n.tr("Adding to Photos"))
                try await Self.addLivePhoto(still: stillURL, movie: movieURL)
                self.notice = L10n.tr("Live Photo added to Photos")
                ActivityCenter.shared.finish(job, title: L10n.tr("Live Photo added to Photos"), outcome: .done(named))
            } catch where error is CancellationError || Task.isCancelled {
                self.notice = L10n.tr("Live Photo stopped")
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Create the Live Photo"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
