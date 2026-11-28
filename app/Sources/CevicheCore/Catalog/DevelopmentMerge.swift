import Foundation

/// Three-way merge of a photo's development, as stored (`RevisionPayload.encode`: sparse, sorted-key JSON with mask
/// rasters as blob references). Two devices that edited the same photo from a common `base` keep both sets of
/// changes: a setting changed on one side only takes that side, and a setting both changed differently is a conflict
/// that the `winner` takes. Settings that only make sense together (crop and rotation, white balance) merge as one.
///
/// The merge works on the JSON, not on `Adjustments`, so settings a newer build wrote and this one can't read pass
/// through untouched. It is deterministic and symmetric: swapping `ours` and `theirs` (and the winner with them)
/// gives the same bytes, so two devices merging the same pair independently agree.
public enum DevelopmentMerge {
    public enum Side: Sendable { case ours, theirs }

    public struct Result: Equatable, Sendable {
        /// The merged development, sorted-key JSON.
        public var data: Data
        /// Settings both sides changed differently, by place ("exposure", "masks › Sky › opacity"); the winner's
        /// value was kept. "*" when the whole development was taken from the winner.
        public var conflicts: [String]
    }

    /// How a value merges.
    indirect enum Rule {
        /// Taken whole from one side.
        case atomic
        /// An object merged key by key. `units` are keys that merge together as one setting.
        case fields([String: Rule], units: [[String]] = [], other: Rule = .atomic)
        /// A list of strings merged as a set (sorted).
        case set
        /// A list of objects with an "id", merged item by item.
        case items(Rule)
    }

    /// A mask's own adjustments: each slider on its own, white balance as one.
    static let localAdjustments = Rule.fields([:], units: [["temperature", "tint"]])
    static let rules = Rule.fields([
        "disabledSections": .set,
        "masks": .items(.fields(["adjustments": localAdjustments, "components": .items(.atomic)])),
        "retouch": .items(.atomic),
        "pointColors": .items(.atomic),
    ], units: [
        // The crop is drawn on the rotated photo.
        ["geometry", "quarterTurns"],
        ["temperature", "tint"],
    ])

    /// Merges `ours` and `theirs` against `base`, the last development both sides had. Without a base (one side never
    /// saw the other's) the winner's development is kept whole. `isValid` checks the merged development (for
    /// example that it decodes); one it rejects is replaced by the winner's.
    public static func merge(base: Data?, ours: Data, theirs: Data, winner: Side,
                             isValid: ((Data) -> Bool)? = nil) throws -> Result {
        let oursTree = try object(ours), theirsTree = try object(theirs)
        let winnerData = winner == .ours ? ours : theirs
        if same(oursTree, theirsTree) { return Result(data: try encode(oursTree), conflicts: []) }
        guard let base else { return Result(data: winnerData, conflicts: ["*"]) }
        var conflicts: [String] = []
        let merged = mergeValue(try object(base), oursTree, theirsTree, rule: rules, winner: winner, path: [], conflicts: &conflicts)
        let data = try encode(merged as? [String: Any] ?? [:])
        if let isValid, !isValid(data) { return Result(data: winnerData, conflicts: ["*"]) }
        return Result(data: data, conflicts: conflicts)
    }

    // MARK: - Values

    /// `nil` stands for a value left out (the default, in a sparse development).
    static func mergeValue(_ base: Any?, _ ours: Any?, _ theirs: Any?, rule: Rule, winner: Side, path: [String],
                           conflicts: inout [String]) -> Any? {
        if same(ours, theirs) { return ours }
        if same(ours, base) { return theirs }
        if same(theirs, base) { return ours }
        // Both changed it, differently.
        switch rule {
        case .atomic: break
        case .fields(let children, let units, let other):
            if let b = base as? [String: Any], let o = ours as? [String: Any], let t = theirs as? [String: Any] {
                return mergeFields(b, o, t, children: children, units: units, other: other, winner: winner, path: path, conflicts: &conflicts)
            }
        case .set:
            // A left-out list is empty, and an empty one is left out again.
            if let b = strings(base), let o = strings(ours), let t = strings(theirs) {
                let kept = Set(b).intersection(o).intersection(t), added = Set(o).union(t).subtracting(b)
                let result = kept.union(added).sorted()
                return result.isEmpty ? nil : result
            }
        case .items(let item):
            if let b = items(base), let o = items(ours), let t = items(theirs) {
                let result = mergeItems(b, o, t, rule: item, winner: winner, path: path, conflicts: &conflicts)
                return result.isEmpty ? nil : result
            }
        }
        conflicts.append(label(path))
        return winner == .ours ? ours : theirs
    }

