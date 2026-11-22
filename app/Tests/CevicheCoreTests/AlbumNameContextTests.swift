import XCTest
@testable import CevicheCore

final class AlbumNameContextTests: XCTestCase {
    func testKeepsRecurringFactsAndDropsGenericTags() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        var ids: [String] = []
        for index in 0..<10 {
            var asset = prepared.0; asset.id = UUID().uuidString; asset.importPath += "-\(index)"
            asset.captureDay = "2024-05-0\(index < 5 ? 3 : 9)"
            asset.placeCity = "Lisbon"; asset.placeRegion = "Lisbon"; asset.placeCountry = "Portugal"
            asset.suggestedTags = index < 8 ? "outdoor, sky, tram, street, hoodie" : index == 8 ? "outdoor, dog" : "outdoor"
            asset.keywords = index == 0 ? "Holiday, family" : ""
            ids.append(try await store.insert(asset, thumbnail: prepared.1).id)
        }
        let context = try await store.albumNameContext(assetIDs: ids)
        XCTAssertEqual(context.photos, 10)
        XCTAssertEqual(context.places, [.init(name: "Lisbon, Portugal", count: 10)])
        XCTAssertEqual(context.tags.map(\.name), ["street", "tram"])
        XCTAssertEqual(context.keywords, ["family", "holiday"])
        XCTAssertEqual(context.prompt, """
            Photos: 10
            Taken: 3 May 2024 to 9 May 2024 (7 days)
            Places: Lisbon, Portugal (10)
            Detected subjects: street (8), tram (8)
            Photographer's keywords: family, holiday
            """)
        XCTAssertEqual(context.timePhrase(locale: Locale(identifier: "it")), "maggio 2024")
        let untagged = try await store.albumNameContext(assetIDs: [])
        XCTAssertFalse(untagged.tagged)
    }

    func testDropsTheParentsVisionTagsAlongsideASubject() throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var snow = try CatalogImporter.prepare(url).0.asset, lake = snow
        snow.suggestedTags = "frozen, liquid, snow, water, daytime, blue sky"
        lake.suggestedTags = "liquid, water, water body"
        XCTAssertEqual(AlbumNameContext([snow]).tags.map(\.name), ["snow"])
        XCTAssertEqual(AlbumNameContext([lake]).tags.map(\.name), ["water"])
    }
}
