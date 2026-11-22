import CoreGraphics
import Foundation
import GRDB

/// Someone the Faces wall grouped faces into. A person is only an ID and an optional name; their faces point at them
/// (`assetFace.personID`). A per-catalog record, not synced yet: another Mac groups its own faces.
public struct CatalogPerson: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var createdAt: Date
}

/// A face the People backfill embeds: where it is, and the photo to cut it from when its wall tile is missing.
public struct CatalogFaceToEmbed: Sendable {
    public var key: CatalogFaceKey
    public var bounds: CGRect
    public var asset: CatalogAsset
}

extension CatalogStore {
    static func createPeopleTables(_ db: Database) throws {
        try db.create(table: "person") { t in
            t.primaryKey("id", .text)
            t.column("name", .text)
            t.column("createdAt", .double).notNull()
        }
        try db.alter(table: "assetFace") { t in
            t.add(column: "personID", .text).references("person", onDelete: .setNull)
            // Placed or taken out by hand: grouping never moves it.
            t.add(column: "pinned", .boolean).notNull().defaults(to: false)
            // `FaceEmbedding.count` Float16 values; empty when the face couldn't be embedded (no landmarks, no original).
            t.add(column: "embedding", .blob)
            t.add(column: "embeddingRevision", .integer)
        }
        try db.create(index: "assetFace_person", on: "assetFace", columns: ["personID"])
    }

    // MARK: Embedding

