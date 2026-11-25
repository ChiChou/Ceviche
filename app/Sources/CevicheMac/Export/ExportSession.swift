import SwiftUI
import AppKit
import CevicheCore

/// What the export dialog needs from whatever is being exported: the open photo in Develop, or a
/// Library selection previewed through its first photo.
@MainActor
protocol ExportTarget: ObservableObject {
    var exportSettings: ExportSettings { get set }
    var outputSize: CGSize? { get }
    var hasImage: Bool { get }
    var busy: Bool { get }
    var exportTitle: String { get }
    var exportSubtitle: String? { get }
    var hdrAvailable: Bool { get }
    /// Offered as "As Developed" in the profile picker when exporting photos with their own profiles.
    var developedProfile: ColorProfile? { get }
    var usesDevelopedProfile: Bool { get set }
    /// True for a selection: sizes apply per photo.
    var exportsManyPhotos: Bool { get }
    /// Where the files go, above the file's own settings, when the dialog decides that: the folder and what happens
    /// to a file already there. Nil when a save panel asks afterwards.
    var locationPanel: AnyView? { get }
    var exportButtonTitle: String { get }
    /// The export, small: what a watermark is laid over while it is edited.
    func makeExportPreview() async throws -> CGImage?
    func dismissExport()
    func performExport()
    /// The latent image type whose Keep Latent Image the dialog's options offer; nil for none.
    var latentType: String? { get }
}

extension ExportTarget {
    var latentType: String? { nil }
}

extension ExportSettings {
    static let lastUsedKey = "lastExportSettings"
    /// The settings of the last export or share, so the dialog opens the way it was left. The watermark is read again
    /// from the library, so it is the saved version, or none once it has been deleted.
    static func lastUsed(_ defaults: UserDefaults = .standard, watermarks: WatermarkLibrary = .standard, key: String = lastUsedKey) -> ExportSettings? {
        guard var settings = defaults.data(forKey: key).flatMap({ try? JSONDecoder().decode(ExportSettings.self, from: $0) }) else { return nil }
        settings.watermark = settings.watermark.flatMap { watermarks.watermark(id: $0.id) }
        return settings
    }
    /// Remembers format, dynamic range, depth, quality, size and options; an imported ICC profile stays with its document.
    func rememberAsLastUsed(_ defaults: UserDefaults = .standard, key: String = lastUsedKey) {
        var kept = self
        kept.profile.iccData = nil; kept.profile.name = ""
        if kept.profile.preset == .custom { kept.profile.preset = .automatic }
        kept.sizing.longEdge = nil; kept.sizing.frame = nil
        if kept.sizing.preset == .custom { kept.sizing.preset = .original }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: key) }
    }
}

extension EditorModel: ExportTarget {
    var exportTitle: String { info?.filename ?? L10n.tr("Choose your output settings") }
    var exportSubtitle: String? { nil }
    var hdrAvailable: Bool { adjustments.hdr.enabled }
    var developedProfile: ColorProfile? { nil }
    var usesDevelopedProfile: Bool { get { false } set {} }
    var exportsManyPhotos: Bool { false }
    var locationPanel: AnyView? { nil }
    var exportButtonTitle: String { L10n.tr("Export…") }
    func dismissExport() { showExport = false }
}

