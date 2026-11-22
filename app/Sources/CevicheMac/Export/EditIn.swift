import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// Apps that open the rendered file a photo is handed to them as, looked up once at launch and again when Ceviche comes
/// back to the front, so a newly installed editor shows up without a restart.
@MainActor
final class ExternalEditors: ObservableObject {
    static let shared = ExternalEditors()
    struct App: Identifiable, Equatable {
        let url: URL
        let name: String
        let icon: NSImage
        var id: URL { url }
        static func == (a: App, b: App) -> Bool { a.url == b.url }
    }
    @Published private(set) var apps: [App] = []
    /// A 16-bit TIFF keeps all the tonal room for further work; an 8-bit JPEG is a fraction of the size.
    enum Format: String, CaseIterable, Identifiable {
        case tiff, jpeg
        var id: String { rawValue }
        var title: String { self == .tiff ? ExportFormat.tiff.rawValue : ExportFormat.jpeg.rawValue }
    }
    @Published var format = Format(rawValue: UserDefaults.standard.string(forKey: "editInFormat") ?? "") ?? .tiff {
        didSet { preferences.set(format.rawValue, forKey: "editInFormat") }
    }
    private var refreshing = false
    private var observer: NSObjectProtocol?
    private let preferences = UserDefaults.standard

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ExternalEditors.shared.refresh() }
        }
    }

    /// The app last used, offered first and on ⌘E.
    var recent: App? {
        guard let path = preferences.string(forKey: "editInApp") else { return nil }
        return apps.first { $0.url.path == path } ?? Self.app(at: URL(fileURLWithPath: path))
    }
    func remember(_ app: URL) {
        preferences.set(app.path, forKey: "editInApp")
        if !apps.contains(where: { $0.url == app }), let entry = Self.app(at: app) { apps.append(entry) }
        objectWillChange.send()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let found = await Task.detached(priority: .utility) { Self.lookUp() }.value
            refreshing = false
            if found.map(\.url) != apps.map(\.url) { apps = found }
        }
    }

    /// Apps that list TIFF but only show it: browsers, players and the like.
    nonisolated private static let viewers: Set<String> = [
        "com.apple.Safari", "com.apple.QuickTimePlayerX", "com.apple.GenerativePlaygroundApp", "com.google.Chrome",
        "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.colliderli.iina", "org.videolan.vlc"
    ]
    /// One entry per bundle id (the copy Launch Services prefers), sorted by name; Ceviche itself, its other builds and
    /// apps inside hidden folders are left out.
    nonisolated private static func lookUp() -> [App] {
        var seen = Set<String>()
        var apps: [App] = []
        for url in NSWorkspace.shared.urlsForApplications(toOpen: .tiff) {
            let identifier = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard !identifier.hasPrefix("me.chichou.ceviche"), !viewers.contains(identifier),
                  !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
                  seen.insert(identifier).inserted, let app = app(at: url) else { continue }
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    nonisolated static func app(at url: URL) -> App? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return App(url: url, name: (name as NSString).deletingPathExtension, icon: icon)
    }

    /// Any other app, from a panel.
    func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = L10n.tr("Edit In")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// The original's folder when the rendered copy can go beside it, as an editor's own save would: not for a photo
    /// copied into the catalog, on a cloud drive or in a folder that can't be written.
    nonisolated static func besideFolder(for source: URL, originalsRoot: URL?) -> URL? {
        let folder = source.deletingLastPathComponent()
        let insideCatalog = originalsRoot.map { source.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") } ?? false
        return !insideCatalog && AssetLocator.describing(source).scheme == .file && FileManager.default.isWritableFile(atPath: folder.path) ? folder : nil
    }
    /// The full-size file in the development's own profile, with metadata: a 16-bit TIFF or an 8-bit JPEG.
    nonisolated static func settings(_ format: Format) -> ExportSettings {
        var settings = ExportSettings(); settings.includeMetadata = true
        switch format {
        case .tiff: settings.select(.tiff); settings.depth = 16
        case .jpeg: settings.select(.jpeg); settings.depth = 8; settings.quality = 0.95
        }
        return settings
    }
    nonisolated static let suffix = "-edit"
    /// Set while the catalog looks for saves from the other app, so returning to Ceviche twice checks once.
    var checkingSaves = false

    func open(_ files: [URL], with app: URL) {
        remember(app)
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }
}

/// The apps that take the rendered file, the last used first, then Other… and the file format.
struct EditInItems: View {
    @ObservedObject private var editors = ExternalEditors.shared
    let open: (URL) -> Void
    var body: some View {
        let recent = editors.recent
        if let recent {
            Button { open(recent.url) } label: { Label { Text(recent.name) } icon: { Image(nsImage: recent.icon) }.labelStyle(.titleAndIcon) }
            Divider()
        }
        ForEach(editors.apps.filter { $0 != recent }) { app in
            Button { open(app.url) } label: { Label { Text(app.name) } icon: { Image(nsImage: app.icon) }.labelStyle(.titleAndIcon) }
        }
        if !editors.apps.isEmpty { Divider() }
        Button(L10n.tr("Other…")) { if let app = editors.chooseApp() { open(app) } }
        Divider()
        Picker(L10n.tr("Format"), selection: $editors.format) {
            ForEach(ExternalEditors.Format.allCases) { Text(verbatim: $0.title).tag($0) }
        }
        .pickerStyle(.inline).labelsHidden()
    }
}

extension CatalogModel {
    /// Renders each photo with its development to a TIFF or JPEG, adds it to the catalog in the photo's group with its metadata,
    /// and opens the catalog's files in `app`, so what the app saves is what the catalog shows. Develop's pending edits
    /// are saved first so the file has them. `stack` is Creative Filters' chain, burnt into the file.
    func editIn(_ targets: [CatalogAsset], app: URL, editor: EditorModel?, filters stack: CreativeFilterStack? = nil) {
        let targets = targets.filter { $0.inLibrary && !$0.isLatent }
        guard !targets.isEmpty, let store, canStartJob else { return }
        activity.start(.exporting, title: L10n.tr("Edit in \(FileManager.default.displayName(atPath: app.path))"), total: targets.count > 1 ? targets.count : nil) { [weak self] job in
            guard let self else { return }
            if let editor, let open = editor.catalogAssetID, targets.contains(where: { $0.id == open }), !(await editor.flushEdits()) {
                activity.finish(job, outcome: .failed(L10n.tr("Edits not saved"))); return
            }
            var files: [URL] = [], failures: [String] = []
            for (index, asset) in targets.enumerated() {
                if Task.isCancelled { break }
                activity.update(job, completed: index, detail: asset.filename)
                do { files.append(try await renderForEditing(asset, store: store, filters: stack))
                } catch is CancellationError { break
                } catch { failures.append("\(asset.filename): \(error.localizedDescription)") }
            }
            if !files.isEmpty {
                indexer.workAvailable()
                await refresh(); syncSoon()
                if !Task.isCancelled { ExternalEditors.shared.open(files, with: app) }
            }
            activity.finish(job, outcome: files.isEmpty && !failures.isEmpty ? .failed(L10n.tr("\(failures.count.formatted()) failed"))
                            : Task.isCancelled ? .stopped : .done(files.count == 1 ? files[0].lastPathComponent : Self.counted(files.count, .exported)),
                            result: files.isEmpty ? nil : .files(files))
            if !failures.isEmpty { failure = Failure(L10n.tr("Some Photos Weren’t Exported"), summary: (failures.count == 1 ? L10n.tr("\(failures.count) photo couldn’t be exported.\n") : L10n.tr("\(failures.count) photos couldn’t be exported.\n")).trimmingCharacters(in: .newlines), items: failures) }
        }
    }
    /// Develop's photo through the catalog; a file opened on its own goes straight from the editor.
    func editInOpenPhoto(app: URL, editor: EditorModel) {
        if let asset = openAsset(editor: editor) { editIn([asset], app: app, editor: editor) } else { editor.editIn(app: app) }
    }

    /// The file is written beside the original and referenced there when that folder takes it, otherwise rendered to a
    /// temporary folder and copied into the catalog's originals. Returns the catalog's file.
    func renderForEditing(_ photo: CatalogAsset, store: CatalogStore, filters: CreativeFilterStack? = nil) async throws -> URL {
        let source = try await resolveOriginal(photo)
        let beside = ExternalEditors.besideFolder(for: source, originalsRoot: store.originalsRoot)
        let directory = beside ?? FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Edit In \(UUID().uuidString)")
        defer { if beside == nil { try? FileManager.default.removeItem(at: directory) } }
        if beside == nil { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard let url = try await Self.exportFile(photo, store: store, settings: ExternalEditors.settings(ExternalEditors.shared.format), to: directory, suffix: ExternalEditors.suffix, filters: filters) else { throw CancellationError() }
        let inserted: CatalogAsset
        do {
            let options = CatalogImporter.ImportOptions(mode: beside == nil ? .copy : .reference, catalogRoot: store.originalsRoot)
            let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
            // Burnt in: the copy starts without development, even when a stray sidecar sits beside it.
            var asset = prepared.0; asset.importBatchID = UUID().uuidString
            asset.adjustmentsData = nil; asset.xmpData = nil; asset.xmpWarnings = ""
            inserted = try await store.insert(asset, thumbnail: prepared.1)
        } catch { if beside != nil { try? FileManager.default.removeItem(at: url) }; throw error }
        // Title, caption, keywords, rating and a location set in the catalog come along. The copy is not grouped with
        // the photo: folded away, it went unnoticed and was picked up by whatever the group was selected for.
        // The copy is in the catalog by now: metadata that can't follow it doesn't undo that.
        if let current = try? await store.asset(photo.id) { try? await store.updateMetadata(current.metadata, assetID: inserted.id) }
        return CatalogImporter.sourceURL(for: inserted, root: store.root)
    }

    /// Picks up what the other app saved over a rendered copy since: the file's size, dimensions and thumbnail, and
    /// reopens it when Develop shows it. Called when Ceviche comes back to the front.
    func pickUpOutsideEdits(editor: EditorModel) {
        guard let store, !ExternalEditors.shared.checkingSaves else { return }
        ExternalEditors.shared.checkingSaves = true
        Task {
            defer { ExternalEditors.shared.checkingSaves = false }
            guard let candidates = try? await store.photosEditedElsewhere(suffix: ExternalEditors.suffix), !candidates.isEmpty else { return }
            let root = store.root, originals = store.originalsRoot
            let saved = await Task.detached(priority: .utility) {
                candidates.compactMap { asset -> (id: String, fresh: CatalogPhoto, thumbnail: Data?)? in
                    let url = CatalogImporter.sourceURL(for: asset, root: root)
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let size = values.fileSize, let modified = values.contentModificationDate,
                          Int64(size) != asset.fileSize || modified > asset.originalUpdatedAt,
                          let fresh = try? CatalogImporter.prepare(url, options: .init(mode: .reference, catalogRoot: originals)) else { return nil }
                    return (asset.id, fresh.0, fresh.1)
                }
            }.value
            guard !saved.isEmpty, self.store === store else { return }
            var reopen: CatalogAsset?
            for file in saved {
                guard let refreshed = try? await store.refreshOriginal(file.id, from: file.fresh) else { continue }
                if let thumbnail = file.thumbnail { try? await store.installPreviewThumbnail(thumbnail, assetID: file.id) }
                if editor.catalogAssetID == file.id, editor.usesCatalog(store) { reopen = refreshed }
            }
            await refresh(); syncSoon()
            if let reopen { await openPhoto(reopen, editor: editor, keepSequence: true, preservingSelection: true) }
        }
    }
}

extension EditorModel {
    /// A file opened on its own, as Develop shows it, unsaved edits included: rendered beside it (or into Pictures when
    /// its folder can't be written) and opened in `app`.
    func editIn(app: URL) {
        guard !busy, let renderer, let source = sourceURL else { return }
        let settings = adjustments
        var options = ExternalEditors.settings(ExternalEditors.shared.format); options.profile = settings.colorProfile
        let store = catalogStore, assetID = catalogAssetID
        let folder = ExternalEditors.besideFolder(for: source, originalsRoot: catalogStore?.originalsRoot)
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche Edits", isDirectory: true)
        let stem = source.deletingPathExtension().lastPathComponent + ExternalEditors.suffix, ext = options.format.fileExtension
        ActivityCenter.shared.start(.exporting, title: L10n.tr("Edit in \(FileManager.default.displayName(atPath: app.path))")) { [weak self] job in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var url = folder.appendingPathComponent(stem).appendingPathExtension(ext), number = 2
                while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(stem) \(number)").appendingPathExtension(ext); number += 1 }
                var output = options; output.location = await EditorModel.exportLocation(store: store, assetID: assetID)
                try await renderer.export(to: url, adjustments: settings, settings: output)
                guard !Task.isCancelled else { return }
                ExternalEditors.shared.open([url], with: app)
                ActivityCenter.shared.finish(job, outcome: .done(url.lastPathComponent), result: .files([url]))
            } catch is CancellationError {
            } catch {
                self?.failure = Failure(L10n.tr("Couldn’t Export"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }
}

/// The File menu's submenu, where ⌘E sends to the app last used.
struct EditInMenu: View {
    @ObservedObject private var editors = ExternalEditors.shared
    let open: (URL) -> Void
    var body: some View {
        if let recent = editors.recent {
            Button(L10n.tr("Edit in \(recent.name)")) { open(recent.url) }.keyboardShortcut("e")
        }
        Menu(L10n.tr("Edit In")) { EditInItems(open: open) }
    }
}
