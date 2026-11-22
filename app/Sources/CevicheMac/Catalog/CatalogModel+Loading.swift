import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import CevicheCore

/// Loading the grid a page at a time, selecting in it, and keeping thumbnails and metadata current.
extension CatalogModel {
    /// Sets the filter and queries immediately instead of after the typing debounce.
    func applyFilterNow(_ value: CatalogFilter) async {
        filter = value; refreshTask?.cancel()
        await refresh()
    }
    /// `throttled` is for typing and range dragging: the first change after a pause queries at once, and while changes
    /// keep coming results follow at most every `typingInterval`, the last change always included. Waiting for typing
    /// to stop showed nothing until it did, though each query takes milliseconds. A click refreshes at once. Changes
    /// made together in one turn of the run loop still make one refresh.
    func scheduleRefresh(throttled: Bool = true) {
        limit = Self.pageSize; refreshTask?.cancel()
        let wait = throttled ? max(.zero, Self.typingInterval - lastRefreshStart.duration(to: .now)) : .zero
        refreshTask = Task {
            if wait > .zero { try? await Task.sleep(for: wait) }
            if !Task.isCancelled { await refresh() }
        }
    }
    static let typingInterval: Duration = .milliseconds(120)
    func refresh() async {
        guard let store else { return }
        // This refresh reads the filter as it is now, so one still waiting to start has nothing left to do; left to
        // run, it would supersede this one and an awaited refresh would return before the grid is current.
        refreshTask?.cancel(); lastRefreshStart = .now
        refreshGeneration += 1; let generation = refreshGeneration
        let snapshot = filter
        do {
            let found = try await store.assets(filter: snapshot, limit: snapshot.geotagged ? nil : limit)
            let matching = try await store.count(filter: snapshot)
            guard generation == refreshGeneration else { return }
            // The grid first: the sidebar's dates, albums, imports and groups below don't depend on the filter.
            // Nothing is written that hasn't changed: an import refreshes every few photos, and each write redraws
            // every view on the model, and new `assets` lay the grid out again.
            if found != assets { assets = found }
            if matching != matchingCount { matchingCount = matching }
            if refreshedFolder != snapshot.folder { refreshedFolder = snapshot.folder }
            let groups = try await store.groups(area: snapshot.area)
            let albumList = try await store.albums()
            let imports = try await store.importGroups()
            var editedFilter = CatalogFilter(); editedFilter.recentEdits = true
            let editedCount = try await store.count(filter: editedFilter)
            let stacks = try await store.stackSizes()
            // The filmstrip under an open photo is the same collection: imports, merges and stitches join it as they land.
            let browsing = !showingLibrary && !browsingAssets.isEmpty && snapshot.area == .library
                ? try await store.assets(filter: snapshot).filter { $0.inLibrary } : nil
            // A folded group stands for all its photos wherever its cover is selected, so they are loaded with it.
            let covers = snapshot.area != .library || snapshot.everyGroupedPhoto ? [] : Set((found + (browsing ?? [])).filter {
                $0.stackID == $0.id && stacks[$0.id, default: 0] > 1 && !snapshot.expandedStacks.contains($0.id)
            }.map(\.id))
            let members = Dictionary(grouping: try await store.stackMembers(Array(covers)).sorted {
                ($0.id == $0.stackID ? 0 : 1, $0.captureTime ?? "", $0.filename) < ($1.id == $1.stackID ? 0 : 1, $1.captureTime ?? "", $1.filename)
            }, by: { $0.stackID ?? "" })
            // Selected photos the loaded pages don't reach stay selected while they still match: photos imported
            // ahead of them in the order push them past the last page without taking them out of the collection.
            let loaded = Set(found.map(\.id)).union(browsing?.map(\.id) ?? [])
            let unloaded = found.count < matching ? selectedIDs.union([selected?.id, selectionAnchorID].compactMap { $0 }).subtracting(loaded) : []
            let beyond = try await store.matching(Array(unloaded), filter: snapshot)
            guard generation == refreshGeneration else { return }
            // Fresh records also carry new thumbnails and ratings, and drop photos trashed, removed or archived.
            if let browsing {
                let sequence = Self.sequence(browsing, replacing: browsingAssets, keeping: selected?.id)
                if sequence != browsingAssets { browsingAssets = sequence }
            }
            if stacks != stackSizes { stackSizes = stacks }
            if members != groupMembers { groupMembers = members }
            if albumList != albums { albums = albumList }
            let days = ImportDayNode.tree(imports)
            if days != importDays { importDays = days }
            if editedCount != recentEditsCount { recentEditsCount = editedCount }
            updateAvailability(for: found, generation: generation)
            // The filmstrip's selection reaches past the Library's loaded pages.
            let reachable = loaded.union(beyond)
            if !selectedIDs.isSubset(of: reachable) { selectedIDs.formIntersection(reachable) }
            if let anchor = selectionAnchorID, !reachable.contains(anchor) { selectionAnchorID = nil }
            if showingLibrary, let selected, !reachable.contains(selected.id), !metadataPending, keyboardSelectionID == nil {
                self.selected = nil; history = []; selectedIndexError = nil; showMetadata { $0 = CatalogMetadata() }
                if let first = selectedCells.first { Task { await self.selectAsset(first, preservingSelection: true) } }
            }
            let tree = CaptureDateNode.tree(days: groups.dates, counts: groups.dayCounts)
            if tree != dates { dates = tree }
            if groups.kinds != kinds { kinds = groups.kinds }
            if groups.total != total { total = groups.total }
            if !totalLoaded { totalLoaded = true }
            if groups.trash != trashCount { trashCount = groups.trash }
            if groups.archive != archiveCount { archiveCount = groups.archive }
            if let selected {
                let current = try await store.asset(selected.id)
                let revisions = try await store.history(assetID: selected.id)
                let indexError = try await store.analysisJob(assetID: current.id)?.lastError
                guard generation == refreshGeneration, self.selected?.id == selected.id else { return }
                guard current.area == snapshot.area else { clearSelection(); return }
                if current != self.selected { self.selected = current }
                if revisions != history { history = revisions }
                if indexError != selectedIndexError { selectedIndexError = indexError }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// The filmstrip after a refresh: the collection as it is now, with the open photo kept where it was when it no
    /// longer matches (a flag or rating changed under a filter), and a photo opened on its own left alone.
    static func sequence(_ fresh: [CatalogAsset], replacing previous: [CatalogAsset], keeping openID: String?) -> [CatalogAsset] {
        guard let openID, !fresh.contains(where: { $0.id == openID }),
              let index = previous.firstIndex(where: { $0.id == openID }) else { return fresh }
        if previous.count == 1 { return previous }
        let kept = Set(fresh.map(\.id))
        var result = fresh
        result.insert(previous[index], at: previous[..<index].filter { kept.contains($0.id) }.count)
        return result
    }
    static let pageSize = 500
    /// Appends the next page only; earlier pages are not queried again.
    func loadMore() {
        guard hasMore, !loadingMore, let store else { return }
        loadingMore = true
        let generation = refreshGeneration, snapshot = filter, offset = assets.count, last = assets.last?.id
        Task {
            defer { loadingMore = false }
            do {
                let page = try await store.assets(filter: snapshot, limit: Self.pageSize, offset: offset)
                guard generation == refreshGeneration, assets.count == offset, assets.last?.id == last else {
                    // A refresh replaced the list meanwhile (an import adds photos every few seconds): the page is
                    // loaded with the list again, rather than dropped and the grid left short until the next scroll.
                    if filter == snapshot, hasMore { limit = max(limit, offset + Self.pageSize); await refresh() }
                    return
                }
                assets += page; limit = max(limit, assets.count)
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Loads the photos up to `index` in the current order, and a page past it.
    func load(through index: Int) async {
        guard hasMore, index >= assets.count else { return }
        limit = min(matchingCount, max(limit, index + Self.pageSize)); await refresh()
    }
    /// Loads every matching photo so selection and End reach past the loaded pages.
    func loadAll() async {
        guard hasMore else { return }
        limit = matchingCount; await refresh()
    }

    func select(_ asset: CatalogAsset, extending: Bool = false, toggling: Bool = false) {
        guard !interactionBusy else { return }
        let focus = keyboardSelectionID ?? selected?.id
        cancelLibraryKeyboardNavigation()
        var selection = MultiSelection(ids: selectedIDs, anchor: selectionAnchorID ?? focus)
        selection.click(asset.id, in: assets.map(\.id), extending: extending, toggling: toggling)
        selectedIDs = selection.ids; selectionAnchorID = selection.anchor
        let target = selectedIDs.contains(asset.id) ? asset : selectedCells.last
        keyboardSelectionID = target?.id
        let generation = keyboardSelectionGeneration
        Task {
            guard generation == keyboardSelectionGeneration else { return }
            if let target { await selectAsset(target, preservingSelection: true) }
            else if await flushMetadata(), generation == keyboardSelectionGeneration { clearSelection() }
            if generation == keyboardSelectionGeneration { keyboardSelectionID = nil }
        }
    }
    func cancelLibraryKeyboardNavigation() {
        keyboardSelectionID = nil; keyboardSelectionGeneration += 1; selectionGeneration += 1
    }
    func moveLibrarySelection(_ direction: CatalogGridMove, extending: Bool = false) {
        guard gridVisible, !interactionBusy else { return }
        if direction == .last, hasMore {
            Task { await loadAll(); if !hasMore { moveLibrarySelection(.last, extending: extending) } }
            return
        }
        let current = assets.firstIndex { $0.id == (keyboardSelectionID ?? selected?.id) }
        guard let index = direction.destination(from: current, count: assets.count, columns: libraryColumnCount, rows: libraryRows, keepsColumn: libraryRowsKeepColumns), index != current else { return }
        select(assets[index], extending: extending)
    }
    func selectAsset(_ asset: CatalogAsset, preservingSelection: Bool = false) async {
        guard !mutatingCatalog, !navigating, pendingDeletion == nil else { return }
        selectionGeneration += 1; let generation = selectionGeneration
        guard await flushMetadata(), let store else { return }
        do {
            let current = try await store.asset(asset.id)
            let revisions = try await store.history(assetID: current.id)
            let indexError = try await store.analysisJob(assetID: current.id)?.lastError
            guard generation == selectionGeneration else { return }
            if !preservingSelection { selectedIDs = [current.id]; selectionAnchorID = current.id }
            selected = current; showMetadata { $0 = current.metadata }
            history = revisions
            selectedIndexError = indexError
        } catch { self.error = error.localizedDescription }
    }
    func scheduleMetadata() {
        guard selected?.inLibrary == true, !mutatingCatalog, pendingDeletion == nil else { return }
        metadataPending = true; metadataTask?.cancel()
        // A half-typed date is not saved; the inspector shows the expected format instead.
        guard captureDayValid else { return }
        metadataTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            _ = await flushMetadata()
        }
    }
    /// New thumbnails (an edit saved, an import, a regenerated preview) reach the grid and the filmstrip as they are
    /// stored, gathered for a moment so a burst of them costs one fetch and one redraw.
    func watchThumbnails(of store: CatalogStore) {
        thumbnailWatchTask?.cancel(); thumbnailFlushTask?.cancel(); thumbnailFlushTask = nil; pendingThumbnailIDs = []; liveThumbnails = [:]
        thumbnailWatchTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: CatalogStore.thumbnailInstalled, object: store) {
                guard let id = note.userInfo?[CatalogStore.assetIDKey] as? String else { continue }
                guard let self, self.store === store else { return }
                self.pendingThumbnailIDs.insert(id)
                if self.thumbnailFlushTask == nil { self.scheduleThumbnailFlush(store) }
            }
        }
    }
    static let thumbnailThrottle: Duration = .milliseconds(300)
    private func scheduleThumbnailFlush(_ store: CatalogStore) {
        thumbnailFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.thumbnailThrottle)
            guard !Task.isCancelled, let self, self.store === store else { return }
            let ids = self.pendingThumbnailIDs; self.pendingThumbnailIDs = []
            let fresh = (try? await store.assets(ids: Array(ids))) ?? []
            guard !Task.isCancelled, self.store === store else { return }
            self.adoptThumbnails(of: fresh)
            // Thumbnails stored while fetching wait for the next round.
            self.thumbnailFlushTask = nil
            if !self.pendingThumbnailIDs.isEmpty { self.scheduleThumbnailFlush(store) }
        }
    }
    /// Only the thumbnail and the development it shows are taken, so ratings and flags set a moment ago stay.
    private func adoptThumbnails(of fresh: [CatalogAsset]) {
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard !byID.isEmpty else { return }
        func patched(_ list: [CatalogAsset]) -> [CatalogAsset]? {
            var list = list, changed = false
            for index in list.indices {
                guard let new = byID[list[index].id], new.thumbnailKey != list[index].thumbnailKey || new.renderKey != list[index].renderKey else { continue }
                list[index].thumbnailKey = new.thumbnailKey; list[index].thumbnailRenderKey = new.thumbnailRenderKey; list[index].renderKey = new.renderKey
                changed = true
            }
            return changed ? list : nil
        }
        if let list = patched(assets) { assets = list }
        if let list = patched(browsingAssets) { browsingAssets = list }
        if let selected, let list = patched([selected]) { self.selected = list[0] }
        if liveThumbnails.keys.contains(where: { byID[$0] != nil }) { liveThumbnails = liveThumbnails.filter { byID[$0.key] == nil } }
    }
    /// Previews of deleted photos, and thumbnails over the budget, go once the grid is up and then hourly, so
    /// neither opening nor browsing waits on the sweep.
    func schedulePreviewSweep(for store: CatalogStore) {
        previewSweepTask?.cancel()
        previewSweepTask = Task(priority: .utility) { [weak self] in
            var delay: Duration = .seconds(15)
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.store === store else { return }
                let evicted = (try? await store.sweepPreviews(budget: self.thumbnailBudget)) ?? 0
                if evicted > 0, self.store === store { await self.refresh() }
                delay = .seconds(3600)
            }
        }
    }
    func flushMetadata() async -> Bool {
        metadataTask?.cancel()
        guard metadataPending, let selected, let store else { return true }
        if !captureDayValid, self.selected?.id == selected.id {
            // Leaving an incomplete date keeps the stored one rather than blocking the selection.
            showMetadata { $0.captureDay = selected.metadata.captureDay }
        }
        let value = metadata
        // The photo left the catalog meanwhile (sync, another window): its pending Info goes with it, rather than
        // holding back every action until it can be saved.
        guard let current = try? await store.asset(selected.id) else { metadataPending = false; return true }
        do {
            let previous = current.metadata
            try await store.updateMetadata(value, assetID: selected.id)
            registerMetadataUndo(assetID: selected.id, from: previous, to: value)
            if self.selected?.id == selected.id, metadata == value { metadataPending = false }
            await refresh(); syncSoon(); return true
        } catch { self.failure = Failure(L10n.tr("Couldn’t Save the Information"), error); return false }
    }
}
