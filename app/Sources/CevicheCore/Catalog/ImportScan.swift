import Foundation
import GRDB

/// Name, size and capture time: enough to recognize a photo already in the catalog without hashing it.
public struct ImportFingerprint: Hashable, Sendable {
    public let name: String
    public let size: Int64?
    public let captureTime: String?
    public init(name: String, size: Int64?, captureTime: String?) {
        self.name = name.lowercased(); self.size = size; self.captureTime = captureTime
    }
    public var captureDay: String { captureTime.map { String($0.prefix(10)) } ?? "" }
}

/// What the catalog already holds, and what recently left it, in forms a scan can match quickly.
public struct CatalogPresence: Sendable {
    struct Keys: Sendable {
        var importPaths: Set<String> = []
        var nameAndTime: Set<String> = []
        var nameAndSize: Set<String> = []
        mutating func insert(_ row: Row) {
            importPaths.insert(row["importPath"])
            importPaths.insert(row["origin"])
            let name = (row["filename"] as String).lowercased()
            if let time: String = row["captureTime"] { nameAndTime.insert(name + "|" + time) }
            if let size: Int64 = row["fileSize"] { nameAndSize.insert(name + "|" + String(size)) }
        }
        func contains(_ fingerprint: ImportFingerprint, locator: AssetLocator?, path: String?) -> Bool {
            if let locator, importPaths.contains(locator.string) { return true }
            if let path, importPaths.contains(path) { return true }
            if let time = fingerprint.captureTime, nameAndTime.contains(fingerprint.name + "|" + time) { return true }
            if let size = fingerprint.size, nameAndSize.contains(fingerprint.name + "|" + String(size)) { return true }
            return false
        }
    }
    var current = Keys()
    var deleted = Keys()
    public init() {}
    public func contains(_ fingerprint: ImportFingerprint, locator: AssetLocator? = nil, path: String? = nil) -> Bool {
        current.contains(fingerprint, locator: locator, path: path)
    }
    /// Imported once and removed from the catalog within `CatalogStore.deletedImportRetention`.
    public func wasDeleted(_ fingerprint: ImportFingerprint, locator: AssetLocator? = nil, path: String? = nil) -> Bool {
        deleted.contains(fingerprint, locator: locator, path: path)
    }
}

extension CatalogStore {
    /// How long a photo removed from the catalog is still recognized by imports, so it is not offered again.
    public static let deletedImportRetention: TimeInterval = 30 * 24 * 60 * 60
    public func presence(now: Date = Date()) throws -> CatalogPresence {
        try database.read { db in
            var presence = CatalogPresence()
            let columns = CatalogAsset.Columns.self
            for row in try Row.fetchAll(db, CatalogAsset.select(columns.importPath, columns.origin, columns.filename, columns.fileSize, columns.captureTime)) {
                presence.current.insert(row)
            }
            for row in try Row.fetchAll(db, sql: "SELECT importPath, origin, filename, fileSize, captureTime FROM deletedImport WHERE deletedAt >= ?",
                                        arguments: [now.addingTimeInterval(-Self.deletedImportRetention)]) {
                presence.deleted.insert(row)
            }
            return presence
        }
    }
    /// Notes photos about to leave the catalog for good, and forgets ones that left longer ago than the retention.
    static func rememberDeletedImports(_ assetIDs: [String], _ db: Database, now: Date = Date()) throws {
        try db.execute(sql: "DELETE FROM deletedImport WHERE deletedAt < ?", arguments: [now.addingTimeInterval(-deletedImportRetention)])
        for id in assetIDs {
            try db.execute(sql: """
                INSERT INTO deletedImport(importPath, origin, filename, fileSize, captureTime, deletedAt)
                SELECT importPath, origin, filename, fileSize, captureTime, ? FROM asset WHERE id = ?
                """, arguments: [now, id])
        }
    }
}

