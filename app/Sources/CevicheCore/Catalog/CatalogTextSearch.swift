import Foundation
import GRDB

extension CatalogStore {
    /// The columns the search field looks in.
    static let searchedColumns = ["filename", "title", "caption", "keywords", "suggestedTags",
                                  "placeCity", "placeRegion", "placeCountry", "cameraMake", "cameraModel",
                                  "lensMake", "lensModel", "artist"]

    /// A full-text index of the searched columns (`assetSearch`), so a search term matches the start of a word
    /// ("car" finds "police car" and "carousel", not "scarf"; "to" finds Tokyo, not Veneto) without reading every photo. It holds no text of its
    /// own: it points at `asset` rows by rowid, and triggers keep it in step with every writer. It is this Mac's
    /// alone, rebuilt from the rows whenever needed, and nothing about it syncs.
    ///
    /// `asset` has no INTEGER PRIMARY KEY, so a VACUUM may renumber its rows: whatever runs one has to
    /// `rebuildTextIndex` afterwards.
    static func createTextIndex(_ db: Database) throws {
        let columns = searchedColumns.joined(separator: ", ")
        func values(_ row: String) -> String { searchedColumns.map { "\(row).\($0)" }.joined(separator: ", ") }
        try db.execute(sql: """
            CREATE VIRTUAL TABLE assetSearch USING fts5(\(columns), content='asset', content_rowid='rowid',
                prefix='2 3', tokenize="unicode61 remove_diacritics 2");
            CREATE TRIGGER assetSearch_insert AFTER INSERT ON asset BEGIN
                INSERT INTO assetSearch(rowid, \(columns)) VALUES (NEW.rowid, \(values("NEW")));
            END;
            CREATE TRIGGER assetSearch_delete AFTER DELETE ON asset BEGIN
                INSERT INTO assetSearch(assetSearch, rowid, \(columns)) VALUES ('delete', OLD.rowid, \(values("OLD")));
            END;
            CREATE TRIGGER assetSearch_update AFTER UPDATE OF \(columns) ON asset
                WHEN \(searchedColumns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")) BEGIN
                INSERT INTO assetSearch(assetSearch, rowid, \(columns)) VALUES ('delete', OLD.rowid, \(values("OLD")));
                INSERT INTO assetSearch(rowid, \(columns)) VALUES (NEW.rowid, \(values("NEW")));
            END;
            """)
        try rebuildTextIndex(db)
    }
    static func rebuildTextIndex(_ db: Database) throws {
        try db.execute(sql: "INSERT INTO assetSearch(assetSearch) VALUES ('rebuild')")
    }

