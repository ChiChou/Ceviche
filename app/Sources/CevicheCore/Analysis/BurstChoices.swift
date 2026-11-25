import Foundation

/// What Pick from Bursts will do: the bursts it found (`CullingPlan`) and the person's choices on them. Each burst gets
/// an action: Pick proposes Pick and Reject for its frames, Group puts it in a group under a cover and leaves its flags
/// alone, Skip leaves it as it is. Choices are kept by frame, so they hold when the bursts are found again as photos
/// land or the options change. Nothing changes in the catalog until `changes` and `groupChanges` are applied.
public struct BurstChoices: Sendable {
    /// What Apply does with a burst: flag its frames, group it under its cover, or leave it.
    public enum Action: Hashable, Sendable { case pick, group, skip }

    /// The photos in scope, in capture order.
    public let photos: [String]
    /// Each photo's flag now.
    public let flags: [String: ReviewState]
    /// For each RAW + JPEG pair, the JPEG that stands for the shot and the RAW behind it.
    public let partners: [String: String]
    /// The group of every photo in scope that is in one, the RAWs behind `partners` included.
    public let stacks: [String: String]
    /// The photos are one group the person made: its one burst is always picked from.
    public let oneBurst: Bool
    public private(set) var plan = CullingPlan([], options: CullingPlan.Options())
    /// The person's own flags; `unreviewed` means leave the photo's flag as it is.
    public private(set) var overrides: [String: ReviewState] = [:]
    /// The action of every burst the person didn't set on its own: Pick, unless Group All or Skip All was chosen. A
    /// timelapse is grouped instead of picked from: its frames are all kept, and one picked would reject the rest.
    public private(set) var defaultAction = Action.pick
    /// The person's action for single bursts, by frame.
    public private(set) var actions: [String: Action] = [:]
    /// Frames the person made the cover of their burst.
    public private(set) var chosenCovers: Set<String> = []
    /// Every frame of every burst.
    public private(set) var burstMembers: Set<String> = []
    private var burstOf: [String: CullingPlan.Burst] = [:]

    public init(photos: [CatalogAsset], partners: [String: String] = [:], stacks: [String: String] = [:], oneBurst: Bool = false) {
        self.photos = photos.map(\.id)
        flags = Dictionary(photos.map { ($0.id, $0.review) }, uniquingKeysWith: { first, _ in first })
        self.partners = partners; self.stacks = stacks; self.oneBurst = oneBurst
    }

    /// The bursts found again; the person's choices carry over by frame.
    public mutating func update(_ plan: CullingPlan) {
        self.plan = plan
        burstMembers = Set(plan.bursts.flatMap(\.members))
        burstOf = Dictionary(plan.bursts.flatMap { burst in burst.members.map { ($0, burst) } }, uniquingKeysWith: { first, _ in first })
    }
    public func burst(of id: String) -> CullingPlan.Burst? { burstOf[id] }

    // MARK: Flags
    public func current(_ id: String) -> ReviewState { flags[id] ?? .unreviewed }
    /// The flag the photo will have after Apply: the person's choice, else the proposal for frames of a burst. A burst
    /// to group or skip keeps its flags.
    public func flag(_ id: String) -> ReviewState {
        if let burst = burstOf[id], action(burst) != .pick { return current(id) }
        let decision = overrides[id] ?? (burstMembers.contains(id) ? plan.proposals[id] ?? .unreviewed : .unreviewed)
        return decision == .unreviewed ? current(id) : decision
    }
    /// Flagging a frame makes its burst one to pick from.
    public mutating func set(_ id: String, _ state: ReviewState) {
        if let burst = burstOf[id], action(burst) != .pick { setAction(burst, .pick) }
        overrides[id] = state
    }
    /// Picks this frame of its burst and rejects the others.
    public mutating func keepOnly(_ id: String) {
        guard let burst = burstOf[id] else { return }
        setAction(burst, .pick)
        for member in burst.members { overrides[member] = member == id ? .accepted : .rejected }
    }

    // MARK: Actions
    public func action(_ burst: CullingPlan.Burst) -> Action {
        if oneBurst { return .pick }
        return burst.members.lazy.compactMap { self.actions[$0] }.first ?? (burst.series != nil && defaultAction == .pick ? .group : defaultAction)
    }
    /// Group All and Skip All: every burst, also those found later.
    public mutating func setAll(_ action: Action) { actions = [:]; defaultAction = action }
    public mutating func setAction(_ burst: CullingPlan.Burst, _ action: Action) { for member in burst.members { actions[member] = action } }
    /// The frame the burst's group shows: the one the person chose, else the best.
    public func cover(of burst: CullingPlan.Burst) -> String { burst.members.first { chosenCovers.contains($0) } ?? burst.best }
    /// Makes the frame the cover of its burst, which is then grouped.
    public mutating func makeCover(_ id: String) {
        guard let burst = burstOf[id] else { return }
        chosenCovers.subtract(burst.members); chosenCovers.insert(id)
        setAction(burst, .group)
    }

    // MARK: Apply
    /// Already exactly one group under its cover, both files of each RAW + JPEG shot included.
    public func isGrouped(_ burst: CullingPlan.Burst) -> Bool {
        let members = Set(files(burst)), cover = cover(of: burst), group = partners[cover] ?? cover
        return members.allSatisfy { stacks[$0] == group } && stacks.allSatisfy { $0.value != group || members.contains($0.key) }
    }
    private func files(_ burst: CullingPlan.Burst) -> [String] { burst.members.flatMap { [$0] + (partners[$0].map { [$0] } ?? []) } }
    /// The bursts Apply groups, both files of a RAW + JPEG shot, under the cover (the RAW of a pair).
    public var groupChanges: [CullingChanges.Group] {
        plan.bursts.filter { action($0) == .group && !isGrouped($0) }.map { burst in
            let cover = cover(of: burst)
            return CullingChanges.Group(members: files(burst), cover: partners[cover] ?? cover)
        }
    }
    /// Every photo whose flag Apply would change, with its new flag.
    public var changes: [String: ReviewState] {
        var result: [String: ReviewState] = [:]
        for id in photos where flag(id) != current(id) { result[id] = flag(id) }
        return result
    }
}
