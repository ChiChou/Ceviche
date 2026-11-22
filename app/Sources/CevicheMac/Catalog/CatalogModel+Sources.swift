import SwiftUI
import AppKit
import ImageIO
import CoreData
import CevicheCore

/// A catalog this Mac has opened, for the File › Catalogs menu and the welcome screen.
struct CatalogReference: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var kind: CatalogKind
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
    init(store: CatalogStore) { id = store.manifest.id; name = store.manifest.name; kind = store.manifest.kind; path = store.root.path }
}

/// What the camera-card importer shows: where it scans and what it found.
struct CardImportRequest: Identifiable {
    let id = UUID()
    let roots: [URL]
    let title: String
    let defaultMode: CatalogImporter.ImportMode
}

extension CatalogModel {
    // MARK: Catalogs
    func recentCatalogs(iCloudEnabled: Bool = BuildFeatures.iCloud) -> [CatalogReference] {
        knownCatalogs.filter { iCloudEnabled || $0.kind != .cloud }
    }
    func remember(_ reference: CatalogReference) {
        var list = knownCatalogs.filter { $0.id != reference.id && $0.path != reference.path }
        list.insert(reference, at: 0)
        setKnownCatalogs(Array(list.prefix(12)))
    }
    func forgetCatalog(_ reference: CatalogReference) { setKnownCatalogs(knownCatalogs.filter { $0.id != reference.id }) }
    private func setKnownCatalogs(_ list: [CatalogReference]) {
        knownCatalogs = list; preferences.set(try? JSONEncoder().encode(list), forKey: "knownCatalogs")
    }
    /// Welcome: import straight away into a catalog created in the app's own container.
    func importIntoNewLocalCatalog() {
        Task {
            if store == nil {
                let root = Self.defaultCatalogRoot
                await openCatalog(root, manifest: Self.catalogExists(at: root) ? nil : CatalogManifest(name: L10n.tr("Library"), kind: .local))
            }
            guard store != nil else { return }
            chooseImport()
        }
    }
    /// Welcome and File menu: a catalog synced through iCloud under the person's Apple ID.
    func createCloudCatalog(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = CatalogManifest(name: trimmed.isEmpty ? L10n.tr("iCloud Library") : trimmed, kind: .cloud)
        Task { await openCatalog(CatalogManifest.cloudRoot(id: manifest.id), manifest: manifest) }
    }
    /// Joins an iCloud catalog another Mac created; its photos arrive on the first sync.
    func joinCloudCatalog(id: String, name: String) {
        Task { await openCatalog(CatalogManifest.cloudRoot(id: id), manifest: CatalogManifest(id: id, name: name, kind: .cloud)) }
    }
    /// Opens an iCloud catalog by its ID: this Mac's replica if it has one, otherwise a new replica that fills in on
    /// the first sync.
    func openCloudCatalog(_ listing: CloudCatalogListing) {
        if let reference = knownCatalogs.first(where: { $0.id == listing.id }) { Task { await openCatalog(reference.url) } }
        else { joinCloudCatalog(id: listing.id, name: listing.name) }
    }
    /// Keeps `cloudCatalogs` current: opens the directory once, reads it, and reads it again whenever iCloud delivers
    /// changes, since on a Mac that has never synced the list arrives some time after the directory opens.
    func lookForCloudCatalogs() {
        guard BuildFeatures.iCloud else { return }
        guard cloudDirectoryTask == nil else { readCloudCatalogs(); return }
        lookingForCloudCatalogs = true
        cloudDirectoryTask = Task { [weak self] in
            let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche/iCloud/Discovery.store")
            try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            let directory = try? await Task.detached { try CloudCatalogDirectory(mirrorURL: store) }.value
            guard let self else { return }
            self.cloudDirectory = directory
            self.cloudCatalogsReachable = directory?.reachesCloud ?? false
            self.readCloudCatalogs()
            guard directory?.reachesCloud == true else { self.lookingForCloudCatalogs = false; return }
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                guard !Task.isCancelled else { break }
                self.readCloudCatalogs()
                self.lookingForCloudCatalogs = false
            }
        }
        // The first import can take a while, or find nothing new; stop showing progress after a minute either way.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.lookingForCloudCatalogs = false
        }
    }
    private func readCloudCatalogs() {
        guard let directory = cloudDirectory else { return }
        // Catalogs deleted on another Mac: this Mac forgets them and removes its replicas, except the open one, which
        // closes when its own sync finds out.
        let deleted = (try? directory.deletedCatalogIDs()) ?? []
        for reference in knownCatalogs where reference.kind == .cloud && deleted.contains(reference.id) && manifest?.id != reference.id {
            removeReplica(of: reference.id)
        }
        if !deleted.isEmpty { Task.detached(priority: .utility) { try? directory.removeLeftovers() } }
        // Catalogs this Mac has opened count too, even before their first sync reaches iCloud.
        var listed = (try? directory.catalogs()) ?? []
        for reference in knownCatalogs where reference.kind == .cloud && !deleted.contains(reference.id) && !listed.contains(where: { $0.id == reference.id }) {
            listed.append(CloudCatalogListing(id: reference.id, name: reference.name))
        }
        cloudCatalogs = listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// iCloud Catalogs ▸ New Catalog: lists a new iCloud catalog on every Mac without opening it; the first Mac that
    /// opens it makes its replica.
    func addCloudCatalog(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let directory = cloudDirectory else { error = L10n.tr("Ceviche is still looking for your iCloud catalogs. Try again in a moment."); return }
        do { try directory.rename(UUID().uuidString, to: trimmed) }
        catch { self.failure = Failure(L10n.tr("Couldn’t Create the Catalog"), L10n.tr("“\(trimmed)” could not be created. \(error.localizedDescription)")); return }
        readCloudCatalogs()
    }
    /// The folder in iCloud Drive that holds the originals imported into an iCloud catalog, when this build keeps them
    /// there; the same folder on every Mac.
    nonisolated static func cloudOriginalsFolder(id: String) -> URL? {
        if let path = try? CatalogManifest.load(root: CatalogManifest.cloudRoot(id: id))?.originals {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if url.lastPathComponent == id { return url }
        }
        guard let folder = ResourceStorage.shared.folder, folder.ubiquitous else { return nil }
        return folder.root.appendingPathComponent("Catalogs/\(id)", isDirectory: true)
    }
    /// Renames the open catalog: an iCloud one for every Mac, any other in its `catalog.json`.
    func renameOpenCatalog(to name: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != store.manifest.name else { return }
        if store.manifest.kind == .cloud, let listing = cloudCatalogs.first(where: { $0.id == store.manifest.id }) {
            renameCloudCatalog(listing, to: trimmed); return
        }
        do {
            objectWillChange.send()
            try store.rename(to: trimmed)
            if store.manifest.kind == .cloud { syncSoon() }
            remember(CatalogReference(store: store))
        } catch { self.failure = Failure(L10n.tr("Couldn’t Rename the Catalog"), L10n.tr("“\(store.manifest.name)” could not be renamed. \(error.localizedDescription)")) }
    }
    /// Renames an iCloud catalog for every Mac: in iCloud, and in this Mac's replica when it has one.
    func renameCloudCatalog(_ listing: CloudCatalogListing, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != listing.name else { return }
        let date = Date()
        do {
            if let store, store.manifest.id == listing.id {
                objectWillChange.send()
                try store.rename(to: trimmed, at: date)
                syncSoon()
            } else if var replica = try CatalogManifest.load(root: CatalogManifest.cloudRoot(id: listing.id)) {
                replica.name = trimmed; replica.renamedAt = date
                try replica.save(root: CatalogManifest.cloudRoot(id: listing.id))
            } else if cloudDirectory == nil {
                error = L10n.tr("Ceviche is still looking for your iCloud catalogs. Try again in a moment."); return
            }
            try cloudDirectory?.rename(listing.id, to: trimmed, at: date)
            if let index = knownCatalogs.firstIndex(where: { $0.id == listing.id }) {
                var list = knownCatalogs; list[index].name = trimmed; setKnownCatalogs(list)
            }
            readCloudCatalogs()
        } catch { self.failure = Failure(L10n.tr("Couldn’t Rename the Catalog"), L10n.tr("“\(listing.name)” could not be renamed. \(error.localizedDescription)")) }
    }
    /// Deletes an iCloud catalog for every Mac: its edits, albums and ratings in iCloud, this Mac's replica, and the
    /// originals imported into it, which go to the Trash from iCloud Drive and from the replica. Linked originals are
    /// not touched. The open catalog closes first; nothing is deleted when it cannot close.
    func deleteCloudCatalog(_ listing: CloudCatalogListing, editor: EditorModel?) async {
        guard !catalogWideBusy else { NSSound.beep(); notice = L10n.tr("Busy, try again in a moment"); return }
        if manifest?.id == listing.id {
            guard let editor else { failure = Failure(L10n.tr("Couldn’t Delete the Catalog"), L10n.tr("Close “\(listing.name)” before deleting it.")); return }
            await closeCatalog(editor: editor)
            guard store == nil else { failure = Failure(L10n.tr("Couldn’t Delete the Catalog"), L10n.tr("“\(listing.name)” is still open, so it was not deleted. Finish or save the current work, then try again.")); return }
        }
        guard let directory = cloudDirectory else { error = L10n.tr("Ceviche is still looking for your iCloud catalogs. Try again in a moment."); return }
        let id = listing.id
        do { try await Task.detached { try directory.delete(id) }.value }
        catch { self.failure = Failure(L10n.tr("Couldn’t Delete the Catalog"), L10n.tr("“\(listing.name)” could not be deleted. \(error.localizedDescription)")); return }
        let trashed = await Task.detached { Self.trashOriginals(ofCloudCatalog: id) }.value
        removeReplica(of: id, name: listing.name)
        readCloudCatalogs()
        if trashed { notice = L10n.tr("Deleted “\(listing.name)”. Its originals are in the Trash.") }
        else { failure = Failure(L10n.tr("Originals Not Moved to Trash"), L10n.tr("Deleted “\(listing.name)”, but its originals could not be moved to the Trash.")) }
    }
    /// Moves the originals imported into an iCloud catalog to the Trash: its iCloud Drive folder, and copies only this
    /// Mac's replica has. False when one of them could not move.
    nonisolated static func trashOriginals(ofCloudCatalog id: String) -> Bool {
        let fm = FileManager.default
        var folders = [CatalogManifest.cloudRoot(id: id).appendingPathComponent("Originals", isDirectory: true)]
        if let shared = cloudOriginalsFolder(id: id) { folders.append(shared) }
        var trashed = true
        for folder in folders where fm.fileExists(atPath: folder.path) {
            do { try fm.trashItem(at: folder, resultingItemURL: nil) } catch { trashed = false }
        }
        return trashed
    }
    /// The open catalog was deleted on another Mac: closes it and removes this Mac's replica.
    func closeRemovedCatalog(editor: EditorModel) async {
        guard let manifest, manifest.kind == .cloud, syncState == .removed else { return }
        await closeCatalog(editor: editor)
        guard store == nil else { return }
        let kept = removeReplica(of: manifest.id, name: manifest.name)
        readCloudCatalogs()
        failure = Failure(L10n.tr("Catalog Deleted on Another Mac"), L10n.tr("“\(manifest.name)” was deleted from iCloud on another Mac, so it was closed and removed from this Mac.")
            + (kept == nil ? "" : L10n.tr(" Copies of originals that were only on this Mac are kept in Finder.")))
        if let kept { NSWorkspace.shared.showInFinder([kept]) }
    }
    /// Removes this Mac's replica of a deleted iCloud catalog and forgets it. Copied originals that never moved to
    /// iCloud Drive stay, in a folder beside the replicas named after the catalog, which is returned.
    @discardableResult
    func removeReplica(of id: String, name: String? = nil) -> URL? {
        let root = CatalogManifest.cloudRoot(id: id)
        var kept: URL?
        do { kept = try Self.removeReplica(at: root, keepingOriginalsAs: ((try? CatalogManifest.load(root: root)) ?? nil)?.name ?? name ?? L10n.tr("iCloud Catalog")) }
        catch { self.error = error.localizedDescription }
        setKnownCatalogs(knownCatalogs.filter { $0.id != id })
        return kept
    }
    nonisolated static func removeReplica(at root: URL, keepingOriginalsAs name: String) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        let files = fm.enumerator(at: originals, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects.compactMap { $0 as? URL } ?? []
        guard files.contains(where: { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }) else { try fm.removeItem(at: root); return nil }
        let label = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var kept = root.deletingLastPathComponent().appendingPathComponent("\(label) Originals", isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: kept.path) { kept = root.deletingLastPathComponent().appendingPathComponent("\(label) Originals \(suffix)", isDirectory: true); suffix += 1 }
        try fm.moveItem(at: originals, to: kept)
        try fm.removeItem(at: root)
        return kept
    }

    // MARK: Sync
    func startSync(for store: CatalogStore) {
        guard store.manifest.kind == .cloud else { syncState = nil; return }
        // The File menu lists the other iCloud catalogs by name.
        lookForCloudCatalogs()
        guard sync == nil, syncStartupTask == nil else { return }
        syncStartupTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.syncStartupTask = nil } }
            do {
                let engine = try await Task.detached { try CloudSyncEngine(store: store) }.value
                guard !Task.isCancelled, self.store === store else { return }
                self.sync = engine
                await engine.observe { [weak self] state, changed in
                    Task { @MainActor in
                        guard let self, self.sync === engine else { return }
                        self.syncState = state
                        guard changed else { return }
                        // A rename on another Mac arrives here too.
                        if self.knownCatalogs.first(where: { $0.id == store.manifest.id })?.name != store.manifest.name {
                            self.objectWillChange.send(); self.remember(CatalogReference(store: store))
                        }
                        self.placeNamer.workAvailable()
                        // Edits from another Mac leave thumbnails to develop here.
                        self.scheduleThumbnailCatchUp(for: store)
                        await self.refresh(); await self.reloadSelection()
                    }
                }
                self.syncState = await engine.state
                await engine.start()
                // Copies made before the catalog kept originals in iCloud Drive move there, for the other Macs.
                Task.detached(priority: .utility) { _ = try? store.shareLocalOriginals() }
            } catch {
                guard !Task.isCancelled, self.store === store else { return }
                self.syncState = .unavailable(L10n.tr("Your catalog is saved on this Mac. iCloud sync could not start: \(error.localizedDescription). Try Sync Again to reconnect."))
            }
        }
    }
    func stopSync() {
        syncStartupTask?.cancel(); syncStartupTask = nil
        syncState = nil
        guard let engine = sync else { return }
        sync = nil
        Task { await engine.stop() }
    }
    /// Pushes recent local changes after a short pause; iCloud catalogs only.
    func syncSoon() {
        guard let engine = sync else { return }
        Task { await engine.syncSoon() }
    }
    func syncNow() {
        guard let store else { return }
        // Recreate the mirror after an initialization failure; ordinary offline uploads are queued by CloudKit.
        guard let engine = sync else { startSync(for: store); return }
        Task {
            if await engine.needsRestart {
                await engine.stop()
                guard self.store === store, sync === engine else { return }
                sync = nil; startSync(for: store)
            } else { await engine.retry() }
        }
    }

    // MARK: Originals
    /// Quick checks per loaded page, off the main thread; only unavailable photos are kept.
    func updateAvailability(for page: [CatalogAsset], generation: Int) {
        let root = self.root
        Task.detached(priority: .utility) {
            var result: [String: AssetAvailability] = [:]
            for asset in page {
                let state = asset.availability(catalog: root)
                if state.localURL == nil { result[asset.id] = state }
            }
            let found = result
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                if self.availability != found { self.availability = found }
                // A folder being indexed makes its own thumbnails, in order.
                self.regenerateThumbnails(for: self.folderSyncTask != nil ? [] : page.filter { $0.thumbnailKey == nil && found[$0.id] == nil })
            }
        }
    }
    /// Thumbnails are per-Mac caches: photos that arrived through iCloud, or were relinked, get the camera preview
    /// from their original when it is reachable, ahead of other thumbnail work. Offline and not-downloaded originals
    /// are skipped; the preview synced with the catalog stands in.
    func regenerateThumbnails(for assets: [CatalogAsset]) {
        let covers = albums.filter { $0.thumbnailKey == nil }.compactMap(\.coverAssetID).filter { !coverThumbnailAttempts.contains($0) }
        guard let store, !assets.isEmpty || !covers.isEmpty else { return }
        coverThumbnailAttempts.formUnion(covers)
        let ids = assets.map(\.id) + covers
        Task {
            // A photo already asked for by an earlier page is done once.
            let ticket = await store.thumbnails.want(ids, kind: .preview, priority: .visible)
            let outcomes = await store.thumbnails.wait(ticket)
            // Tiles update as each thumbnail lands; album covers need the refresh.
            if covers.contains(where: { outcomes[$0] == .installed }), self.store === store { await refresh() }
        }
    }
    /// A readable URL for the original, mounting or downloading when needed.
    func resolveOriginal(_ asset: CatalogAsset) async throws -> URL {
        switch asset.availability(catalog: root) {
        case .available(let url): return url
        case .offline(let reason): throw EditorError.invalidDocument(L10n.tr("\(asset.filename) is offline. \(reason)"))
        case .fetchable(let storage):
            let fetch = UUID()
            activeFetch = fetch
            maintenanceKind = .downloading
            maintenance = L10n.tr("Downloading \(asset.filename)"); maintenanceDetail = L10n.tr("From \(storage)"); maintenanceProgress = 0
            defer { if activeFetch == fetch { activeFetch = nil; maintenance = nil; maintenanceDetail = nil; maintenanceProgress = nil } }
            let locator = asset.locator, root = self.root
            return try await AssetResolver.fetch(locator, catalog: root) { [weak self] fraction in
                // Progress arrives on its own tasks; one that runs after the fetch ended must not bring the status back.
                Task { @MainActor in
                    guard let self, self.activeFetch == fetch else { return }
                    self.maintenanceProgress = fraction
                }
            }
        }
    }
    /// Points an offline photo at another file, keeping edits and history.
    func replaceOriginal() {
        guard let selected, selected.inLibrary, let store, !catalogBusy else { return }
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(message: L10n.tr("Choose the file to use as the original for “\(selected.filename)”."))),
                  await FileChooser.confirm(ConfirmationRequest(title: L10n.tr("Replace the Original?"),
                    message: L10n.tr("“\(selected.filename)” will use \(url.lastPathComponent) from now on. Edits, history and metadata stay; crops and masks line up only if the new file has the same dimensions."),
                    action: L10n.tr("Replace"))) else { return }
            maintenance = L10n.tr("Checking \(url.lastPathComponent)…")
            defer { maintenance = nil }
            do { try await store.replaceOriginal(url, assetID: selected.id); await reloadSelection(); syncSoon(); notice = L10n.tr("Original replaced") }
            catch { self.failure = Failure(L10n.tr("Couldn’t Replace the Original"), error) }
        }
    }

    // MARK: Importers
    /// Device discovery starts, and sessions open, only after the user chooses an import source (`CameraImportModel.start`).
    func requestCameraImport() {
        guard store != nil, canStartJob else { return }
        cameraImporter.requestedCamera = nil
        showingCameraImport = true
    }
    /// Scan only a folder explicitly chosen by the user; never probe mounted volumes.
    func requestFolderImport() {
        guard store != nil, canStartJob else { return }
        Task {
            guard let urls = await FileChooser.open(FileOpenRequest(files: false, folders: true, multiple: true,
                                                                    message: L10n.tr("Choose a camera card or folder to scan."))) else { return }
            cardImport = CardImportRequest(roots: urls, title: urls.count == 1 ? urls[0].lastPathComponent : L10n.tr("\(urls.count) folders"), defaultMode: .copy)
        }
    }
    /// Imports what a card or storage browser selected.
    @discardableResult
    func importCandidates(_ candidates: [ImportCandidate], mode: CatalogImporter.ImportMode) -> Bool {
        guard let store, !candidates.isEmpty else { return false }
        guard canStartJob else { NSSound.beep(); notice = L10n.tr("Busy, try again in a moment"); return false }
        activity.start(.importing, title: L10n.tr("Importing photos"), total: candidates.count) { [weak self] job in
            await self?.runImport(candidates.map { ImportItem(url: $0.url, locator: $0.locator) }, mode: mode, store: store, job: job)
        }
        return true
    }
}

/// Reference or copy, inside the quick Import panel.
struct ImportModeAccessory: View {
    @ObservedObject var model: CatalogModel
    var body: some View {
        Picker(L10n.tr("Add photos by"), selection: $model.importMode) {
            ForEach(CatalogImporter.ImportMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.radioGroup).fixedSize().padding(12)
    }
}
