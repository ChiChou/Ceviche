import CevicheCore
import Foundation

/// The sidebar's Capture Date outline: years, then months, then days, newest first.
struct CaptureDateNode: Identifiable, Equatable {
    /// The filter value: "2022", "2022-06", "2022-06-12", or "" for photos without a date.
    let id: String
    let title: String
    let count: Int
    var children: [CaptureDateNode]?

    static func tree(days: [String], counts: [String: Int]) -> [CaptureDateNode] {
        var years: [CaptureDateNode] = []
        for day in days where day.count == 10 {
            let year = String(day.prefix(4)), month = String(day.prefix(7)), count = counts[day] ?? 0
            let dayNode = CaptureDateNode(id: day, title: title(for: day), count: count)
            if years.last?.id != year { years.append(CaptureDateNode(id: year, title: year, count: 0, children: [])) }
            var yearNode = years.removeLast()
            var months = yearNode.children ?? []
            if months.last?.id != month { months.append(CaptureDateNode(id: month, title: title(for: month), count: 0, children: [])) }
            var monthNode = months.removeLast()
            monthNode.children?.append(dayNode)
            months.append(CaptureDateNode(id: month, title: monthNode.title, count: monthNode.count + count, children: monthNode.children))
            yearNode.children = months
            years.append(CaptureDateNode(id: year, title: year, count: yearNode.count + count, children: yearNode.children))
        }
        if let unknown = counts[""], unknown > 0 { years.append(CaptureDateNode(id: "", title: L10n.tr("Unknown Date"), count: unknown)) }
        return years
    }
    private static let monthParser = parser("yyyy-MM"), dayParser = parser("yyyy-MM-dd")
    private static func parser(_ format: String) -> DateFormatter {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = format
        return parser
    }
    /// "June" for a month, "12 Sunday" for a day; a full date when shown outside the tree.
    static func title(for value: String, full: Bool = false) -> String {
        guard !value.isEmpty else { return L10n.tr("Unknown Date") }
        let parser = value.count == 7 ? monthParser : dayParser
        guard value.count != 4, let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter(); formatter.timeZone = parser.timeZone; formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(value.count == 7 ? (full ? "MMMMyyyy" : "MMMM") : (full ? "yMMMd" : "dEEEE"))
        return formatter.string(from: date)
    }
    /// The years and months that contain a value, so the outline can reveal it.
    static func ancestors(of value: String) -> [String] {
        guard value.count >= 7 else { return [] }
        return value.count == 10 ? [String(value.prefix(4)), String(value.prefix(7))] : [String(value.prefix(4))]
    }
}
