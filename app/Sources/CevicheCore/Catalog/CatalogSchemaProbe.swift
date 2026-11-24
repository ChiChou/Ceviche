import Foundation
import GRDB

/// What opening a catalog would do to its schema, read without writing to it, for an app that asks before it upgrades
/// a catalog it did not make (the touch app opening a Mac's catalog from Files). `CatalogStore(root:)` itself is
/// unchanged: it upgrades as it always has.
public enum CatalogSchemaState: Equatable, Sendable {
    /// At this build's schema, or a new, empty database.
    case current
    /// From an earlier released schema: opening it migrates it, after a copy in MigrationBackups.
    case upgrade
    /// From before the current schema, or written by a newer build: `CatalogStore` refuses it.
    case refused(CatalogOpenError)

    /// The state of the catalog database at `root`, opened read-only.
    public static func probe(root: URL) throws -> CatalogSchemaState {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabasePool(path: root.appendingPathComponent("catalog.sqlite").path, configuration: configuration)
        defer { try? database.close() }
        let migrations = CatalogStore.migrator
        return try database.read { db in
            let applied = try migrations.appliedIdentifiers(db)
            if !CatalogStore.retiredMigrations.isDisjoint(with: applied) { return .refused(.earlier) }
            if try migrations.hasBeenSuperseded(db) { return .refused(.newer) }
            if try applied.isEmpty || migrations.hasCompletedMigrations(db) { return .current }
            return .upgrade
        }
    }
}
