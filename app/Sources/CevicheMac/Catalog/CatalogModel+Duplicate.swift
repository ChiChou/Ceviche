import AppKit
import CevicheCore

/// Duplicate: a real second original beside the first (an APFS clone, so it takes no space until either changes),
/// added as its own photo with the same development, rating and metadata.
extension CatalogModel {
    func canDuplicate(_ targets: [CatalogAsset]) -> Bool {
        store != nil && !catalogBusy && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && !$0.isLatent }
    }

    func duplicate(_ targets: [CatalogAsset], editor: EditorModel) async {
        guard let store, canDuplicate(targets) else { return }
        // The open photo's unsaved changes belong to the copy too.
        guard await flushMetadata(), await editor.flushEdits() else { return }
        var made: [CatalogAsset] = [], failures: [String] = []
        for asset in targets {
            do {
                guard case .available(let url) = asset.availability(catalog: root) else {
                    throw EditorError.invalidDocument(L10n.tr("The original isn’t on this Mac."))
                }
                let originals = store.originalsRoot
                let (copy, locator) = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try CatalogImporter.duplicateOriginal(of: asset, at: url, originalsRoot: originals)
                }.value
                do { made.append(try await store.duplicate(asset, as: copy, locator: locator)) }
                catch { try? FileManager.default.removeItem(at: copy); throw error }
            } catch {
                failures.append("\(asset.filename): \(error.localizedDescription)")
            }
        }
        if !made.isEmpty {
            if let albumID = filter.albumID { await addToAlbum(albumID, assetIDs: made.map(\.id)) }
            indexer.workAvailable()
            await refresh(); syncSoon()
            if let shown = assets.first(where: { $0.id == made.last?.id }) { select(shown) }
        }
        if failures.isEmpty {
            notice = made.count == 1 ? L10n.tr("Duplicated as \(made[0].filename)") : L10n.tr("Duplicated \(made.count.formatted()) photos")
        } else {
            failure = Failure(L10n.tr("Some Photos Weren’t Duplicated"), summary: L10n.tr("Duplicated \(made.count) of \(targets.count) photos.\n").trimmingCharacters(in: .newlines), items: failures)
        }
    }
}
