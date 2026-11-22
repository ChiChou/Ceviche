import Foundation
import GRDB

/// An album as it syncs: its name, and when it last changed.
public struct CatalogSyncAlbum: Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
}

/// One photo in one album. Each is its own record, so a photo added on one Mac and another removed on a second Mac
/// both survive; a photo added and removed on two Macs keeps the later change.
public struct CatalogSyncAlbumEntry: Equatable, Sendable {
    public var albumID: String
    public var assetID: String
    public var position: Int
    public var updatedAt: Date
    public var key: String { CatalogStore.albumEntryID(albumID, assetID) }
}

extension CatalogStore {
    /// Albums and album photos changed since they last matched iCloud.
    public func albumsNeedingSync() throws -> (albums: [CatalogSyncAlbum], entries: [CatalogSyncAlbumEntry]) {
        try database.read { db in
            let albums = try Row.fetchAll(db, sql: "SELECT id, name, createdAt, updatedAt FROM album WHERE syncedAt IS NULL OR updatedAt > syncedAt").map {
                CatalogSyncAlbum(id: $0["id"], name: $0["name"], createdAt: $0["createdAt"], updatedAt: $0["updatedAt"])
            }
            let entries = try Row.fetchAll(db, sql: "SELECT albumID, assetID, position, updatedAt FROM albumAsset WHERE syncedAt IS NULL OR updatedAt > syncedAt").map {
                CatalogSyncAlbumEntry(albumID: $0["albumID"], assetID: $0["assetID"], position: $0["position"], updatedAt: $0["updatedAt"])
            }
            return (albums, entries)
        }
    }
    /// Records that these albums and album photos now match iCloud, unless they changed again meanwhile.
    public func markAlbumsSynced(_ albums: [CatalogSyncAlbum], entries: [CatalogSyncAlbumEntry]) throws {
        try database.write { db in
            for album in albums {
                try db.execute(sql: "UPDATE album SET syncedAt = updatedAt WHERE id = ? AND updatedAt = ?", arguments: [album.id, album.updatedAt])
            }
            for entry in entries {
                try db.execute(sql: "UPDATE albumAsset SET syncedAt = updatedAt WHERE albumID = ? AND assetID = ? AND updatedAt = ?",
                               arguments: [entry.albumID, entry.assetID, entry.updatedAt])
            }
        }
    }
    /// Applies albums and album photos from other Macs where they are newer than this Mac's, and deletions dated after
    /// this Mac's last change. A photo this catalog does not have yet is skipped, so a later pass adds it. Returns
    /// true when anything changed.
    @discardableResult
    public func applyRemoteAlbums(_ albums: [CatalogSyncAlbum], deletedAlbums: [String: Date],
                                  entries: [CatalogSyncAlbumEntry], removedEntries: [String: Date]) throws -> Bool {
        try database.write { db in
            var changed = false
            for album in albums {
                if let tombstone = try CatalogSyncTombstone.fetchOne(db, key: album.id), tombstone.deletedAt >= album.updatedAt { continue }
                if let local = try Date.fetchOne(db, sql: "SELECT updatedAt FROM album WHERE id = ?", arguments: [album.id]) {
                    guard album.updatedAt > local else { continue }
                    try db.execute(sql: "UPDATE album SET name = ?, updatedAt = ?, syncedAt = ? WHERE id = ?", arguments: [album.name, album.updatedAt, album.updatedAt, album.id])
                } else {
                    try db.execute(sql: "INSERT INTO album(id, name, createdAt, updatedAt, syncedAt) VALUES (?, ?, ?, ?, ?)",
                                   arguments: [album.id, album.name, album.createdAt, album.updatedAt, album.updatedAt])
                }
                changed = true
            }
            for (id, deletedAt) in deletedAlbums {
                guard let local = try Date.fetchOne(db, sql: "SELECT updatedAt FROM album WHERE id = ?", arguments: [id]), local <= deletedAt else { continue }
                try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [id])
                changed = true
            }
            for entry in entries {
                if let tombstone = try CatalogSyncTombstone.fetchOne(db, key: entry.key), tombstone.deletedAt >= entry.updatedAt { continue }
                guard try CatalogAlbum.exists(db, key: entry.albumID), try CatalogAsset.exists(db, key: entry.assetID) else { continue }
                let local = try Date.fetchOne(db, sql: "SELECT updatedAt FROM albumAsset WHERE albumID = ? AND assetID = ?", arguments: [entry.albumID, entry.assetID])
                if let local, entry.updatedAt <= local { continue }
                try db.execute(sql: """
                    INSERT INTO albumAsset(albumID, assetID, position, updatedAt, syncedAt) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(albumID, assetID) DO UPDATE SET position = excluded.position, updatedAt = excluded.updatedAt, syncedAt = excluded.syncedAt
                    """, arguments: [entry.albumID, entry.assetID, entry.position, entry.updatedAt, entry.updatedAt])
                changed = true
            }
            for (key, deletedAt) in removedEntries {
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let local = try Date.fetchOne(db, sql: "SELECT updatedAt FROM albumAsset WHERE albumID = ? AND assetID = ?", arguments: [parts[0], parts[1]]),
                      local <= deletedAt else { continue }
                try db.execute(sql: "DELETE FROM albumAsset WHERE albumID = ? AND assetID = ?", arguments: [parts[0], parts[1]])
                changed = true
            }
            return changed
        }
    }
}
