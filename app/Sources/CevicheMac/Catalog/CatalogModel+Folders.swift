import AppKit
import CevicheCore

/// Progress of indexing the folder shown in the grid.
struct FolderSync: Equatable {
    var path: String
    var done = 0
    var total = 0
    /// New photos are being listed; thumbnails, and their count, come after.
    var listing = false
}

/// Photos opened from the Finder, waiting for their folder's listing.
struct FinderPhotos {
    var folder: String
    /// Paths as the listing spells them, the one to open first.
    var paths: [String]
    weak var editor: EditorModel?
}

/// A folder that cannot be shown.
enum FolderIssue: Equatable {
    /// The system refused the read: privacy settings, or file permissions.
    case denied(String)
    case missing(String)
}

/// Browsing folders in place. Choosing a folder in the sidebar shows what the catalog already has from it at once,
/// then indexes the rest by reference in the background and follows files added and deleted there while it is shown.
extension CatalogModel {
    /// Shows `url` in the grid and brings the catalog up to date with it.
    func showFolder(_ url: URL, root: String? = nil) async {
        guard FileAccess.shared.authorizeFolder(url) else { return }
        // The tab is switching to the folders' own index: wait for it rather than list into the catalog.
        if sidebarTab == .folders, !isFolderIndex { await openFolderIndex() }
        guard store != nil, !interactionBusy, await flushMetadata() else { return }
        clearSelection()
        let path = CatalogFolders.path(url)
        var value = baseFilter(); value.folder = path; value.subfolders = folderSubfolders
        folderRoot = root; folderStopped = nil
        if filter.folder == path, filter.subfolders == value.subfolders { syncFolder() } else { filter = value }
    }

    /// Photos or a folder from the Finder: the Folders view shows the folder, with nothing imported, and selects the
    /// photos as soon as they are listed; one photo opens in Detail. Photos from several folders show the first's.
    func openInPlace(_ urls: [URL], editor: EditorModel) async {
        guard let first = urls.first else { return }
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isFolder ? first : first.deletingLastPathComponent()
        let path = CatalogFolders.path(folder)
        let photos = isFolder ? [] : urls.filter { CatalogFolders.path($0.deletingLastPathComponent()) == path }
            .map { path + "/" + $0.lastPathComponent }
        restoringTab = false; showSidebar = true
        if sidebarTab != .folders { sidebarTab = .folders }
        pendingFinderPhotos = photos.isEmpty ? nil : FinderPhotos(folder: path, paths: photos, editor: editor)
        folders.activate()
        let root = folders.reveal(path)
        if root != nil { folderScrollTarget = path }
        await showFolder(folder, root: root)
        guard filter.folder == path else { pendingFinderPhotos = nil; return }
        await openFinderPhotos(listingDone: false)
    }

    /// Selects the photos from the Finder once the shown folder lists them, and opens a single one in Detail.
    /// `listingDone`: the folder is read through, so photos still missing aren't coming (not photos, or unreadable).
    func openFinderPhotos(listingDone: Bool) async {
        guard let pending = pendingFinderPhotos, let store else { return }
        guard filter.folder == pending.folder, let editor = pending.editor else { pendingFinderPhotos = nil; return }
        let found = ((try? await store.assets(filter: filter)) ?? []).filter { pending.paths.contains($0.sourcePath) && $0.inLibrary }
        guard pendingFinderPhotos?.folder == pending.folder, self.store === store else { return }
        guard let photo = pending.paths.lazy.compactMap({ path in found.first { $0.sourcePath == path } }).first else {
            if listingDone { pendingFinderPhotos = nil; NSSound.beep() }
            return
        }
        // Some may still be listing; those that are here are enough to go on with.
        pendingFinderPhotos = nil
        await selectAsset(photo)
        if found.count > 1 { selectedIDs = Set(found.map(\.id)) } else { develop(photo, editor: editor) }
    }

