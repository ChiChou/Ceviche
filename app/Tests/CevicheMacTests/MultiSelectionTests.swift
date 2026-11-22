import XCTest
@testable import CevicheMac

/// The one set of selection rules every multi-select list follows.
final class MultiSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testClickSelectsOneAndSetsTheAnchor() {
        var selection = MultiSelection<String>(ids: ["a", "b"], anchor: "a")
        selection.click("c", in: order)
        XCTAssertEqual(selection, MultiSelection(ids: ["c"], anchor: "c"))
    }

    func testShiftSelectsTheRangeFromTheAnchorEitherWay() {
        var selection = MultiSelection<String>()
        selection.click("b", in: order)
        selection.click("d", in: order, extending: true)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])
        XCTAssertEqual(selection.anchor, "b", "The anchor stays, so the next ⇧-click redraws the range")
        selection.click("a", in: order, extending: true)
        XCTAssertEqual(selection.ids, ["a", "b"])
    }

    func testCommandTogglesAndMovesTheAnchor() {
        var selection = MultiSelection<String>()
        selection.click("b", in: order)
        selection.click("d", in: order, toggling: true)
        XCTAssertEqual(selection.ids, ["b", "d"]); XCTAssertEqual(selection.anchor, "d")
        selection.click("b", in: order, toggling: true)
        XCTAssertEqual(selection.ids, ["d"])
    }

    func testShiftCommandAddsTheRange() {
        var selection = MultiSelection<String>()
        selection.click("a", in: order)
        selection.click("d", in: order, toggling: true)
        selection.click("e", in: order, extending: true, toggling: true)
        XCTAssertEqual(selection.ids, ["a", "d", "e"])
    }

    func testShiftWithoutAnAnchorInTheListActsAsAClick() {
        var selection = MultiSelection<String>(ids: ["x"], anchor: "x")
        selection.click("c", in: order, extending: true)
        XCTAssertEqual(selection, MultiSelection(ids: ["c"], anchor: "c"))
    }

    func testSelectAllKeepsAnAnchorInsideAndClearForgetsIt() {
        var selection = MultiSelection<String>(ids: ["c"], anchor: "c")
        selection.selectAll(order)
        XCTAssertEqual(selection.ids, Set(order)); XCTAssertEqual(selection.anchor, "c")
        selection = MultiSelection(ids: [], anchor: "x")
        selection.selectAll(order)
        XCTAssertEqual(selection.anchor, "a")
        selection.clear()
        XCTAssertEqual(selection, MultiSelection<String>())
    }
}
