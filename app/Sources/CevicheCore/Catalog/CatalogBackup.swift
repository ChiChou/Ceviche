import Foundation
import GRDB

/// What a backup with originals copied, and which originals it could not reach.
public struct CatalogBackupResult: Sendable {
    public var originals = 0
    /// Filenames of originals that were offline (an unmounted volume, a missing file); the backup keeps their records.
    public var missing: [String] = []
}

extension CatalogStore {
    /// A database and preview snapshot into `folder`, taken while no other catalog work runs on the actor.
    func snapshot(into folder: URL) throws {
        do {
            let snapshot = try DatabaseQueue(path: folder.appendingPathComponent("catalog.sqlite").path)
            try database.backup(to: snapshot)
        }
        // Thumbnails are a cache the catalog rebuilds when it opens: a damaged one doesn't fail the backup.
        try? previews.backup(to: folder.appendingPathComponent(PreviewStore.filename))
    }

    /// A self-contained backup: the catalog snapshot plus every original. Copies the catalog keeps go to the same
    /// place below `Originals/`; referenced files (on this Mac, an external volume or a server) are copied in by
    /// capture month and the backup's records point at those copies, so it opens anywhere with every photo present.
    /// `progress` reports originals done and the total.
    public nonisolated func backupWithOriginals(to destination: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> CatalogBackupResult {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw EditorError.invalidDocument(L10n.tr("Backup destination already exists.")) }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let replacement = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: replacement) }
        let staging = replacement.appendingPathComponent("Catalog", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await snapshot(into: staging)

        let queue = try DatabaseQueue(path: staging.appendingPathComponent("catalog.sqlite").path)
        // Catalog copies first, so a referenced file copied in later never takes a copy's name.
        let assets = try await queue.read { try CatalogAsset.fetchAll($0) }
            .sorted { ($0.locator.scheme == .catalog ? 0 : 1) < ($1.locator.scheme == .catalog ? 0 : 1) }
        let needed = assets.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
        if let free = try? destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < needed {
            throw EditorError.invalidDocument(L10n.tr("Not enough space for the originals: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed."))
        }

        var result = CatalogBackupResult()
        var repointed: [(id: String, relative: String)] = []
        progress(0, assets.count)
        for (index, asset) in assets.enumerated() {
            defer { progress(index + 1, assets.count) }
            let source: URL
            switch asset.availability(catalog: root) {
            case .available(let url): source = url
            case .fetchable:
                guard let url = try? await AssetResolver.fetch(asset.locator, catalog: root) else { result.missing.append(asset.filename); continue }
                source = url
            case .offline: result.missing.append(asset.filename); continue
            }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            // One original that can't be copied is listed as missing; the backup goes on. Running out of space
            // still stops it.
            do {
                if case .catalog(let relative) = asset.locator {
                    let target = staging.appendingPathComponent(relative)
                    // Two photos can share one catalog copy: it is copied once.
                    if !fm.fileExists(atPath: target.path) {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: source, to: target)
                        for (from, to) in zip(XMPPacket.sidecarNames(for: source), XMPPacket.sidecarNames(for: target)) where fm.fileExists(atPath: from.path) {
                            try? fm.copyItem(at: from, to: to)
                        }
                    }
                } else {
                    let sidecar = try? XMPPacket.sidecar(for: source)
                    let (_, relative) = try CatalogImporter.copyIntoCatalog(source, sidecar: sidecar, root: staging, captureDay: asset.captureDay)
                    repointed.append((asset.id, relative))
                }
            } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
                throw error
            } catch {
                result.missing.append(asset.filename); continue
            }
            result.originals += 1
        }
        let records = repointed
        try await queue.write { db in
            for (id, relative) in records {
                let locator = AssetLocator.catalog(relativePath: relative).string
                try db.execute(sql: "UPDATE asset SET importPath = ?, origin = ?, isCopy = 1, bookmark = NULL, sourcePath = ? WHERE id = ?",
                               arguments: [locator, locator, destination.appendingPathComponent(relative).path, id])
            }
        }
        try queue.close()
        try fm.moveItem(at: staging, to: destination)
        return result
    }
}
