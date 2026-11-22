import Foundation
import CoreImage
import GRDB
import Synchronization

/// Edit history and its compaction, installed thumbnails, relinking originals and backup.
extension CatalogStore {
    /// Folds old History steps per `HistoryCompactor`; blobs only the folded steps used go with them.
    /// Returns the number of entries folded away.
    @discardableResult
    public func compactHistory(assetID: String? = nil, now: Date = Date()) throws -> Int {
        let folded = try database.write { db -> Int in
            let edits = CatalogRevision.filter(CatalogRevision.Columns.kind == CatalogRevision.Kind.edit)
            let ids = try assetID.map { [$0] } ?? edits.select(CatalogRevision.Columns.assetID, as: String.self).distinct().fetchAll(db)
            var removed = 0
            for id in ids {
                let steps = edits.filter(CatalogRevision.Columns.assetID == id).order(CatalogRevision.Columns.createdAt, Column.rowID)
                let rows = try Row.fetchAll(db, steps.select(CatalogRevision.Columns.id, CatalogRevision.Columns.createdAt, CatalogRevision.Columns.milestone))
                let entries = rows.map { HistoryCompactor.Entry(id: $0["id"], createdAt: $0["createdAt"], milestone: $0["milestone"]) }
                for run in HistoryCompactor.plan(entries, now: now) {
                    guard let first = entries.firstIndex(where: { $0.id == run[0] }), let keepID = run.last,
                          var keep = try CatalogRevision.fetchOne(db, key: keepID) else { continue }
                    let before = try first > 0 ? CatalogRevision.fetchOne(db, key: entries[first - 1].id).map { $0.payload } : nil
                    keep.summary = EditSummary.describe(from: before, to: keep.payload)
                    try keep.update(db)
                    for folded in run.dropLast() { _ = try CatalogRevision.deleteOne(db, key: folded) }
                    removed += run.count - 1
                }
                try Self.removeStaleBlobs(of: id, db)
            }
            return removed
        }
        return folded
    }
    /// The camera's embedded preview for a photo that has none yet (a replica, or a relinked original).
    /// An edited photo keeps showing the "updates when opened" mark, since the preview is undeveloped.
    public func installPreviewThumbnail(_ data: Data, assetID: String) async throws {
        let current = try asset(assetID)
        guard current.thumbnailKey == nil else { return }
        try await installThumbnail(data, assetID: assetID, renderKey: current.renderKey, developed: false)
    }
    /// Marks a saved latent image as changed and installs its new thumbnail.
    public func updateLatent(assetID: String, thumbnail: Data) async throws {
        let key = UUID().uuidString
        try database.writeSync { db in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID), asset.isLatent else { throw LatentImage.invalid() }
            asset.renderKey = key; asset.lastEditedAt = Date(); asset.updatedAt = Date(); asset.originalUpdatedAt = Date()
            try asset.update(db)
        }
        try await installThumbnail(thumbnail, assetID: assetID, renderKey: key)
    }

    /// `thumbnailKey` is a fresh token per installed image, so views keyed on it reload; the bytes replace the
    /// photo's previous thumbnail in the preview store. `developed` is false for the camera's own preview: it shows an
    /// edited photo without its edits, so the photo stays marked for a render, in the same write that installs it (a
    /// separate one left a quit between the two marking the preview as showing the edits), and History keeps its image.
    public func installThumbnail(_ data: Data, assetID: String, renderKey: String, developed: Bool = true) async throws {
        let current = try asset(assetID)
        // The newest History step shows the development this thumbnail was rendered from.
        if developed, current.renderKey == renderKey, let small = RevisionPayload.historyThumbnail(from: data) {
            try database.writeSync { db in
                let latest = CatalogRevision.filter(CatalogRevision.Columns.assetID == assetID && CatalogRevision.Columns.kind == CatalogRevision.Kind.edit)
                    .order(CatalogRevision.Columns.createdAt.desc, Column.rowID.desc)
                if let id = try latest.select(CatalogRevision.Columns.id, as: String.self).fetchOne(db) {
                    try CatalogRevision.filter(key: id).updateAll(db, CatalogRevision.Columns.thumbnail.set(to: small))
                }
            }
        }
        guard !data.isEmpty, current.renderKey == renderKey else { return }
        if current.thumbnailRenderKey == renderKey, current.thumbnailKey != nil,
           try await previews.data(assetID: assetID) == data { return }
        try await previews.install(data, assetID: assetID)
        try database.writeSync { db in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID), asset.renderKey == renderKey else { return }
            let edited = try !developed && Self.development(assetID, db).adjustmentsData != nil
            asset.thumbnailKey = UUID().uuidString; asset.thumbnailRenderKey = edited ? nil : renderKey; try asset.update(db)
        }
        NotificationCenter.default.post(name: Self.thumbnailInstalled, object: self, userInfo: [Self.assetIDKey: assetID])
    }
    /// Posted by `installThumbnail` once a photo's new thumbnail is stored; `userInfo[assetIDKey]` names the photo.
    public static let thumbnailInstalled = Notification.Name("CatalogStore.thumbnailInstalled")
    public static let assetIDKey = "assetID"
    /// Drops previews of photos that are gone, and over `budget` bytes the least recently shown thumbnails,
    /// which regenerate when they next scroll into view. Returns how many thumbnails were evicted.
    @discardableResult
    public func sweepPreviews(budget: Int? = nil) async throws -> Int {
        // The preview store lists what it holds first, then asks which photos keep theirs, so a thumbnail installed in
        // between is never swept while its row still names it.
        let database = self.database
        let evicted = try await previews.sweep(budget: budget) { try database.read { Set(try CatalogAsset.filter(Columns.thumbnailKey != nil).select(Columns.id, as: String.self).fetchAll($0)) } }
        guard !evicted.isEmpty else { return 0 }
        _ = try database.writeSync { db in
            try CatalogAsset.filter(keys: evicted).updateAll(db, Columns.thumbnailKey.set(to: nil), Columns.thumbnailRenderKey.set(to: nil))
        }
        return evicted.count
    }
    public func history(assetID: String) throws -> [CatalogRevision] {
        try database.read { try CatalogRevision.filter(CatalogRevision.Columns.assetID == assetID).order(CatalogRevision.Columns.createdAt.desc, Column.rowID.desc).fetchAll($0) }
    }
    public func restore(_ item: CatalogRevision) throws {
        // Autosave entries are updated in place, so restore the stored payload rather than a possibly older copy.
        guard let item = try database.read({ try CatalogRevision.filter(key: item.id).filter(CatalogRevision.Columns.assetID == item.assetID && CatalogRevision.Columns.kind == item.kind.rawValue).fetchOne($0) }) else { throw EditorError.invalidDocument(L10n.tr("Unknown revision.")) }
        if item.kind == .edit { try saveEdits(adjustments(of: item), assetID: item.assetID, summary: L10n.tr("Reverted to “\(item.summary)”"), milestone: true) }
        else { try updateMetadata(JSONDecoder().decode(CatalogMetadata.self, from: item.payload), assetID: item.assetID) }
    }
    public func relink(_ url: URL, assetID: String, allowUnverified: Bool = false) throws {
        let current = try asset(assetID)
        if current.hasOriginalIdentity {
            guard try CatalogImporter.matches(url, current) else { throw EditorError.invalidDocument(L10n.tr("Choose the same original file. Its size and capture time must match the imported original.")) }
        } else if !allowUnverified {
            throw EditorError.invalidDocument(L10n.tr("This photo has no recorded size or capture time to check a replacement against."))
        }
        try link(url, assetID: assetID, replacing: false)
    }
    /// Points an offline photo at a different file, keeping its edits, history and metadata. Masks and
    /// crops stay aligned only when the replacement has the same dimensions, so the caller confirms first.
    public func replaceOriginal(_ url: URL, assetID: String) throws {
        let locator = AssetLocator.describing(url)
        if let other = try existingImport(locator.string), other.id != assetID {
            throw EditorError.invalidDocument(L10n.tr("That file is already in the catalog as “\(other.filename)”."))
        }
        try link(url, assetID: assetID, replacing: true)
    }
    private func link(_ url: URL, assetID: String, replacing: Bool) throws {
        // Fall back to a plain bookmark so the photo keeps tracking moves when scoped bookmarks are unavailable.
        let bookmark = (try? url.bookmarkData(options: .securityScoped, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
        let locator = AssetLocator.describing(url)
        let identity = try CatalogImporter.fingerprint(url)
        try database.write { db in
            // A located or replacement file is referenced where it is, even when the original was a catalog copy.
            let linked: [ColumnAssignment] = [Columns.sourcePath.set(to: url.path), Columns.bookmark.set(to: bookmark), Columns.origin.set(to: locator.string), Columns.isCopy.set(to: false),
                                              Columns.fileSize.set(to: identity.size), Columns.captureTime.set(to: identity.captureTime)]
                + [Columns.updatedAt, Columns.originalUpdatedAt].map { $0.set(to: Date()) }
            if replacing {
                try CatalogAsset.filter(key: assetID).updateAll(db, linked + [Columns.importPath.set(to: locator.string), Columns.filename.set(to: url.lastPathComponent), Columns.renderKey.set(to: UUID().uuidString)])
                try revision(assetID, kind: .metadata, summary: L10n.tr("Replaced original with \(url.lastPathComponent)"), payload: JSONEncoder().encode(try CatalogAsset.fetchOne(db, key: assetID)?.metadata ?? CatalogMetadata())).insert(db)
            } else {
                try CatalogAsset.filter(key: assetID).updateAll(db, linked)
            }
            try Self.enqueueAnalysis(db, assetID: assetID, version: CatalogImporter.analysisVersion, priority: 0)
        }
    }
    /// Moves originals an iCloud catalog copied into its own folder, before it kept them in iCloud Drive, into the
    /// shared folder so the other Macs can read them. Their paths below `Originals/` stay the same, so nothing in the
    /// catalog changes. Returns how many files moved; one that is already there is left where it is.
    public nonisolated func shareLocalOriginals() throws -> Int {
        guard originalsRoot != root else { return 0 }
        let local = root.appendingPathComponent("Originals", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: local, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        let ubiquitous = resources.folder?.ubiquitous == true
        var moved = 0
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let destination = originalsRoot.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if ubiquitous { try FileManager.default.setUbiquitous(true, itemAt: url, destinationURL: destination) }
            else { try FileManager.default.moveItem(at: url, to: destination) }
            moved += 1
        }
        return moved
    }
    /// Consistent database snapshot, taken while no other catalog work runs on the actor.
    public func backup(to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw EditorError.invalidDocument(L10n.tr("Backup destination already exists.")) }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let replacement = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: replacement) }
        let staging = replacement.appendingPathComponent("Catalog", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try snapshot(into: staging)
        try fm.moveItem(at: staging, to: destination)
    }
    static let originalSummary = L10n.tr("Original development")
    /// Autosaves separated by less than this idle gap belong to the same history entry.
    static let coalescingInterval: TimeInterval = 120
    func revision(_ assetID: String, kind: CatalogRevision.Kind, summary: String, payload: Data) -> CatalogRevision {
        CatalogRevision(id: UUID().uuidString, assetID: assetID, kind: kind, summary: summary, payload: payload, createdAt: Date())
    }
}
