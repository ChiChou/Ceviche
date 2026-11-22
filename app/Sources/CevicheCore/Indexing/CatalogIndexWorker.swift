import Foundation

public enum CatalogIndexWorker {
    public enum Outcome: String, Sendable { case idle, completed, failed, discarded }
    public static let concurrency = 4
    public static let batchSize = 16
    /// Vision's classify request deadlocks when several run at once from background-priority threads: each
    /// waits on a dispatch group whose work never gets scheduled. Utility is the lowest priority that completes.
    public static let priority = TaskPriority.utility

    /// Keep a small worker pool occupied without an XPC round trip between photos.
    public static func runBatch(store: CatalogStore, owner: String, version: String = CatalogImporter.analysisVersion,
                                cancellation: CatalogAnalysisCancellation = CatalogAnalysisCancellation(),
                                classify: (@Sendable (URL) throws -> (String, String))? = nil) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            func enqueue() {
                group.addTask(priority: priority) {
                    try cancellation.check()
                    return try await runOne(store: store, owner: owner, version: version, cancellation: cancellation, classify: classify)
                }
            }
            for _ in 0..<concurrency { enqueue() }
            var submitted = concurrency
            var result = Outcome.idle
            do {
                while let outcome = try await group.next() {
                    if outcome == .completed || result == .idle { result = outcome }
                    if outcome != .idle && submitted < batchSize {
                        submitted += 1; enqueue()
                    }
                }
                // With nothing left to analyse, the photos analysed before prints were kept get one; not while
                // maintenance has paused background work, which an idle claim doesn't tell apart.
                if result == .idle, classify == nil, try await store.analysisEnabled() {
                    return try await runPrintBackfill(store: store, cancellation: cancellation)
                }
                return result
            } catch {
                cancellation.cancel(); group.cancelAll()
                throw error
            }
        }
    }
    /// Prints a batch of photos that have no feature print yet, four at a time: one small decode and Vision's print each,
    /// a fraction of a full analysis, so a library analysed before prints were kept catches up quickly.
    public static func runPrintBackfill(store: CatalogStore, cancellation: CatalogAnalysisCancellation, batch: Int = 32) async throws -> Outcome {
        let photos = try await store.photosNeedingPrint(limit: batch)
        guard !photos.isEmpty else { return .idle }
        let root = store.root
        try await withThrowingTaskGroup(of: (String, CatalogPrint?).self) { group in
            var next = 0
            func enqueue() {
                let asset = photos[next]; next += 1
                group.addTask(priority: priority) {
                    try cancellation.check()
                    let url = CatalogImporter.sourceURL(for: asset, root: root)
                    // Never downloads a library from iCloud Drive; a photo not here is marked and printed when analysed.
                    guard CatalogImporter.isDownloaded(url) else { return (asset.id, nil) }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return (asset.id, autoreleasepool { CatalogPrint.measure(url) })
                }
            }
            for _ in 0..<min(concurrency, photos.count) { enqueue() }
            while let (id, print) = try await group.next() {
                try cancellation.check()
                try await store.savePrint(print, assetID: id)
                if next < photos.count { enqueue() }
            }
        }
        return .completed
    }
    /// Bounded unit of work used by the XPC service and integration tests.
    public static func runOne(store: CatalogStore, owner: String, version: String = CatalogImporter.analysisVersion,
                              cancellation: CatalogAnalysisCancellation = CatalogAnalysisCancellation(),
                              classify: (@Sendable (URL) throws -> (String, String))? = nil) async throws -> Outcome {
        guard let claim = try await store.claimAnalysis(owner: owner, version: version) else { return .idle }
        do {
            let result = try await withTaskCancellationHandler {
                try await Task.detached(priority: priority) {
                    try autoreleasepool {
                        try cancellation.check()
                        let url = CatalogImporter.sourceURL(for: claim.asset, root: store.root)
                        // Indexing never downloads a whole library from iCloud Drive; opening a photo does.
                        guard CatalogImporter.isDownloaded(url) else { throw EditorError.invalidDocument(L10n.tr("The original is in iCloud Drive and not downloaded on this Mac.")) }
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let before = try CatalogImporter.fileStamp(url)
                        guard try CatalogImporter.matches(url, claim.asset) else { throw EditorError.invalidDocument(L10n.tr("The original has changed. Relink the matching original or import the changed file separately.")) }
                        try cancellation.check()
                        let result: (tags: String, version: String, confidences: [String: Double], faces: [CatalogFace]?, print: CatalogPrint?, tiles: [Int: Data])
                        if let classify { let given = try classify(url); result = (given.0, given.1, [:], nil, nil, [:]) }
                        else {
                            let found = try CatalogImporter.classifyLabels(url, cancellation: cancellation)
                            try cancellation.check()
                            result = (found.labels.map(\.label).joined(separator: ", "), found.version,
                                      Dictionary(found.labels.map { ($0.label, $0.confidence) }, uniquingKeysWith: max), found.faces, found.print,
                                      FaceCrops.wallTiles(at: url, faces: found.faces))
                        }
                        try cancellation.check()
                        let after = try CatalogImporter.fileStamp(url)
                        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw EditorError.invalidDocument(L10n.tr("The original changed while indexing.")) }
                        return result
                    }
                }.value
            } onCancel: { cancellation.cancel() }
            try cancellation.check()
            try Task.checkCancellation()
            let applied = try await store.finishAnalysis(claim, tags: result.tags, version: result.version, confidences: result.confidences, faces: result.faces, print: result.print)
            // The tiles are a cache beside the catalog: written once the faces they show are.
            if applied, result.faces != nil { try? await store.previews.installFaceTiles(result.tiles, assetID: claim.asset.id) }
            if !applied { try await store.failAnalysis(owner: owner, assetID: claim.asset.id, message: L10n.tr("The source or analysis version changed before indexing finished.")) }
            return applied ? .completed : .discarded
        } catch where error is CancellationError || cancellation.isCancelled {
            // The supervising app releases this claim with the correct reason: yielding to rendering
            // does not consume a retry, whereas a timeout does. If the app died, the lease expires.
            throw CancellationError()
        } catch {
            try await store.failAnalysis(owner: owner, assetID: claim.asset.id, message: error.localizedDescription)
            return .failed
        }
    }
}
