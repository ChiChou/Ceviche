import XCTest
@testable import CevicheMac
import CevicheCore
import AppKit

final class EditorModelTests: XCTestCase {
    @MainActor func testSliderGestureIsOneUndoAndNewEditClearsRedo() {
        let model = EditorModel()
        model.beginGesture()
        model.edit { $0.exposure = 0.25 }
        model.edit { $0.exposure = 0.5 }
        model.edit { $0.exposure = 1 }
        model.endGesture()
        XCTAssertEqual(model.undoStack.count, 1)
        model.undo()
        XCTAssertEqual(model.adjustments.exposure, 0)
        XCTAssertEqual(model.redoStack.count, 1)
        model.redo()
        XCTAssertEqual(model.adjustments.exposure, 1)
        model.undo()
        model.edit { $0.contrast = 10 }
        XCTAssertTrue(model.redoStack.isEmpty)
        XCTAssertTrue(model.dirty)
    }
    @MainActor func testCloseClearsDocumentAndPendingEdits() {
        let model = EditorModel()
        model.edit { $0.exposure = 1 }
        model.closeDocument()
        XCTAssertFalse(model.dirty)
        XCTAssertFalse(model.hasImage)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(model.adjustments.exposure, 0)
    }
    @MainActor func testSectionResetLeavesOtherSectionsAndCanUndo() {
        let model = EditorModel()
        var defaults = Adjustments(); defaults.temperature = 4920; defaults.tint = -3
        model.info = ImageInfo(filename: "a.ARW", width: 100, height: 100, isRAW: true, defaults: defaults)
        model.edit { $0.exposure = 2; $0.shadows = 40; $0.temperature = 8000; $0.monochrome = true; $0.clarity = 30 }
        model.addCurvePoint(x: 0.3, y: 0.4)
        let before = model.adjustments
        model.resetSection(.light)
        XCTAssertEqual(model.adjustments.exposure, 0)
        XCTAssertEqual(model.adjustments.shadows, 0)
        XCTAssertEqual(model.adjustments.temperature, 8000)
        XCTAssertEqual(model.adjustments.curve, before.curve)
        model.undo(); XCTAssertEqual(model.adjustments, before)
        model.resetSection(.color)
        XCTAssertEqual(model.adjustments.temperature, 4920)
        XCTAssertEqual(model.adjustments.tint, -3)
        XCTAssertFalse(model.adjustments.monochrome)
        XCTAssertEqual(model.adjustments.exposure, 2)
        model.resetSection(.curve)
        XCTAssertEqual(model.adjustments.curve, ToneCurve())
        XCTAssertEqual(model.adjustments.clarity, 30)
        model.resetSection(.detail)
        XCTAssertEqual(model.adjustments.clarity, 0)
    }
    @MainActor func testSectionSwitchKeepsSettingsAndUndoRestoresEnableState() {
        let model = EditorModel()
        model.edit { $0.exposure = 2; $0.selectiveColors[1].hue = 30; $0.vignette = 75 }
        let settings = model.adjustments
        model.setSection(.light, enabled: false)
        XCTAssertEqual(model.adjustments.exposure, 2)
        XCTAssertTrue(model.adjustments.disabledSections.contains(.light))
        model.undo(); XCTAssertEqual(model.adjustments, settings)
        model.redo(); XCTAssertTrue(model.adjustments.disabledSections.contains(.light))
        model.setSection(.light, enabled: true); XCTAssertEqual(model.adjustments, settings)
        model.resetSection(.selectiveColor)
        XCTAssertEqual(model.adjustments.selectiveColors, SelectiveColor.defaults)
        XCTAssertEqual(model.adjustments.vignette, 75)
    }
    @MainActor func testHistogramDragTargetsAllRegionsClampsAndGroupsUndo() {
        for region in HistogramRegion.allCases {
            let model = EditorModel()
            XCTAssertEqual(HistogramRegion.at((Double(region.rawValue) + 0.5) / 5), region)
            model.beginHistogramDrag(region)
            model.updateHistogramDrag(translation: 0.1)
            model.updateHistogramDrag(translation: 0.25)
            model.endHistogramDrag()
            XCTAssertEqual(model.adjustments[keyPath: region.key], region == .exposure ? 2.5 : 50)
            for other in HistogramRegion.allCases where other != region { XCTAssertEqual(model.adjustments[keyPath: other.key], 0) }
            XCTAssertEqual(model.undoStack.count, 1)
            model.undo(); XCTAssertEqual(model.adjustments[keyPath: region.key], 0)
            model.redo(); XCTAssertEqual(model.adjustments[keyPath: region.key], region == .exposure ? 2.5 : 50)
            model.beginHistogramDrag(region)
            model.updateHistogramDrag(translation: -100)
            model.endHistogramDrag()
            XCTAssertEqual(model.adjustments[keyPath: region.key], region.range.lowerBound)
        }
    }
    @MainActor func testNativeCurveClickDragDoubleClickAndContextMenu() throws {
        let model = EditorModel()
        let view = CurveControl(frame: NSRect(x: 0, y: 0, width: 214, height: 214))
        view.model = model
        // Convert graph coordinates to the window coordinate system used by native events.
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 67, 147))
        view.mouseUp(with: event(.leftMouseUp, 67, 147))
        XCTAssertEqual(model.adjustments.curve.points.count, 3)
        XCTAssertEqual(model.undoStack.count, 1)
        let point = model.adjustments.curve.points[1]
        let start = NSPoint(x: 7 + point.x * 200, y: 7 + (1 - point.y) * 200)
        view.mouseDown(with: event(.leftMouseDown, start.x, start.y))
        view.mouseDragged(with: event(.leftMouseDragged, 87, 107))
        view.mouseUp(with: event(.leftMouseUp, 87, 107))
        XCTAssertEqual(model.adjustments.curve.points[1].x, 0.4, accuracy: 1e-8)
        XCTAssertEqual(model.adjustments.curve.points[1].y, 0.5, accuracy: 1e-8)
        XCTAssertEqual(model.undoStack.count, 2)
        let menu = try XCTUnwrap(view.menu(for: event(.rightMouseDown, 87, 107)))
        XCTAssertEqual(menu.items.first?.title, "Remove Point")
        view.mouseDown(with: event(.leftMouseDown, 87, 107, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, 87, 107, clicks: 2))
        XCTAssertEqual(model.adjustments.curve.points.count, 2)
        model.undo(); XCTAssertEqual(model.adjustments.curve.points.count, 3)
        let item = try XCTUnwrap(menu.items.first)
        _ = (item.target as? NSObject)?.perform(item.action)
        XCTAssertEqual(model.adjustments.curve.points.count, 2)
    }

}
