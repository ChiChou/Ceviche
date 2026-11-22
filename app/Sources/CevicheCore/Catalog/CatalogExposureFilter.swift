import Foundation
import GRDB

/// A point a filter scale can stop at: a value (millimetres, or a third stop of `CatalogExposureScale`), its number
/// when the scale prints one, and where on the scale it sits (0 to 1).
public struct CatalogScaleTick: Equatable, Sendable {
    public let value: Int
    public let label: String?
    public let position: Double
    public init(_ value: Int, label: String? = nil, position: Double) {
        self.value = value; self.label = label; self.position = position
    }
}

/// Aperture, shutter speed and ISO as a camera counts them: in third stops. A filter holds a range of third stops
/// (`CatalogFilter.aperture` and the others), stop 0 being f/1, 1 s and ISO 100; each stands for the values that
/// round to it, so f/1.7 counts as f/1.8 and 1/60 s as 1/64 s.
public enum CatalogExposureScale: String, CaseIterable, Sendable {
    case aperture, shutter, iso

    /// The `asset` column the scale filters.
    public var column: String {
        switch self {
        case .aperture: "fNumber"
        case .shutter: "exposureTime"
        case .iso: "iso"
        }
    }
    /// The value at a third stop, or between two at a fraction: f-numbers grow by √2 a stop, times and ISO double.
    public func value(atStop stop: Double) -> Double {
        switch self {
        case .aperture: pow(2, stop / 6)
        case .shutter: pow(2, stop / 3)
        case .iso: 100 * pow(2, stop / 3)
        }
    }
    /// The third stop a value rounds to.
    public func stop(of value: Double) -> Int {
        switch self {
        case .aperture: Int((6 * log2(value)).rounded())
        case .shutter: Int((3 * log2(value)).rounded())
        case .iso: Int((3 * log2(value / 100)).rounded())
        }
    }
    /// The values a range of stops matches, from half a third below the first to half a third above the last.
    public func bounds(_ stops: ClosedRange<Int>) -> Range<Double> {
        value(atStop: Double(stops.lowerBound) - 0.5)..<value(atStop: Double(stops.upperBound) + 0.5)
    }

    /// The marked value of a third stop, as a camera shows it: 5.6, 1/250, 2", 3200.
    public func label(_ stop: Int) -> String {
        switch self {
        case .aperture:
            if let nominal = Self.nominal(Self.apertures, stop, from: -3) { return nominal }
            return Self.short(value(atStop: Double(stop)))
        case .shutter:
            if stop < 0 {
                guard let denominator = Self.nominal(Self.shutterFractions, stop, from: -Self.shutterFractions.count) else {
                    return "1/" + Self.short(1 / value(atStop: Double(stop)))
                }
                // 1/1.3, 1/1.6 and 1/2.5 read as tenths of a second.
                if denominator.contains(".") { return Self.short(1 / (Double(denominator) ?? 1)) + "\"" }
                return "1/" + denominator
            }
            return (Self.nominal(Self.shutterSeconds, stop, from: 0) ?? Self.short(value(atStop: Double(stop)))) + "\""
        case .iso:
            return Self.nominal(Self.isos, stop, from: -6) ?? String(Int(value(atStop: Double(stop)).rounded()))
        }
    }
    /// The same for a range: f/2.8–5.6, 1/250–1/60, ISO 100–800.
    public func label(_ stops: ClosedRange<Int>) -> String {
        let span = stops.lowerBound == stops.upperBound ? label(stops.lowerBound) : "\(label(stops.lowerBound))–\(label(stops.upperBound))"
        switch self {
        case .aperture: return "f/" + span
        case .shutter: return span
        case .iso: return "ISO " + span
        }
    }

