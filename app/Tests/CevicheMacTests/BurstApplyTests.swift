import XCTest
import CevicheCore
@testable import CevicheMac

/// Pick from Bursts' Apply: flags for one burst and a group for another, in one undoable step.
final class BurstApplyTests: XCTestCase {
    @MainActor private func settle(_ model: CatalogModel) async throws {
        for _ in 0..<50 where model.catalogBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
    }
    @MainActor func testFlagsAndGroupsApplyAndUndoTogether() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        XCTAssertGreaterThanOrEqual(photos.count, 5)
        // One burst picked from (0, 1), another grouped under its second frame (2, 3, 4) with its flags left alone.
        await model.applyCulling([photos[0].id: .accepted, photos[1].id: .rejected],
                                 groups: [CullingChanges.Group(members: [photos[2].id, photos[3].id, photos[4].id], cover: photos[3].id)])
        XCTAssertEqual(model.notice, "Flags changed on 2 photos: 1 rejected, 1 picked; 1 burst grouped")
        var grouped = try await store.asset(photos[2].id)
        XCTAssertEqual(grouped.stackID, photos[3].id); XCTAssertEqual(grouped.review, photos[2].review)
        let flagged = try await store.asset(photos[1].id); XCTAssertEqual(flagged.review, .rejected)

        model.undo(); try await settle(model)
        grouped = try await store.asset(photos[2].id)
        XCTAssertNil(grouped.stackID)
        let restored = try await store.asset(photos[1].id); XCTAssertEqual(restored.review, photos[1].review)
        model.redo(); try await settle(model)
        let regrouped = try await store.asset(photos[4].id), picked = try await store.asset(photos[0].id)
        XCTAssertEqual(regrouped.stackID, photos[3].id); XCTAssertEqual(picked.review, .accepted)
    }
}
