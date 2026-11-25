import Foundation
import GRDB

/// Where a searchable tag comes from.
public enum CatalogTagSource: String, Sendable, CaseIterable {
    /// The person's own keywords.
    case keyword
    /// Background tagging (`CatalogImporter.classify`).
    case automatic
    /// The city, region and country (`CatalogAsset.placeCity` and the others).
    case place
    /// The camera's make and model; the lens's model, and its make when another maker's than the camera's.
    case camera, lens
    /// Who took the photo.
    case artist
    /// Aperture, focal length, shutter speed, ISO, exposure compensation and flash, written the way the search
    /// reads them ("f/1.4", "35mm", "1/250s", "ISO 3200", "+0.7 EV", "Flash").
    case exposure
    /// The prefix of a search term that matches this source's tags exactly (`camera:"ILCE-7RM5"`); exposure
    /// values need none, since the search reads them as numbers.
    public var key: String? {
        switch self {
        case .keyword: "keyword"
        case .automatic: "tag"
        case .place: "place"
        case .camera: "camera"
        case .lens: "lens"
        case .artist: "artist"
        case .exposure: nil
        }
    }
    init?(key: String) {
        guard let source = Self.allCases.first(where: { $0.key?.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
        self = source
    }
}

public struct CatalogSearchSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { completion }
    public let tag: String
    public let source: CatalogTagSource
    /// Photos with the tag from `source`.
    public let photoCount: Int
    /// The search text with the typed term replaced by a term that matches exactly this tag.
    public let completion: String
}

extension CatalogStore {
    /// Every photo's tags by source (`assetTag`), and how many photos in the Library and out of it, in the Trash or
    /// archived, have each one (`tagCount`). Triggers derive both from the photo's columns, so they stay right whichever process or
    /// connection writes, and a photo counts once per tag and source. `tagSearch` indexes the words of every
    /// tag, so a suggestion matches any word start ("gm" finds "FE 24-70mm F2.8 GM II", "7r" finds "ILCE-7RM5").
    static func createTagIndex(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE assetTag (
                assetID TEXT NOT NULL,
                source TEXT NOT NULL,
                tag TEXT NOT NULL COLLATE NOCASE,
                confidence REAL,
                trashed BOOLEAN NOT NULL DEFAULT 0,
                PRIMARY KEY (assetID, source, tag)
            ) WITHOUT ROWID;
            CREATE INDEX assetTag_tag ON assetTag(tag, source);
            CREATE TABLE tagCount (
                id INTEGER PRIMARY KEY,
                tag TEXT NOT NULL COLLATE NOCASE,
                source TEXT NOT NULL,
                libraryCount INTEGER NOT NULL CHECK(libraryCount >= 0),
                trashCount INTEGER NOT NULL CHECK(trashCount >= 0),
                UNIQUE (tag, source)
            );
            CREATE INDEX tagCount_source ON tagCount(source, libraryCount);
            CREATE VIRTUAL TABLE tagSearch USING fts5(tag, content='tagCount', content_rowid='id',
                prefix='1 2 3', tokenize="unicode61 remove_diacritics 2");
            CREATE TRIGGER tagSearch_insert AFTER INSERT ON tagCount BEGIN
                INSERT INTO tagSearch(rowid, tag) VALUES (NEW.id, NEW.tag);
            END;
            CREATE TRIGGER tagSearch_delete AFTER DELETE ON tagCount BEGIN
                INSERT INTO tagSearch(tagSearch, rowid, tag) VALUES ('delete', OLD.id, OLD.tag);
            END;
            CREATE TRIGGER tagCount_insert AFTER INSERT ON assetTag BEGIN
                INSERT INTO tagCount(tag, source, libraryCount, trashCount) VALUES (NEW.tag, NEW.source, NOT NEW.trashed, NEW.trashed <> 0)
                    ON CONFLICT(tag, source) DO UPDATE SET libraryCount = libraryCount + excluded.libraryCount, trashCount = trashCount + excluded.trashCount;
            END;
            CREATE TRIGGER tagCount_delete AFTER DELETE ON assetTag BEGIN
                UPDATE tagCount SET libraryCount = libraryCount - (NOT OLD.trashed), trashCount = trashCount - (OLD.trashed <> 0)
                    WHERE tag = OLD.tag AND source = OLD.source;
                DELETE FROM tagCount WHERE tag = OLD.tag AND source = OLD.source AND libraryCount = 0 AND trashCount = 0;
            END;
            CREATE TRIGGER tagCount_trash AFTER UPDATE OF trashed ON assetTag WHEN OLD.trashed IS NOT NEW.trashed BEGIN
                UPDATE tagCount SET libraryCount = libraryCount + (NOT NEW.trashed) - (NOT OLD.trashed), trashCount = trashCount + (NEW.trashed <> 0) - (OLD.trashed <> 0)
                    WHERE tag = NEW.tag AND source = NEW.source;
            END;
            """)
        try createAssetTagTriggers(db)
        // The photos already in the catalog.
        for source in CatalogTagSource.allCases { try db.execute(sql: insertTags(source, of: "asset", joining: true)) }
    }
    /// The triggers that keep `assetTag` in step with the photo's columns. `trashed` means out of the library: in the
    /// Trash or archived.
    private static func createAssetTagTriggers(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER assetTag_insert AFTER INSERT ON asset BEGIN
                \(CatalogTagSource.allCases.map { insertTags($0, of: "NEW", joining: false) }.joined(separator: "\n"))
            END;
            CREATE TRIGGER assetTag_delete AFTER DELETE ON asset BEGIN DELETE FROM assetTag WHERE assetID = OLD.id; END;
            CREATE TRIGGER assetTag_trash AFTER UPDATE OF trashedAt, archivedAt ON asset
                WHEN (OLD.trashedAt IS NULL AND OLD.archivedAt IS NULL) IS NOT (NEW.trashedAt IS NULL AND NEW.archivedAt IS NULL) BEGIN
                UPDATE assetTag SET trashed = \(outOfLibrary("NEW")) WHERE assetID = NEW.id;
            END;
            """)
        for source in CatalogTagSource.allCases {
            let columns = tagColumns(source)
            try db.execute(sql: """
                CREATE TRIGGER assetTag_\(source.rawValue) AFTER UPDATE OF \(columns.joined(separator: ", ")) ON asset
                    WHEN \(columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")) BEGIN
                    DELETE FROM assetTag WHERE assetID = NEW.id AND source = '\(source.rawValue)';
                    \(insertTags(source, of: "NEW", joining: false))
                END;
                """)
        }
    }
    private static func outOfLibrary(_ row: String) -> String { "(\(row).trashedAt IS NOT NULL OR \(row).archivedAt IS NOT NULL)" }
    private static func tagColumns(_ source: CatalogTagSource) -> [String] {
        switch source {
        case .keyword: ["keywords"]
        case .automatic: ["suggestedTags"]
        case .place: ["placeCity", "placeRegion", "placeCountry"]
        case .camera: ["cameraMake", "cameraModel"]
        case .lens: ["cameraMake", "lensMake", "lensModel"]
        case .artist: ["artist"]
        case .exposure: ["fNumber", "focalLength", "exposureTime", "iso", "exposureBias", "flashFired"]
        }
    }
    /// The tags of `row` from a source with one tag per column; exposure values are written as `exposureCondition` reads them.
    private static func tagValues(_ source: CatalogTagSource, of row: String) -> [String] {
        // A lens make is a tag only when the lens isn't the body maker's own (SIGMA on a SONY), so FUJIFILM
        // isn't offered twice, as a camera and as a lens.
        if source == .lens {
            return ["CASE WHEN \(row).lensMake IS NOT \(row).cameraMake COLLATE NOCASE THEN \(row).lensMake END", "\(row).lensModel"]
        }
        guard source == .exposure else { return tagColumns(source).map { "\(row).\($0)" } }
        return [
            "CASE WHEN \(row).fNumber IS NOT NULL THEN 'f/' || printf('%g', round(\(row).fNumber, 1)) END",
            "CASE WHEN \(row).focalLength IS NOT NULL THEN printf('%g', round(\(row).focalLength)) || 'mm' END",
            "CASE WHEN \(row).exposureTime >= 0.3 THEN printf('%g', round(\(row).exposureTime, 1)) || 's' WHEN \(row).exposureTime IS NOT NULL THEN '1/' || CAST(round(1.0 / \(row).exposureTime) AS INTEGER) || 's' END",
            "CASE WHEN \(row).iso IS NOT NULL THEN 'ISO ' || \(row).iso END",
            "CASE WHEN round(\(row).exposureBias, 1) <> 0 THEN printf('%+g', round(\(row).exposureBias, 1)) || ' EV' END",
            "CASE WHEN \(row).flashFired THEN 'Flash' END",
        ]
    }
    /// Adds the tags of `row` (NEW in a trigger, or every photo with `joining`) from one source. Keywords and
    /// automatic tags are comma-separated: json_quote protects quotes, backslashes and control characters before the
    /// commas are split. Automatic tags are lowercase; the person's own keywords keep their capitals.
    private static func insertTags(_ source: CatalogTagSource, of row: String, joining: Bool) -> String {
        let split: (String) -> String = { "json_each('[' || replace(json_quote(\(row).\($0)), ',', '\",\"') || ']')" }
        let values = source == .keyword || source == .automatic
            ? split(tagColumns(source)[0])
            : "json_each(json_array(\(tagValues(source, of: row).joined(separator: ", "))))"
        let trimmed = "trim(value, char(9) || char(10) || char(13) || ' ')"
        let tag = source == .automatic ? "lower(\(trimmed))" : trimmed
        return """
            INSERT OR IGNORE INTO assetTag(assetID, source, tag, trashed)
                SELECT \(row).id, '\(source.rawValue)', \(tag), \(outOfLibrary(row)) FROM \(joining ? "asset, " : "")\(values)
                WHERE value IS NOT NULL AND \(trimmed) <> '';
            """
    }
    /// Sets the confidence of automatic tags the analysis reported it for.
    static func setTagConfidences(_ confidences: [String: Double], assetID: String, _ db: Database) throws {
        for (tag, confidence) in confidences {
            try db.execute(sql: "UPDATE assetTag SET confidence = ? WHERE assetID = ? AND source = 'automatic' AND tag = ?", arguments: [confidence, assetID, tag])
        }
    }