/// A Library export: one dialog for the whole selection, previewing and estimating with the first photo.
@MainActor
final class CatalogExportSession: ObservableObject, Identifiable, ExportTarget {
    let id = UUID()
    let assets: [CatalogAsset]
    private weak var catalog: CatalogModel?
    private let store: CatalogStore
    /// Starts from the last export's settings, sized per photo. HDR is offered once a photo developed in HDR is found;
    /// the photos without HDR edits go out in SDR.
    @Published var exportSettings: ExportSettings = {
        var settings = ExportSettings.lastUsed() ?? CatalogExportRequest(assets: []).settings
        settings.sizing.longEdge = nil; settings.sizing.frame = nil
        return settings
    }()
    /// One of the photos is developed in HDR.
    @Published private(set) var hdrPhotos = false
    @Published var usesDevelopedProfile = true
    @Published var destination: URL?
    @Published var existing = ExistingFilePolicy.rename
    let catalogRoot: URL
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    private var renderer: RawRenderer?
    private var sample: (info: ImageInfo, adjustments: Adjustments)?
    private var loadTask: Task<Void, Never>?
    init(assets: [CatalogAsset], store: CatalogStore, catalog: CatalogModel) {
        self.assets = assets; self.store = store; self.catalog = catalog; catalogRoot = store.root
        destination = catalog.lastExportFolder
        load()
    }
    private func load() {
        guard let first = assets.first else { loading = false; return }
        let root = store.root, store = store
        loadTask = Task { [weak self] in
            do {
                let current = try await store.asset(first.id)
                let availability = current.availability(catalog: root)
                guard case .available(let url) = availability else {
                    throw EditorError.invalidDocument(L10n.tr("\(current.filename) is not reachable from this Mac, so there is no preview. The export still runs for every photo it can read."))
                }
                let saved = try await store.savedAdjustments(of: current)
                let loaded = try await Task.detached(priority: .userInitiated) { () -> (RawRenderer, Adjustments) in
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let opened = try RawRenderer.open(url, hdr: current.hdr)
                    return (opened.0, saved ?? opened.1)
                }.value
                guard let self, !Task.isCancelled else { return }
                renderer = loaded.0; sample = (loaded.0.info, loaded.1)
                exportSettings.sizing.updateSource(outputSize ?? .zero)
                loading = false
                // Read from the catalog alone; stops at the first HDR photo.
                for asset in assets where !Task.isCancelled {
                    if (try? await store.savedAdjustments(of: asset))?.hdr.enabled == true { hdrPhotos = true; break }
                }
            } catch { self?.loadError = error.localizedDescription; self?.loading = false }
        }
    }
    var outputSize: CGSize? {
        guard let sample else { return nil }
        return try? GeometryPlan(size: CGSize(width: sample.info.width, height: sample.info.height), settings: sample.adjustments.geometry, quarterTurns: sample.adjustments.quarterTurns).outputSize
    }
    var hasImage: Bool { renderer != nil }
    var busy: Bool { loading || catalog?.canStartJob == false }
    var exportTitle: String { assets.count == 1 ? assets[0].filename : L10n.tr("\(assets.count) photos") }
    var exportSubtitle: String? { loadError }
    var exportsManyPhotos: Bool { assets.count > 1 }
    var locationPanel: AnyView? { AnyView(ExportLocation(session: self)) }
    var exportButtonTitle: String { destination == nil ? L10n.tr("Export…") : L10n.tr("Export") }
    func chooseDestination() {
        Task {
            if let url = await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true,
                message: L10n.tr("Choose the folder exported photos go to."), prompt: L10n.tr("Choose"), directory: destination)) { destination = url }
        }
    }
    var hdrAvailable: Bool { hdrPhotos }
    var developedProfile: ColorProfile? { sample?.adjustments.colorProfile ?? ColorProfile() }
    /// The dialog's settings as they reach the export: HDR only when a photo has it to keep.
    private var chosenSettings: ExportSettings {
        var settings = exportSettings
        if !hdrPhotos { settings.setHDR(false) }
        return settings
    }
    /// The settings the previewed photo gets, with the profile each photo should get.
    private var effectiveSettings: ExportSettings {
        var settings = chosenSettings
        if sample?.adjustments.hdr.enabled != true { settings.setHDR(false) }
        if usesDevelopedProfile, let sample { settings.profile = sample.adjustments.colorProfile }
        return settings
    }
    func makeExportPreview() async throws -> CGImage? {
        guard let renderer, let sample else { return nil }
        return try await renderer.exportPreview(sample.adjustments, settings: effectiveSettings)
    }
    private var request: CatalogExportRequest {
        CatalogExportRequest(assets: assets, settings: chosenSettings, profile: usesDevelopedProfile ? nil : exportSettings.profile.preset, destination: destination, existing: existing)
    }
    func dismissExport() { loadTask?.cancel(); catalog?.exportSession = nil }
    func performExport() { exportSettings.rememberAsLastUsed(); catalog?.export(request) }
}
