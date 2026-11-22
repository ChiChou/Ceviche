import XCTest
import AppKit
import CoreImage
import CevicheCore
@testable import CevicheMac

final class MaskEditorTests: XCTestCase {
    @MainActor func testBrushGestureIsOneUndoAndDeletingOneMaskPreservesTheOther() {
        let model = EditorModel()
        let first = PhotoMask(kind: .brush), second = PhotoMask(kind: .radial)
        model.edit { $0.masks = [first, second] }
        model.selectedMaskID = first.id; model.toolTab = .masks; model.maskTool = .brush
        model.beginMask(at: MaskPoint(x: 0.1, y: 0.7))
        model.dragMask(to: MaskPoint(x: 0.4, y: 0.7))
        model.dragMask(to: MaskPoint(x: 0.8, y: 0.7))
        model.endMask()
        XCTAssertEqual(model.undoStack.count, 2)
        XCTAssertEqual(model.adjustments.masks[0].strokes[0].points.count, 3)
        model.undo(); XCTAssertTrue(model.adjustments.masks[0].strokes.isEmpty)
        model.redo(); XCTAssertEqual(model.adjustments.masks[0].strokes[0].points.count, 3)
        model.deleteMask(first.id)
        XCTAssertEqual(model.adjustments.masks, [second])
        model.undo(); XCTAssertEqual(model.adjustments.masks.count, 2)
    }
    @MainActor func testGradientToolsCreateNothingUntilDrawnAndDeleteRemovesTheSelection() throws {
        let model = EditorModel()
        model.toolTab = .masks; model.maskTool = .linear; model.awaitingGradient = true
        // A click without a drag leaves nothing behind and keeps waiting for a line.
        model.beginMask(at: MaskPoint(x: 0.2, y: 0.2)); model.endMask()
        XCTAssertTrue(model.adjustments.masks.isEmpty); XCTAssertTrue(model.awaitingGradient); XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertNil(model.selectedMaskID)
        // The drag creates the mask along the drawn line, as one undo step, and leaves the tool on it for reshaping.
        model.beginMask(at: MaskPoint(x: 0.2, y: 0.2)); model.dragMask(to: MaskPoint(x: 0.6, y: 0.7)); model.endMask()
        XCTAssertEqual(model.adjustments.masks.count, 1)
        XCTAssertEqual(model.adjustments.masks[0].start, MaskPoint(x: 0.2, y: 0.2)); XCTAssertEqual(model.adjustments.masks[0].end, MaskPoint(x: 0.6, y: 0.7))
        XCTAssertFalse(model.awaitingGradient); XCTAssertEqual(model.maskTool, .linear); XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertEqual(model.selectedMaskID, model.adjustments.masks[0].id)
        model.undo(); XCTAssertTrue(model.adjustments.masks.isEmpty); model.redo(); XCTAssertEqual(model.adjustments.masks.count, 1)
        let linear = model.adjustments.masks[0].id
        // Radial: the mouse-down point is the center and the drag sets the extents; Shift keeps a circle.
        model.maskTool = .radial; model.awaitingGradient = true
        model.beginMask(at: MaskPoint(x: 0.5, y: 0.5)); model.dragMask(to: MaskPoint(x: 0.7, y: 0.6), shift: true); model.endMask()
        XCTAssertEqual(model.adjustments.masks.count, 2)
        for (actual, expected) in [(model.adjustments.masks[1].start.x, 0.3), (model.adjustments.masks[1].start.y, 0.3), (model.adjustments.masks[1].end.x, 0.7), (model.adjustments.masks[1].end.y, 0.7)] {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(model.adjustments.masks[1].feather, 0.125); XCTAssertEqual(model.undoStack.count, 2)
        // An ellipse centered near the edge extends past the photo and still saves.
        model.maskTool = .radial; model.awaitingGradient = true
        model.beginMask(at: MaskPoint(x: 0.9, y: 0.5)); model.dragMask(to: MaskPoint(x: 0.5, y: 0.3)); model.endMask()
        XCTAssertEqual(model.adjustments.masks[2].end.x, 1.3, accuracy: 1e-9); XCTAssertEqual(model.adjustments.masks[2].start.y, 0.3, accuracy: 1e-9)
        XCTAssertNoThrow(try model.adjustments.validated())
        // Delete removes the selected mask; with a component selected, only the component.
        model.deleteSelectedMaskOrComponent()
        XCTAssertEqual(model.adjustments.masks.count, 2)
        model.selectMask(linear); model.addComponent(.linear, operation: .subtract)
        XCTAssertTrue(model.awaitingGradient); XCTAssertEqual(model.selectedMaskID, linear)
        model.beginMask(at: MaskPoint(x: 0.1, y: 0.1)); model.dragMask(to: MaskPoint(x: 0.3, y: 0.3)); model.endMask()
        XCTAssertEqual(model.adjustments.masks[0].components.count, 1)
        XCTAssertEqual(model.selectedComponentID, model.adjustments.masks[0].components[0].id)
        XCTAssertEqual(model.adjustments.masks[0].components[0].operation, .subtract)
        model.deleteSelectedMaskOrComponent()
        XCTAssertTrue(model.adjustments.masks[0].components.isEmpty); XCTAssertEqual(model.adjustments.masks.count, 2)
        // Escape leaves the armed tool without touching the masks.
        model.maskTool = .linear; model.awaitingGradient = true
        XCTAssertTrue(model.cancelCanvasTool()); XCTAssertNil(model.maskTool); XCTAssertFalse(model.awaitingGradient)
        XCTAssertFalse(model.cancelCanvasTool())
    }
    @MainActor func testRadialGradientHandlesTurnMoveAndNeverRedraw() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ from: (Double, Double), _ to: (Double, Double)) {
            view.mouseDown(with: event(.leftMouseDown, from.0, from.1)); view.mouseDragged(with: event(.leftMouseDragged, to.0, to.1)); view.mouseUp(with: event(.leftMouseUp, to.0, to.1))
        }
        model.toolTab = .masks; model.maskTool = .radial; model.awaitingGradient = true
        // Draw from the center (300,200) out to (420,260): half-extents 120×60 canvas points = 0.2×0.15 of the photo.
        drag((300, 200), (420, 260))
        XCTAssertEqual(model.adjustments.masks.count, 1)
        let mask = try XCTUnwrap(model.selectedMask)
        XCTAssertEqual(mask.start.x, 0.3, accuracy: 1e-6); XCTAssertEqual(mask.end.y, 0.65, accuracy: 1e-6)
        // The outline between handles turns the ellipse (the point at 45° on the outline, dragged a quarter turn).
        let onOutline = (300 + 120 * cos(Double.pi / 4), 200 - 60 * sin(Double.pi / 4))
        drag(onOutline, (300 - 120 * cos(Double.pi / 4) + 60 * sin(Double.pi / 4), 120))
        XCTAssertNotNil(model.selectedMask?.rotation)
        XCTAssertEqual(model.adjustments.masks.count, 1)
        // Inside the ellipse drags it as a whole.
        let before = try XCTUnwrap(model.selectedMask)
        drag((320, 210), (350, 230))
        let moved = try XCTUnwrap(model.selectedMask)
        XCTAssertEqual(moved.start.x - before.start.x, 0.05, accuracy: 1e-6); XCTAssertEqual(moved.end.x - before.end.x, 0.05, accuracy: 1e-6)
        // A drag elsewhere neither redraws nor starts a mask, as in other RAW editors.
        drag((60, 40), (120, 90))
        XCTAssertEqual(model.adjustments.masks.count, 1); XCTAssertEqual(model.selectedMask?.start, moved.start)
        // Redraw replaces the geometry of the same mask.
        model.redrawGradient = true
        drag((100, 100), (160, 130))
        XCTAssertEqual(model.adjustments.masks.count, 1)
        XCTAssertEqual(try XCTUnwrap(model.selectedMask).start.x, 1.0 / 15, accuracy: 1e-6)
        XCTAssertFalse(model.redrawGradient)
    }
    @MainActor func testTargetedMixerDragMovesTheBandsOfTheSampledHue() {
        let model = EditorModel()
        model.edit { $0.selectiveColors[5].saturation = 10 }
        model.targetedMixer = .saturation
        model.beginGesture(); model.armMixerDrag(hue: 225.0 / 360)
        XCTAssertEqual(model.selectiveColorBand, 5)
        model.updateMixerDrag(points: 40)
        XCTAssertEqual(model.adjustments.selectiveColors[5].saturation, 50)
        XCTAssertEqual(model.adjustments.selectiveColors[4].saturation, 7)
        XCTAssertEqual(model.adjustments.selectiveColors[0].saturation, 0)
        model.updateMixerDrag(points: -400)
        XCTAssertEqual(model.adjustments.selectiveColors[5].saturation, -100)
        model.endMixerDrag()
        XCTAssertEqual(model.undoStack.count, 2)
        model.targetedMixer = .hue
        model.beginGesture(); model.armMixerDrag(hue: 0); model.updateMixerDrag(points: 40); model.endMixerDrag()
        XCTAssertEqual(model.adjustments.selectiveColors[0].hue, 20)
        XCTAssertEqual(model.adjustments.selectiveColors[1].hue, 0)
        XCTAssertTrue(model.cancelCanvasTool()); XCTAssertNil(model.targetedMixer)
        XCTAssertEqual(model.lastMixerProperty, .hue)
    }
    @MainActor func testEscapeDismissesTheArmedToolThenTheToolPanelAndNothingElse() throws {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        // Adjustment panels have nothing to dismiss, so Escape falls through (it never leaves Develop).
        model.toolTab = .light
        XCTAssertFalse(model.dismissTool()); XCTAssertEqual(model.toolTab, .light)
        // Crop: a guide being drawn cancels first; the next Escape closes the tool and undoes its changes (one undo step).
        model.toolTab = .crop; model.setStraighten(3); model.cropDrawingGuide = true
        XCTAssertTrue(model.dismissTool()); XCTAssertFalse(model.cropDrawingGuide); XCTAssertEqual(model.toolTab, .crop)
        XCTAssertTrue(model.dismissTool()); XCTAssertEqual(model.toolTab, .light); XCTAssertEqual(model.adjustments.geometry.straighten, 0)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.straighten, 3)
        // Return (Done) keeps them.
        model.toolTab = .crop; model.setStraighten(5)
        XCTAssertTrue(model.finishCrop()); XCTAssertEqual(model.toolTab, .light); XCTAssertEqual(model.adjustments.geometry.straighten, 5)
        // Remove: a selected stroke is deselected first, then the brush is put down for the pointer, then the panel closes.
        model.toolTab = .remove; model.selectedRetouchID = UUID()
        XCTAssertTrue(model.dismissTool()); XCTAssertNil(model.selectedRetouchID); XCTAssertEqual(model.toolTab, .remove)
        XCTAssertTrue(model.dismissTool()); XCTAssertTrue(model.retouchPointer); XCTAssertEqual(model.toolTab, .remove)
        XCTAssertTrue(model.dismissTool()); XCTAssertEqual(model.toolTab, .light)
        // Masks: a pending gradient, then an armed brush, then a selected component, then the panel; the mask stays selected.
        model.toolTab = .masks; model.maskTool = .linear; model.awaitingGradient = true
        XCTAssertTrue(model.dismissTool()); XCTAssertNil(model.maskTool); XCTAssertEqual(model.toolTab, .masks)
        model.acceptSelection(PhotoMask(kind: .brush), operation: nil, parentID: nil)
        let mask = try XCTUnwrap(model.selectedMaskID)
        model.maskTool = .brush
        XCTAssertTrue(model.dismissTool()); XCTAssertNil(model.maskTool); XCTAssertEqual(model.toolTab, .masks)
        model.redrawGradient = true
        XCTAssertTrue(model.dismissTool()); XCTAssertFalse(model.redrawGradient); XCTAssertEqual(model.toolTab, .masks)
        XCTAssertTrue(model.dismissTool()); XCTAssertEqual(model.toolTab, .light)
        XCTAssertEqual(model.selectedMaskID, mask); XCTAssertNil(model.adjustmentTargetID)
        XCTAssertFalse(model.dismissTool())
    }
    @MainActor func testReturnFinishesGeometryToolsOnly() {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        // Return does nothing in other panels, including Remove and Masks.
        for tab in [ToolTab.light, .remove, .masks] { model.toolTab = tab; XCTAssertFalse(model.finishCrop()); XCTAssertEqual(model.toolTab, tab) }
        model.toolTab = .light
        // Return finishes Crop, putting down guides first when they are being drawn.
        model.toolTab = .crop; model.setStraighten(2)
        XCTAssertTrue(model.finishCrop()); XCTAssertEqual(model.toolTab, .light)
        model.toolTab = .crop; model.cropDrawingGuide = true
        XCTAssertTrue(model.finishCrop())
        XCTAssertEqual(model.toolTab, .crop); XCTAssertFalse(model.cropDrawingGuide); XCTAssertNil(model.guideDraft)
        XCTAssertTrue(model.finishCrop())
        XCTAssertEqual(model.toolTab, .light)
        XCTAssertEqual(model.adjustments.geometry.straighten, 2)
    }
    @MainActor func testToolKeysAreDistinctAndToggleTheInspector() {
        let keys = ToolTab.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isDisjoint(with: ["g", "d", "p", "x", "u", "0", "1", "2", "3", "4", "5", "\\"]))
        for tab in ToolTab.allCases { XCTAssertNotNil(NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil), "\(tab) has a symbol") }
        let model = EditorModel()
        model.showInspector = true; model.toolTab = .light
        model.toggleTool(.crop); XCTAssertEqual(model.toolTab, .crop); XCTAssertTrue(model.showInspector)
        model.toggleTool(.crop); XCTAssertFalse(model.showInspector)
        model.toggleTool(.crop); XCTAssertTrue(model.showInspector)
    }
    /// Darkroom is a panel like Light & Color: it reopens at launch, shows Strip and Ring only for a negative to print, and
    /// Escape returns a proof to the photo without leaving the tab.
    @MainActor func testDarkroomShowsProofsOnlyWhereThereIsAPrintToTime() throws {
        let suite = "DarkroomTests.\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = EditorModel(preferences: preferences)
        model.showInspector = true; model.toolTab = .darkroom
        XCTAssertEqual(preferences.string(forKey: "developToolTab"), ToolTab.darkroom.rawValue)
        XCTAssertFalse(model.printing)
        model.edit { $0.film = FilmSimulation() }
        // Without the film engine the photo keeps the camera's rendering, and there is nothing to proof.
        XCTAssertEqual(model.printing, FilmCatalog.shared.isAvailable)
        model.edit { $0.film?.medium = "negative" }
        XCTAssertFalse(model.printing, "a viewed negative is not printed")
        model.printView = .ring
        XCTAssertTrue(model.dismissTool()); XCTAssertEqual(model.printView, .photo); XCTAssertEqual(model.toolTab, .darkroom)
        XCTAssertFalse(model.dismissTool())
    }
    @MainActor func testCanvasPickingAccountsForFitZoomPanAndRotation() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.model = model
        let context = CIContext(options: [.useSoftwareRenderer: true])
        view.image = try XCTUnwrap(context.createCGImage(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)), from: CGRect(x: 0, y: 0, width: 200, height: 100)))
        view.updateGeometry()
        let original = MaskPoint(x: 0.25, y: 0.75)
        for turn in 0..<4 {
            model.adjustments.quarterTurns = turn
            model.viewport.fit()
            model.zoomImageIn(); model.panImage(by: CGSize(width: 15, height: -10))
            let rect = model.viewport.imageRect(image: CGSize(width: 200, height: 100), canvas: view.bounds.size)
            let p = original.rotated(turn)
            let sampled = try XCTUnwrap(view.maskPoint(CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + (1-p.y)*rect.height), clamp: false))
            XCTAssertEqual(sampled.x, original.x, accuracy: 1e-8)
            XCTAssertEqual(sampled.y, original.y, accuracy: 1e-8)
        }
        XCTAssertNil(view.maskPoint(CGPoint(x: -100, y: -100), clamp: false))
    }
}
