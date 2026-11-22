import Foundation
import CevicheCore

/// History and Snapshots for the open catalog photo. Reverting, resetting and applying a snapshot or a look each add
/// a History step (and an Undo step), so nothing is ever lost by going back.
extension EditorModel: HistorySource {
    var keepsHistory: Bool { catalogStore != nil && catalogAssetID != nil }
    var historySubjectID: String? { catalogAssetID }
    var historySubjectAvailable: Bool { hasImage }
    var historyBusy: Bool { busy }
    var canResetEdits: Bool { adjustments != info?.defaults }

    func refreshHistory() {
        guard let store = catalogStore, let id = catalogAssetID else { history = []; snapshots = []; return }
        Task {
            do {
                let entries = try await store.history(assetID: id).filter { $0.kind == .edit }
                let saved = try await store.snapshots(assetID: id)
                guard catalogAssetID == id else { return }
                history = entries; snapshots = saved
            } catch { self.error = error.localizedDescription }
        }
    }
    func revert(to revision: CatalogRevision) {
        historyAction { store, id in
            try await store.restore(revision)
            return try await store.adjustments(of: revision)
        }
    }
    /// Back to the import development, without the settings an imported XMP carried; standalone documents reset as an
    /// undoable edit.
    func resetAllEdits() {
        guard let info else { return }
        xmpSourceData = nil; xmpReport = nil
        guard keepsHistory else { edit { $0 = info.defaults }; return }
        historyAction { store, id in
            try await store.resetEdits(to: info.defaults, assetID: id)
            return info.defaults
        }
    }
    func takeSnapshot(named name: String) {
        guard let store = catalogStore, let id = catalogAssetID else { return }
        let settings = adjustments, thumbnail = lastThumbnailJPEG
        Task {
            do {
                // Unsaved edits go into History first; when that fails the snapshot waits.
                if dirty, !(await save()) { return }
                try await store.createSnapshot(name: name, adjustments: settings, thumbnail: thumbnail, assetID: id)
                refreshHistory()
            } catch { self.error = error.localizedDescription }
        }
    }
    func applySnapshot(_ snapshot: CatalogSnapshot) {
        historyAction { store, id in
            let settings = try await store.adjustments(of: snapshot)
            try await store.saveEdits(settings, assetID: id, summary: L10n.tr("Applied snapshot “\(snapshot.name)”"), milestone: true)
            return settings
        }
    }
    func renameSnapshot(_ snapshot: CatalogSnapshot, to name: String) {
        guard let store = catalogStore else { return }
        Task { do { try await store.renameSnapshot(snapshot.id, to: name); refreshHistory() } catch { self.error = error.localizedDescription } }
    }
    func deleteSnapshot(_ snapshot: CatalogSnapshot) {
        guard let store = catalogStore else { return }
        Task { do { try await store.deleteSnapshot(snapshot.id); refreshHistory() } catch { self.error = error.localizedDescription } }
    }
    private func historyAction(_ change: @escaping (CatalogStore, String) async throws -> Adjustments) {
        Task { await historyStep(change) }
    }
    /// Saves pending edits, runs `change` in the catalog, then shows the result and refreshes thumbnails. Returns
    /// whether the result was saved and shown.
    @discardableResult
    func historyStep(_ change: (CatalogStore, String) async throws -> Adjustments) async -> Bool {
        guard let store = catalogStore, let id = catalogAssetID, let renderer, !busy else { return false }
        var accepted = false
        do {
            if dirty, !(await save()) { return false }
            let settings = try await change(store, id)
            guard catalogAssetID == id else { return false }
            acceptAutomationEdits(settings); accepted = true
            refreshHistory()
            let key = try await store.asset(id).renderKey
            let rendered = try await renderer.preview(settings)
            try await store.installThumbnail(rendered.thumbnail, assetID: id, renderKey: key)
            refreshHistory()
        } catch { self.error = error.localizedDescription }
        return accepted
    }
}
