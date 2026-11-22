import XCTest
import CevicheCore
@testable import CevicheMac

final class CatalogUndoTests: XCTestCase {
    @MainActor private func settle(_ model: CatalogModel) async throws {
        for _ in 0..<50 where model.catalogBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
    }
    @MainActor func testRatingMetadataAndTrashUndoAndRedo() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        await model.setQuickMetadata([photos[0], photos[1]], rating: 4)
        XCTAssertEqual(model.undoTitle, "Undo Rating")
        model.undo(); try await settle(model)
        var first = try await store.asset(photos[0].id)
        XCTAssertEqual(first.rating, 0)
        model.redo(); try await settle(model)
        first = try await store.asset(photos[0].id)
        XCTAssertEqual(first.rating, 4)

        await model.selectAsset(photos[2])
        model.metadata.title = "Dolomites"
        let saved = await model.flushMetadata()
        XCTAssertTrue(saved)
        await model.setQuickMetadata([photos[2]], rating: 2)
        model.undo(); try await settle(model)   // rating
        model.undo(); try await settle(model)   // title, keeping nothing else
        let third = try await store.asset(photos[2].id)
        XCTAssertEqual(third.title, "")
        XCTAssertEqual(model.metadata.title, "", "The inspector shows the restored value")

        await model.moveToTrash([photos[3]], editor: editor)
        XCTAssertEqual(model.undoTitle, "Undo Move to Trash")
        model.undo(); try await settle(model)
        let recovered = try await store.asset(photos[3].id)
        XCTAssertNil(recovered.trashedAt)
        XCTAssertTrue(model.assets.contains { $0.id == photos[3].id })
    }
    @MainActor func testRestoringHistoryShowsRestoredMetadata() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.selectAsset(model.assets[0])
        model.metadata.title = "Later title"
        let saved = await model.flushMetadata()
        XCTAssertTrue(saved)
        let imported = try XCTUnwrap(model.history.last { $0.summary == "Imported metadata" })
        model.restore(imported)
        for _ in 0..<50 where model.metadata.title != "" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.metadata.title, "")
        XCTAssertFalse(model.metadataPending, "Restoring does not queue a save of stale values")
    }
    @MainActor func testBatchKeywordsKeepEachPhotosOwnAndUndo() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        var metadata = photos[0].metadata; metadata.keywords = "alps"
        try await store.updateMetadata(metadata, assetID: photos[0].id)
        await model.addKeywords("Dolomites, Alps", to: [photos[0], photos[1]])
        var first = try await store.asset(photos[0].id)
        let second = try await store.asset(photos[1].id)
        XCTAssertEqual(first.keywords, "alps, Dolomites", "Existing keywords stay; duplicates ignore case")
        XCTAssertEqual(second.keywords, "Dolomites, Alps")
        XCTAssertEqual(model.undoTitle, "Undo Add Keywords")
        model.undo(); try await settle(model)
        first = try await store.asset(photos[0].id)
        XCTAssertEqual(first.keywords, "alps")
    }
}
