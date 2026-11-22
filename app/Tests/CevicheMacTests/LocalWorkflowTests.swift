import XCTest
import AppKit
import CoreImage
import CevicheCore
@testable import CevicheMac

final class LocalWorkflowTests: XCTestCase {
    @MainActor func testTargetControlsUndoAndResetStayOnSelectedMask() throws {
        let model = EditorModel(), mask = PhotoMask(kind: .linear)
        model.edit { $0.exposure = 0.3; $0.masks = [mask] }; model.selectMask(mask.id)
        model.toolTab = .light; model.curveChannel = .red
        _ = model.addCurvePoint(x: 0.4, y: 0.7)
        model.beginGesture(); model.editTarget { $0.selectiveColors[2].hue = 15 }; model.editTarget { $0.selectiveColors[2].hue = 25 }; model.endGesture()
        XCTAssertEqual(model.adjustments.selectiveColors[2].hue, 0)
        XCTAssertEqual(model.selectedMask?.adjustments.selectiveColors[2].hue, 25)
        XCTAssertTrue(model.adjustments.redCurve.isIdentity); XCTAssertFalse(try XCTUnwrap(model.selectedMask).adjustments.redCurve.isIdentity)
        model.undo(); XCTAssertEqual(model.selectedMask?.adjustments.selectiveColors[2].hue, 0)
        model.redo(); XCTAssertEqual(model.selectedMask?.adjustments.selectiveColors[2].hue, 25)
        model.setSection(.curve, enabled: false); XCTAssertTrue(try XCTUnwrap(model.selectedMask).adjustments.disabledSections.contains(.curve))
        model.resetSection(.curve); XCTAssertTrue(try XCTUnwrap(model.selectedMask).adjustments.redCurve.isIdentity)
        model.beginHistogramDrag(.exposure); model.updateHistogramDrag(translation: 0.2); model.endHistogramDrag()
        XCTAssertEqual(model.adjustments.exposure, 0.3); XCTAssertNotEqual(model.selectedMask?.adjustments.exposure, 0)
        model.setAdjustmentTarget(nil); model.editTarget { $0.exposure = 1 }; XCTAssertEqual(model.adjustments.exposure, 1)
        model.selectMask(mask.id); model.toolTab = .detail; model.refineTarget(); XCTAssertEqual(model.toolTab, .masks)
        model.editSelectedMask(); XCTAssertEqual(model.toolTab, .detail)
    }
    @MainActor func testComponentsDuplicateCopyOrderAndUndo() throws {
        let model = EditorModel(), a = PhotoMask(kind: .radial), b = PhotoMask(kind: .linear)
        model.edit { $0.masks = [a, b] }; model.selectMask(a.id); model.toolTab = .masks
        model.addComponent(.brush, operation: .subtract)
        model.beginMask(at: .init(x: 0.4, y: 0.4)); model.dragMask(to: .init(x: 0.6, y: 0.4)); model.endMask()
        XCTAssertTrue(try XCTUnwrap(model.selectedMask).strokes.isEmpty)
        XCTAssertEqual(model.selectedMask?.components[0].selection.strokes[0].points.count, 2)
        model.undo(); XCTAssertTrue(try XCTUnwrap(model.selectedMask).components[0].selection.strokes.isEmpty)
        model.redo(); model.editTarget { $0.exposure = 0.8; $0.blueCurve.insert(x: 0.4, y: 0.5) }
        model.copyMaskAdjustments(); model.selectMask(b.id); model.pasteMaskAdjustments()
        XCTAssertEqual(model.adjustments.masks[0].adjustments, model.adjustments.masks[1].adjustments)
        XCTAssertTrue(model.adjustments.masks[1].components.isEmpty)
        model.duplicateMask(a.id)
        let copy = try XCTUnwrap(model.selectedMask)
        XCTAssertNotEqual(copy.id, a.id); XCTAssertNotEqual(copy.components[0].id, model.adjustments.masks[0].components[0].id)
        model.moveMask(copy.id, by: -1); XCTAssertEqual(model.adjustments.masks[1].id, copy.id)
        model.undo(); XCTAssertEqual(model.adjustments.masks[2].id, copy.id)
        model.deleteMask(copy.id); XCTAssertFalse(model.isLocalTarget)
    }
    @MainActor func testBundledSkyWorksAcrossPhotosWithoutSetup() async throws {
        guard BundledModel.sky.isAvailable else { throw XCTSkip("Run with CEVICHE_MODELS pointing at compiled bundled models") }
        let relaunched = EditorModel()
        let ctx = CIContext(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["first", "second"] {
            let source = dir.appendingPathComponent(name + ".png")
            try XCTUnwrap(ctx.pngRepresentation(of: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)), format: .RGBA8, colorSpace: RGBProfile.sRGB.space)).write(to: source)
            await relaunched.open(source); XCTAssertTrue(relaunched.skyAvailable)
            relaunched.addMask(.sky)
            for _ in 0..<200 where relaunched.isSelecting { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertFalse(relaunched.isSelecting); XCTAssertNil(relaunched.error); XCTAssertEqual(relaunched.adjustments.masks.count, 1)
        }
        relaunched.closeDocument()
    }
}
