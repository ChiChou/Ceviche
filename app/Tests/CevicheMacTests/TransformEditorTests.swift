import XCTest
import AppKit
import CevicheCore
@testable import CevicheMac

final class TransformEditorTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        return model
    }
    @MainActor func testManualGestureUndoAndCropRecovery() {
        let model = model()
        model.beginGesture(); model.setManualTransform(\.vertical, to: 50); model.setManualTransform(\.vertical, to: 0); model.endGesture()
        XCTAssertEqual(model.adjustments.geometry.crop, .full)
        XCTAssertTrue(model.undoStack.isEmpty)
        model.beginGesture(); model.setManualTransform(\.scale, to: 80); model.setManualTransform(\.offsetX, to: 10); model.endGesture()
        XCTAssertEqual(model.undoStack.count, 1)
        let edited = model.adjustments
        model.undo(); XCTAssertEqual(model.adjustments.geometry.transform, ManualTransform()); XCTAssertEqual(model.adjustments.geometry.crop, .full)
        model.redo(); XCTAssertEqual(model.adjustments, edited)
    }
    @MainActor func testIndependentResetsAndTabState() throws {
        let model = model()
        model.adjustments.geometry.constrainCrop = false
        model.adjustments.geometry.crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        model.adjustments.geometry.straighten = 5; model.adjustments.geometry.flipHorizontal = true; model.adjustments.quarterTurns = 1
        model.setManualTransform(\.vertical, to: 25)
        model.adjustments.geometry.guides = [UprightGuide(axis: .vertical, start: .init(x: 0.2, y: 0.1), end: .init(x: 0.2, y: 0.9))]
        let before = model.adjustments
        model.resetTransform()
        XCTAssertEqual(model.adjustments.geometry.crop, before.geometry.crop)
        XCTAssertEqual(model.adjustments.geometry.straighten, 5); XCTAssertEqual(model.adjustments.quarterTurns, 1)
        XCTAssertTrue(model.adjustments.geometry.flipHorizontal); XCTAssertTrue(model.adjustments.geometry.guides.isEmpty)
        model.undo(); XCTAssertEqual(model.adjustments, before)
        model.resetCrop()
        XCTAssertEqual(model.adjustments.geometry.transform, before.geometry.transform)
        XCTAssertEqual(model.adjustments.geometry.guides, before.geometry.guides)
        XCTAssertEqual(model.adjustments.geometry.crop, .full); XCTAssertEqual(model.adjustments.quarterTurns, 0)
        model.toolTab = .crop; model.toggleGuideDrawing()
        XCTAssertTrue(model.cropDrawingGuide)
        XCTAssertEqual(model.displayAdjustments.geometry.crop, .full)
        model.toolTab = .light; XCTAssertFalse(model.cropDrawingGuide, "Leaving Crop puts the guide tool down")
        model.toolTab = .crop; model.toggleStraightenRuler(); XCTAssertTrue(model.cropStraightening)
        model.toggleGuideDrawing(); XCTAssertFalse(model.cropStraightening, "Drawing guides puts the ruler down")
        model.toggleStraightenRuler(); XCTAssertFalse(model.cropDrawingGuide, "The ruler puts the guide tool down")
    }
    @MainActor func testCropRotationAndFlipsKeepManualCorrectionOnTheSubject() throws {
        let model = model()
        model.adjustments.geometry.constrainCrop = false
        model.adjustments.geometry.crop = CropRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        model.setManualTransform(\.vertical, to: 25); model.setManualTransform(\.horizontal, to: -10)
        model.setManualTransform(\.aspect, to: 50); model.setManualTransform(\.rotate, to: 3)
        model.setManualTransform(\.offsetX, to: 15); model.setManualTransform(\.offsetY, to: -10)
        model.toolTab = .light
        let subject = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
        for operation in [{ model.rotateCrop(1) }, { model.flipCrop(horizontal: true) }, { model.rotateCrop(-1) }, { model.flipCrop(horizontal: false) }] {
            operation()
            let center = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
            XCTAssertEqual(center.x, subject.x, accuracy: 0.002)
            XCTAssertEqual(center.y, subject.y, accuracy: 0.002)
        }
    }
    /// A fast drag past a turned photo's edge ends on the edge and slides along it.
    @MainActor func testCropDragReachesTheEdgeOfATurnedPhoto() {
        let model = model()
        model.setStraighten(8)
        let start = model.adjustments.geometry.crop
        // Shrunk first, so the frame has room to move.
        let small = CropRect(x: start.x + start.width / 4, y: start.y + start.height / 4, width: start.width / 2, height: start.height / 2)
        func movedSmall(_ offset: CGPoint) -> CropRect? { var crop = small; crop.x += offset.x; crop.y += offset.y; return crop }
        // A start that doesn't fit gives nothing to reach from.
        XCTAssertNil(ImageCanvas.reach(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 6), frame: movedSmall, fits: model.cropFitsImage))
        let hit = ImageCanvas.reach(from: .zero, to: CGPoint(x: 0.5, y: 0.02), frame: movedSmall, fits: model.cropFitsImage)
        XCTAssertNotNil(hit)
        guard let hit else { return }
        XCTAssertTrue(model.cropFitsImage(hit.crop))
        // On the edge: a hair further right no longer fits.
        XCTAssertFalse(model.cropFitsImage(CropRect(x: hit.crop.x + 0.002, y: hit.crop.y, width: hit.crop.width, height: hit.crop.height)))
        XCTAssertGreaterThan(hit.point.x, 0.05)
    }
    @MainActor func testInvalidManualChangeIsNotApplied() {
        let model = model()
        let before = model.adjustments
        model.setManualTransform(\.rotate, to: 90)
        XCTAssertEqual(model.adjustments, before); XCTAssertNotNil(model.guideMessage); XCTAssertTrue(model.undoStack.isEmpty)
    }
    @MainActor func testConstrainRejectsAnImageEntirelyOutsideTheCanvas() {
        let model = model()
        model.setManualTransform(\.scale, to: 50)
        model.setManualTransform(\.offsetX, to: 100)
        XCTAssertEqual(model.adjustments.geometry.transform.offsetX, 0); XCTAssertNotNil(model.guideMessage)
        model.setConstrainCrop(false); model.setManualTransform(\.offsetX, to: 100)
        XCTAssertEqual(model.adjustments.geometry.transform.offsetX, 100)
        model.setConstrainCrop(true)
        XCTAssertFalse(model.adjustments.geometry.constrainCrop); XCTAssertNotNil(model.guideMessage)
    }
}

