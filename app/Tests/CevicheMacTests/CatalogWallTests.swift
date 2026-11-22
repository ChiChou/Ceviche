import XCTest
import CevicheCore
@testable import CevicheMac

/// The wall lays photos out in rows that fill the width; G switches between it and the tile grid.
final class CatalogWallTests: XCTestCase {
    func testRowsFillTheWidthAndTheLastRowKeepsItsHeight() {
        // Seven 3:2 photos at a 100-point row height are 150 points each: the fourth overflows 460 points, so the
        // row takes four and shrinks to fit; the three left over do not fill a row and keep the height.
        let layout = WallLayout(aspects: Array(repeating: 1.5, count: 7), width: 460, rowHeight: 100, spacing: 2)
        XCTAssertEqual(layout.rows.map(\.range), [0..<4, 4..<7])
        XCTAssertEqual(layout.rows[0].widths.reduce(0, +) + 6, 460, accuracy: 0.001)
        XCTAssertEqual(layout.rows[0].height, (460 - 6) / 6, accuracy: 0.001)
        let last = try! XCTUnwrap(layout.rows.last)
        XCTAssertEqual(last.height, 100); XCTAssertEqual(last.widths, [150, 150, 150])
        // Portrait photos take less width, so more of them share a row; a panorama wider than the row shrinks to fit.
        let mixed = WallLayout(aspects: [0.67, 0.67, 0.67, 0.67, 4, 1.5], width: 260, rowHeight: 100, spacing: 0)
        XCTAssertEqual(mixed.rows.map(\.range), [0..<4, 4..<5, 5..<6])
        XCTAssertEqual(mixed.rows[0].height, 260 / 2.68, accuracy: 0.001)
        XCTAssertEqual(mixed.rows[1].height, 65, accuracy: 0.001); XCTAssertEqual(mixed.rows[1].widths, [260])
        XCTAssertEqual(mixed.rows[2].height, 100); XCTAssertEqual(mixed.rows[2].widths, [150])
        XCTAssertTrue(WallLayout(aspects: [1.5], width: 0, rowHeight: 100).rows.isEmpty)
        XCTAssertTrue(WallLayout(aspects: [], width: 300, rowHeight: 100).rows.isEmpty)
    }
    func testArrowKeysMoveBetweenRowsOfDifferentLengths() {
        let rows: [Range<Int>] = [0..<3, 3..<8, 8..<10]
        // Down from the end of a three-photo row lands at the end of the five-photo row; up from its middle lands in the middle.
        XCTAssertEqual(CatalogGridMove.down.destination(from: 2, count: 10, columns: 4, rows: rows), 7)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 0, count: 10, columns: 4, rows: rows), 3)
        XCTAssertEqual(CatalogGridMove.up.destination(from: 5, count: 10, columns: 4, rows: rows), 1)
        XCTAssertEqual(CatalogGridMove.up.destination(from: 1, count: 10, columns: 4, rows: rows), 1)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 9, count: 10, columns: 4, rows: rows), 9)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 7, count: 10, columns: 4, rows: rows), 9)
        // Left and right ignore the rows, and without rows the column count rules as before.
        XCTAssertEqual(CatalogGridMove.right.destination(from: 2, count: 10, columns: 4, rows: rows), 3)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 2, count: 10, columns: 4), 6)
    }
    @MainActor func testGridStylePersistsAndGCyclesBetweenTheGridsInEitherWindow() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        XCTAssertEqual(model.gridStyle, .tiles)
        model.pressGrid(editor: editor); XCTAssertEqual(model.gridStyle, .wall); XCTAssertTrue(model.showingLibrary)
        model.pressGrid(editor: editor); XCTAssertEqual(model.gridStyle, .tiles)
        // From the photo, G returns to the grid as it was.
        model.gridStyle = .wall
        model.show(.detail, editor: editor)
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        model.pressGrid(editor: editor)
        // The grid becomes visible before closePhoto finishes refreshing the catalog. Wait until navigation
        // accepts another command before switching the secondary window (otherwise this races that refresh).
        for _ in 0..<300 where !model.showingLibrary || model.interactionBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.interactionBusy)
        XCTAssertTrue(model.showingLibrary); XCTAssertEqual(model.gridStyle, .wall)
        // In the secondary window G cycles its own grid, and only when it shows the grid.
        XCTAssertTrue(model.showSecondary(.detail, editor: editor))
        model.pressGrid(secondary: true, editor: editor)
        XCTAssertEqual(model.secondaryViewMode, .grid); XCTAssertEqual(model.gridStyle, .wall)
        model.pressGrid(secondary: true, editor: editor); XCTAssertEqual(model.gridStyle, .tiles)
        let suite = UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        CatalogModel(preferences: preferences).gridStyle = .wall
        XCTAssertEqual(CatalogModel(preferences: preferences).gridStyle, .wall)
    }
}
