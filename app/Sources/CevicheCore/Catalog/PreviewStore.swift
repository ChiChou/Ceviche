import Foundation
import GRDB

/// One stored preview: a photo's thumbnail bytes, and the day it was last shown. `tier` is always 0, the thumbnail.
struct CatalogPreview: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "preview"
    var id: Int64?
    var assetID: String
    var tier: Int
    var bytes: Int
    var lastSeenDay: Int
    var data: Data
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum Columns {
        static let id = Column(CodingKeys.id), assetID = Column(CodingKeys.assetID), tier = Column(CodingKeys.tier)
        static let bytes = Column(CodingKeys.bytes), lastSeenDay = Column(CodingKeys.lastSeenDay), data = Column(CodingKeys.data)
    }
}

/// Derived images for one catalog, in `previews.sqlite` beside the catalog database: one thumbnail per photo and the
/// Faces wall's tiles,
/// replaced in place so the file never collects stale copies. All I/O runs on GRDB's own queues; the
/// actor only guards the list of photos shown since the last flush.
public actor PreviewStore {
    private typealias Columns = CatalogPreview.Columns
    public static let filename = "previews.sqlite"
    public nonisolated let url: URL
    private let pool: DatabasePool
    private var seen: Set<String> = []

    public init(root: URL) throws {
        url = root.appendingPathComponent(Self.filename)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // Both take effect only on a new file: a thumbnail spans a few pages, and freed pages can be given back.
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA page_size = 16384; PRAGMA auto_vacuum = INCREMENTAL") }
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("previews-v1") { db in
            try db.execute(sql: """
                CREATE TABLE preview (
                    id INTEGER PRIMARY KEY,
                    assetID TEXT NOT NULL,
                    tier INTEGER NOT NULL,
                    bytes INTEGER NOT NULL,
                    lastSeenDay INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    UNIQUE (assetID, tier));
                CREATE INDEX preview_lru ON preview (tier, lastSeenDay);
                """)
        }
        // The Faces wall's tiles: cut from the original once, by background analysis, so the wall never reads one.
        migrator.registerMigration("previews-v2-face-tiles") { db in
            try db.execute(sql: """
                CREATE TABLE faceTile (
                    assetID TEXT NOT NULL,
                    idx INTEGER NOT NULL,
                    data BLOB NOT NULL,
                    PRIMARY KEY (assetID, idx)) WITHOUT ROWID;
                """)
        }
        try migrator.migrate(pool)
    }
    static var today: Int { Int(Date().timeIntervalSince1970 / 86_400) }

    /// Stores or replaces one preview. The old blob's pages are reused by the new one.
    public func install(_ data: Data, assetID: String) async throws {
        try await pool.write { db in
            var preview = CatalogPreview(assetID: assetID, tier: 0, bytes: data.count, lastSeenDay: Self.today, data: data)
            _ = try preview.upsertAndFetch(db, onConflict: ["assetID", "tier"])
        }
    }
    /// The stored bytes, and a note that the photo was shown, for the eviction order.
    public func data(assetID: String) async throws -> Data? {
        seen.insert(assetID)
        return try await pool.read { db in
            try CatalogPreview.filter(Columns.assetID == assetID).select(Columns.data, as: Data.self).fetchOne(db)
        }
    }
    public func remove(assetIDs: [String]) async throws {
        guard !assetIDs.isEmpty else { return }
        try await pool.write { db in
            for chunk in Self.chunks(assetIDs) {
                try CatalogPreview.filter(chunk.contains(Columns.assetID)).deleteAll(db)
                let list = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
                try db.execute(sql: "DELETE FROM faceTile WHERE assetID IN (SELECT value FROM json_each(?))", arguments: [list])
            }
        }
    }
    /// Replaces a photo's face tiles, keyed by the face's place in the photo (`CatalogFaceEntry.index`).
    public func installFaceTiles(_ tiles: [Int: Data], assetID: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM faceTile WHERE assetID = ?", arguments: [assetID])
            for (index, data) in tiles { try db.execute(sql: "INSERT INTO faceTile(assetID, idx, data) VALUES (?, ?, ?)", arguments: [assetID, index, data]) }
        }
    }
    public func faceTile(assetID: String, index: Int) async throws -> Data? {
        try await pool.read { try Data.fetchOne($0, sql: "SELECT data FROM faceTile WHERE assetID = ? AND idx = ?", arguments: [assetID, index]) }
    }
    /// Writes the day each shown photo was last seen: at most one update per photo per day, none while browsing.
    public func flushSeen() async throws {
        guard !seen.isEmpty else { return }
        let ids = Array(seen), day = Self.today
        seen = []
        try await pool.write { db in
            for chunk in Self.chunks(ids) {
                try CatalogPreview.filter(Columns.lastSeenDay < day && chunk.contains(Columns.assetID)).updateAll(db, Columns.lastSeenDay.set(to: day))
            }
        }
    }
    /// Drops the previews of photos not in `keeping` (asked after the stored list is taken, so a preview installed
    /// meanwhile is kept), then the least recently shown thumbnails until they fit `budget` bytes, and returns
    /// the pages to the file. The photos whose thumbnail went are returned so the catalog can mark them for regeneration.
    @discardableResult
    public func sweep(budget: Int? = nil, keeping: () async throws -> Set<String>) async throws -> [String] {
        try await flushSeen()
        let stored = try await pool.read { db in
            Set(try CatalogPreview.select(Columns.assetID, as: String.self).distinct().fetchAll(db))
                .union(try String.fetchAll(db, sql: "SELECT DISTINCT assetID FROM faceTile"))
        }
        let keeping = try await keeping()
        try await remove(assetIDs: stored.filter { !keeping.contains($0) })
        var evicted: [String] = []
        if let budget {
            var total = try await bytes()
            while total > budget {
                // Short transactions, so a thumbnail install never waits long behind a large first sweep.
                let over = total - budget
                let batch = try await pool.write { db -> [(assetID: String, bytes: Int)] in
                    var remaining = over, ids: [Int64] = [], taken: [(assetID: String, bytes: Int)] = []
                    // `tier = 0` (every row) lets the walk use the `preview_lru` index.
                    let oldest = CatalogPreview.filter(Columns.tier == 0).order(Columns.lastSeenDay, Columns.id).limit(200)
                    for row in try Row.fetchAll(db, oldest.select(Columns.id, Columns.assetID, Columns.bytes)) {
                        guard remaining > 0 else { break }
                        let bytes: Int = row["bytes"]
                        remaining -= bytes; ids.append(row["id"]); taken.append((row["assetID"], bytes))
                    }
                    try CatalogPreview.deleteAll(db, keys: ids)
                    return taken
                }
                guard !batch.isEmpty else { break }
                total -= batch.reduce(0) { $0 + $1.bytes }
                evicted += batch.map(\.assetID)
            }
        }
        try await pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
        return evicted
    }
    public func bytes() async throws -> Int {
        try await pool.read { try CatalogPreview.select(sum(Columns.bytes), as: Int.self).fetchOne($0) ?? 0 }
    }
    public func count() async throws -> Int {
        try await pool.read { try CatalogPreview.fetchCount($0) }
    }
    /// A consistent copy of the database at `destination`.
    public nonisolated func backup(to destination: URL) throws {
        try pool.backup(to: DatabaseQueue(path: destination.path))
    }
    private static func chunks<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: 500).map { Array(values[$0..<min($0 + 500, values.count)]) }
    }
}
