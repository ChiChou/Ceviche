import SwiftUI
import AppKit
import CevicheCore
import UniformTypeIdentifiers

struct FiltersRequest: Identifiable {
    let id = UUID()
    let assets: [CatalogAsset]
    /// The latent image opened, with its photo as the one asset; its stack replaces the last one used.
    var latent: Latent?
    struct Latent { let assetID: String, stack: CreativeFilterStack }
}

/// Filters: a stack of photographic filters applied to the developed photo on the way out. The photo's development is
/// left alone; each output leaves a latent image per photo holding the stack, to open and export again.
extension CatalogModel {
    func canApplyFilters(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && !$0.isLatent }
    }
    func requestFilters(_ targets: [CatalogAsset]) {
        guard canApplyFilters(targets) else { return }
        filters = FiltersRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// Saves `stack` on each photo as a latent image, one after another in the background: into the one `kept` names
    /// for it, else a new one, which `kept` then names.
    func keepFilterLatents(_ assets: [CatalogAsset], stack: CreativeFilterStack, kept: @escaping @MainActor (String) -> String?,
                           saved: @escaping @MainActor (String, String) -> Void) {
        guard let store, !stack.isEmpty else { return }
        Task {
            for asset in assets {
                do { saved(asset.id, try await saveFilterLatent(asset, stack: stack, store: store, into: kept(asset.id))) }
                catch is CancellationError { return }
                catch { self.failure = Failure(L10n.tr("Couldn’t Keep the Latent Image"), error) }
            }
        }
    }

    /// Writes `stack` on `photo` into the latent image `into`, or into a new one filed in the catalog, with a thumbnail
    /// of the photo as it develops now. Returns the latent image's asset ID.
    @discardableResult
    func saveFilterLatent(_ photo: CatalogAsset, stack: CreativeFilterStack, store: CatalogStore, into latentAssetID: String?) async throws -> String {
        let url = try await resolveOriginal(photo)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let source = try LatentImage.Source(assetID: photo.id, url: url)
        let (renderer, defaults) = try await Task.detached(priority: .utility) { try RawRenderer.open(url) }.value
        let edits = try await store.savedAdjustments(of: await store.asset(photo.id)) ?? defaults
        var settings = ExportSettings(); settings.select(.tiff); settings.profile.preset = .displayP3
        let image = try await renderer.exportPreview(edits, settings: settings, maxDimension: 320, filters: stack)
        let size = try GeometryPlan(size: CGSize(width: renderer.info.width, height: renderer.info.height), settings: edits.geometry, quarterTurns: edits.quarterTurns).outputSize
        let latent = try LatentImage(catalogID: store.manifest.id, source: source, stack: stack,
                                     width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        return try await storeLatent(latent, pictures: try LatentImage.pictures(image), name: "\((photo.filename as NSString).deletingPathExtension)-Filters",
                                     sources: [photo], into: latentAssetID, store: store)
    }
}

@MainActor
final class FiltersModel: ObservableObject, ExportTarget {
    enum Stage: Equatable { case reading, ready, failed(String) }
    /// How the canvas sets the filtered picture against the photo.
    enum Compare: String, CaseIterable {
        case single, split, sideBySide
        var title: String {
            switch self {
            case .single: L10n.tr("Single")
            case .split: L10n.tr("Split")
            case .sideBySide: L10n.tr("Side by Side")
            }
        }
        var symbol: String {
            switch self {
            case .single: "rectangle"
            case .split: "rectangle.lefthalf.inset.filled"
            case .sideBySide: "rectangle.split.2x1"
            }
        }
    }
    static let outputKey = "filtersExportSettings"

    let request: FiltersRequest
    @Published private(set) var stage = Stage.reading
    @Published var selected = 0 { didSet { if selected != oldValue { open() } } }
    @Published var stack: CreativeFilterStack { didSet { if stack != oldValue { remember(); render() } } }
    @Published var compare: Compare { didSet { preferences.set(compare.rawValue, forKey: "filtersCompare") } }
    /// The card last clicked: ringed, and the one Delete takes out.
    @Published var selection: CreativeFilterKind?
    /// The cards folded to their titles.
    @Published var folded: Set<CreativeFilterKind> = []
    /// The Export dialog is up, over the tool.
    @Published var showingExport = false
    /// The file's own settings, as Export has them; noise reduction is the stack's.
    @Published var exportSettings: ExportSettings {
        didSet {
            guard exportSettings != oldValue else { return }
            exportSettings.rememberAsLastUsed(key: Self.outputKey)
            if Self.shows(exportSettings) != Self.shows(oldValue) { baseStale = true; render() }
        }
    }
    @Published var usesDevelopedProfile: Bool {
        didSet { if usesDevelopedProfile != oldValue { preferences.set(usesDevelopedProfile, forKey: "filtersDevelopedProfile"); baseStale = true; render() } }
    }
    @Published private(set) var recipes: [CreativeFilterRecipe]
    /// Each recipe on the photo now shown, small.
    @Published private(set) var thumbnails: [UUID: CGImage] = [:]
    @Published private(set) var before: CGImage?
    @Published private(set) var after: CGImage?
    @Published private(set) var rendering = false
    @Published private(set) var renderError: String?
    private var renderer: RawRenderer?
    private var edits: Adjustments?
    private var access: URL?
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// The unfiltered preview no longer matches the output settings.
    private var baseStale = false
    /// AI Noise Reduction's tiles on this photo's preview, and what they were run on.
    private var denoiseTiles: (input: CreativeFilterStack.DenoiseInput, run: DenoiseRun)?
    private weak var catalog: CatalogModel?
    private let preferences = UserDefaults.standard

    init(request: FiltersRequest) {
        self.request = request
        let preferences = UserDefaults.standard
        stack = request.latent?.stack ?? (preferences.data(forKey: "filtersStack").flatMap { try? JSONDecoder().decode(CreativeFilterStack.self, from: $0) }).flatMap { try? $0.validated() } ?? CreativeFilterStack()
        recipes = SavedList<CreativeFilterRecipe>(preferences.data(forKey: "filterRecipes")).items
        compare = preferences.string(forKey: "filtersCompare").flatMap(Compare.init(rawValue:)) ?? .single
        usesDevelopedProfile = preferences.object(forKey: "filtersDevelopedProfile") as? Bool ?? true
        // A filtered file starts as a master: a 16-bit TIFF at the photo's own size.
        var settings = ExportSettings.lastUsed(key: Self.outputKey) ?? {
            var settings = ExportSettings(); settings.select(.tiff); settings.quality = 1
            if settings.depths.contains(16) { settings.depth = 16 }
            return settings
        }()
        settings.setHDR(false); settings.aiDenoise = 0; settings.sizing.longEdge = nil; settings.sizing.frame = nil
        exportSettings = settings
        selection = stack.applied.first?.kind
    }

    var canApply: Bool { stage == .ready && !stack.isEmpty && renderError == nil && exportSettings.format.isAvailable && catalog?.canStartJob != false }
    var denoiseMissing: Bool { !BundledModel.denoise.isAvailable }
    var library: [CreativeFilterRecipe] { CreativeFilterRecipe.builtIn + recipes }
    /// True while the filter is switched on.
    func isOn(_ kind: CreativeFilterKind) -> Bool { stack.filters.contains { $0.kind == kind && $0.enabled } }
    /// True when the filters switched on are this recipe's, with its settings.
    func matches(_ recipe: CreativeFilterRecipe) -> Bool {
        let on = applied, wanted = recipe.stack.applied
        return on.count == wanted.count && zip(on, wanted).allSatisfy { var other = $1; other.id = $0.id; return $0 == other }
    }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        self.catalog = catalog
        open()
    }

    /// Develops the photo now chosen, for the preview.
    private func open() {
        task?.cancel(); renderTask?.cancel(); thumbnailTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
        before = nil; after = nil; renderer = nil; edits = nil; thumbnails = [:]; denoiseTiles = nil; stage = .reading
        guard let catalog, let store = catalog.store else { return }
        let asset = request.assets[selected]
        task = Task {
            guard let url = try? await catalog.resolveOriginal(asset) else { fail(L10n.tr("The original isn’t available.")); return }
            if url.startAccessingSecurityScopedResource() { access = url }
            do {
                let (renderer, defaults) = try await Task.detached(priority: .userInitiated) { try RawRenderer.open(url) }.value
                let edits = try await store.savedAdjustments(of: store.asset(asset.id)) ?? defaults
                guard !Task.isCancelled else { return }
                self.renderer = renderer; self.edits = edits
                exportSettings.sizing.updateSource(outputSize ?? .zero)
                before = try await renderer.exportPreview(edits, settings: previewSettings, maxDimension: 2200)
                baseStale = false; stage = .ready
                render()
                renderThumbnails(library)
            } catch is CancellationError {
            } catch { fail(error.localizedDescription) }
        }
    }
    /// What the file gets, less what a preview can't hold.
    private var outputSettings: ExportSettings {
        var settings = exportSettings; settings.hdr = false; settings.aiDenoise = 0
        if usesDevelopedProfile, let edits { settings.profile = edits.colorProfile }
        return settings
    }
    private var previewSettings: ExportSettings { outputSettings }
    /// The settings a preview shows: the rest only change the file.
    private struct Shown: Equatable { var profile: ColorProfile, sizing: ExportSizing, watermark: Watermark?, alpha: Bool }
    private static func shows(_ settings: ExportSettings) -> Shown {
        Shown(profile: settings.profile, sizing: settings.sizing, watermark: settings.watermark, alpha: settings.preserveAlpha && settings.format.supportsAlpha)
    }

    private func render() {
        renderTask?.cancel()
        guard let renderer, let edits, stage == .ready else { return }
        let stack = stack, settings = previewSettings, base = baseStale, denoise = denoiseRun(for: stack)
        guard base || !stack.isEmpty else { after = nil; renderError = nil; rendering = false; return }
        rendering = true
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(base ? 200 : 40))
            guard !Task.isCancelled else { return }
            do {
                if base {
                    let image = try await renderer.exportPreview(edits, settings: settings, maxDimension: 2200)
                    guard !Task.isCancelled else { return }
                    before = image; baseStale = false
                }
                let image = stack.isEmpty ? nil : try await renderer.exportPreview(edits, settings: settings, maxDimension: 2200, filters: stack, denoise: denoise)
                guard !Task.isCancelled else { return }
                after = image; renderError = nil
            } catch is CancellationError { return
            } catch { renderError = error.localizedDescription }
            rendering = false
        }
    }

    /// The network is the slow part of a preview, and its tiles hold while nothing before it changes: a slider on
    /// another filter re-runs only what follows.
    private func denoiseRun(for stack: CreativeFilterStack) -> DenoiseRun? {
        guard let input = stack.denoiseInput else { return nil }
        if let denoiseTiles, denoiseTiles.input == input { return denoiseTiles.run }
        let run = DenoiseRun(keepsTiles: true)
        denoiseTiles = (input, run)
        return run
    }

    /// The recipes on a small copy of the photo, one after another behind the preview's own work.
    private func renderThumbnails(_ recipes: [CreativeFilterRecipe]) {
        guard let renderer, let edits else { return }
        var settings = ExportSettings(); settings.select(.tiff); settings.profile.preset = .displayP3
        let earlier = thumbnailTask
        thumbnailTask = Task(priority: .utility) {
            await earlier?.value
            for recipe in recipes {
                guard !Task.isCancelled else { return }
                // A recipe that can't run here (a model not installed) keeps its symbol.
                guard let image = try? await renderer.exportPreview(edits, settings: settings, maxDimension: 260, filters: recipe.stack), !Task.isCancelled else { continue }
                thumbnails[recipe.id] = image
            }
        }
    }

    /// Shows the filter's settings, switching it on the first time it is picked: each filter is in the stack once,
    /// in the order they apply, and keeps its settings while it is off.
    func select(_ kind: CreativeFilterKind) {
        setOn(kind, true)
        selection = kind
    }
    func setOn(_ kind: CreativeFilterKind, _ on: Bool) {
        // Switched on, it is the one being set up: its card is picked, and its handles are the ones on the photo.
        if on { selection = kind }
        if let index = stack.filters.firstIndex(where: { $0.kind == kind }) { stack.filters[index].enabled = on }
        else if on {
            // A new filter goes where it usually belongs; from there its place is the photographer's.
            let order = CreativeFilterKind.renderOrder, place = order.firstIndex(of: kind) ?? order.count
            let index = stack.filters.firstIndex { (order.firstIndex(of: $0.kind) ?? order.count) > place } ?? stack.filters.count
            stack.filters.insert(CreativeFilter(kind), at: index)
        }
    }
    /// The filters switched on, in the order they apply.
    var applied: [CreativeFilter] { stack.applied }
    /// The filter `offset` places from this one among those it can trade places with; nil at an end.
    func neighbour(of kind: CreativeFilterKind, by offset: Int) -> CreativeFilterKind? {
        let peers = applied.filter { $0.kind.slot == kind.slot && ($0.kind == .border) == (kind == .border) }.map(\.kind)
        guard let index = peers.firstIndex(of: kind), peers.indices.contains(index + offset) else { return nil }
        return peers[index + offset]
    }
    /// Takes the picked filter out of the chain, settings and all, and picks the one that took its place.
    func removeSelection() { if let selection { remove(selection) } }
    /// Takes a filter out of the chain, settings and all; if it was the picked one, the one that took its place is.
    func remove(_ kind: CreativeFilterKind) {
        let index = applied.firstIndex { $0.kind == kind }
        stack.filters.removeAll { $0.kind == kind }
        if selection == kind { selection = applied.isEmpty ? nil : applied[min(index ?? 0, applied.count - 1)].kind }
    }
    /// The chain in its three runs: the filters on the lens, which see the photo's light first, then those on the
    /// picture, then the border round it, which no filter touches. A card moves within its own run.
    var appliedGroups: (lens: [CreativeFilter], picture: [CreativeFilter], border: [CreativeFilter]) {
        let on = applied
        return (on.filter { $0.kind.slot == .scene }, on.filter { $0.kind.slot != .scene && $0.kind != .border }, on.filter { $0.kind == .border })
    }
    /// The list's own move, within one run of the chain.
    func moveApplied(lens: Bool, from source: IndexSet, to destination: Int) {
        var groups = appliedGroups
        if lens { groups.lens.move(fromOffsets: source, toOffset: destination) } else { groups.picture.move(fromOffsets: source, toOffset: destination) }
        stack.filters = groups.lens + groups.picture + groups.border + stack.filters.filter { !$0.enabled }
    }
    func canMove(_ kind: CreativeFilterKind, by offset: Int) -> Bool { neighbour(of: kind, by: offset) != nil }
    func move(_ kind: CreativeFilterKind, by offset: Int) {
        guard let other = neighbour(of: kind, by: offset), let a = stack.filters.firstIndex(where: { $0.kind == kind }),
              let b = stack.filters.firstIndex(where: { $0.kind == other }) else { return }
        stack.filters.swapAt(a, b)
    }
    /// The filters placed on the picture, each with its point in percent from the picture's top left.
    var placed: [(kind: CreativeFilterKind, point: CGPoint)] {
        stack.filters.filter { $0.kind.isPlaced && $0.enabled }.map { ($0.kind, CGPoint(x: $0["x"], y: $0["y"])) }
    }
    func place(_ kind: CreativeFilterKind, at point: CGPoint) {
        guard let index = stack.filters.firstIndex(where: { $0.kind == kind }) else { return }
        stack.filters[index]["x"] = min(100, max(0, point.x)); stack.filters[index]["y"] = min(100, max(0, point.y))
    }
    /// One value of a filter set from its handle on the picture, kept inside the value's range.
    func set(_ kind: CreativeFilterKind, _ key: String, _ value: Double) {
        guard let index = stack.filters.firstIndex(where: { $0.kind == kind }), let range = kind.parameters.first(where: { $0.key == key })?.range else { return }
        stack.filters[index][key] = min(range.upperBound, max(range.lowerBound, value))
    }
    private func remember() {
        if let data = try? JSONEncoder().encode(stack) { preferences.set(data, forKey: "filtersStack") }
        saveLatentSoon()
    }

    // MARK: Latent image

    /// The latent image each photo's output left, by photo, so another output from this window updates it.
    private var kept: [String: String] = [:]
    /// The stack last written to the latent image this window opened.
    private var savedStack: CreativeFilterStack?
    private var saveTask: Task<Void, Never>?
    /// An opened latent image follows the stack a second after it stops changing; an emptied stack is not saved.
    private func saveLatentSoon(immediately: Bool = false) {
        guard let latent = request.latent, let catalog, let store = catalog.store, !stack.isEmpty, stack != (savedStack ?? latent.stack) else { return }
        saveTask?.cancel()
        let stack = stack, photo = request.assets[0]
        saveTask = Task {
            if !immediately { try? await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return } }
            do { try await catalog.saveFilterLatent(photo, stack: stack, store: store, into: latent.assetID); savedStack = stack }
            catch is CancellationError {}
            catch { catalog.error = error.localizedDescription }
        }
    }
    /// A new window's output leaves a latent image per photo when Keep Latent Image is ticked; an opened one follows its
    /// own, and `stop` saves the rest.
    private func keepLatents() {
        guard let catalog else { return }
        if request.latent == nil, LatentPreference.keeps(LatentImage.creativeFilters) {
            catalog.keepFilterLatents(request.assets, stack: stack, kept: { [weak self] in self?.kept[$0] }, saved: { [weak self] in self?.kept[$0] = $1 })
        }
    }

    func saveRecipe(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !stack.isEmpty else { return }
        if let old = recipes.first(where: { $0.name == name }) { thumbnails[old.id] = nil }
        recipes.removeAll { $0.name == name }
        let recipe = CreativeFilterRecipe(name: name, stack: CreativeFilterStack(stack.filters.filter(\.enabled)))
        recipes.append(recipe)
        recipes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        storeRecipes()
        renderThumbnails([recipe])
    }
    func apply(_ recipe: CreativeFilterRecipe) {
        // Fresh identities: the rows are this dialog's own.
        stack = CreativeFilterStack(recipe.stack.filters.map { var filter = $0; filter.id = UUID(); return filter })
        selection = applied.first?.kind
    }
    func isBuiltIn(_ recipe: CreativeFilterRecipe) -> Bool { !recipes.contains { $0.id == recipe.id } }
    func delete(_ recipe: CreativeFilterRecipe) { recipes.removeAll { $0.id == recipe.id }; thumbnails[recipe.id] = nil; storeRecipes() }
    /// Recipes this build can't read stay in the saved list.
    private func storeRecipes() {
        var saved = SavedList<CreativeFilterRecipe>(preferences.data(forKey: "filterRecipes"))
        saved.items = recipes
        try? saved.write(to: preferences, key: "filterRecipes")
    }

    // MARK: Output

    var outputSize: CGSize? {
        guard let renderer, let edits else { return nil }
        return try? GeometryPlan(size: CGSize(width: renderer.info.width, height: renderer.info.height), settings: edits.geometry, quarterTurns: edits.quarterTurns).outputSize
    }
    var hasImage: Bool { renderer != nil }
    var busy: Bool { stage != .ready }
    var exportTitle: String { request.assets.count == 1 ? request.assets[0].filename : L10n.tr("\(request.assets.count) photos") }
    var exportSubtitle: String? { nil }
    var hdrAvailable: Bool { false }
    var developedProfile: ColorProfile? { edits?.colorProfile ?? ColorProfile() }
    var exportsManyPhotos: Bool { request.assets.count > 1 }
    var locationPanel: AnyView? { nil }
    var exportButtonTitle: String { L10n.tr("Export…") }
    /// A window opened from a latent image keeps it without asking.
    var latentType: String? { request.latent == nil ? LatentImage.creativeFilters : nil }
    func makeExportPreview() async throws -> CGImage? {
        guard let renderer, let edits else { return nil }
        return try await renderer.exportPreview(edits, settings: outputSettings, filters: stack, denoise: denoiseRun(for: stack))
    }
    func dismissExport() { showingExport = false }
    @Published private var printJob: UUID?
    var preparingPrint: Bool {
        guard let printJob else { return false }
        return catalog?.activity.running.contains { $0.id == printJob && $0.outcome == nil } == true
    }
    var canPrint: Bool {
        stage == .ready && !rendering && renderError == nil && catalog?.canStartJob == true
            && catalog?.activity.contains(.exporting) == false
    }
    func printPhotos() {
        guard canPrint, let catalog else { return }
        printJob = catalog.printPhotos(request.assets, filters: stack)
        if printJob != nil { keepLatents() }
    }

    /// Asks where to put the photos (a file for one, which can be renamed; a folder for several), then hands them to
    /// the catalog's export job with the stack. The dialog and the tool stay open until the panel is answered, so backing
    /// out of it loses nothing.
    func performExport() {
        var settings = exportSettings; settings.aiDenoise = 0
        export(CatalogExportRequest(assets: request.assets, settings: settings, profile: usesDevelopedProfile ? nil : exportSettings.profile.preset, filters: stack))
    }
    private func export(_ job: CatalogExportRequest) {
        guard canApply, let catalog else { return }
        let photos = request.assets
        Task {
            var job = job
            if photos.count == 1 {
                let ext = job.settings.format.fileExtension
                let name = (photos[0].filename as NSString).deletingPathExtension + "." + ext
                guard let file = await FileChooser.save(FileSaveRequest(name: name, types: UTType(filenameExtension: ext).map { [$0] } ?? [],
                    prompt: L10n.tr("Export"), directory: catalog.lastExportFolder)), catalog.canStartJob else { return }
                job.destination = file.deletingLastPathComponent(); job.fileName = file.lastPathComponent
            } else {
                guard let folder = await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true,
                    message: L10n.tr("Choose a folder for \(photos.count) exported photos."),
                    prompt: L10n.tr("Export"), directory: catalog.lastExportFolder)), catalog.canStartJob else { return }
                job.destination = folder
            }
            showingExport = false
            keepLatents()
            close(catalog: catalog)
            catalog.export(job)
        }
    }
    /// The only photo couldn't be read: there is nothing to work with, so the tool closes and says why. With several,
    /// the failure stays on that photo and the others can still be used.
    private func fail(_ message: String) {
        stage = .failed(message)
        if request.assets.count == 1, let catalog { close(catalog: catalog); catalog.failure = Failure(L10n.tr("Can’t Filter This Photo"), message) }
    }
    func close(catalog: CatalogModel) {
        stop()
        catalog.filters = nil
    }
    func stop() {
        // A pending save outlives the window: the task holds the catalog, not the window.
        if saveTask != nil { saveLatentSoon(immediately: true) }
        task?.cancel(); renderTask?.cancel(); thumbnailTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
    }
}
