import XCTest
@testable import CevicheMac

/// The Library's rows are placed from their known heights, and only those near the visible part are built.
final class RowStackTests: XCTestCase {
    func testRowsArePlacedFromTheirHeights() {
        let stack = RowStack(heights: [100, 50, 100], spacing: 10, inset: 16)
        XCTAssertEqual(stack.tops, [16, 126, 186])
        XCTAssertEqual(stack.total, 16 + 100 + 10 + 50 + 10 + 100 + 16)
        XCTAssertEqual(RowStack(heights: [], spacing: 10, inset: 16).total, 32)
    }
    func testOnlyRowsNearTheVisiblePartAreShown() {
        let stack = RowStack(heights: Array(repeating: 100, count: 10_000), spacing: 10, inset: 0)
        // Jumping to the end finds the last rows directly.
        let end = CGRect(x: 0, y: stack.total - 500, width: 800, height: 500)
        XCTAssertEqual(stack.rows(in: end, margin: 0), 9_995..<10_000)
        XCTAssertEqual(stack.rows(in: CGRect(x: 0, y: 0, width: 800, height: 205), margin: 0), 0..<2)
        XCTAssertTrue(stack.rows(in: CGRect(x: 0, y: 105, width: 800, height: 1), margin: 0).isEmpty, "the gap between rows shows none")
        XCTAssertEqual(stack.rows(in: CGRect(x: 0, y: 0, width: 800, height: 205), margin: 220), 0..<4)
        XCTAssertEqual(RowStack(heights: [], spacing: 10, inset: 0).rows(in: end, margin: 100), 0..<0)
    }
}
