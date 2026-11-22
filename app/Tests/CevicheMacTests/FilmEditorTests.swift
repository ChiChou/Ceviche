import XCTest
import CevicheCore
@testable import CevicheMac

final class FilmEditorTests: XCTestCase {
    @MainActor func testChannelEditingUndoAndResetStayIsolated() {
        let model = EditorModel()
        model.curveChannel = .red
        model.beginGesture()
        let point = model.addCurvePoint(x: 0.4,y: 0.6)!
        model.moveCurvePoint(at: point,x: 0.45,y: 0.7)
        model.endGesture()
        XCTAssertTrue(model.adjustments.curve.isIdentity)
        XCTAssertFalse(model.adjustments.redCurve.isIdentity)
        XCTAssertEqual(model.undoStack.count, 1)
        model.undo(); XCTAssertTrue(model.adjustments.redCurve.isIdentity)
        model.redo(); XCTAssertFalse(model.adjustments.redCurve.isIdentity)
        model.edit { $0.grain.amount = 35; $0.splitToning.shadowSaturation = 30 }
        model.resetSection(.curve)
        XCTAssertTrue(model.adjustments.redCurve.isIdentity)
        XCTAssertEqual(model.adjustments.grain.amount, 35)
        model.setSection(.grain, enabled: false)
        XCTAssertEqual(model.adjustments.grain.amount, 35)
        XCTAssertEqual(model.adjustments.effective(defaults: Adjustments()).grain.amount, 0)
        model.undo(); XCTAssertFalse(model.adjustments.disabledSections.contains(.grain))
        model.closeDocument()
    }
}
