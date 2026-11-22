import XCTest
import Metal
import CevicheCore
@testable import CevicheMac

final class InspectorControlsTests: XCTestCase {
    func testMixedRatingClickSetsValueRatherThanClearing() {
        XCTAssertEqual(StarRatingDrag.committedRating(3, previous: nil, horizontalTravel: 0), 3)
        XCTAssertEqual(StarRatingDrag.committedRating(3, previous: 3, horizontalTravel: 0), 0)
        XCTAssertEqual(StarRatingDrag.committedRating(3, previous: 3, horizontalTravel: 30), 3)
        XCTAssertEqual(StarRatingDrag.committedRating(0, previous: nil, horizontalTravel: -30), 0)
    }

    @MainActor func testDefringeEyedropperUpdatesTheSelectedMaskInOneEdit() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel()
        let opened = await model.open(photo)
        XCTAssertTrue(opened)
        var mask = PhotoMask(kind: .radial)
        mask.adjustments.defringe.greenAmount = 16
        model.edit { $0.masks = [mask] }
        model.adjustmentTargetID = mask.id
        model.toolTab = .detail
        let before = model.adjustments, undoCount = model.undoStack.count
        model.toggleEyedropper(.defringe(.green))
        model.pickColor(at: MaskPoint(x: 0.5, y: 0.5))
        for _ in 0..<100 where model.eyedropper != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.eyedropper)
        XCTAssertEqual(model.adjustments.defringe, before.defringe)
        XCTAssertEqual(model.targetAdjustments.defringe.greenAmount, 16)
        XCTAssertNotEqual(model.targetAdjustments.defringe.greenHigh, mask.adjustments.defringe.greenHigh)
        XCTAssertEqual(model.undoStack.count, undoCount + 1)
        model.undo()
        XCTAssertEqual(model.adjustments, before)
    }
}
