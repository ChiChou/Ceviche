import Foundation
import GRDB

/// One photo's place in the analysis queue, shared with the index service through the database.
public struct CatalogAnalysisJob: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "analysisJob"
    public enum State: String, Codable, Sendable, DatabaseValueConvertible { case pending, running, failed, complete }
    public static let maximumAttempts = 5
    public var assetID: String
    public var version = ""
    public var state = State.pending
    public var attempts = 0
    public var priority = 0
    public var nextAttempt = 0.0
    public var owner: String?
    public var leaseUntil: Double?
    public var lastError: String?
    public init(assetID: String, version: String = "", priority: Int = 0) {
        self.assetID = assetID; self.version = version; self.priority = priority
    }
    public enum Columns {
        public static let assetID = Column(CodingKeys.assetID), version = Column(CodingKeys.version), state = Column(CodingKeys.state)
        public static let attempts = Column(CodingKeys.attempts), priority = Column(CodingKeys.priority), nextAttempt = Column(CodingKeys.nextAttempt)
        public static let owner = Column(CodingKeys.owner), leaseUntil = Column(CodingKeys.leaseUntil), lastError = Column(CodingKeys.lastError)
    }
    /// Released by its worker: back in the queue, or failed once the attempts are used up.
    mutating func release(nextAttempt: Double, error: String?) {
        state = attempts >= Self.maximumAttempts ? .failed : .pending
        owner = nil; leaseUntil = nil; self.nextAttempt = nextAttempt; lastError = error
    }
}

/// The one-row switch and change counter the app and the index service watch.
public struct CatalogAnalysisControl: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "analysisControl"
    public var id = 1
    public var enabled = true
    public var generation: Int64 = 0
    public enum Columns {
        public static let id = Column(CodingKeys.id), enabled = Column(CodingKeys.enabled), generation = Column(CodingKeys.generation)
    }
}

public struct CatalogAnalysisClaim: Sendable {
    public let asset: CatalogAsset
    public let owner: String
    public let version: String
}
public struct CatalogAnalysisStatus: Equatable, Sendable {
    public var enabled = true
    public var pending = 0
    public var running = 0
    public var failed = 0
    public var complete = 0
    public var ready = 0
    public var generation: Int64 = 0
    public init() {}
    public var remaining: Int { pending + running }
}

