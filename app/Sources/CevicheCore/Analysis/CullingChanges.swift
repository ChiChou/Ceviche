import Foundation

/// What a culling tool writes to the catalog when applied: flags, set on both files of a RAW + JPEG shot, and bursts put
/// in groups under their covers. Ratings, edits and files stay as they are.
public struct CullingChanges: Sendable {
    public struct Group: Equatable, Sendable {
        public var members: [String]
        public var cover: String
        public init(members: [String], cover: String) { self.members = members; self.cover = cover }
    }
    /// The new flag of every photo, the RAW behind each shown JPEG included.
    public let flags: [String: ReviewState]
    public let groups: [Group]

    /// `partners` maps the JPEG that stands for a RAW + JPEG shot to the RAW behind it, which gets the same flag.
    public init(flags: [String: ReviewState], partners: [String: String] = [:], groups: [Group] = []) {
        var all = flags
        for (shown, state) in flags { if let partner = partners[shown] { all[partner] = state } }
        self.flags = all; self.groups = groups
    }
    public var isEmpty: Bool { flags.isEmpty && groups.isEmpty }
    /// The flags in one write per flag: rejections first, then picks, then flags cleared.
    public var batches: [(review: ReviewState, ids: [String])] {
        [ReviewState.rejected, .accepted, .unreviewed].compactMap { state in
            let ids = flags.filter { $0.value == state }.map(\.key).sorted()
            return ids.isEmpty ? nil : (state, ids)
        }
    }
}

/// What applying `CullingChanges` did, for the app to report it and make it undoable.
public struct CullingOutcome {
    /// Each photo's metadata before its flag changed; photos already flagged so are left out.
    public var previous: [String: CatalogMetadata] = [:]
    /// The flags that changed.
    public var applied: [String: ReviewState] = [:]
    /// Groups made.
    public var grouped = 0
    /// The grouped photos' groups before and after, for Undo and Redo; empty when nothing was grouped.
    public var stacksBefore: [String: String?] = [:]
    public var stacksAfter: [String: String?] = [:]
    public var flagErrors: [Error] = []
    public var groupErrors: [Error] = []
    public var changed: Bool { !previous.isEmpty || grouped > 0 }
}

extension CatalogStore {
    /// Writes the culling tools' flags and groups. A step that fails is reported; the others still apply. When the
    /// grouped photos' groups can't be read first, nothing is grouped, since it couldn't be undone.
    public func applyCulling(_ changes: CullingChanges) -> CullingOutcome {
        var outcome = CullingOutcome()
        for batch in changes.batches {
            do { outcome.previous.merge(try updateQuickMetadata(assetIDs: batch.ids, review: batch.review)) { first, _ in first } }
            catch { outcome.flagErrors.append(error) }
        }
        outcome.applied = changes.flags.filter { outcome.previous[$0.key] != nil }
        let grouping = changes.groups.flatMap(\.members)
        guard !grouping.isEmpty else { return outcome }
        do { outcome.stacksBefore = try stackState(grouping) } catch { outcome.groupErrors.append(error); return outcome }
        for group in changes.groups {
            do { if try stack(group.members, cover: group.cover) != nil { outcome.grouped += 1 } }
            catch { outcome.groupErrors.append(error) }
        }
        outcome.stacksAfter = (try? stackState(grouping)) ?? [:]
        return outcome
    }
}

extension RawJPEGPairs {
    /// The photos with each RAW + JPEG pair as one shot, stood for by its JPEG, and the RAW behind each such JPEG; nil
    /// when there are no pairs.
    public static func shots(_ assets: [CatalogAsset]) -> (assets: [CatalogAsset], partners: [String: String])? {
        let pairs = pairs(assets)
        guard !pairs.isEmpty else { return nil }
        let hidden = Set(pairs.map(\.raw.id))
        return (assets.filter { !hidden.contains($0.id) }, Dictionary(pairs.map { ($0.processed.id, $0.raw.id) }, uniquingKeysWith: { first, _ in first }))
    }
}

extension CullingIssue {
    /// A frame of a burst not kept, rather than a fault of the photo itself.
    public var inBurst: Bool { self == .burstAlternate || self == .duplicate }
    /// The problems Find Flawed Photos looks for; a burst's alternate is Pick from Bursts' business.
    public static let flaws = allCases.filter { !$0.inBurst }
}

/// Which photos Find Flawed Photos rejects: the ones left ticked. A photo the person picked starts unticked, so their
/// pick stands unless they tick it.
public struct FlawTicks: Equatable, Sendable {
    /// Photos the person unticked: they keep their flag.
    public private(set) var excluded: Set<String> = []
    /// Photos the person had picked and then ticked.
    public private(set) var overridden: Set<String> = []
    public init() {}

    public func isIncluded(_ id: String, current: ReviewState) -> Bool { current == .accepted ? overridden.contains(id) : !excluded.contains(id) }
    public mutating func toggle(_ id: String, current: ReviewState) {
        switch (isIncluded(id, current: current), current == .accepted) {
        case (true, true): overridden.remove(id)
        case (true, false): excluded.insert(id)
        case (false, true): overridden.insert(id)
        case (false, false): excluded.remove(id)
        }
    }
    /// Ticks or unticks every photo `found`.
    public mutating func setAll(_ included: Bool, _ found: [CatalogAsset]) {
        excluded = included ? [] : Set(found.map(\.id))
        overridden = included ? Set(found.filter { $0.review == .accepted }.map(\.id)) : []
    }
    /// The photos `found` that are ticked and not rejected already.
    public func toReject(_ found: [CatalogAsset]) -> [String] {
        found.filter { isIncluded($0.id, current: $0.review) && $0.review != .rejected }.map(\.id)
    }
}
