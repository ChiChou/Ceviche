import Foundation
import CoreImage
import GRDB
import Synchronization

/// Stored developments and snapshots of a photo's edits.
extension CatalogStore {
    /// Mask rasters, each owned by one photo, and the LUTs and profiles a `.database` build keeps in the catalog.
    static func createBlobTables(_ db: Database) throws {
        try db.create(table: "blob") { t in
            t.primaryKey("id", .text)
            t.column("assetID", .text).notNull().references("asset", onDelete: .cascade).indexed()
            t.column("data", .blob).notNull()
        }
        try db.create(table: "resource") { t in
            t.primaryKey("digest", .text)
            t.column("path", .text).notNull()
            t.column("data", .blob).notNull()
        }
    }
    /// Stored JSON for one of `assetID`'s developments. A raster the photo already stores keeps its blob; a new one
    /// gets a blob of its own, even when another photo has the same bytes.
    static func encodeDevelopment(_ settings: Adjustments, _ db: Database, assetID: String, resources: ResourceStorage) throws -> Data {
        try RevisionPayload.encode(settings, blob: { data in
            for row in try Row.fetchAll(db, sql: "SELECT id, data FROM blob WHERE assetID = ? AND length(data) = ?", arguments: [assetID, data.count]) where (row["data"] as Data) == data {
                return row["id"]
            }
            let id = UUID().uuidString
            try CatalogBlob(id: id, assetID: assetID, data: data).insert(db)
            return id
        }, resource: { try storeResource($0, db, resources) })
    }
    /// A stored development (a photo's, a History step's or a Snapshot's) with its blobs and resources read back.
    static func decodeDevelopment(_ stored: Data, _ db: Database, resources: ResourceStorage) throws -> Adjustments {
        do {
            return try readDevelopment(stored, db, resources: resources)
        } catch let error as ResourceUnavailable {
            // Said as it is (a LUT still downloading opens later); Reset Unreadable still drops it when asked.
            throw error
        } catch {
            // Said plainly, with what could not be read and what Reset Unreadable would take out, so the photo can be
            // reset instead of left unopenable. Values out of range and missing mask rasters too, not only data the
            // decoder can't parse.
            let detail = switch error {
            case let error as DecodingError: EditorError.describe(error)
            case EditorError.invalidDocument(let message): message
            default: error.localizedDescription
            }
            let parts = RevisionPayload.salvage(stored) { try readDevelopment($0, db, resources: resources) }?.dropped ?? []
            throw EditorError.unreadableEdits(detail, parts: parts)
        }
    }
    private static func readDevelopment(_ stored: Data, _ db: Database, resources: ResourceStorage) throws -> Adjustments {
        try RevisionPayload.decode(stored, blob: { id in
            guard let data = try Data.fetchOne(db, sql: "SELECT data FROM blob WHERE id = ?", arguments: [id]) else {
                throw EditorError.invalidDocument(L10n.tr("The development refers to mask data that is missing from this catalog."))
            }
            return data
        }, resource: { try resourceData($0, db, resources) })
    }
    /// Takes out only what the photo's saved development has that this build can't read, keeping the rest, as a
    /// revertible History step: a list item (a mask, a face) goes, a setting returns to `defaults`.
    @discardableResult
    public func resetUnreadableEdits(to defaults: Adjustments, assetID: String) throws -> String {
        let settings = try database.read { db -> Adjustments in
            guard let stored = try Self.development(assetID, db).adjustmentsData else { return defaults }
            if let settings = try? Self.readDevelopment(stored, db, resources: resources) { return settings }
            guard let salvaged = RevisionPayload.salvage(stored, defaults: defaults, decode: { try Self.readDevelopment($0, db, resources: resources) }) else {
                throw EditorError.invalidDocument(L10n.tr("The readable edits can’t be kept apart. Reset all edits instead."))
            }
            return salvaged.settings
        }
        return try saveEdits(settings, assetID: assetID, summary: L10n.tr("Reset unreadable edits"), milestone: true)
    }
    /// Deletes `assetID`'s blobs that neither its development, its History nor its Snapshots refer to any more.
    static func removeStaleBlobs(of assetID: String, _ db: Database) throws {
        let owned = try String.fetchAll(db, sql: "SELECT id FROM blob WHERE assetID = ?", arguments: [assetID])
        guard !owned.isEmpty else { return }
        var used: Set<String> = []
        for stored in try Data.fetchAll(db, sql: """
            SELECT adjustmentsData FROM assetDevelopment WHERE assetID = ?1 AND adjustmentsData IS NOT NULL
            UNION ALL SELECT payload FROM revision WHERE assetID = ?1 AND kind = 'edit'
            UNION ALL SELECT payload FROM snapshot WHERE assetID = ?1
            """, arguments: [assetID]) {
            // A step that can't be parsed may still use any of them: nothing is deleted, and the save goes on.
            guard let references = try? RevisionPayload.references(stored) else { return }
            used.formUnion(references)
        }
        let stale = owned.filter { !used.contains($0) }
        if !stale.isEmpty { try CatalogBlob.deleteAll(db, keys: stale) }
    }
    /// The file that holds a LUT, profile or ICC profile: the one the development already names when it is still
    /// there, otherwise one written now.
    static func storeResource(_ request: RevisionPayload.ResourceRequest, _ db: Database, _ resources: ResourceStorage) throws -> ResourceReference {
        if let existing = request.existing, try hasResource(existing, db, resources) { return existing }
        if let key = request.key, let known = ResourceCache.shared.storedReference(key), try hasResource(known, db, resources) { return known }
        let contents = try request.contents()
        let reference: ResourceReference
        switch resources {
        case .folder(let folder):
            reference = try folder.store(contents, kind: request.kind, name: request.name)
        case .database:
            reference = ResourceReference(path: request.kind.folder + "/" + FolderResources.fileName(request.name) + "." + request.kind.fileExtension,
                                          digest: ResourceReference.digest(of: contents))
            try db.execute(sql: "INSERT OR IGNORE INTO resource(digest, path, data) VALUES (?, ?, ?)", arguments: [reference.digest, reference.path, contents])
        }
        if let key = request.key { ResourceCache.shared.rememberStored(key, reference) }
        return reference
    }
    private static func hasResource(_ reference: ResourceReference, _ db: Database, _ resources: ResourceStorage) throws -> Bool {
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM resource WHERE digest = ?)", arguments: [reference.digest]) == true { return true }
        return resources.folder?.contains(reference) ?? false
    }
    /// A resource's bytes, from the catalog first and then the library folder, so a catalog written by a `.database`
    /// build still opens in a folder build.
    static func resourceData(_ reference: ResourceReference, _ db: Database, _ resources: ResourceStorage) throws -> Data {
        if let data = try Data.fetchOne(db, sql: "SELECT data FROM resource WHERE digest = ?", arguments: [reference.digest]) { return data }
        guard let folder = resources.folder else { throw ResourceUnavailable(reference: reference, downloading: false) }
        return try folder.data(for: reference)
    }
    /// The saved development with its blobs read back, or nil when the photo has never been edited.
    public func savedAdjustments(of asset: CatalogAsset) throws -> Adjustments? {
        try database.read { db in
            guard let stored = try Self.development(asset.id, db).adjustmentsData else { return nil }
            return try Self.decodeDevelopment(stored, db, resources: resources)
        }
    }
    /// The development a History entry holds.
    public func adjustments(of revision: CatalogRevision) throws -> Adjustments {
        guard revision.kind == .edit else { throw EditorError.invalidDocument(L10n.tr("This History entry is not a development.")) }
        return try database.read { try Self.decodeDevelopment(revision.payload, $0, resources: resources) }
    }
    /// Goes back to the import development as a new, revertible History step, and forgets the imported XMP packet so
    /// settings other software wrote, including ones Ceviche does not render, no longer travel with the photo.
    @discardableResult
    public func resetEdits(to defaults: Adjustments, assetID: String) throws -> String {
        try database.write { db in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
            var development = try Self.development(assetID, db)
            guard development.xmpData != nil || !asset.xmpWarnings.isEmpty else { return }
            development.xmpData = nil; asset.xmpWarnings = ""; asset.developmentUpdatedAt = Date(); try asset.update(db); try development.update(db)
        }
        return try saveEdits(defaults, assetID: assetID, baseline: defaults, summary: L10n.tr("Reset all edits"), milestone: true)
    }
    /// Forgets the XMP packet each photo was imported with and its compatibility notes, keeping the development:
    /// settings Ceviche does not render no longer travel with the photo or warn when it opens. The sidecar on disk is
    /// left alone. Returns the photos that had something to forget.
    @discardableResult
    public func stripSourceXMP(_ assetIDs: [String]) throws -> [String] {
        try database.write { db in
            var stripped: [String] = []
            for id in assetIDs {
                guard var asset = try CatalogAsset.fetchOne(db, key: id) else { continue }
                var development = try Self.development(id, db)
                guard development.xmpData != nil || !asset.xmpWarnings.isEmpty else { continue }
                development.xmpData = nil; asset.xmpWarnings = ""; asset.developmentUpdatedAt = Date()
                try asset.update(db); try development.update(db)
                stripped.append(id)
            }
            return stripped
        }
    }
    public func snapshots(assetID: String) throws -> [CatalogSnapshot] {
        try database.read { try CatalogSnapshot.filter(CatalogSnapshot.Columns.assetID == assetID).order(CatalogSnapshot.Columns.createdAt.desc).fetchAll($0) }
    }
    @discardableResult
    public func createSnapshot(name: String, adjustments: Adjustments, thumbnail: Data?, assetID: String) throws -> CatalogSnapshot {
        _ = try adjustments.validated()
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return try database.write { db in
            guard try CatalogAsset.exists(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("Photo not found.")) }
            let snapshot = CatalogSnapshot(id: UUID().uuidString, assetID: assetID, name: trimmed.isEmpty ? L10n.tr("Snapshot") : trimmed,
                                           payload: try Self.encodeDevelopment(adjustments, db, assetID: assetID, resources: resources),
                                           thumbnail: thumbnail.flatMap { RevisionPayload.historyThumbnail(from: $0) }, createdAt: Date())
            try snapshot.insert(db)
            return snapshot
        }
    }
    public func renameSnapshot(_ id: String, to name: String) throws {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !trimmed.isEmpty else { return }
        _ = try database.write { try CatalogSnapshot.filter(key: id).updateAll($0, CatalogSnapshot.Columns.name.set(to: trimmed)) }
    }
    public func deleteSnapshot(_ id: String) throws {
        try database.write { db in
            guard let snapshot = try CatalogSnapshot.fetchOne(db, key: id) else { return }
            try snapshot.delete(db)
            try Self.removeStaleBlobs(of: snapshot.assetID, db)
        }
    }
    public func adjustments(of snapshot: CatalogSnapshot) throws -> Adjustments {
        try database.read { try Self.decodeDevelopment(snapshot.payload, $0, resources: resources) }
    }
}