final class UprightModeEditorTests: XCTestCase {
    @MainActor private func model() -> EditorModel {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.toolTab = .crop
        return model
    }
    private var identity: UprightAnalysis { UprightAnalysis(auto: UprightAnalysis.identity, level: UprightAnalysis.identity, vertical: UprightAnalysis.identity, full: UprightAnalysis.identity) }
    /// Perspective crop in the Crop tab: the corners tool places a frame in one undo step and shows the photo
    /// unrectified while it is up; a dragged corner is kept only while the four make a quadrilateral; Upright and
    /// the perspective crop let go of each other.
    @MainActor func testPerspectiveCornersToolPlacesMovesAndRemoves() throws {
        let model = model()
        model.setUprightMode(.guided)
        model.togglePerspectiveCorners()
        XCTAssertTrue(model.cropPlacingCorners); XCTAssertFalse(model.cropDrawingGuide)
        XCTAssertEqual(model.adjustments.geometry.perspective, PerspectiveCrop())
        XCTAssertEqual(model.adjustments.geometry.uprightMode, .off)
        XCTAssertEqual(model.undoStack.count, 2)
        XCTAssertEqual(model.geometryPlan?.fullSize, CGSize(width: 600, height: 400), "The corners are placed on the whole photo")
        var moved = PerspectiveCrop.inset; moved[0] = MaskPoint(x: 0.3, y: 0.8)
        model.cornerDraft = moved; model.acceptCorners()
        XCTAssertEqual(model.adjustments.geometry.perspective?.corners, moved); XCTAssertNil(model.cornerDraft)
        var dented = moved; dented[0] = MaskPoint(x: 0.7, y: 0.3)
        model.cornerDraft = dented; model.acceptCorners()
        XCTAssertEqual(model.adjustments.geometry.perspective?.corners, moved, "A dented quadrilateral is not kept")
        XCTAssertNotNil(model.guideMessage)
        model.setPerspectiveProportion(.square)
        XCTAssertTrue(model.finishCrop()); XCTAssertFalse(model.cropPlacingCorners); XCTAssertEqual(model.toolTab, .crop, "Return puts the corners down first")
        let size = try XCTUnwrap(model.outputSize)
        XCTAssertEqual(size.width, size.height); XCTAssertEqual(model.geometryPlan?.fullSize, size)
        model.togglePerspectiveCorners(); XCTAssertTrue(model.cropPlacingCorners)
        XCTAssertTrue(model.cancelCanvasTool()); XCTAssertFalse(model.cropPlacingCorners)
        model.setUprightMode(.guided)
        XCTAssertNil(model.adjustments.geometry.perspective)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.perspective?.proportion, .square)
        model.removePerspective()
        XCTAssertNil(model.adjustments.geometry.perspective); XCTAssertEqual(model.adjustments.geometry.crop, .full)
    }
    @MainActor func testGuidedPicksUpTheToolAndOtherModesPutItDown() {
        let model = model()
        model.setUprightMode(.guided)
        XCTAssertEqual(model.adjustments.geometry.uprightMode, .guided); XCTAssertTrue(model.cropDrawingGuide)
        XCTAssertEqual(model.undoStack.count, 1)
        model.setUprightMode(.off)
        XCTAssertEqual(model.adjustments.geometry.uprightMode, .off); XCTAssertFalse(model.cropDrawingGuide)
        model.setUprightMode(.level)
        XCTAssertTrue(model.adjustments.geometry.needsUprightAnalysis, "Without a renderer the analysis waits")
        XCTAssertEqual(model.geometryPlan?.uprightMessage, "Analyzing the photo…")
        XCTAssertFalse(model.cropDrawingGuide)
    }
    @MainActor func testFirstAnalysisFillsEveryRememberedStateWithoutAnUndoStep() {
        let model = model()
        model.setUprightMode(.vertical)
        model.beginGesture(); model.setManualTransform(\.rotate, to: 2)
        let analysis = identity
        model.editSilently { if $0.geometry.uprightAnalysis == nil { $0.geometry.uprightAnalysis = analysis } }
        model.endGesture()
        XCTAssertEqual(model.adjustments.geometry.uprightAnalysis, analysis)
        XCTAssertEqual(model.undoStack.count, 2)
        XCTAssertTrue(model.undoStack.allSatisfy { $0.geometry.uprightAnalysis == analysis }, "The analysis belongs to the photo, so earlier states carry it too")
        model.undo(); model.undo()
        XCTAssertEqual(model.adjustments.geometry.uprightMode, .off)
        XCTAssertEqual(model.adjustments.geometry.uprightAnalysis, analysis)
        XCTAssertTrue(model.dirty, "The analysis is saved with the photo")
    }
    @MainActor func testCropTabShowsTheWholePhotoBehindTheFrame() {
        let model = model()
        model.adjustments.geometry.constrainCrop = false
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        model.adjustments.geometry.crop = crop
        XCTAssertEqual(model.displayAdjustments.geometry.crop, .full, "The crop frame is drawn over the whole photo")
        model.setUprightMode(.guided)
        XCTAssertEqual(model.displayAdjustments.geometry.crop, .full, "Guides are drawn on the whole photo")
        model.cropDrawingGuide = false
        model.setConstrainCrop(true)
        XCTAssertEqual(model.displayAdjustments.geometry.crop, .full)
        model.toolTab = .light
        XCTAssertEqual(model.displayAdjustments.geometry.crop, model.adjustments.geometry.crop, "Other panels show the crop as it will export")
    }
    @MainActor func testSwitchResetAndTransferClearWhatTheyShould() throws {
        let model = model()
        model.adjustments.geometry.uprightMode = .full; model.adjustments.geometry.uprightAnalysis = identity
        model.setManualTransform(\.vertical, to: 10)
        model.setTransformEnabled(false)
        XCTAssertFalse(model.adjustments.geometry.uprightEnabled); XCTAssertFalse(model.adjustments.geometry.transform.enabled)
        XCTAssertFalse(model.adjustments.geometry.uprightActive)
        XCTAssertEqual(model.adjustments.geometry.transform.vertical, 10, "Bypassing keeps the values")
        model.setTransformEnabled(true)
        XCTAssertTrue(model.adjustments.geometry.uprightActive)
        let transfer = EditTransfer(sourceName: "a", adjustments: model.adjustments, items: [.crop, .transform])
        let pasted = try transfer.applying(to: Adjustments())
        XCTAssertEqual(pasted.geometry.uprightMode, .full); XCTAssertNil(pasted.geometry.uprightAnalysis, "Another photo is analysed afresh")
        model.resetTransform()
        XCTAssertEqual(model.adjustments.geometry.uprightMode, .off); XCTAssertNil(model.adjustments.geometry.uprightAnalysis)
        XCTAssertTrue(model.adjustments.geometry.transform.isIdentity)
    }
}
