import XCTest
@testable import CevicheCore

final class CatalogStackTests: XCTestCase {
    func testGroupLeftWithOnePhotoIsTakenApart() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        var ids: [String] = []
        for second in 0..<4 {
            var asset = prepared.0; asset.id = "photo-\(second)"; asset.importPath += "-\(second)"
            asset.captureDay = "2026-10-31"; asset.captureTime = "2026-10-31T21:00:0\(second)"
            ids.append(try await store.insert(asset, thumbnail: nil).id)
        }
        // Moved to the Trash: the photo left is on its own, and the trashed one comes back on its own.
        try await store.stack([ids[0], ids[1]])
        try await store.moveToTrash(ids[1])
        var left = try await store.asset(ids[0]); XCTAssertNil(left.stackID)
        try await store.recoverFromTrash(ids[1])
        var back = try await store.asset(ids[1]); XCTAssertNil(back.stackID)
        var sizes = try await store.stackSizes(); XCTAssertEqual(sizes, [:])
        // Trashing the cover of a pair takes it apart too.
        try await store.stack([ids[2], ids[3]])
        try await store.moveToTrash(ids[2])
        left = try await store.asset(ids[3]); XCTAssertNil(left.stackID)
        back = try await store.asset(ids[2]); XCTAssertNil(back.stackID)
        sizes = try await store.stackSizes(); XCTAssertEqual(sizes, [:])
    }

    func testGroupsFoldToTheirEarliestPhotoUntilExpanded() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        let store = try CatalogStore(root: root)
        let prepared = try CatalogImporter.prepare(url)
        var ids: [String] = []
        for second in 0..<4 {
            var asset = prepared.0; asset.id = "photo-\(second)"; asset.importPath += "-\(second)"
            asset.captureDay = "2026-10-31"; asset.captureTime = "2026-10-31T21:00:0\(second)"
            ids.append(try await store.insert(asset, thumbnail: nil).id)
        }
        func shown(_ filter: CatalogFilter = CatalogFilter()) async throws -> [String] { try await store.assets(filter: filter).map(\.id).sorted() }

        let cover = try await store.stack([ids[3], ids[1], ids[2]])
        XCTAssertEqual(cover, ids[1])
        var result = try await shown(); XCTAssertEqual(result, [ids[0], ids[1]])
        var count = try await store.count(filter: CatalogFilter()); XCTAssertEqual(count, 2)
        let sizes = try await store.stackSizes(); XCTAssertEqual(sizes, [ids[1]: 3])
        var expanded = CatalogFilter(); expanded.expandedStacks = [ids[1]]
        result = try await shown(expanded); XCTAssertEqual(result, ids)

        // A group's photos show on their own where the cover doesn't match.
        var metadata = try await store.asset(ids[2]).metadata; metadata.rating = 4
        try await store.updateMetadata(metadata, assetID: ids[2])
        var rated = CatalogFilter(); rated.minimumRating = 4
        result = try await shown(rated); XCTAssertEqual(result, [ids[2]])
        // A cover moved to the Trash hands the group to its earliest remaining photo, and comes back into it.
        try await store.moveToTrash(ids[1])
        result = try await shown(); XCTAssertEqual(result, [ids[0], ids[2]])
        let handed = try await store.stackSizes(); XCTAssertEqual(handed, [ids[2]: 2])
        try await store.recoverFromTrash(ids[1])
        let back = try await store.stackSizes(); XCTAssertEqual(back, [ids[2]: 3])

        // Grouping a photo with a member joins the whole group; the earliest becomes the cover.
        let joined = try await store.stack([ids[0], ids[3]])
        XCTAssertEqual(joined, ids[0])
        result = try await shown(); XCTAssertEqual(result, [ids[0]])
        let state = try await store.syncStates([ids[2]])[0]; XCTAssertEqual(state.stackID, ids[0])

        // Undo puts the groups back as they were.
        let grouped = try await store.stackState([ids[2]])
        try await store.unstack([ids[2]])
        result = try await shown(); XCTAssertEqual(result, ids)
        try await store.restoreStacks(grouped)
        let reopened = try CatalogStore(root: root)
        result = try await reopened.assets().map(\.id); XCTAssertEqual(result, [ids[0]])
    }
}
