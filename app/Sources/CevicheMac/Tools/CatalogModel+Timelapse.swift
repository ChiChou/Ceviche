import AppKit
import UniformTypeIdentifiers
import CevicheCore

struct TimelapseRequest: Identifiable {
    let id = UUID()
    /// As selected; the dialog orders them by the capture time in each original's EXIF.
    let assets: [CatalogAsset]
    /// The latent image opened, with its photos as `assets`.
    var latent: (assetID: String, saved: TimelapseLatent)? = nil
    /// What the window opens set to make; the toolbar switches it.
    var output = TimelapseOutput.video
}

/// What the Timelapse window makes: a video file, or a Live Photo added to Photos.
enum TimelapseOutput: Hashable, CaseIterable {
    case video, livePhoto
    var title: String { self == .video ? L10n.tr("Video") : L10n.tr("Live Photo") }
}

extension CatalogModel {
    func canCreateTimelapse(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.filter { $0.inLibrary && !$0.isLatent }.count >= 2
    }
    /// Opens the video dialog for the selected photos.
    func requestTimelapse(_ targets: [CatalogAsset]) {
        guard canCreateTimelapse(targets) else { return }
        timelapse = TimelapseRequest(assets: targets.filter { $0.inLibrary && !$0.isLatent })
    }

    /// Asks where to save the video, with the first photo's name and the container's file type; `prompt` names the
    /// panel's button after the window's own action.
    func chooseTimelapseDestination(first: CatalogAsset?, settings: TimelapseSettings, suffix: String = MergeOutput.timelapse.suffix,
                                    prompt: String = L10n.tr("Create Video")) async -> URL? {
        let stem = first.map { ($0.filename as NSString).deletingPathExtension } ?? "Timelapse"
        guard let url = await FileChooser.save(FileSaveRequest(name: "\(stem)-\(suffix).\(settings.fileContainer.fileExtension)",
                                                               types: [settings.fileContainer == .mov ? .quickTimeMovie : .mpeg4Movie],
                                                               prompt: prompt, directory: lastExportFolder)) else { return nil }
        lastExportFolder = url.deletingLastPathComponent()
        return url
    }

    /// Photos developed ahead of the frames that need them. Each has its own renderer, so the GPU and the decoder overlap
    /// while the encoder works on the frame before.
    private static let photosAhead = 3

