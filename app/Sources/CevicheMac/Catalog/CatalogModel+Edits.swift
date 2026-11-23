import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Copying, pasting and resetting edits across photos.
extension CatalogModel {
    func copyEdits(from asset: CatalogAsset, editor: EditorModel, _ copy: EditCopy = .everything) async {
        guard let store, !catalogBusy, !editor.busy, asset.inLibrary else { return }
        if editor.catalogAssetID == asset.id, editor.usesCatalog(store) { editor.copyEdits(copy); noteCopiedEdits(copy); return }
        guard let settings = await developedSettings(of: asset) else { return }
        editor.captureEdits(settings, baseline: asset.info.defaults, name: asset.filename, copy)
        noteCopiedEdits(copy)
    }
    /// A Library photo's saved development, or its camera defaults when it has none; nil after reporting an error.
    func developedSettings(of asset: CatalogAsset) async -> Adjustments? {
        guard let store else { return nil }
        mutatingCatalog = true
        defer { mutatingCatalog = false }
        do {
            let current = try await store.asset(asset.id)
            guard current.inLibrary else { return nil }
            if let saved = try await store.savedAdjustments(of: current) { return saved }
            if current.info.defaultsFromImport == true { return current.info.defaults }
            return try await Task.detached {
                let url = CatalogImporter.sourceURL(for: current, root: store.root), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try RawRenderer.open(url, hdr: current.hdr).1
            }.value
        } catch { self.error = error.localizedDescription; return nil }
    }
    /// Pastes the copied edits, or `transfer` for Sync Edits.
    func pasteEdits(to targets: [CatalogAsset], editor: EditorModel, transfer: EditTransfer? = nil) async {
        guard let copied = transfer ?? editor.copiedEdits else { return }
        await runEditBatch(targets, editor: editor, title: transfer == nil ? L10n.tr("Pasting edits") : L10n.tr("Syncing edits"),
                           inEditor: { editor.pasteEdits(copied) },
                           develop: { _, saved, defaults in try copied.applying(to: saved ?? defaults) },
                           save: { store, settings, baseline, id in try await store.saveEdits(settings, assetID: id, baseline: baseline) }) { completed, total, failures in
            if completed > 0, transfer != nil { self.notice = completed == 1 ? L10n.tr("Edits synced to 1 photo") : L10n.tr("Edits synced to \(completed.formatted()) photos") }
            else if completed > 0 { self.notice = completed == 1 ? L10n.tr("Edits pasted") : L10n.tr("Edits pasted to \(completed.formatted()) photos") }
            if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Edits Weren’t Pasted"), summary: L10n.tr("Pasted edits to \(completed) of \(total) photos.\n").trimmingCharacters(in: .newlines), items: failures) }
        }
    }
    func requestResetEdits(_ targets: [CatalogAsset]) {
        let live = targets.filter { $0.inLibrary }
        if !live.isEmpty { pendingReset = live }
    }
    func resetEdits(targets: [CatalogAsset], editor: EditorModel) async {
        await runEditBatch(targets, editor: editor, title: L10n.tr("Resetting edits"), cameraDefaults: true,
                           inEditor: {
                               // Awaited: a reset still running would find the editor saving, and leave the edits as they were.
                               guard await editor.resetAllEditsNow() else { throw EditorError.invalidDocument(editor.error ?? L10n.tr("Couldn’t Reset Edits")) }
                           },
                           develop: { _, _, defaults in defaults },
                           save: { store, settings, _, id in try await store.resetEdits(to: settings, assetID: id) }) { completed, total, failures in
            if completed > 0 { self.notice = completed == 1 ? L10n.tr("Edits reset") : L10n.tr("Edits reset on \(completed.formatted()) photos") }
            if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Edits Weren’t Reset"), summary: L10n.tr("Reset edits on \(completed) of \(total) photos.\n").trimmingCharacters(in: .newlines), items: failures) }
        }
    }

    /// Takes out only what `asset`'s saved edits hold that this build can't read; settings among them return to the
    /// camera's defaults.
    func resetUnreadableEdits(of asset: CatalogAsset, editor: EditorModel) async {
        await runEditBatch([asset], editor: editor, title: L10n.tr("Resetting edits"), cameraDefaults: true,
                           inEditor: {},
                           develop: { _, _, defaults in defaults },
                           save: { store, settings, _, id in try await store.resetUnreadableEdits(to: settings, assetID: id) }) { completed, _, failures in
            if completed > 0 { self.notice = L10n.tr("Unreadable edits reset") }
            if let failure = failures.first { self.failure = Failure(L10n.tr("Couldn’t Reset Edits"), failure) }
        }
    }

