import Foundation
import CryptoKit
import GRDB

// Edits made on two devices before either saw the other's are merged, not overwritten. Each photo keeps the last
// state and development this catalog and the mirror agreed on (`syncBase`); when both sides changed a part since,
// `DevelopmentMerge` and `CatalogSyncState.merged` combine them against it. A setting both changed differently takes
// the later edit's, and the other side's whole development is kept as a snapshot. The merge depends only on the two
// versions, so two devices that merge the same pair write the same result.

/// When the agreed versions of a photo's parts were made; nil for a part not agreed yet.
public struct CatalogSyncBaseClocks: Equatable, Sendable {
    public var state: Date?
    public var development: Date?
}

struct CatalogSyncBase {
    var state: CatalogSyncState?
    var development: CatalogSyncDevelopment?
}

extension CatalogStore {
    static func createSyncBase(_ db: Database) throws {
        try db.create(table: "syncBase") { t in
            t.primaryKey("assetID", .text).references("asset", onDelete: .cascade)
            t.column("stateUpdatedAt", .datetime)
            t.column("state", .blob)
            t.column("developmentUpdatedAt", .datetime)
            t.column("development", .blob)
        }
    }

    public func syncBaseClocks() throws -> [String: CatalogSyncBaseClocks] {
        try database.read { db in
            var clocks: [String: CatalogSyncBaseClocks] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT assetID, stateUpdatedAt, developmentUpdatedAt FROM syncBase") {
                clocks[row["assetID"]] = CatalogSyncBaseClocks(state: row["stateUpdatedAt"], development: row["developmentUpdatedAt"])
            }
            return clocks
        }
    }
    /// Records parts this catalog and the mirror now agree on, as the mirror holds them.
    public func recordSyncBases(states: [CatalogSyncState], developments: [CatalogSyncDevelopment]) throws {
        guard !states.isEmpty || !developments.isEmpty else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try database.write { db in
            func ensure(_ assetID: String) throws -> Bool {
                guard try CatalogAsset.exists(db, key: assetID) else { return false }
                try db.execute(sql: "INSERT OR IGNORE INTO syncBase (assetID) VALUES (?)", arguments: [assetID])
                return true
            }
            for state in states where try ensure(state.assetID) {
                try db.execute(sql: "UPDATE syncBase SET stateUpdatedAt = ?, state = ? WHERE assetID = ?", arguments: [state.updatedAt, encoder.encode(state), state.assetID])
            }
            for development in developments where try ensure(development.assetID) {
                try db.execute(sql: "UPDATE syncBase SET developmentUpdatedAt = ?, development = ? WHERE assetID = ?",
                               arguments: [development.updatedAt, encoder.encode(development), development.assetID])
            }
        }
    }
    static func syncBase(_ assetID: String, _ db: Database) throws -> CatalogSyncBase? {
        guard let row = try Row.fetchOne(db, sql: "SELECT state, development FROM syncBase WHERE assetID = ?", arguments: [assetID]) else { return nil }
        let decoder = JSONDecoder()
        return CatalogSyncBase(state: (row["state"] as Data?).flatMap { try? decoder.decode(CatalogSyncState.self, from: $0) },
                               development: (row["development"] as Data?).flatMap { try? decoder.decode(CatalogSyncDevelopment.self, from: $0) })
    }

    /// Whether a part changed both here and in the mirror since they last agreed.
    static func changedOnBothSides(local: Date, remote: Date, base: Date?) -> Bool {
        guard let base else { return false }
        return local != base && remote != base && local != remote
    }
    /// The later edit wins; equal times are settled by `key`, the same way on every device.
    static func winner(local: Date, remote: Date, localKey: String, remoteKey: String) -> DevelopmentMerge.Side {
        if remote != local { return remote > local ? .theirs : .ours }
        return remoteKey > localKey ? .theirs : .ours
    }
    /// A merge is newer than both sides, by the same step on every device.
    static func mergedClock(_ a: Date, _ b: Date) -> Date { max(a, b).addingTimeInterval(0.001) }
    /// A UUID from `parts`, the same on every device for the same parts.
    static func derivedID(_ parts: [String]) -> String {
        let digest = Array(SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }

    static func syncState(of asset: CatalogAsset) -> CatalogSyncState {
        CatalogSyncState(assetID: asset.id, origin: asset.origin, isCopy: asset.isCopy, metadata: asset.metadata, trashedAt: asset.trashedAt,
                         archivedAt: asset.archivedAt, stackID: asset.stackID, updatedAt: asset.updatedAt)
    }
    /// The state to apply for `remote`: merged with this catalog's when both changed since `base`.
    static func incomingState(_ remote: CatalogSyncState, asset: CatalogAsset, base: CatalogSyncState?) -> CatalogSyncState? {
        guard let base, changedOnBothSides(local: asset.updatedAt, remote: remote.updatedAt, base: base.updatedAt) else {
            return remote.updatedAt > asset.updatedAt ? remote : nil
        }
        let local = syncState(of: asset)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func key(_ state: CatalogSyncState) -> String { (try? encoder.encode(state)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        let winner = winner(local: local.updatedAt, remote: remote.updatedAt, localKey: key(local), remoteKey: key(remote))
        var merged = CatalogSyncState.merged(base: base, ours: local, theirs: remote, winner: winner).state
        merged.updatedAt = mergedClock(local.updatedAt, remote.updatedAt)
        return merged
    }

    /// Merges a development another device made with this catalog's, both changed since `base`. False, with nothing
    /// written, while data the result refers to hasn't arrived.
    func mergeDevelopment(_ remote: CatalogSyncDevelopment, base: CatalogSyncDevelopment, blobs: [String: Data], _ db: Database) throws -> Bool {
        let assetID = remote.assetID
        guard let asset = try CatalogAsset.fetchOne(db, key: assetID) else { return false }
        let stored = try Self.development(assetID, db)
        let local = CatalogSyncDevelopment(assetID: assetID, adjustmentsData: stored.adjustmentsData, xmpData: stored.xmpData, xmpWarnings: asset.xmpWarnings,
                                           renderKey: asset.renderKey, lastEditedAt: asset.lastEditedAt, updatedAt: asset.developmentUpdatedAt)
        let winner = Self.winner(local: local.updatedAt, remote: remote.updatedAt, localKey: local.renderKey, remoteKey: remote.renderKey)
        let (won, lost) = winner == .ours ? (local, remote) : (remote, local)
        var merged = won
        merged.renderKey = Self.derivedID(["merge", assetID] + [local.renderKey, remote.renderKey].sorted())
        merged.lastEditedAt = [local.lastEditedAt, remote.lastEditedAt].compactMap { $0 }.max()
        merged.updatedAt = Self.mergedClock(local.updatedAt, remote.updatedAt)
        var conflicts: [String]
        if let ours = local.adjustmentsData, let theirs = remote.adjustmentsData, let baseData = base.adjustmentsData {
            let result = try DevelopmentMerge.merge(base: baseData, ours: ours, theirs: theirs, winner: winner)
            merged.adjustmentsData = result.data; conflicts = result.conflicts
        } else {
            // A side back at the original development: the later one is kept whole.
            conflicts = local.adjustmentsData == remote.adjustmentsData ? [] : ["*"]
        }
        var applied = false
        do {
            try db.inSavepoint {
                applied = try applyDevelopment(merged, blobs: blobs, db, summary: L10n.tr("Merged edits"))
                return applied ? .commit : .rollback
            }
        } catch let error as DatabaseError {
            throw error
        } catch {
            // A merge this build can't read (settings that only make sense together, not declared so): the later
            // development is kept whole, the other as a snapshot.
            merged.adjustmentsData = won.adjustmentsData; conflicts = ["*"]
            applied = try applyDevelopment(merged, blobs: blobs, db, summary: L10n.tr("Merged edits"))
        }
        guard applied else { return false }
        if !conflicts.isEmpty, let edits = lost.adjustmentsData, edits != merged.adjustmentsData {
            try keepOtherEdits(edits, of: lost, local: lost.renderKey == local.renderKey, blobs: blobs, db)
        }
        return true
    }
    /// The side a conflict went against, as a snapshot every device names the same way, so merging on two devices
    /// adds it once.
    private func keepOtherEdits(_ edits: Data, of development: CatalogSyncDevelopment, local: Bool, blobs: [String: Data], _ db: Database) throws {
        let id = Self.derivedID(["conflict", development.assetID, development.renderKey])
        guard try !CatalogSnapshot.exists(db, key: id) else { return }
        let payload = local ? edits : try Self.receiveDevelopment(edits, blobs: blobs, db, assetID: development.assetID, resources: resources)
        guard let payload else { return }
        try CatalogSnapshot(id: id, assetID: development.assetID, name: L10n.tr("Other edits"), payload: payload, thumbnail: nil,
                            createdAt: development.lastEditedAt ?? development.updatedAt).insert(db)
    }
}
