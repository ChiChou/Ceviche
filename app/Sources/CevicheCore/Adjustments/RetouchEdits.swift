import Foundation

/// Retouch's decisions both apps share: room in the stroke list, which strokes wait for an AI fill, the sources Refresh
/// moves away from, and turning reviewed dust spots into strokes. The apps keep the tasks and what is on screen.
extension Adjustments {
    /// How many more strokes the retouch list takes.
    public var retouchRoom: Int { max(0, DustFinder.strokeLimit - retouch.count) }
    /// As many of `strokes` as the retouch list has room for, first ones first.
    public func fittingRetouch(_ strokes: [RetouchStroke]) -> [RetouchStroke] { Array(strokes.prefix(retouchRoom)) }

    // MARK: AI fill

    /// Puts a fill made for stroke `id` on it, while the stroke still asks for one and has the footprint it was made for.
    public mutating func placeFill(_ fill: RetouchFill, on id: UUID) {
        for i in retouch.indices where retouch[i].id == id && retouch[i].needsFill && RetouchFill.footprint(of: retouch[i]) == fill.footprint {
            retouch[i].fill = fill
        }
    }
    /// Remove strokes `ids` ask for an AI fill, or (off) drop theirs and use a patch.
    public mutating func setGenerative(_ on: Bool, _ ids: Set<UUID>) {
        for i in retouch.indices where ids.contains(retouch[i].id) && retouch[i].mode == .remove {
            retouch[i].generative = on; if !on { retouch[i].fill = nil }
        }
    }
    /// Fills cancelled while waiting: those strokes use a patch, so Undo asks for their fills again.
    public mutating func patchInstead(_ ids: Set<UUID>) {
        for i in retouch.indices where ids.contains(retouch[i].id) { retouch[i].generative = false }
    }
    /// Drops the fills of `ids`, for others to be made.
    public mutating func dropFills(_ ids: Set<UUID>) {
        for i in retouch.indices where ids.contains(retouch[i].id) { retouch[i].fill = nil }
    }

    // MARK: Sources

    /// Lands sources and Dodge/Burn depths chosen meanwhile: a depth on a stroke that has not changed since, a source
    /// on one whose fill type, source, path and size are as they were. A stroke changed meanwhile keeps what it has.
    public mutating func apply(_ choice: RetouchSourceChoice) {
        for stroke in choice.strokes {
            if let ev = choice.exposures[stroke.id], let i = retouch.firstIndex(where: { $0 == stroke }) { retouch[i].exposure = ev }
            if let source = choice.sources[stroke.id],
               let i = retouch.firstIndex(where: { $0.id == stroke.id && $0.mode == stroke.mode && $0.source == stroke.source && $0.points == stroke.points && $0.radius == stroke.radius }) {
                retouch[i].source = source
            }
        }
    }
}

/// The strokes waiting for an AI fill, and what each has been through: why a fill could not be made (by stroke and
/// footprint, so it is not tried again until the stroke changes) and how many times another was asked for, each one
/// made from other windows around the stroke.
public struct RetouchFillQueue: Equatable, Sendable {
    /// Strokes waiting, in the order they were queued.
    public private(set) var pending: [UUID] = []
    public private(set) var failures: [String: String] = [:]
    public private(set) var variants: [UUID: Int] = [:]
    public init() {}

    static func key(_ stroke: RetouchStroke) -> String { "\(stroke.id) \(RetouchFill.footprint(of: stroke))" }
    /// Why the stroke has no AI fill, when one was tried for its current footprint and could not be made.
    public func failure(for stroke: RetouchStroke) -> String? { stroke.needsFill ? failures[Self.key(stroke)] : nil }
    public func variant(_ id: UUID) -> Int { variants[id] ?? 0 }
    public var isEmpty: Bool { pending.isEmpty }
    public func contains(_ id: UUID) -> Bool { pending.contains(id) }

    /// Queues every stroke that asks for an AI fill and has none for its footprint, unless one already failed there.
    /// True when something waits.
    @discardableResult public mutating func schedule(_ strokes: [RetouchStroke]) -> Bool {
        guard strokes.contains(where: \.generative) else { return false }
        for stroke in strokes where stroke.needsFill && !pending.contains(stroke.id) && failures[Self.key(stroke)] == nil {
            pending.append(stroke.id)
        }
        return !pending.isEmpty
    }
    /// The next fill to make: the first stroke waiting in stroke order, so a later stroke's fill sees the earlier ones.
    public func next(in strokes: [RetouchStroke]) -> RetouchStroke? { strokes.first { pending.contains($0.id) } }
    public mutating func finish(_ id: UUID) { pending.removeAll { $0 == id } }
    public mutating func fail(_ stroke: RetouchStroke, _ reason: String) { failures[Self.key(stroke)] = reason }
    /// Strokes removed, or no longer asking for a fill: a fill already being made is dropped when it lands.
    public mutating func drop(_ ids: Set<UUID>) { pending.removeAll { ids.contains($0) } }
    /// Fills asked for again (AI fill turned back on): the failures of every footprint are forgotten.
    public mutating func forgetFailures(_ ids: Set<UUID>) {
        let prefixes = ids.map { $0.uuidString + " " }
        failures = failures.filter { key, _ in !prefixes.contains { key.hasPrefix($0) } }
    }
    /// Refresh: another fill for each, from other windows; the stroke's fill is dropped (`Adjustments.dropFills`).
    public mutating func refresh(_ ids: Set<UUID>) {
        for id in ids { variants[id, default: 0] += 1 }
        forgetFailures(ids)
    }
    /// Refresh on `strokes`: those with an AI fill to make again, and the others, which take another source.
    public static func refreshing(_ strokes: [RetouchStroke], fillAvailable: Bool) -> (fills: Set<UUID>, sources: Set<UUID>) {
        let fills = fillAvailable ? Set(strokes.filter { $0.mode == .remove && $0.generative }.map(\.id)) : []
        return (fills, Set(strokes.map(\.id)).subtracting(fills))
    }
    /// Stops waiting; returns the strokes that were.
    @discardableResult public mutating func cancel() -> Set<UUID> {
        defer { pending = [] }
        return Set(pending)
    }
    /// Another photo: nothing waits and nothing is remembered.
    public mutating func reset() { self = Self() }
}