    /// Wall-sized faces of library photos without an embedding of the current revision, newest imports first.
    public func facesNeedingEmbedding(limit: Int) throws -> [CatalogFaceToEmbed] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.assetID, f.idx, f.x, f.y, f.width, f.height FROM assetFace f JOIN asset a ON a.id = f.assetID
                WHERE f.width >= ? AND (f.embeddingRevision IS NULL OR f.embeddingRevision != ?)
                AND a.trashedAt IS NULL AND a.archivedAt IS NULL AND a.kind != ?
                ORDER BY a.importedAt DESC, f.assetID, f.idx LIMIT ?
                """, arguments: [CatalogFace.wallWidth, FaceEmbedding.revision, LatentImage.kind, limit])
            let ids = Array(Set(rows.map { $0["assetID"] as String }))
            let assets = Dictionary(try CatalogAsset.filter(keys: ids).fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return rows.compactMap { row in
                guard let asset = assets[row["assetID"]] else { return nil }
                return CatalogFaceToEmbed(key: CatalogFaceKey(assetID: row["assetID"], index: row["idx"]),
                                          bounds: CGRect(x: row["x"] as Double, y: row["y"] as Double, width: row["width"] as Double, height: row["height"] as Double),
                                          asset: asset)
            }
        }
    }
    /// Stores embeddings (nil: tried, none found) for faces still where they were when the backfill read them.
    public func saveEmbeddings(_ results: [(face: CatalogFaceToEmbed, vector: [Float]?)]) throws {
        try database.write { db in
            for (face, vector) in results {
                let b = face.bounds
                try db.execute(sql: """
                    UPDATE assetFace SET embedding = ?, embeddingRevision = ?
                    WHERE assetID = ? AND idx = ? AND abs(x - ?) < 1e-9 AND abs(y - ?) < 1e-9 AND abs(width - ?) < 1e-9 AND abs(height - ?) < 1e-9
                    """, arguments: [vector.map(FaceEmbedding.data) ?? Data(), FaceEmbedding.revision, face.key.assetID, face.key.index,
                                     b.minX, b.minY, b.width, b.height])
            }
        }
    }
    /// How many wall-sized faces of library photos have an embedding, and how many are still to be embedded.
    public func embeddingProgress() throws -> (done: Int, waiting: Int) {
        try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT sum(f.embeddingRevision = ?) AS done, sum(f.embeddingRevision IS NULL OR f.embeddingRevision != ?) AS waiting
                FROM assetFace f JOIN asset a ON a.id = f.assetID
                WHERE f.width >= ? AND a.trashedAt IS NULL AND a.archivedAt IS NULL AND a.kind != ?
                """, arguments: [FaceEmbedding.revision, FaceEmbedding.revision, CatalogFace.wallWidth, LatentImage.kind])
            return ((row?["done"] as Int?) ?? 0, (row?["waiting"] as Int?) ?? 0)
        }
    }

    // MARK: Grouping

    /// Places the faces nobody holds (`PeopleGrouping`) and forgets unnamed people left without a face. Returns
    /// whether anything changed.
    @discardableResult
    public func groupPeople(now: Date = Date()) throws -> Bool {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.assetID, f.idx, f.embedding, f.personID, f.pinned, a.captureTime FROM assetFace f JOIN asset a ON a.id = f.assetID
                WHERE f.embeddingRevision = ? AND length(f.embedding) = ? AND a.trashedAt IS NULL AND a.archivedAt IS NULL
                """, arguments: [FaceEmbedding.revision, FaceEmbedding.count * 2])
            let faces = rows.compactMap { row -> PeopleGrouping.Face? in
                guard let vector = FaceEmbedding.vector(row["embedding"]) else { return nil }
                return PeopleGrouping.Face(key: CatalogFaceKey(assetID: row["assetID"], index: row["idx"]), vector: vector,
                                           captureTime: row["captureTime"], personID: row["personID"], pinned: row["pinned"])
            }
            let result = PeopleGrouping.group(faces)
            for (key, person) in result.joined {
                try db.execute(sql: "UPDATE assetFace SET personID = ? WHERE assetID = ? AND idx = ? AND personID IS NULL AND pinned = 0",
                               arguments: [person, key.assetID, key.index])
            }
            for members in result.created {
                let id = UUID().uuidString
                try db.execute(sql: "INSERT INTO person(id, name, createdAt) VALUES (?, NULL, ?)", arguments: [id, now.timeIntervalSinceReferenceDate])
                for key in members {
                    try db.execute(sql: "UPDATE assetFace SET personID = ? WHERE assetID = ? AND idx = ? AND personID IS NULL AND pinned = 0",
                                   arguments: [id, key.assetID, key.index])
                }
            }
            try Self.forgetEmptyPeople(db)
            return !result.joined.isEmpty || !result.created.isEmpty || db.changesCount > 0
        }
    }
    static func forgetEmptyPeople(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM person WHERE name IS NULL AND NOT EXISTS (SELECT 1 FROM assetFace f WHERE f.personID = person.id)")
    }

    // MARK: People

    public func people() throws -> [CatalogPerson] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM person ORDER BY createdAt, id").map {
                CatalogPerson(id: $0["id"], name: $0["name"], createdAt: Date(timeIntervalSinceReferenceDate: $0["createdAt"]))
            }
        }
    }
    /// Names a person; an empty name clears it.
    public func renamePerson(_ id: String, name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.write { db in
            try db.execute(sql: "UPDATE person SET name = ? WHERE id = ?", arguments: [trimmed?.isEmpty == false ? trimmed : nil, id])
            try Self.forgetEmptyPeople(db)
        }
    }
    /// Puts faces with a person by hand, or takes them out of every group (`nil`); grouping never moves them again.
    public func assignFaces(_ keys: [CatalogFaceKey], to personID: String?) throws {
        try database.write { db in
            for key in keys {
                try db.execute(sql: "UPDATE assetFace SET personID = ?, pinned = 1 WHERE assetID = ? AND idx = ?", arguments: [personID, key.assetID, key.index])
            }
            try Self.forgetEmptyPeople(db)
        }
    }
    /// A new person holding `keys`, pinned to them.
    @discardableResult
    public func newPerson(with keys: [CatalogFaceKey], name: String? = nil, now: Date = Date()) throws -> String {
        let id = UUID().uuidString
        try database.write { db in
            try db.execute(sql: "INSERT INTO person(id, name, createdAt) VALUES (?, ?, ?)", arguments: [id, name, now.timeIntervalSinceReferenceDate])
            for key in keys {
                try db.execute(sql: "UPDATE assetFace SET personID = ?, pinned = 1 WHERE assetID = ? AND idx = ?", arguments: [id, key.assetID, key.index])
            }
            try Self.forgetEmptyPeople(db)
        }
        return id
    }
    /// Moves every face of `others` to `target`, which keeps its name or takes the first of theirs.
    public func mergePeople(_ others: [String], into target: String) throws {
        let others = others.filter { $0 != target }
        guard !others.isEmpty else { return }
        try database.write { db in
            let list = String(decoding: try JSONEncoder().encode(others), as: UTF8.self)
            try db.execute(sql: """
                UPDATE person SET name = coalesce(name, (SELECT p.name FROM person p WHERE p.id IN (SELECT value FROM json_each(?1)) AND p.name IS NOT NULL ORDER BY p.createdAt LIMIT 1))
                WHERE id = ?2
                """, arguments: [list, target])
            try db.execute(sql: "UPDATE assetFace SET personID = ? WHERE personID IN (SELECT value FROM json_each(?))", arguments: [target, list])
            try db.execute(sql: "DELETE FROM person WHERE id IN (SELECT value FROM json_each(?))", arguments: [list])
        }
    }
    /// Breaks a person up: their faces leave every group for good, and the person is gone.
    public func removePerson(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE assetFace SET personID = NULL, pinned = 1 WHERE personID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [id])
        }
    }
    /// Lets grouping place every face again that it placed itself: faces put or taken out by hand, and named people,
    /// stay. For trying grouping again after a model or rule change.
    public func regroupPeople() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE assetFace SET personID = NULL WHERE pinned = 0 AND personID IN (SELECT id FROM person WHERE name IS NULL)")
            try Self.forgetEmptyPeople(db)
        }
    }
}
