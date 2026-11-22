import Foundation

extension Adjustments {
    /// The development a preset gives at `amount` (0…1) of its strength, where `self` is the photo before the preset and
    /// `target` after it at full strength. Every setting the preset changed moves that share of the way: numbers in
    /// proportion, tone curves through their shape, and switches and choices at half. A camera profile or LUT the preset
    /// adds comes in at that share of its own amount. Geometry, masks, retouching and the output profile, which presets
    /// never carry, stay as they are.
    public func blended(toward target: Adjustments, amount: Double) throws -> Adjustments {
        guard amount.isFinite, amount < 1 else { return target }
        guard amount > 0, self != target else { return self }
        let encoder = JSONEncoder()
        guard let before = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any],
              let after = try JSONSerialization.jsonObject(with: encoder.encode(target)) as? [String: Any] else { throw EditorError.render }
        let kept: Set<String> = ["geometry", "masks", "retouch", "quarterTurns", "colorProfile", "cameraProfile", "lut", "look"]
        var mixed = before
        for (key, value) in after where !kept.contains(key) { mixed[key] = PresetStrength.mix(before[key], value, amount) }
        // Curves keep their own shape between their points, so they are mixed as curves rather than point lists.
        for curve in [("curve", \Adjustments.curve), ("redCurve", \.redCurve), ("greenCurve", \.greenCurve), ("blueCurve", \.blueCurve)] where self[keyPath: curve.1] != target[keyPath: curve.1] {
            mixed[curve.0] = try JSONSerialization.jsonObject(with: encoder.encode(PresetStrength.mix(self[keyPath: curve.1], target[keyPath: curve.1], amount)))
        }
        var result = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: mixed))
        result.geometry = geometry; result.masks = masks; result.retouch = retouch; result.quarterTurns = quarterTurns; result.colorProfile = colorProfile
        result.cameraProfile = PresetStrength.mix(cameraProfile, target.cameraProfile, amount, \.amount)
        result.lut = PresetStrength.mix(lut, target.lut, amount, \.amount)
        result.look = PresetStrength.mix(look, target.look, amount, \.amount)
        return result
    }
}

enum PresetStrength {
    /// Two JSON values `amount` of the way from `a` to `b`: numbers in proportion, objects and equal-length arrays member
    /// by member, anything else (switches, choices, lists of another length, a value one side lacks) at half.
    static func mix(_ a: Any?, _ b: Any?, _ amount: Double) -> Any? {
        switch (a, b) {
        case let (x as NSNumber, y as NSNumber) where !isBool(x) && !isBool(y):
            if x == y { return x }
            return x.doubleValue + (y.doubleValue - x.doubleValue) * amount
        case let (x as [String: Any], y as [String: Any]):
            var result = x
            for key in Set(x.keys).union(y.keys) { result[key] = mix(x[key], y[key], amount) }
            return result
        case let (x as [Any], y as [Any]) where x.count == y.count:
            return zip(x, y).map { mix($0, $1, amount) as Any }
        default:
            return amount < 0.5 ? a : b
        }
    }
    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// A curve through both curves' points, each output `amount` of the way from `a`'s to `b`'s.
    static func mix(_ a: ToneCurve, _ b: ToneCurve, _ amount: Double) -> ToneCurve {
        var inputs: [Double] = []
        for x in (a.points + b.points).map(\.x).sorted() where inputs.last.map({ x - $0 >= ToneCurve.minimumSpacing }) ?? true { inputs.append(x) }
        if !inputs.contains(1) { inputs = inputs.filter { abs($0 - 1) >= ToneCurve.minimumSpacing } + [1]; inputs.sort() }
        return ToneCurve(points: inputs.map { x in
            let range = ToneCurve.outputRange(forInput: x), y = a.value(at: x) + (b.value(at: x) - a.value(at: x)) * amount
            return CurvePoint(x: x, y: min(range.upperBound, max(range.lowerBound, y)))
        })
    }

    /// A camera profile or LUT: the preset's comes in at `amount` of its own amount where the photo had none, the same one
    /// changes its amount in proportion, and another one replaces it at half.
    static func mix<Look: Equatable>(_ a: Look?, _ b: Look?, _ amount: Double, _ strength: WritableKeyPath<Look, Double>) -> Look? {
        guard a != b else { return a }
        switch (a, b) {
        case (nil, var added?): added[keyPath: strength] *= amount; return added
        case (var kept?, nil): kept[keyPath: strength] *= 1 - amount; return kept
        case (let x?, var y?):
            var same = x; same[keyPath: strength] = y[keyPath: strength]
            guard same == y else { return amount < 0.5 ? x : y }
            y[keyPath: strength] = x[keyPath: strength] + (y[keyPath: strength] - x[keyPath: strength]) * amount
            return y
        default: return nil
        }
    }
}
