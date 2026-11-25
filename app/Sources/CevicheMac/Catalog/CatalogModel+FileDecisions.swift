import Foundation
import CevicheCore

extension CatalogModel {
    struct FileDecisionResult {
        var archived = 0, rejected = 0, picked = 0
        var failures: [String] = []
    }

    /// Applies `decisions` (`CatalogStore.apply`) with one Undo that brings archived photos back and restores the flags, ratings and labels.
    func applyFileDecisions(_ decisions: FileDecisions, undoTitle: String) async -> FileDecisionResult? {
        guard let store, !interactionBusy, await flushMetadata(), self.store === store else { return nil }
        var result = FileDecisionResult()
        // One photo that fails is listed; the other decisions still apply.
        let outcome = await store.apply(decisions)
        result.failures = outcome.errors.map(\.localizedDescription)
        let archived = outcome.archived, previous = outcome.previous, applied = outcome.applied
        if !archived.isEmpty || !previous.isEmpty {
            registerUndo(undoTitle, undo: { store in
                for (id, metadata) in previous { _ = try await store.updateQuickMetadata(assetIDs: [id], rating: metadata.rating, review: metadata.review, label: .some(metadata.label)) }
                if !archived.isEmpty { try await store.unarchive(archived) }
            }, redo: { store in
                if !archived.isEmpty { try await store.archive(archived) }
                for (id, change) in applied { _ = try await store.updateQuickMetadata(assetIDs: [id], rating: change.rating, review: change.review, label: change.label) }
            })
            syncSoon()
        }
        result.archived = archived.count
        result.rejected = outcome.rejected
        result.picked = outcome.picked
        await refresh()
        if selected != nil { await reloadSelection() }
        return result
    }
}