    static let lastFolderKey = "lastFolder", lastFolderRootKey = "lastFolderRoot"
    /// The folder last shown in the Folders view, shown again when the view opens: at launch and on coming back from
    /// the Library. Nothing when it is gone, or a volume it was on is not mounted.
    func showLastFolder() async {
        guard isFolderIndex, filter.folder == nil, let path = preferences.string(forKey: Self.lastFolderKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let root = preferences.string(forKey: Self.lastFolderRootKey)
        if root != nil { folderScrollTarget = path }
        await showFolder(URL(fileURLWithPath: path, isDirectory: true), root: root)
    }

    /// The folder in the filter changed: stop indexing the old one, start on the new one.
    func folderChanged() {
        folderSyncTask?.cancel(); folderSyncTask = nil
        folderSyncGeneration += 1
        folderSync = nil; folderIssue = nil; folderCount = 0; folderResync = false
        // The folder left behind must not stay on screen under the new one's name while that one is read.
        if isFolderIndex, !assets.isEmpty { assets = [] }
        if folders.changed == nil {
            // A busy tree changes all the time: a read under way is finished, not started over at every change.
            folders.changed = { [weak self] path in
                guard let self, self.filter.folder == path else { return }
                if self.folderSyncTask != nil { self.folderResync = true } else { self.syncFolder() }
            }
        }
        folders.pin(filter.folder, deep: filter.subfolders)
        if filter.folder == nil { folderRoot = nil } else { syncFolder() }
        if isFolderIndex, let path = filter.folder {
            preferences.set(path, forKey: Self.lastFolderKey); preferences.set(folderRoot, forKey: Self.lastFolderRootKey)
        }
    }

    /// Brings the catalog in line with the shown folder. Runs when the folder is chosen, when its contents change on
    /// disk and when the app comes forward; a run already under way is replaced, since the folder is listed again.
    func syncFolder() {
        guard let store, let path = filter.folder, folderStopped != path, !folderImporting else { return }
        let deep = filter.subfolders
        folderSyncTask?.cancel()
        folderSyncGeneration += 1
        let generation = folderSyncGeneration
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Listing has no count yet; the grid shows it is busy rather than empty.
        if folderSync == nil { folderSync = FolderSync(path: path) }
        // A file that failed is tried again only once it changes, such as a copy that was still arriving.
        let skipping = Set((folderFailures[path] ?? [:]).filter { Self.modified($0.key) == $0.value }.keys)
        let keeping = selectedIDs.union(selected.map { [$0.id] } ?? [])
        folderSyncTask = Task { [weak self] in
            do {
                let result = try await CatalogFolders.sync(url, store: store, deep: deep, folderData: self?.isFolderIndex == true, skipping: skipping, keeping: keeping, listed: { [weak self] in
                    await self?.folderListed(store)
                }, progress: { [weak self] done, total in
                    await self?.folderProgress(FolderSync(path: path, done: done, total: total), generation: generation)
                })
                guard let self, self.store === store else { return }
                var failures = (self.folderFailures[path] ?? [:]).filter { skipping.contains($0.key) }
                for file in result.failedPaths { failures[file] = Self.modified(file) }
                self.folderFailures[path] = failures.isEmpty ? nil : failures
                if result.added + result.removed > 0 {
                    self.indexer.workAvailable(); self.placeNamer.workAvailable(); self.syncSoon()
                }
                guard self.folderSyncGeneration == generation else {
                    // Replaced by a newer run; what this one added still has to show.
                    if result.added + result.removed > 0 { await self.refresh() }
                    return
                }
                self.folders.pin(path, readable: true, deep: deep)
                self.folderCount = result.found; self.folderSync = nil; self.folderIssue = nil
                if result.added + result.removed > 0 || Task.isCancelled { await self.refresh() }
                self.folderSyncTask = nil
                await self.openFinderPhotos(listingDone: true)
                if self.folderResync {
                    self.folderResync = false
                    try? await Task.sleep(for: .seconds(2))
                    if self.folderSyncGeneration == generation, self.folderSyncTask == nil { self.syncFolder() }
                }
            } catch {
                guard let self, self.folderSyncGeneration == generation else { return }
                self.folderSync = nil; self.pendingFinderPhotos = nil
                self.folderIssue = CatalogFolders.isDenied(error) ? .denied(path) : .missing(path)
            }
        }
    }

    /// Photos were listed: they show at once, as placeholders their thumbnails fill in behind.
    private func folderListed(_ listedIn: CatalogStore) async {
        guard store === listedIn else { return }
        if folderSync != nil, folderSync?.listing != true { folderSync?.listing = true }
        await refresh()
        await openFinderPhotos(listingDone: false)
    }

    /// Thumbnails reach their tiles on their own (`watchThumbnails`); this only moves the count.
    private func folderProgress(_ progress: FolderSync, generation: Int) async {
        guard folderSyncGeneration == generation else { return }
        folderSync = progress
    }

    /// Stops indexing the shown folder. What is listed stays; choosing the folder again carries on.
    func stopFolderSync() {
        guard let path = filter.folder, folderSyncTask != nil else { return }
        folderStopped = path
        folderSyncTask?.cancel(); folderSyncTask = nil
        folderSyncGeneration += 1
        folderSync = nil
    }

    /// Shows the folders below the chosen folder as well, or only the folder itself.
    func setFolderSubfolders(_ on: Bool) {
        guard folderSubfolders != on, !interactionBusy else { return }
        folderSubfolders = on
        guard filter.folder != nil else { return }
        folderStopped = nil
        clearSelection(); filter.subfolders = on
    }

    /// Asks again after the person changes the privacy settings.
    func retryFolder() {
        guard let path = filter.folder else { return }
        guard FileAccess.shared.authorizeFolder(URL(fileURLWithPath: path, isDirectory: true)) else { return }
        folderIssue = nil; folderStopped = nil
        folders.retry(path)
        syncFolder()
    }

    /// Welcome: browse folders without setting anything up. The catalog that indexes them is the default library,
    /// made the first time, as Import Photos makes it.
    func browseFolders() {
        showSidebar = true
        if sidebarTab == .folders { Task { await openFolderIndex() } } else { sidebarTab = .folders }
    }

    /// Where the index of browsed folders lives: the system's cache folder, which the person and the system may
    /// empty. Nothing that matters is only there; ratings, labels, text and edits are kept in each folder.
    static var folderIndexRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "me.chichou.ceviche", isDirectory: true).appendingPathComponent("Folders.cevichecatalog", isDirectory: true)
    }

    /// The tabs are two places: the person's catalog, and the folders on disk with their own index.
    func tabChanged() {
        restoringTab = false
        Task {
            if sidebarTab == .folders, !isFolderIndex { await openFolderIndex(); await showLastFolder() }
            else if sidebarTab == .catalog, isFolderIndex { await openLibrary() }
        }
    }

    func openFolderIndex() async {
        if let opening = folderIndexOpening { await opening.value; return }
        let opening = Task { await openFolderIndexNow() }
        folderIndexOpening = opening
        await opening.value
        folderIndexOpening = nil
    }
    private func openFolderIndexNow() async {
        guard !isFolderIndex || store == nil else { return }
        let root = folderIndexOverride ?? Self.folderIndexRoot
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        await openCatalog(root, manifest: Self.catalogExists(at: root) ? nil : CatalogManifest(name: L10n.tr("Folders"), kind: .local), folderIndex: true)
        // The index only caches what the folders and their sidecars hold: one from an earlier build, or damaged, is
        // set aside and made again rather than leaving the Folders tab unusable.
        if !isFolderIndex, let failure = catalogOpenFailure, failure.folderIndex, failure.root == root, failure.reason != .newer {
            let aside = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".old")
            try? FileManager.default.removeItem(at: aside)
            if (try? FileManager.default.moveItem(at: root, to: aside)) != nil {
                catalogOpenFailure = nil
                await openCatalog(root, manifest: CatalogManifest(name: L10n.tr("Folders"), kind: .local), folderIndex: true)
            }
        }
        // Could not be opened: stay with the catalog.
        if !isFolderIndex, sidebarTab == .folders { sidebarTab = .catalog }
    }

    /// Back to the person's catalog; the default library is made if they have none yet, as importing makes it.
    func openLibrary() async {
        let saved = libraryRoot ?? preferences.string(forKey: "catalogRoot").map { URL(fileURLWithPath: $0) }
        let root = saved.flatMap { Self.catalogExists(at: $0) ? $0 : nil } ?? Self.defaultCatalogRoot
        await openCatalog(root, manifest: Self.catalogExists(at: root) ? nil : CatalogManifest(name: L10n.tr("Library"), kind: .local))
        if isFolderIndex, sidebarTab == .catalog { sidebarTab = .folders }
    }

    /// From a folder's menu in the sidebar: moves the folder, with everything in it, to the Finder's Trash, after
    /// asking. The index forgets its photos; their edits go with the folder, in the sidecars.
    func trashFolder(_ folder: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("Move “\(folder.lastPathComponent)” to Trash?")
        alert.informativeText = L10n.tr("The folder and everything in it move to the Finder’s Trash.")
        alert.addButton(withTitle: L10n.tr("Move to Trash")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let path = CatalogFolders.path(folder)
        Task {
            // Shown, or a folder inside it is: nothing of it should stay on screen, or be listed again, while it goes.
            if let shown = filter.folder, shown == path || shown.hasPrefix(path + "/") {
                folderSyncTask?.cancel(); folderSyncTask = nil
                clearSelection(); filter = baseFilter()
            }
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try FileManager.default.trashItem(at: folder, resultingItemURL: nil); return nil } catch { return error.localizedDescription }
            }.value
            if let failure { self.failure = Failure(L10n.tr("Couldn’t Move the Folder to Trash"), failure); return }
            if let store { try? await store.forgetFolder(below: path) }
            folders.removed(path)
            await refresh()
        }
    }

    /// Follows edits made in the index into the photos' XMP sidecars, from where the last run left off.
    func followFolderEdits(of store: CatalogStore) {
        let stamp = store.root.appendingPathComponent("folder-edits-flushed")
        let since = (try? String(contentsOf: stamp, encoding: .utf8)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        folderEditsTask = Task.detached(priority: .utility) {
            await FolderEdits.follow(store, since: since) { mark in
                try? String(mark.timeIntervalSince1970).write(to: stamp, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Files and Folders in System Settings, where access to Desktop, Documents, Downloads and volumes is granted.
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
    }

    private nonisolated static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
