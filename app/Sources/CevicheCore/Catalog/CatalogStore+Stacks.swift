import Foundation
import GRDB

/// Groups of photos the person put together, such as a burst or the frames of a merge, shown as one in the library.
extension CatalogStore {
    /// Puts the photos in one group, together with the rest of any group one of them was already in. The earliest
    /// becomes the cover, or `cover` when it is one of them (the RAW of a RAW + JPEG pair). Returns the cover's ID, or nil
    /// when fewer than two photos would be in the group.
    @discardableResult
    public func stack(_ assetIDs: [String], cover chosenCover: String? = nil) throws -> String? {
        try database.write { db in
            let ids = Set(assetIDs)
            let chosen = try CatalogAsset.filter(keys: ids).fetchAll(db)
            let joined = Set(chosen.compactMap(\.stackID))
            let others = joined.isEmpty ? [] : try CatalogAsset.filter(joined.contains(Columns.stackID) && !ids.contains(Columns.id)).fetchAll(db)
            let members = chosen + others
            guard members.count >= 2 else { return nil }
            let cover = chosenCover.flatMap { id in members.contains { $0.id == id } ? id : nil } ?? members.min { ($0.captureDay, $0.captureTime ?? "", $0.id) < ($1.captureDay, $1.captureTime ?? "", $1.id) }!.id
            try CatalogAsset.filter(keys: members.map(\.id)).filter(Columns.stackID == nil || Columns.stackID != cover)
                .updateAll(db, Columns.stackID.set(to: cover), Columns.updatedAt.set(to: Date()))
            return cover
        }
    }
    /// Takes apart every group one of the photos is in.
    public func unstack(_ assetIDs: [String]) throws {
        try database.write { db in
            let groups = Set(try CatalogAsset.filter(keys: Set(assetIDs)).fetchAll(db).compactMap(\.stackID))
            guard !groups.isEmpty else { return }
            try CatalogAsset.filter(groups.contains(Columns.stackID)).updateAll(db, Columns.stackID.set(to: nil), Columns.updatedAt.set(to: Date()))
        }
    }
    /// After photos leave the library: a group left with one photo there is taken apart, its photos in the Trash or
    /// the archive included, so none comes back into a group of one; a group whose cover left takes its earliest
    /// remaining photo as the cover.
    static func tidyStacks(_ groups: Set<String>, db: Database) throws {
        for group in groups {
            let members = try CatalogAsset.filter(Columns.stackID == group).fetchAll(db)
            let remaining = members.filter(\.inLibrary)
            if remaining.count < 2 {
                try CatalogAsset.filter(Columns.stackID == group).updateAll(db, Columns.stackID.set(to: nil), Columns.updatedAt.set(to: Date()))
            } else if !remaining.contains(where: { $0.id == group }) {
                let cover = remaining.min { ($0.captureDay, $0.captureTime ?? "", $0.id) < ($1.captureDay, $1.captureTime ?? "", $1.id) }!.id
                try CatalogAsset.filter(Columns.stackID == group).updateAll(db, Columns.stackID.set(to: cover), Columns.updatedAt.set(to: Date()))
            }
        }
    }
    /// The group of each photo and of every other photo in its group: everything `stack` or `unstack` can change,
    /// for undoing it with `restoreStacks`.
    public func stackState(_ assetIDs: [String]) throws -> [String: String?] {
        try database.read { db in
            let ids = Set(assetIDs)
            let chosen = try CatalogAsset.filter(keys: ids).fetchAll(db)
            let groups = Set(chosen.compactMap(\.stackID))
            let others = groups.isEmpty ? [] : try CatalogAsset.filter(groups.contains(Columns.stackID)).fetchAll(db)
            return Dictionary((chosen + others).map { ($0.id, $0.stackID) }, uniquingKeysWith: { first, _ in first })
        }
    }
    public func restoreStacks(_ state: [String: String?]) throws {
        try database.write { db in
            for (id, stackID) in state {
                try CatalogAsset.filter(key: id).updateAll(db, Columns.stackID.set(to: stackID), Columns.updatedAt.set(to: Date()))
            }
        }
    }
    /// The photos outside the Trash in the groups with these covers, covers included.
    public func stackMembers(_ covers: [String]) throws -> [CatalogAsset] {
        guard !covers.isEmpty else { return [] }
        return try database.read { db in
            try CatalogAsset.filter(Set(covers).contains(Columns.stackID) && Columns.area(.library)).fetchAll(db)
        }
    }
    /// How many photos outside the Trash each group has, by cover.
    public func stackSizes() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT stackID, COUNT(*) AS count FROM asset WHERE stackID IS NOT NULL AND trashedAt IS NULL AND archivedAt IS NULL GROUP BY stackID")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["stackID"], $0["count"]) })
        }
    }
}
