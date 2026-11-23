import XCTest
import GRDB
@testable import CevicheCore

final class CatalogTagSearchTests: XCTestCase {
    func testPrefixesPhrasesLiteralWildcardsAndKeywords() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var asset = try CatalogImporter.prepare(url).0
        asset.suggestedTags = " SKY, sky, skyline, water bird, water, 100% blue, 100_percent, 1000, path\\name, say \"hi\", ,\n"
        var metadata = asset.metadata; metadata.keywords = "sketch"; asset.metadata = metadata
        _ = try await store.insert(asset, thumbnail: nil)
        let sky = try await store.searchSuggestions(for: "SK")
        XCTAssertEqual(sky.map(\.tag), ["sketch", "sky", "skyline"])
        XCTAssertEqual(sky.map(\.source), [.keyword, .automatic, .automatic])
        XCTAssertEqual(sky.map(\.photoCount), [1, 1, 1], "Repeated labels on one photo count once")
        let phrase = try await store.searchSuggestions(for: "water b")
        XCTAssertEqual(phrase.map(\.completion), ["tag:\"water bird\""])
        let terms = try await store.searchSuggestions(for: "mountain sk")
        XCTAssertEqual(terms.map(\.completion), ["mountain keyword:sketch", "mountain tag:sky", "mountain tag:skyline"])
        // Punctuation separates words; a tag that starts with the typed text as written comes first.
        for (query, expected) in [("100%", "100% blue"), ("100_", "100_percent"), ("path\\", "path\\name"), ("say \"", "say \"hi\"")] {
            let result = try await store.searchSuggestions(for: query)
            XCTAssertEqual(result.first?.tag, expected, query)
        }
        let quoted = try await store.searchSuggestions(for: "say")
        XCTAssertEqual(quoted.map(\.completion), ["tag:\"say \"\"hi\"\"\""])
        var filter = CatalogFilter(); filter.search = try XCTUnwrap(quoted.first?.completion)
        let picked = try await store.count(filter: filter); XCTAssertEqual(picked, 1)
        let limited = try await store.searchSuggestions(for: "s", limit: 1)
        XCTAssertEqual(limited.count, 1)
        for query in ["", " \n", "no match", String(repeating: "x", count: 257)] {
            let empty = try await store.searchSuggestions(for: query); XCTAssertTrue(empty.isEmpty)
        }
    }

    func testPopularTagsListKeywordsAndAutomaticTagsByCount() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var asset = try CatalogImporter.prepare(url).0; asset.suggestedTags = "sky, beach"
        var metadata = asset.metadata; metadata.keywords = "Sky, Trip"; asset.metadata = metadata
        _ = try await store.insert(asset, thumbnail: nil)
        var copy = asset; copy.id = "copy"; copy.importPath += "-copy"; copy.suggestedTags = "sky"
        var copyMetadata = copy.metadata; copyMetadata.keywords = ""; copy.metadata = copyMetadata
        _ = try await store.insert(copy, thumbnail: nil)
        // "sky" twice as a tag beats "Sky" once as a keyword; places and cameras are not offered.
        let popular = try await store.popularTags()
        XCTAssertEqual(popular.map(\.tag), ["sky", "beach", "Trip"])
        XCTAssertEqual(popular.map(\.completion), ["tag:sky", "tag:beach", "keyword:Trip"])
        let top = try await store.popularTags(limit: 1); XCTAssertEqual(top.map(\.tag), ["sky"])
        let all = try await store.popularTags(limit: nil); XCTAssertEqual(all.count, 3)
        try await store.moveToTrash(copy.id)
        let trash = try await store.popularTags(area: .trash); XCTAssertEqual(trash.map(\.tag), ["sky"])
    }

    func testWorkerUpdatesTrashRecoveryAndDeletionMaintainCounts() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var asset = try CatalogImporter.prepare(url).0; asset.suggestedTags = "sky, skyline"
        _ = try await store.insert(asset, thumbnail: nil)
        var copy = asset; copy.id = "copy"; copy.importPath += "-copy"
        _ = try await store.insert(copy, thumbnail: nil)
        let two = try await store.searchSuggestions(for: "sk")
        XCTAssertEqual(two.map(\.photoCount), [2, 2])
        try await store.moveToTrash(asset.id)
        let library = try await store.searchSuggestions(for: "sk")
        let trash = try await store.searchSuggestions(for: "sk", area: .trash)
        XCTAssertEqual(library.map(\.photoCount), [1, 1]); XCTAssertEqual(trash.map(\.photoCount), [1, 1])
        let worker = try CatalogStore(root: store.root, existingOnly: true)
        let pending = try await worker.claimAnalysis(owner: "tag-test", version: CatalogImporter.analysisVersion)
        let claim = try XCTUnwrap(pending)
        XCTAssertEqual(claim.asset.id, copy.id)
        let applied = try await worker.finishAnalysis(claim, tags: "snow, SNOW, snowfield", version: CatalogImporter.analysisVersion)
        XCTAssertTrue(applied)
        let removed = try await store.searchSuggestions(for: "sk"); XCTAssertTrue(removed.isEmpty)
        let snow = try await store.searchSuggestions(for: "sn")
        XCTAssertEqual(snow.map(\.photoCount), [1, 1])
        try await store.recoverFromTrash(asset.id)
        let recovered = try await store.searchSuggestions(for: "sk")
        let emptyTrash = try await store.searchSuggestions(for: "sk", area: .trash)
        XCTAssertEqual(recovered.map(\.photoCount), [1, 1]); XCTAssertTrue(emptyTrash.isEmpty)
        // The delete trigger also covers sync deletes and deletes through other connections.
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "DELETE FROM asset") }
        let counts = try await db.read { try Int.fetchOne($0, sql: "SELECT (SELECT count(*) FROM tagCount) + (SELECT count(*) FROM assetTag)") }
        XCTAssertEqual(counts, 0)
    }


    func testLookupReadsOnlyTheTagIndexes() async throws {
        let (directory, _) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        for trash in [false, true] {
            let words = try await db.read {
                try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + CatalogStore.tagSuggestionSQL(trash: trash, words: true, source: false), arguments: ["\"sk\"*", "sk%", 8])
                    .map { $0["detail"] as String }.joined(separator: "\n")
            }
            XCTAssertTrue(words.contains("VIRTUAL TABLE INDEX"), words)
            XCTAssertTrue(words.contains("tagCount USING INTEGER PRIMARY KEY"), words)
            XCTAssertFalse(words.contains("SCAN tagCount") || words.contains("asset"), words)
            let source = try await db.read {
                try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + CatalogStore.tagSuggestionSQL(trash: trash, words: false, source: true), arguments: ["%", "lens", "%", 8])
                    .map { $0["detail"] as String }.joined(separator: "\n")
            }
            XCTAssertTrue(source.contains("SEARCH tagCount USING INDEX tagCount_source"), source)
        }
    }

    func testSearchSplitsIntoChipsAndText() {
        let (tokens, text) = CatalogSearchToken.split("mountain lens:\"FE 24-70mm F2.8 GM\" f/2.8 sky iso>=3200 camera:ILCE-7RM5 +0.7ev F8")
        XCTAssertEqual(tokens.map(\.label), ["FE 24-70mm F2.8 GM", "f/2.8", "ISO ≥ 3200", "ILCE-7RM5", "+0.7 EV", "f/8"])
        XCTAssertEqual(tokens.map(\.source), [.lens, .exposure, .exposure, .camera, .exposure, .exposure])
        XCTAssertEqual(text, "mountain sky")
        XCTAssertEqual(CatalogSearchToken.search(tokens, text: text), "lens:\"FE 24-70mm F2.8 GM\" f/2.8 iso>=3200 camera:ILCE-7RM5 +0.7ev F8 mountain sky")
        for term in ["lens:", "lens:\"FE 24", "camera", "f/", "flash", "unknown:x", "f<2.8x"] {
            XCTAssertNil(CatalogSearchToken(term), term)
        }
        XCTAssertEqual(CatalogSearchToken("f<2.8")?.label, "f < 2.8"); XCTAssertEqual(CatalogSearchToken(">200mm")?.label, "> 200mm")
        XCTAssertEqual(CatalogSearchToken("tag:\"police car\"")?.label, "police car")
    }
}
