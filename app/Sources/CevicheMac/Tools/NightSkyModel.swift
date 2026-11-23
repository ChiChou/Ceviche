import SwiftUI
import AppKit
import CevicheCore

/// The options every tool shares: what counts as sky, and the areas painted to come from one photo.
protocol NightSkyEditableSettings {
    var skyEdge: Int { get set }
    var allSky: Bool { get set }
    var skyStrokes: [NightSkyStroke] { get set }
    var photoRegions: [NightSkyStroke] { get set }
}

/// What dragging over the preview paints.
enum NightSkyBrushMode: Hashable {
    case addSky, removeSky, photo
    /// The `sky` its dabs carry: nil for areas from one photo.
    var sky: Bool? { switch self { case .addSky: true; case .removeSky: false; case .photo: nil } }
}

/// The retouching undo and redo step through: the sky's corrections and the areas from one photo.
struct NightSkyRetouch: Equatable {
    var skyEdge: Int, allSky: Bool, skyStrokes: [NightSkyStroke], photoRegions: [NightSkyStroke]
}

extension NightSkyEditableSettings {
    var retouch: NightSkyRetouch {
        get { NightSkyRetouch(skyEdge: skyEdge, allSky: allSky, skyStrokes: skyStrokes, photoRegions: photoRegions) }
        set { skyEdge = newValue.skyEdge; allSky = newValue.allSky; skyStrokes = newValue.skyStrokes; photoRegions = newValue.photoRegions }
    }
}

/// A tool window's retouching history, a step per brush stroke or toolbar change; Edit › Undo and Redo use it while
/// the tool fills the window.
@MainActor
final class NightSkyHistory: ObservableObject {
    @Published private(set) var undoStack: [NightSkyRetouch] = []
    @Published private(set) var redoStack: [NightSkyRetouch] = []
    /// The model's current retouching, and how it takes one back.
    var current: () -> NightSkyRetouch? = { nil }
    var apply: (NightSkyRetouch) -> Void = { _ in }
    private(set) var applying = false
    private var lastEdgeChange: Date?

    /// Records the retouching as it was before a change. A Sky Edge drag is one step: edge changes in quick succession
    /// join the first.
    func record(_ old: NightSkyRetouch, now new: NightSkyRetouch) {
        let edgeOnly = NightSkyRetouch(skyEdge: new.skyEdge, allSky: old.allSky, skyStrokes: old.skyStrokes, photoRegions: old.photoRegions) == new
        defer { lastEdgeChange = edgeOnly ? Date() : nil }
        redoStack = []
        if edgeOnly, let lastEdgeChange, Date().timeIntervalSince(lastEdgeChange) < 1 { return }
        undoStack.append(old)
    }
    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }
    private func step(from: inout [NightSkyRetouch], to: inout [NightSkyRetouch]) {
        guard let current = current(), let target = from.popLast() else { return }
        to.append(current); lastEdgeChange = nil
        applying = true; apply(target); applying = false
    }
}

extension StarTrailsSettings: NightSkyEditableSettings {}

extension NightSkyDenoiseSettings: NightSkyEditableSettings {}

extension MeteorShowerSettings: NightSkyEditableSettings {}

