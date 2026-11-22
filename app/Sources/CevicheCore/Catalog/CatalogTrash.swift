import Foundation
import GRDB

public struct CatalogDeletionEntry: Equatable, Sendable {
    public let id: String
    public let filename: String
    public let inTrash: Bool
}

/// One original and the photos using it, built from the catalog alone: no file is touched until the deletion itself.
public struct CatalogDeletionPlan: Identifiable, Sendable {
    public let id = UUID()
    public let entries: [CatalogDeletionEntry]
    /// A copy the catalog made at import; its sidecar goes with it.
    public let catalogOwned: Bool
    fileprivate let catalogRoot: URL
    /// The photo the plan was made for, whose stored locator and path find the others.
    fileprivate let source: DeletionSource
    fileprivate let sources: [DeletionSource]
}

private struct DeletionSource: Decodable, FetchableRecord, Equatable, Sendable {
    let id: String
    let filename: String
    let origin: String
    let sourcePath: String
    let bookmark: Data?
    let fileSize: Int64?
    let trashedAt: Date?
    let isCopy: Bool
    /// Resolved as everywhere else: a catalog copy under the root, else the bookmark, else the recorded path.
    func accessURL(root: URL) -> URL {
        CatalogImporter.sourceURL(locator: AssetLocator(stored: origin), sourcePath: sourcePath, bookmark: bookmark, root: root)
    }
}
/// The size of the regular file (or latent image package) at `url`, or nil when nothing is there.
private func originalSize(_ url: URL) throws -> UInt64? {
    let a: [FileAttributeKey: Any]
    do { a = try FileManager.default.attributesOfItem(atPath: url.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
    guard a[.type] as? FileAttributeType == .typeRegular || (a[.type] as? FileAttributeType == .typeDirectory && LatentImage.isBundle(url)) else {
        throw EditorError.invalidDocument(L10n.tr("The original is not a regular file. Nothing was deleted."))
    }
    guard a[.type] as? FileAttributeType == .typeDirectory else { return (a[.size] as? NSNumber)?.uint64Value ?? 0 }
    // A package's own entry is a few bytes; what it holds is what deleting frees.
    var total: UInt64 = 0
    if let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let file as URL in files { total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    return total
}

extension CatalogStore {
    public func moveToTrash(_ assetID: String) throws { try moveToTrash([assetID]) }
    public func moveToTrash(_ assetIDs: [String]) throws {
        try database.write { db in try Self.moveToTrash(assetIDs, db: db) }
    }
    static func moveToTrash(_ assetIDs: [String], db: Database) throws {
        var groups: Set<String> = []
        for assetID in Set(assetIDs) {
            // Already gone (sync, another window): nothing left to move.
            guard let asset = try CatalogAsset.fetchOne(db, key: assetID), asset.trashedAt == nil else { continue }
            if let group = asset.stackID { groups.insert(group) }
            try CatalogAsset.filter(key: assetID).updateAll(db, CatalogAsset.Columns.trashedAt.set(to: Date()), CatalogAsset.Columns.updatedAt.set(to: Date()))
            // Removing the lease also rejects a late result from a worker already in flight.
            try CatalogAnalysisJob.deleteOne(db, key: assetID)
            try Self.analysisChanged(db)
        }
        try tidyStacks(groups, db: db)
    }
    public func recoverFromTrash(_ assetID: String) throws { try recoverFromTrash([assetID]) }
    public func recoverFromTrash(_ assetIDs: [String]) throws {
        try database.write { db in
            for assetID in Set(assetIDs) {
                guard let asset = try CatalogAsset.fetchOne(db, key: assetID), asset.trashedAt != nil else { continue }
                try CatalogAsset.filter(key: assetID).updateAll(db, CatalogAsset.Columns.trashedAt.set(to: nil), CatalogAsset.Columns.updatedAt.set(to: Date()))
                // Only this Mac's own analyses are redone here; another Mac's stay its to refresh.
                if asset.analysisOrigin == "local", asset.analysisVersion != CatalogImporter.analysisVersion {
                    try Self.enqueueAnalysis(db, assetID: assetID, version: CatalogImporter.analysisVersion, priority: 0)
                } else { try Self.analysisChanged(db) }
            }
        }
    }
    private static var deletionColumns: [any SQLSelectable] {
        let columns = CatalogAsset.Columns.self
        return [columns.id, columns.filename, columns.origin, columns.sourcePath, columns.bookmark, columns.fileSize, columns.trashedAt, columns.isCopy]
    }
    /// The photos using the same original, from what the catalog stored at import: the same locator or the same
    /// recorded path. One query; no file is touched.
    private func deletionSources(_ db: Database, sharing source: DeletionSource) throws -> [DeletionSource] {
        let columns = CatalogAsset.Columns.self
        // A photo received from another Mac without a file path records none: an empty path is no shared original.
        var shared = columns.id == source.id
        if !source.origin.isEmpty { shared = shared || columns.origin == source.origin }
        if !source.sourcePath.isEmpty { shared = shared || columns.sourcePath == source.sourcePath }
        return try DeletionSource.fetchAll(db, CatalogAsset.filter(shared).order(columns.id).select(Self.deletionColumns))
    }
    /// The plans for these photos, one per original, from the catalog alone. Photos sharing an original with an
    /// earlier one fold into its plan.
    public func deletionPlans(for assetIDs: [String]) throws -> [CatalogDeletionPlan] {
        try database.read { db in
            var plans: [CatalogDeletionPlan] = [], included: Set<String> = []
            for assetID in assetIDs where !included.contains(assetID) {
                // One already gone (sync, another window) has nothing left to delete.
                guard try CatalogAsset.exists(db, key: assetID) else { continue }
                let plan = try deletionPlan(db, for: assetID)
                plans.append(plan); included.formUnion(plan.entries.map(\.id))
            }
            return plans
        }
    }
    public func deletionPlan(for assetID: String) throws -> CatalogDeletionPlan {
        try database.read { try deletionPlan($0, for: assetID) }
    }
    private func deletionPlan(_ db: Database, for assetID: String) throws -> CatalogDeletionPlan {
        guard let source = try DeletionSource.fetchOne(db, CatalogAsset.filter(key: assetID).select(Self.deletionColumns)) else {
            throw EditorError.invalidDocument(L10n.tr("Photo is no longer in this catalog."))
        }
        let sources = try deletionSources(db, sharing: source)
        // The record says where the original came from: a copy the importer made is the catalog's to delete.
        return CatalogDeletionPlan(entries: sources.map { CatalogDeletionEntry(id: $0.id, filename: $0.filename, inTrash: $0.trashedAt != nil) },
            catalogOwned: source.isCopy, catalogRoot: root, source: source, sources: sources)
    }
    /// Where the plan's original is now, symlinks resolved: what an open document is compared against.
    public func originalURL(_ plan: CatalogDeletionPlan) -> URL {
        plan.source.accessURL(root: root).resolvingSymlinksInPath().standardizedFileURL
    }
    /// Call only after the user confirms this exact plan. The original is found and checked here, once: a file
    /// whose size no longer matches what the catalog recorded at import is not this photo's and stays, and a
    /// missing one only takes its records with it. Unlink failure retains every catalog record. A rare DB commit
    /// failure after unlink is reported explicitly; retained records can be removed with a new plan.
    public func deletePermanently(_ plan: CatalogDeletionPlan) async throws {
        try await deletePermanently(plan, removeOriginal: { try FileManager.default.removeItem(at: $0) })
    }
    func deletePermanently(_ plan: CatalogDeletionPlan, removeOriginal: (URL) throws -> Void) async throws {
        guard plan.catalogRoot == root else { throw EditorError.invalidDocument(L10n.tr("This deletion belongs to another catalog.")) }
        let accessURL = plan.source.accessURL(root: root)
        let access = accessURL.startAccessingSecurityScopedResource()
        defer { if access { accessURL.stopAccessingSecurityScopedResource() } }
        let url = accessURL.resolvingSymlinksInPath().standardizedFileURL
        var originalRemoved = false
        do {
            try database.writeSync { db in
                let current = try deletionSources(db, sharing: plan.source)
                guard current == plan.sources else { throw EditorError.invalidDocument(L10n.tr("Catalog references changed since confirmation. Review the deletion again.")) }
                if let size = try originalSize(url) {
                    guard !current.contains(where: { $0.fileSize.map { UInt64($0) != size } ?? false }) else {
                        throw EditorError.invalidDocument(L10n.tr("The file at this path no longer matches the imported original. Nothing was deleted. Locate the original before trying again."))
                    }
                    try removeOriginal(url); originalRemoved = true
                }
                if plan.catalogOwned {
                    // The sidecar copied beside a catalog-owned original has no other owner.
                    for sidecar in XMPPacket.sidecarNames(for: url) where FileManager.default.fileExists(atPath: sidecar.path) { try? FileManager.default.removeItem(at: sidecar) }
                }
                try Self.rememberDeletedImports(plan.entries.map(\.id), db)
                let groups = Set(try CatalogAsset.filter(keys: plan.entries.map(\.id)).fetchAll(db).compactMap(\.stackID))
                for entry in plan.entries {
                    try CatalogAsset.deleteOne(db, key: entry.id)
                    try CatalogSyncTombstone(id: entry.id, kind: "asset", deletedAt: Date()).insert(db, onConflict: .replace)
                }
                try Self.tidyStacks(groups, db: db)
                try Self.analysisChanged(db)
            }
        } catch {
            if originalRemoved { throw EditorError.invalidDocument(L10n.tr("The original was deleted, but catalog cleanup failed: \(error.localizedDescription). Try permanent deletion again to remove the remaining catalog records.")) }
            throw error
        }
        // Previews are derived data; anything left behind goes in the next sweep.
        try? await previews.remove(assetIDs: plan.entries.map(\.id))
        try? reclaimSpace()
    }
}

/// One photo leaving the catalog. A copy the importer made into the catalog folder goes with it;
/// a referenced original stays where it is.
public struct CatalogRemovalEntry: Equatable, Sendable {
    public let id: String
    public let filename: String
    public let inTrash: Bool
    public let locator: AssetLocator
    public let catalogOwned: Bool
}

/// A frozen set of photos to remove from the catalog without deleting any referenced original.
public struct CatalogRemovalPlan: Identifiable, Sendable {
    public let id = UUID()
    public let entries: [CatalogRemovalEntry]
    fileprivate let catalogRoot: URL
    public var copies: [CatalogRemovalEntry] { entries.filter(\.catalogOwned) }
    public var references: [CatalogRemovalEntry] { entries.filter { !$0.catalogOwned } }
}

extension CatalogStore {
    public func removalPlan(for assetIDs: [String]) throws -> CatalogRemovalPlan {
        var entries: [CatalogRemovalEntry] = []
        var seen: Set<String> = []
        let unique = assetIDs.filter { seen.insert($0).inserted }
        try database.read { db in
            // One query for the whole selection, only the columns the confirmation shows, kept in the order given.
            let columns = CatalogAsset.Columns.self
            let request = CatalogAsset.filter(keys: unique).select(columns.id, columns.filename, columns.origin, columns.trashedAt, columns.isCopy)
            let rows = Dictionary(try Row.fetchAll(db, request).map { ($0[columns.id] as String, $0) }, uniquingKeysWith: { first, _ in first })
            for assetID in unique {
                // One already gone (sync, another window) has nothing left to remove.
                guard let row = rows[assetID] else { continue }
                let origin: String = row[columns.origin], trashedAt: Date? = row[columns.trashedAt]
                entries.append(CatalogRemovalEntry(id: assetID, filename: row[columns.filename], inTrash: trashedAt != nil,
                                                   locator: AssetLocator(stored: origin), catalogOwned: row[columns.isCopy]))
            }
        }
        return CatalogRemovalPlan(entries: entries, catalogRoot: root)
    }
    /// Removes the records, their edits and history. With `deletingCopies`, copies in the catalog folder are deleted
    /// afterwards unless another photo still uses the same copy; referenced originals are never touched.
    @discardableResult
    public func removeFromCatalog(_ plan: CatalogRemovalPlan, deletingCopies: Bool = true) async throws -> Int {
        guard plan.catalogRoot == root else { throw EditorError.invalidDocument(L10n.tr("This removal belongs to another catalog.")) }
        let ids = Set(plan.entries.map(\.id))
        var orphanedCopies: [URL] = []
        try database.writeSync { db in
            try Self.rememberDeletedImports(plan.entries.map(\.id), db)
            for entry in plan.entries {
                guard try CatalogAsset.fetchOne(db, key: entry.id) != nil else { continue }
                if deletingCopies, entry.catalogOwned, case .catalog(let relative) = entry.locator {
                    let others = try CatalogAsset.filter(CatalogAsset.Columns.origin == entry.locator.string && !ids.contains(CatalogAsset.Columns.id)).fetchCount(db)
                    if others == 0 { orphanedCopies.append(CatalogImporter.catalogCopyURL(relative, root: root)) }
                }
                try CatalogAsset.deleteOne(db, key: entry.id)
                try CatalogSyncTombstone(id: entry.id, kind: "asset", deletedAt: Date()).insert(db, onConflict: .replace)
            }
            try Self.analysisChanged(db)
        }
        var deleted = 0
        for url in Set(orphanedCopies) {
            // The record is gone either way; a copy that will not unlink stays behind in the catalog folder.
            if (try? FileManager.default.removeItem(at: url)) != nil { deleted += 1 }
            for sidecar in XMPPacket.sidecarNames(for: url) where FileManager.default.fileExists(atPath: sidecar.path) { try? FileManager.default.removeItem(at: sidecar) }
        }
        try? await previews.remove(assetIDs: Array(ids))
        try? reclaimSpace()
        return deleted
    }
}
