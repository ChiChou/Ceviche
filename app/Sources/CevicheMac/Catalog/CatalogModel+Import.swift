import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Importing photos and XMP sidecars into the open catalog.
extension CatalogModel {
    /// The quick way in: a file panel for photos on this Mac. Reference or copy is chosen in the panel.
    /// The folder imports are copied into: the one shown, while browsing folders. Its photos stay plain files there,
    /// so there is nothing to choose between copying and referencing.
    var importFolder: URL? { filter.folder.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    func chooseImport() {
        Task {
            guard let urls = await FileChooser.open(FileOpenRequest(folders: true, multiple: true, message: L10n.tr("Choose photos or folders to import."),
                                                                    accessory: importFolder == nil ? AnyView(ImportModeAccessory(model: self)) : nil)) else { return }
            importFiles(urls)
        }
    }
    @discardableResult
    func importFiles(_ urls: [URL], mode: CatalogImporter.ImportMode? = nil, finished: ((ImportSummary) -> Void)? = nil) -> Bool {
        guard let store, !urls.isEmpty else { return false }
        guard canStartJob else { NSSound.beep(); notice = L10n.tr("Busy, try again in a moment"); return false }
        guard canImport else { NSSound.beep(); return false }
        urls.forEach { FileAccess.shared.remember($0) }
        let mode = mode ?? importMode
        activity.start(.importing, title: L10n.tr("Importing photos")) { [weak self] job in
            let accesses = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let files = try await Task.detached { try CatalogImporter.files(in: urls) }.value
                let summary = await self?.runImport(files.map { ImportItem(url: $0, locator: nil) }, mode: mode, store: store, job: job)
                finished?(summary ?? ImportSummary(stopped: true))
            } catch {
                self?.failure = Failure(L10n.tr("Couldn’t Import"), error)
                finished?(ImportSummary(failures: [Failure.Detail(path: urls.map(\.path).joined(separator: ", "), reason: error.localizedDescription)]))
            }
        }
        return true
    }
    /// A photo to import: a readable file, or a remote original to fetch first.
    struct ImportItem {
        var url: URL?
        var locator: AssetLocator?
        /// Session-local transfer path, used for RAW + JPEG pairing, never persisted as an original.
        var transferPath: String? = nil
        var download: (@MainActor (@escaping @MainActor (Double) -> Void) async throws -> ImportedPhotoFile)? = nil
        var pairingPath: String { transferPath ?? locator?.string ?? url.map { AssetLocator.describing($0).string } ?? "" }
        var filename: String { transferPath.map { ($0 as NSString).lastPathComponent } ?? locator?.filename ?? url?.lastPathComponent ?? L10n.tr("Photo") }
        /// Where the photo is, in full: its path on this Mac, else where it is on a volume, a share or a camera.
        var fullPath: String {
            if let url { return url.path }
            guard let locator else { return transferPath ?? filename }
            switch locator {
            case .file(let path): return path
            case .catalog(let path), .volume(_, let path), .smb(_, _, let path): return locator.storageDescription + "/" + path
            }
        }
    }
    struct ImportSummary {
        var imported = 0, duplicates = 0, inTrash = 0
        /// Each failed file, in full, with why.
        var failures: [Failure.Detail] = []
        var stopped = false
    }
    /// Shared by every importer. Copies skip photos the catalog already has by name and capture time.
    /// Imports running together claim each file before adding it, so the same photo is never added twice.
    @discardableResult
    func runImport(_ items: [ImportItem], mode: CatalogImporter.ImportMode, store: CatalogStore, job: UUID) async -> ImportSummary {
        // Never into the cache that indexes folders: its copies would go when the cache does.
        guard !isFolderIndex || importFolder != nil else { NSSound.beep(); return ImportSummary(stopped: true) }
        let items = rawJPEGImport.keep(items)
        var failures: [Failure.Detail] = []; var inTrash = 0; var duplicates = 0; var imported = 0; var lastImported: String?
        var importedAssets: [CatalogAsset] = []
        var claims: [String] = []
        defer { activity.release(claims) }
        let root = store.root
        let batchID = UUID().uuidString
        // While browsing a folder every import is a copy into it; the folder is left alone until the copies are in.
        let folder = importFolder, mode = folder == nil ? mode : .copy
        if folder != nil { folderImporting = true; folderSyncTask?.cancel() }
        defer { if folder != nil { folderImporting = false; syncFolder() } }
        let presence = mode == .copy ? ((try? await store.presence()) ?? CatalogPresence()) : CatalogPresence()
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            let name = item.filename
            activity.update(job, completed: index, total: items.count, detail: L10n.tr("\(index + 1) of \(items.count) - \(name)"))
            let key = item.locator.map(\.string) ?? item.url.map { AssetLocator.describing($0).string }
            if let key {
                guard activity.claim(key) else { duplicates += 1; continue }
                claims.append(key)
            }
            do {
                // Every original is keyed by its locator; a readable file's is derived from its path.
                if let url = item.url, item.locator == nil || item.locator?.scheme == .file,
                   let existing = try await store.existingImport(AssetLocator.describing(url).string) {
                    if existing.trashedAt != nil { inTrash += 1 } else { duplicates += 1 }
                    continue
                }
                if let locator = item.locator, locator.scheme != .file, let existing = try await store.existingImport(locator.string) {
                    if existing.trashedAt != nil { inTrash += 1 } else { duplicates += 1 }
                    continue
                }
                var downloaded: ImportedPhotoFile?
                defer { downloaded?.remove() }
                if let download = item.download {
                    downloaded = try await download { [weak self] fraction in
                        self?.activity.update(job, progress: (Double(index) + fraction) / Double(max(items.count, 1)))
                    }
                    try Task.checkCancellation()
                }
                var url = downloaded?.url ?? item.url
                if url == nil, let locator = item.locator {
                    status = L10n.tr("Fetching \(name) from \(locator.storageDescription)…")
                    defer { status = "" }
                    url = try await AssetResolver.fetch(locator, catalog: root)
                }
                guard let url else { throw EditorError.invalidDocument(L10n.tr("Nothing to import.")) }
                if mode == .copy, url.pathExtension.lowercased() != "xmp",
                   let fingerprint = await Task.detached(priority: .utility, operation: { try? CatalogImporter.fingerprint(url) }).value {
                    let claim = "fingerprint:\(fingerprint)"
                    guard !presence.contains(fingerprint), activity.claim(claim) else { duplicates += 1; continue }
                    claims.append(claim)
                }
                // Copies go where the catalog keeps originals: iCloud Drive for an iCloud catalog.
                var options = CatalogImporter.ImportOptions(mode: item.download == nil ? mode : .copy, catalogRoot: store.originalsRoot, locator: item.locator?.scheme == .file ? nil : item.locator)
                options.copyFolder = folder
                options.marksSidecarEdits = !isFolderIndex
                // The camera's preview makes the thumbnail: reading it is about a tenth of decoding a RAW, so each photo
                // can be opened as soon as it lands. Photos whose sidecar changes the look are rendered right after.
                options.embeddedPreview = true
                let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
                if let existing = try await store.existingImport(prepared.0.importPath) {
                    if existing.trashedAt != nil { inTrash += 1 } else { duplicates += 1 }
                } else {
                    var asset = prepared.0; asset.importBatchID = batchID
                    let inserted = try await store.insert(asset, thumbnail: prepared.1)
                    // On a network share or another drive, rendered as the grid shows it rather than all at once.
                    if asset.xmpData != nil, inserted.originalOnThisMac {
                        _ = await store.thumbnails.want([inserted.id], kind: .developed, priority: .background)
                    }
                    lastImported = inserted.id; imported += 1; importedAssets.append(inserted)
                    if imported == 1 { await showImportBatch(batchID, importedAt: inserted.importedAt, store: store) }
                }
            } catch is CancellationError { break
            } catch { failures.append(Failure.Detail(path: item.fullPath, reason: error.localizedDescription, url: item.url)) }
            if item.download != nil { activity.update(job, progress: Double(index + 1) / Double(max(items.count, 1))) }
            if index % 20 == 0 { await refresh() }
        }
        indexer.workAvailable(); placeNamer.workAvailable()
        // Measuring for culling waits until a Culling tool asks for it, so an import does only the indexing it needs.
        if rawJPEGImport == .both && groupRawJPEGPairsOnImport {
            for pair in RawJPEGPairs.pairs(importedAssets) { _ = try? await store.stack([pair.raw.id, pair.processed.id], cover: pair.raw.id) }
        }
        await refresh(); syncSoon()
        let stopped = Task.isCancelled
        var summary: [String] = []
        if duplicates > 0 { summary.append(L10n.tr("\(duplicates.formatted()) already in the catalog")) }
        if inTrash > 0 { summary.append(L10n.tr("\(inTrash.formatted()) already in Trash")) }
        if stopped || !summary.isEmpty { notice = ((stopped ? [L10n.tr("Import stopped")] : []) + summary).joined(separator: " - ") }
        let failed = failures.isEmpty ? nil : Failure(L10n.tr("Some Files Weren’t Imported"), summary: (failures.count == 1 ? L10n.tr("\(failures.count) file couldn’t be imported.\n") : L10n.tr("\(failures.count) files couldn’t be imported.\n")).trimmingCharacters(in: .newlines), details: failures)
        if let failed { failure = failed }
        var outcome = [(imported == 1 ? L10n.tr("\(imported.formatted()) photo imported") : L10n.tr("\(imported.formatted()) photos imported"))] + summary
        if !failures.isEmpty { outcome.append(L10n.tr("\(failures.count.formatted()) failed")) }
        activity.finish(job, title: L10n.tr("Import"), outcome: imported == 0 && !failures.isEmpty ? .failed(outcome.joined(separator: " - ")) : stopped ? .stopped : .done(outcome.joined(separator: " - ")),
                        result: lastImported.map { .photo($0) }, failure: failed)
        return ImportSummary(imported: imported, duplicates: duplicates, inTrash: inTrash, failures: failures, stopped: stopped)
    }
    /// The grid switches to the batch as its first photo lands, so new photos are culled apart from the catalog's
    /// others. A photo open in Detail or Compare keeps its sequence.
    /// Only from the whole catalog, or from the batch of an import that has finished: a search being typed, filters,
    /// an album, a folder or another running import's batch stay as they are, and the batch waits under Imports.
    private func showImportBatch(_ batchID: String, importedAt: Date, store: CatalogStore) async {
        guard self.store === store, showingLibrary, filter.importBatchID != batchID else { return }
        var whole = baseFilter(); whole.expandedStacks = filter.expandedStacks
        var finishedBatch = whole
        finishedBatch.recentlyAdded = true; finishedBatch.importDay = filter.importDay; finishedBatch.importBatchID = filter.importBatchID
        finishedBatch.sort = .importDate; finishedBatch.ascending = false
        let imports = activity.running.filter { $0.kind == .importing }.count
        guard filter == whole || (filter.importBatchID != nil && filter == finishedBatch && imports <= 1) else { return }
        let day = Calendar.current.dateComponents([.year, .month, .day], from: importedAt)
        guard let year = day.year, let month = day.month, let date = day.day else { return }
        await showCatalogGroup(recentlyAdded: true, importDay: String(format: "%04d-%02d-%02d", year, month, date), importBatchID: batchID)
    }
    func chooseXMPImport() {
        guard let selected, selected.inLibrary, !catalogBusy else { return }
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(types: [.xmp], message: L10n.tr("Choose an XMP file to apply. The current settings stay in History.")))
            else { return }
            await importXMP(from: url)
        }
    }
    func importXMP(from url: URL) async {
        guard let selected, selected.inLibrary, let store, !catalogBusy else { return }
        handlingXMP = true; defer { handlingXMP = false }
        guard await flushMetadata() else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let current = try await store.asset(selected.id)
            let saved = try await store.savedAdjustments(of: current)
            let result = try await Task.detached {
                let defaults = CatalogImporter.developmentDefaults(for: CatalogImporter.sourceURL(for: current, root: store.root), info: current.info)
                let base = saved ?? defaults
                return (try XMPCodec.apply(XMPPacket(url: url), to: base, metadata: current.metadata, defaults: defaults, profiles: current.info.profileResolver), base)
            }.value
            try await store.importXMP(result.0, assetID: current.id, baseline: result.1)
            await refresh()
            if self.selected?.id == current.id {
                showMetadata { $0 = result.0.metadata }
            }
            notice = L10n.tr("XMP settings imported")
            xmpReport = result.0.warnings.isEmpty ? XMPCodec.importedNotice : result.0.warnings.joined(separator: "\n\n")
        } catch { self.failure = Failure(L10n.tr("Couldn’t Import XMP"), error) }
    }
    func chooseXMPExport() {
        guard let selected, !catalogBusy else { return }
        Task {
            guard let url = await FileChooser.save(FileSaveRequest(name: (selected.filename as NSString).deletingPathExtension + ".ceviche.xmp", types: [.xmp]))
            else { return }
            await exportXMP(to: url)
        }
    }
    func exportXMP(to url: URL) async {
        guard let selected, selected.inLibrary, let store, !catalogBusy else { return }
        handlingXMP = true; defer { handlingXMP = false }
        guard await flushMetadata() else { return }
        do {
            let current = try await store.asset(selected.id)
            // XMP carries the development inline; this is the one place blobs leave the catalog as data.
            let saved = try await store.savedAdjustments(of: current)
            let sourceXMP = try await store.development(current.id).xmpData
            try await Task.detached {
                let original = CatalogImporter.sourceURL(for: current, root: store.root)
                let defaults = CatalogImporter.developmentDefaults(for: original, info: current.info)
                let settings = saved ?? defaults
                let data = try XMPCodec.encode(adjustments: settings, metadata: current.metadata, defaults: defaults, sourceData: sourceXMP, filename: original.lastPathComponent)
                try XMPCodec.write(data, to: url, protecting: original)
            }.value
            notice = L10n.tr("Exported ") + url.lastPathComponent; xmpReport = XMPCodec.exportNotice
        } catch { self.failure = Failure(L10n.tr("Couldn’t Export XMP"), error) }
    }
    func cancelImport() { activity.cancelAll(.importing) }
}