    /// Tags with a word that starts with the typed text, those that start with it as a whole first, then the
    /// ones most photos have. Scripts without spaces between words match anywhere. Reads only the tag tables.
    nonisolated static func tagSuggestionSQL(trash: Bool, words: Bool, source: Bool) -> String {
        let count = trash ? "trashCount" : "libraryCount"
        let match = words ? "id IN (SELECT rowid FROM tagSearch WHERE tagSearch MATCH ?)" : "tag LIKE ? ESCAPE '\\'"
        return """
            SELECT tag, source, \(count) AS photoCount FROM tagCount WHERE \(match) AND \(count) > 0\(source ? " AND source = ?" : "")
                ORDER BY tag LIKE ? ESCAPE '\\' DESC, \(count) DESC, tag LIMIT ?
            """
    }
    /// The term that matches exactly `tag` from `source`.
    nonisolated static func searchToken(_ tag: String, source: CatalogTagSource) -> String {
        guard let key = source.key else { return tag.filter { !$0.isWhitespace } }
        guard tag.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return key + ":" + tag }
        return key + ":\"" + tag.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    /// The keywords and automatic tags most photos in `area` have, most used first; `limit` nil lists them all. A
    /// keyword and an automatic tag of the same name are offered once, as whichever more photos have.
    public func popularTags(area: CatalogArea = .library, limit: Int? = 40) throws -> [CatalogSearchSuggestion] {
        let count = area != .library ? "trashCount" : "libraryCount"
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT tag, source, \(count) AS photoCount FROM tagCount
                    WHERE source IN ('keyword', 'automatic') AND \(count) > 0 ORDER BY \(count) DESC, tag LIMIT ?
                """, arguments: [limit.map { $0 * 2 } ?? -1])
        }
        var seen = Set<String>(), tags: [CatalogSearchSuggestion] = []
        for row in rows {
            let tag: String = row["tag"]
            guard seen.insert(tag.lowercased()).inserted else { continue }
            let source = CatalogTagSource(rawValue: row["source"]) ?? .automatic
            tags.append(CatalogSearchSuggestion(tag: tag, source: source, photoCount: row["photoCount"], completion: Self.searchToken(tag, source: source)))
            if let limit, tags.count == limit { break }
        }
        return tags
    }
    public func searchSuggestions(for query: String, area: CatalogArea = .library, limit: Int = 8) throws -> [CatalogSearchSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 256 else { return [] }
        return try database.read { db in
            /// `fromStart` matches only tags that start with `typed`, as settings, which are written one way, do.
            func matches(_ typed: String, in source: CatalogTagSource? = nil, preceding: String = "", fromStart: Bool = false) throws -> [CatalogSearchSuggestion] {
                let words = !fromStart && !typed.unicodeScalars.contains(where: Self.isUnspacedScript)
                let pattern: String
                if typed.isEmpty {
                    guard source != nil else { return [] }
                    pattern = "%"
                } else if words {
                    guard typed.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return [] }
                    pattern = "\"" + typed.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
                } else {
                    pattern = (fromStart ? "" : "%") + Self.likePattern(typed) + "%"
                }
                var values: [(any DatabaseValueConvertible)?] = [pattern]
                if let source { values.append(source.rawValue) }
                values += [Self.likePattern(typed) + "%", limit]
                let arguments = StatementArguments(values)
                let sql = Self.tagSuggestionSQL(trash: area != .library, words: words && !typed.isEmpty, source: source != nil)
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                    let tag: String = row["tag"]
                    let source = CatalogTagSource(rawValue: row["source"]) ?? .automatic
                    return CatalogSearchSuggestion(tag: tag, source: source, photoCount: row["photoCount"], completion: preceding + Self.searchToken(tag, source: source))
                }
            }
            // A final term that can only be a setting ("f/", "f2", "iso64", "1/", "+0") is offered settings alone, and
            // one that is already a bound ("<1/500", ">200mm") nothing.
            if let last = Self.searchTermRanges(text).last {
                let term = String(text[last])
                if term.hasPrefix("<") || term.hasPrefix(">") { return [] }
                if term.range(of: #"^(f/|f\d|iso:?\d|1/|[+-]\d)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    let words = term.replacingOccurrences(of: #"^f/?"#, with: "f/", options: [.regularExpression, .caseInsensitive])
                        .replacingOccurrences(of: #"^iso:?"#, with: "iso ", options: [.regularExpression, .caseInsensitive])
                    return try matches(words, in: .exposure, preceding: String(text[..<last.lowerBound]), fromStart: true)
                }
            }
            // Prefer whole phrases ("water b" → "water bird"); otherwise complete the final term and
            // preserve the earlier search terms ("mountain sk" → "mountain sky"). "lens:" offers only lenses.
            if !Self.searchTerms(text).contains(where: { term in term.firstIndex(of: ":").map { CatalogTagSource(key: String(term[..<$0])) != nil } ?? false }) {
                let phrases = try matches(text)
                if !phrases.isEmpty { return phrases }
            }
            guard let last = Self.searchTermRanges(text).last else { return [] }
            let preceding = String(text[..<last.lowerBound])
            let term = String(text[last])
            if let colon = term.firstIndex(of: ":"), let source = CatalogTagSource(key: String(term[..<colon])) {
                return try matches(Self.unquoted(String(term[term.index(after: colon)...])), in: source, preceding: preceding)
            }
            return try matches(term, preceding: preceding)
        }
    }
}

/// How a tag's source is shown beside it in search suggestions, on the Mac and on iPad.
extension CatalogTagSource {
    public var symbol: String {
        switch self {
        case .keyword: "tag.fill"
        case .automatic: "tag"
        case .place: "mappin.and.ellipse"
        case .camera: "camera"
        case .lens: "camera.aperture"
        case .artist: "person"
        case .exposure: "dial.medium"
        }
    }
    public var title: String {
        switch self {
        case .keyword: L10n.tr("Keyword")
        case .automatic: L10n.tr("Automatic tag")
        case .place: L10n.tr("Place")
        case .camera: L10n.tr("Camera")
        case .lens: L10n.tr("Lens")
        case .artist: L10n.tr("Photographer")
        case .exposure: L10n.tr("Exposure")
        }
    }
}
