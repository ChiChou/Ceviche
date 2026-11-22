import Foundation
import GRDB

/// A search term the field shows as a chip rather than as text: one that matches a tag exactly
/// (`camera:ILCE-7RM5`, `lens:"FE 24-70mm F2.8 GM"`) or a setting (`f/2.8`, `35mm`, `iso>=3200`). The search text
/// stays the record of them, so typing, pasting and MCP queries use the same terms.
public struct CatalogSearchToken: Equatable, Hashable, Sendable {
    /// The term as it is written in the search text.
    public let term: String
    /// The tag's source; `.exposure` for a setting.
    public let source: CatalogTagSource
    /// The tag, or the setting written for reading ("ISO ≥ 3200").
    public let label: String

    public init?(_ term: String) {
        if let location = CatalogLocationTerm(term) {
            self.term = term; self.source = .place; self.label = location.label
            return
        }
        if let colon = term.firstIndex(of: ":"), let source = CatalogTagSource(key: String(term[..<colon])) {
            let value = String(term[term.index(after: colon)...])
            // A quote still open is a tag being typed.
            if value.hasPrefix("\"") && (value.count < 2 || !value.hasSuffix("\"")) { return nil }
            let tag = CatalogStore.unquoted(value)
            guard !tag.isEmpty else { return nil }
            self.term = term; self.source = source; self.label = tag
            return
        }
        guard CatalogStore.exposureCondition(term) != nil else { return nil }
        self.term = term; self.source = .exposure; self.label = Self.reading(term)
    }

    /// The search split into chips and the text around them; text terms keep their order.
    public static func split(_ search: String) -> (tokens: [CatalogSearchToken], text: String) {
        var tokens: [CatalogSearchToken] = []
        var text: [String] = []
        for term in CatalogStore.searchTerms(search) {
            if let token = CatalogSearchToken(term) { tokens.append(token) } else { text.append(term) }
        }
        return (tokens, text.joined(separator: " "))
    }
    /// The search text for chips followed by typed text.
    public static func search(_ tokens: [CatalogSearchToken], text: String) -> String {
        (tokens.map(\.term) + [text]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func reading(_ term: String) -> String {
        var text = term.replacingOccurrences(of: ">=", with: "≥").replacingOccurrences(of: "<=", with: "≤")
        if let iso = text.range(of: #"^iso:?"#, options: [.regularExpression, .caseInsensitive]) { text.replaceSubrange(iso, with: "ISO ") }
        // Bounds read "ISO ≥ 3200", "f < 2.8", "> 200mm".
        text = text.replacingOccurrences(of: #"\s*([≥≤<>])\s*"#, with: " $1 ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let ev = text.range(of: "ev", options: [.caseInsensitive, .anchored, .backwards]) { text.replaceSubrange(ev, with: " EV") }
        if text.lowercased().hasPrefix("f"), let next = text.dropFirst().drop(while: { $0 == "/" }).first, next.isNumber {
            text = "f/" + text.dropFirst().drop { $0 == "/" }
        }
        return text
    }
}

/// A search term for where photos' locations came from: `location:set` (set in Ceviche), `location:file` (read from
/// the file) and `location:none`.
public enum CatalogLocationTerm: String, CaseIterable, Sendable {
    case set, file, none
    public init?(_ term: String) {
        let parts = term.lowercased().split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "location", let value = Self(rawValue: String(parts[1])) else { return nil }
        self = value
    }
    public var term: String { "location:" + rawValue }
    public var label: String {
        switch self {
        case .set: L10n.tr("Location Set in Ceviche")
        case .file: L10n.tr("Location from File")
        case .none: L10n.tr("No Location")
        }
    }
    var condition: SQLExpression {
        let located = CatalogAsset.Columns.latitude != nil && CatalogAsset.Columns.longitude != nil
        switch self {
        case .set: return located && CatalogAsset.Columns.locationSource != nil
        case .file: return located && CatalogAsset.Columns.locationSource == nil
        case .none: return !located
        }
    }
}