extension CatalogStore {
    private typealias Job = CatalogAnalysisJob
    private typealias Asset = CatalogAsset.Columns
    /// Run once on catalog open. Existing failures remain backed off until retry or a model change.
    public func enqueueOutdatedAnalysis(version: String) throws {
        try database.write { db in
            // Only photos this Mac analyzes; another Mac's result is final here (`CatalogAsset.analysisOrigin`).
            let outdated = CatalogAsset.filter(Asset.kind != LatentImage.kind && Asset.area(.library) && Asset.analysisOrigin == "local" && (Asset.analysisVersion == nil || Asset.analysisVersion != version))
            // Jobs queued for another version start over; photos without a job get one.
            let reset = try Job.filter(outdated.select(Asset.id).contains(Job.Columns.assetID) && Job.Columns.version != version)
                .updateAll(db, Self.freshJob(version: version))
            let missing = try outdated.filter(!Job.select(Job.Columns.assetID).contains(Asset.id)).select(Asset.id, as: String.self).fetchAll(db)
            for id in missing { try Job(assetID: id, version: version).insert(db) }
            if reset + missing.count > 0 { try Self.analysisChanged(db) }
        }
    }
    private static func freshJob(version: String) -> [ColumnAssignment] {
        [Job.Columns.version.set(to: version), Job.Columns.state.set(to: Job.State.pending), Job.Columns.attempts.set(to: 0),
         Job.Columns.nextAttempt.set(to: 0), Job.Columns.owner.set(to: nil), Job.Columns.leaseUntil.set(to: nil), Job.Columns.lastError.set(to: nil)]
    }
    static func analysisChanged(_ db: Database) throws {
        try CatalogAnalysisControl.updateAll(db, CatalogAnalysisControl.Columns.generation.set(to: CatalogAnalysisControl.Columns.generation + 1))
    }
    static func enqueueAnalysis(_ db: Database, assetID: String, version: String, priority: Int) throws {
        guard try CatalogAsset.filter(key: assetID).filter(Asset.area(.library) && Asset.kind != LatentImage.kind).fetchCount(db) == 1 else { return }
        // Asked for on this Mac (analyze again, or a relinked original): this Mac's result becomes the one that syncs.
        try CatalogAsset.filter(key: assetID).updateAll(db, Asset.analysisOrigin.set(to: "local"))
        let job = Job(assetID: assetID, version: version, priority: priority)
        try job.upsert(db)
        try analysisChanged(db)
    }
    public func enqueueAnalysis(assetID: String, version: String, priority: Int = 100) throws {
        try database.write { try Self.enqueueAnalysis($0, assetID: assetID, version: version, priority: priority) }
    }
    public func retryFailedAnalysis() throws {
        try database.write { db in
            let changed = try Job.filter(Job.Columns.state == Job.State.failed || (Job.Columns.state == Job.State.pending && Job.Columns.lastError != nil))
                .updateAll(db, Job.Columns.state.set(to: Job.State.pending), Job.Columns.attempts.set(to: 0), Job.Columns.nextAttempt.set(to: 0), Job.Columns.lastError.set(to: nil))
            if changed > 0 { try Self.analysisChanged(db) }
        }
    }
    /// False while catalog maintenance has paused background work.
    public func analysisEnabled() throws -> Bool {
        try database.read { try CatalogAnalysisControl.fetchOne($0, key: 1)?.enabled == true }
    }
    public func setAnalysisEnabled(_ enabled: Bool) throws {
        _ = try database.write { db in
            try CatalogAnalysisControl.updateAll(db, CatalogAnalysisControl.Columns.enabled.set(to: enabled),
                                                 CatalogAnalysisControl.Columns.generation.set(to: CatalogAnalysisControl.Columns.generation + 1))
        }
    }
    public func analysisJob(assetID: String) throws -> CatalogAnalysisJob? {
        try database.read { try Job.fetchOne($0, key: assetID) }
    }
    public func analysisStatus(now: Date = Date()) throws -> CatalogAnalysisStatus {
        try database.read { db in
            var result = CatalogAnalysisStatus()
            if let control = try CatalogAnalysisControl.fetchOne(db, key: 1) { result.enabled = control.enabled; result.generation = control.generation }
            for row in try Row.fetchAll(db, Job.select(Job.Columns.state, GRDB.count(Job.Columns.assetID).forKey("count")).group(Job.Columns.state)) {
                let count: Int = row["count"]
                switch Job.State(rawValue: row["state"]) {
                case .pending: result.pending = count
                case .running: result.running = count
                case .failed: result.failed = count
                case .complete: result.complete = count
                case nil: break
                }
            }
            let time = now.timeIntervalSince1970
            result.ready = try Job.filter((Job.Columns.state == Job.State.pending && Job.Columns.nextAttempt <= time) || (Job.Columns.state == Job.State.running && Job.Columns.leaseUntil <= time)).fetchCount(db)
            return result
        }
    }
    /// A write transaction is a cross-process claim. Never hold it while hashing or running Vision.
    public func claimAnalysis(owner: String, version: String, now: Date = Date(), leaseSeconds: Double = 300) throws -> CatalogAnalysisClaim? {
        try database.write { db in
            guard try CatalogAnalysisControl.fetchOne(db, key: 1)?.enabled == true else { return nil }
            let time = now.timeIntervalSince1970
            // Leases a dead worker left behind go back in the queue, or fail once the attempts are used up.
            let expired = Job.filter(Job.Columns.state == Job.State.running && Job.Columns.leaseUntil <= time)
            let released: [ColumnAssignment] = [Job.Columns.owner.set(to: nil), Job.Columns.leaseUntil.set(to: nil), Job.Columns.nextAttempt.set(to: time),
                                                 Job.Columns.lastError.set(to: L10n.tr("Worker interrupted; retrying."))]
            let failed = try expired.filter(Job.Columns.attempts >= Job.maximumAttempts).updateAll(db, [Job.Columns.state.set(to: Job.State.failed)] + released)
            let requeued = try expired.filter(Job.Columns.attempts < Job.maximumAttempts).updateAll(db, [Job.Columns.state.set(to: Job.State.pending)] + released)
            if failed + requeued > 0 { try Self.analysisChanged(db) }
            let active = CatalogAsset.filter(Asset.area(.library)).select(Asset.id)
            guard var job = try Job.filter(active.contains(Job.Columns.assetID) && Job.Columns.state == Job.State.pending && Job.Columns.nextAttempt <= time
                                           && (Job.Columns.version == "" || Job.Columns.version == version))
                    .order(Job.Columns.priority.desc, Job.Columns.nextAttempt, Job.Columns.assetID).fetchOne(db),
                  let asset = try CatalogAsset.filter(key: job.assetID)
                    .fetchOne(db) else { return nil }
            job.state = .running; job.version = version; job.attempts += 1; job.owner = owner; job.leaseUntil = time + leaseSeconds
            try job.update(db)
            try Self.analysisChanged(db)
            return CatalogAnalysisClaim(asset: asset, owner: owner, version: version)
        }
    }
    /// Reject work from expired leases, explicit requeues, relinks, and different source identities.
    @discardableResult
    public func finishAnalysis(_ claim: CatalogAnalysisClaim, tags: String, version: String, confidences: [String: Double] = [:], faces: [CatalogFace]? = nil,
                               print: CatalogPrint? = nil, now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard version == claim.version, var job = try Job.fetchOne(db, key: claim.asset.id),
                  job.state == .running, job.owner == claim.owner, job.version == version,
                  (job.leaseUntil ?? 0) > now.timeIntervalSince1970,
                  let source = try CatalogAsset.filter(key: claim.asset.id).filter(Asset.area(.library)).fetchOne(db),
                  source.sourcePath == claim.asset.sourcePath, source.fileSize == claim.asset.fileSize, source.captureTime == claim.asset.captureTime else { return false }
            // Update only machine-owned fields. User metadata, edits, thumbnails and history stay intact.
            try CatalogAsset.filter(key: claim.asset.id).updateAll(db, Asset.suggestedTags.set(to: tags), Asset.analysisVersion.set(to: version), Asset.analyzedAt.set(to: now))
            try CatalogStore.setFaces(faces, assetID: claim.asset.id, db)
            try CatalogStore.setPrint(print, assetID: claim.asset.id, db)
            try CatalogStore.setTagConfidences(confidences, assetID: claim.asset.id, db)
            job.state = .complete; job.owner = nil; job.leaseUntil = nil; job.lastError = nil
            try job.update(db)
            try Self.analysisChanged(db)
            return true
        }
    }
    public func failAnalysis(owner: String, assetID: String? = nil, message: String, interrupted: Bool = false, now: Date = Date()) throws {
        try database.write { db in
            var running = Job.filter(Job.Columns.state == Job.State.running && Job.Columns.owner == owner)
            if let assetID { running = running.filter(Job.Columns.assetID == assetID) }
            for var job in try running.fetchAll(db) {
                // Yielding to the foreground is not an attempt; a timeout or an error is, with growing backoff.
                job.attempts = interrupted ? max(0, job.attempts - 1) : job.attempts
                let delay = interrupted ? 0 : min(3600, 30 * pow(2, Double(max(0, job.attempts - 1))))
                job.release(nextAttempt: now.timeIntervalSince1970 + delay, error: interrupted ? job.lastError : String(message.prefix(1000)))
                try job.update(db)
                try Self.analysisChanged(db)
            }
        }
    }
}
