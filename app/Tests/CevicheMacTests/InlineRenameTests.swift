import XCTest
import AppKit
@testable import CevicheMac

final class InlineRenameTests: XCTestCase {
    @MainActor func testDraftCommitsOnceAndTrimsOnFocusLoss() {
        let field = InlineRenameField()
        field.stringValue = "Original"
        var names: [String] = []
        field.onCommit = { names.append($0) }
        field.beginRename(); field.stringValue = "  Renamed  "
        XCTAssertTrue(names.isEmpty)
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        field.finishRename(save: true)
        XCTAssertEqual(names, ["Renamed"])
        XCTAssertEqual(field.stringValue, "Renamed")
        XCTAssertFalse(field.isEditable)
    }
    @MainActor func testEscapeEmptyAndUnchangedDoNotCommit() {
        let field = InlineRenameField()
        field.stringValue = "Original"
        var names: [String] = []
        field.onCommit = { names.append($0) }
        field.beginRename(); field.stringValue = "Discard"
        XCTAssertTrue(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        XCTAssertEqual(field.stringValue, "Original")
        field.beginRename(); field.stringValue = " \n "
        field.finishRename(save: true)
        XCTAssertEqual(field.stringValue, "Original")
        field.beginRename(); field.finishRename(save: true)
        XCTAssertTrue(names.isEmpty)
    }
    @MainActor func testDoubleClickStartsEditingWithoutSelectingOrApplying() throws {
        let field = InlineRenameField()
        field.stringValue = "Snapshot"
        var selected = false
        field.onSelect = { selected = true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        field.mouseDown(with: event)
        XCTAssertTrue(field.renaming)
        XCTAssertFalse(selected)
        field.finishRename(save: false)
        field.isEnabled = false; field.mouseDown(with: event)
        XCTAssertFalse(field.renaming)
    }
}
