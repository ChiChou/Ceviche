import XCTest
import GRDB
@testable import CevicheCore

/// A replica written by a newer build: iCloud catalogs rebuild theirs from the mirror, local catalogs refuse to open.
final class CatalogSupersededTests: XCTestCase {
    private func markSuperseded(_ root: URL) throws {
        let queue = try DatabaseQueue(path: root.appendingPathComponent("catalog.sqlite").path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('catalog-v99-future')") }
    }
    func testSupersededCloudReplicaIsSetAsideAndRebuiltFromTheMirror() async throws {
        let (directory, url) = try CloudSyncTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try CloudSyncTests().replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        _ = await syncA.sync(); _ = await syncB.sync()
        let synced = try await b.count(filter: CatalogFilter()); XCTAssertEqual(synced, 1)
        await syncA.stop(); await syncB.stop()
        try markSuperseded(b.root)
        let reopened = try CatalogStore(root: b.root)
        XCTAssertEqual(reopened.manifest.id, a.manifest.id)
        let emptied = try await reopened.count(filter: CatalogFilter()); XCTAssertEqual(emptied, 0)
        let backups = try FileManager.default.contentsOfDirectory(atPath: b.root.appendingPathComponent("MigrationBackups").path)
        XCTAssertTrue(backups.contains { $0.hasSuffix("-superseded.sqlite") }, "\(backups)")
        let sync = try CloudSyncEngine(store: reopened, mirrorURL: directory.appendingPathComponent("mirror.store"), cloudContainer: nil)
        _ = await sync.sync()
        let rebuilt = try await reopened.count(filter: CatalogFilter()); XCTAssertEqual(rebuilt, 1)
        let received = try await reopened.asset(asset.id); XCTAssertEqual(received.filename, asset.filename)
        await sync.stop()
    }
    func testSupersededLocalCatalogRefusesUnlessOpenedReadOnly() async throws {
        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        do {
            let store = try CatalogStore(root: root, manifest: CatalogManifest(name: "Local", kind: .local))
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        try markSuperseded(root)
        XCTAssertThrowsError(try CatalogStore(root: root)) { XCTAssertEqual($0 as? CatalogOpenError, .newer) }
        let database = root.appendingPathComponent("catalog.sqlite")
        let before = try Data(contentsOf: database)
        do {
            let store = try CatalogStore(root: root, readOnly: true)
            XCTAssertTrue(store.isReadOnly)
            let count = try await store.count(filter: CatalogFilter()); XCTAssertEqual(count, 1)
            let assets = try await store.assets(); let id = try XCTUnwrap(assets.first?.id)
            do { _ = try await store.updateQuickMetadata(assetIDs: [id], rating: 3); XCTFail("wrote to a read-only catalog") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("MigrationBackups").path))
    }
    /// A database that fails to open as usual is reported with its own reason, and still opens read-only.
    func testDamagedCatalogOpensReadOnly() async throws {
        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        do {
            let store = try CatalogStore(root: root, manifest: CatalogManifest(name: "Local", kind: .local))
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        // An upgrade that can't run: the latest migration's index is already there under its name.
        let last = try XCTUnwrap(CatalogStore.migrator.migrations.last)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("catalog.sqlite").path)
        try await queue.write { try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [last]) }
        try queue.close()
        XCTAssertThrowsError(try CatalogStore(root: root)) { error in
            guard case .unreadable = error as? CatalogOpenError else { return XCTFail("\(error)") }
        }
        let store = try CatalogStore(root: root, readOnly: true)
        XCTAssertTrue(store.isReadOnly)
        let count = try await store.count(filter: CatalogFilter()); XCTAssertEqual(count, 1)
    }
    /// A catalog a release made opens in every later build: its migrations stay where they are.
    func testReleasedMigrationsAreKeptInOrder() {
        XCTAssertEqual(Array(CatalogStore.migrator.migrations.prefix(CatalogStore.releasedMigrations.count)), CatalogStore.releasedMigrations)
        XCTAssertTrue(CatalogStore.retiredMigrations.isDisjoint(with: CatalogStore.releasedMigrations))
    }
    /// A build with a newer schema upgrades an older catalog in place, keeping a copy of the database as it was.
    func testUpgradingAnOlderCatalogKeepsACopyAndItsPhotos() async throws {
        guard CatalogStore.migrator.migrations.count > 1 else { throw XCTSkip("No migration after the base schema yet") }
        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        do {
            let store = try CatalogStore(root: root, manifest: CatalogManifest(name: "Local", kind: .local))
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        // As an earlier build left it: without the latest migration, whose tables and columns go with it.
        let last = try XCTUnwrap(CatalogStore.migrator.migrations.last)
        let previous = try XCTUnwrap(CatalogStore.migrator.migrations.dropLast().last)
        let earlier = try DatabaseQueue()
        try CatalogStore.migrator.migrate(earlier, upTo: previous)
        func columns(_ db: Database, _ table: String) throws -> Set<String> {
            Set(try Row.fetchAll(db, sql: "PRAGMA table_xinfo(\(table.quotedDatabaseIdentifier))").map { $0["name"] as String })
        }
        let (tables, indexes, earlierColumns) = try await earlier.read { db in
            let tables = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                .map { (row: Row) -> (String, String) in (row["name"], row["sql"]) })
            return (tables,
                    Dictionary(grouping: try Row.fetchAll(db, sql: "SELECT tbl_name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
                        .map { (row: Row) -> (String, String) in (row["tbl_name"], row["sql"]) }, by: \.0).mapValues { $0.map(\.1) },
                    try tables.keys.reduce(into: [String: Set<String>]()) { $0[$1] = try columns(db, $1) })
        }
        let queue = try DatabaseQueue(path: root.appendingPathComponent("catalog.sqlite").path)
        try await queue.write { db in
            // Whatever the latest migration added or changed goes back to how the earlier one left it. A table that only
            // gained columns loses them and keeps its rows (the photo counted below); any other is made again.
            let now = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
                .map { (row: Row) -> (String, String) in (row["name"], row["sql"]) }
            let undone = now.filter { tables[$0.0] != $0.1 }
            XCTAssertFalse(undone.isEmpty, "The latest migration changes a table to take back")
            for (table, _) in undone {
                let current = try columns(db, table)
                if let old = earlierColumns[table], old.isSubset(of: current), old != current {
                    for column in current.subtracting(old) { try db.execute(sql: "ALTER TABLE \(table.quotedDatabaseIdentifier) DROP COLUMN \(column.quotedDatabaseIdentifier)") }
                    continue
                }
                try db.execute(sql: "DROP TABLE \(table.quotedDatabaseIdentifier)")
                guard let earlier = tables[table] else { continue }
                try db.execute(sql: earlier)
                for index in indexes[table] ?? [] { try db.execute(sql: index) }
            }
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: [last])
        }
        try queue.close()
        let reopened = try CatalogStore(root: root)
        let count = try await reopened.count(filter: CatalogFilter()); XCTAssertEqual(count, 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("MigrationBackups").path)
        XCTAssertEqual(backups, [CatalogStore.upgradeBackupName(previous)])
        // The copy is the catalog as the earlier build left it.
        let copy = try DatabaseQueue(path: root.appendingPathComponent("MigrationBackups/\(backups[0])").path)
        let kept = try await copy.read { (try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations"), try Int.fetchOne($0, sql: "SELECT count(*) FROM asset")) }
        XCTAssertEqual(kept.0.last, previous); XCTAssertEqual(kept.1, 1)
    }
    func testCatalogFromTheRetiredSchemaIsRefusedWithItsOwnReason() async throws {
        let (directory, _) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CatalogManifest(name: "Old", kind: .local).save(root: root)
        let queue = try DatabaseQueue(path: root.appendingPathComponent("catalog.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY); CREATE TABLE asset (id TEXT PRIMARY KEY)")
            for identifier in CatalogStore.retiredMigrations { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [identifier]) }
        }
        try queue.close()
        XCTAssertThrowsError(try CatalogStore(root: root)) { XCTAssertEqual($0 as? CatalogOpenError, .earlier) }
        XCTAssertThrowsError(try CatalogStore(root: root, readOnly: true)) { XCTAssertEqual($0 as? CatalogOpenError, .earlier) }
    }
}
