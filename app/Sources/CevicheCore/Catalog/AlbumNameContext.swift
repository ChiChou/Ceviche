import Foundation
import GRDB

/// What an on-device language model is told about the photos of a new album so it can suggest a name: when and where
/// they were taken, what the classifier saw in them, and the words the photographer gave them. Only facts that recur
/// make it in, so one stray photo does not name the album.
public struct AlbumNameContext: Equatable, Sendable {
    public var photos = 0
    public var firstDay: String?, lastDay: String?
    /// Places by how many photos share them, most first: "Lisbon, Portugal".
    public var places: [Counted] = []
    /// Classifier tags by how many photos have them, generic ones left out.
    public var tags: [Counted] = []
    /// The photographer's own keywords and titles, most used first.
    public var keywords: [String] = []
    public var titles: [String] = []
    /// Whether the classifier has looked at any of the photos yet.
    public var tagged: Bool { !tags.isEmpty }

    public struct Counted: Equatable, Sendable {
        public let name: String
        public let count: Int
    }

    public init() {}

    /// Parents in the Vision taxonomy that every other photo carries, and incidental things; they say nothing about this set.
    static let genericTags: Set<String> = [
        "outdoor", "indoor", "people", "adult", "child", "liquid", "water body", "structure", "land", "clothing", "headgear",
        "material", "textile", "wood processed", "vehicle", "machine", "conveyance", "consumable", "food", "plant", "foliage",
        "sky", "light", "art", "document", "screenshot", "printed page", "furniture", "container", "tool", "equipment",
        "animal", "mammal", "wood natural", "optical equipment", "luggage", "bag", "backpack", "handbag",
        // States and conditions rather than subjects: snow also comes tagged frozen, the light of any day sky.
        "frozen", "daytime", "blue sky", "cloudy",
        // What people wear is in every set with people in it.
        "hoodie", "jacket", "coat", "shirt", "t-shirt", "jeans", "shorts", "dress", "suit", "hat", "cap", "sunglasses",
        "eyeglasses", "footwear", "shoes", "sneaker", "scarf", "gloves", "uniform",
    ]

    /// Vision tags its parents onto a photo with the child (snow comes with water and liquid); with the child there,
    /// the parent says nothing more, and would outnumber it in the counts.
    static let parentTags: [String: Set<String>] = [
        "snow": ["water", "liquid", "frozen"], "ice": ["water", "liquid", "frozen"],
        "forest": ["vegetation", "plant", "foliage"], "skyscraper": ["building", "structure"],
        "statue": ["art", "sculpture"], "tramway": ["railroad"],
    ]

    public init(_ assets: [CatalogAsset]) {
        photos = assets.count
        let days = assets.map(\.captureDay).filter { !$0.isEmpty }.sorted()
        firstDay = days.first; lastDay = days.last
        func ranked(_ values: [String], minimum: Int, limit: Int) -> [Counted] {
            var counts: [String: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            let kept: [Counted] = counts.compactMap { $0.value >= minimum ? Counted(name: $0.key, count: $0.value) : nil }
            let sorted = kept.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            return Array(sorted.prefix(limit))
        }
        // A tag or place in a single photo, or in under a tenth of a large set, is noise.
        let minimum = assets.count >= 5 ? max(2, assets.count / 10) : 1
        let placeNames: [String] = assets.compactMap { asset in
            var unique: [String] = []
            for part in [asset.placeCity, asset.placeRegion, asset.placeCountry].compactMap({ $0 }) where !unique.contains(part) { unique.append(part) }
            guard let first = unique.first else { return nil }
            // City and country: the region in between rarely belongs in a name.
            return unique.count > 1 ? first + ", " + unique[unique.count - 1] : first
        }
        places = ranked(placeNames, minimum: minimum, limit: 3)
        let split: (String) -> [String] = { text in
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        let tagNames: [String] = assets.flatMap { asset in
            let all = Set(split(asset.suggestedTags))
            let implied = all.reduce(into: Set<String>()) { $0.formUnion(Self.parentTags[$1] ?? []) }
            return all.subtracting(implied).filter { !Self.genericTags.contains($0) }
        }
        tags = ranked(tagNames, minimum: minimum, limit: 12)
        keywords = ranked(assets.flatMap { Set(split($0.keywords)) }, minimum: 1, limit: 8).map(\.name)
        let titleTexts: [String] = assets.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        titles = ranked(titleTexts, minimum: 1, limit: 3).map(\.name)
    }

    /// The facts as the model reads them, one per line; lines without facts are left out.
    public var prompt: String {
        var lines = ["Photos: \(photos)"]
        if let firstDay, let lastDay {
            lines.append(firstDay == lastDay ? "Taken: \(Self.spoken(firstDay))"
                         : "Taken: \(Self.spoken(firstDay)) to \(Self.spoken(lastDay)) (\(Self.span(firstDay, lastDay)))")
        }
        if !places.isEmpty { lines.append("Places: " + places.map { "\($0.name) (\($0.count))" }.joined(separator: "; ")) }
        if !tags.isEmpty { lines.append("Detected subjects: " + tags.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")) }
        if !keywords.isEmpty { lines.append("Photographer's keywords: " + keywords.joined(separator: ", ")) }
        if !titles.isEmpty { lines.append("Photo titles: " + titles.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    /// The time an album name can carry, decided here rather than by the model: the month for photos within one
    /// month, the year within one year, the years otherwise. "May 2024", "2025", "2019–2024".
    public func timePhrase(locale: Locale) -> String? {
        guard let firstDay, let lastDay, firstDay.count == 10, lastDay.count == 10 else { return nil }
        let firstYear = firstDay.prefix(4), lastYear = lastDay.prefix(4)
        if firstDay.prefix(7) == lastDay.prefix(7) {
            let parse = Date.ISO8601FormatStyle().year().month().day()
            guard let date = try? Date(firstDay, strategy: parse) else { return nil }
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: TimeZone(identifier: "UTC")!)
            style = style.month(.wide).year()
            return date.formatted(style)
        }
        return firstYear == lastYear ? String(firstYear) : "\(firstYear)–\(lastYear)"
    }

    /// How far apart two ISO days are, roughly: "7 days", "3 months", "2 years".
    static func span(_ first: String, _ last: String) -> String {
        let parse = Date.ISO8601FormatStyle().year().month().day()
        guard let a = try? Date(first, strategy: parse), let b = try? Date(last, strategy: parse) else { return "unknown span" }
        let days = (Calendar(identifier: .gregorian).dateComponents([.day], from: a, to: b).day ?? 0) + 1
        if days < 45 { return "\(days) days" }
        if days < 548 { return "\(Int((Double(days) / 30.4).rounded())) months" }
        return "\(Int((Double(days) / 365.25).rounded())) years"
    }

    /// "2024-05-03" as "3 May 2024", which the model reads more reliably than ISO days.
    static func spoken(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        return "\(parts[2]) \(months[parts[1] - 1]) \(parts[0])"
    }
}

extension CatalogStore {
    /// The naming facts for photos about to form an album; at most `limit` of them are read.
    public func albumNameContext(assetIDs: [String], limit: Int = 400) throws -> AlbumNameContext {
        let ids = Array(assetIDs.prefix(limit))
        let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        let assets = try database.read { db in
            try CatalogAsset.filter(sql: "id IN (SELECT value FROM json_each(?)) AND trashedAt IS NULL AND archivedAt IS NULL", arguments: [list]).fetchAll(db)
        }
        var context = AlbumNameContext(assets)
        context.photos = max(context.photos, assetIDs.count)
        return context
    }
}
