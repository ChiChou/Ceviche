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

    /// Makes the Live Photo as a background job and adds it to Photos: `photos` in capture order, the frames `plan`
    /// makes from them at the settings' rate and framing, and photo `key` as the still. The caller has leave to add to
    /// Photos.
    func startTimelapseLivePhoto(_ photos: [CatalogAsset], captures: [TimelapseCapture], plan: TimelapsePlan, settings: TimelapseSettings,
                                 photo: CGSize, key: Int, bounce: Bool, steady: TimelapseStabilization? = nil) {
        guard let store, photos.indices.contains(key) else { return }
        let ratio = settings.ratio(photo: photo)
        let sizes = TimelapseLivePhoto.sizes(ratio: ratio, settings: settings, photo: captures[key].size)
        let order = TimelapseLivePhoto.frames(count: plan.frames.count, bounce: bounce)
        let name = (photos[key].filename as NSString).deletingPathExtension
        activity.start(.exporting, title: L10n.tr("Creating Live Photo"), detail: photos[key].filename, total: order.count + 1) { job in
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhoto-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let stillURL = staging.appendingPathComponent("\(name).heic"), movieURL = staging.appendingPathComponent("\(name).mov")
                let keySource = try await self.resolveOriginal(photos[key])
                try await TimelapseLivePhoto.write(plan: plan, order: order, key: key, movieSize: sizes.movie, frameDuration: settings.frameRate.frameDuration,
                                                   stillURL: stillURL, movieURL: movieURL, source: keySource,
                                                   developStill: {
                    try await Self.develop(photos[key], source: keySource, store: store) { renderer, adjustments in
                        try await renderer.livePhotoStill(adjustments, crop: settings.crop, ratio: ratio, size: sizes.still, steady: steady?.frame(key))
                    }
                }, developPhoto: { photo in
                    let source = try await self.resolveOriginal(photos[photo])
                    let frameSteady = steady?.frame(photo)
                    return try await Self.develop(photos[photo], source: source, store: store) { renderer, adjustments in
                        try await renderer.renderTimelapsePhoto(adjustments, crop: settings.crop, ratio: ratio, size: sizes.movie, hdr: false, steady: frameSteady)
                    }
                }, progress: { done, total in
                    ActivityCenter.shared.update(job, completed: done, detail: L10n.tr("Frame \(done) of \(total)"))
                })
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
