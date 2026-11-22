import XCTest
import CevicheCore
@testable import CevicheMac

/// The secondary window shows the grid or the photo; the grid is in one window at a time, the photo may be in both.
final class SecondaryWindowTests: XCTestCase {
    @MainActor func testDisconnectingDisplayReturnsSecondaryPhotoToMainWindow() {
        let model = CatalogModel()
        model.updateDisplayCount(2)
        XCTAssertTrue(model.hasSecondaryDisplay)
        model.viewMode = .grid; model.secondaryViewMode = .detail
        model.updateDisplayCount(1)
        XCTAssertFalse(model.hasSecondaryDisplay)
        XCTAssertNil(model.secondaryViewMode)
        XCTAssertEqual(model.viewMode, .detail)
        model.updateDisplayCount(2)
        XCTAssertTrue(model.hasSecondaryDisplay)
        XCTAssertNil(model.secondaryViewMode, "Reconnecting offers the menu without opening a window unexpectedly")
    }
    @MainActor func testGridIsInOneWindowAndThePhotoStaysOpenBetweenThem() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let first = model.assets[0]
        XCTAssertNil(model.secondaryViewMode)
        // Closed, the menu offers the view the main window is not showing.
        XCTAssertEqual(model.secondaryViewChoice, .detail)
        XCTAssertFalse(model.showSecondary(.compare, editor: editor))
        // The grid on the secondary sends the main window to Detail with the first photo.
        XCTAssertTrue(model.showSecondary(.grid, editor: editor))
        XCTAssertEqual(model.secondaryViewMode, .grid)
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .detail); XCTAssertEqual(editor.catalogAssetID, first.id)
        XCTAssertTrue(model.gridVisible)
        // G in the main window: the photo moves to the secondary instead of closing.
        model.show(.grid, editor: editor)
        for _ in 0..<300 where !model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .grid); XCTAssertEqual(model.secondaryViewMode, .detail)
        XCTAssertTrue(editor.hasImage); XCTAssertEqual(editor.catalogAssetID, first.id)
        // Asking the secondary for Detail again changes nothing; asking for the grid flips the main window back.
        XCTAssertTrue(model.showSecondary(.detail, editor: editor)); XCTAssertEqual(model.viewMode, .grid)
        XCTAssertTrue(model.showSecondary(.grid, editor: editor))
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .detail); XCTAssertEqual(model.secondaryViewMode, .grid)
        // Compare in the main window leaves the grid where it is.
        model.show(.compare, editor: editor); XCTAssertEqual(model.viewMode, .compare); XCTAssertEqual(model.secondaryViewMode, .grid)
        model.show(.detail, editor: editor)
        // Closing the secondary while the main window shows the photo keeps it; closing while the main window
        // shows the grid closes the photo, since no window shows it any more.
        model.closeSecondaryWindow(editor: editor)
        XCTAssertNil(model.secondaryViewMode); XCTAssertTrue(editor.hasImage); XCTAssertEqual(model.viewMode, .detail)
        // Detail on the secondary beside Detail in the main window: both show the photo, and Compare keeps it there.
        XCTAssertTrue(model.canShowSecondary(.detail, editor: editor))
        XCTAssertTrue(model.showSecondary(.detail, editor: editor))
        XCTAssertEqual(model.viewMode, .detail); XCTAssertEqual(model.secondaryViewMode, .detail); XCTAssertTrue(model.secondaryMirrorsPhoto)
        model.show(.compare, editor: editor); XCTAssertEqual(model.secondaryViewMode, .detail); XCTAssertTrue(model.secondaryMirrorsPhoto)
        model.show(.detail, editor: editor); XCTAssertEqual(model.secondaryViewMode, .detail)
        model.show(.grid, editor: editor)
        for _ in 0..<300 where !model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .grid); XCTAssertEqual(model.secondaryViewMode, .detail)
        XCTAssertTrue(editor.hasImage); XCTAssertFalse(model.secondaryMirrorsPhoto)
        model.closeSecondaryWindow(editor: editor)
        for _ in 0..<300 where editor.hasImage { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.hasImage); XCTAssertEqual(model.viewMode, .grid)
        // Without a secondary window, leaving Detail closes the photo as before.
        model.show(.detail, editor: editor)
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        await model.closePhoto(editor: editor)
        XCTAssertFalse(editor.hasImage); XCTAssertNil(model.secondaryViewMode)
    }
    @MainActor func testGridSelectionOpensThePhotoInTheOtherWindowAndDevelopTakesItBack() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let first = model.assets[0], second = model.assets[1], third = model.assets[2]
        // The secondary shows Detail of nothing until the grid has a selection.
        XCTAssertTrue(model.showSecondary(.detail, editor: editor))
        await model.followSelection(editor: editor)
        XCTAssertFalse(editor.hasImage)
        model.select(second)
        for _ in 0..<300 where model.selected?.id != second.id { try await Task.sleep(for: .milliseconds(10)) }
        await model.followSelection(editor: editor)
        XCTAssertEqual(editor.catalogAssetID, second.id); XCTAssertEqual(model.viewMode, .grid)
        XCTAssertEqual(model.secondaryViewMode, .detail)
        // A multiple selection shows its focused photo and stays a multiple selection.
        model.select(third, extending: true)
        for _ in 0..<300 where model.selected?.id != third.id { try await Task.sleep(for: .milliseconds(10)) }
        await model.followSelection(editor: editor)
        XCTAssertEqual(editor.catalogAssetID, third.id); XCTAssertEqual(model.selectedIDs, [second.id, third.id])
        XCTAssertEqual(model.cullingTargets(editor: editor).map(\.id).sorted(), [second.id, third.id].sorted())
        // Developing from the grid opens the photo in the main window; the secondary keeps showing it.
        model.develop(first, editor: editor)
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .detail); XCTAssertEqual(model.secondaryViewMode, .detail)
        XCTAssertEqual(editor.catalogAssetID, first.id); XCTAssertEqual(model.selectedIDs, [first.id])
        // With the secondary window closed, nothing follows.
        model.closeSecondaryWindow(editor: editor)
        model.select(second)
        for _ in 0..<300 where model.selected?.id != second.id { try await Task.sleep(for: .milliseconds(10)) }
        await model.followSelection(editor: editor)
        XCTAssertEqual(editor.catalogAssetID, first.id)
    }
}