/// What the window needs from a night-sky tool's merger.
protocol NightSkyWorkflow: AnyObject, Sendable {
    associatedtype Settings: Codable & Equatable & Sendable & NightSkyEditableSettings
    associatedtype Analysis: Sendable
    init(urls: [URL]) throws
    var urls: [URL] { get }
    func analyze(allSky: Bool, skyStrokes: [NightSkyStroke], progress: @escaping @Sendable (Double, String) -> Void) throws -> Analysis
    func saveAnalysis(to directory: URL) throws
    func restoreAnalysis(from directory: URL, progress: @escaping @Sendable (Double, String) -> Void) throws -> Analysis
    func analysisSnapshot() throws -> Data
    func reuse(_ snapshot: Data) throws -> Analysis
    func preview(_ settings: Settings) throws -> NightSkyPreview
    func merge(_ settings: Settings, to url: URL, progress: @escaping @Sendable (Double, String) -> Void) throws
    /// The options to keep after analyzing again found `new` where `old` was found.
    static func settings(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Settings
    /// Whether keeping `new` would turn down lines chosen by hand in `old`.
    static func losesChoices(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Bool
}

extension NightSkyWorkflow {
    static func settings(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Settings { settings }
    static func losesChoices(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Bool { false }
}

/// An analysis that finds lines, which a tool's options can choose by id.
protocol NightSkyLineAnalysis { var lines: [NightSkyLineInfo] { get } }

extension StarTrailsAnalysis: NightSkyLineAnalysis {}

extension MeteorShowerAnalysis: NightSkyLineAnalysis {}

extension NightSkyWorkflow where Settings: NightSkyLineChoosing, Analysis: NightSkyLineAnalysis {
    /// Lines chosen by hand stay chosen only if the same lines were found again.
    static func settings(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Settings {
        var settings = settings
        settings.keepChoices(from: old.lines, to: new.lines)
        return settings
    }
    static func losesChoices(_ settings: Settings, reanalyzed old: Analysis, as new: Analysis) -> Bool {
        settings.losesChoices(from: old.lines, to: new.lines)
    }
}

extension StarTrailsMerger: NightSkyWorkflow {}

extension NightSkyDenoiser: NightSkyWorkflow {}

extension MeteorShowerMerger: NightSkyWorkflow {}

/// Analyzes the sequence once, then redraws the preview from that analysis as the options change.
@MainActor
final class NightSkyModel<Workflow: NightSkyWorkflow>: ObservableObject {
    /// `unstackable` waits for the photos that can't be stacked with the rest to be left out.
    enum Stage: Equatable { case preparing(String, Double?), unstackable, ready, failed(String) }

    let request: NightSkyRequest
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var analysis: Workflow.Analysis?
    @Published private(set) var preview: NightSkyPreview?
    /// Photos of another kind, camera or size than the rest, with why; analysis waits until they are left out.
    @Published private(set) var unstackable: [(asset: CatalogAsset, url: URL, reason: String)] = []
    private var configure: ((Workflow.Analysis, inout Workflow.Settings) -> Void)?
    /// The request's originals in capture order, while some wait to be left out.
    private var urls: [URL] = []
    private var sourceReferences: [URL: LatentImage.Source] = [:]
    private var latent: LatentImage?
    private var latentURL: URL?
    private var latentAssetID: String?
    private var analysisNeedsSaving = true
    /// How many of the request's photos the tool works with: all, less any left out for not stacking with the rest.
    private(set) var photoCount = 0
    @Published private(set) var rendering = false
    @Published private(set) var closing = false
    @Published private(set) var previewError: String?
    /// Why the latent image couldn't be saved; the preview and Create still work.
    @Published private(set) var saveError: String?
    @Published var settings: Workflow.Settings {
        didSet {
            guard settings != oldValue else { return }
            if stage == .ready, !history.applying, settings.retouch != oldValue.retouch { history.record(oldValue.retouch, now: settings.retouch) }
            render()
        }
    }
    let history = NightSkyHistory()
    /// Tints what the tool treats as sky over the preview.
    @Published var presentation: Data? {
        didSet { if presentation != oldValue { scheduleSave() } }
    }
    @Published var showSky = false { didSet { if !showSky, brush?.sky != nil { brush = nil } } }
    /// What dragging over the preview paints, if anything. The sky brushes show the sky, which they change.
    @Published var brush: NightSkyBrushMode? { didSet { if brush?.sky != nil { showSky = true } } }
    /// The brush's width on screen in points.
    @Published var brushDiameter: Double { didSet { preferences.set(brushDiameter, forKey: "nightSkyBrushDiameter") } }
    private(set) var workflow: Workflow?
    private var access: [URL] = []
    /// The photo each original belongs to: the result takes the edits of the photo it is based on.
    private var assetsByURL: [URL: CatalogAsset] = [:]
    private weak var catalog: CatalogModel?
    private var latentStore: CatalogStore?
    /// Per base photo, the development the result takes, worked out on the first preview from it; nil inside for none.
    private var developments: [Int: Adjustments?] = [:]
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Something changed since the latent image was last saved.
    private var saveNeeded = false
    private let preferences = UserDefaults.standard

    init(request: NightSkyRequest, settings: Workflow.Settings) {
        self.request = request
        self.settings = settings
        photoCount = request.assets.count
        let diameter = preferences.double(forKey: "nightSkyBrushDiameter")
        brushDiameter = diameter > 0 ? NightSkyBrushSize.clamped(diameter) : 60
        history.current = { [weak self] in self?.settings.retouch }
        history.apply = { [weak self] in self?.settings.retouch = $0 }
    }
    var canMerge: Bool { stage == .ready && preview != nil && previewError == nil && !rendering }
    /// The sky corrections the stars were last found and aligned with.
    private var alignedSky: (allSky: Bool, strokes: [NightSkyStroke]) = (false, [])
    /// Whether the sky was corrected since the stars were aligned, so aligning again would use it.
    var skyChangedSinceAligning: Bool {
        settings.allSky != alignedSky.allSky || settings.skyStrokes.filter { $0.sky != nil } != alignedSky.strokes
    }

    /// Analyzes, then lets `configure` set the first options from what analysis found.
    func start(catalog: CatalogModel, configure: @escaping (Workflow.Analysis, inout Workflow.Settings) -> Void) {
        guard task == nil else { return }
        self.catalog = catalog
        latentStore = catalog.store
        catalog.nightSkyHistory = history
        self.configure = configure
        task = Task {
            do {
                var urls: [URL] = []
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url); assetsByURL[url] = asset
                }
                if let bundle = request.latentURL {
                    let latent = try await Task.detached(priority: .utility) { try LatentImage.load(bundle) }.value
                    let originals = urls
                    sourceReferences = Dictionary(uniqueKeysWithValues: zip(originals, latent.sources))
                    let workflow = try Workflow(urls: urls)
                    stage = .preparing(L10n.tr("Creating preview…"), 0)
                    let progress: @Sendable (Double, String) -> Void = { fraction, _ in
                        Task { @MainActor in
                            guard case .preparing = self.stage else { return }
                            self.stage = .preparing(L10n.tr("Creating preview…"), fraction)
                        }
                    }
                    try await Task.detached(priority: .userInitiated) {
                        for (source, url) in zip(latent.sources, originals) { try source.validate(url) }
                    }.value
                    // Only the preview copies are decoded again; what analysis found comes from the latent image. Saved
                    // results this build can't use (damaged, or from an older analysis) are found again from the
                    // photos, all of which are here, and saved with the next change.
                    let work = Task.detached(priority: .userInitiated) {
                        try workflow.restoreAnalysis(from: latent.analysisURL(in: bundle), progress: progress)
                    }
                    let restored: Workflow.Analysis?
                    do { restored = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
                    catch is CancellationError { throw CancellationError() }
                    catch { restored = nil }
                    let saved = try JSONDecoder().decode(Workflow.Settings.self, from: latent.settings)
                    let analysis: Workflow.Analysis
                    if let restored { analysis = restored } else {
                        // Found with the saved sky corrections.
                        self.settings = saved
                        analysis = try await analyze(workflow)
                    }
                    self.latent = latent; self.latentURL = bundle; self.latentAssetID = request.latentAssetID
                    self.analysisNeedsSaving = restored == nil
                    self.presentation = latent.presentation
                    self.analysis = analysis
                    if restored != nil { self.alignedSky = (latent.alignedAllSky, latent.alignedStrokes) }
                    self.settings = saved
                    self.workflow = workflow
                    render(immediately: true)
                    return
                }
                let originals = urls, sourceAssets = request.assets
                sourceReferences = try await Task.detached(priority: .utility) {
                    try Dictionary(uniqueKeysWithValues: zip(originals, sourceAssets).map { url, asset in
                        (url, try LatentImage.Source(assetID: asset.id, url: url))
                    })
                }.value
                let reasons = try await Task.detached(priority: .userInitiated) { try NightSkyPhotos.unstackable(urls) }.value
                if !reasons.isEmpty {
                    self.urls = urls
                    unstackable = reasons.keys.sorted().map { (request.assets[$0], urls[$0], reasons[$0]!) }
                    stage = .unstackable
                    return
                }
                try await begin(urls)
            } catch is CancellationError {
            } catch { abort(error.localizedDescription) }
        }
    }

    /// Leaves out the photos that can't be stacked with the rest and analyzes the others.
    func leaveOutUnstackable() {
        guard stage == .unstackable else { return }
        let out = Set(unstackable.map(\.url))
        for url in access where out.contains(url) { url.stopAccessingSecurityScopedResource() }
        access.removeAll { out.contains($0) }
        let urls = self.urls.filter { !out.contains($0) }
        for url in out { assetsByURL[url] = nil }
        unstackable = []
        photoCount = urls.count
        guard urls.count >= request.tool.minimumCount else { abort(L10n.tr("Too few photos are left to combine.")); return }
        stage = .preparing(L10n.tr("Reading photos…"), nil)
        task = Task {
            do { try await begin(urls) } catch is CancellationError {
            } catch { abort(error.localizedDescription) }
        }
    }

    private func begin(_ urls: [URL]) async throws {
        let workflow = try Workflow(urls: urls)
        let analysis = try await analyze(workflow)
        self.workflow = workflow
        self.analysis = analysis
        var settings = self.settings
        configure?(analysis, &settings)
        stage = .preparing(L10n.tr("Creating preview…"), nil)
        if settings != self.settings { self.settings = settings } else { render(immediately: true) }
    }

    /// Finds and aligns the stars again with the corrected sky, keeping the options.
    func alignAgain() {
        guard stage == .ready, let workflow else { return }
        task?.cancel(); renderTask?.cancel()
        let previous = renderTask
        stage = .preparing(L10n.tr("Analyzing the sky…"), 0)
        task = Task {
            do {
                await previous?.value
                // What was found before, a few MB, to take back if the new lines would turn down the hand choices.
                let snapshot = try await Task.detached(priority: .userInitiated) { try workflow.analysisSnapshot() }.value
                let old = analysis, oldSky = alignedSky, new = try await analyze(workflow)
                if let old, Workflow.losesChoices(settings, reanalyzed: old, as: new) {
                    lineChange = (old, new, snapshot, oldSky)
                    return
                }
                accept(new, replacing: old)
            } catch is CancellationError {
            } catch { stage = .failed(error.localizedDescription) }
        }
    }

    /// Other lines were found by aligning again while some were chosen by hand: the window asks which to keep.
    var askingAboutLines: Bool { lineChange != nil }
    @Published private var lineChange: (old: Workflow.Analysis, new: Workflow.Analysis, snapshot: Data, sky: (allSky: Bool, strokes: [NightSkyStroke]))?

    /// Takes the lines just found; the hand choices go.
    func useNewLines() {
        guard let change = lineChange else { return }
        lineChange = nil
        accept(change.new, replacing: change.old)
    }

    /// Goes back to the lines found before, with their choices, using the preview copies already made.
    func keepPreviousLines() {
        guard let change = lineChange, let workflow else { return }
        lineChange = nil
        task = Task {
            do {
                let analysis = try await Task.detached(priority: .userInitiated) { try workflow.reuse(change.snapshot) }.value
                self.analysis = analysis
                alignedSky = change.sky
                stage = .preparing(L10n.tr("Creating preview…"), nil)
                render(immediately: true)
            } catch is CancellationError {
            } catch { stage = .failed(error.localizedDescription) }
        }
    }

    private func accept(_ new: Workflow.Analysis, replacing old: Workflow.Analysis?) {
        analysisNeedsSaving = true
        analysis = new
        if let old { settings = Workflow.settings(settings, reanalyzed: old, as: new) }
        stage = .preparing(L10n.tr("Creating preview…"), nil)
        render(immediately: true)
    }

    private func analyze(_ workflow: Workflow) async throws -> Workflow.Analysis {
        let progress: @Sendable (Double, String) -> Void = { fraction, message in
            Task { @MainActor in
                guard case .preparing = self.stage else { return }
                self.stage = .preparing(message.isEmpty ? L10n.tr("Analyzing the sky…") : message, fraction)
            }
        }
        let sky = (allSky: settings.allSky, strokes: settings.skyStrokes.filter { $0.sky != nil })
        let work = Task.detached(priority: .userInitiated) { try workflow.analyze(allSky: sky.allSky, skyStrokes: sky.strokes, progress: progress) }
        let analysis = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        alignedSky = sky
        return analysis
    }

    /// Draws the preview for the current options. Renders run one at a time; a newer request replaces a waiting one.
    func render(immediately: Bool = false) {
        guard workflow != nil else { return }
        rendering = true
        let previous = renderTask
        previous?.cancel()
        let settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            if !immediately { try? await Task.sleep(for: .milliseconds(40)) }
            guard !Task.isCancelled, let self, let workflow = self.workflow else { return }
            self.rendering = true
            let result = await Task.detached(priority: .userInitiated) { Result { try workflow.preview(settings) } }.value
            guard !Task.isCancelled else { return }
            let developed = if case .success(let preview) = result { await self.developed(preview) } else { nil as NightSkyPreview? }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let preview):
                self.preview = developed ?? preview; self.previewError = nil
                // With Keep Latent Image ticked, the first preview creates the latent image at once; later edits save
                // once they settle.
                self.scheduleSave(immediately: self.latent == nil)
            case .failure(let error): self.previewError = error.localizedDescription
            }
            self.rendering = false
            if case .preparing = self.stage { self.stage = .ready }
        }
    }

    /// `preview` developed as the result will be: with the base photo's edits. It stays as drawn when the photo has none,
    /// or when developing fails.
    func developed(_ preview: NightSkyPreview) async -> NightSkyPreview {
        guard let catalog, let workflow, preview.base < workflow.urls.count, let asset = assetsByURL[workflow.urls[preview.base]],
              developments[preview.base] != .some(nil) else { return preview }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Night Sky Preview \(UUID().uuidString).\(preview.fileExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let renderer = try await Task.detached(priority: .userInitiated) { try preview.write(to: file); return try RawRenderer(sourceURL: file) }.value
            let edit: Adjustments
            if let known = developments[preview.base], let known { edit = known } else {
                let found = try await catalog.mergeDevelopment(from: asset, onto: renderer)
                developments[preview.base] = .some(found)
                guard let found else { return preview }
                edit = found
            }
            var result = preview
            result.image = try await renderer.displayImage(edit, maxDimension: Double(max(preview.image.width, preview.image.height)), sdr: true)
            return result
        } catch { return preview }
    }

    /// Hands the merge to the catalog's background jobs; the originals stay open until it finishes.
    /// Processed photos are kept as `format` asks; RAW photos give a DNG.
    func merge(catalog: CatalogModel, beside: Int, count: Int, format: ProcessedFormat = .original) {
        guard canMerge, let workflow else { return }
        let access = self.access, settings = self.settings, sources = sourceReferences
        self.access = []
        catalog.startNightSky(request.tool, beside: workflow.urls[beside], editsFrom: assetsByURL[workflow.urls[beside]], count: count,
                              access: access, format: format) { url, progress in
            for sourceURL in workflow.urls { try sources[sourceURL]?.validate(sourceURL) }
            try workflow.merge(settings, to: url, progress: progress)
        }
        close(catalog: catalog)
    }

    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(_ message: String) {
        guard let catalog else { stage = .failed(message); return }
        close(catalog: catalog)
        catalog.failure = Failure(L10n.tr("Can’t Combine These Photos"), message)
    }
    func close(catalog: CatalogModel) {
        guard !closing else { return }
        closing = true
        // Finish the last edit's save before releasing the tool. Preparation can still be cancelled.
        if analysis != nil {
            Task {
                await renderTask?.value
                if saveNeeded { scheduleSave(immediately: true) }
                await saveTask?.value
                if let error = saveError ?? previewError { catalog.error = error }
                stop(); catalog.nightSky = nil; catalog.nightSkyHistory = nil
            }
        } else {
            stop(); catalog.nightSky = nil; catalog.nightSkyHistory = nil
        }
    }

    /// Opened from a latent image, which it keeps up to date without asking.
    var opensLatent: Bool { request.latentURL != nil }
    /// Keep Latent Image is ticked for this tool, or the window already has a latent image to keep up to date.
    private var keepsLatent: Bool { latentURL != nil || LatentPreference.keeps(request.tool.rawValue) }
    /// Keep Latent Image was just ticked: saves now, analysis and all.
    func latentTicked() { scheduleSave(immediately: true) }

    /// Saves the latent image once edits pause, when it is kept. Saves run one at a time, each with the options current
    /// when it starts.
    private func scheduleSave(immediately: Bool = false) {
        guard workflow != nil, preview != nil, keepsLatent else { return }
        saveNeeded = true
        let previous = saveTask
        previous?.cancel()
        saveTask = Task { [weak self] in
            await previous?.value
            if !immediately { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled, let self, let workflow = self.workflow, let preview = self.preview else { return }
            self.saveNeeded = false
            do {
                try await self.saveLatent(settings: self.settings, presentation: self.presentation, preview: preview, workflow: workflow)
                self.saveError = nil
            } catch is CancellationError {
            } catch {
                self.saveNeeded = true
                self.saveError = error.localizedDescription
            }
        }
    }

    private func saveLatent(settings: Workflow.Settings, presentation: Data?, preview: NightSkyPreview, workflow: Workflow) async throws {
        guard let catalog, let store = latentStore, catalog.store === store else { throw CancellationError() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Object \(UUID().uuidString)")
        let stem = workflow.urls[0].deletingPathExtension().lastPathComponent
        let bundle = latentURL ?? temporary.appendingPathComponent("\(stem)-\(request.tool.rawValue).cevichelatent")
        let isNew = latentURL == nil
        defer { if isNew { try? FileManager.default.removeItem(at: temporary) } }
        let analysisID = analysisNeedsSaving ? UUID().uuidString : latent!.analysisID
        let sources = try workflow.urls.map { url -> LatentImage.Source in
            guard let source = sourceReferences[url] else { throw LatentImage.invalid() }
            return source
        }
        var saved = LatentImage(type: request.tool.rawValue, id: latent?.id ?? UUID().uuidString, catalogID: store.manifest.id,
                                  sources: sources, settings: try JSONEncoder().encode(settings), analysisID: analysisID,
                                  width: assetsByURL[workflow.urls[0]]?.info.width ?? preview.image.width, height: assetsByURL[workflow.urls[0]]?.info.height ?? preview.image.height,
                                  alignedAllSky: alignedSky.allSky, alignedStrokes: alignedSky.strokes)
        saved.presentation = presentation
        let snapshot = saved
        let needsAnalysis = analysisNeedsSaving
        let originals = workflow.urls
        let pictures = try await Task.detached(priority: .utility) {
            if needsAnalysis {
                for (source, url) in zip(sources, originals) { try source.validate(url) }
                try workflow.saveAnalysis(to: snapshot.analysisURL(in: bundle))
            }
            let pictures = try LatentImage.pictures(preview.image)
            try snapshot.save(to: bundle, pictures: pictures)
            return pictures
        }.value
        let thumbnail = pictures.thumbnail
        if isNew {
            var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
            options.objectCaptureDay = request.assets.map(\.captureDay).max()
            var prepared = try await Task.detached(priority: .utility) { [options] in try CatalogImporter.prepareLatent(bundle, options: options) }.value
            prepared.0.captureTime = request.assets.compactMap(\.captureTime).max()
            let asset = try await store.insertCompletedOutput(prepared.0, thumbnail: thumbnail)
            latentAssetID = asset.id; latentURL = CatalogImporter.sourceURL(for: asset, root: store.root)
        } else if let id = latentAssetID {
            if latent?.settings != saved.settings || latent?.presentation != saved.presentation || latent?.analysisID != saved.analysisID {
                try await store.updateLatent(assetID: id, thumbnail: thumbnail)
            } else {
                try await store.installThumbnail(thumbnail, assetID: id, renderKey: store.asset(id).renderKey)
            }
        }
        // Only the manifest's analysis is ever read; earlier ones (from Align Again) are gigabytes of dead weight.
        if needsAnalysis, let previous = latent?.analysisID, previous != analysisID, UUID(uuidString: previous) != nil, let current = latentURL {
            try? FileManager.default.removeItem(at: current.appendingPathComponent(previous, isDirectory: true))
        }
        latent = saved; analysisNeedsSaving = false
        if catalog.store === store { await catalog.refresh(); catalog.syncSoon() }
    }

    /// Ends the analysis and releases the originals; also when the catalog closes the window from outside.
    func stop() {
        task?.cancel(); renderTask?.cancel(); saveTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }
}

extension NightSkyModel where Workflow == StarTrailsMerger {
    /// Hands the video of `included` photos to the catalog's background jobs, developed as the preview is.
    func createVideo(catalog: CatalogModel, beside: Int, included: [Int], settings video: TimelapseSettings, trails: StarTrailsVideoTrails, glow: StarTrailsVideoGlow,
                     meteorFade: StarTrailsMeteorFade?) {
        guard canMerge, let workflow, included.first != nil else { return }
        Task {
            // The panel may stay open a while on iPad, so check the tool is still ready once it closes.
            guard let url = await catalog.chooseTimelapseDestination(first: assetsByURL[workflow.urls[beside]], settings: video, suffix: "StarTrails",
                                                                   prompt: L10n.tr("Render Video")),
                  canMerge, let workflow = self.workflow, let analysis, let preview, let first = included.first else { return }
            startVideo(catalog: catalog, workflow: workflow, analysis: analysis, preview: preview, first: first, included: included,
                       settings: video, trails: trails, glow: glow, meteorFade: meteorFade, to: url)
        }
    }
    /// Hands a Live Photo of `included` photos to the catalog's background jobs, developed and framed as the video
    /// would be, then closes the tool.
    func createLivePhoto(catalog: CatalogModel, beside: Int, included: [Int], crop: TimelapseCrop, ratio: Double, size: LivePhotoSize, trails: StarTrailsVideoTrails,
                         glow: StarTrailsVideoGlow, meteorFade: StarTrailsMeteorFade?) {
        guard canMerge, included.count > 1 else { return }
        Task {
            // Asked while the tool is still open, so a refusal leaves it as it was.
            guard await catalog.canAddToPhotos(), canMerge, let workflow, let analysis, let preview else { return }
            let source = workflow.urls[beside], access = self.access
            self.access = []
            catalog.startStarTrailLivePhoto(workflow, settings: settings, trails: trails, glow: glow, meteorFade: meteorFade, crop: crop, ratio: ratio, size: size,
                                            photo: CGSize(width: analysis.width, height: analysis.height), frames: included.count,
                                            development: developments[preview.base] ?? nil, source: source,
                                            named: source.deletingPathExtension().lastPathComponent + "-StarTrails", access: access, pending: renderTask)
            close(catalog: catalog)
        }
    }
    private func startVideo(catalog: CatalogModel, workflow: StarTrailsMerger, analysis: StarTrailsMerger.Analysis, preview: NightSkyPreview, first: Int, included: [Int],
                            settings video: TimelapseSettings, trails: StarTrailsVideoTrails, glow: StarTrailsVideoGlow, meteorFade: StarTrailsMeteorFade?, to url: URL) {
        let metadata = video.includeMetadata ? TimelapseMetadata([TimelapseCapture.read(workflow.urls[first], filename: workflow.urls[first].lastPathComponent)]) : nil
        let access = self.access
        self.access = []
        catalog.startStarTrailVideo(workflow, settings: settings, trails: trails, glow: glow, meteorFade: meteorFade, video: video, photo: CGSize(width: analysis.width, height: analysis.height),
                                    frames: included.count, development: developments[preview.base] ?? nil, metadata: metadata,
                                    access: access, pending: renderTask, to: url)
        close(catalog: catalog)
    }
}
