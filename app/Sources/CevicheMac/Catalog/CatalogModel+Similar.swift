import AppKit
import CevicheCore

/// Show Similar and Duplicates: photos found by their Vision feature prints (`CatalogStore+Prints`), shown in the grid
/// as a found set. The library's prints are read once and kept until background analysis adds more.
extension CatalogModel {
    func canShowSimilar(_ targets: [CatalogAsset]) -> Bool {
        store != nil && !isFolderIndex && targets.count == 1 && targets[0].inLibrary && !targets[0].isLatent
    }

    /// The library's prints: kept while background analysis has finished the same number of photos.
    private func loadPrints(_ store: CatalogStore) async throws -> CatalogPrintIndex {
        let key = indexing.complete
        if let cached = printCache, cached.key == key, cached.store === store { return cached.index }
        let index = try await store.printIndex()
        printCache = (key, store, index)
        return index
    }

    /// The photos that look like `asset`, nearest first, after it.
    func showSimilar(to asset: CatalogAsset, editor: EditorModel) async {
        guard let store, canShowSimilar([asset]) else { return }
        do {
            let index = try await loadPrints(store)
            var stand: CatalogPrint?
            if !index.ids.contains(asset.id) {
                // Not analysed yet: printed now, from the same small decode analysis uses.
                let url = try await resolveOriginal(asset)
                stand = await Task.detached(priority: .userInitiated) { () -> CatalogPrint? in
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return CatalogPrint.measure(url)
                }.value
                guard stand != nil else { notice = L10n.tr("This photo can’t be compared"); return }
            }
            let found = await Task.detached(priority: .userInitiated) { [index, stand] in index.similar(to: asset.id, print: stand) }.value
            await showFound(CatalogPhotoSet(kind: .similar(to: asset.id), ids: [asset.id] + found.map(\.id)), editor: editor)
            if found.isEmpty { notice = L10n.tr("No similar photos") }
        } catch { failure = Failure(L10n.tr("Couldn’t Find Similar Photos"), error) }
    }

    /// The library's duplicates, each photo beside its copies: the sidebar's Duplicates. The last search shows at once
    /// and a fresh one replaces it only if photos were added, analysed or removed since.
    func showDuplicates(editor: EditorModel) async {
        guard let store, !isFolderIndex, await flushMetadata(), self.store === store else { return }
        let cached = duplicateCache?.store === store ? duplicateCache?.groups : nil
        if let cached { await showFound(CatalogPhotoSet(kind: .duplicates, ids: cached.flatMap { $0 }), editor: editor) }
        do {
            async let waiting = store.photosWithoutPrint()
            let groups = try await searchDuplicates(store, priority: .userInitiated)
            let left = try await waiting
            // Moved on while the fresh search ran: the view is left alone.
            guard self.store === store, cached == nil || filter.photoSet?.kind == .duplicates else { return }
            if groups != cached { await showFound(CatalogPhotoSet(kind: .duplicates, ids: groups.flatMap { $0 }), editor: editor) }
            if groups.isEmpty { notice = left > 0 ? L10n.tr("No duplicates so far; \(left.formatted()) photos still to analyse") : L10n.tr("No duplicates found") }
            else if left > 0 { notice = L10n.tr("\(left.formatted()) photos still to analyse") }
        } catch { failure = Failure(L10n.tr("Couldn’t Find Duplicates"), error) }
    }

    /// Searches once in the background when a catalog opens, so Duplicates shows its count and opens at once.
    func prepareDuplicates(of store: CatalogStore) {
        duplicateCache = nil; duplicateCount = nil
        Task { _ = try? await searchDuplicates(store, priority: .utility) }
    }

    private func searchDuplicates(_ store: CatalogStore, priority: TaskPriority) async throws -> [[String]] {
        let groups = try await Task.detached(priority: priority) { try store.duplicates() }.value
        if self.store === store { duplicateCache = (store, groups); duplicateCount = groups.reduce(0) { $0 + $1.count } }
        return groups
    }

    /// The found set in the grid, in its order, with nothing else narrowing it.
    private func showFound(_ set: CatalogPhotoSet, editor: EditorModel) async {
        if !showingLibrary { await closePhoto(editor: editor) }
        clearSelection()
        var found = CatalogFilter()
        found.photoSet = set
        filter = found
        await refresh()
    }
}
