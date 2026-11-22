import AppKit
import CoreMedia
import Photos
import CevicheCore

/// Create Live Photo: the Timelapse window making a Live Photo instead of a video file. The movie is the timelapse's
/// frames at its frame rate and framing, one photo is the still, both at the chosen size, added to Photos as one
/// Live Photo.
extension CatalogModel {
    func canCreateLivePhoto(_ targets: [CatalogAsset]) -> Bool { canCreateTimelapse(targets) }

    /// Opens the Timelapse window set to Live Photo.
    func requestLivePhoto(_ targets: [CatalogAsset]) {
        guard canCreateLivePhoto(targets) else { return }
        timelapse = TimelapseRequest(assets: targets.filter { $0.inLibrary && !$0.isLatent }, output: .livePhoto)
    }

    /// The movie's frames as plan frame numbers: each once, or with `bounce` forward and back again.
    nonisolated static func livePhotoFrames(count: Int, bounce: Bool) -> [Int] {
        bounce && count > 1 ? Array(0..<count) + (0..<(count - 1)).reversed() : Array(0..<count)
    }

    /// The movie's size for a frame of `ratio` cut by `crop`, and the still's, as `preset` has them and no larger than
    /// the photo's cut allows.
    nonisolated static func livePhotoSizes(ratio: Double, crop: TimelapseCrop, preset: LivePhotoSize, photo: CGSize?) -> (movie: CGSize, still: CGSize) {
        let limit = photo.map { size in let cut = crop.rect(in: size, aspect: ratio); return Double(max(cut.width, cut.height)) }
        return (LivePhoto.size(ratio: ratio, longEdge: preset.movieLongEdge, limit: limit),
                LivePhoto.size(ratio: ratio, longEdge: preset.stillLongEdge, limit: limit))
    }
    nonisolated static func livePhotoSizes(ratio: Double, settings: TimelapseSettings, photo: CGSize?) -> (movie: CGSize, still: CGSize) {
        livePhotoSizes(ratio: ratio, crop: settings.crop, preset: settings.livePhotoSize, photo: photo)
    }

    /// Makes the Live Photo as a background job and adds it to Photos: `photos` in capture order, the frames `plan`
    /// makes from them at the settings' rate and framing, and photo `key` as the still. The caller has leave to add to
    /// Photos.
    func startTimelapseLivePhoto(_ photos: [CatalogAsset], captures: [TimelapseCapture], plan: TimelapsePlan, settings: TimelapseSettings,
                                 photo: CGSize, key: Int, bounce: Bool, steady: TimelapseStabilization? = nil) {
        guard let store, photos.indices.contains(key) else { return }
        let ratio = settings.ratio(photo: photo)
        let sizes = Self.livePhotoSizes(ratio: ratio, settings: settings, photo: captures[key].size)
        let order = Self.livePhotoFrames(count: plan.frames.count, bounce: bounce)
        // The still's moment: the first frame that shows the key photo most, else the one nearest it.
        let shown = order.firstIndex { plan.frames[$0].dominant == key }
            ?? order.indices.min { abs(plan.frames[order[$0]].dominant - key) < abs(plan.frames[order[$1]].dominant - key) } ?? 0
        let name = (photos[key].filename as NSString).deletingPathExtension
        activity.start(.exporting, title: L10n.tr("Creating Live Photo"), detail: photos[key].filename, total: order.count + 1) { job in
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhoto-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let stillURL = staging.appendingPathComponent("\(name).heic"), movieURL = staging.appendingPathComponent("\(name).mov")
                let identifier = UUID().uuidString, keySource = try await self.resolveOriginal(photos[key])
                let still = try await Self.develop(photos[key], source: keySource, store: store) { renderer, adjustments in
                    try await renderer.livePhotoStill(adjustments, crop: settings.crop, ratio: ratio, size: sizes.still, steady: steady?.frame(key))
                }
                try await Task.detached(priority: .userInitiated) { try LivePhoto.writeStill(still, to: stillURL, identifier: identifier, source: keySource) }.value
                let writer = try LivePhotoWriter(url: movieURL, size: sizes.movie, frameDuration: settings.frameRate.frameDuration, stillFrame: shown, identifier: identifier)
                do {
                    let compositor = TimelapseCompositor()
                    // Photos are kept while the next frame needs them; Bounce develops the way back again.
                    var ready: [Int: TimelapsePhoto] = [:]
                    for (position, index) in order.enumerated() {
                        try Task.checkCancellation()
                        let frame = plan.frames[index], next = order.indices.contains(position + 1) ? plan.frames[order[position + 1]].photos : []
                        for photo in frame.photos where ready[photo] == nil {
                            let source = try await self.resolveOriginal(photos[photo])
                            let frameSteady = steady?.frame(photo)
                            ready[photo] = try await Self.develop(photos[photo], source: source, store: store) { renderer, adjustments in
                                try await renderer.renderTimelapsePhoto(adjustments, crop: settings.crop, ratio: ratio, size: sizes.movie, hdr: false, steady: frameSteady)
                            }
                        }
                        let buffer = try writer.makeBuffer(), inputs = ready
                        try await Task.detached(priority: .userInitiated) { try compositor.compose(frame, photos: inputs, into: buffer) }.value
                        try await writer.append(buffer)
                        ready = ready.filter { frame.photos.contains($0.key) || next.contains($0.key) }
                        ActivityCenter.shared.update(job, completed: position + 1, detail: L10n.tr("Frame \(position + 1) of \(order.count)"))
                    }
                    try await writer.finish()
                } catch { writer.cancel(); throw error }
                try Task.checkCancellation()
                ActivityCenter.shared.update(job, completed: order.count + 1, detail: L10n.tr("Adding to Photos"))
                try await Self.addLivePhoto(still: stillURL, movie: movieURL)
                self.notice = L10n.tr("Live Photo added to Photos")
                ActivityCenter.shared.finish(job, title: L10n.tr("Live Photo added to Photos"), outcome: .done(photos[key].filename))
            } catch where error is CancellationError || Task.isCancelled {
                self.notice = L10n.tr("Live Photo stopped")
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Create the Live Photo"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// Asks for leave to add to Photos; when refused, says where to allow it.
    func canAddToPhotos() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            failure = Failure(L10n.tr("Couldn’t Add to Photos"), L10n.tr("Allow Ceviche to add photos in System Settings › Privacy & Security › Photos."))
            return false
        }
        return true
    }

    /// Moves the pair into Photos as one Live Photo.
    nonisolated static func addLivePhoto(still: URL, movie: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: still, options: options)
            request.addResource(with: .pairedVideo, fileURL: movie, options: options)
        }
    }

    /// Opens the photo's original with its saved edits and runs `work` off the main actor.
    nonisolated private static func develop<T: Sendable>(_ asset: CatalogAsset, source: URL, store: CatalogStore,
                                                         _ work: @escaping @Sendable (RawRenderer, Adjustments) async throws -> T) async throws -> T {
        let current = try await store.asset(asset.id)
        let adjustments = try await store.savedAdjustments(of: current)
        return try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let (renderer, defaults) = try RawRenderer.open(source)
                return try await work(renderer, adjustments ?? defaults)
            } catch is CancellationError { throw CancellationError() }
            catch { throw EditorError.invalidDocument("\(asset.filename): \(error.localizedDescription)") }
        }.value
    }
}
