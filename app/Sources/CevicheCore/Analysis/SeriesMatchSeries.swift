import Foundation

/// Where one photo of Match Series stands.
public enum SeriesMatchOutcome: Sendable {
    case waiting, matching, matched(SeriesMatchResult), failed(String)
}

/// One photo of a series being matched: its original, its edits and what matching it gave.
public struct SeriesMatchPhoto: Identifiable, Sendable {
    public let asset: CatalogAsset
    public var url: URL?
    /// Its saved edits, and the defaults.
    public var saved: Adjustments?
    public var defaults: Adjustments?
    public var outcome = SeriesMatchOutcome.waiting
    public var prefer = SeriesMatchPreference.automatic
    /// False leaves the photo as it is.
    public var included = true

    public init(asset: CatalogAsset) { self.asset = asset }

    public var id: String { asset.id }
    /// The edits it develops with now: the saved ones, else the defaults.
    public var edits: Adjustments? { saved ?? defaults }
    /// Its Exposure, Temperature and Tint now.
    public var current: SeriesMatchValues? {
        guard let defaults else { return nil }
        let effective = (saved ?? defaults).effective(defaults: defaults)
        return SeriesMatchValues(exposure: effective.exposure, temperature: effective.temperature, tint: effective.tint)
    }
    public var result: SeriesMatchResult? { if case .matched(let result) = outcome { return result }; return nil }
    /// Its original and its values are read, so it can be matched or be the reference.
    public var readable: Bool { url != nil && current != nil }
}

extension SeriesMatchValues {
    /// Sets Exposure, and Temperature with Tint, in `settings` as asked, leaving the rest of its edits.
    public func apply(to settings: inout Adjustments, exposure: Bool, whiteBalance: Bool) {
        if exposure { settings.exposure = self.exposure }
        if whiteBalance { settings.temperature = temperature; settings.tint = tint }
    }

    /// Whether setting these values changes a photo that has `current`, by more than the sliders show.
    public func differs(from current: SeriesMatchValues, exposure: Bool, whiteBalance: Bool) -> Bool {
        (exposure && abs(self.exposure - current.exposure) >= 0.005)
            || (whiteBalance && (abs(temperature - current.temperature) >= 1 || abs(tint - current.tint) >= 0.5))
    }
}

/// Match Series' photos and the one they are matched to: which photos change and to what, and which to match next.
/// The apps hold one and run the matcher; every decision is here.
public struct SeriesMatchSeries: Sendable {
    /// In capture order.
    public var photos: [SeriesMatchPhoto]
    public private(set) var reference: Int

    public init(_ assets: [CatalogAsset], reference: Int = 0) {
        photos = assets.map(SeriesMatchPhoto.init)
        self.reference = assets.indices.contains(reference) ? reference : 0
    }

    /// The values to write, by photo: matched, included, and different from what the photo has.
    public func changes(exposure: Bool, whiteBalance: Bool) -> [String: SeriesMatchValues] {
        var changes: [String: SeriesMatchValues] = [:]
        for (index, photo) in photos.enumerated() where index != reference && photo.included {
            guard let result = photo.result, result.method != .unmatched, let current = photo.current else { continue }
            if result.values.differs(from: current, exposure: exposure, whiteBalance: whiteBalance) { changes[photo.id] = result.values }
        }
        return changes
    }

    /// Whether a photo other than the reference is still to be matched; the reference itself is never matched.
    public var matching: Bool {
        photos.indices.contains { index in
            guard index != reference else { return false }
            switch photos[index].outcome {
            case .waiting, .matching: return true
            case .matched, .failed: return false
            }
        }
    }

    /// The next photo to match: the first other than the reference that waits and can be read.
    public var next: Int? {
        photos.indices.first { index in
            guard index != reference, case .waiting = photos[index].outcome else { return false }
            return photos[index].readable
        }
    }

    /// What photo `index` is matched on: its own choice, or the skin when Skin is on and it left the choice to the match.
    public func preference(_ index: Int, skin: Bool) -> SeriesMatchPreference {
        photos[index].prefer == .automatic && skin ? .skin : photos[index].prefer
    }

    /// The edits photo `index` would get: its own, with the matched values set as asked.
    public func adjusted(_ index: Int, exposure: Bool, whiteBalance: Bool) -> Adjustments? {
        guard var settings = photos[index].edits else { return nil }
        if index != reference, photos[index].included, let result = photos[index].result, result.method != .unmatched {
            result.values.apply(to: &settings, exposure: exposure, whiteBalance: whiteBalance)
        }
        return settings
    }

    /// Sets the photos to match again (all of them, or only `index`); one left matching by a stopped pass waits again.
    public mutating func rematch(only index: Int? = nil) {
        for k in photos.indices where k != reference && (index == nil || index == k) && photos[k].readable { photos[k].outcome = .waiting }
        for k in photos.indices { if case .matching = photos[k].outcome { photos[k].outcome = .waiting } }
    }

    /// Makes photo `index` the reference, the others then to be matched again; false when it can't be one.
    public mutating func makeReference(_ index: Int) -> Bool {
        guard index != reference, photos.indices.contains(index), photos[index].readable else { return false }
        reference = index
        return true
    }
}
