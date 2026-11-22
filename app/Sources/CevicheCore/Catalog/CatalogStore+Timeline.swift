import Foundation
import GRDB

extension CatalogStore {
    /// The months (`YYYY-MM`) that hold at least one photo matching `filter`: one pass over the matching photos'
    /// capture days, in the date index where the filter allows.
    public func captureMonths(filter: CatalogFilter) throws -> Set<String> {
        try database.read { db in
            let days = try String.fetchAll(db, Self.query(filter).filter(Columns.captureDay != "").select(Columns.captureDay).distinct())
            return Set(days.map { String($0.prefix(7)) })
        }
    }

    /// Where the photos nearest `month` (`YYYY-MM`) start among those matching `filter`, sorted by capture date: the
    /// month's first photo, or, when it has none (a scrubber stop can land anywhere), the first photo of the closest
    /// day before or after it. Two index seeks and a count.
    public func offset(nearestMonth month: String, filter: CatalogFilter) throws -> Int {
        try database.read { db in
            let dated = Self.query(filter).filter(Columns.captureDay != "")
            // Days are compared as text: "-32" sorts after every day of the month and "-00" before.
            let end = "\(month)-32", start = "\(month)-00"
            let earlier = try String.fetchOne(db, dated.filter(Columns.captureDay < end).select(Columns.captureDay).order(Columns.captureDay.desc).limit(1))
            let later = try String.fetchOne(db, dated.filter(Columns.captureDay > start).select(Columns.captureDay).order(Columns.captureDay.asc).limit(1))
            let day: String
            switch (earlier, later) {
            case let (earlier?, later?):
                if earlier.hasPrefix(month) { day = earlier }
                else if later.hasPrefix(month) { day = later }
                else { day = Self.daysBetween(earlier, start) <= Self.daysBetween(end, later) ? earlier : later }
            case let (earlier?, nil): day = earlier
            case let (nil, later?): day = later
            case (nil, nil): return 0
            }
            // A month with photos starts at its newest day going down, its oldest going up.
            let first: String
            if day.hasPrefix(month) {
                first = filter.ascending ? (later ?? day) : (earlier ?? day)
            } else { first = day }
            let before = filter.ascending ? Columns.captureDay < first : Columns.captureDay > first
            return try Self.query(filter).filter(before).fetchCount(db)
        }
    }
    /// Days from `a` to `b` (`YYYY-MM-DD`, or a month bound such as `YYYY-MM-00`), roughly: enough to tell which side is nearer.
    public static func daysBetween(_ a: String, _ b: String) -> Int {
        func number(_ day: String) -> Int {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return 0 }
            return parts[0] * 372 + parts[1] * 31 + parts[2]
        }
        return abs(number(b) - number(a))
    }
}
