import Foundation
import CoreImage
import GRDB
import Synchronization

extension DatabasePool {
    /// The synchronous forms under their own names, since an async caller would otherwise get the async overloads.
    func writeSync<T>(_ updates: (Database) throws -> T) throws -> T { try write(updates) }
    func readSync<T>(_ value: (Database) throws -> T) throws -> T { try read(value) }
}

/// One local filesystem catalog. Database work is serialized independently of GPU work.
public actor CatalogStore {
    typealias Columns = CatalogAsset.Columns
    public nonisolated let root: URL
    /// Name, kind and identity; iCloud catalogs are matched across Macs by `manifest.id`.
    public nonisolated var manifest: CatalogManifest { manifestState.withLock { $0 } }
    private nonisolated let manifestState: Mutex<CatalogManifest>
    /// Thumbnails and other derived images, in their own database beside the catalog.
    public nonisolated let previews: PreviewStore
    /// Made on first use by `thumbnails`.
    nonisolated let thumbnailReactor = Mutex<ThumbnailReactor?>(nil)
    /// Where LUTs, camera profiles and ICC profiles that developments use are kept: for this catalog's kind
    /// (`ResourceStorage.scoped(to:)`), so a local catalog's looks stay on this Mac.
    public nonisolated let resources: ResourceStorage
    /// Where copied originals live. An iCloud catalog in a build with iCloud Drive keeps them in the app's iCloud Drive
    /// folder, under `Catalogs/<catalog ID>` beside the look library, so every Mac reads the same files, only downloads
    /// the ones it opens, and Finder can show them; any other catalog keeps them in its own folder.
    public nonisolated let originalsRoot: URL
    let database: DatabasePool
    /// Set when the catalog is shown as it is, at the person's choice: nothing is written to it.
    public nonisolated let isReadOnly: Bool
    /// `manifest` describes a catalog being created; an existing catalog keeps its own manifest. `originals` overrides
    /// where an iCloud catalog's copied originals go (tests). A local catalog that can't be opened as usual throws
    /// `CatalogOpenError`; unless it is from before the current schema, `readOnly` then shows it without writing to it.
    public init(root: URL, existingOnly: Bool = false, manifest requested: CatalogManifest? = nil, resources: ResourceStorage = .shared, originals: URL? = nil,
                readOnly: Bool = false) throws {
        self.root = root.standardizedFileURL
        let fm = FileManager.default
        var loaded: CatalogManifest
        if existingOnly {
            guard fm.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path), let existing = try CatalogManifest.load(root: root) else {
                throw EditorError.invalidDocument(L10n.tr("Catalog database does not exist."))
            }
            loaded = existing
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if let existing = try CatalogManifest.load(root: root) { loaded = existing }
            else {
                loaded = requested ?? CatalogManifest.inferred(root: root, defaultRoot: CatalogManifest.defaultRoot)
                try loaded.save(root: root)
            }
        }
        let drive = loaded.kind == .cloud ? resources.folder.flatMap { $0.ubiquitous ? $0.root : nil } : nil
        let shared = loaded.kind != .cloud ? nil : originals ?? drive.map { $0.appendingPathComponent("Catalogs/\(loaded.id)", isDirectory: true) }
            ?? loaded.originals.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let shared, loaded.originals != shared.path, !existingOnly { loaded.originals = shared.path; try loaded.save(root: root) }
        manifestState = Mutex(loaded)
        self.resources = resources.scoped(to: loaded.kind)
        originalsRoot = shared ?? self.root
        if let shared { CatalogImporter.setOriginalsRoot(shared, for: self.root) }
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            // Takes effect only in a new, empty catalog, before its first table.
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
        }
        let databaseURL = root.appendingPathComponent("catalog.sqlite")
        let existed = fm.fileExists(atPath: databaseURL.path)
        previews = try Self.openPreviews(root: self.root)
        let migrations = Self.migrator
        func retired(_ database: DatabasePool) throws -> Bool {
            try database.read { !Self.retiredMigrations.isDisjoint(with: try migrations.appliedIdentifiers($0)) }
        }
        // Shown as it is, schema and all; a catalog from before the current schema can't be read even so.
        if readOnly, loaded.kind != .cloud {
            var reading = configuration; reading.readonly = true
            let database = try DatabasePool(path: databaseURL.path, configuration: reading)
            if try retired(database) { throw CatalogOpenError.earlier }
            self.database = database; isReadOnly = true
            return
        }
        isReadOnly = false
        let database: DatabasePool
        do {
            var opened = try DatabasePool(path: databaseURL.path, configuration: configuration)
            // Newer schemas, and the retired ones from before `schemaVersion`, are never upgraded. An iCloud catalog's
            // replica is this Mac's cache of the cloud mirror, so one written by a newer (or since-abandoned) build is
            // set aside under MigrationBackups and rebuilt from CloudMirror.store by the next sync; a local catalog has
            // no copy to rebuild from.
            if try opened.read({ try migrations.hasBeenSuperseded($0) }) {
                guard !existingOnly, loaded.kind == .cloud else { throw try retired(opened) ? CatalogOpenError.earlier : CatalogOpenError.newer }
                try opened.close()
                let backups = root.appendingPathComponent("MigrationBackups")
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let name = UUID().uuidString + "-superseded"
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: databaseURL.path + suffix)
                    if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: backups.appendingPathComponent(name + ".sqlite" + suffix)) }
                }
                opened = try DatabasePool(path: databaseURL.path, configuration: configuration)
            }
            if existingOnly {
                guard try opened.read({ try migrations.hasCompletedMigrations($0) }) else { throw EditorError.invalidDocument(L10n.tr("Open this catalog in Ceviche to update its schema before indexing.")) }
            } else {
                try Self.backupBeforeUpgrade(opened, migrations: migrations, root: root)
                try migrations.migrate(opened)
            }
            database = opened
        } catch let error as CatalogOpenError {
            throw error
        } catch where existed && !existingOnly && loaded.kind != .cloud {
            // A damaged database or a failed upgrade: what is in it may still be readable.
            throw CatalogOpenError.unreadable(error.localizedDescription)
        }
        self.database = database
    }
    /// Thumbnails are a cache: a previews database that can't be opened is started again rather than keeping the
    /// catalog closed.
    static func openPreviews(root: URL) throws -> PreviewStore {
        do { return try PreviewStore(root: root) } catch {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: root.appendingPathComponent(PreviewStore.filename).path + suffix) }
            return try PreviewStore(root: root)
        }
    }
    /// An upgrade never costs a catalog: before a newer build changes the schema of a catalog that has photos' worth of
    /// history in it, the database as it was is copied into MigrationBackups, named for the schema it was at
    /// (`catalog.catalog-2026-11-22.sqlite`). A later try from the same schema replaces that copy; the copies of the
    /// two latest schemas are kept.
    static func backupBeforeUpgrade(_ database: DatabasePool, migrations: DatabaseMigrator, root: URL) throws {
        let (applied, done) = try database.read { (try migrations.appliedIdentifiers($0), try migrations.hasCompletedMigrations($0)) }
        guard let version = migrations.migrations.last(where: applied.contains), !done else { return }
        let fm = FileManager.default, backups = root.appendingPathComponent("MigrationBackups")
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        // Written beside its name first, so an interrupted copy never replaces a complete one.
        let copy = backups.appendingPathComponent(upgradeBackupName(version))
        let partial = backups.appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try database.backup(to: DatabaseQueue(path: partial.path))
            _ = try fm.replaceItemAt(copy, withItemAt: partial)
        } catch { try? fm.removeItem(at: partial); throw error }
        let dated = ((try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(upgradeBackupPrefix) && $0.pathExtension == "sqlite" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(2) { try? fm.removeItem(at: url) }
    }
    static let upgradeBackupPrefix = "catalog."
    static func upgradeBackupName(_ version: String) -> String { "\(upgradeBackupPrefix)\(version).sqlite" }
    /// The migrations of every released build, in order. A catalog made by any release opens in every later one, so
    /// these are never renamed, removed or reordered: a schema change is a new migration after the last.
    static let releasedMigrations = [schemaVersion]
    /// The catalog schema. Catalogs from before the first public release (`retiredMigrations`, the tester previews
    /// included) are not upgraded: an iCloud catalog is rebuilt from its cloud copy, and a local one has to be made
    /// again. From the first release on, the base and every migration stay (`releasedMigrations`), so no released
    /// catalog is ever turned away as too old.
    static var migrator: DatabaseMigrator {
        var migrations = DatabaseMigrator()
        migrations.registerMigration(schemaVersion) { db in try Self.createSchema(db) }
        migrations.registerMigration("catalog-2026-11-27-sync-base") { db in try Self.createSyncBase(db) }
        return migrations
    }
    static let schemaVersion = "catalog-2026-11-22"
    /// Not a `CatalogAsset` property: only analysis writes it, and record saves leave it as it is.
    static let faceCountColumn = "faceCount"
    /// `sourcePath` up to and including its last separator: trimming from the right every character the path has other
    /// than "/" stops at that separator.
    static let folderSQL = "rtrim(sourcePath, replace(sourcePath, '/', ''))"
    /// The migrations of the schemas this one replaced.
    static let retiredMigrations: Set<String> = ["catalog-v1", "catalog-v2-stacks", "catalog-v3-culling", "catalog-v4-search", "catalog-v5-exif-search",
                                                 "catalog-2026-11", "catalog-2026-11-label", "catalog-2026-11-archive",
                                                 "catalog-2026-11-06", "catalog-2026-11-11-folder", "catalog-2026-11-20-faces", "catalog-2026-11-20-hdr",
                                                 "catalog-2026-11-20-face-boxes", "catalog-2026-11-20-prints", "catalog-2026-11-22-people",
                                                 "catalog-2026-11-22-location-source"]
    static func createSchema(_ db: Database) throws {
        try createAssetTables(db)
        // History and Snapshots (see `RevisionPayload` for what a payload holds).
        try db.create(table: "revision") { t in
            t.primaryKey("id", .text)
            t.column("assetID", .text).notNull().references("asset", onDelete: .cascade).indexed()
            t.column("kind", .text).notNull()
            t.column("summary", .text).notNull()
            t.column("payload", .blob).notNull()
            t.column("thumbnail", .blob)
            t.column("milestone", .boolean).notNull().defaults(to: false)
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "snapshot") { t in
            t.primaryKey("id", .text)
            t.column("assetID", .text).notNull().references("asset", onDelete: .cascade).indexed()
            t.column("name", .text).notNull()
            t.column("payload", .blob).notNull()
            t.column("thumbnail", .blob)
            t.column("createdAt", .datetime).notNull()
        }
        try Self.createBlobTables(db)
        // Background tagging queue and its on/off switch.
        try db.create(table: "analysisJob") { t in
            t.primaryKey("assetID", .text).references("asset", onDelete: .cascade)
            t.column("version", .text).notNull().defaults(to: "")
            t.column("state", .text).notNull().defaults(to: "pending")
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("priority", .integer).notNull().defaults(to: 0)
            t.column("nextAttempt", .double).notNull().defaults(to: 0)
            t.column("owner", .text)
            t.column("leaseUntil", .double)
            t.column("lastError", .text)
        }
        try db.create(index: "analysis_ready", on: "analysisJob", columns: ["state", "nextAttempt", "priority"])
        try db.create(table: "analysisControl") { t in
            t.primaryKey("id", .integer)
            t.column("enabled", .boolean).notNull()
            t.column("generation", .integer).notNull().defaults(to: 0)
        }
        try db.execute(sql: "INSERT INTO analysisControl(id, enabled) VALUES (1, 1)")
        // Albums: when each album and each photo in it last changed, and when that last matched iCloud.
        try db.create(table: "album") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime)
            t.column("syncedAt", .datetime)
        }
        try db.create(table: "albumAsset") { t in
            t.column("albumID", .text).notNull().references("album", onDelete: .cascade)
            t.column("assetID", .text).notNull().references("asset", onDelete: .cascade).indexed()
            t.column("position", .integer).notNull()
            t.column("updatedAt", .datetime)
            t.column("syncedAt", .datetime)
            t.primaryKey(["albumID", "assetID"])
        }
        // iCloud: deletions to push, and photos removed from the library that a card import should not preselect.
        try db.create(table: "syncTombstone") { t in
            t.primaryKey("id", .text)
            t.column("kind", .text).notNull()
            t.column("deletedAt", .datetime).notNull()
        }
        try db.create(table: "deletedImport") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("importPath", .text).notNull()
            t.column("origin", .text).notNull()
            t.column("filename", .text).notNull()
            t.column("fileSize", .integer)
            t.column("captureTime", .text)
            t.column("deletedAt", .datetime).notNull().indexed()
        }
        try createCullingTable(db)
        try createTagIndex(db)
        try createPlaceTables(db)
        try createTextIndex(db)
        try db.create(index: "asset_folder", on: "asset", columns: ["folder", "trashedAt", "captureDay", "captureTime", "id"])
        // Where each face is (`assetFace`), each photo's Vision feature print (`assetPrint`), and People: faces grouped
        // by who they are, each face's embedding beside its box.
        try createFaceTable(db)
        try createPrintTable(db)
        try createPeopleTables(db)
    }
    /// Renames the catalog in `catalog.json`. `at` is when the name changed, here or on another Mac.
    public nonisolated func rename(to name: String, at date: Date = Date()) throws {
        try manifestState.withLock { manifest in
            var renamed = manifest
            renamed.name = name; renamed.renamedAt = date
            try renamed.save(root: root)
            manifest = renamed
        }
    }
    /// A LIKE pattern that matches `text` literally, with `\\` as the escape.
    static func likePattern(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
    /// Photos matching `filter` in display order: a page of `limit` from `offset`, or every match when `limit` is nil.
    public func assets(filter: CatalogFilter = CatalogFilter(), limit: Int? = nil, offset: Int = 0) throws -> [CatalogAsset] {
        try database.read { db in
            // The page's IDs first, then its rows: sorting only IDs keeps a broad search from carrying every
            // matching photo's metadata through the sort.
            var page = Self.query(filter).select(Columns.id, as: String.self).order(Self.ordering(filter))
            if let limit { page = page.limit(limit, offset: offset) }
            let ids = try page.fetchAll(db)
            // One JSON argument, since a page can hold more IDs than SQLite takes parameters.
            let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            let rows = Dictionary(uniqueKeysWithValues: try CatalogAsset.filter(sql: "id IN (SELECT value FROM json_each(?))", arguments: [list])
                .fetchAll(db).map { ($0.id, $0) })
            return ids.compactMap { rows[$0] }
        }
    }
    /// Which of `ids` match `filter`, wherever they fall in its order, so a selection outlives the page loaded into the grid.
    public func matching(_ ids: [String], filter: CatalogFilter) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try database.read { db in
            Set(try Self.query(filter).filter(sql: "id IN (SELECT value FROM json_each(?))", arguments: [list])
                .select(Columns.id, as: String.self).fetchAll(db))
        }
    }
    /// Number of photos matching a filter, independent of the page loaded into the grid.
    public func count(filter: CatalogFilter) throws -> Int {
        try database.read { try Self.query(filter).fetchCount($0) }
    }
    nonisolated static func ordering(_ filter: CatalogFilter) -> [SQLOrderingTerm] {
        // A found set keeps the order it was found in: nearest first, or copies side by side.
        if let set = filter.photoSet { return [SQL(sql: "(SELECT key FROM json_each(?) WHERE value = asset.id)", arguments: [set.json])] }
        // Every term runs the same way, so one index scan, forwards or backwards, gives the order without a sort.
        func direction(_ column: Column) -> SQLOrderingTerm { filter.ascending ? column.asc : column.desc }
        switch filter.sort {
        case .captureDate: return [direction(Columns.captureDay), direction(Columns.captureTime), direction(Columns.id)]
        case .filename: return [filter.ascending ? Columns.filename.collating(.localizedCaseInsensitiveCompare).asc : Columns.filename.collating(.localizedCaseInsensitiveCompare).desc, direction(Columns.id)]
        case .importDate: return [direction(Columns.importedAt), direction(Columns.id)]
        case .rating: return [direction(Columns.rating), direction(Columns.captureDay), direction(Columns.id)]
        // Unedited photos follow the edited ones either way.
        case .edited: return [filter.ascending ? Columns.lastEditedAt.ascNullsLast : Columns.lastEditedAt.desc, direction(Columns.id)]
        }
    }
    nonisolated static func query(_ filter: CatalogFilter) -> QueryInterfaceRequest<CatalogAsset> {
        var query = CatalogAsset.all().filter(Columns.area(filter.area))
        query = query.filter(Columns.rating >= filter.minimumRating)
        if filter.geotagged {
            query = query.filter(Columns.latitude != nil && Columns.longitude != nil)
        }
        if let located = filter.hasLocation {
            let complete = Columns.latitude != nil && Columns.longitude != nil
            query = query.filter(located ? complete : !complete)
        }
        if let tags = filter.tags { query = Self.filter(query, tags: tags) }
        if filter.withFaces { query = query.filter(Column(faceCountColumn) > 0) }
        if let area = filter.mapArea {
            query = query.filter(Columns.latitude >= area.south && Columns.latitude <= area.north && Columns.longitude >= area.west && Columns.longitude <= area.east)
        }
        if let person = filter.personID { query = query.filter(sql: "id IN (SELECT assetID FROM assetFace WHERE personID = ?)", arguments: [person]) }
        if let albumID = filter.albumID {
            query = query.filter(sql: "id IN (SELECT assetID FROM albumAsset WHERE albumID = ?)", arguments: [albumID])
        }
        if let set = filter.photoSet { query = query.filter(sql: "id IN (SELECT value FROM json_each(?))", arguments: [set.json]) }
        if let folder = filter.folder { query = query.filter(Self.folderCondition(folder, deep: filter.subfolders)) }
        else if filter.nothing { query = query.filter(sql: "0") }
        if let day = filter.importDay {
            query = query.filter(sql: "date(importedAt, 'localtime') = ?", arguments: [day])
        }
        if let batchID = filter.importBatchID { query = query.filter(Columns.importBatchID == batchID) }
        if filter.recentEdits { query = query.filter(Columns.lastEditedAt != nil) }
        if let review = filter.review { query = query.filter(Columns.review == review) }
        if let label = filter.label { query = query.filter(Columns.label == label.rawValue) }
        if let kind = filter.kind { query = query.filter(Columns.kind == kind) }
        if let range = filter.focalLength {
            query = query.filter(sql: "(\(CatalogFocalFilter.effectiveFocalSQL)) >= ? AND (\(CatalogFocalFilter.effectiveFocalSQL)) < ?", arguments: [Double(range.lowerBound) - 0.5, Double(range.upperBound) + 0.5])
        }
        for scale in CatalogExposureScale.allCases {
            guard let stops = filter[scale] else { continue }
            let bounds = scale.bounds(stops), column = Column(scale.column)
            query = query.filter(column >= bounds.lowerBound && column < bounds.upperBound)
        }
        if let flash = filter.flash { query = query.filter(Column("flashFired") == flash) }
        if let faces = filter.faces { query = query.filter(faces.condition) }
        if let orientation = filter.orientation {
            let aspect = Column("aspect"), tolerance = CatalogOrientation.tolerance
            switch orientation {
            case .landscape: query = query.filter(aspect >= tolerance)
            case .portrait: query = query.filter(aspect <= 1 / tolerance)
            case .square: query = query.filter(aspect > 1 / tolerance && aspect < tolerance)
            }
        }
        if let day = filter.captureDay {
            // A year or month is the range of ISO days that start with it: "-" and "." bracket the day's own
            // separator, and a range scan uses the browse index where a LIKE prefix would not.
            query = day.isEmpty || day.count == 10 ? query.filter(Columns.captureDay == day)
                : query.filter(Columns.captureDay >= day + "-" && Columns.captureDay < day + ".")
        }
        for term in Self.searchTerms(filter.search) {
            if let condition = Self.searchCondition(term) { query = query.filter(condition) }
        }
        // A collapsed group shows only its cover. Where the cover itself doesn't match (filtered out, or in the
        // Trash), the group's matching photos show one by one rather than not at all.
        // A found set shows its photos whether or not they head a group: a copy is often the one grouped under another.
        if filter.area == .library && !filter.everyGroupedPhoto && filter.photoSet == nil {
            let shown = query.select(Columns.id)
            query = query.filter(Columns.stackID == nil || Columns.stackID == Columns.id || filter.expandedStacks.contains(Columns.stackID) || !shown.contains(Columns.stackID))
        }
        return query
    }
    /// `tag` in `assetTag` compares without case, as the column is declared.
    nonisolated static func filter(_ query: QueryInterfaceRequest<CatalogAsset>, tags: CatalogTagFilter) -> QueryInterfaceRequest<CatalogAsset> {
        func clean(_ list: [String]) -> [String] { list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let sources = String(decoding: (try? JSONEncoder().encode(tags.sources.map(\.rawValue))) ?? Data("[]".utf8), as: UTF8.self)
        func having(_ list: [String]) -> SQLExpression {
            let json = String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
            return SQL("id IN (SELECT assetID FROM assetTag WHERE tag IN (SELECT value FROM json_each(\(json))) AND source IN (SELECT value FROM json_each(\(sources))))").sqlExpression
        }
        var query = query
        for tag in clean(tags.all) { query = query.filter(having([tag])) }
        if !clean(tags.any).isEmpty { query = query.filter(having(clean(tags.any))) }
        if !clean(tags.none).isEmpty { query = query.filter(!having(clean(tags.none))) }
        return query
    }
    public func groups(area: CatalogArea = .library) throws -> CatalogGroups {
        try database.read { db in
            let scope = CatalogAsset.filter(Columns.area(area))
            // Counting rowids lets SQLite answer from the browse index alone.
            let days = try Row.fetchAll(db, scope.select(Columns.captureDay, GRDB.count(Column.rowID).forKey("count")).group(Columns.captureDay).order(Columns.captureDay.desc))
            return CatalogGroups(dates: days.map { $0["captureDay"] }, dayCounts: Dictionary(uniqueKeysWithValues: days.map { ($0["captureDay"], $0["count"]) }),
                          kinds: try scope.select(Columns.kind, as: String.self).distinct().order(Columns.kind).fetchAll(db),
                          total: try CatalogAsset.filter(Columns.area(.library)).fetchCount(db),
                          trash: try CatalogAsset.filter(Columns.area(.trash)).fetchCount(db),
                          archive: try CatalogAsset.filter(Columns.area(.archive)).fetchCount(db))
        }
    }
    /// The records of `ids` that are still in the catalog, in no particular order.
    public func assets(ids: [String]) throws -> [CatalogAsset] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            try stride(from: 0, to: ids.count, by: 500).flatMap { try CatalogAsset.fetchAll(db, keys: Array(ids[$0..<min($0 + 500, ids.count)])) }
        }
    }
    public func asset(_ id: String) throws -> CatalogAsset {
        try database.read { db in
            guard let asset = try CatalogAsset.fetchOne(db, key: id) else { throw EditorError.invalidDocument(L10n.tr("Photo is no longer in this catalog.")) }
            return asset
        }
    }
    /// The photo's development and the XMP it came with.
    public func development(_ assetID: String) throws -> CatalogDevelopment {
        try database.read { try Self.development(assetID, $0) }
    }
    public func exif(_ assetID: String) throws -> CatalogExif {
        try database.read { db in
            guard let exif = try CatalogExif.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
            return exif
        }
    }
    public func photo(_ id: String) throws -> CatalogPhoto {
        try database.read { db in
            guard let asset = try CatalogAsset.fetchOne(db, key: id), let exif = try CatalogExif.fetchOne(db, key: id) else {
                throw EditorError.invalidDocument(L10n.tr("Photo is no longer in this catalog."))
            }
            return CatalogPhoto(asset: asset, exif: exif, development: try Self.development(id, db))
        }
    }
    static func development(_ assetID: String, _ db: Database) throws -> CatalogDevelopment {
        guard let development = try CatalogDevelopment.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
        return development
    }
    public func existingImport(_ path: String) throws -> CatalogAsset? {
        try database.read { try CatalogAsset.filter(Columns.importPath == path).fetchOne($0) }
    }
    /// Publishes a completed generated file only after its thumbnail is durable. No image work follows insertion.
    public func insertCompletedOutput(_ photo: CatalogPhoto, thumbnail: Data?) async throws -> CatalogAsset {
        var photo = photo
        if let thumbnail {
            try await previews.install(thumbnail, assetID: photo.id)
            photo.thumbnailKey = UUID().uuidString; photo.thumbnailRenderKey = photo.renderKey
        }
        do { return try await insert(photo, thumbnail: nil) }
        catch {
            if thumbnail != nil { try? await previews.remove(assetIDs: [photo.id]) }
            throw error
        }
    }

    public func insert(_ photo: CatalogPhoto, thumbnail: Data?) async throws -> CatalogAsset {
        if let existing = try existingImport(photo.importPath) { return existing }
        try database.writeSync { db in
            var photo = photo
            photo.exif.assetID = photo.id; photo.development.assetID = photo.id
            // The importer holds the development inline.
            photo.adjustmentsData = try photo.adjustmentsData.map {
                try Self.encodeDevelopment(Self.decodeDevelopment($0, db, resources: resources), db, assetID: photo.id, resources: resources)
            }
            try photo.asset.insert(db)
            try photo.exif.insert(db)
            try photo.development.insert(db)
            if !photo.asset.isLatent { try CatalogAnalysisJob(assetID: photo.id).insert(db) }
            try Self.analysisChanged(db)
            try revision(photo.id, kind: .metadata, summary: L10n.tr("Imported metadata"), payload: JSONEncoder().encode(photo.metadata)).insert(db)
            if let edits = photo.adjustmentsData { try revision(photo.id, kind: .edit, summary: L10n.tr("Imported development"), payload: edits).insert(db) }
        }
        let asset = photo.asset
        if let thumbnail {
            try await installThumbnail(thumbnail, assetID: asset.id, renderKey: asset.renderKey)
            if photo.xmpData != nil {
                // The embedded camera preview has not been developed with imported XMP settings.
                _ = try database.writeSync { try CatalogAsset.filter(key: asset.id).updateAll($0, Columns.thumbnailRenderKey.set(to: nil)) }
            }
        }
        return try self.asset(asset.id)
    }
    public func updateMetadata(_ metadata: CatalogMetadata, assetID: String) throws {
        try updateMetadata([assetID: metadata])
    }
    /// Writes several photos' metadata in one transaction: all of them or none.
    public func updateMetadata(_ values: [String: CatalogMetadata]) throws {
        for value in values.values { _ = try value.validated() }
        try database.write { db in
            for (assetID, metadata) in values {
                guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
                guard asset.metadata != metadata else { continue }
                let summary = EditSummary.describe(metadata: metadata, from: asset.metadata)
                var described = metadata; described.rating = asset.metadata.rating; described.review = asset.metadata.review; described.label = asset.metadata.label
                let recordsHistory = described != asset.metadata
                asset.metadata = metadata; asset.updatedAt = Date()
                try asset.update(db)
                // Rating, flag and label changes alone are culling, not History.
                if recordsHistory { try revision(assetID, kind: .metadata, summary: summary, payload: JSONEncoder().encode(metadata)).insert(db) }
            }
        }
    }
    /// Adds keywords to each photo, keeping its own; returns the previous metadata of photos that changed.
    @discardableResult
    public func addKeywords(_ keywords: [String], assetIDs: [String]) throws -> [String: CatalogMetadata] {
        try database.write { db in
            var previous: [String: CatalogMetadata] = [:]
            for assetID in assetIDs {
                guard var asset = try CatalogAsset.fetchOne(db, key: assetID), asset.trashedAt == nil else { continue }
                var metadata = asset.metadata
                let existing = metadata.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let added = keywords.filter { word in !existing.contains { $0.caseInsensitiveCompare(word) == .orderedSame } }
                guard !added.isEmpty else { continue }
                metadata.keywords = (existing + added).joined(separator: ", ")
                previous[assetID] = asset.metadata
                let summary = EditSummary.describe(metadata: metadata, from: asset.metadata)
                asset.metadata = metadata; asset.updatedAt = Date()
                try asset.update(db)
                try revision(assetID, kind: .metadata, summary: summary, payload: JSONEncoder().encode(metadata)).insert(db)
            }
            return previous
        }
    }
    /// Returns the previous metadata of every photo that changed, for undo.
    @discardableResult
    /// `label` sets one: `.some(nil)` clears it, nil leaves it.
    public func updateQuickMetadata(assetIDs: [String], rating: Int? = nil, review: ReviewState? = nil, label: CatalogLabel?? = nil) throws -> [String: CatalogMetadata] {
        if let rating, !(0...5).contains(rating) { throw EditorError.invalidDocument(L10n.tr("Rating must be 0 to 5.")) }
        return try database.write { db in
            var previous: [String: CatalogMetadata] = [:]
            for assetID in assetIDs {
                guard var asset = try CatalogAsset.fetchOne(db, key: assetID), asset.trashedAt == nil else { continue }
                var metadata = asset.metadata
                if let rating { metadata.rating = rating }
                if let review { metadata.review = review }
                if let label { metadata.label = label }
                guard metadata != asset.metadata else { continue }
                previous[assetID] = asset.metadata
                // Culling (ratings, flags and labels) is undoable but stays out of History.
                asset.metadata = metadata; asset.updatedAt = Date()
                try asset.update(db)
            }
            return previous
        }
    }
    public func importXMP(_ imported: XMPImport, assetID: String, baseline: Adjustments) throws {
        _ = try imported.adjustments.validated(); _ = try imported.metadata.validated()
        try database.write { db in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
            var development = try Self.development(assetID, db)
            if asset.metadata != imported.metadata {
                try revision(assetID, kind: .metadata, summary: L10n.tr("Imported XMP metadata"), payload: JSONEncoder().encode(imported.metadata)).insert(db)
            }
            let edits = try Self.encodeDevelopment(imported.adjustments, db, assetID: assetID, resources: resources)
            if development.adjustmentsData != edits {
                if development.adjustmentsData == nil {
                    var original = revision(assetID, kind: .edit, summary: Self.originalSummary, payload: try Self.encodeDevelopment(baseline, db, assetID: assetID, resources: resources)); original.milestone = true
                    try original.insert(db)
                }
                var imported = revision(assetID, kind: .edit, summary: L10n.tr("Imported XMP development"), payload: edits); imported.milestone = true
                try imported.insert(db)
                asset.renderKey = UUID().uuidString; asset.lastEditedAt = Date()
            }
            asset.metadata = imported.metadata; development.adjustmentsData = edits
            development.xmpData = imported.sourceData; asset.xmpWarnings = imported.warnings.joined(separator: "\n\n")
            asset.updatedAt = Date(); asset.developmentUpdatedAt = asset.updatedAt
            try asset.update(db); try development.update(db)
            try Self.removeStaleBlobs(of: assetID, db)
        }
    }
    /// Edits are durable before a thumbnail render starts. Metadata never invalidates image caches.
    /// `coalescing` merges autosaves made during one editing session into a single history entry,
    /// so History lists meaningful steps ("Exposure, Highlights") instead of one row per pause.
    @discardableResult
    public func saveEdits(_ settings: Adjustments, assetID: String, baseline: Adjustments? = nil, coalescing: Bool = false,
                          summary: String? = nil, milestone: Bool = false) throws -> String {
        _ = try settings.validated()
        let session = autosaveSessions[assetID]
        let (renderKey, nextSession) = try database.write { db -> (String, (revisionID: String, base: Data?)??) in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
            var development = try Self.development(assetID, db)
            let payload = try Self.encodeDevelopment(settings, db, assetID: assetID, resources: resources)
            if development.adjustmentsData == payload { return (asset.renderKey, nil) }
            let baselineData = try baseline.map { try Self.encodeDevelopment($0, db, assetID: assetID, resources: resources) }
            if development.adjustmentsData == nil, let baselineData {
                var original = revision(assetID, kind: .edit, summary: Self.originalSummary, payload: baselineData); original.milestone = true
                try original.insert(db)
            }
            let previous = development.adjustmentsData ?? baselineData
            development.adjustmentsData = payload; asset.renderKey = UUID().uuidString; asset.developmentUpdatedAt = Date(); asset.lastEditedAt = asset.developmentUpdatedAt
            try asset.update(db); try development.update(db)
            // Timestamps have millisecond precision; rowid breaks ties by insertion order.
            let recent = try CatalogRevision.filter(CatalogRevision.Columns.assetID == assetID && CatalogRevision.Columns.kind == CatalogRevision.Kind.edit).order(CatalogRevision.Columns.createdAt.desc, Column.rowID.desc).limit(2).fetchAll(db)
            if coalescing, !milestone, var last = recent.first, !last.milestone, Date().timeIntervalSince(last.createdAt) < Self.coalescingInterval {
                var base: Data?? = nil
                if let session, session.revisionID == last.id { base = .some(session.base) }
                // Returning to the same controls soon after continues that step instead of adding one.
                else if recent.count == 2, let previous {
                    let before = recent[1].payload
                    let stepKeys = EditSummary.changedKeys(from: before, to: previous), newKeys = EditSummary.changedKeys(from: previous, to: payload)
                    if !newKeys.isEmpty, newKeys.isSubset(of: stepKeys) { base = .some(before) }
                }
                if let base {
                    last.payload = payload; last.createdAt = Date(); last.summary = EditSummary.describe(from: base, to: payload)
                    try last.update(db)
                    // The step no longer holds the rasters it had; they go unless something else uses them.
                    try Self.removeStaleBlobs(of: assetID, db)
                    return (asset.renderKey, .some((last.id, base)))
                }
            }
            var entry = revision(assetID, kind: .edit, summary: summary ?? EditSummary.describe(from: previous, to: payload), payload: payload)
            entry.milestone = milestone
            try entry.insert(db)
            try Self.removeStaleBlobs(of: assetID, db)
            return (asset.renderKey, .some(coalescing && !milestone ? (entry.id, previous) : nil))
        }
        if let nextSession { autosaveSessions[assetID] = nextSession }
        return renderKey
    }
    /// The open autosave history entry per photo and the development it started from.
    private var autosaveSessions: [String: (revisionID: String, base: Data?)] = [:]
}
