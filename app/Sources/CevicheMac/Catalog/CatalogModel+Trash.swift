import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// The Trash, and removing photos from the catalog for good.
extension CatalogModel {
    /// Whether trashing or removing can go ahead now; when it can't, says so rather than doing nothing. An import
    /// running beside it is no reason to wait (`catalogBusy`).
    private func refuseWhileBusy(_ editor: EditorModel?) -> Bool {
        guard catalogBusy || editor?.busy == true else { return true }
        NSSound.beep(); notice = L10n.tr("Busy, try again in a moment")
        return false
    }
    private func prepareCatalogMutation(editor: EditorModel, ids: Set<String>) async -> Bool {
        guard refuseWhileBusy(editor), await flushMetadata() else { return false }
        if let latent = latentShown, ids.contains(latent.id) { latentShown = nil }
        if let id = editor.catalogAssetID, ids.contains(id), editor.usesCatalog(store) {
            guard await editor.flushEdits() else { return false }
            editor.closeDocument(); setCompareAsset(nil, editor: editor)
        }
        refreshTask?.cancel(); refreshGeneration += 1; cancelLibraryKeyboardNavigation()
        indexer.cancelCurrent()
        return true
    }
    /// Move to Trash from a key (Delete or ⌘⌫) asks first, since a stray key press is easy to make; a click on a menu
    /// item, the context menu or a button moves the photos at once.
    func requestMoveToTrash(_ targets: [CatalogAsset], editor: EditorModel) {
        guard !targets.isEmpty else { return }
        if NSApp.currentEvent?.type == .keyDown { pendingTrash = targets }
        else { Task { await moveToTrash(targets, editor: editor) } }
    }
    func moveToTrash(_ targets: [CatalogAsset], editor: EditorModel) async {
        let ids = Set(targets.map(\.id))
        let deletingOpenPhoto = latentShown.map { ids.contains($0.id) } ?? (editor.usesCatalog(store) && editor.catalogAssetID.map { ids.contains($0) } == true)
        let keepDevelop = viewMode != .grid && deletingOpenPhoto
        let sequence = browsingAssets.isEmpty ? assets : browsingAssets
        let index = sequence.firstIndex { $0.id == shownAssetID(editor: editor) } ?? 0
        let next = (Array(sequence.dropFirst(index + 1)) + Array(sequence.prefix(index).reversed()))
            .first { !ids.contains($0.id) && $0.inLibrary }
        guard !ids.isEmpty, let store, await prepareCatalogMutation(editor: editor, ids: ids), self.store === store else { return }
        mutatingCatalog = true
        defer { mutatingCatalog = false }
        do {
            if isFolderIndex {
                // A folder's photos are files: they go to the Finder's Trash, where Put Back returns them.
                let trashed = try await Self.trashOriginals(targets, root: store.root)
                _ = try await store.forgetVanished(trashed, whateverWasMade: true)
                guard trashed.count == ids.count else {
                    await refresh()
                    throw EditorError.invalidDocument(L10n.tr("\(ids.count - trashed.count) photos could not be moved to the Trash."))
                }
            } else {
                let groups = try await store.moveToTrash(Array(ids))
                registerTrashUndo(Array(ids), movedToTrash: true, groups: groups)
            }
            if let selected, ids.contains(selected.id) { clearSelection() }
            if keepDevelop { browsingAssets = sequence.filter { !ids.contains($0.id) } }
            else { browsingAssets.removeAll { ids.contains($0.id) } }
            await refresh(); syncSoon(); notice = Self.counted(ids.count, .movedToTrash)
            if keepDevelop, let next {
                mutatingCatalog = false
                _ = await openPhoto(next, editor: editor, keepSequence: true)
            }
        } catch { self.failure = Failure(L10n.tr("Couldn’t Move to Trash"), error) }
    }
    /// Moves the originals, and the sidecars beside each, to the Finder's Trash; returns the photos that went. Put
    /// back together from the Trash, a photo has its edits again.
    nonisolated static func trashOriginals(_ assets: [CatalogAsset], root: URL) async throws -> [String] {
        await Task.detached(priority: .userInitiated) {
            var trashed: [String] = []
            for asset in assets {
                let url = CatalogImporter.sourceURL(for: asset, root: root), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let own = XMPSidecar.cevicheURL(for: url)
                let sidecars = [(try? XMPPacket.sidecar(for: url)) ?? nil, FileManager.default.fileExists(atPath: own.path) ? own : nil].compactMap { $0 }
                // A file already gone from a folder that is still there was deleted in the Finder: nothing left to move.
                let manager = FileManager.default
                let gone = !manager.fileExists(atPath: url.path) && manager.fileExists(atPath: url.deletingLastPathComponent().path)
                guard gone || (try? manager.trashItem(at: url, resultingItemURL: nil)) != nil else { continue }
                for sidecar in sidecars { try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil) }
                trashed.append(asset.id)
            }
            return trashed
        }.value
    }
    func trashPhotosAndDeleteAlbum(_ id: String, editor: EditorModel) async {
        guard let store, refuseWhileBusy(editor) else { return }
        do {
            let ids = try await store.activeAlbumPhotoIDs(id)
            guard self.store === store, await prepareCatalogMutation(editor: editor, ids: Set(ids)), self.store === store else { return }
            mutatingCatalog = true
            defer { mutatingCatalog = false }
            try await store.trashPhotosAndDeleteAlbum(id, expectedPhotoIDs: ids)
            if let selected, ids.contains(selected.id) { clearSelection() }
            if filter.albumID == id {
                clearSelection()
                await applyFilterNow(baseFilter())
            } else { await refresh() }
            syncSoon()
            notice = Self.counted(ids.count, .movedToTrash)
        } catch { self.failure = Failure(L10n.tr("Couldn’t Move to Trash"), error) }
    }
    func recoverFromTrash(_ targets: [CatalogAsset]) async {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty, let store, refuseWhileBusy(nil), await flushMetadata(), self.store === store else { return }
        mutatingCatalog = true; indexer.cancelCurrent(); cancelLibraryKeyboardNavigation()
        defer { mutatingCatalog = false }
        do {
            try await store.recoverFromTrash(Array(ids))
            registerTrashUndo(Array(ids), movedToTrash: false)
            if let selected, ids.contains(selected.id) { clearSelection() }
            await refresh(); syncSoon(); notice = Self.counted(ids.count, .recovered)
        } catch { self.failure = Failure(L10n.tr("Couldn’t Recover the Photos"), error) }
    }
    /// Remove from Library and Empty Trash: the photos leave the catalog, and copies the catalog made at import are
    /// deleted with them. Referenced originals elsewhere stay unless the box is ticked. The confirmation opens from
    /// the catalog alone; no file is looked at before the deletion itself.
    func requestPermanentDeletion(_ targets: [CatalogAsset], editor: EditorModel) async {
        guard !targets.isEmpty, let store, refuseWhileBusy(editor), await flushMetadata(), self.store === store else { return }
        let removal: CatalogRemovalPlan
        do {
            preparingDeletion = true; cancelLibraryKeyboardNavigation()
            defer { preparingDeletion = false }
            removal = try await store.removalPlan(for: targets.map(\.id))
            guard !removal.entries.isEmpty else { await refresh(); return }
            // Save the open photo before the confirmation freezes its record; it closes if the record may go.
            if editor.catalogAssetID.map({ id in removal.entries.contains { $0.id == id } }) ?? false {
                guard await editor.flushEdits() else { return }
                editor.closeDocument(); setCompareAsset(nil, editor: editor)
            }
        } catch { self.failure = Failure(L10n.tr("Couldn’t Delete the Photos"), error); return }
        guard self.store === store else { return }
        indexer.cancelCurrent()
        deletionStore = store; deletionEditor = editor; deleteReferencedFiles = false
        pendingDeletion = CatalogDeletionBatch(removal: removal)
    }
    /// Shows the sheet's progress once the removal has run half a second; a quick one never shows it.
    private func revealDeletionProgress() {
        guard let id = pendingDeletion?.id else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.pendingDeletion?.id == id, self.pendingDeletion?.removing == true else { return }
            self.pendingDeletion?.showsProgress = true
        }
    }
    func cancelPermanentDeletion() {
        guard pendingDeletion?.removing != true else { return }
        pendingDeletion = nil; deletionStore = nil
    }
    /// The confirmation stays up, with its progress, until the photos are gone.
    func confirmPermanentDeletion() async {
        guard let batch = pendingDeletion, !batch.removing, let deletionStore, deletionStore === store, !mutatingCatalog else { return }
        let deletingReferences = deleteReferencedFiles && !batch.removal.references.isEmpty
        mutatingCatalog = true
        refreshTask?.cancel(); refreshGeneration += 1; cancelLibraryKeyboardNavigation()
        defer { mutatingCatalog = false; pendingDeletion = nil; self.deletionStore = nil; deletionEditor = nil }
        pendingDeletion?.removing = true; revealDeletionProgress()
        if deletingReferences { await deleteFiles(batch, store: deletionStore) }
        else {
            do {
                let copies = try await deletionStore.removeFromCatalog(batch.removal, deletingCopies: true)
                if let selected, batch.removal.entries.contains(where: { $0.id == selected.id }) { clearSelection() }
                let count = batch.removal.entries.count
                notice = Self.counted(count, .removed) + (copies == 0 ? "" : copies == 1 ? L10n.tr(" - its copy deleted") : L10n.tr(" - \(copies.formatted()) copies deleted"))
            } catch { self.failure = Failure(L10n.tr("Couldn’t Remove the Photos"), error) }
        }
        await refresh(); syncSoon()
    }
    /// Every original goes with its photos, referenced ones included. Each file is checked only as it is deleted;
    /// one that can't go is skipped, the rest still go, and what failed is listed once at the end.
    private func deleteFiles(_ batch: CatalogDeletionBatch, store: CatalogStore) async {
        let plans: [CatalogDeletionPlan]
        do { plans = try await store.deletionPlans(for: batch.removal.entries.map(\.id)) }
        catch { self.failure = Failure(L10n.tr("Couldn’t Delete the Photos"), error); return }
        if let editor = deletionEditor, let openURL = editor.sourceURL?.resolvingSymlinksInPath().standardizedFileURL {
            // A document open from one of the files closes too, saved first. Only a plan with its name is resolved.
            for plan in plans where plan.entries.contains(where: { $0.filename == openURL.lastPathComponent }) {
                guard await store.originalURL(plan) == openURL else { continue }
                guard await editor.flushEdits() else { return }
                editor.closeDocument(); setCompareAsset(nil, editor: editor); break
            }
        }
        var completed = 0, failures: [String] = []
        pendingDeletion?.progress = (0, plans.count)
        for (index, plan) in plans.enumerated() {
            do {
                try await store.deletePermanently(plan)
                completed += 1
                if let selected, plan.entries.contains(where: { $0.id == selected.id }) { clearSelection() }
            } catch {
                failures.append("\(plan.entries.first?.filename ?? ""): \(error.localizedDescription)")
            }
            pendingDeletion?.progress = (index + 1, plans.count)
        }
        if completed > 0 { notice = Self.counted(completed, .deleted) }
        if !failures.isEmpty {
            let head = (failures.count == 1 ? L10n.tr("1 photo couldn’t be deleted.\n") : L10n.tr("\(failures.count.formatted()) photos couldn’t be deleted.\n")).trimmingCharacters(in: .newlines)
            self.failure = Failure(L10n.tr("Some Photos Weren’t Deleted"), summary: head, items: failures)
        }
    }
}

struct CatalogDeletionBatch: Identifiable {
    let id = UUID()
    let removal: CatalogRemovalPlan
    /// Confirmed and under way.
    var removing = false
    /// Originals deleted so far, while referenced files go too.
    var progress: (done: Int, total: Int)?
    /// The removal has run long enough to show its progress.
    var showsProgress = false
}
