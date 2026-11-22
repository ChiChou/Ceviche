import Foundation
import GRDB

/// Folders browsed in place: the catalog indexes what a folder holds the first time it is shown, by reference, and
/// follows the files added and deleted there afterwards. Nothing is read ahead of the folder the person opens.
public enum CatalogFolders {
    public struct Listing: Sendable, Equatable {
        public var folders: [URL] = []
        public var photos: [URL] = []
        public init() {}
    }

    /// The canonical spelling of a folder, as `CatalogFilter.folder` and `CatalogAsset.sourcePath` use it.
    public static func path(_ url: URL) -> String { url.standardizedFileURL.path }

    /// The visible subfolders and photos directly in `folder`. Packages (a catalog, a Photos library) are not folders
    /// to browse. Throws when the folder cannot be read, which is how a denied privacy request shows up.
    public static func list(_ folder: URL, photos wanted: Bool = true) throws -> Listing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]
        let base = URL(fileURLWithPath: path(folder), isDirectory: true)
        var result = Listing()
        for item in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            let url = base.appendingPathComponent(item.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                if values.isPackage != true, !LatentImage.isBundle(url) { result.folders.append(url) }
            } else if wanted, values.isRegularFile == true, CatalogImporter.supported(item) {
                result.photos.append(url)
            }
        }
        result.folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        result.photos.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return result
    }

    /// True when `error` says the system refused access (privacy settings or permissions) rather than the folder being gone.
    public static func isDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(EPERM) || underlying.code == Int(EACCES))
    }

    public struct SyncResult: Sendable, Equatable {
        public var added = 0, removed = 0, failed = 0
        /// Photos in the folder once the sync finished or stopped.
        public var found = 0
        /// Thumbnails made for photos that were listed without one.
        public var thumbnails = 0
        /// Thumbnails developed for photos that carry edits, such as a sidecar's, in place of the camera's preview.
        public var developed = 0
        /// Files that could not be read as photos, so the next sync can leave them alone until they change.
        public var failedPaths: [String] = []
        public init() {}
    }

    /// `folder` with, when `deep`, everything below it: the photos, and the folders that could not be read (so their
    /// records are not taken for deleted). Hidden folders and packages are not entered.
    static func walk(_ folder: URL, deep: Bool) throws -> (photos: [URL], unread: [String]) {
        var listing = try list(folder)
        guard deep else { return (listing.photos, []) }
        var photos = listing.photos, unread: [String] = [], queue = listing.folders
        while !queue.isEmpty, !Task.isCancelled {
            let next = queue.removeFirst()
            do { listing = try list(next); photos += listing.photos; queue += listing.folders }
            catch { unread.append(path(next)) }
        }
        return (photos, unread)
    }

    /// Brings the catalog in line with `folder`, in the order a person wants to see it happen:
    ///
    /// 1. Records whose file is gone are dropped unless the person has worked on them (`CatalogStore.forgetVanished`).
    /// 2. Photos new to the catalog are listed by reference from their headers alone, without a thumbnail, so the
    ///    whole folder is in the grid within moments. `listed` is called as they land.
    /// 3. Thumbnails follow: first the preview each camera embedded, which is quick, then a decode of the photos
    ///    that carry none.
    /// 4. Photos with edits (a sidecar beside them) are developed last, a couple at a time, and their thumbnail
    ///    replaces the camera's preview, which does not show the edits.
    ///
    /// `deep` includes the folders below. `skipping` names files a previous sync could not read, and `keeping` the
    /// records to leave alone even if their file is gone (the photo that is open). `progress` counts thumbnails;
    /// cancelling stops between photos, and the next sync picks up the thumbnails still missing.
    ///
    /// `folderData` is for the index of browsed folders, which is only a cache: edits live in the photos' sidecars
    /// (`FolderEdits`), Ceviche's own `IMG.ceviche.xmp` read before another application's `IMG.xmp`, and a record
    /// whose file is gone is dropped whatever was made of it.
    public static func sync(_ folder: URL, store: CatalogStore, deep: Bool = false, folderData: Bool = false, width: Int = defaultWidth, skipping: Set<String> = [], keeping: Set<String> = [],
                            listed: (@Sendable () async -> Void)? = nil,
                            progress: (@Sendable (_ done: Int, _ total: Int) async -> Void)? = nil) async throws -> SyncResult {
        let folderPath = path(folder)
        let walked = try await Task.detached(priority: .userInitiated) { try walk(folder, deep: deep) }.value
        let records = try await store.folderRecords(folderPath, deep: deep)
        let known = Set(records.map(\.sourcePath))
        let present = Set(walked.photos.map(\.path))
        var result = SyncResult()
        result.found = walked.photos.count
        let vanished = records.filter { record in
            !present.contains(record.sourcePath) && !keeping.contains(record.id) && !walked.unread.contains { record.sourcePath.hasPrefix($0 + "/") }
        }
        if !vanished.isEmpty { result.removed = try await store.forgetVanished(vanished.map(\.id), whateverWasMade: folderData) }
        let new = walked.photos.filter { !known.contains($0.path) && !skipping.contains($0.path) }
        // Photos already listed whose thumbnail never arrived: a sync that was stopped, or a preview evicted since.
        var pending: [(id: String, url: URL)] = records.filter { $0.thumbnailKey == nil && present.contains($0.sourcePath) && !skipping.contains($0.sourcePath) }
            .map { ($0.id, URL(fileURLWithPath: $0.sourcePath)) }
        guard !new.isEmpty || !pending.isEmpty else { return result }
        let width = max(1, width)

        // Listing: headers only.
        var sinceListed = 0
        // Ceviche's own sidecars, looked for once per folder rather than once per photo.
        let own: Set<String> = folderData ? Set(Set(new.map { $0.deletingLastPathComponent() }).flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".ceviche.xmp") }.map { folder.appendingPathComponent($0).path.lowercased() }
        }) : []
        for await outcome in pool(new, width: width, priority: .userInitiated, work: { url -> String? in
            let ours = XMPSidecar.cevicheURL(for: url)
            let sidecar = own.contains(ours.path.lowercased()) ? ours : nil
            guard var prepared = try? CatalogImporter.prepare(url, sidecar: sidecar, options: CatalogImporter.ImportOptions(thumbnail: false)) else { return nil }
            prepared.0.importBatchID = nil
            return try? await store.insert(prepared.0, thumbnail: nil).id
        }) {
            if let id = outcome.1 { result.added += 1; pending.append((id, outcome.0)) } else { result.failed += 1; result.failedPaths.append(outcome.0.path) }
            sinceListed += 1
            if sinceListed >= 256 { sinceListed = 0; await listed?() }
        }
        if result.added > 0 { await listed?() }
        let undeveloped = Task.isCancelled ? [] : ((try? await store.folderUndeveloped(folderPath, deep: deep)) ?? []).filter { present.contains($0.sourcePath) && !skipping.contains($0.sourcePath) }
        guard !Task.isCancelled, !pending.isEmpty || !undeveloped.isEmpty else { return result }

        // Thumbnails, through the catalog's queue: camera previews first, decodes of photos without one, then
        // developed thumbnails for the edited, behind everything else.
        let paths = Dictionary(pending.map { ($0.id, $0.url.path) } + undeveloped.map { ($0.id, $0.sourcePath) }) { first, _ in first }
        let reactor = store.thumbnails
        let previews = await reactor.want(pending.map(\.id), kind: .preview, priority: .visible)
        let developed = await reactor.want(undeveloped.map(\.id), kind: .developed, priority: .background)
        await progress?(0, previews.total + developed.total)
        let outcomes = await reactor.wait([previews, developed], progress: progress)
        result.thumbnails = pending.filter { outcomes[$0.id] == .installed }.count
        result.developed = undeveloped.filter { outcomes[$0.id] == .installed }.count
        result.failedPaths += paths.filter { outcomes[$0.key] == .failed }.map(\.value)
        return result
    }

    /// Runs `work` over `items`, `width` at a time, and gives each outcome as it finishes. Stops handing out items
    /// once the caller is cancelled; items already under way finish.
    private static func pool<Item: Sendable, Output: Sendable>(_ items: [Item], width: Int, priority: TaskPriority,
                                                               work: @escaping @Sendable (Item) async -> Output) -> AsyncStream<(Item, Output)> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (Item, Output).self) { group in
                    var next = 0
                    func enqueue() {
                        guard next < items.count, !Task.isCancelled else { return }
                        let item = items[next]; next += 1
                        group.addTask(priority: priority) { (item, await work(item)) }
                    }
                    for _ in 0..<width { enqueue() }
                    while let outcome = await group.next() { continuation.yield(outcome); enqueue() }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Thumbnails decode in parallel; past the performance cores the disk and the decoder stop scaling.
    public static var defaultWidth: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) }
}