    static func mergeFields(_ base: [String: Any], _ ours: [String: Any], _ theirs: [String: Any], children: [String: Rule], units: [[String]],
                            other: Rule, winner: Side, path: [String], conflicts: inout [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        var done = Set<String>()
        for unit in units {
            func pick(_ tree: [String: Any]) -> [String: Any] { tree.filter { unit.contains($0.key) } }
            let merged = mergeValue(pick(base), pick(ours), pick(theirs), rule: .atomic, winner: winner,
                                    path: path + [unit.joined(separator: " + ")], conflicts: &conflicts) as? [String: Any] ?? [:]
            result.merge(merged) { $1 }
            done.formUnion(unit)
        }
        let keys = Set(base.keys).union(ours.keys).union(theirs.keys).subtracting(done)
        for key in keys.sorted() {
            if let value = mergeValue(base[key], ours[key], theirs[key], rule: children[key] ?? other, winner: winner, path: path + [key], conflicts: &conflicts) {
                result[key] = value
            }
        }
        return result
    }

    /// Items are matched by "id". A removed item stays removed unless the other side changed it (a conflict the
    /// winner settles). New items keep their place after the item they followed; the loser's go in first.
    static func mergeItems(_ base: [[String: Any]], _ ours: [[String: Any]], _ theirs: [[String: Any]], rule: Rule, winner: Side,
                           path: [String], conflicts: inout [String]) -> [[String: Any]] {
        func byID(_ list: [[String: Any]]) -> [String: [String: Any]] {
            Dictionary(list.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
        let b = byID(base), o = byID(ours), t = byID(theirs)
        let ordered = { (list: [[String: Any]]) in list.map(id) }
        // The order of the items that were there before: a side that reordered them wins over one that didn't.
        let kept = Set(b.keys)
        let baseOrder = ordered(base), oursOrder = ordered(ours).filter(kept.contains), theirsOrder = ordered(theirs).filter(kept.contains)
        func filtered(_ order: [String], by other: [String]) -> [String] { let set = Set(other); return order.filter(set.contains) }
        let common = filtered(filtered(baseOrder, by: oursOrder), by: theirsOrder)
        let oursCommon = filtered(oursOrder, by: common), theirsCommon = filtered(theirsOrder, by: common)
        var order: [String]
        if oursCommon == common { order = theirsCommon } else if theirsCommon == common { order = oursCommon } else { order = winner == .ours ? oursCommon : theirsCommon }
        // Items one side removed but the other changed come back where they were.
        var values: [String: [String: Any]] = [:]
        for key in baseOrder {
            let itemPath = path + [itemLabel(b[key] ?? o[key] ?? t[key] ?? [:], key)]
            if let value = mergeValue(b[key], o[key], t[key], rule: rule, winner: winner, path: itemPath, conflicts: &conflicts) as? [String: Any] {
                values[key] = value
                if !order.contains(key) {
                    let before = baseOrder.prefix { $0 != key }.last { order.contains($0) }
                    order.insert(key, at: before.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
                }
            } else { order.removeAll { $0 == key } }
        }
        // New items, the loser's first, each after the item it followed on its own side.
        let sides = winner == .ours ? [theirs, ours] : [ours, theirs]
        var placedEarlier = Set<String>()
        for list in sides {
            var anchor: String?, placed = Set<String>()
            for item in list {
                let key = id(item)
                defer { anchor = key }
                guard b[key] == nil, values[key] == nil else { continue }
                // Both sides may have added the same item (pasted edits).
                guard let value = mergeValue(nil, o[key], t[key], rule: rule, winner: winner, path: path + [itemLabel(item, key)],
                                             conflicts: &conflicts) as? [String: Any] else { continue }
                values[key] = value
                var index = anchor.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } ?? 0
                // After the other side's items that follow the same item, so the winner's, made last, come last.
                while index < order.count, placedEarlier.contains(order[index]) { index += 1 }
                order.insert(key, at: index); placed.insert(key)
            }
            placedEarlier.formUnion(placed)
        }
        return order.compactMap { values[$0] }
    }

    // MARK: - JSON

    static func object(_ data: Data) throws -> [String: Any] {
        guard let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditorError.invalidDocument(L10n.tr("The development could not be read."))
        }
        return tree
    }
    static func encode(_ tree: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]) }
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a as [String: Any], b as [String: Any]):
            // A LUT or profile file is the same file wherever each device keeps it: only its digest counts.
            if let digest = a["digest"] as? String, a["path"] != nil, b["path"] != nil { return digest == b["digest"] as? String }
            return a.count == b.count && a.allSatisfy { same($0.value, b[$0.key]) }
        case let (a as [Any], b as [Any]): return a.count == b.count && zip(a, b).allSatisfy { same($0, $1) }
        case let (a as NSObject, b as NSObject): return a.isEqual(b)
        default: return false
        }
    }
    static func id(_ item: [String: Any]) -> String { item["id"] as? String ?? "" }
    static func strings(_ value: Any?) -> [String]? { value == nil ? [] : value as? [String] }
    /// A list whose every item has an id, or nil (merged whole then). A left-out list is empty.
    static func items(_ value: Any?) -> [[String: Any]]? {
        guard let value else { return [] }
        guard let list = value as? [[String: Any]], list.allSatisfy({ !id($0).isEmpty }), Set(list.map(id)).count == list.count else { return nil }
        return list
    }
    static func itemLabel(_ item: [String: Any], _ id: String) -> String {
        if let name = item["name"] as? String, !name.isEmpty { return name }
        return String(id.prefix(8))
    }
    static func label(_ path: [String]) -> String { path.isEmpty ? "*" : path.joined(separator: " › ") }
}

