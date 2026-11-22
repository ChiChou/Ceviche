import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Opening photos in Detail and Compare, and moving along the filmstrip.
extension CatalogModel {
    /// Print Proof is a view of the photo in Develop: from the Library it opens the photo there with the proof on,
    /// in Develop it turns the proof on and off.
    func canPrintProof(_ targets: [CatalogAsset], editor: EditorModel) -> Bool {
        if viewMode == .detail { return editor.hasImage }
        return store != nil && !toolOpen && targets.count == 1 && targets[0].inLibrary
    }
    func togglePrintProof(_ targets: [CatalogAsset], editor: EditorModel) {
        guard canPrintProof(targets, editor: editor) else { return }
        if viewMode == .detail { editor.proof.on.toggle() } else { editor.proof.on = true; develop(targets[0], editor: editor) }
    }
    /// Opens the photo in the main window's Detail, even when the secondary window already shows it; that
    /// window keeps showing it.
    /// A double-click on a latent image opens its tool; switching to Develop with one selected shows its preview.
    func develop(_ asset: CatalogAsset, editor: EditorModel) {
        if asset.isLatent { openLatent(asset); return }
        Task { if await openPhoto(asset, editor: editor), viewMode == .grid { viewMode = .detail } }
    }
    @discardableResult
    func openPhoto(_ asset: CatalogAsset, editor: EditorModel, keepSequence: Bool = false, preservingSelection: Bool = false) async -> Bool {
        guard let store, !interactionBusy, asset.inLibrary, !editor.busy else { return false }
        navigating = true
        defer { navigating = false }
        let previousID = latentShown?.id ?? (editor.usesCatalog(store) ? editor.catalogAssetID : nil)
        guard await flushMetadata(), await editor.flushEdits(), self.store === store else { return false }
        do {
            let current = try await store.asset(asset.id)
            guard current.inLibrary else { return false }
            if current.isLatent {
                // Nothing to edit: Develop shows the latent image's preview, and its tool opens from there.
                refreshTask?.cancel(); refreshGeneration += 1; selectionGeneration += 1
                editor.closeDocument(); latentShown = current
                if viewMode == .compare { viewMode = .detail }
            } else {
                let original = try await resolveOriginal(current)
                guard self.store === store else { return false }
                refreshTask?.cancel(); refreshGeneration += 1; selectionGeneration += 1
                // Browsing always shows the finished crop without editing overlays.
                editor.endMask(); editor.setAdjustmentTarget(nil); editor.maskTool = nil; editor.comparing = false
                editor.lastOpenError = nil
                let opened = await editor.open(original, catalog: store, asset: current)
                if !opened, let parts = EditorModel.recoverableEdits(editor.lastOpenError) {
                    // Edits an earlier build saved, or that use a LUT or profile that is gone: Reset Unreadable takes
                    // out only what can't be read, when the rest can be kept; Reset Edits starts the photo over.
                    // Either opens it.
                    func reset(_ run: @escaping @MainActor (CatalogModel) async -> Void) -> @MainActor () -> Void {
                        { [weak self] in
                            guard let self else { return }
                            Task {
                                await run(self)
                                if await self.openPhoto(current, editor: editor), self.viewMode == .grid { self.viewMode = .detail }
                            }
                        }
                    }
                    var message = editor.lastOpenError!.localizedDescription, actions: [Failure.Action] = []
                    if !parts.isEmpty { message += "\n\n" + L10n.tr("Unreadable: \(parts.joined(separator: ", "))") }
                    if !parts.isEmpty || editor.lastOpenError is ResourceUnavailable {
                        actions.append(.init(title: L10n.tr("Reset Unreadable"), destructive: true, run: reset { await $0.resetUnreadableEdits(of: current, editor: editor) }))
                    }
                    actions.append(.init(title: L10n.tr("Reset Edits"), destructive: true, run: reset { await $0.resetEdits(targets: [current], editor: editor) }))
                    editor.failure = Failure(L10n.tr("Couldn’t Open the Photo"), message, actions: actions)
                }
                guard opened, editor.catalogAssetID == current.id, editor.usesCatalog(store) else { return false }
                latentShown = nil
            }
            if !keepSequence {
                browsingAssets = try await store.assets(filter: filter).filter { $0.inLibrary }
                if !browsingAssets.contains(where: { $0.id == current.id }) { browsingAssets = [current] }
            }
            if let i = browsingAssets.firstIndex(where: { $0.id == current.id }) { browsingAssets[i] = try await store.asset(current.id) }
            if !preservingSelection || !selectedIDs.contains(current.id) { selectedIDs = [current.id]; selectionAnchorID = current.id }
            selected = current; showMetadata { $0 = current.metadata }
            metadataPending = false; history = try await store.history(assetID: current.id)
            // A photo that was the comparison partner is now the open one; the previous photo takes its place.
            if compareAsset?.id == current.id { setCompareAsset(browsingAssets.first { $0.id == previousID }, editor: editor) }
            else if let compareAsset, compareAsset.id != current.id, let fresh = browsingAssets.first(where: { $0.id == compareAsset.id }) { setCompareAsset(fresh, editor: editor) }
            // The photo opens in the main window unless the secondary window is the one showing photos.
            if viewMode == .grid, secondaryViewMode != .detail { viewMode = .detail }
            return true
        } catch { self.failure = Failure(L10n.tr("Couldn’t Open the Photo"), error); return false }
    }
    /// What Develop shows: the latent image, or the photo open in the editor.
    func shownAssetID(editor: EditorModel) -> String? { latentShown?.id ?? editor.catalogAssetID }
    func browseIndex(editor: EditorModel) -> Int? { shownAssetID(editor: editor).flatMap(browsingPosition) }
    /// The catalog photo or latent image open in Detail; nil for a file opened on its own.
    func openAsset(editor: EditorModel) -> CatalogAsset? {
        if let latentShown { return browsingAssets.first { $0.id == latentShown.id } ?? latentShown }
        guard let store, editor.usesCatalog(store), let id = editor.catalogAssetID else { return nil }
        return browsingAssets.first { $0.id == id } ?? (selected?.id == id ? selected : nil)
    }
    func canNavigate(_ offset: Int, editor: EditorModel) -> Bool {
        guard !interactionBusy, !editor.busy, let index = browseIndex(editor: editor) else { return false }
        return browsingAssets.indices.contains(index + offset)
    }
    @discardableResult
    func navigate(_ offset: Int, editor: EditorModel) async -> Bool {
        guard !interactionBusy, !editor.busy, let index = browseIndex(editor: editor) else { return false }
        let next = index + offset
        guard browsingAssets.indices.contains(next) else { return false }
        return await openPhoto(browsingAssets[next], editor: editor, keepSequence: true)
    }
    func canShow(_ mode: ViewMode, editor: EditorModel) -> Bool {
        guard !interactionBusy, !editor.busy else { return false }
        if mode == .grid { return true }
        // A latent image has no pixels to compare.
        if mode == .compare, latentShown != nil || (showingLibrary && openTarget?.isLatent == true) { return false }
        return showingLibrary ? openTarget != nil : editor.hasImage || latentShown != nil
    }
    /// The photo Detail or Compare opens from the grid: the selection, or the first photo shown.
    private var openTarget: CatalogAsset? {
        if let selected { return selected.inLibrary ? selected : nil }
        return assets.first { $0.inLibrary }
    }
    /// G / D / ⌥C and ⌘1–4: the grid, or Detail and Compare with the selected photo. Compare pairs the
    /// first two selected photos when the grid has a multiple selection.
    func show(_ mode: ViewMode, editor: EditorModel) {
        guard canShow(mode, editor: editor), mode != viewMode else { return }
        switch mode {
        case .grid: returnToLibrary(editor: editor)
        case .detail, .compare:
            guard showingLibrary else { viewMode = mode; return }
            guard let target = openTarget else { return }
            let partner = mode == .compare ? selectedCells.first { $0.id != target.id && $0.inLibrary } : nil
            Task {
                guard await openPhoto(target, editor: editor) else { return }
                if let partner { compareSource = .twoPhotos; setCompareAsset(partner, editor: editor) }
                viewMode = mode
            }
        }
    }
    /// Leaves Detail or Compare for the grid.
    func back(editor: EditorModel) {
        guard !showingLibrary else { return }
        returnToLibrary(editor: editor)
    }
    /// The photo shown beside the open one in a two-photo comparison; `nil` clears it.
    func setCompareAsset(_ asset: CatalogAsset?, editor: EditorModel) {
        guard asset?.id != editor.catalogAssetID || asset == nil else { return }
        if let asset, !asset.inLibrary || asset.isLatent { return }
        compareAsset = asset
        renderComparePreview(editor: editor)
    }
    /// Called by the Compare view: without a chosen partner, a two-photo comparison pairs the open photo
    /// with its neighbour in the filmstrip, and the partner is rendered if it is not already.
    func prepareCompare(editor: EditorModel) {
        if compareSource == .twoPhotos, compareAsset == nil, let index = browsingAssets.firstIndex(where: { $0.id == editor.catalogAssetID }) {
            let neighbours = [index + 1, index - 1].filter { browsingAssets.indices.contains($0) && !browsingAssets[$0].isLatent }
            compareAsset = neighbours.first.map { browsingAssets[$0] }
        }
        renderComparePreview(editor: editor)
    }
    /// Renders the partner at the editing preview size with its saved development; the open photo is live.
    private func renderComparePreview(editor: EditorModel) {
        guard let asset = compareAsset, store != nil else { compareRenderTask?.cancel(); comparePreview = nil; compareRenderKey = nil; compareRendering = false; return }
        let sdr = editor.sdrPreview
        let key = asset.id + "|" + asset.renderKey + (sdr ? "|sdr" : "")
        guard key != compareRenderKey else { return }
        compareRenderTask?.cancel(); compareRenderKey = key; comparePreview = nil; compareRendering = true
        compareRenderTask = Task {
            defer { if compareRenderKey == key { compareRendering = false } }
            do {
                let url = try await resolveOriginal(asset)
                try Task.checkCancellation()
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try RawRenderer.open(url, hdr: asset.hdr)
                }.value
                let settings = try await store?.savedAdjustments(of: asset) ?? loaded.1
                let image = try await loaded.0.displayImage(settings, maxDimension: 2200, sdr: sdr)
                guard !Task.isCancelled, compareRenderKey == key else { return }
                comparePreview = image
            } catch is CancellationError {
            } catch { if compareRenderKey == key { self.error = error.localizedDescription } }
        }
    }
    /// The grid's header and the breadcrumb in Detail and Compare.
    var collectionTitle: String {
        if let id = filter.albumID { return albums.first { $0.id == id }?.album.name ?? L10n.tr("Album") }
        if let folder = filter.folder { return (folder as NSString).lastPathComponent }
        // No folder chosen yet: there is no "All Photos" of folders.
        if isFolderIndex { return L10n.tr("Folders") }
        if let set = filter.photoSet {
            switch set.kind {
            case .similar(let id): return L10n.tr("Similar to \(assets.first { $0.id == id }?.filename ?? "")")
            case .duplicates: return L10n.tr("Duplicates")
            }
        }
        if filter.recentEdits { return L10n.tr("Recent Edits") }
        if let day = filter.importDay {
            let title = L10n.tr("Imported ") + CaptureDateNode.title(for: day, full: true)
            if let id = filter.importBatchID, let batch = importDays.first(where: { $0.id == day })?.batches.first(where: { $0.batchID == id }) {
                return title + " - " + batch.startedAt.localized(date: .omitted, time: .shortened)
            }
            return title
        }
        if filter.recentlyAdded { return L10n.tr("Recently Added") }
        let collection = filter.area == .trash ? L10n.tr("Trash") : filter.area == .archive ? L10n.tr("Archived") : filter.geotagged ? L10n.tr("Map") : filter.withFaces ? L10n.tr("People") : L10n.tr("All Photos")
        if let day = filter.captureDay { return CaptureDateNode.title(for: day, full: true) }
        return filter.kind ?? collection
    }
    func showInFinder(_ targets: [CatalogAsset]) {
        // Saved tool work lives only in the catalog.
        let targets = targets.filter { !$0.isLatent }
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.showInFinder(targets.map { CatalogImporter.sourceURL(for: $0, root: root) })
    }
    /// Lists every photo in Trash for one permanent-deletion confirmation.
    func requestEmptyTrash(editor: EditorModel) async {
        guard let store, trashCount > 0, !catalogBusy else { return }
        var trash = CatalogFilter(); trash.area = .trash
        do { await requestPermanentDeletion(try await store.assets(filter: trash), editor: editor) }
        catch { self.failure = Failure(L10n.tr("Couldn’t Empty the Trash"), error) }
    }
    func returnToLibrary(editor: EditorModel) {
        Task { await closePhoto(editor: editor) }
    }
    func closePhoto(editor: EditorModel) async {
        guard !interactionBusy, !editor.busy else { return }
        // With a secondary window the photo stays open: that window shows it once the main window takes the grid.
        if secondaryViewMode != nil { viewMode = .grid; return }
        navigating = true
        defer { navigating = false }
        guard await editor.flushEdits() else { return }
        editor.closeDocument(); latentShown = nil; viewMode = .grid
        browsingAssets = []; setCompareAsset(nil, editor: editor); compareSwapped = false
        await refresh(); syncSoon()
    }
}
