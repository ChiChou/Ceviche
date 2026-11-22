import Foundation
import CevicheCore

/// Strip Unsupported XMP Settings: forgets the packet a photo was imported with, so the settings Ceviche does not
/// render stop warning each time it opens. The development and the sidecar on disk are unchanged.
extension CatalogModel {
    func canStripXMP(_ targets: [CatalogAsset], editor: EditorModel) -> Bool {
        if !showingLibrary, editor.developmentStore is SidecarDevelopmentStore { return editor.canStripXMP }
        return store != nil && !catalogBusy && targets.contains { $0.inLibrary && !$0.xmpWarnings.isEmpty }
    }
    func stripUnsupportedXMP(_ targets: [CatalogAsset], editor: EditorModel) async {
        if !showingLibrary, editor.developmentStore is SidecarDevelopmentStore { await editor.stripUnsupportedXMP(); return }
        guard let store, !catalogBusy else { return }
        do {
            let stripped = try await store.stripSourceXMP(targets.filter(\.inLibrary).map(\.id))
            if let id = editor.catalogAssetID, stripped.contains(id), editor.usesCatalog(store) { editor.forgetSourceXMP() }
            await refresh()
            guard !stripped.isEmpty else { return }
            notice = stripped.count == 1 ? L10n.tr("Unsupported settings stripped") : L10n.tr("Unsupported settings stripped from \(stripped.count.formatted()) photos")
        } catch { self.failure = Failure(L10n.tr("Couldn’t Strip Unsupported Settings"), error) }
    }
}

extension EditorModel {
    /// The open photo has an imported packet to forget, and a store to forget it in.
    var canStripXMP: Bool { developmentStore != nil && xmpSourceData != nil && hasImage && !busy }
    func forgetSourceXMP() { xmpSourceData = nil; xmpReport = nil }
    /// For the open photo: a catalog entry forgets its packet; a sidecar photo is saved again without it, into
    /// `IMG.ceviche.xmp` when another application wrote the sidecar.
    func stripUnsupportedXMP() async {
        guard let developmentStore, hasImage else { return }
        do { try await developmentStore.stripSourceXMP() } catch { self.failure = Failure(L10n.tr("Couldn’t Strip Unsupported Settings"), error); return }
        forgetSourceXMP()
        if developmentStore is SidecarDevelopmentStore { await save() }
    }
}