    /// Changes the edits of many photos as a job in the activity queue, with progress and Stop. The edits are stored
    /// first, without rendering, so the batch is done in moments; the thumbnails follow in their own job at
    /// low priority. The open photo goes through the editor; the others get `develop(assetID, saved, defaults)` and
    /// are stored with `save(store, settings, baseline, assetID)`. `defaults` is the camera's only with `cameraDefaults`
    /// or for a photo never edited; otherwise it is the saved edits, so the original need not be read.
    func runEditBatch(_ targets: [CatalogAsset], editor: EditorModel, title: String, cameraDefaults: Bool = false,
                              inEditor: @escaping @MainActor () async throws -> Void,
                              develop: @escaping @Sendable (String, Adjustments?, Adjustments) throws -> Adjustments,
                              save: @escaping @Sendable (CatalogStore, Adjustments, Adjustments, String) async throws -> String,
                              finished: @escaping @MainActor (_ completed: Int, _ total: Int, _ failures: [String]) -> Void) async {
        guard !targets.isEmpty, let store, !catalogBusy, !editor.busy,
              await flushMetadata(), self.store === store else { return }
        // A photo already in another running batch is left to that one.
        let claims = targets.map { "edits:\($0.id)" }.filter { activity.claim($0) }
        let mine = targets.filter { claims.contains("edits:\($0.id)") }
        guard !mine.isEmpty else { return }
        indexer.cancelCurrent()
        let batch = activity.start(.editing, title: title, detail: mine.count == 1 ? mine[0].filename : "", total: mine.count) { [weak self] job in
            guard let self else { return }
            defer { self.activity.release(claims) }
            var completed = 0, failures: [String] = [], done = 0, changed: [String] = []
            var lastRefresh = ContinuousClock.now
            @MainActor func record(_ asset: CatalogAsset, _ error: Error?) async {
                if let error { if !(error is CancellationError) { failures.append("\(asset.filename): \(error.localizedDescription)") } }
                else { completed += 1 }
                done += 1
                self.activity.update(job, completed: done, detail: asset.filename)
                if ContinuousClock.now - lastRefresh > .seconds(2) { await self.refresh(); lastRefresh = .now }
            }
            var queue = mine[...]
            if let open = queue.firstIndex(where: { editor.catalogAssetID == $0.id }), editor.usesCatalog(store) {
                // The editor stores its own thumbnail after saving.
                let asset = queue.remove(at: open)
                do {
                    let current = try await store.asset(asset.id)
                    guard current.inLibrary else { throw EditorError.invalidDocument(L10n.tr("Photo is in Trash.")) }
                    try await inEditor()
                    guard await editor.save() else { throw EditorError.invalidDocument(editor.error ?? L10n.tr("Could not save edits.")) }
                    await record(asset, nil)
                } catch { await record(asset, error) }
            }
            await withTaskGroup(of: (CatalogAsset, Result<String, Error>).self) { group in
                func add() {
                    guard !Task.isCancelled, let asset = queue.popFirst() else { return }
                    group.addTask {
                        do { return (asset, .success(try await Self.storeEdits(asset, store: store, cameraDefaults: cameraDefaults, develop: develop, save: save))) }
                        catch { return (asset, .failure(error)) }
                    }
                }
                for _ in 0..<Self.editBatchWidth { add() }
                while let (asset, result) = await group.next() {
                    switch result {
                    case .success: changed.append(asset.id); await record(asset, nil)
                    case .failure(let error): await record(asset, error)
                    }
                    add()
                }
            }
            await self.refresh(); self.syncSoon()
            finished(completed, mine.count, failures)
            self.updateThumbnails(changed, store: store)
        }
        // The job runs in the activity queue; waiting here only holds the caller's own task.
        await activity.wait(batch)
    }
    /// Photos rendered at once: the RAW decoder is mostly single-threaded per photo, so a few in parallel use the
    /// Mac's cores without crowding the editor and the grid.
    static let editBatchWidth = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// One photo of a batch: its new edits, without rendering. Gives the render key its thumbnail is to match.
    nonisolated private static func storeEdits(_ asset: CatalogAsset, store: CatalogStore, cameraDefaults: Bool,
                                               develop: @Sendable (String, Adjustments?, Adjustments) throws -> Adjustments,
                                               save: @Sendable (CatalogStore, Adjustments, Adjustments, String) async throws -> String) async throws -> String {
        let current = try await store.asset(asset.id)
        guard current.inLibrary else { throw EditorError.invalidDocument(L10n.tr("Photo is in Trash.")) }
        // Resetting replaces the saved edit with the camera's defaults without reading it, so even an edit this build
        // can't read any more resets.
        let saved = cameraDefaults ? nil : try await store.savedAdjustments(of: current)
        let defaults: Adjustments
        if let saved, !cameraDefaults { defaults = saved } else if current.info.defaultsFromImport == true {
            // The camera's defaults (as-shot white balance, noise reduction), recorded at import.
            defaults = current.info.defaults
        } else {
            // Imported before the catalog kept them: from the original's metadata, without decoding it.
            let url = CatalogImporter.sourceURL(for: current, root: store.root), access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let original = { () throws -> Adjustments in
                if try !CatalogImporter.matches(url, current) { throw EditorError.invalidDocument(L10n.tr("The original has changed. Locate the original before pasting edits.")) }
                return try RawRenderer.open(url, hdr: current.hdr).1
            }
            // A reset never needs the original: offline, changed or damaged, the defaults kept at import stand in.
            defaults = cameraDefaults ? ((try? original()) ?? current.info.defaults) : try original()
        }
        return try await save(store, try develop(current.id, saved, defaults), saved ?? defaults, current.id)
    }
}
