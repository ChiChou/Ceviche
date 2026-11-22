import Foundation
import GRDB

/// Stops for the focal-length filter (`CatalogFilter.focalLength`).
public enum CatalogFocalFilter {
    /// The 35 mm equivalent, or the actual focal length when the camera records none.
    static let effectiveFocalSQL = "COALESCE(focalLength35mm, focalLength)"
}

/// A focal length the filter's slider can stop at, and where on the slider (0 to 1); labelled ones carry their number.
public struct CatalogFocalTick: Equatable, Sendable {
    public let millimetres: Int
    public let labelled: Bool
    public let position: Double
    public init(_ millimetres: Int, labelled: Bool = false, position: Double) {
        self.millimetres = millimetres; self.labelled = labelled; self.position = position
    }
}

extension CatalogFocalTick {
    /// The tick on a filter scale, in millimetres.
    public var scaleTick: CatalogScaleTick { CatalogScaleTick(millimetres, label: labelled ? "\(millimetres)" : nil, position: position) }
}

extension CatalogFocalFilter {
    /// 35 mm, 24–70 mm.
    public static func label(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound) mm" : "\(range.lowerBound)–\(range.upperBound) mm"
    }
    /// Popular focal lengths, in the order they earn a numbered stop: the classic primes and telephoto staples, then
    /// the ultra-wides and the ends of the common zooms (16-35, 24-105, 100-400, 200-800…), then the rest.
    static let standard: [[Int]] = [
        [24, 35, 50, 85, 135, 200, 400, 600],
        [14, 16, 20, 28, 105, 300, 800],
        [10, 12, 18, 40, 70, 100, 500, 1000],
    ]
    /// Stops from the shortest to the longest focal length in the catalog: both ends, then standard focal lengths
    /// between them, the most common first, up to `count` in all. A stop too close to another on the slider's
    /// logarithmic scale (`position`), or within 15 % of it, is left out.
    public static func stops(from range: ClosedRange<Int>, count: Int = 9, minimumGap: Double = 0.08) -> [Int] {
        var stops: Set<Int> = [range.lowerBound, range.upperBound]
        for tier in standard {
            for millimetres in tier where range.lowerBound < millimetres && millimetres < range.upperBound && stops.count < max(count, 2) {
                let crowded = stops.contains { stop in
                    abs(Double(stop - millimetres)) / Double(millimetres) < 0.15
                        || abs(position(of: stop, in: range) - position(of: millimetres, in: range)) < minimumGap
                }
                if !crowded { stops.insert(millimetres) }
            }
        }
        return stops.sorted()
    }
    /// The slider's ticks: `labels` numbered stops at popular lengths (`stops`), where they fall, and an even
    /// graduation of `divisions` between the ends, each tick the length at that point of the logarithmic scale.
    /// Graduation ticks almost on a numbered stop are left out. The ends widen to the nearest popular lengths outside
    /// the catalog's, so the scale reads 24–85 rather than 24–80; past 1000 mm the catalog's own end stays.
    public static func ticks(from catalog: ClosedRange<Int>, labels: Int = 5, divisions: Int = 24) -> [CatalogFocalTick] {
        let popular = standard.flatMap { $0 }.sorted()
        let range = (popular.last { $0 <= catalog.lowerBound } ?? catalog.lowerBound)...(popular.first { $0 >= catalog.upperBound } ?? catalog.upperBound)
        var ticks = stops(from: range, count: labels, minimumGap: 0.12).map { CatalogFocalTick($0, labelled: true, position: position(of: $0, in: range)) }
        guard range.upperBound > range.lowerBound, divisions > 0 else { return ticks }
        for step in 0...divisions {
            let at = Double(step) / Double(divisions)
            let millimetres = Int((Double(range.lowerBound) * pow(Double(range.upperBound) / Double(range.lowerBound), at)).rounded())
            if ticks.allSatisfy({ abs($0.position - at) >= 0.4 / Double(divisions) && $0.millimetres != millimetres }) {
                ticks.append(CatalogFocalTick(millimetres, position: at))
            }
        }
        return ticks.sorted { $0.position < $1.position }
    }
    /// Where a focal length sits on the slider, 0 at the shortest and 1 at the longest: logarithmic, so 24 to 35 gets
    /// as much room as 200 to 300 and a long telephoto doesn't stretch the slider.
    public static func position(of millimetres: Int, in range: ClosedRange<Int>) -> Double {
        guard range.upperBound > range.lowerBound, range.lowerBound > 0 else { return 0.5 }
        return log(Double(millimetres) / Double(range.lowerBound)) / log(Double(range.upperBound) / Double(range.lowerBound))
    }
}

extension CatalogStore {
    /// Equivalent focal bounds from the catalog's stored EXIF, including existing imports.
    public func focalRange(area: CatalogArea = .library) throws -> ClosedRange<Int>? {
        return try database.read { db in
            let value = CatalogFocalFilter.effectiveFocalSQL
            guard let row = try Row.fetchOne(db, sql: "SELECT MIN(\(value)) AS shortest, MAX(\(value)) AS longest FROM asset WHERE \(area.sql())"),
                  let shortest: Double = row["shortest"], let longest: Double = row["longest"] else { return nil }
            return max(1, Int(shortest.rounded()))...max(1, Int(longest.rounded()))
        }
    }
}
