import AppKit
import CevicheCore

struct IDPhotoRequest: Identifiable {
    let id = UUID()
    /// In the order they were selected; one photo opens straight into it, several open on the grid.
    let assets: [CatalogAsset]
    init(assets: [CatalogAsset]) { self.assets = assets }
    init(asset: CatalogAsset) { self.init(assets: [asset]) }
}

/// The white balance the tool set on a photo, to write to its development (the layout itself is never kept).
struct IDPhotoSave: Sendable {
    let asset: CatalogAsset
    let balance: IDPhotoWhiteBalance
}

/// ID Photo: passport, visa or ID photos cropped to an official spec from portraits, checked, and exported or printed
/// at the spec's size. Nothing new joins the catalog, and no layout is kept: only a white balance set in the tool goes
/// to the photo's development.
extension CatalogModel {
    /// A family's or a sitting's worth; each photo is developed and kept in memory while the tool is open.
    static let idPhotoBatchLimit = 24

    func canMakeIDPhoto(_ targets: [CatalogAsset]) -> Bool {
        store != nil && (1...Self.idPhotoBatchLimit).contains(targets.count) && targets.allSatisfy { $0.inLibrary && !$0.isLatent } && !catalogBusy
    }
    func requestIDPhoto(_ targets: [CatalogAsset], editor: EditorModel) {
        guard canMakeIDPhoto(targets) else { return }
        Task {
            // The open photo's unsaved development is what gets printed.
            guard await editor.flushEdits() else { return }
            idPhoto = IDPhotoRequest(assets: targets)
        }
    }

    /// The photo's saved development.
    func idPhotoSource(_ asset: CatalogAsset) async throws -> (URL, Adjustments?) {
        guard let store else { throw CancellationError() }
        let url = try await resolveOriginal(asset)
        let current = try await store.asset(asset.id)
        return (url, try await store.savedAdjustments(of: current))
    }

    /// Writes each white balance set in the tool to its photo's development as a History step, through the editor for
    /// the photo open in it.
    func saveIDPhotoWhiteBalance(_ saves: [IDPhotoSave], editor: EditorModel) async {
        guard !saves.isEmpty else { return }
        let summary = L10n.tr("ID Photo")
        let byID = Dictionary(saves.map { ($0.asset.id, $0) }, uniquingKeysWith: { _, last in last })
        await runEditBatch(saves.map(\.asset), editor: editor, title: summary,
                           inEditor: {
                               guard let id = editor.catalogAssetID, let save = byID[id] else { return }
                               editor.edit { save.balance.apply(to: &$0) }
                           },
                           develop: { id, saved, defaults in
                               var edit = saved ?? defaults
                               if let save = byID[id] { save.balance.apply(to: &edit) }
                               return edit
                           },
                           save: { store, settings, baseline, id in try await store.saveEdits(settings, assetID: id, baseline: baseline, summary: summary) }) { _, _, failures in
            if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Photos Weren’t Changed"), summary: "", items: failures) }
        }
    }

}