extension CatalogSyncState {
    /// Three-way merge of a photo's state, field by field: keywords as a set, the location and where the original
    /// lives each as one. Fields both sides changed differently take the winner's and are listed.
    public static func merged(base: CatalogSyncState, ours: CatalogSyncState, theirs: CatalogSyncState,
                              winner: DevelopmentMerge.Side) -> (state: CatalogSyncState, conflicts: [String]) {
        var conflicts: [String] = []
        func pick<T: Equatable>(_ name: String, _ path: KeyPath<CatalogSyncState, T>) -> T {
            let b = base[keyPath: path], o = ours[keyPath: path], t = theirs[keyPath: path]
            if o == t || t == b { return o }
            if o == b { return t }
            conflicts.append(name)
            return winner == .ours ? o : t
        }
        var result = winner == .ours ? ours : theirs
        result.metadata.title = pick("title", \.metadata.title)
        result.metadata.caption = pick("caption", \.metadata.caption)
        result.metadata.rating = pick("rating", \.metadata.rating)
        result.metadata.review = pick("review", \.metadata.review)
        result.metadata.label = pick("label", \.metadata.label)
        result.metadata.captureDay = pick("captureDay", \.metadata.captureDay)
        let location = pick("location", \.location)
        result.metadata.latitude = location.latitude; result.metadata.longitude = location.longitude; result.metadata.locationSource = location.source
        result.trashedAt = pick("trashedAt", \.trashedAt)
        result.archivedAt = pick("archivedAt", \.archivedAt)
        result.stackID = pick("stackID", \.stackID)
        let original = pick("origin", \.originUnit)
        result.origin = original.origin; result.isCopy = original.isCopy
        // Keywords: each one added or removed on either side, in the winner's order, then the loser's additions.
        let b = base.metadata.keywordList, o = ours.metadata.keywordList, t = theirs.metadata.keywordList
        if o != t {
            let removed = Set(b).subtracting(o).union(Set(b).subtracting(t))
            let first = winner == .ours ? o : t, second = winner == .ours ? t : o
            var list = first.filter { !removed.contains($0) }
            for keyword in second where !removed.contains(keyword) && !list.contains(keyword) { list.append(keyword) }
            result.metadata.keywords = list.joined(separator: ", ")
        }
        result.updatedAt = max(ours.updatedAt, theirs.updatedAt)
        return (result, conflicts)
    }
    struct Location: Equatable { var latitude: Double?, longitude: Double?, source: CatalogLocationSource? }
    var location: Location { Location(latitude: metadata.latitude, longitude: metadata.longitude, source: metadata.locationSource) }
    struct OriginUnit: Equatable { var origin: String, isCopy: Bool }
    var originUnit: OriginUnit { OriginUnit(origin: origin, isCopy: isCopy) }
}
