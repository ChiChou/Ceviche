import XCTest
import AppKit
import CoreImage
import CevicheCore
@testable import CevicheMac

final class GeometryEditorTests: XCTestCase {
    @MainActor func testGuidesKeepCropAndDrawingMode() {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.toolTab = .crop
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        model.adjustments.geometry.crop = crop
        model.cropDrawingGuide = true
        model.guideDraft = UprightGuide(axis: .vertical, start: .init(x: 0.3, y: 0.2), end: .init(x: 0.35, y: 0.8))
        model.acceptGuide()
        XCTAssertEqual(model.adjustments.geometry.crop, crop, "Adding a guide must not discard framing")
        XCTAssertTrue(model.cropDrawingGuide, "Draw stays active for the next guide")
    }
    @MainActor func testStraightenGestureDoesNotPermanentlyShrinkCrop() {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.beginGesture()
        model.setStraighten(25)
        model.setStraighten(0)
        model.endGesture()
        XCTAssertEqual(model.adjustments.geometry.crop, .full, "Returning the slider to zero restores the starting crop")
    }
    @MainActor func testSwitchingUprightModeGivesBackTheFrameTheStrongerModeCropped() {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        let keystone = [1, 0, 0, 0, 1, 0, 0, 0.3, 1]
        model.adjustments.geometry.uprightAnalysis = UprightAnalysis(auto: keystone, level: UprightAnalysis.identity, vertical: keystone, full: keystone)
        model.setUprightMode(.auto)
        XCTAssertLessThan(model.adjustments.geometry.crop.width, 0.95, "Constrain Crop hides Auto's empty corners")
        model.setUprightMode(.level)
        XCTAssertEqual(model.adjustments.geometry.crop, .full, "Level changes nothing here, so the whole photo is the crop")
        model.setUprightMode(.auto)
        let drawn = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        model.edit { $0.geometry.crop = drawn }
        model.setUprightMode(.level)
        XCTAssertEqual(model.adjustments.geometry.crop, drawn, "A frame drawn by hand stays")
        model.beginGesture(); model.setManualTransform(\.rotate, to: 10); model.setManualTransform(\.rotate, to: 0); model.endGesture()
        XCTAssertEqual(model.adjustments.geometry.crop, drawn)
    }
    func testOneVerticalAndOneHorizontalGuideBothCorrect() throws {
        var settings = GeometryAdjustments()
        let v = UprightGuide(axis: .vertical, start: .init(x: 0.3, y: 0.1), end: .init(x: 0.4, y: 0.9))
        let h = UprightGuide(axis: .horizontal, start: .init(x: 0.1, y: 0.3), end: .init(x: 0.9, y: 0.4))
        settings.guides = [v, h]; settings.uprightMode = .guided
        let plan = try GeometryPlan(size: CGSize(width: 600, height: 400), settings: settings, quarterTurns: 0)
        XCTAssertEqual(plan.displayPoint(v.start).x, plan.displayPoint(v.end).x, accuracy: 0.001)
        XCTAssertEqual(plan.displayPoint(h.start).y, plan.displayPoint(h.end).y, accuracy: 0.001)
    }
    @MainActor func testRulerAndGuideEndpointGesturesAreUndoable() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        model.toolTab = .crop
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        model.cropStraightening = true
        view.mouseDown(with: event(.leftMouseDown, 100, 100)); view.mouseDragged(with: event(.leftMouseDragged, 500, 140)); view.mouseUp(with: event(.leftMouseUp, 500, 140))
        XCTAssertEqual(model.adjustments.geometry.straighten, -atan(0.1) * 180 / .pi, accuracy: 0.001)
        XCTAssertEqual(model.undoStack.count, 1); XCTAssertFalse(model.cropStraightening)
        model.undo(); model.toolTab = .crop; model.viewport.fit(); model.cropDrawingGuide = true
        view.mouseDown(with: event(.leftMouseDown, 100, 100)); view.mouseDragged(with: event(.leftMouseDragged, 100, 300)); view.mouseUp(with: event(.leftMouseUp, 100, 300))
        XCTAssertEqual(model.adjustments.geometry.guides.count, 1); XCTAssertTrue(model.cropDrawingGuide)
        let original = try XCTUnwrap(model.adjustments.geometry.guides.first)
        let count = model.undoStack.count
        view.mouseDown(with: event(.leftMouseDown, 100, 300)); view.mouseDragged(with: event(.leftMouseDragged, 120, 320)); view.mouseUp(with: event(.leftMouseUp, 120, 320))
        XCTAssertEqual(model.adjustments.geometry.guides.count, 1)
        XCTAssertEqual(model.adjustments.geometry.guides[0].id, original.id)
        XCTAssertNotEqual(model.adjustments.geometry.guides[0].end, original.end)
        XCTAssertEqual(model.undoStack.count, count + 1)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.guides[0], original)
        model.selectedGuideID = original.id; model.deleteSelectedGuide(); XCTAssertTrue(model.adjustments.geometry.guides.isEmpty)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.guides[0], original)
    }
    func testAllFourGuidesCanBeVertical() throws {
        var geometry = GeometryAdjustments()
        geometry.guides = [0.15, 0.35, 0.55, 0.75].map { x in UprightGuide(axis: .vertical, start: .init(x: x, y: 0.1), end: .init(x: x + 0.08, y: 0.9)) }; geometry.uprightMode = .guided
        let plan = try GeometryPlan(size: CGSize(width: 600, height: 400), settings: geometry, quarterTurns: 0)
        for guide in geometry.guides { XCTAssertEqual(plan.displayPoint(guide.start).x, plan.displayPoint(guide.end).x, accuracy: 1e-6) }
    }
    @MainActor func testFlipAndAspectSwapKeepTheFramedSubject() throws {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.adjustments.geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let before = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
        model.flipCrop(horizontal: true); model.flipCrop(horizontal: false)
        let after = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
        XCTAssertEqual(before.x, after.x, accuracy: 0.002); XCTAssertEqual(before.y, after.y, accuracy: 0.002)
        let crop = model.adjustments.geometry.crop
        model.setCropAspect(.threeTwo); model.swapCropAspect()
        let changed = model.adjustments.geometry.crop
        XCTAssertEqual(crop.x + crop.width / 2, changed.x + changed.width / 2, accuracy: 0.002)
        XCTAssertEqual(crop.y + crop.height / 2, changed.y + changed.height / 2, accuracy: 0.002)
        let size = try XCTUnwrap(model.outputSize)
        XCTAssertEqual(size.width / size.height, 2.0 / 3, accuracy: 0.01)
    }
    @MainActor func testGuideDragKeepsTheDisplayedPreviewUntilMouseUp() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        let original = try GeometryPlan(size: view.bounds.size, settings: GeometryAdjustments(), quarterTurns: 0)
        view.setPreview(image, geometry: original)
        model.toolTab = .crop; model.cropDrawingGuide = true
        model.guideDraft = UprightGuide(axis: .vertical, start: .init(x: 0.2, y: 0.2), end: .init(x: 0.2, y: 0.8))
        let rotated = try GeometryPlan(size: view.bounds.size, settings: GeometryAdjustments(), quarterTurns: 2)
        view.setPreview(image, geometry: rotated)
        // Crop insets the photo to (60,40)–(540,360); this point is a fifth of the way in from its top-left.
        let point = try XCTUnwrap(view.maskPoint(CGPoint(x: 156, y: 104), clamp: false))
        XCTAssertEqual(point.x, 0.2, accuracy: 0.001); XCTAssertEqual(point.y, 0.8, accuracy: 0.001)
        model.guideDraft = nil; view.setPreview(image, geometry: rotated)
        let next = try XCTUnwrap(view.maskPoint(CGPoint(x: 156, y: 104), clamp: false))
        XCTAssertEqual(next.x, 0.8, accuracy: 0.001); XCTAssertEqual(next.y, 0.2, accuracy: 0.001)
    }
    func testStraightenFollowsThePointerAroundTheCropCenter() {
        let center = CGPoint(x: 300, y: 200)
        // Canvas y grows downward, so right-to-bottom is clockwise on screen: positive straighten.
        XCTAssertEqual(ImageCanvas.straightenDelta(start: CGPoint(x: 500, y: 200), current: CGPoint(x: 300, y: 400), center: center, mirrored: false), 90, accuracy: 1e-9)
        XCTAssertEqual(ImageCanvas.straightenDelta(start: CGPoint(x: 500, y: 200), current: CGPoint(x: 300, y: 400), center: center, mirrored: true), -90, accuracy: 1e-9)
        // Crossing the ±180° seam is a small move (upward on the left side is clockwise), not a full turn.
        XCTAssertEqual(ImageCanvas.straightenDelta(start: CGPoint(x: 100, y: 201), current: CGPoint(x: 100, y: 199), center: center, mirrored: false), 0.573, accuracy: 0.01)
    }
    func testEdgeHandlesKeepTheOppositeEdgeAndFollowTheAspect() {
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        var r = ImageCanvas.edgeResized(crop, edge: 1, to: MaskPoint(x: 0.9, y: 0.1), ratio: nil)
        XCTAssertEqual(r.x, 0.2); XCTAssertEqual(r.width, 0.7, accuracy: 1e-9); XCTAssertEqual(r.height, 0.6)
        r = ImageCanvas.edgeResized(crop, edge: 0, to: MaskPoint(x: 0.5, y: 0.1), ratio: nil)
        XCTAssertEqual(r.x, 0.5, accuracy: 1e-9); XCTAssertEqual(r.width, 0.3, accuracy: 1e-9)
        r = ImageCanvas.edgeResized(crop, edge: 1, to: MaskPoint(x: 0.9, y: 0.1), ratio: 1)
        XCTAssertEqual(r.height, 0.7, accuracy: 1e-9); XCTAssertEqual(r.y, 0.15, accuracy: 1e-9)
        // Too wide for the photo: the dragged edge gives way, the fixed edge stays.
        r = ImageCanvas.edgeResized(crop, edge: 3, to: MaskPoint(x: 0.5, y: 0.95), ratio: 2)
        XCTAssertEqual(r.width, 1, accuracy: 1e-9); XCTAssertEqual(r.height, 0.5, accuracy: 1e-9); XCTAssertEqual(r.y, 0.2, accuracy: 1e-9); XCTAssertEqual(r.x, 0, accuracy: 1e-9)
    }
    func testCenteredResizeMirrorsTheDragAboutTheCenter() throws {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        var r = ImageCanvas.edgeResized(crop, edge: 1, to: MaskPoint(x: 0.85, y: 0.5), ratio: nil, centered: true)
        XCTAssertEqual(r.x, 0.15, accuracy: 1e-9); XCTAssertEqual(r.width, 0.7, accuracy: 1e-9); XCTAssertEqual(r.height, 0.4)
        r = try XCTUnwrap(ImageCanvas.cornerResized(crop, corner: 2, to: MaskPoint(x: 0.7, y: 0.6), ratio: nil, centered: true))
        XCTAssertEqual(r.x, 0.3, accuracy: 1e-9); XCTAssertEqual(r.y, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r.width, 0.4, accuracy: 1e-9); XCTAssertEqual(r.height, 0.2, accuracy: 1e-9)
        // With proportions kept, the frame stops where it meets the nearest photo edge.
        r = try XCTUnwrap(ImageCanvas.cornerResized(CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.4), corner: 2, to: MaskPoint(x: 0.98, y: 0.5), ratio: 1.5, centered: true))
        XCTAssertEqual(r.width / r.height, 1.5, accuracy: 1e-9); XCTAssertEqual(r.y, 0, accuracy: 1e-9); XCTAssertEqual(r.height, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.x + r.width / 2, 0.5, accuracy: 1e-9)
    }
    func testCornerResizeKeepsTheOppositeCorner() throws {
        let crop = CropRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        let r = try XCTUnwrap(ImageCanvas.cornerResized(crop, corner: 2, to: MaskPoint(x: 0.9, y: 0.8), ratio: 1.5))
        XCTAssertEqual(r.x, 0.2); XCTAssertEqual(r.y, 0.3)
        XCTAssertEqual(r.width, 0.7, accuracy: 1e-9); XCTAssertEqual(r.height, 0.7 / 1.5, accuracy: 1e-9)
    }
    @MainActor func testDraggingOutsideTheCropFrameStraightensAsOneUndoStep() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        model.toolTab = .crop
        model.edit { $0.geometry.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        // Crop shows the whole photo inside its margin and holds the view still: (60,40)–(540,360) on this canvas.
        view.updateGeometry()
        XCTAssertTrue(model.viewport.isFitted)
        XCTAssertEqual(model.viewport.imageRect(image: CGSize(width: 600, height: 400), canvas: view.bounds.size), CGRect(x: 60, y: 40, width: 480, height: 320))
        let before = model.undoStack.count
        // The frame spans (180,120)–(420,280). The pointer starts in the ring outside the right edge's handle and
        // circles the frame's center downward.
        let turned = atan2(75.0, 145.0) * 180 / .pi
        view.mouseDown(with: event(.leftMouseDown, 445, 200)); view.mouseDragged(with: event(.leftMouseDragged, 445, 275)); view.mouseUp(with: event(.leftMouseUp, 445, 275))
        XCTAssertEqual(model.adjustments.geometry.straighten, turned, accuracy: 0.051)
        // Only the photo turns: the frame keeps its 300×200 pixels and its center.
        let plan = try XCTUnwrap(model.geometryPlan), crop = model.adjustments.geometry.crop
        XCTAssertTrue(model.adjustments.geometry.constrainCrop)
        XCTAssertEqual(crop.width * plan.fullSize.width, 300, accuracy: 1e-6); XCTAssertEqual(crop.height * plan.fullSize.height, 200, accuracy: 1e-6)
        XCTAssertEqual(crop.x + crop.width / 2, 0.5, accuracy: 1e-9); XCTAssertEqual(crop.y + crop.height / 2, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.undoStack.count, before + 1)
        // The frame stays where it was on screen, at its size: the turned photo is not refitted smaller around it.
        let shown = model.viewport.imageRect(image: plan.fullSize, canvas: view.bounds.size)
        XCTAssertFalse(model.viewport.isFitted)
        XCTAssertEqual(shown.minX + crop.x * shown.width, 180, accuracy: 0.5); XCTAssertEqual(crop.width * shown.width, 240, accuracy: 0.5)
        XCTAssertEqual(shown.minY + (1 - crop.y - crop.height) * shown.height, 120, accuracy: 0.5); XCTAssertEqual(crop.height * shown.height, 160, accuracy: 0.5)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.straighten, 0)
        model.viewport.fit()
        // While turning, Constrain Crop leaves the frame alone even when the photo no longer fills it; letting go
        // refits it, in the same undo step.
        model.edit { $0.geometry.crop = .full }
        let full = model.undoStack.count
        view.mouseDown(with: event(.leftMouseDown, 565, 200)); view.mouseDragged(with: event(.leftMouseDragged, 565, 240))
        XCTAssertNotEqual(model.adjustments.geometry.straighten, 0)
        XCTAssertEqual(model.adjustments.geometry.crop.width * model.geometryPlan!.fullSize.width, 600, accuracy: 1e-6)
        XCTAssertFalse(model.adjustments.geometry.cropFitsImage(sourceSize: CGSize(width: 600, height: 400), quarterTurns: 0))
        view.mouseUp(with: event(.leftMouseUp, 565, 240))
        XCTAssertTrue(model.adjustments.geometry.cropFitsImage(sourceSize: CGSize(width: 600, height: 400), quarterTurns: 0))
        XCTAssertLessThan(model.adjustments.geometry.crop.width * model.geometryPlan!.fullSize.width, 600)
        XCTAssertEqual(model.undoStack.count, full + 1)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.crop, .full)
        model.viewport.fit()
        model.edit { $0.geometry.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        // A flipped photo turns the other way so it still follows the pointer.
        model.edit { $0.geometry.flipHorizontal = true }
        view.mouseDown(with: event(.leftMouseDown, 445, 200)); view.mouseDragged(with: event(.leftMouseDragged, 445, 275)); view.mouseUp(with: event(.leftMouseUp, 445, 275))
        XCTAssertEqual(model.adjustments.geometry.straighten, -turned, accuracy: 0.051)
        model.viewport.fit()
        // Dragging an edge midpoint resizes just that edge.
        model.edit { $0.geometry.flipHorizontal = false; $0.geometry.straighten = 0; $0.geometry.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        view.mouseDown(with: event(.leftMouseDown, 420, 200)); view.mouseDragged(with: event(.leftMouseDragged, 492, 200)); view.mouseUp(with: event(.leftMouseUp, 492, 200))
        XCTAssertEqual(model.adjustments.geometry.crop.width, 0.65, accuracy: 1e-6); XCTAssertEqual(model.adjustments.geometry.crop.x, 0.25, accuracy: 1e-9)
        // Dragging inside moves the frame with the pointer (right and up), over the still photo.
        view.mouseDown(with: event(.leftMouseDown, 300, 200)); view.mouseDragged(with: event(.leftMouseDragged, 324, 168)); view.mouseUp(with: event(.leftMouseUp, 324, 168))
        XCTAssertEqual(model.adjustments.geometry.crop.x, 0.3, accuracy: 1e-6); XCTAssertEqual(model.adjustments.geometry.crop.y, 0.35, accuracy: 1e-6)
        XCTAssertEqual(model.adjustments.geometry.crop.width, 0.65, accuracy: 1e-6)
        XCTAssertTrue(model.viewport.isFitted)
        // Far from the frame a drag does nothing.
        let held = model.adjustments.geometry
        view.mouseDown(with: event(.leftMouseDown, 70, 350)); view.mouseDragged(with: event(.leftMouseDragged, 120, 300)); view.mouseUp(with: event(.leftMouseUp, 120, 300))
        XCTAssertEqual(model.adjustments.geometry, held)
    }
    @MainActor func testCropAndRetouchMouseGesturesAreUndoable() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        model.toolTab = .crop
        // The photo sits inside Crop's margin at (60,40)–(540,360); its top-left corner is dragged in and down.
        view.mouseDown(with: event(.leftMouseDown, 60, 40)); view.mouseDragged(with: event(.leftMouseDragged, 108, 72)); view.mouseUp(with: event(.leftMouseUp, 108, 72))
        XCTAssertEqual(model.adjustments.geometry.crop.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(model.adjustments.geometry.crop.height, 0.9, accuracy: 0.001)
        XCTAssertEqual(model.undoStack.count, 1)
        model.undo(); XCTAssertEqual(model.adjustments.geometry.crop, .full)
        model.redo(); XCTAssertEqual(model.adjustments.geometry.crop.x, 0.1, accuracy: 0.001)
        // Remove: the brush paints straight away, with a source beside the stroke until one is chosen.
        model.toolTab = .remove; model.showInspector = true; model.retouchTool = .heal
        let before = model.undoStack.count
        view.mouseDown(with: event(.leftMouseDown, 350, 250)); view.mouseDragged(with: event(.leftMouseDragged, 380, 270)); view.mouseUp(with: event(.leftMouseUp, 380, 270))
        XCTAssertEqual(model.adjustments.retouch.count, 1); XCTAssertEqual(model.adjustments.retouch[0].points.count, 2)
        XCTAssertEqual(model.adjustments.retouch[0].mode, .heal); XCTAssertNotEqual(model.adjustments.retouch[0].source, model.adjustments.retouch[0].points[0])
        XCTAssertEqual(model.selectedRetouchID, model.adjustments.retouch[0].id)
        XCTAssertEqual(model.undoStack.count, before + 1)
        // Dragging inside the selected stroke moves it as one undo step instead of painting another.
        let points = model.adjustments.retouch[0].points
        view.mouseDown(with: event(.leftMouseDown, 350, 250)); view.mouseDragged(with: event(.leftMouseDragged, 360, 250)); view.mouseUp(with: event(.leftMouseUp, 360, 250))
        XCTAssertEqual(model.adjustments.retouch.count, 1); XCTAssertNotEqual(model.adjustments.retouch[0].points, points)
        XCTAssertEqual(model.undoStack.count, before + 2)
        model.undo(); XCTAssertEqual(model.adjustments.retouch[0].points, points)
        model.undo(); XCTAssertTrue(model.adjustments.retouch.isEmpty)
        model.redo(); XCTAssertEqual(model.adjustments.retouch[0].points, points)
    }
    @MainActor func testStrokesAreSelectedTogetherAndChangedOrDeletedAsOne() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        model.toolTab = .remove; model.showInspector = true; model.retouchTool = .heal
        for (x, y) in [(100.0, 100.0), (300, 100), (300, 300)] {
            view.mouseDown(with: event(.leftMouseDown, x, y)); view.mouseDragged(with: event(.leftMouseDragged, x + 20, y)); view.mouseUp(with: event(.leftMouseUp, x + 20, y))
        }
        let ids = model.adjustments.retouch.map(\.id)
        XCTAssertEqual(ids.count, 3); XCTAssertEqual(model.selectedRetouchID, ids[2])
        // Option-drag boxes the pins it covers instead of painting.
        view.mouseDown(with: event(.leftMouseDown, 50, 50, .option)); view.mouseDragged(with: event(.leftMouseDragged, 400, 150, .option)); view.mouseUp(with: event(.leftMouseUp, 400, 150, .option))
        XCTAssertEqual(model.adjustments.retouch.count, 3); XCTAssertEqual(model.selectedRetouchIDs, Set(ids[0...1]))
        XCTAssertNil(model.selectedRetouchID, "Several selected: no single stroke shows its handles")
        // Shift-click on a pin takes its stroke into the selection, and out again.
        view.mouseDown(with: event(.leftMouseDown, 300, 300, .shift)); view.mouseUp(with: event(.leftMouseUp, 300, 300, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 3); XCTAssertEqual(model.selectedRetouchIDs, Set(ids))
        view.mouseDown(with: event(.leftMouseDown, 300, 300, .shift)); view.mouseUp(with: event(.leftMouseUp, 300, 300, .shift))
        XCTAssertEqual(model.selectedRetouchIDs, Set(ids[0...1]))
        // A setting goes to every selected stroke as one undo step; so does a selected row's checkbox.
        let before = model.undoStack.count
        model.updateSelectedRetouch { $0.opacity = 0.5 }
        XCTAssertEqual(model.adjustments.retouch.map(\.opacity), [0.5, 0.5, 1]); XCTAssertEqual(model.undoStack.count, before + 1)
        model.setSelectedRetouchRadius(0.05)
        XCTAssertEqual(model.adjustments.retouch.map(\.radius), [0.05, 0.05, 0.025])
        model.setRetouchEnabled(ids[0], false)
        XCTAssertEqual(model.adjustments.retouch.map(\.enabled), [false, false, true])
        model.setRetouchEnabled(ids[2], false)
        XCTAssertEqual(model.adjustments.retouch.map(\.enabled), [false, false, false], "A row outside the selection switches alone")
        // Delete removes the selection in one step.
        let count = model.undoStack.count
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)))
        XCTAssertEqual(model.adjustments.retouch.map(\.id), [ids[2]]); XCTAssertTrue(model.selectedRetouchIDs.isEmpty); XCTAssertEqual(model.undoStack.count, count + 1)
        model.undo(); XCTAssertEqual(model.adjustments.retouch.map(\.id), ids)
        // In the list, Shift takes a range and a single click opens the stroke's own tool.
        model.clickRetouch(ids[0], in: ids, extending: false, toggling: false)
        model.clickRetouch(ids[2], in: ids, extending: true, toggling: false)
        XCTAssertEqual(model.selectedRetouchIDs, Set(ids))
        model.updateRetouch(ids[1]) { $0.suggested = true }
        model.clickRetouch(ids[1], in: ids, extending: false, toggling: false)
        XCTAssertEqual(model.retouchTool, .dust); XCTAssertEqual(model.selectedRetouchID, ids[1])
        // A brush shows only the hand-drawn strokes, so going back to one lets go of the dust.
        model.selectedRetouchIDs = Set(ids); model.retouchTool = .remove
        XCTAssertEqual(model.selectedRetouchIDs, [ids[0], ids[2]])
    }
    @MainActor func testShiftClickCarriesTheSelectedStrokeOnInAStraightLine() throws {
        let model = EditorModel(), view = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        view.model = model
        view.image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .white).cropped(to: view.bounds), from: view.bounds))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        model.toolTab = .remove; model.showInspector = true; model.retouchTool = .heal
        view.mouseDown(with: event(.leftMouseDown, 150, 150)); view.mouseDragged(with: event(.leftMouseDragged, 170, 150)); view.mouseUp(with: event(.leftMouseUp, 170, 150))
        let id = try XCTUnwrap(model.selectedRetouchID)
        // A source placed by hand stays where it is when the stroke is carried on.
        model.updateRetouch(id) { $0.source = MaskPoint(x: 0.1, y: 0.1) }
        let before = model.undoStack.count, end = try XCTUnwrap(view.maskPoint(NSPoint(x: 400, y: 300), clamp: true))
        view.mouseDown(with: event(.leftMouseDown, 400, 300, .shift)); view.mouseUp(with: event(.leftMouseUp, 400, 300, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 1, "Shift-click carries the stroke on instead of starting one")
        XCTAssertEqual(model.adjustments.retouch[0].points.count, 3); XCTAssertEqual(model.adjustments.retouch[0].points.last, end)
        XCTAssertEqual(model.adjustments.retouch[0].source, MaskPoint(x: 0.1, y: 0.1)); XCTAssertEqual(model.selectedRetouchID, id)
        XCTAssertEqual(model.undoStack.count, before + 1)
        // Dragging on after the Shift-click paints more of the same stroke.
        view.mouseDown(with: event(.leftMouseDown, 450, 300, .shift)); view.mouseDragged(with: event(.leftMouseDragged, 470, 320, .shift)); view.mouseUp(with: event(.leftMouseUp, 470, 320, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 1); XCTAssertEqual(model.adjustments.retouch[0].points.count, 5)
        XCTAssertEqual(model.undoStack.count, before + 2)
        model.undo(); XCTAssertEqual(model.adjustments.retouch[0].points.count, 3)
        model.undo(); XCTAssertEqual(model.adjustments.retouch[0].points.count, 2)
        // With nothing selected a Shift-click starts a stroke, which the next one carries on.
        model.selectRetouch(nil)
        view.mouseDown(with: event(.leftMouseDown, 200, 250, .shift)); view.mouseUp(with: event(.leftMouseUp, 200, 250, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 2); XCTAssertEqual(model.adjustments.retouch[1].points.count, 1)
        view.mouseDown(with: event(.leftMouseDown, 260, 250, .shift)); view.mouseUp(with: event(.leftMouseUp, 260, 250, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 2); XCTAssertEqual(model.adjustments.retouch[1].points.count, 2)
        // With the Remove panel hidden the canvas neither paints nor carries strokes on.
        model.toggleTool(.remove); XCTAssertFalse(model.showInspector); XCTAssertFalse(model.removing)
        view.mouseDown(with: event(.leftMouseDown, 300, 120)); view.mouseUp(with: event(.leftMouseUp, 300, 120))
        view.mouseDown(with: event(.leftMouseDown, 320, 120, .shift)); view.mouseUp(with: event(.leftMouseUp, 320, 120, .shift))
        XCTAssertEqual(model.adjustments.retouch.count, 2); XCTAssertEqual(model.adjustments.retouch[1].points.count, 2)
    }
    @MainActor func testRotationPreservesSelectedSourceAreaAndStraightenKeepsAspect() throws {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.adjustments.geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        model.adjustments.geometry.flipHorizontal = true
        let before = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
        model.rotateCrop(1)
        let after = try XCTUnwrap(model.geometryPlan).sourcePoint(.init(x: 0.5, y: 0.5))
        XCTAssertEqual(before.x, after.x, accuracy: 0.002); XCTAssertEqual(before.y, after.y, accuracy: 0.002)
        model.setCropAspect(.fourThree); model.setStraighten(12)
        let size = try XCTUnwrap(model.outputSize)
        XCTAssertEqual(size.width / size.height, 0.75, accuracy: 0.005)
    }
    @MainActor func testAspectRotationAndGuidesRespectDisplayOrientation() throws {
        let model = EditorModel()
        model.info = ImageInfo(filename: "fixture", width: 600, height: 400, isRAW: false, defaults: Adjustments())
        model.toolTab = .crop
        model.setCropAspect(.square)
        let size = try XCTUnwrap(model.outputSize); XCTAssertEqual(size.width, size.height)
        model.rotateCrop(1)
        let rotated = try XCTUnwrap(model.outputSize); XCTAssertEqual(rotated.width, rotated.height)
        model.guideAxis = .vertical; XCTAssertEqual(model.sourceGuideAxis, .horizontal)
        model.guideDraft = UprightGuide(axis: .horizontal, start: .init(x: 0.1, y: 0.2), end: .init(x: 0.9, y: 0.3))
        model.acceptGuide(); XCTAssertEqual(model.adjustments.geometry.guides.count, 1)
        XCTAssertNil(model.guideDraft)
        model.undo(); XCTAssertTrue(model.adjustments.geometry.guides.isEmpty)
    }
}

final class CropZoneTests: XCTestCase {
    func testHandlesResizeAndTheRingAroundThemTurns() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        typealias Z = ImageCanvas.CropZone
        // Corners on either side of the frame line; the canvas is flipped, so the top-left corner is at minY.
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 97, y: 97), frame: frame), Z.corner(3))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 106, y: 106), frame: frame), Z.corner(3))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 503, y: 397), frame: frame), Z.corner(1))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 93, y: 104), frame: frame), Z.corner(3), "Along the bracket's arm")
        // Diagonally past the bracket a drag turns the photo, however close to the corner it starts.
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 94, y: 94), frame: frame), Z.rotate)
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 506, y: 406), frame: frame), Z.rotate)
        // Past the handle, outside the frame and within the ring, a drag turns the photo; beyond the ring nothing happens.
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 80, y: 80), frame: frame), Z.rotate)
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 300, y: 70), frame: frame), Z.rotate, "Above the top edge's handle")
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 530, y: 250), frame: frame), Z.rotate, "Beside the right edge's handle")
        XCTAssertNil(ImageCanvas.cropZone(at: CGPoint(x: 60, y: 60), frame: frame))
        XCTAssertNil(ImageCanvas.cropZone(at: CGPoint(x: 200, y: 80), frame: frame), "Between handles, away from the edge")
        // Edge handles, and the edges along their whole length.
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 300, y: 92), frame: frame), Z.edge(3))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 300, y: 108), frame: frame), Z.edge(3))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 160, y: 404), frame: frame), Z.edge(2))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 96, y: 180), frame: frame), Z.edge(0))
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 505, y: 250), frame: frame), Z.edge(1))
        // Inside the frame, past the handles and the edge grip, the frame moves.
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 115, y: 115), frame: frame), Z.move)
        XCTAssertEqual(ImageCanvas.cropZone(at: CGPoint(x: 300, y: 250), frame: frame), Z.move)
    }
}
