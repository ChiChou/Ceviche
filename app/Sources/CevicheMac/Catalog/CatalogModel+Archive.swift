import AppKit
import CevicheCore

/// The archive: photos out of the library with their files untouched (`CatalogAsset.archivedAt`), until the person
/// unarchives them, moves their originals to a folder, or removes them, files and all if they choose.
extension CatalogModel {
    func archive(_ targets: [CatalogAsset]) async {
        let ids = targets.filter(\.inLibrary).map(\.id)
        guard !ids.isEmpty, let store, !catalogBusy, await flushMetadata(), self.store === store else { return }
        mutatingCatalog = true; indexer.cancelCurrent(); cancelLibraryKeyboardNavigation()
        defer { mutatingCatalog = false }
        do {
            let archived = try await store.archive(ids)
            registerArchiveUndo(archived, archived: true)
            if let selected, archived.contains(selected.id) { clearSelection() }
            await refresh(); syncSoon(); notice = Self.counted(archived.count, .archived)
        } catch { self.error = error.localizedDescription }
    }
    func unarchive(_ targets: [CatalogAsset]) async {
        let ids = targets.filter { $0.area == .archive }.map(\.id)
        guard !ids.isEmpty, let store, !catalogBusy, await flushMetadata(), self.store === store else { return }
        mutatingCatalog = true; indexer.cancelCurrent(); cancelLibraryKeyboardNavigation()
        defer { mutatingCatalog = false }
        do {
            try await store.unarchive(ids)
            registerArchiveUndo(ids, archived: false)
            if let selected, ids.contains(selected.id) { clearSelection() }
            await refresh(); syncSoon(); notice = Self.counted(ids.count, .unarchived)
        } catch { self.error = error.localizedDescription }
    }
    func registerArchiveUndo(_ ids: [String], archived: Bool) {
        guard !ids.isEmpty else { return }
        registerUndo(archived ? L10n.tr("Archive") : L10n.tr("Unarchive"), undo: { store in
            if archived { try await store.unarchive(ids) } else { try await store.archive(ids) }
        }, redo: { store in
            if archived { try await store.archive(ids) } else { try await store.unarchive(ids) }
        })
    }

