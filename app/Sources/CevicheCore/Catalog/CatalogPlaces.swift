import Foundation
import GRDB

/// A place by name: the city, its region (a state, province or prefecture) and the country.
public struct CatalogPlace: Equatable, Sendable {
    public var country: String?
    public var region: String?
    public var city: String?
    public init(country: String? = nil, region: String? = nil, city: String? = nil) {
        func named(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        self.country = named(country); self.region = named(region); self.city = named(city)
    }
    public var isEmpty: Bool { country == nil && region == nil && city == nil }
    /// How a photo's place was found.
    public enum Source: String, Sendable {
        /// Looked up from the photo's own location.
        case gps
        /// Borrowed from a photo with a location taken shortly before or after (`CatalogStore.inferPlaces`).
        case nearby
    }
}

/// A square of about a kilometre that one lookup names for every photo in it.
public struct CatalogPlaceCell: Hashable, Sendable {
    public let key: String
    /// A photo's location in the square, to look up.
    public let latitude: Double
    public let longitude: Double
    /// Hundredths of a degree; SQL computes the same key with `CatalogStore.cellSQL`.
    public static func key(latitude: Double, longitude: Double) -> String {
        "\(Int((latitude * 100).rounded())),\(Int((longitude * 100).rounded()))"
    }
}

extension CatalogStore {
    /// Results of place lookups per square, in the language they were asked in. A square with nothing to name
    /// (open sea) keeps an empty row so it is not asked about again.
    static func createPlaceTables(_ db: Database) throws {
        try db.create(table: "placeLookup", options: .withoutRowID) { t in
            t.primaryKey("cell", .text)
            t.column("country", .text)
            t.column("region", .text)
            t.column("city", .text)
            t.column("locale", .text).notNull()
            t.column("resolvedAt", .datetime).notNull()
        }
        // A photo whose location changes, or is removed, is named again.
        try db.execute(sql: """
            CREATE TRIGGER asset_place_moved AFTER UPDATE OF latitude, longitude ON asset
                WHEN NEW.placeSource = 'gps' AND (OLD.latitude IS NOT NEW.latitude OR OLD.longitude IS NOT NEW.longitude) BEGIN
                UPDATE asset SET placeCountry = NULL, placeRegion = NULL, placeCity = NULL, placeSource = NULL WHERE id = NEW.id;
            END;
            """)
    }
    /// `CatalogPlaceCell.key` of a row's location; SQLite's round(), like Swift's, rounds halves away from zero.
    static let cellSQL = "CAST(round(latitude * 100) AS INTEGER) || ',' || CAST(round(longitude * 100) AS INTEGER)"

