import Foundation
import GRDB

// One photo syncs as three parts, each with its own clock, so a change to one never overwrites another Mac's change
// to another: the original (file facts and EXIF; written once, again only when the file is replaced), the photo's
// state (metadata, Trash, group, where the original lives) and its development. Thumbnails, caches, History and
// analysis results stay on each Mac, apart from what syncs on its own (previews, suggested tags, snapshots).

/// The original as it syncs: what the file is. `updatedAt` is `CatalogAsset.originalUpdatedAt`.
public struct CatalogSyncOriginal: Codable, Equatable, Sendable {
    public var assetID: String
    public var filename: String
    public var kind: String
    public var fileSize: Int64?
    public var captureTime: String?
    public var infoData: Data
    public var extractedMetadata: Data
    public var importedAt: Date
    public var importBatchID: String?
    public var updatedAt: Date
}

/// The photo's state as it syncs. `updatedAt` is `CatalogAsset.updatedAt`.
public struct CatalogSyncState: Codable, Equatable, Sendable {
    public var assetID: String
    /// Where the original lives (`AssetLocator`).
    public var origin: String
    public var isCopy: Bool
    public var metadata: CatalogMetadata
    public var trashedAt: Date?
    /// Nil from a Mac whose build predates the archive.
    public var archivedAt: Date? = nil
    public var stackID: String?
    public var updatedAt: Date
}

/// The development as it syncs. `updatedAt` is `CatalogAsset.developmentUpdatedAt`.
public struct CatalogSyncDevelopment: Codable, Equatable, Sendable {
    public var assetID: String
    public var adjustmentsData: Data?
    public var xmpData: Data?
    public var xmpWarnings: String
    public var renderKey: String
    public var lastEditedAt: Date?
    public var updatedAt: Date
}

/// The parts of one photo another Mac changed after this Mac did; a new photo needs at least its original and state.
public struct CatalogSyncPhoto: Equatable, Sendable {
    public var assetID: String
    public var original: CatalogSyncOriginal?
    public var state: CatalogSyncState?
    public var development: CatalogSyncDevelopment?
    public init(assetID: String, original: CatalogSyncOriginal? = nil, state: CatalogSyncState? = nil, development: CatalogSyncDevelopment? = nil) {
        self.assetID = assetID; self.original = original; self.state = state; self.development = development
    }
}

/// When each part of a photo last changed here.
public struct CatalogSyncClocks: Equatable, Sendable {
    public var original: Date
    public var state: Date
    public var development: Date
}

extension CatalogMetadata {
    /// Keywords as a list, the way they sync: split at commas, trimmed, without empty ones.
    public var keywordList: [String] { CatalogMetadata.list(keywords) }
    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct CatalogSyncSnapshot: Codable, Equatable, Sendable {
    public var snapshotID: String
    public var assetID: String
    public var name: String
    public var adjustmentsJSON: Data
    public var createdAt: Date
}

public struct CatalogSyncTombstone: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "syncTombstone"
    public var id: String
    public var kind: String
    public var deletedAt: Date
}