    /// The scale's ticks for the values in the catalog: one a third stop, or a stop where that would be more than 36,
    /// between whole stops at or beyond the catalog's ends, evenly spaced, with up to `labels` whole stops numbered.
    public func ticks(from catalog: ClosedRange<Double>, labels: Int = 5) -> [CatalogScaleTick] {
        guard catalog.lowerBound > 0 else { return [] }
        let lower = Int((Double(stop(of: catalog.lowerBound)) / 3).rounded(.down)) * 3
        var upper = Int((Double(stop(of: catalog.upperBound)) / 3).rounded(.up)) * 3
        if upper == lower { upper += 3 }
        let step = upper - lower > 36 ? 3 : 1
        let wholeStops = (upper - lower) / 3
        let count = min(max(labels, 2), wholeStops + 1)
        let numbered = Set((0..<count).map { lower + 3 * Int((Double($0 * wholeStops) / Double(count - 1)).rounded()) })
        return stride(from: lower, through: upper, by: step).map { stop in
            CatalogScaleTick(stop, label: numbered.contains(stop) ? label(stop) : nil, position: Double(stop - lower) / Double(upper - lower))
        }
    }

    // Third-stop markings, from f/0.7, 1/32000 s and ISO 25.
    static let apertures = ["0.7", "0.8", "0.9", "1", "1.1", "1.2", "1.4", "1.6", "1.8", "2", "2.2", "2.5", "2.8", "3.2", "3.5", "4", "4.5", "5",
                            "5.6", "6.3", "7.1", "8", "9", "10", "11", "13", "14", "16", "18", "20", "22", "25", "29", "32", "36", "40", "45",
                            "51", "57", "64", "72", "80", "90"]
    static let shutterFractions = ["32000", "25000", "20000", "16000", "12800", "10000", "8000", "6400", "5000", "4000", "3200", "2500", "2000",
                                   "1600", "1250", "1000", "800", "640", "500", "400", "320", "250", "200", "160", "125", "100", "80", "60",
                                   "50", "40", "30", "25", "20", "15", "13", "10", "8", "6", "5", "4", "3", "2.5", "2", "1.6", "1.3"]
    static let shutterSeconds = ["1", "1.3", "1.6", "2", "2.5", "3.2", "4", "5", "6", "8", "10", "13", "15", "20", "25", "30", "40", "50", "60",
                                 "80", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000"]
    static let isos = ["25", "32", "40", "50", "64", "80", "100", "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000", "1250",
                       "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000", "12800", "16000", "20000", "25600", "32000",
                       "40000", "51200", "64000", "80000", "102400", "128000", "160000", "204800", "256000", "320000", "409600"]
    private static func nominal(_ table: [String], _ stop: Int, from first: Int) -> String? {
        let index = stop - first
        return table.indices.contains(index) ? table[index] : nil
    }
    private static func short(_ value: Double) -> String {
        value >= 10 ? String(Int(value.rounded())) : String(format: "%g", (value * 10).rounded() / 10)
    }
}

/// The shape a photo is shown in, after its crop and quarter turns (`asset.aspect`).
public enum CatalogOrientation: String, CaseIterable, Sendable {
    case landscape, portrait, square
    /// Within 2 % of square counts as square.
    static let tolerance = 1.02
}

/// Whether background tagging found faces in a photo (`asset.faceCount`). A photo it hasn't analysed yet matches
/// none of these, so it is never taken for one without faces.
public enum CatalogFaces: String, CaseIterable, Sendable {
    case none, some, group
    /// Faces from which a photo counts as a group photo.
    public static let groupSize = 3
    var condition: SQLExpression {
        let count = Column(CatalogStore.faceCountColumn)
        switch self {
        case .none: return count == 0
        case .some: return count > 0
        case .group: return count >= Self.groupSize
        }
    }
}

extension CatalogStore {
    /// The smallest and largest values of a scale in the photos, read from the column's index.
    public func exposureRange(_ scale: CatalogExposureScale, area: CatalogArea = .library) throws -> ClosedRange<Double>? {
        let column = scale.column, trashed = area.sql()
        return try database.read { db in
            func end(_ order: String) throws -> Double? {
                try Double.fetchOne(db, sql: "SELECT \(column) FROM asset WHERE \(column) IS NOT NULL AND \(trashed) ORDER BY \(column) \(order) LIMIT 1")
            }
            guard let lowest = try end("ASC"), let highest = try end("DESC") else { return nil }
            return lowest...highest
        }
    }
}
