import CevicheCore

/// One undoable library change. Steps act on the store directly, so undoing never registers new steps.
struct CatalogUndoStep {
    let name: String
    let undo: (CatalogStore) async throws -> Void
    let redo: (CatalogStore) async throws -> Void
}

extension CatalogModel {
    var undoTitle: String { undoSteps.last.map { L10n.tr("Undo \($0.name)") } ?? L10n.tr("Undo") }
    var redoTitle: String { redoSteps.last.map { L10n.tr("Redo \($0.name)") } ?? L10n.tr("Redo") }
    var canUndo: Bool { !undoSteps.isEmpty && !catalogBusy }
    var canRedo: Bool { !redoSteps.isEmpty && !catalogBusy }

    func registerUndo(_ name: String, undo: @escaping (CatalogStore) async throws -> Void, redo: @escaping (CatalogStore) async throws -> Void) {
        undoSteps.append(CatalogUndoStep(name: name, undo: undo, redo: redo)); redoSteps = []
        if undoSteps.count > 100 { undoSteps.removeFirst() }
    }
    func undo() { Task { await perform(undo: true) } }
    func redo() { Task { await perform(undo: false) } }
    func perform(undo: Bool) async {
        guard let store, !catalogBusy, await flushMetadata(), self.store === store,
              let step = undo ? undoSteps.last : redoSteps.last else { return }
        do {
            try await (undo ? step.undo : step.redo)(store)
            // A step that failed stays where it was, so it can be tried again.
            if undo { undoSteps.removeLast(); redoSteps.append(step) } else { redoSteps.removeLast(); undoSteps.append(step) }
            // A step that moved photos names their place again; for any other step the namer finds nothing to do.
            placeNamer.workAvailable()
        } catch { self.error = error.localizedDescription }
        await reloadSelection()
    }

    /// Quick rating/review changes restore each photo's own previous values.
    func registerQuickMetadataUndo(previous: [String: CatalogMetadata], rating: Int?, review: ReviewState?, label: CatalogLabel?? = nil) {
        guard !previous.isEmpty else { return }
        let ids = Array(previous.keys)
        registerUndo(rating != nil ? L10n.tr("Rating") : review != nil ? L10n.tr("Review") : L10n.tr("Label"), undo: { store in
            for (id, metadata) in previous {
                try await store.updateQuickMetadata(assetIDs: [id], rating: rating.map { _ in metadata.rating }, review: review.map { _ in metadata.review },
                                                    label: label.map { _ in metadata.label })
            }
        }, redo: { store in
            try await store.updateQuickMetadata(assetIDs: ids, rating: rating, review: review, label: label)
        })
    }

    /// Inspector edits restore only the fields that changed, so later ratings are kept.
    func registerMetadataUndo(assetID: String, from old: CatalogMetadata, to new: CatalogMetadata) {
        let fields: [(String, WritableKeyPath<CatalogMetadata, String>)] = [(L10n.tr("Title"), \.title), (L10n.tr("Caption"), \.caption), (L10n.tr("Keywords"), \.keywords), (L10n.tr("Capture Date"), \.captureDay)]
        let changed = fields.filter { old[keyPath: $0.1] != new[keyPath: $0.1] }
        let ratingChanged = old.rating != new.rating, reviewChanged = old.review != new.review, labelChanged = old.label != new.label
        guard !changed.isEmpty || ratingChanged || reviewChanged || labelChanged else { return }
        let culling = [ratingChanged, reviewChanged, labelChanged].filter { $0 }.count
        let name = changed.count == 1 && culling == 0 ? changed[0].0
            : changed.isEmpty && culling == 1 ? (ratingChanged ? L10n.tr("Rating") : reviewChanged ? L10n.tr("Review") : L10n.tr("Label")) : L10n.tr("Metadata")
        func apply(_ source: CatalogMetadata) -> (CatalogStore) async throws -> Void {
            { store in
                var value = try await store.asset(assetID).metadata
                for (_, path) in changed { value[keyPath: path] = source[keyPath: path] }
                if ratingChanged { value.rating = source.rating }
                if reviewChanged { value.review = source.review }
                if labelChanged { value.label = source.label }
                try await store.updateMetadata(value, assetID: assetID)
            }
        }
        registerUndo(name, undo: apply(old), redo: apply(new))
    }

    /// An AI client's batch: one step for every photo it changed. Undo and redo touch only the fields the batch
    /// changed on each photo, so edits made since in other fields are kept.
    func registerBatchMetadataUndo(_ changes: [(id: String, old: CatalogMetadata, new: CatalogMetadata)], name: String = L10n.tr("AI Changes")) {
        guard !changes.isEmpty else { return }
        func carry(_ source: CatalogMetadata, from old: CatalogMetadata, to new: CatalogMetadata, onto value: inout CatalogMetadata) {
            let text: [WritableKeyPath<CatalogMetadata, String>] = [\.title, \.caption, \.keywords, \.captureDay]
            for path in text where old[keyPath: path] != new[keyPath: path] { value[keyPath: path] = source[keyPath: path] }
            if old.rating != new.rating { value.rating = source.rating }
            if old.review != new.review { value.review = source.review }
            if old.label != new.label { value.label = source.label }
            if old.latitude != new.latitude || old.longitude != new.longitude || old.locationSource != new.locationSource {
                value.latitude = source.latitude; value.longitude = source.longitude; value.locationSource = source.locationSource
            }
        }
        func apply(undo: Bool) -> (CatalogStore) async throws -> Void {
            { store in
                var values: [String: CatalogMetadata] = [:]
                for change in changes {
                    var value = try await store.asset(change.id).metadata
                    carry(undo ? change.old : change.new, from: change.old, to: change.new, onto: &value)
                    values[change.id] = value
                }
                try await store.updateMetadata(values)
            }
        }
        registerUndo(name, undo: apply(undo: true), redo: apply(undo: false))
    }

    /// Batch keyword changes restore each photo's own previous keywords.
    func registerKeywordsUndo(previous: [String: CatalogMetadata], added: [String]) {
        guard !previous.isEmpty else { return }
        let ids = Array(previous.keys)
        registerUndo(L10n.tr("Add Keywords"), undo: { store in
            for (id, old) in previous {
                var value = try await store.asset(id).metadata
                value.keywords = old.keywords
                try await store.updateMetadata(value, assetID: id)
            }
        }, redo: { store in
            try await store.addKeywords(added, assetIDs: ids)
        })
    }
    func registerTrashUndo(_ ids: [String], movedToTrash: Bool) {
        registerUndo(movedToTrash ? L10n.tr("Move to Trash") : L10n.tr("Recover"), undo: { store in
            if movedToTrash { try await store.recoverFromTrash(ids) } else { try await store.moveToTrash(ids) }
        }, redo: { store in
            if movedToTrash { try await store.moveToTrash(ids) } else { try await store.recoverFromTrash(ids) }
        })
    }
}
