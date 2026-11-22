import Foundation
import GRDB

public struct CatalogAlbum: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "album"
    public let id: String
    public var name: String
    public let createdAt: Date
}

public struct CatalogAlbumSummary: Identifiable, Equatable, Sendable {
    public let album: CatalogAlbum
    public let count: Int
    public let coverAssetID: String?
    public let thumbnailKey: String?
    public var id: String { album.id }
}

/// Counts include only active photos. A batch spanning midnight appears under each import day.
public struct CatalogImportGroup: Equatable, Sendable {
    public let day: String
    public let batchID: String?
    public let startedAt: Date
    public let count: Int
}

extension CatalogStore {
    public func importGroups() throws -> [CatalogImportGroup] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT date(importedAt, 'localtime') AS day, importBatchID, MIN(importedAt) AS startedAt, COUNT(*) AS count
                FROM asset WHERE trashedAt IS NULL AND archivedAt IS NULL GROUP BY day, importBatchID ORDER BY day DESC, startedAt DESC, importBatchID
                """).map { CatalogImportGroup(day: $0["day"], batchID: $0["importBatchID"], startedAt: $0["startedAt"], count: $0["count"]) }
        }
    }

    public func albums() throws -> [CatalogAlbumSummary] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT album.*, COUNT(asset.id) AS count,
                    (SELECT a.id FROM albumAsset m JOIN asset a ON a.id = m.assetID
                     WHERE m.albumID = album.id AND a.trashedAt IS NULL AND a.archivedAt IS NULL ORDER BY m.position, a.id LIMIT 1) AS coverAssetID,
                    (SELECT a.thumbnailKey FROM albumAsset m JOIN asset a ON a.id = m.assetID
                     WHERE m.albumID = album.id AND a.trashedAt IS NULL AND a.archivedAt IS NULL ORDER BY m.position, a.id LIMIT 1) AS coverKey
                FROM album LEFT JOIN albumAsset ON albumAsset.albumID = album.id
                LEFT JOIN asset ON asset.id = albumAsset.assetID AND asset.trashedAt IS NULL AND asset.archivedAt IS NULL
                GROUP BY album.id ORDER BY album.name COLLATE NOCASE, album.id
                """).map { CatalogAlbumSummary(album: try CatalogAlbum(row: $0), count: $0["count"], coverAssetID: $0["coverAssetID"], thumbnailKey: $0["coverKey"]) }
        }
    }

    @discardableResult
    public func createAlbum(name: String, assetIDs: [String] = []) throws -> CatalogAlbum {
        let album = CatalogAlbum(id: UUID().uuidString, name: try Self.albumName(name), createdAt: Date())
        try database.write { db in
            try album.insert(db)
            try db.execute(sql: "UPDATE album SET updatedAt = ? WHERE id = ?", arguments: [album.createdAt, album.id])
            try Self.addToAlbum(album.id, assetIDs: assetIDs, db: db)
        }
        return album
    }

    public func renameAlbum(_ id: String, to name: String) throws {
        let name = try Self.albumName(name)
        try database.write { db in
            guard try CatalogAlbum.exists(db, key: id) else { throw EditorError.invalidDocument(L10n.tr("Album no longer exists.")) }
            try db.execute(sql: "UPDATE album SET name = ?, updatedAt = ? WHERE id = ?", arguments: [name, Date(), id])
        }
    }

    /// Deletes only the collection; photos, originals, edits and other albums remain intact.
    public func deleteAlbum(_ id: String) throws {
        try database.write { db in try Self.deleteAlbum(id, db: db) }
    }
    private static func deleteAlbum(_ id: String, db: Database) throws {
        guard try CatalogAlbum.deleteOne(db, key: id) else { return }
        try CatalogSyncTombstone(id: id, kind: "album", deletedAt: Date()).insert(db, onConflict: .replace)
    }

    public func activeAlbumPhotoIDs(_ id: String) throws -> [String] {
        try database.read { db in try Self.activeAlbumPhotoIDs(id, db: db) }
    }
    private static func activeAlbumPhotoIDs(_ id: String, db: Database) throws -> [String] {
        guard try CatalogAlbum.exists(db, key: id) else { throw EditorError.invalidDocument(L10n.tr("Album no longer exists.")) }
        return try String.fetchAll(db, sql: """
            SELECT asset.id FROM albumAsset JOIN asset ON asset.id = albumAsset.assetID
            WHERE albumAsset.albumID = ? AND asset.trashedAt IS NULL AND asset.archivedAt IS NULL ORDER BY asset.id
            """, arguments: [id])
    }

    /// Both changes share a transaction. Other album memberships remain recoverable with the photos.
    public func trashPhotosAndDeleteAlbum(_ id: String, expectedPhotoIDs: [String]) throws {
        try database.write { db in
            let ids = try Self.activeAlbumPhotoIDs(id, db: db)
            guard Set(ids) == Set(expectedPhotoIDs) else {
                throw EditorError.invalidDocument(L10n.tr("Album contents changed. Review the album and try again."))
            }
            try Self.moveToTrash(ids, db: db)
            try Self.deleteAlbum(id, db: db)
        }
    }

    public func addToAlbum(_ id: String, assetIDs: [String]) throws {
        try database.write { db in try Self.addToAlbum(id, assetIDs: assetIDs, db: db) }
    }

    public func removeFromAlbum(_ id: String, assetIDs: [String]) throws {
        try database.write { db in
            for assetID in Set(assetIDs) {
                try db.execute(sql: "DELETE FROM albumAsset WHERE albumID = ? AND assetID = ?", arguments: [id, assetID])
                guard db.changesCount > 0 else { continue }
                try CatalogSyncTombstone(id: Self.albumEntryID(id, assetID), kind: "albumAsset", deletedAt: Date()).insert(db, onConflict: .replace)
            }
        }
    }
    /// The tombstone and mirror key of one photo in one album.
    static func albumEntryID(_ albumID: String, _ assetID: String) -> String { albumID + "/" + assetID }

    private static func albumName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EditorError.invalidDocument(L10n.tr("Enter an album name.")) }
        return name
    }

    private static func addToAlbum(_ id: String, assetIDs: [String], db: Database) throws {
        guard try CatalogAlbum.fetchOne(db, key: id) != nil else { throw EditorError.invalidDocument(L10n.tr("Album no longer exists.")) }
        var position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM albumAsset WHERE albumID = ?", arguments: [id]) ?? -1) + 1
        let now = Date()
        for assetID in assetIDs {
            // INSERT OR IGNORE preserves the first photo and makes adding a selection idempotent.
            try db.execute(sql: """
                INSERT OR IGNORE INTO albumAsset(albumID, assetID, position, updatedAt)
                SELECT ?, id, ?, ? FROM asset WHERE id = ? AND trashedAt IS NULL AND archivedAt IS NULL
                """, arguments: [id, position, now, assetID])
            // Added back after being removed: the removal no longer travels.
            if db.changesCount > 0 { _ = try CatalogSyncTombstone.deleteOne(db, key: albumEntryID(id, assetID)) }
            position += 1
        }
    }
}