    /// Names photos with a location from squares already looked up in `locale`. Returns how many photos changed.
    @discardableResult
    public func applyKnownPlaces(locale: String) throws -> Int {
        try database.write { db in
            try Self.applyPlaceLookups(db, locale: locale)
            return db.changesCount
        }
    }
    /// Squares with photos in them still to look up in `locale`, at most `limit`: new ones, and every square again
    /// after the language changes.
    public func pendingPlaceCells(locale: String, limit: Int = 50) throws -> [CatalogPlaceCell] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT cell, latitude, longitude FROM (
                    SELECT \(Self.cellSQL) AS cell, latitude, longitude FROM asset
                    WHERE latitude IS NOT NULL AND longitude IS NOT NULL
                ) WHERE cell NOT IN (SELECT cell FROM placeLookup WHERE locale = ?) GROUP BY cell LIMIT ?
                """, arguments: [locale, limit]).map { CatalogPlaceCell(key: $0["cell"], latitude: $0["latitude"], longitude: $0["longitude"]) }
        }
    }
    /// Keeps what a lookup found for a square (nil: nothing there) and names the square's photos.
    public func recordPlace(_ place: CatalogPlace?, cell: String, locale: String, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO placeLookup(cell, country, region, city, locale, resolvedAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [cell, place?.country, place?.region, place?.city, locale, now])
            try Self.applyPlaceLookups(db, locale: locale, cell: cell)
        }
    }
    /// Copies looked-up names onto the photos in those squares. Only the place columns change, so neither
    /// `updatedAt` nor iCloud sees it: every Mac names places itself.
    private static func applyPlaceLookups(_ db: Database, locale: String, cell: String? = nil) throws {
        try db.execute(sql: """
            UPDATE asset SET placeCountry = lookup.country, placeRegion = lookup.region, placeCity = lookup.city, placeSource = 'gps'
            FROM (SELECT cell, country, region, city FROM placeLookup WHERE locale = ?1 AND (?2 IS NULL OR cell = ?2)) AS lookup
            WHERE asset.latitude IS NOT NULL AND asset.longitude IS NOT NULL AND lookup.cell = \(cellSQL)
                AND (asset.placeSource IS NOT 'gps' OR asset.placeCountry IS NOT lookup.country OR asset.placeRegion IS NOT lookup.region OR asset.placeCity IS NOT lookup.city)
            """, arguments: [locale, cell])
    }

    /// The location of the photo taken closest in time to `captureTime` (`YYYY-MM-DDTHH:MM:SS`), for where to start
    /// placing a photo that has none.
    public func nearestLocation(to captureTime: String) throws -> (latitude: Double, longitude: Double)? {
        try database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT latitude, longitude FROM asset
                WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND captureTime IS NOT NULL AND trashedAt IS NULL
                ORDER BY abs(julianday(captureTime) - julianday(?)) LIMIT 1
                """, arguments: [captureTime]).map { ($0["latitude"], $0["longitude"]) }
        }
    }
    /// Gives photos without a location the place of a photo with one taken close in time: the nearest, when it is
    /// within `near`, or the one on both sides when both are within `around` and agree. That covers a camera without
    /// GPS used beside a phone. Capture times are the cameras' own clocks, so one set to another time zone can
    /// borrow from the wrong hour; such places are marked `nearby` and a photo's own location always wins.
    /// Returns the number of photos whose place changed.
    @discardableResult
    public func inferPlaces(near: TimeInterval = 3600, around: TimeInterval = 6 * 3600) throws -> Int {
        try database.write { db in
            struct Shot { let id: String; let time: TimeInterval; let located: Bool; let place: CatalogPlace; let source: String? }
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let shots = try Row.fetchAll(db, sql: """
                SELECT id, captureTime, latitude IS NOT NULL AND longitude IS NOT NULL AS located, placeCountry, placeRegion, placeCity, placeSource
                FROM asset WHERE captureTime IS NOT NULL ORDER BY captureTime
                """).compactMap { row -> Shot? in
                guard let time = parser.date(from: row["captureTime"]) else { return nil }
                return Shot(id: row["id"], time: time.timeIntervalSinceReferenceDate, located: row["located"],
                            place: CatalogPlace(country: row["placeCountry"], region: row["placeRegion"], city: row["placeCity"]), source: row["placeSource"])
            }
            // Anchors: photos whose own location has been named.
            let anchors = shots.filter { $0.located && $0.source == CatalogPlace.Source.gps.rawValue && !$0.place.isEmpty }
            var changed = 0
            var next = 0
            for shot in shots where !shot.located {
                while next < anchors.count, anchors[next].time < shot.time { next += 1 }
                let before = next > 0 ? anchors[next - 1] : nil, after = next < anchors.count ? anchors[next] : nil
                let gapBefore = before.map { shot.time - $0.time } ?? .infinity, gapAfter = after.map { $0.time - shot.time } ?? .infinity
                var found: CatalogPlace?
                if min(gapBefore, gapAfter) <= near { found = gapBefore <= gapAfter ? before?.place : after?.place }
                else if gapBefore <= around, gapAfter <= around, let before, let after, before.place == after.place { found = before.place }
                let source = found.map { _ in CatalogPlace.Source.nearby.rawValue }
                // A place someone else set (a later source) is left alone; only inferred ones are revised.
                guard shot.source == nil || shot.source == CatalogPlace.Source.nearby.rawValue,
                      shot.place != (found ?? CatalogPlace()) || shot.source != source else { continue }
                try db.execute(sql: "UPDATE asset SET placeCountry = ?, placeRegion = ?, placeCity = ?, placeSource = ? WHERE id = ?",
                               arguments: [found?.country, found?.region, found?.city, source, shot.id])
                changed += 1
            }
            return changed
        }
    }
}
