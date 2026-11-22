import Foundation
import GRDB

/// Edits made to photos in a folder browsed in place. The index of browsed folders is a cache the system may empty,
/// so each edited photo's development is written to its XMP sidecar (`XMPSidecar`): `IMG.xmp`, or `IMG.ceviche.xmp`
/// when another application wrote `IMG.xmp`. Listing the folder reads them back. A photo that was only looked at
/// gets no file.
public enum FolderEdits {
    /// Writes the sidecars of the photos edited after `since`, and returns the moment to pass next time. Off the
    /// store's actor for the file work; a folder that cannot be written is skipped and its photos are tried again
    /// on their next edit.
    public static func flush(_ catalog: CatalogStore, since: Date) async throws -> Date {
        // A second of overlap: the catalog keeps times to the millisecond, and a change landing in the instant this
        // one is taken must not fall between two flushes. Writing a sidecar twice costs little; it says the same.
        let mark = Date().addingTimeInterval(-1)
        let edits = try await catalog.folderEdits(since: since)
        guard !edits.isEmpty else { return mark }
        await Task.detached(priority: .utility) {
            for edit in edits {
                let image = URL(fileURLWithPath: edit.path)
                let defaults = CatalogImporter.developmentDefaults(for: image, info: edit.info)
                try? XMPSidecar.resolveForWriting(for: image).write(adjustments: edit.adjustments, metadata: nil, defaults: defaults)
            }
        }.value
        return mark
    }

    /// Keeps the sidecars up to date for as long as the task runs: every edit is followed, once things have been
    /// quiet for a moment, by a flush. `since` is where the last run left off, and `reached` is told each new mark
    /// so it can be kept for the next launch.
    public static func follow(_ catalog: CatalogStore, since: Date, reached: @escaping @Sendable (Date) async -> Void) async {
        var since = since
        let observation = ValueObservation.tracking { db in
            try String.fetchOne(db, sql: "SELECT coalesce(max(developmentUpdatedAt), '') FROM asset") ?? ""
        }
        do {
            for try await _ in observation.values(in: catalog.database) {
                try await Task.sleep(for: .milliseconds(800))
                since = try await flush(catalog, since: since)
                await reached(since)
            }
        } catch {}
    }
}

extension CatalogStore {
    struct FolderEdit: Sendable {
        let path: String
        let adjustments: Adjustments
        let info: ImageInfo
    }
    /// After a folder went to the Trash: the index forgets its photos. Edits are dropped with their History; they
    /// went with the folder, in the sidecars.
    public func forgetFolder(below folder: String) async throws {
        let ids = try database.readSync { db in
            try String.fetchAll(db, CatalogAsset.filter(Self.folderCondition(folder, deep: true) && Columns.isCopy == false).select(Columns.id))
        }
        guard !ids.isEmpty else { return }
        try await removeFromCatalog(try removalPlan(for: ids), deletingCopies: false)
    }
    /// The photos edited here after `since`, with their development. Only once the person has edited the photo
    /// here: a sidecar read at listing already says what it holds.
    func folderEdits(since: Date) throws -> [FolderEdit] {
        try database.read { db in
            let changed = try CatalogAsset.filter(Columns.developmentUpdatedAt > since && Columns.lastEditedAt != nil && Columns.isCopy == false).fetchAll(db)
            // A development that can't be read is left for its next edit; the others are still written.
            return changed.compactMap { asset in
                guard let stored = (try? Self.development(asset.id, db))?.adjustmentsData,
                      let adjustments = try? Self.decodeDevelopment(stored, db, resources: resources) else { return nil }
                return FolderEdit(path: asset.sourcePath, adjustments: adjustments, info: asset.info)
            }
        }
    }
}
