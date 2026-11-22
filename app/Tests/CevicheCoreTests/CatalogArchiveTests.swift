import XCTest
import GRDB
@testable import CevicheCore

final class CatalogArchiveTests: XCTestCase {
    func testArchiveLeavesLibraryKeepsFileAndComesBack() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var prepared = try CatalogImporter.prepare(url).0; prepared.suggestedTags = "sky"
        let asset = try await store.insert(prepared, thumbnail: nil)
        var other = prepared; other.id = "other"; other.importPath += "-other"
        _ = try await store.insert(other, thumbnail: nil)

        let archived = try await store.archive([asset.id])
        XCTAssertEqual(archived, [asset.id])
        let stored = try await store.asset(asset.id)
        XCTAssertNotNil(stored.archivedAt); XCTAssertNil(stored.trashedAt); XCTAssertEqual(stored.area, .archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let library = try await store.assets(), groups = try await store.groups()
        XCTAssertEqual(library.map(\.id), ["other"])
        XCTAssertEqual(groups.total, 1); XCTAssertEqual(groups.archive, 1); XCTAssertEqual(groups.trash, 0)
        var filter = CatalogFilter(); filter.area = .archive
        let inArchive = try await store.assets(filter: filter)
        XCTAssertEqual(inArchive.map(\.id), [asset.id])
        filter.area = .trash
        let inTrash = try await store.count(filter: filter); XCTAssertEqual(inTrash, 0)
        // Tags count it as out of the library.
        let suggestions = try await store.searchSuggestions(for: "sk")
        XCTAssertEqual(suggestions.map(\.photoCount), [1])

        // Trashed from the archive, it shows in the Trash, and recovering it puts it back in the archive.
        try await store.moveToTrash(asset.id)
        let trashedGroups = try await store.groups()
        XCTAssertEqual(trashedGroups.trash, 1); XCTAssertEqual(trashedGroups.archive, 0)
        try await store.recoverFromTrash(asset.id)
        let recovered = try await store.asset(asset.id)
        XCTAssertEqual(recovered.area, .archive)

        try await store.unarchive([asset.id])
        let back = try await store.asset(asset.id)
        XCTAssertEqual(back.area, .library)
        let all = try await store.groups(); XCTAssertEqual(all.total, 2); XCTAssertEqual(all.archive, 0)
        let restored = try await store.searchSuggestions(for: "sk")
        XCTAssertEqual(restored.map(\.photoCount), [2])
    }

    func testArchiveSyncs() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let asset = try await store.insert(try CatalogImporter.prepare(url).0, thumbnail: nil)
        try await store.archive([asset.id])
        let states = try await store.syncStates([asset.id])
        let state = try XCTUnwrap(states.first)
        XCTAssertNotNil(state.archivedAt)
        // A state from a build before the archive decodes with none.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "archivedAt")
        let old = try JSONDecoder().decode(CatalogSyncState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.archivedAt)
        var unarchived = state; unarchived.archivedAt = nil; unarchived.updatedAt = state.updatedAt.addingTimeInterval(10)
        let changed = try await store.applyRemote(CatalogSyncPhoto(assetID: asset.id, state: unarchived))
        XCTAssertTrue(changed)
        let after = try await store.asset(asset.id)
        XCTAssertEqual(after.area, .library)
    }
}
