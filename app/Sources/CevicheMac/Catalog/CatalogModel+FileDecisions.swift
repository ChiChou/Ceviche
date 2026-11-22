import Foundation
import CevicheCore

/// What a housekeeping tool decided about a set of photos, applied in one go when its view is confirmed: photos
/// archived (`CatalogModel.archive`), and flags, ratings and labels set, all in one undoable step. No file is moved or
/// deleted; archived photos wait in the Archived view, rejected ones for Trash Rejected. Tidy RAW + JPEG Pairs builds
/// one per pair; a duplicate finder would reject the copies.
struct FileDecisions {
    struct Change: Equatable {
        var review: ReviewState? = nil
        var rating: Int? = nil
        var label: CatalogLabel?? = nil
    }
    /// Photos that leave the library for the archive.
    var archive: [CatalogAsset] = []
    /// Per photo ID, what to set.
    var changes: [String: Change] = [:]

    var isEmpty: Bool { archive.isEmpty && changes.isEmpty }
    mutating func set(_ id: String, review: ReviewState) { changes[id, default: Change()].review = review }
}

extension CatalogModel {
    struct FileDecisionResult {
        var archived = 0, rejected = 0, picked = 0
        var failures: [String] = []
    }

    /// Applies `decisions` with one Undo that brings archived photos back and restores the flags, ratings and labels.
    func applyFileDecisions(_ decisions: FileDecisions, undoTitle: String) async -> FileDecisionResult? {
        guard let store, !interactionBusy, await flushMetadata(), self.store === store else { return nil }
        var result = FileDecisionResult()
        var archived: [String] = []
        var previous: [String: CatalogMetadata] = [:]
        // One photo that fails is listed; the other decisions still apply.
        do {
            if !decisions.archive.isEmpty { archived = try await store.archive(decisions.archive.map(\.id)) }
        } catch { result.failures.append(error.localizedDescription) }
        for (id, change) in decisions.changes {
            do {
                let before = try await store.updateQuickMetadata(assetIDs: [id], rating: change.rating, review: change.review, label: change.label)
                previous.merge(before) { first, _ in first }
            } catch { result.failures.append(error.localizedDescription) }
        }
        let applied = decisions.changes.filter { previous[$0.key] != nil }
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
        result.rejected = applied.filter { $0.value.review == .rejected }.count
        result.picked = applied.filter { $0.value.review == .accepted }.count
        await refresh()
        if selected != nil { await reloadSelection() }
        return result
    }
}