/// What a browsed folder holds, for its Info panel.
public struct CatalogFolderSummary: Sendable, Equatable {
    public var photos = 0, raw = 0, edited = 0
    public var bytes: Int64 = 0
    public var firstDay: String?, lastDay: String?
}

/// A catalogued photo whose original was last read from a folder.
public struct CatalogFolderRecord: Sendable, Equatable {
    public let id: String
    public let sourcePath: String
    /// Nil while the photo is listed without a thumbnail.
    public let thumbnailKey: String?
}

extension CatalogStore {
    /// Photos whose original sits directly in `folder`, not in its subfolders: the generated `folder` column, which
    /// ends in a separator, answered from its index.
    /// `deep` takes in the folders below as well: every `folder` value that starts with this one, as a range of the
    /// same index ("0" is the character after the separator).
    nonisolated static func folderCondition(_ folder: String, deep: Bool = false) -> SQLExpression {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        guard deep else { return Column("folder") == base + "/" }
        // By row, read off the folder index for the range: given the bare range, the planner prefers an equality on
        // some other column and passes over the whole catalog.
        return SQL("asset.rowid IN (SELECT rowid FROM asset WHERE folder >= \(base + "/") AND folder < \(base + "0"))").sqlExpression
    }

    /// Every record of `folder`, wherever the photo is now: the library, the archive or the Trash.
    public func folderRecords(_ folder: String, deep: Bool = false) throws -> [CatalogFolderRecord] {
        try database.read { db in
            try Row.fetchAll(db, CatalogAsset.filter(Self.folderCondition(folder, deep: deep)).select(Columns.id, Columns.sourcePath, Columns.thumbnailKey))
                .map { CatalogFolderRecord(id: $0["id"], sourcePath: $0["sourcePath"], thumbnailKey: $0["thumbnailKey"]) }
        }
    }

