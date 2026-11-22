import Foundation
import CevicheCore

/// The Library's History tab works on the selected photo through the same panel as Develop. Changes go straight to
/// the catalog and the selection is reloaded; the grid's thumbnail catches up when the photo is next rendered.
extension CatalogModel: HistorySource {
    var historySubjectID: String? { selected?.id }
    var historySubjectAvailable: Bool { selected?.inLibrary == true }
    var historyBusy: Bool { catalogBusy }
    var keepsHistory: Bool { store != nil && selected != nil }
    /// A saved development leaves a development step in History (an imported one included).
    var canResetEdits: Bool { history.contains { $0.kind == .edit } }

    func refreshHistory() {
        guard let store, let id = selected?.id else { history = []; snapshots = []; return }
        Task {
            do {
                let entries = try await store.history(assetID: id)
                let saved = try await store.snapshots(assetID: id)
                guard selected?.id == id else { return }
                history = entries; snapshots = saved
            } catch { self.error = error.localizedDescription }
        }
    }
    func revert(to revision: CatalogRevision) { restore(revision) }
    func resetAllEdits() {
        historyAction { store, asset in
            _ = try await store.resetEdits(to: asset.info.defaults, assetID: asset.id)
        }
    }
    func takeSnapshot(named name: String) {
        historyAction { store, asset in
            let settings = try await store.savedAdjustments(of: asset) ?? asset.info.defaults
            _ = try await store.createSnapshot(name: name, adjustments: settings, thumbnail: nil, assetID: asset.id)
        }
    }
    func applySnapshot(_ snapshot: CatalogSnapshot) {
        historyAction { store, asset in
            let settings = try await store.adjustments(of: snapshot)
            try await store.saveEdits(settings, assetID: asset.id, summary: L10n.tr("Applied snapshot “\(snapshot.name)”"), milestone: true)
        }
    }
    func renameSnapshot(_ snapshot: CatalogSnapshot, to name: String) {
        historyAction { store, _ in try await store.renameSnapshot(snapshot.id, to: name) }
    }
    func deleteSnapshot(_ snapshot: CatalogSnapshot) {
        historyAction { store, _ in try await store.deleteSnapshot(snapshot.id) }
    }
    /// Saves pending metadata, runs `change` on the selected photo, then reloads it and its history.
    private func historyAction(_ change: @escaping (CatalogStore, CatalogAsset) async throws -> Void) {
        guard !catalogBusy, let asset = selected, asset.inLibrary else { return }
        Task {
            guard await flushMetadata(), let store else { return }
            do {
                try await change(store, asset)
                await reloadSelection()
                refreshHistory()
            } catch { self.error = error.localizedDescription }
        }
    }
}