    /// Writes a movie as a background job. `render` makes the frames each encoder pass asks for, in order, and appends
    /// them to the pass's writer. The file appears under its name only once the video is complete; `finally` runs
    /// however the job ends.
    func startVideoJob(to url: URL, settings: TimelapseSettings, size: CGSize, frames count: Int, metadata: TimelapseMetadata?,
                       finally: @escaping @MainActor () -> Void = {}, render: @escaping @MainActor (VideoPass) async throws -> Void) {
        activity.start(.exporting, title: L10n.tr("Creating video"), detail: url.lastPathComponent, total: count) { [weak self] job in
            defer { finally() }
            guard let self else { return }
            let writer: TimelapseWriter
            do { writer = try TimelapseWriter(url: url, settings: settings, size: size, frames: count, metadata: metadata) } catch {
                self.failure = Failure(L10n.tr("Couldn’t Create the Video"), L10n.tr("The video couldn’t be created. \(error.localizedDescription)"))
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription)); return
            }
            do {
                // One pass is every frame in order; a second pass asks for them again, developed afresh.
                while let runs = await writer.nextPass() {
                    if writer.pass > 1 { self.activity.update(job, completed: 0, detail: L10n.tr("Pass \(writer.pass) - \(url.lastPathComponent)")) }
                    try await render(VideoPass(writer: writer, runs: runs, job: job))
                }
                try Task.checkCancellation()
                ActivityCenter.shared.update(job, detail: L10n.tr("Finishing \(url.lastPathComponent)"))
                try await writer.finish(overwriteExisting: true)
                notice = L10n.tr("Video created")
                NSWorkspace.shared.showInFinder([url])
                ActivityCenter.shared.finish(job, title: L10n.tr("Video created"), outcome: .done(url.lastPathComponent), result: .files([url]))
            } catch where error is CancellationError || Task.isCancelled {
                // A frame stopped mid-decode can fail with the decoder's own error.
                writer.cancel()
                notice = L10n.tr("Video stopped")
            } catch {
                writer.cancel()
                self.failure = Failure(L10n.tr("Couldn’t Create the Video"), L10n.tr("The video couldn’t be created. \(error.localizedDescription)"))
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// Develops every photo with its saved edits once, cuts the video's frame from it, and makes the frames `plan`
    /// asks for from those photos, in order. `frames` are the request's photos in capture order, and `metadata` what
    /// their originals record. `steady` moves each photo back to the series' view.
    func startTimelapse(_ frames: [CatalogAsset], captures: [TimelapseCapture], plan: TimelapsePlan, settings: TimelapseSettings, photo: CGSize,
                        metadata: TimelapseMetadata, skyCache: TimelapseSkyCache? = nil, steady: TimelapseStabilization? = nil, to url: URL) {
        guard let store else { return }
        let size = settings.outputSize(photo: photo), ratio = settings.ratio(photo: photo), crop = settings.crop, hdr = settings.fileColor.isHDR
        let compositor = TimelapseCompositor()
        var maskCache = skyCache
        startVideoJob(to: url, settings: settings, size: size, frames: plan.frames.count, metadata: settings.includeMetadata ? metadata : nil) { pass in
            if settings.temporalDenoise {
                if maskCache == nil { maskCache = try TimelapseSkyCache() }
                try await self.renderDenoisedTimelapse(frames, captures: captures, plan: plan, settings: settings, size: size, ratio: ratio,
                                                     store: store, compositor: compositor, skyCache: maskCache!, steady: steady, pass: pass)
                return
            }
            let order = pass.runs.flatMap { Array($0) }
            // The photos in the order frames first need them, and the last frame that needs each.
            var needed: [Int] = [], lastUse: [Int: Int] = [:]
            for (position, index) in order.enumerated() {
                for photo in plan.frames[index].photos { if lastUse[photo] == nil { needed.append(photo) }; lastUse[photo] = position }
            }
            try await withThrowingTaskGroup(of: (Int, TimelapsePhoto).self) { group in
                var next = 0, rendering = 0
                var ready: [Int: TimelapsePhoto] = [:]
                for (position, index) in order.enumerated() {
                    let frame = plan.frames[index]
                    while !frame.photos.allSatisfy({ ready[$0] != nil }) {
                        // Start photos ahead, keeping a few in hand; the ones this frame needs come first.
                        while next < needed.count && rendering + ready.count < Self.photosAhead + 2 {
                            let photo = needed[next], asset = frames[photo], frameSteady = steady?.frame(photo); next += 1; rendering += 1
                            let source = try await self.resolveOriginal(asset)
                            group.addTask {
                                do { return (photo, try await Self.renderPhoto(asset, source: source, store: store, crop: crop, ratio: ratio, size: size, hdr: hdr, steady: frameSteady)) }
                                catch is CancellationError { throw CancellationError() }
                                catch { throw EditorError.invalidDocument("\(asset.filename): \(error.localizedDescription)") }
                            }
                        }
                        guard let (photo, image) = try await group.next() else { throw EditorError.render }
                        rendering -= 1; ready[photo] = image
                    }
                    try Task.checkCancellation()
                    let buffer = try pass.writer.makeBuffer(), photos = ready
                    try await Task.detached(priority: .userInitiated) { try compositor.compose(frame, photos: photos, into: buffer) }.value
                    try await pass.writer.append(buffer, at: index)
                    for photo in frame.photos where lastUse[photo] == position { ready[photo] = nil }
                    pass.wrote(index)
                }
            }
        }
    }

    /// Only one RAW development is in flight. The source cache holds at most five originals and the compositor
    /// holds only its current one/two outputs. A new instance per encoder pass also handles sparse second-pass runs.
    private func renderDenoisedTimelapse(_ assets: [CatalogAsset], captures: [TimelapseCapture], plan: TimelapsePlan,
                                       settings: TimelapseSettings, size: CGSize, ratio: Double, store: CatalogStore,
                                       compositor: TimelapseCompositor, skyCache: TimelapseSkyCache, steady: TimelapseStabilization?, pass: VideoPass) async throws {
        let denoiser = try await Self.makeDenoiser(size: size, skyCache: skyCache), interval = TimelapseSeries(captures).interval
        var ready: [Int: TimelapsePhoto] = [:]
        for run in pass.runs { for index in run {
            try Task.checkCancellation()
            let frame = plan.frames[index]
            ready = ready.filter { frame.photos.contains($0.key) }
            for photo in frame.photos where ready[photo] == nil {
                ready[photo] = try await denoisedPhoto(photo, assets: assets, captures: captures, interval: interval, settings: settings,
                                                     size: size, ratio: ratio, hdr: settings.fileColor.isHDR, store: store, denoiser: denoiser, steady: steady)
            }
            try Task.checkCancellation()
            let buffer = try pass.writer.makeBuffer(), photos = ready
            try await Task.detached(priority: .userInitiated) { try compositor.compose(frame, photos: photos, into: buffer) }.value
            try Task.checkCancellation()
            try await pass.writer.append(buffer, at: index)
            pass.wrote(index)
        } }
        await denoiser.clear()
    }

    nonisolated private static func makeDenoiser(size: CGSize, skyCache: TimelapseSkyCache?) async throws -> TimelapseDenoiser {
        try Task.checkCancellation()
        return try TimelapseDenoiser(size: size, skyCache: skyCache)
    }

    private func denoisedPhoto(_ index: Int, assets: [CatalogAsset], captures: [TimelapseCapture], interval: Double?,
                               settings: TimelapseSettings, size: CGSize, ratio: Double, hdr: Bool, store: CatalogStore,
                               denoiser: TimelapseDenoiser, steady: TimelapseStabilization?) async throws -> TimelapsePhoto {
        let window = TimelapseDenoiser.window(around: index, captures: captures, count: denoiser.windowSize, interval: interval)
        await denoiser.retain(window)
        for photo in window {
            try Task.checkCancellation()
            if await denoiser.contains(photo) { continue }
            let asset = assets[photo], source = try await resolveOriginal(asset)
            do {
                let rendered = try await Self.developPhoto(asset, source: source, store: store, crop: settings.crop, ratio: ratio, size: size, hdr: hdr,
                                                           steady: steady?.frame(photo), maskIdentity: true)
                try Task.checkCancellation()
                if window.count == 1 { return rendered.photo }
                try await denoiser.prepare(rendered.photo, at: photo, maskKey: rendered.key)
            } catch is CancellationError { throw CancellationError() }
            catch { throw EditorError.invalidDocument("\(asset.filename): \(error.localizedDescription)") }
        }
        return try await denoiser.render(index, window: window)
    }

    nonisolated private static func renderPhoto(_ asset: CatalogAsset, source: URL, store: CatalogStore, crop: TimelapseCrop, ratio: Double,
                                                size: CGSize, hdr: Bool, steady: TimelapseStabilization.Frame?) async throws -> TimelapsePhoto {
        try await developPhoto(asset, source: source, store: store, crop: crop, ratio: ratio, size: size, hdr: hdr, steady: steady, maskIdentity: false).photo
    }

    nonisolated private static func developPhoto(_ asset: CatalogAsset, source: URL, store: CatalogStore, crop: TimelapseCrop, ratio: Double,
                                                 size: CGSize, hdr: Bool, steady: TimelapseStabilization.Frame?, maskIdentity: Bool) async throws -> (photo: TimelapsePhoto, key: String) {
        let current = try await store.asset(asset.id)
        try Task.checkCancellation()
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (renderer, defaults) = try RawRenderer.open(source)
        let adjustments = try await store.savedAdjustments(of: current) ?? defaults
        var key = ""
        if maskIdentity {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let edit = try encoder.encode(adjustments).base64EncodedString()
            let file = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            key = "\(asset.id)|\(source.path)|\(file.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(file.fileSize ?? 0)|\(edit)|\(crop.centerX),\(crop.centerY),\(crop.scale)|\(ratio)|\(size.width),\(size.height)|\(hdr)|\(steady.map { "\($0.shift.dx),\($0.shift.dy),\($0.shift.angle),\($0.margin.width),\($0.margin.height)" } ?? "")"
        }
        return (try await renderer.renderTimelapsePhoto(adjustments, crop: crop, ratio: ratio, size: size, hdr: hdr, steady: steady), key)
    }

    /// One frame as the video shows it, for the dialog's paused preview.
    func timelapsePreview(_ assets: [CatalogAsset], captures: [TimelapseCapture], index: Int, settings: TimelapseSettings, photo: CGSize,
                          size: CGSize, skyCache: TimelapseSkyCache? = nil, steady: TimelapseStabilization? = nil) async throws -> CGImage {
        guard let store else { throw CancellationError() }
        try Task.checkCancellation()
        if settings.temporalDenoise {
            // Analyze and merge at export size so a paused preview shows the actual alignment and rejection policy.
            let output = settings.outputSize(photo: photo), denoiser = try await Self.makeDenoiser(size: settings.outputSize(photo: photo), skyCache: skyCache)
            let rendered = try await denoisedPhoto(index, assets: assets, captures: captures, interval: TimelapseSeries(captures).interval,
                                                 settings: settings, size: output, ratio: settings.ratio(photo: photo), hdr: false,
                                                 store: store, denoiser: denoiser, steady: steady)
            try Task.checkCancellation()
            return try await denoiser.preview(rendered, size: size)
        }
        let asset = assets[index]
        let source = try await resolveOriginal(asset)
        let current = try await store.asset(asset.id)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (renderer, defaults) = try await Task.detached(priority: .userInitiated) { try RawRenderer.open(source) }.value
        let adjustments = try await store.savedAdjustments(of: current) ?? defaults
        return try await renderer.timelapsePreview(adjustments, crop: settings.crop, ratio: settings.ratio(photo: photo), size: size, steady: steady?.frame(index))
    }
}

/// One encoder pass of a video job: the frames it asks for and the writer they go to.
struct VideoPass: Sendable {
    let writer: TimelapseWriter
    /// Frame numbers in the order they're written.
    let runs: [Range<Int>]
    let job: UUID

    func wants(_ index: Int) -> Bool { runs.contains { $0.contains(index) } }
    /// Shows the job's progress once frame `index` of this pass is written.
    @MainActor func wrote(_ index: Int) {
        let total = runs.reduce(0) { $0 + $1.count }
        let written = runs.reduce(0) { $0 + max(0, min($1.upperBound, index + 1) - $1.lowerBound) }
        let count = writer.frameCount, name = writer.url.lastPathComponent
        ActivityCenter.shared.update(job, completed: written * count / max(1, total),
                                     detail: writer.pass > 1 ? L10n.tr("Pass \(writer.pass) - frame \(written) of \(total) - \(name)")
                                         : L10n.tr("Frame \(written) of \(count) - \(name)"))
    }
}