/// The sources each stroke has had and Refresh moved away from, so it does not come back to them.
public struct RetouchSourceHistory: Equatable, Sendable {
    public private(set) var refused: [UUID: [MaskPoint]] = [:]
    public init() {}
    /// Before sources are chosen for `strokes`: Refresh refuses each one's current source as well; otherwise (painted,
    /// moved, resized) the stroke starts afresh. Returns what those strokes refuse.
    public mutating func choosing(_ strokes: [RetouchStroke], refresh: Bool) -> [UUID: [MaskPoint]] {
        for stroke in strokes {
            if refresh { refused[stroke.id, default: []].append(stroke.source) } else { refused[stroke.id] = nil }
        }
        let ids = Set(strokes.map(\.id))
        return refused.filter { ids.contains($0.key) }
    }
    public mutating func reset() { refused = [:] }
}

/// Sources for patch strokes and depths for Dodge/Burn ones, chosen from one look at the photo for `strokes` as they
/// were; `Adjustments.apply` lands them.
public struct RetouchSourceChoice: Sendable {
    public let strokes: [RetouchStroke]
    public let sources: [UUID: MaskPoint]
    public let exposures: [UUID: Double]
}

extension RawRenderer {
    /// Sources (and Dodge/Burn depths) for `strokes` on the photo as developed, away from what each `refused`.
    public func retouchSourceChoice(for strokes: [RetouchStroke], settings: Adjustments, refused: [UUID: [MaskPoint]]) throws -> RetouchSourceChoice {
        let tonal = strokes.filter { $0.mode == .tone }, patches = strokes.filter { $0.mode != .tone }
        let exposures = try spotExposures(for: tonal, settings: settings)
        let sources = patches.isEmpty ? [:] : try retouchSources(for: patches, settings: settings, refused: refused)
        return RetouchSourceChoice(strokes: strokes, sources: sources, exposures: exposures)
    }
}

/// Reviewed dust spots made into strokes, and spots moved on the photo.
public enum DustRepair {
    /// A spot's or healed spot's centre, kept on the photo.
    public static func clamped(_ center: MaskPoint) -> MaskPoint { MaskPoint(x: min(1, max(0, center.x)), y: min(1, max(0, center.y))) }
    /// A spot's radius, within a brush's sizes.
    public static func clamped(radius: Double) -> Double { min(0.15, max(0.001, radius)) }
    /// The spots one repair turns into strokes: those `selected` (nil: all) as far as `room` goes, and how many of
    /// them were left out.
    public static func batch(_ spots: [DustSpot], selected: Set<UUID>? = nil, room: Int) -> (spots: [DustSpot], skipped: Int) {
        let wanted = spots.filter { selected?.contains($0.id) ?? true }
        let taken = Array(wanted.prefix(max(0, room)))
        return (taken, wanted.count - taken.count)
    }
    /// The strokes made for `spots` that join the edit: for spots still under review (`current`; ones removed meanwhile
    /// stay removed), as far as `room` goes now, since strokes added meanwhile take room first.
    public static func accepted(_ spots: [DustSpot], strokes: [RetouchStroke], current: [DustSpot], room: Int) -> [(spot: DustSpot, stroke: RetouchStroke)] {
        let ids = Set(current.map(\.id))
        return Array(zip(spots, strokes).filter { ids.contains($0.0.id) }.prefix(max(0, room))).map { (spot: $0.0, stroke: $0.1) }
    }
}

extension DustSpot {
    /// Moves or resizes a spot under review.
    public mutating func move(to center: MaskPoint? = nil, radius: Double? = nil) {
        if let center { self.center = DustRepair.clamped(center) }
        if let radius { self.radius = DustRepair.clamped(radius: radius) }
    }
}

extension RetouchStroke {
    /// Moves or resizes a healed dust spot's stroke. A Dodge/Burn spot keeps its source on its centre, where it is made
    /// (`RawRenderer.dustStrokes`): rendering never reads it, but a spot switched to Heal then patches from where it
    /// is, not from where it once was, until its own source is chosen.
    public mutating func moveDustSpot(to center: MaskPoint? = nil, radius: Double? = nil) {
        if let center {
            let center = DustRepair.clamped(center)
            points = [center]
            if mode == .tone { source = center }
        }
        if let radius { self.radius = DustRepair.clamped(radius: radius) }
    }
}