/// A photo found by scanning a card, folder or remote storage.
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public var id: String { locator.string }
    public let locator: AssetLocator
    /// Readable now (mounted storage); nil for files that must be downloaded first.
    public let url: URL?
    public let filename: String
    /// The folder inside the scanned root, for album-style grouping.
    public let folder: String
    public let fingerprint: ImportFingerprint
    public let modified: Date?
    /// Already in the catalog by locator, or by name with capture time or size.
    public var present: Bool
    /// Not in the catalog, but imported and then removed from it recently; offered without being preselected.
    public var recentlyDeleted = false
    /// The capture day from EXIF when the scan read it, else the file's modification day: a quick scan
    /// groups by the latter, which on a camera card is the same day.
    public var captureDay: String {
        if !fingerprint.captureDay.isEmpty { return fingerprint.captureDay }
        return modified.map { Self.dayFormatter.string(from: $0) } ?? ""
    }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    public init(locator: AssetLocator, url: URL?, filename: String, folder: String, fingerprint: ImportFingerprint, modified: Date?, present: Bool, recentlyDeleted: Bool = false) {
        self.locator = locator; self.url = url; self.filename = filename; self.folder = folder; self.fingerprint = fingerprint; self.modified = modified
        self.present = present; self.recentlyDeleted = !present && recentlyDeleted
    }
}

public enum ImportScanner {
    /// Recursively lists supported photos under `roots`, newest folders first, marking ones the catalog has.
    /// Hidden folders and packages are skipped; XMP sidecars travel with their photo at import. A quick scan
    /// reads only the file's size and date, not its EXIF, so a whole card is listed in a moment; capture
    /// times are then read when a photo comes into view.
    public static func scan(_ roots: [URL], presence: CatalogPresence, quick: Bool = false) -> AsyncThrowingStream<ImportCandidate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for root in roots {
                        try Task.checkCancellation()
                        let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        if !isDirectory {
                            if CatalogImporter.supported(root) { continuation.yield(try candidate(root, folder: "", presence: presence, quick: quick)) }
                            continue
                        }
                        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                        while let next = enumerator.nextObject() {
                            try Task.checkCancellation()
                            guard let file = next as? URL else { continue }
                            if LatentImage.isBundle(file) { enumerator.skipDescendants(); continue }
                            guard CatalogImporter.supported(file),
                                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                            let folder = AssetLocator.relativePath(of: file.deletingLastPathComponent(), in: root) ?? ""
                            if let item = try? candidate(file, folder: folder, presence: presence, quick: quick) { continuation.yield(item) }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    static func candidate(_ url: URL, folder: String, presence: CatalogPresence, quick: Bool = false) throws -> ImportCandidate {
        let fingerprint: ImportFingerprint
        if quick { let stamp = try CatalogImporter.fileStamp(url); fingerprint = ImportFingerprint(name: url.lastPathComponent, size: stamp.fileSize.map { Int64($0) }, captureTime: nil) }
        else { fingerprint = try CatalogImporter.fingerprint(url) }
        let locator = AssetLocator.describing(url)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let path = url.resolvingSymlinksInPath().path
        return ImportCandidate(locator: locator, url: url, filename: url.lastPathComponent, folder: folder, fingerprint: fingerprint, modified: modified,
                               present: presence.contains(fingerprint, locator: locator, path: path),
                               recentlyDeleted: presence.wasDeleted(fingerprint, locator: locator, path: path))
    }
    /// Groups for an album-style view: by folder when a card has several, otherwise by capture day.
    public static func groups(_ candidates: [ImportCandidate]) -> [(title: String, items: [ImportCandidate])] {
        let folders = Set(candidates.map(\.folder))
        let keyed: [String: [ImportCandidate]]
        if folders.count > 1 { keyed = Dictionary(grouping: candidates) { $0.folder.isEmpty ? L10n.tr("Top level") : $0.folder } }
        else { keyed = Dictionary(grouping: candidates) { $0.captureDay.isEmpty ? L10n.tr("Unknown Date") : $0.captureDay } }
        return keyed.keys.sorted(by: >).map { (title: $0, items: keyed[$0]!.sorted { ($0.fingerprint.captureTime ?? "", $0.filename) < ($1.fingerprint.captureTime ?? "", $1.filename) }) }
    }
}
