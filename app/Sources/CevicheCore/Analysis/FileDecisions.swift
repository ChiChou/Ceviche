import Foundation

/// What a housekeeping tool decided about a set of photos, applied in one go when its view is confirmed: photos
/// archived, and flags, ratings and labels set. No file is moved or deleted; archived photos wait in the Archived view,
/// rejected ones for Trash Rejected. Tidy RAW + JPEG Pairs builds one per pair (`TidyPairsPlan`).
public struct FileDecisions: Sendable {
    public struct Change: Equatable, Sendable {
        public var review: ReviewState?
        public var rating: Int?
        public var label: CatalogLabel??
        public init(review: ReviewState? = nil, rating: Int? = nil, label: CatalogLabel?? = nil) { self.review = review; self.rating = rating; self.label = label }
    }
    /// Photos that leave the library for the archive.
    public var archive: [CatalogAsset] = []
    /// Per photo ID, what to set.
    public var changes: [String: Change] = [:]
    public init() {}

    public var isEmpty: Bool { archive.isEmpty && changes.isEmpty }
    public mutating func set(_ id: String, review: ReviewState) { changes[id, default: Change()].review = review }
}

/// What applying `FileDecisions` did, for the app to report it and make it undoable.
public struct FileDecisionsOutcome {
    /// The photos archived.
    public var archived: [String] = []
    /// Each changed photo's metadata before.
    public var previous: [String: CatalogMetadata] = [:]
    /// The changes that went through.
    public var applied: [String: FileDecisions.Change] = [:]
    public var errors: [Error] = []
    public var rejected: Int { applied.values.count { $0.review == .rejected } }
    public var picked: Int { applied.values.count { $0.review == .accepted } }
}

extension CatalogStore {
    /// Archives and sets flags, ratings and labels; a photo that fails is reported and the others still apply.
    public func apply(_ decisions: FileDecisions) -> FileDecisionsOutcome {
        var outcome = FileDecisionsOutcome()
        do { if !decisions.archive.isEmpty { outcome.archived = try archive(decisions.archive.map(\.id)) } }
        catch { outcome.errors.append(error) }
        for (id, change) in decisions.changes {
            do { outcome.previous.merge(try updateQuickMetadata(assetIDs: [id], rating: change.rating, review: change.review, label: change.label)) { first, _ in first } }
            catch { outcome.errors.append(error) }
        }
        outcome.applied = decisions.changes.filter { outcome.previous[$0.key] != nil }
        return outcome
    }
}

/// What Tidy RAW + JPEG Pairs' Apply does with each pair's decision: archived JPEGs leave the library for Archived, the
/// other files are picked or rejected (a kept JPEG stays to be developed). A file picked takes over the stars and label
/// of the other, so they aren't lost with it.
public struct TidyPairsPlan: Sendable {
    public var decisions = FileDecisions()
    public var archived = 0, picked = 0, rejectedFiles = 0
    /// The size of the files newly rejected.
    public var rejectedBytes: Int64 = 0
    public var isEmpty: Bool { decisions.isEmpty }

    public init(_ pairs: [(raw: CatalogAsset, processed: CatalogAsset, decision: PairDecision)]) {
        for pair in pairs {
            switch pair.decision {
            case .undecided: break
            case .archiveJPEG:
                decisions.archive.append(pair.processed); archived += 1
                reject(pair.raw)
            case .keepJPEG:
                pick(pair.processed, over: pair.raw)
                reject(pair.raw)
            case .keepRAW:
                pick(pair.raw, over: pair.processed)
                reject(pair.processed)
            case .rejectBoth:
                reject(pair.raw); reject(pair.processed)
            }
        }
    }
    private mutating func reject(_ asset: CatalogAsset) {
        decisions.set(asset.id, review: .rejected)
        if asset.review != .rejected { rejectedFiles += 1; rejectedBytes += asset.fileSize ?? 0 }
    }
    private mutating func pick(_ kept: CatalogAsset, over other: CatalogAsset) {
        var change = FileDecisions.Change(review: .accepted)
        if kept.rating == 0, other.rating > 0 { change.rating = other.rating }
        if kept.label == nil, let label = other.label { change.label = .some(label) }
        if kept.review != .accepted || change.rating != nil || change.label != nil { decisions.changes[kept.id] = change; picked += 1 }
    }
}
