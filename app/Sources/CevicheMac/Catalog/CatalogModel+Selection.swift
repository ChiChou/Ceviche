import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Ratings, flags and labels on the selection; the filmstrip selection; collections and filters.
extension CatalogModel {
    /// After undo, redo or restore: re-query, and show the selected photo's stored metadata.
    func reloadSelection() async {
        await refresh()
        guard let selected, let store, let current = try? await store.asset(selected.id), self.selected?.id == current.id else { return }
        if current.area != filter.area { clearSelection(); return }
        self.selected = current; showMetadata { $0 = current.metadata }
        metadataPending = false
    }
    func clearSelection() {
        cancelLibraryKeyboardNavigation()
        selectionGeneration += 1; metadataTask?.cancel()
        selectedIDs = []; selectionAnchorID = nil
        selected = nil; history = []; selectedIndexError = nil; showMetadata { $0 = CatalogMetadata() }; metadataPending = false
    }
    /// Tile controls toggle: clicking the current rating or review state clears it.
    func updateQuickMetadata(_ asset: CatalogAsset, rating: Int? = nil, review: ReviewState? = nil) async {
        guard !isFolderIndex else { return }
        // Toggle against the persisted (or pending inspector) value, never a stale tile value.
        let current: CatalogMetadata
        if selected?.id == asset.id { current = metadata }
        else if let store {
            do {
                let stored = try await store.asset(asset.id)
                guard stored.inLibrary else { return }
                current = stored.metadata
            } catch { self.error = error.localizedDescription; return }
        } else { return }
        await setQuickMetadata([asset], rating: rating.map { current.rating == $0 ? 0 : $0 },
                               review: review.map { current.review == $0 ? .unreviewed : $0 })
    }
    /// Culling: sets rating and/or review on every target. Cells update immediately and the
    /// window stays interactive, so rapid key presses are never dropped. Only these fields
    /// change, preserving pending inspector edits and GPS metadata.
    /// Sets the label on every target, or clears it where every target already has it, as the Finder's tags do.
    func toggleLabel(_ label: CatalogLabel?, on targets: [CatalogAsset]) async {
        let current = targets.map { selected?.id == $0.id ? metadata.label : $0.metadata.label }
        await setQuickMetadata(targets, label: .some(label != nil && current.allSatisfy { $0 == label } ? nil : label))
    }
    func setQuickMetadata(_ targets: [CatalogAsset], rating: Int? = nil, review: ReviewState? = nil, label: CatalogLabel?? = nil) async {
        let targets = targets.filter { $0.inLibrary }
        // Ratings, flags and labels belong to a catalog; the keys that set them do nothing in a browsed folder.
        guard !isFolderIndex else { return }
        guard !targets.isEmpty, let store, !interactionBusy, rating != nil || review != nil || label != nil, await flushMetadata() else { return }
        let ids = Set(targets.map(\.id))
        for index in assets.indices where ids.contains(assets[index].id) {
            if let rating { assets[index].rating = rating }
            if let review { assets[index].review = review }
            if let label { assets[index].label = label }
        }
        for index in browsingAssets.indices where ids.contains(browsingAssets[index].id) {
            if let rating { browsingAssets[index].rating = rating }
            if let review { browsingAssets[index].review = review }
            if let label { browsingAssets[index].label = label }
        }
        if let selected, ids.contains(selected.id) {
            showMetadata {
                if let rating { $0.rating = rating }
                if let review { $0.review = review }
                if let label { $0.label = label }
            }
        }
        var failed = false
        do {
            let previous = try await store.updateQuickMetadata(assetIDs: targets.map(\.id), rating: rating, review: review, label: label)
            registerQuickMetadataUndo(previous: previous, rating: rating, review: review, label: label); syncSoon()
        } catch { failed = true; self.error = error.localizedDescription }
        // Re-query only when the change can move photos in or out of the current view.
        if failed || filter.minimumRating > 0 || filter.review != nil || filter.label != nil { await refresh() }
        else if let selected, ids.contains(selected.id), let store = self.store {
            do { history = try await store.history(assetID: selected.id) } catch { self.error = error.localizedDescription }
        }
    }
    /// Adds comma-separated keywords to every target photo.
    func addKeywords(_ text: String, to targets: [CatalogAsset]) async {
        let keywords = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !keywords.isEmpty, !targets.isEmpty, let store, !interactionBusy, await flushMetadata() else { return }
        do {
            let previous = try await store.addKeywords(keywords, assetIDs: targets.map(\.id))
            registerKeywordsUndo(previous: previous, added: keywords)
            if !previous.isEmpty { notice = previous.count == 1 ? L10n.tr("Keywords added") : L10n.tr("Keywords added to \(previous.count.formatted()) photos") }
            await reloadSelection()
        } catch { self.error = error.localizedDescription }
    }
    /// The photos culling keys and Photo menu commands apply to: the Library selection, or the open photo.
    func cullingTargets(editor: EditorModel) -> [CatalogAsset] {
        if gridVisible { return selectedAssets }
        if selectedIDs.count > 1 { return withGroups(browsingAssets(withIDs: selectedIDs)) }
        guard let id = shownAssetID(editor: editor) else { return [] }
        return browsingAssets(withIDs: [id])
    }
    /// Develop's filmstrip is on screen.
    func filmstripShown(editor: EditorModel) -> Bool { !showingLibrary && !developPanelsHidden && editor.showFilmstrip && !browsingAssets.isEmpty }
    /// ⌘A in Develop: every photo in the filmstrip, for pasting edits or stacking; the open photo stays open.
    func selectAllInFilmstrip(editor: EditorModel) {
        guard !interactionBusy, filmstripShown(editor: editor), let open = shownAssetID(editor: editor) else { return }
        selectedIDs = Set(browsingAssets.map(\.id)); selectionAnchorID = open
    }
    /// ⇧⌘A in Develop: back to the open photo alone.
    func deselectFilmstrip(editor: EditorModel) {
        guard !interactionBusy, let open = shownAssetID(editor: editor) else { return }
        selectedIDs = [open]; selectionAnchorID = open
    }
    func filmstripSelect(_ asset: CatalogAsset, extending: Bool = false, toggling: Bool = false) {
        guard !interactionBusy else { return }
        var selection = MultiSelection(ids: selectedIDs, anchor: selectionAnchorID ?? selectedIDs.first)
        selection.click(asset.id, in: browsingAssets.map(\.id), extending: extending, toggling: toggling)
        selectedIDs = selection.ids; selectionAnchorID = selection.anchor
    }
    /// Selects a group just expanded, so the photos it stood for while folded stay selected until another click; the
    /// cover stays the photo the inspector loads.
    func selectExpandedGroup(_ members: [CatalogAsset], cover: CatalogAsset) {
        guard members.count > 1 else { return }
        cancelLibraryKeyboardNavigation()
        selectedIDs = Set(members.map(\.id)); selectionAnchorID = cover.id
        if selected?.id != cover.id { Task { await selectAsset(cover, preservingSelection: true) } }
    }
    func selectAll() {
        guard gridVisible, !interactionBusy else { return }
        Task {
            await loadAll()
            guard let first = assets.first else { return }
            cancelLibraryKeyboardNavigation()
            selectedIDs = Set(assets.map(\.id)); selectionAnchorID = first.id
            if selected == nil { await selectAsset(first, preservingSelection: true) }
        }
    }
    func deselectAll() {
        guard gridVisible, !interactionBusy, !selectedIDs.isEmpty else { return }
        Task { if await flushMetadata() { clearSelection() } }
    }
    func showCollection(trash: Bool, geotagged: Bool = false) async {
        await showCollection(area: trash ? .trash : .library, geotagged: geotagged)
    }
    func showCollection(area: CatalogArea, geotagged: Bool = false, faces: Bool = false) async {
        guard !interactionBusy, await flushMetadata() else { return }
        clearSelection(); mapFocus = nil
        showingOverview = true; peopleSubpage = nil
        var value = baseFilter(); value.area = area; value.geotagged = geotagged && area == .library; value.withFaces = faces && area == .library
        await applyFilterNow(value)
    }
    /// A fresh filter for a new collection, keeping the chosen sort.
    func baseFilter() -> CatalogFilter {
        var value = CatalogFilter(); value.sort = filter.sort; value.ascending = filter.ascending
        // Browsing folders, nothing shows until a folder is chosen.
        value.nothing = isFolderIndex
        return value
    }
    /// Changing the key resets the direction to its natural order (newest, highest or A first).
    func setSort(_ sort: CatalogSort, ascending: Bool? = nil) {
        guard !interactionBusy else { return }
        let direction = ascending ?? (sort == filter.sort ? filter.ascending : sort.defaultAscending)
        filter.sort = sort; filter.ascending = direction
        preferences.set(sort.rawValue, forKey: "librarySort"); preferences.set(direction, forKey: "librarySortAscending")
        // The filmstrip follows the new order while a photo is open.
        if !showingLibrary, let store, !browsingAssets.isEmpty {
            let snapshot = filter
            Task {
                guard let reordered = try? await store.assets(filter: snapshot).filter({ $0.inLibrary }),
                      self.store === store, filter == snapshot, !showingLibrary else { return }
                browsingAssets = Self.sequence(reordered, replacing: browsingAssets, keeping: selected?.id)
            }
        }
    }
    /// Sidebar rows are mutually exclusive views: a file type or date replaces the other.
    func showSubset(kind: String? = nil, captureDay: String? = nil) {
        guard !interactionBusy else { return }
        var value = baseFilter(); value.search = filter.search; value.minimumRating = filter.minimumRating; value.review = filter.review
        value.area = filter.area; value.kind = kind; value.captureDay = captureDay; filter = value
    }

    func focusSearch() { searchFocusRequest += 1 }
    func clearFilters() {
        var value = baseFilter(); value.area = filter.area; value.geotagged = filter.geotagged; value.withFaces = filter.withFaces
        value.personID = filter.personID; value.mapArea = filter.mapArea
        value.albumID = filter.albumID; value.folder = filter.folder; value.recentlyAdded = filter.recentlyAdded
        value.importDay = filter.importDay; value.importBatchID = filter.importBatchID; value.recentEdits = filter.recentEdits
        filter = value
    }
}