    /// The search text's terms: split at spaces, except inside double quotes (`lens:"FE 24-70mm F2.8 GM II"`).
    nonisolated static func searchTermRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var quoted = false
        for index in text.indices {
            let character = text[index]
            if character == "\"" { quoted.toggle() }
            if character.isWhitespace && !quoted {
                if let begun = start { ranges.append(begun..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }
    nonisolated static func searchTerms(_ text: String) -> [String] { searchTermRanges(text).map { String(text[$0]) } }
    /// A term's text without its surrounding quotes, with doubled quotes inside it single again.
    nonisolated static func unquoted(_ value: String) -> String {
        guard value.hasPrefix("\"") else { return value }
        var inner = value.dropFirst()
        if inner.hasSuffix("\"") { inner = inner.dropLast() }
        return inner.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// What one search term requires of a photo. `location:set`, `location:file` and `location:none` match where
    /// the location came from (`CatalogLocationTerm`). `camera:`, `lens:`, `keyword:`, `tag:`, `place:` and `artist:`
    /// followed by a tag match photos with exactly that tag. Exposure values match the photo's settings, as one
    /// value, a range or a bound: "f/1.4", "f<2.8", "35mm", "70-200mm", "1/250s", "<1/1000", "2s", "iso3200",
    /// "iso>=6400", "+0.7ev". Any other term matches the start of a word in any searched column; one with digits
    /// also matches anywhere in the file name ("1234" finds DSC01234). Scripts written without spaces between
    /// words (Chinese, Japanese, Thai…) have no word starts to match, so their terms match anywhere, as a plain
    /// substring. Nil for a term with nothing to match, such as a lone dash.
    nonisolated static func searchCondition(_ term: String) -> SQLExpression? {
        if let location = CatalogLocationTerm(term) { return location.condition }
        if let colon = term.firstIndex(of: ":"), let source = CatalogTagSource(key: String(term[..<colon])) {
            let tag = unquoted(String(term[term.index(after: colon)...]))
            guard !tag.isEmpty else { return nil }
            return SQL("id IN (SELECT assetID FROM assetTag WHERE tag = \(tag) AND source = \(source.rawValue))").sqlExpression
        }
        if let exposure = exposureCondition(term) { return exposure }
        if term.unicodeScalars.contains(where: isUnspacedScript) {
            let pattern = "%" + likePattern(term) + "%"
            return searchedColumns.map { Column($0).like(pattern, escape: "\\") }.joined(operator: .or)
        }
        guard term.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        // A quoted phrase is never read as query syntax; the tokenizer splits it like the indexed text, and the
        // star makes its last word a prefix.
        let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        let words = SQL("rowid IN (SELECT rowid FROM assetSearch WHERE assetSearch MATCH \(phrase))").sqlExpression
        // "flash" also finds photos where the flash fired.
        if term.caseInsensitiveCompare("flash") == .orderedSame { return words || Column("flashFired") == true }
        guard term.contains(where: \.isNumber) else { return words }
        return words || Column("filename").like("%" + likePattern(term) + "%", escape: "\\")
    }

    /// An exposure term, as `searchCondition` describes. Each value stands for the settings its tag is written
    /// from (`createTagIndex`), so f/2.8 is f/2.75 up to f/2.85, 1/250s every time that rounds to 1/250.
    nonisolated static func exposureCondition(_ term: String) -> SQLExpression? {
        let text = term.lowercased()
        let number = #"\d+(?:\.\d+)?"#
        let bound = #"(<=|>=|<|>)?"#
        func match(_ pattern: String) -> [String?]? {
            guard let regex = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<found.numberOfRanges).map { Range(found.range(at: $0), in: text).map { String(text[$0]) } }
        }
        func condition(_ column: String, _ parts: [String?], window: (String) -> Range<Double>?) -> SQLExpression? {
            guard let first = parts[1].flatMap(window) else { return nil }
            let value = Column(column)
            switch parts[0] {
            case "<": return value < first.lowerBound
            case "<=": return value < first.upperBound
            case ">": return value >= first.upperBound
            case ">=": return value >= first.lowerBound
            default:
                guard let last = parts[2].map(window) else { return value >= first.lowerBound && value < first.upperBound }
                guard let last else { return nil }
                return value >= min(first.lowerBound, last.lowerBound) && value < max(first.upperBound, last.upperBound)
            }
        }
        func around(_ step: Double) -> (String) -> Range<Double>? {
            { Double($0).map { ($0 - step)..<($0 + step) } }
        }
        if let parts = match("f/?" + bound + "(\(number))(?:-(\(number)))?") { return condition("fNumber", parts, window: around(0.05)) }
        if let parts = match("iso:?" + bound + "(\\d+)(?:-(\\d+))?") { return condition("iso", parts, window: around(0.5)) }
        if let parts = match(bound + "(\(number))(?:-(\(number)))?mm") { return condition("focalLength", parts, window: around(0.5)) }
        if let parts = match(bound + "([+-]?\(number))ev") { return condition("exposureBias", parts + [nil], window: around(0.05)) }
        let time = "(1/\\d+|\(number))"
        if let parts = match(bound + time + "(?:-" + time + ")?s") ?? match(bound + "(1/\\d+)(?:-" + time + ")?") {
            return condition("exposureTime", parts) { value in
                guard value.hasPrefix("1/") else { return around(0.05)(value) }
                guard let speed = Double(value.dropFirst(2)), speed >= 1 else { return nil }
                return (1 / (speed + 0.5))..<(1 / max(speed - 0.5, 0.5))
            }
        }
        return nil
    }
    nonisolated static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF,  // Thai, Lao, Myanmar, Khmer
             0x3040...0x30FF, 0x31F0...0x31FF,                    // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,   // CJK ideographs
             0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }
}
