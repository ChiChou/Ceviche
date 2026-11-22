import XCTest
import Combine
@testable import CevicheCore
@testable import CevicheMac

/// The menu bar and the filmstrip follow `EditorMenuState`, not the editor, so a slider does not rebuild them.
@MainActor
final class EditorMenuStateTests: XCTestCase {
    func testSliderEditsLeaveTheMenusAloneAndMenuChangesReachThem() async throws {
        let editor = EditorModel()
        let state = editor.menuState
        var published = 0
        let watch = state.$values.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        for step in 1...20 { editor.adjustments.exposure = Double(step) / 20 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(published, 0, "Exposure changes nothing the menus show")
        editor.showInspector.toggle()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(published, 1)
        XCTAssertEqual(state.values.showInspector, editor.showInspector)
    }

    func testSelectionKeepsTheGridOrder() {
        let catalog = CatalogModel()
        let photos = (0..<5).map { index in
            CatalogAsset(id: "p\(index)", importPath: "file:///p\(index).jpg", sourcePath: "/p\(index).jpg", bookmark: nil, filename: "p\(index).jpg", kind: "JPG",
                         infoData: Data(), xmpWarnings: "", title: "", caption: "", keywords: "", rating: 0, review: .unreviewed, captureDay: "",
                         latitude: nil, longitude: nil, suggestedTags: "", analysisVersion: nil, thumbnailKey: nil, thumbnailRenderKey: nil,
                         renderKey: "", importedAt: Date(), updatedAt: Date(), origin: "file:///p\(index).jpg")
        }
        catalog.assets = photos
        XCTAssertEqual(catalog.assets(withIDs: ["p3", "p0", "gone"]).map(\.id), ["p0", "p3"])
        catalog.assets = Array(photos.reversed())
        XCTAssertEqual(catalog.assets(withIDs: ["p3", "p0"]).map(\.id), ["p3", "p0"], "A new list is indexed again")
    }
}