extension CatalogStore {
    /// Every photo's clocks, so a sync pass can tell which parts the mirror has newer and which it lacks.
    public func syncClocks() throws -> [String: CatalogSyncClocks] {
        try database.read { db in
            var clocks: [String: CatalogSyncClocks] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, originalUpdatedAt, updatedAt, developmentUpdatedAt FROM asset") {
                clocks[row["id"]] = CatalogSyncClocks(original: row["originalUpdatedAt"], state: row["updatedAt"], development: row["developmentUpdatedAt"])
            }
            return clocks
        }
    }
    public func syncOriginals(_ ids: [String]) throws -> [CatalogSyncOriginal] {
        try database.read { db in
            let exif = Dictionary(uniqueKeysWithValues: try CatalogExif.fetchAll(db, keys: ids).map { ($0.assetID, $0.extractedMetadata) })
            // A photo missing its row is left out rather than holding back every other.
            return try CatalogAsset.fetchAll(db, keys: ids).compactMap { asset in
                guard let extracted = exif[asset.id] else { return nil }
                return CatalogSyncOriginal(assetID: asset.id, filename: asset.filename, kind: asset.kind, fileSize: asset.fileSize, captureTime: asset.captureTime,
                                           infoData: asset.infoData, extractedMetadata: extracted, importedAt: asset.importedAt, importBatchID: asset.importBatchID,
                                           updatedAt: asset.originalUpdatedAt)
            }
        }
    }
    public func syncStates(_ ids: [String]) throws -> [CatalogSyncState] {
        try database.read { db in
            try CatalogAsset.fetchAll(db, keys: ids).map { asset in
                CatalogSyncState(assetID: asset.id, origin: asset.origin,
                                 isCopy: asset.isCopy, metadata: asset.metadata, trashedAt: asset.trashedAt, archivedAt: asset.archivedAt, stackID: asset.stackID, updatedAt: asset.updatedAt)
            }
        }
    }
    public func syncDevelopments(_ ids: [String]) throws -> [CatalogSyncDevelopment] {
        try database.read { db in
            let developments = Dictionary(uniqueKeysWithValues: try CatalogDevelopment.fetchAll(db, keys: ids).map { ($0.assetID, $0) })
            return try CatalogAsset.fetchAll(db, keys: ids).compactMap { asset in
                guard let development = developments[asset.id] else { return nil }
                return CatalogSyncDevelopment(assetID: asset.id, adjustmentsData: development.adjustmentsData, xmpData: development.xmpData, xmpWarnings: asset.xmpWarnings,
                                              renderKey: asset.renderKey, lastEditedAt: asset.lastEditedAt, updatedAt: asset.developmentUpdatedAt)
            }
        }
    }
    /// Applies the parts of `photo` newer than this Mac's. A changed development is a History milestone, so the
    /// previous local state stays reachable. `blobs` carries data the development refers to that this catalog may
    /// not have yet; while some has not arrived, the development waits for a later pass and the rest applies.
    /// A photo this Mac doesn't have yet is added once its original and state have both arrived. Returns true when
    /// anything changed.
    @discardableResult
    public func applyRemote(_ photo: CatalogSyncPhoto, blobs: [String: Data] = [:]) throws -> Bool {
        if let state = photo.state { _ = try state.metadata.validated() }
        return try database.write { db in
            let assetID = photo.assetID
            let newest = [photo.original?.updatedAt, photo.state?.updatedAt, photo.development?.updatedAt].compactMap { $0 }.max() ?? .distantPast
            if let tombstone = try CatalogSyncTombstone.fetchOne(db, key: assetID), tombstone.deletedAt >= newest { return false }
            // A new photo's blobs are written before the photo itself.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else {
                guard let original = photo.original, let state = photo.state else { return false }
                try insertRemote(original, state, db)
                if let development = photo.development { _ = try applyDevelopment(development, blobs: blobs, db) }
                try Self.analysisChanged(db)
                return true
            }
            var changed = false
            if let original = photo.original, original.updatedAt > asset.originalUpdatedAt {
                asset.filename = original.filename; asset.kind = original.kind; asset.fileSize = original.fileSize; asset.captureTime = original.captureTime
                asset.importBatchID = original.importBatchID; asset.originalUpdatedAt = original.updatedAt
                // EXIF changes only when another Mac recorded a new file (Edit In).
                let exif = try CatalogExif.fetchOne(db, key: assetID)
                if asset.infoData != original.infoData || exif?.extractedMetadata != original.extractedMetadata {
                    let info = try JSONDecoder().decode(ImageInfo.self, from: original.infoData)
                    asset.infoData = original.infoData; asset.camera = CatalogCamera(extracted: original.extractedMetadata)
                    asset.hdr = info.defaultsFromImport == true ? info.defaults.hdr.enabled : nil
                    try CatalogExif(assetID: assetID, extractedMetadata: original.extractedMetadata).save(db)
                }
                try asset.update(db); changed = true
            }
            if let state = photo.state, state.updatedAt > asset.updatedAt {
                var metadata = state.metadata
                // The same keywords keep this Mac's way of writing them.
                if metadata.keywordList == asset.metadata.keywordList { metadata.keywords = asset.keywords }
                if asset.metadata != metadata {
                    try revision(assetID, kind: .metadata, summary: EditSummary.describe(metadata: metadata, from: asset.metadata), payload: JSONEncoder().encode(metadata)).insert(db)
                }
                asset.metadata = metadata; asset.trashedAt = state.trashedAt; asset.archivedAt = state.archivedAt; asset.stackID = state.stackID; asset.updatedAt = state.updatedAt
                // Another Mac may have relinked or replaced the original.
                if asset.origin != state.origin {
                    asset.origin = state.origin; asset.isCopy = state.isCopy
                    // The old bookmark would still resolve the old file, ahead of a volume or share locator.
                    asset.bookmark = nil
                    asset.sourcePath = { if case .file(let path)? = AssetLocator(string: state.origin) { return path } else { return "" } }()
                    asset.importPath = try Self.uniqueImportPath(state.origin, assetID: assetID, db)
                }
                try asset.update(db)
                if !asset.inLibrary { try CatalogAnalysisJob.deleteOne(db, key: assetID) }
                changed = true
            }
            if let development = photo.development, development.updatedAt > asset.developmentUpdatedAt, try applyDevelopment(development, blobs: blobs, db) {
                changed = true
            }
            if changed { try Self.analysisChanged(db) }
            return changed
        }
    }
    /// Adds a photo another Mac imported, without a development until that part arrives.
    private func insertRemote(_ original: CatalogSyncOriginal, _ state: CatalogSyncState, _ db: Database) throws {
        // Another Mac's row: its image facts must decode before they are stored (`CatalogAsset.info`).
        _ = try JSONDecoder().decode(ImageInfo.self, from: original.infoData)
        let locator = AssetLocator(string: state.origin)
        var asset = CatalogAsset(id: original.assetID, importPath: try Self.uniqueImportPath(state.origin, assetID: original.assetID, db),
            sourcePath: { if case .file(let path)? = locator { return path } else { return "" } }(), bookmark: nil,
            filename: original.filename, kind: original.kind, infoData: original.infoData, xmpWarnings: "",
            title: "", caption: "", keywords: "", rating: 0, review: .unreviewed, captureDay: "", latitude: nil, longitude: nil, suggestedTags: "",
            analysisVersion: nil, thumbnailKey: nil, thumbnailRenderKey: nil, renderKey: "", importedAt: original.importedAt, updatedAt: state.updatedAt, trashedAt: state.trashedAt, origin: state.origin)
        asset.archivedAt = state.archivedAt
        asset.metadata = state.metadata; asset.isCopy = state.isCopy; asset.stackID = state.stackID
        asset.fileSize = original.fileSize; asset.captureTime = original.captureTime; asset.importBatchID = original.importBatchID
        asset.camera = CatalogCamera(extracted: original.extractedMetadata)
        if asset.info.defaultsFromImport == true { asset.hdr = asset.info.defaults.hdr.enabled }
        asset.originalUpdatedAt = original.updatedAt; asset.developmentUpdatedAt = .distantPast
        // The Mac that imported the photo analyzes it; its suggested tags arrive with `applyRemoteAnalysis`.
        asset.analysisOrigin = "remote"
        try asset.insert(db)
        try CatalogExif(assetID: asset.id, extractedMetadata: original.extractedMetadata).insert(db)
        try CatalogDevelopment(assetID: asset.id).insert(db)
        try revision(asset.id, kind: .metadata, summary: L10n.tr("Received from iCloud"), payload: JSONEncoder().encode(state.metadata)).insert(db)
    }
    /// Writes a development from another Mac; false, with nothing written, while data it refers to hasn't arrived.
    private func applyDevelopment(_ remote: CatalogSyncDevelopment, blobs: [String: Data], _ db: Database) throws -> Bool {
        let assetID = remote.assetID
        guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { return false }
        var edits: Data?
        if let data = remote.adjustmentsData {
            guard let stored = try Self.receiveDevelopment(data, blobs: blobs, db, assetID: assetID, resources: resources) else { return false }
            edits = stored
        }
        var development = try Self.development(assetID, db)
        if let edits, development.adjustmentsData != edits {
            var entry = revision(assetID, kind: .edit, summary: L10n.tr("Received from iCloud"), payload: edits); entry.milestone = true
            try entry.insert(db)
        }
        development.adjustmentsData = edits; development.xmpData = remote.xmpData
        asset.xmpWarnings = remote.xmpWarnings; asset.renderKey = remote.renderKey; asset.lastEditedAt = remote.lastEditedAt
        asset.developmentUpdatedAt = remote.updatedAt
        try development.update(db); try asset.update(db)
        try Self.removeStaleBlobs(of: assetID, db)
        return true
    }
    /// The duplicate key is the origin, unique per catalog; a photo imported separately on two Macs keeps both rows.
    private static func uniqueImportPath(_ origin: String, assetID: String, _ db: Database) throws -> String {
        let taken = try CatalogAsset.filter(CatalogAsset.Columns.importPath == origin && CatalogAsset.Columns.id != assetID).fetchCount(db) > 0
        return taken ? origin + "#" + assetID : origin
    }
    /// Deletions still to send: photos (`asset`), albums (`album`) or a photo leaving an album (`albumAsset`).
    public func tombstones(kind: String = "asset") throws -> [CatalogSyncTombstone] {
        try database.read { try CatalogSyncTombstone.filter(Column("kind") == kind).fetchAll($0) }
    }
    public func removeTombstones(_ ids: [String]) throws {
        try database.write { db in for id in ids { _ = try CatalogSyncTombstone.deleteOne(db, key: id) } }
    }
    /// Removes photos another Mac deleted permanently. Their originals on this Mac are left alone.
    public func applyRemoteDeletion(_ assetID: String, deletedAt: Date) async throws {
        try database.writeSync { db in
            guard let asset = try CatalogAsset.fetchOne(db, key: assetID), asset.updatedAt <= deletedAt else { return }
            try Self.rememberDeletedImports([assetID], db)
            try CatalogAsset.deleteOne(db, key: assetID)
            try Self.analysisChanged(db)
        }
        try? await previews.remove(assetIDs: [assetID])
    }
    public func snapshotRecords() throws -> [CatalogSyncSnapshot] {
        try database.read { db in
            try CatalogSnapshot.fetchAll(db).map {
                CatalogSyncSnapshot(snapshotID: $0.id, assetID: $0.assetID, name: $0.name, adjustmentsJSON: $0.payload, createdAt: $0.createdAt)
            }
        }
    }
    /// Adds snapshots this Mac does not have and renames ones it does. Returns the IDs applied; a new snapshot
    /// whose data has not arrived (in `blobs` or this catalog) waits for a later pass.
    @discardableResult
    public func applyRemoteSnapshots(_ remote: [CatalogSyncSnapshot], blobs: [String: Data] = [:]) throws -> Set<String> {
        try database.write { db in
            var applied: Set<String> = []
            for item in remote {
                // One this build can't read is left in the mirror for a later build; the others still arrive.
                var done = false
                try? db.inSavepoint {
                    guard try CatalogAsset.exists(db, key: item.assetID) else { return .rollback }
                    if var existing = try CatalogSnapshot.fetchOne(db, key: item.snapshotID) {
                        if existing.name != item.name { existing.name = item.name; try existing.update(db) }
                    } else {
                        guard let stored = try Self.receiveDevelopment(item.adjustmentsJSON, blobs: blobs, db, assetID: item.assetID, resources: resources) else { return .rollback }
                        try CatalogSnapshot(id: item.snapshotID, assetID: item.assetID, name: item.name, payload: stored, thumbnail: nil, createdAt: item.createdAt).insert(db)
                    }
                    done = true
                    return .commit
                }
                if done { applied.insert(item.snapshotID) }
            }
            return applied
        }
    }
    /// Stored JSON for one of `assetID`'s developments from another Mac, after adding the mask blobs it refers to
    /// from `blobs`; nil, with nothing written, while a blob is neither there nor in this catalog, or a LUT or profile
    /// it uses has not reached this Mac's library yet.
    private static func receiveDevelopment(_ remote: Data, blobs: [String: Data], _ db: Database, assetID: String, resources: ResourceStorage) throws -> Data? {
        let missing = try RevisionPayload.references(remote).filter { try !CatalogBlob.exists(db, key: $0) }
        guard missing.allSatisfy({ blobs[$0] != nil }) else { return nil }
        for id in missing { try CatalogBlob(id: id, assetID: assetID, data: blobs[id]!).insert(db) }
        do {
            let settings = try decodeDevelopment(remote, db, resources: resources)
            return try encodeDevelopment(settings, db, assetID: assetID, resources: resources)
        } catch is ResourceUnavailable {
            for id in missing { _ = try CatalogBlob.deleteOne(db, key: id) }
            return nil
        }
    }
    /// A photo's suggested tags as they sync: what one Mac's analysis produced, and when.
    public struct AnalysisResult: Equatable, Sendable {
        public var tags: String
        public var version: String
        public var analyzedAt: Date
        /// Faces found; nil from a version that didn't look.
        public var faces: Int?
        /// Where they are (`assetFace`); nil from a version that only counted them.
        public var faceBoxes: [CatalogFace]?
        public init(tags: String, version: String, analyzedAt: Date, faces: Int? = nil, faceBoxes: [CatalogFace]? = nil) {
            self.tags = tags; self.version = version; self.analyzedAt = analyzedAt; self.faces = faces; self.faceBoxes = faceBoxes
        }
    }
    /// Results this Mac produced (`analysisOrigin` is `local`), to upload.
    public func localAnalysisResults() throws -> [String: AnalysisResult] {
        try database.read { db in
            var results: [String: AnalysisResult] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, suggestedTags, analysisVersion, analyzedAt, faceCount FROM asset
                WHERE analysisOrigin = 'local' AND analysisVersion IS NOT NULL AND analyzedAt IS NOT NULL
                """) {
                let faces: Int? = row["faceCount"]
                results[row["id"]] = AnalysisResult(tags: row["suggestedTags"], version: row["analysisVersion"], analyzedAt: row["analyzedAt"], faces: faces,
                                                    faceBoxes: faces == nil ? nil : [])
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT f.* FROM assetFace f JOIN asset a ON a.id = f.assetID WHERE a.analysisOrigin = 'local' ORDER BY f.assetID, f.idx
                """) {
                results[row["assetID"]]?.faceBoxes?.append(Self.face(row))
            }
            return results
        }
    }
    /// Suggested tags another Mac produced: the source of truth, so this Mac never reads the original (which may not
    /// even be downloaded) to analyze the photo itself. A result newer than this Mac's replaces it, whatever analysis
    /// version made it, and this Mac's queued analysis of the photo is dropped. Returns true when anything changed.
    @discardableResult
    public func applyRemoteAnalysis(_ results: [String: AnalysisResult]) throws -> Bool {
        try database.write { db in
            var changed = false
            for (assetID, result) in results {
                guard let row = try Row.fetchOne(db, sql: "SELECT analyzedAt FROM asset WHERE id = ?", arguments: [assetID]) else { continue }
                if let local: Date = row["analyzedAt"], local >= result.analyzedAt { continue }
                try CatalogAsset.filter(key: assetID).updateAll(db, CatalogAsset.Columns.suggestedTags.set(to: result.tags), CatalogAsset.Columns.analysisVersion.set(to: result.version),
                                                               CatalogAsset.Columns.analyzedAt.set(to: result.analyzedAt), CatalogAsset.Columns.analysisOrigin.set(to: "remote"))
                // A result from a build that only counted faces keeps the count, with no boxes behind it.
                if let boxes = result.faceBoxes { try Self.setFaces(boxes, assetID: assetID, db) }
                else {
                    try Self.setFaces(nil, assetID: assetID, db)
                    try CatalogAsset.filter(key: assetID).updateAll(db, Column(Self.faceCountColumn).set(to: result.faces))
                }
                try db.execute(sql: "DELETE FROM analysisJob WHERE assetID = ? AND state != ?", arguments: [assetID, CatalogAnalysisJob.State.running])
                changed = true
            }
            if changed { try Self.analysisChanged(db) }
            return changed
        }
    }
    /// Each photo's development (`renderKey`), whether it has a grid preview, and whether that preview shows the
    /// development (rather than the camera's embedded preview of an edited photo).
    public func previewStates() throws -> [String: (renderKey: String, present: Bool, current: Bool)] {
        try database.read { db in
            var states: [String: (String, Bool, Bool)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, renderKey, thumbnailKey IS NOT NULL AS present, thumbnailKey IS NOT NULL AND thumbnailRenderKey IS renderKey AS current FROM asset") {
                states[row["id"]] = (row["renderKey"], row["present"], row["current"])
            }
            return states
        }
    }
    /// The photo's grid preview, to sync.
    public func previewData(_ assetID: String) async throws -> Data? { try await previews.data(assetID: assetID) }
    /// The subset of `ids` this catalog has no blob for.
    public func missingBlobs(_ ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let present = try database.read { try CatalogBlob.filter(keys: Array(ids)).select(CatalogBlob.Columns.id, as: String.self).fetchAll($0) }
        return ids.subtracting(present)
    }
    /// Blob data by ID, for the given IDs this catalog has.
    public func blobs(_ ids: Set<String>) throws -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            Dictionary(try CatalogBlob.filter(keys: Array(ids)).fetchAll(db).map { ($0.id, $0.data) }, uniquingKeysWith: { a, _ in a })
        }
    }
    public func removeSnapshotsMissing(from remoteIDs: Set<String>, knownBefore: Set<String>) throws {
        try database.write { db in
            for id in knownBefore.subtracting(remoteIDs) {
                guard let snapshot = try CatalogSnapshot.fetchOne(db, key: id) else { continue }
                try snapshot.delete(db)
                try Self.removeStaleBlobs(of: snapshot.assetID, db)
            }
        }
    }
}
