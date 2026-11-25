import SwiftUI
import ImageIO
import CevicheCore

/// Reads the photos' capture times, orders them, and plays them back as the video will run: from the catalog's
/// thumbnails while playing, and from the original with its full development on the frame playback stops at.
@MainActor
final class TimelapseModel: ObservableObject {
    enum Stage: Equatable { case reading(Double), ready }
    /// Framing the crop over the whole photo, or the video's frame alone.
    enum Mode: Hashable { case crop, video }

    let request: TimelapseRequest
    @Published private(set) var stage = Stage.reading(0)
    /// The photos the video keeps, in capture order, with what their originals record.
    @Published private(set) var frames: [CatalogAsset] = []
    @Published private(set) var captures: [TimelapseCapture] = []
    /// Read from the kept photos alone, so removing one clears what it caused.
    @Published private(set) var series: TimelapseSeries?
    /// Kept photos whose originals couldn't be opened; the video can't be made with them.
    @Published private(set) var offline: [String] = []
    /// Photos left out of the video, by asset ID.
    @Published private(set) var removed: Set<String> = []
    /// Frames picked in the filmstrip, by asset ID; empty when only the current frame is.
    @Published var selection: Set<String> = []
    @Published var settings: TimelapseSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.remember(output.preferenceKey); updatePlan()
            if settings.stabilize != oldValue.stabilize { measureStabilization() }
            scheduleRender()
        }
    }
    /// A video file, or a Live Photo; each keeps its own settings, the framing carried across.
    @Published var output: TimelapseOutput {
        didSet {
            guard output != oldValue else { return }
            playing = false
            var next = TimelapseSettings.remembered(output.preferenceKey) ?? output.defaults
            next.crop = settings.crop
            settings = next
        }
    }
    /// Live Photo: plays forward and back again.
    @Published var bounce = UserDefaults.standard.bool(forKey: "livePhotoBounce") { didSet { UserDefaults.standard.set(bounce, forKey: "livePhotoBounce") } }
    /// Live Photo: the photo the still is made from, by asset ID; nil for the middle one.
    @Published var keyID: String?
    /// Which photos make each video frame; nil until the series is read, or when the timing can't make one.
    @Published private(set) var plan: TimelapsePlan?
    @Published private(set) var planError: String?
    /// Each kept frame's place against its neighbors, from the thumbnails; empty until measured.
    @Published private(set) var alignment: [TimelapseAlignment.Mark?] = []
    @Published private(set) var aligning = false
    /// Each kept frame's drift from the series' view, measured from the thumbnails while Stabilize is on.
    @Published private(set) var stabilization: TimelapseStabilization? { didSet { if stabilization != oldValue { scheduleRender() } } }
    @Published private(set) var stabilizing = false
    /// What the video's frames are moved by: nil while Stabilize is off.
    var steady: TimelapseStabilization? { settings.stabilize ? stabilization : nil }
    @Published var index = 0 { didSet { if index != oldValue { thumbnail = image(at: index); scheduleRender() } } }
    /// Where a Shift-click range starts.
    private var anchor = 0
    @Published var mode = Mode.crop { didSet { scheduleRender() } }
    @Published var playing = false { didSet { if playing != oldValue { playing ? play() : stopPlaying() } } }
    /// The catalog thumbnail of the current frame.
    @Published private(set) var thumbnail: CGImage?
    /// The current frame rendered from its original, once playback rests on it in Video mode.
    @Published private(set) var rendered: (image: CGImage, key: RenderKey)?
    @Published private(set) var renderingFrame = false
    @Published private(set) var renderError: String?

    struct RenderKey: Equatable { let assetID: String; let settings: TimelapseSettings; let steady: TimelapseStabilization.Frame? }
    private weak var catalog: CatalogModel?
    /// Every photo of the request in capture order; `frames` is this less `removed`.
    private var all: [(asset: CatalogAsset, capture: TimelapseCapture)] = []
    private var offlineIDs: Set<String> = []
    private var thumbnails: [String: Data] = [:]
    /// By frame position, so cleared whenever the frames change.
    private var decoded: [Int: CGImage] = [:]
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    /// Masks survive scrubbing and are handed to the export job, then removed when the last owner finishes.
    private var skyCache: TimelapseSkyCache?
    private var alignTask: Task<Void, Never>?
    private var stabilizeTask: Task<Void, Never>?
    /// Registration of one frame on another, by "previous>next" asset IDs, so removing a frame measures only the new
    /// neighbors.
    private var shifts: [String: CGVector?] = [:]
    init(request: TimelapseRequest, key: String? = nil) {
        self.request = request
        output = request.output; keyID = key
        var settings = TimelapseSettings.remembered(request.output.preferenceKey) ?? request.output.defaults
        // The framing belongs to the photos it was made for.
        settings.crop = TimelapseCrop()
        self.settings = request.latent?.saved.settings ?? settings
        removed = Set(request.latent?.saved.removed ?? [])
        latentAssetID = request.latent?.assetID; savedLatent = request.latent?.saved
    }

    /// The latent image this window opened, or the one its video left.
    private(set) var latentAssetID: String?
    private var savedLatent: TimelapseLatent?
    /// Keeps the settings and the photos left out in the latent image: a new one only for a video with Keep Latent
    /// Image ticked, which closing updates.
    func keepLatent(catalog: CatalogModel, output: Bool) {
        let state = TimelapseLatent(settings: settings, removed: removed)
        guard output && LatentPreference.keeps(LatentImage.timelapse) || latentAssetID != nil, stage == .ready, state != savedLatent, let picture = image(at: 0) ?? thumbnail,
              let store = catalog.store else { return }
        savedLatent = state
        let sources = request.assets, into = latentAssetID, size = outputSize
        let stem = ((frames.first ?? sources[0]).filename as NSString).deletingPathExtension
        Task {
            do {
                var references: [LatentImage.Source] = []
                for asset in sources { references.append(try await catalog.latentSource(asset)) }
                let latent = try LatentImage(catalogID: store.manifest.id, sources: references, timelapse: state,
                                             width: Int(size.width.rounded()), height: Int(size.height.rounded()))
                latentAssetID = try await catalog.storeLatent(latent, pictures: try LatentImage.pictures(picture), name: "\(stem)-Timelapse",
                                                              sources: sources, into: latentAssetID ?? into, store: store)
            } catch is CancellationError {
            } catch { savedLatent = nil; catalog.failure = Failure(L10n.tr("Couldn’t Keep the Latent Image"), error) }
        }
    }

    /// The first frame's proportions as developed, which As Photo follows and the crop is drawn on.
    var photoSize: CGSize {
        if let first = image(at: 0) { return CGSize(width: first.width, height: first.height) }
        return captures.first?.size ?? CGSize(width: 3, height: 2)
    }
    var ratio: Double { settings.ratio(photo: photoSize) }
    var outputSize: CGSize { settings.outputSize(photo: photoSize) }
    var validationError: String? {
        // A Live Photo's size and encoding are its own.
        if output == .livePhoto { return planError }
        do { try settings.validate(photo: photoSize) } catch { return error.localizedDescription }
        if settings.temporalDenoise && !BundledModel.sky.isAvailable {
            return L10n.tr("The \(BundledModel.sky.feature) model is not installed. Install it in Settings › Models.")
        }
        return planError
    }
    var canCreate: Bool {
        stage == .ready && offline.isEmpty && frames.count >= 2 && (plan?.frames.count ?? 0) >= 2 && validationError == nil
            && (!settings.stabilize || stabilization != nil)
    }
    /// Live Photo: the key photo's place in the frames.
    var keyPosition: Int { keyID.flatMap { id in frames.firstIndex { $0.id == id } } ?? frames.count / 2 }
    /// Live Photo: the movie's frames, with Bounce's way back, and how long it plays.
    var livePhotoFrameCount: Int { TimelapseLivePhoto.frames(count: plan?.frames.count ?? frames.count, bounce: bounce).count }
    var livePhotoSeconds: Double { Double(livePhotoFrameCount) / max(1, settings.frameRate.rate) }
    /// Slower than a video's, so a few photos can fill a Live Photo's few seconds.
    static let liveRates = [4, 6, 8, 10, 12, 15, 24, 30, 60].map { VideoFrameRate($0) }
    /// The Live Photo rate that plays the frames closest to its 3 seconds; nil when it is the one set.
    var liveFitRate: VideoFrameRate? {
        let frames = Double(livePhotoFrameCount)
        let best = Self.liveRates.min { abs(log(frames / $0.rate / LivePhoto.movieSeconds)) < abs(log(frames / $1.rate / LivePhoto.movieSeconds)) }
        return best == settings.frameRate ? nil : best
    }
    var livePhotoSizes: (movie: CGSize, still: CGSize) { TimelapseLivePhoto.sizes(ratio: ratio, settings: settings, photo: captures.first?.size) }
    var livePhotoSize: CGSize { livePhotoSizes.movie }
    /// Real time each frame covers in Follow Capture Time when the field is left to the series.
    var usualStep: Double { series?.interval ?? 1 }

    func start(catalog: CatalogModel) {
        guard loadTask == nil else { return }
        self.catalog = catalog
        loadTask = Task {
            let assets = request.assets
            var urls: [URL?] = []
            for (number, asset) in assets.enumerated() {
                do { urls.append(try await catalog.resolveOriginal(asset)) } catch { urls.append(nil) }
                stage = .reading(Double(number + 1) / Double(assets.count) * 0.3)
                if Task.isCancelled { return }
            }
            // Header reads only; a few hundred originals take a second or two.
            var captures: [TimelapseCapture] = []
            for start in stride(from: 0, to: assets.count, by: 24) {
                let batch = Array(start..<min(assets.count, start + 24))
                let read = await Task.detached(priority: .userInitiated) {
                    batch.map { index -> TimelapseCapture in
                        guard let url = urls[index] else { return TimelapseCapture(filename: assets[index].filename, date: nil) }
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return TimelapseCapture.read(url, filename: assets[index].filename)
                    }
                }.value
                captures += read
                stage = .reading(0.3 + Double(captures.count) / Double(assets.count) * 0.5)
                if Task.isCancelled { return }
            }
            all = TimelapseSeries(captures).order.map { (assets[$0], captures[$0]) }
            offlineIDs = Set(assets.indices.filter { urls[$0] == nil }.map { assets[$0].id })
            var thumbnails: [String: Data] = [:]
            for (number, entry) in all.enumerated() {
                thumbnails[entry.asset.id] = try? await catalog.previews?.data(assetID: entry.asset.id)
                if number % 32 == 0 { stage = .reading(0.8 + Double(number) / Double(all.count) * 0.2) }
                if Task.isCancelled { return }
            }
            self.thumbnails = thumbnails
            rebuild(keeping: nil)
            stage = .ready
        }
    }

    func stop() {
        playing = false
        loadTask?.cancel(); playTask?.cancel(); renderTask?.cancel(); alignTask?.cancel(); stabilizeTask?.cancel()
        skyCache = nil
    }

    /// The thumbnail of frame `index`, decoded on first use. Decoding a 640-pixel JPEG takes a few milliseconds, well
    /// inside a frame at 60 fps, so playback decodes as it goes and keeps only the frames around the playhead.
    func image(at index: Int) -> CGImage? {
        if let cached = decoded[index] { return cached }
        guard frames.indices.contains(index), let data = thumbnails[frames[index].id],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        if decoded.count >= 96 {
            for key in decoded.keys where abs(key - index) > 24 && key != 0 { decoded[key] = nil }
        }
        decoded[index] = image
        return image
    }

    /// Plays the video's frames at its rate, showing the photo each frame shows most: a burst runs at the series' pace
    /// when the timing follows capture time. A Live Photo with Bounce plays forward and back.
    private func play() {
        guard frames.count > 1, let plan, plan.frames.count > 1 else { playing = false; return }
        let order = output == .livePhoto ? TimelapseLivePhoto.frames(count: plan.frames.count, bounce: bounce) : Array(plan.frames.indices)
        var frame = order.firstIndex { plan.frames[$0].dominant >= index } ?? 0
        if index == frames.count - 1 && !(output == .livePhoto && bounce) { frame = 0 }
        playTask?.cancel()
        playTask = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while let self, self.playing, !Task.isCancelled, let plan = self.plan, !plan.frames.isEmpty {
                let order = self.output == .livePhoto ? TimelapseLivePhoto.frames(count: plan.frames.count, bounce: self.bounce) : Array(plan.frames.indices)
                frame = (frame + 1) % order.count
                deadline += .seconds(1.0 / max(1, self.settings.frameRate.rate))
                // Behind by more than a frame, drop the lost time instead of rushing to catch up.
                if deadline < clock.now { deadline = clock.now }
                try? await clock.sleep(until: deadline)
                guard self.playing, !Task.isCancelled else { return }
                let photo = plan.frames[order[frame]].dominant
                if self.frames.indices.contains(photo) && self.index != photo { self.index = photo }
            }
        }
    }
    private func stopPlaying() { playTask?.cancel(); playTask = nil; scheduleRender() }

    /// Renders the current frame from its original after playback or scrubbing has rested on it for a moment.
    private func scheduleRender() {
        let previous = renderTask
        renderTask?.cancel()
        let steady = steady
        let key = RenderKey(assetID: frames.indices.contains(index) ? frames[index].id : "", settings: settings, steady: steady?.frame(index))
        if rendered?.key != key { rendered = nil }
        guard mode == .video, !playing, stage == .ready, frames.indices.contains(index), let catalog, validationError == nil else { renderingFrame = false; return }
        if rendered?.key == key { return }
        let assets = frames, captures = captures, position = index, photo = photoSize, settings = settings
        // The preview needs no more pixels than the dialog shows, nor more than the video has.
        let output = outputSize, limit = 1600.0
        let fit = min(1, limit / max(output.width, output.height))
        let size = CGSize(width: max(2, (output.width * fit).rounded()), height: max(2, (output.height * fit).rounded()))
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            // A cancelled full RAW decode can take time to return. Do not pile up five-frame previews while scrubbing.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.renderingFrame = true; self.renderError = nil
            do {
                if settings.temporalDenoise && self.skyCache == nil { self.skyCache = try TimelapseSkyCache() }
                let image = try await catalog.timelapsePreview(assets, captures: captures, index: position, settings: settings,
                                                             photo: photo, size: size, skyCache: self.skyCache, steady: steady)
                guard !Task.isCancelled else { return }
                self.rendered = (image, key)
            } catch is CancellationError {
                return
            } catch { if !Task.isCancelled { self.renderError = error.localizedDescription } }
            if !Task.isCancelled { self.renderingFrame = false }
        }
    }

    func step(_ delta: Int) {
        guard !frames.isEmpty else { return }
        playing = false; selection = []
        index = min(frames.count - 1, max(0, index + delta))
        anchor = index
    }

    // MARK: Choosing the frames

    func isOffline(_ position: Int) -> Bool { frames.indices.contains(position) && offlineIDs.contains(frames[position].id) }

    /// A click in the filmstrip: moves the playhead there; ⌘ adds or takes the frame from the selection and ⇧ selects
    /// the frames from the last one clicked.
    func click(_ position: Int, toggling: Bool, extending: Bool) {
        guard frames.indices.contains(position) else { return }
        playing = false
        let id = frames[position].id
        if extending || toggling {
            // With nothing selected the current frame stands for the selection, so ⌘-click adds to it.
            var picked = MultiSelection(ids: selection.isEmpty && !extending && frames.indices.contains(index) ? [frames[index].id] : selection,
                                        anchor: frames.indices.contains(anchor) ? frames[anchor].id : nil)
            picked.click(id, in: frames.map(\.id), extending: extending, toggling: toggling)
            selection = picked.ids
            if let start = picked.anchor.flatMap({ start in frames.firstIndex { $0.id == start } }) { anchor = start }
        } else {
            // A plain click moves the playhead; no selection means the current frame.
            selection = []; anchor = position
        }
        index = position
    }

    /// What Remove takes out: the selection, or the current frame alone.
    var targets: Set<String> {
        if !selection.isEmpty { return selection }
        return frames.indices.contains(index) ? [frames[index].id] : []
    }
    /// A video needs two frames.
    func selectAll() { selection = Set(frames.map(\.id)) }
    func canRemove(_ ids: Set<String>) -> Bool { stage == .ready && !ids.isEmpty && frames.count - ids.count >= 2 }
    func remove(_ ids: Set<String>) {
        guard canRemove(ids) else { return }
        let current = frames.indices.contains(index) ? frames[index].id : nil
        removed.formUnion(ids); selection.subtract(ids)
        rebuild(keeping: current)
    }
    func restoreRemoved() {
        let current = frames.indices.contains(index) ? frames[index].id : nil
        removed = []
        rebuild(keeping: current)
    }

    /// What can be wrong with a frame, in the order the filmstrip sums them up.
    enum Problem: CaseIterable, Hashable {
        case offline, missingTime, sameTime, otherCamera, otherSize, unaligned, cameraMoved
        /// Stabilize couldn't measure it, or it moved further than a tripod drifts.
        case unsteadied
        /// Shot sooner or later than the steady interval: a burst, or the frame after a pause.
        case pace
        var title: String {
            switch self {
            case .offline: return L10n.tr("Offline")
            case .missingTime: return L10n.tr("No capture time")
            case .sameTime: return L10n.tr("Repeats")
            case .otherCamera: return L10n.tr("Other camera")
            case .otherSize: return L10n.tr("Other size")
            case .unaligned: return L10n.tr("Out of line")
            case .cameraMoved: return L10n.tr("Camera moved")
            case .unsteadied: return L10n.tr("Not stabilized")
            case .pace: return L10n.tr("Off pace")
            }
        }
        /// How many frames have it, saying what they are.
        func count(_ count: Int) -> String {
            let one = count == 1
            switch self {
            case .offline: return one ? L10n.tr("1 offline photo") : L10n.tr("\(count) offline photos")
            case .missingTime: return one ? L10n.tr("1 photo without capture time") : L10n.tr("\(count) photos without capture time")
            case .sameTime: return one ? L10n.tr("1 repeat") : L10n.tr("\(count) repeats")
            case .otherCamera: return one ? L10n.tr("1 photo from another camera") : L10n.tr("\(count) photos from another camera")
            case .otherSize: return one ? L10n.tr("1 photo of another size") : L10n.tr("\(count) photos of another size")
            case .unaligned: return one ? L10n.tr("1 frame out of line") : L10n.tr("\(count) frames out of line")
            case .cameraMoved: return one ? L10n.tr("1 camera move") : L10n.tr("\(count) camera moves")
            case .unsteadied: return one ? L10n.tr("1 frame not stabilized") : L10n.tr("\(count) frames not stabilized")
            case .pace: return one ? L10n.tr("1 photo off pace") : L10n.tr("\(count) photos off pace")
            }
        }
        /// Something wrong with the photo itself, which Remove Flagged takes out. Pace is left to the timing, and a
        /// camera that moved and stayed is not undone by removing the frame after it.
        var removable: Bool { ![.pace, .cameraMoved].contains(self) }
    }

    /// A pause counts on the frame after it.
    func problems(at position: Int) -> [Problem] {
        var problems: [Problem] = []
        if isOffline(position) { problems.append(.offline) }
        if let marks = series?.marks, marks.indices.contains(position) {
            for mark in marks[position] {
                switch mark {
                case .missingTime: problems.append(.missingTime)
                case .sameTime: problems.append(.sameTime)
                case .otherCamera: problems.append(.otherCamera)
                case .otherSize: problems.append(.otherSize)
                case .faster, .afterGap: problems.append(.pace)
                }
            }
        }
        if let steady, steady.shifts.indices.contains(position) {
            // A frame Stabilize moves back is out of line no longer.
            if steady.shifts[position] == nil { problems.append(.unsteadied) }
            else if alignment.indices.contains(position), alignment[position] != nil, steady.followedSky {
                problems.append(alignment[position] == .unaligned ? .unaligned : .cameraMoved)
            }
        } else if alignment.indices.contains(position), let mark = alignment[position] { problems.append(mark == .unaligned ? .unaligned : .cameraMoved) }
        return Problem.allCases.filter(problems.contains)
    }
    /// Each problem the series has, with its frames.
    var problemFrames: [(problem: Problem, positions: [Int])] {
        var found: [Problem: [Int]] = [:]
        for position in frames.indices { for problem in problems(at: position) { found[problem, default: []].append(position) } }
        return Problem.allCases.compactMap { problem in found[problem].map { (problem, $0) } }
    }
    /// Selects a problem's frames and shows the first.
    func select(_ problem: Problem) { show(frames.indices.filter { problems(at: $0).contains(problem) }) }

    var faulty: Set<String> { Set(frames.indices.filter { problems(at: $0).contains(where: \.removable) }.map { frames[$0].id }) }
    /// Takes out every faulty frame at once; Restore brings them back.
    func removeFaulty() { remove(faulty) }

    private func updatePlan() {
        guard stage == .ready || !captures.isEmpty else { plan = nil; planError = nil; return }
        do { plan = try TimelapsePlan(settings: settings, captures: captures, interval: series?.interval); planError = nil }
        catch { plan = nil; planError = error.localizedDescription }
    }

    /// Registers each frame on the one before from the thumbnails, off the main actor, measuring only pairs not seen
    /// before.
    private func measureAlignment() {
        alignTask?.cancel()
        let ids = frames.map(\.id), thumbnails = thumbnails, known = shifts
        guard ids.count >= 3 else { alignment = []; aligning = false; return }
        aligning = true
        alignTask = Task { [weak self] in
            let measured = await Task.detached(priority: .utility) { () -> [String: CGVector?] in
                var measured: [String: CGVector?] = [:], images: [String: CGImage] = [:]
                func image(_ id: String) -> CGImage? {
                    if let cached = images[id] { return cached }
                    let made = thumbnails[id].flatMap(TimelapseAlignment.image)
                    images[id] = made
                    return made
                }
                for (previous, next) in zip(ids, ids.dropFirst()) {
                    let key = previous + ">" + next
                    if known[key] != nil || Task.isCancelled { continue }
                    guard let a = image(previous), let b = image(next) else { measured[key] = .some(nil); continue }
                    measured[key] = .some(TimelapseAlignment.shift(from: a, to: b))
                    // Only the two newest decodes are needed again.
                    if images.count > 4 { images = images.filter { $0.key == next } }
                }
                return measured
            }.value
            guard let self, !Task.isCancelled else { return }
            self.shifts.merge(measured) { $1 }
            let steps = [CGVector?.some(.zero)] + zip(ids, ids.dropFirst()).map { self.shifts[$0 + ">" + $1] ?? nil }
            self.alignment = TimelapseAlignment.marks(steps)
            self.aligning = false
        }
    }
    /// Measures each kept frame's drift from the thumbnails, off the main actor, while Stabilize is on.
    private func measureStabilization() {
        stabilizeTask?.cancel()
        stabilization = nil
        guard settings.stabilize, frames.count >= 2 else { stabilizing = false; return }
        stabilizing = true
        let found = frames.map { thumbnails[$0.id] }, times = captures.map(\.date)
        stabilizeTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> TimelapseStabilization? in
                let result = TimelapseStabilizer.stabilize(thumbnails: found, times: times, isCancelled: { Task.isCancelled })
                return Task.isCancelled ? nil : result
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.stabilization = result
            self.stabilizing = false
        }
    }
    private func show(_ positions: [Int]) {
        guard let first = positions.first else { return }
        playing = false
        selection = Set(positions.map { frames[$0].id })
        anchor = first; index = first
    }

    /// Reads the kept photos as a series again, and keeps the playhead on `current`, or where it was when that photo
    /// went.
    private func rebuild(keeping current: String?) {
        let kept = all.filter { !removed.contains($0.asset.id) }
        let series = TimelapseSeries(kept.map(\.capture))
        frames = series.order.map { kept[$0].asset }
        captures = series.order.map { kept[$0].capture }
        self.series = series
        offline = frames.filter { offlineIDs.contains($0.id) }.map(\.filename)
        decoded = [:]
        // Neighbor membership changes the denoised preview even when the current photo and settings do not.
        rendered = nil
        alignment = []
        updatePlan()
        measureAlignment()
        measureStabilization()
        var position = 0
        if let current {
            if let kept = frames.firstIndex(where: { $0.id == current }) { position = kept }
            else if let gone = all.firstIndex(where: { $0.asset.id == current }) { position = all[..<gone].filter { !removed.contains($0.asset.id) }.count }
        }
        position = min(max(0, frames.count - 1), position)
        anchor = position
        if index != position { index = position } else { thumbnail = image(at: index); scheduleRender() }
    }

    func create(catalog: CatalogModel) {
        guard canCreate else { return }
        playing = false
        if output == .livePhoto {
            Task {
                guard await catalog.canAddToPhotos(), canCreate, let plan else { return }
                catalog.startTimelapseLivePhoto(frames, captures: captures, plan: plan, settings: settings, photo: photoSize, key: keyPosition, bounce: bounce,
                                                steady: steady)
                keepLatent(catalog: catalog, output: true)
                close(catalog: catalog)
            }
            return
        }
        Task {
            guard let url = await catalog.chooseTimelapseDestination(first: frames.first, settings: settings), canCreate, let plan else { return }
            catalog.startTimelapse(frames, captures: captures, plan: plan, settings: settings, photo: photoSize,
                                  metadata: TimelapseMetadata(captures), skyCache: skyCache, steady: steady, to: url)
            keepLatent(catalog: catalog, output: true)
            close(catalog: catalog)
        }
    }
    func close(catalog: CatalogModel) {
        keepLatent(catalog: catalog, output: false)
        stop()
        catalog.timelapse = nil
    }

}

extension TimelapseOutput {
    /// Each output remembers its own settings.
    var preferenceKey: String { self == .video ? "timelapseSettings" : "livePhotoSettings" }
    /// A Live Photo starts at 30 fps in the photo's own proportions, as an iPhone's does.
    var defaults: TimelapseSettings {
        var settings = TimelapseSettings()
        if self == .livePhoto { settings.framesPerSecond = 30; settings.aspect = .original }
        return settings
    }
}