/// The whole catalog at a glance, outside the Trash: what the Library inspector shows without a selection.
public struct CatalogOverview: Equatable, Sendable {
    public var photos = 0, raw = 0, picked = 0, rejected = 0, edited = 0
    /// ISO capture days of the oldest and newest photo with one.
    public var firstDay: String?, lastDay: String?
    public init() {}
}

extension CatalogStore {
    public func overview() throws -> CatalogOverview {
        try database.read { db in
            var overview = CatalogOverview()
            if let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS photos, COUNT(CASE WHEN kind = 'RAW' THEN 1 END) AS raw,
                    COUNT(CASE WHEN review = 'accepted' THEN 1 END) AS picked, COUNT(CASE WHEN review = 'rejected' THEN 1 END) AS rejected,
                    COUNT(lastEditedAt) AS edited,
                    MIN(NULLIF(captureDay, '')) AS firstDay, MAX(NULLIF(captureDay, '')) AS lastDay
                FROM asset WHERE trashedAt IS NULL AND archivedAt IS NULL
                """) {
                overview.photos = row["photos"]; overview.raw = row["raw"]; overview.picked = row["picked"]
                overview.rejected = row["rejected"]; overview.edited = row["edited"]
                overview.firstDay = row["firstDay"]; overview.lastDay = row["lastDay"]
            }
            return overview
        }
    }
}