    /// Asks for a folder, confirms, then moves the archived photos' originals there and removes them from the catalog.
    func requestMoveToFolder(_ targets: [CatalogAsset]) {
        let photos = targets.filter { $0.area == .archive }
        guard !photos.isEmpty, store != nil, !catalogBusy else { return }
        let last = UserDefaults.standard.string(forKey: "archiveMoveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        Task {
            guard let folder = await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true,
                                                                         prompt: L10n.tr("Choose"), directory: last)) else { return }
            UserDefaults.standard.set(folder.path, forKey: "archiveMoveFolder")
            let title = photos.count == 1
                ? L10n.tr("Move “\(photos[0].filename)” to “\(folder.lastPathComponent)”?")
                : L10n.tr("Move \(photos.count.formatted()) originals to “\(folder.lastPathComponent)”?")
            guard await FileChooser.confirm(ConfirmationRequest(title: title,
                message: L10n.tr("Edits go with them as XMP sidecars. They leave the catalog, and this can’t be undone."),
                action: L10n.tr("Move"), destructive: true)) else { return }
            await moveToFolder(photos, folder: folder)
        }
    }
    func moveToFolder(_ photos: [CatalogAsset], folder: URL) async {
        guard let store, !catalogBusy, await flushMetadata(), self.store === store else { return }
        mutatingCatalog = true; indexer.cancelCurrent(); cancelLibraryKeyboardNavigation()
        defer { mutatingCatalog = false }
        let result = await moveOriginals(photos, to: folder)
        if let selected, result.moved.contains(selected.id) { clearSelection() }
        await refresh(); syncSoon()
        if !result.moved.isEmpty { notice = Self.counted(result.moved.count, .moved) }
        if !result.failures.isEmpty {
            failure = Failure(L10n.tr("Some Photos Weren’t Moved"), summary: (result.failures.count == 1 ? L10n.tr("1 photo couldn’t be moved.\n") : L10n.tr("\(result.failures.count.formatted()) photos couldn’t be moved.\n")).trimmingCharacters(in: .newlines),
                items: result.failures)
        }
    }

    /// Moves the photos' originals into `folder` with FileManager, whether the catalog made them or they were referenced,
    /// and removes them from the catalog. A name already in the folder gets a number. Each move is checked by size
    /// before its record goes. The photo's own sidecar (`name.JPG.xmp`) goes along, while one named like the shot
    /// (`name.xmp`) stays with the RAW; the development and metadata are written beside the moved file as `name.xmp`,
    /// as Export Originals writes them, unless a file of that name is already there. Returns the IDs moved and what failed.
    func moveOriginals(_ assets: [CatalogAsset], to folder: URL) async -> (moved: [String], failures: [String]) {
        guard let store else { return ([], []) }
        let root = self.root
        let job = activity.begin(.catalog, title: L10n.tr("Moving originals"))
        var moved: [String] = [], failures: [String] = []
        let folderAccess = folder.startAccessingSecurityScopedResource(); defer { if folderAccess { folder.stopAccessingSecurityScopedResource() } }
        for (index, asset) in assets.enumerated() {
            activity.update(job, completed: index, total: assets.count, detail: asset.filename)
            guard case .available(let url) = asset.availability(catalog: root) else { failures.append(L10n.tr("\(asset.filename): the original isn’t on this Mac.")); continue }
            let current: CatalogAsset, saved: Adjustments?, sourceXMP: Data?
            do {
                current = try await store.asset(asset.id)
                saved = try await store.savedAdjustments(of: current)
                sourceXMP = try await store.development(current.id).xmpData
            } catch { failures.append("\(asset.filename): \(error.localizedDescription)"); continue }
            let result = await Task.detached(priority: .userInitiated) { () -> (moved: Bool, failure: String?) in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let fm = FileManager.default
                var destination = folder.appendingPathComponent(url.lastPathComponent), number = 2
                while fm.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(number)").appendingPathExtension(url.pathExtension)
                    number += 1
                }
                let xmp: Data
                do {
                    let defaults = CatalogImporter.developmentDefaults(for: url, info: current.info)
                    xmp = try XMPCodec.encode(adjustments: saved ?? defaults, metadata: current.metadata, defaults: defaults, sourceData: sourceXMP, filename: url.lastPathComponent)
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    try fm.moveItem(at: url, to: destination)
                    guard try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { return (false, L10n.tr("\(url.lastPathComponent): the moved file doesn’t match the original.")) }
                } catch { return (false, "\(url.lastPathComponent): \(error.localizedDescription)") }
                let sidecar = url.appendingPathExtension("xmp")
                if fm.fileExists(atPath: sidecar.path) { try? fm.moveItem(at: sidecar, to: destination.appendingPathExtension("xmp")) }
                // The file has moved either way, so its record goes; a sidecar that can't be written is reported.
                let xmpURL = destination.deletingPathExtension().appendingPathExtension("xmp")
                guard !fm.fileExists(atPath: xmpURL.path) else { return (true, nil) }
                do { try xmp.write(to: xmpURL, options: .atomic); return (true, nil) }
                catch { return (true, "\(xmpURL.lastPathComponent): \(error.localizedDescription)") }
            }.value
            if result.moved { moved.append(asset.id) }
            if let failure = result.failure { failures.append(failure) }
        }
        do {
            if !moved.isEmpty { try await store.removeFromCatalog(try await store.removalPlan(for: moved), deletingCopies: false) }
        } catch { failures.append(error.localizedDescription) }
        activity.end(job, outcome: failures.isEmpty ? .done(Self.counted(moved.count, .moved)) : .failed(failures.joined(separator: "\n")))
        return (moved, failures)
    }
}