    public func folderSummary(_ folder: String, deep: Bool = false) throws -> CatalogFolderSummary {
        try database.read { db in
            let request = CatalogAsset.filter(Self.folderCondition(folder, deep: deep) && Columns.trashedAt == nil).select(sql: """
                count(*), coalesce(sum(kind = 'RAW'), 0), count(lastEditedAt), coalesce(sum(fileSize), 0),
                min(nullif(captureDay, '')), max(nullif(captureDay, ''))
                """)
            guard let row = try Row.fetchOne(db, request) else { return CatalogFolderSummary() }
            return CatalogFolderSummary(photos: row[0] ?? 0, raw: row[1] ?? 0, edited: row[2] ?? 0, bytes: row[3] ?? 0, firstDay: row[4], lastDay: row[5])
        }
    }

    /// Photos of `folder` that carry edits and whose thumbnail does not show them yet.
    public func folderUndeveloped(_ folder: String, deep: Bool = false) throws -> [CatalogFolderRecord] {
        try database.read { db in
            let edited = SQL("asset.id IN (SELECT assetID FROM assetDevelopment WHERE adjustmentsData IS NOT NULL)").sqlExpression
            // Asked before the camera previews are in, so a photo with no thumbnail yet counts too.
            let stale = Columns.thumbnailRenderKey == nil || Columns.thumbnailRenderKey != Columns.renderKey
            return try Row.fetchAll(db, CatalogAsset.filter(Self.folderCondition(folder, deep: deep) && Columns.trashedAt == nil && stale && edited)
                .select(Columns.id, Columns.sourcePath, Columns.thumbnailKey))
                .map { CatalogFolderRecord(id: $0["id"], sourcePath: $0["sourcePath"], thumbnailKey: $0["thumbnailKey"]) }
        }
    }

    /// Drops the records of files deleted from a browsed folder, and returns how many went. A photo the person has
    /// worked on (edited, rated, flagged, labelled, described, grouped or put in an album) and a copy the catalog
    /// owns stay, and show as missing, so nothing made here is lost to a file that was only moved.
    @discardableResult
    public func forgetVanished(_ ids: [String], whateverWasMade: Bool = false) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        if whateverWasMade {
            try await removeFromCatalog(try removalPlan(for: ids), deletingCopies: false)
            return ids.count
        }
        let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        let untouched = try database.readSync { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM asset WHERE id IN (SELECT value FROM json_each(?)) AND isCopy = 0 AND lastEditedAt IS NULL AND rating = 0
                AND review = 'unreviewed' AND label IS NULL AND title = '' AND caption = '' AND keywords = '' AND stackID IS NULL
                AND id NOT IN (SELECT assetID FROM albumAsset)
                """, arguments: [list])
        }
        guard !untouched.isEmpty else { return 0 }
        try await removeFromCatalog(try removalPlan(for: untouched), deletingCopies: false)
        return untouched.count
    }
}
