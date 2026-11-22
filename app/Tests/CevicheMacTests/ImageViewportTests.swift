import XCTest
import CevicheTestSupport
import AppKit
import Metal
@testable import CevicheMac

final class ImageViewportTests: XCTestCase {
    let image = CGSize(width: 2200, height: 1467)
    let canvas = CGSize(width: 1000, height: 700)

    func testFitStepsAndLimits() {
        var state = ImageViewport()
        let fit = state.imageRect(image: image, canvas: canvas)
        XCTAssertEqual(fit.width, 1000, accuracy: 1e-8)
        XCTAssertEqual(fit.midY, 350, accuracy: 1e-8)
        XCTAssertFalse(state.canZoomOut)
        state.zoom(to: state.nextLarger, image: image, canvas: canvas)
        XCTAssertEqual(state.scale, 1.25)
        state.zoom(to: state.nextLarger, image: image, canvas: canvas)
        XCTAssertEqual(state.scale, 1.5)
        state.zoom(to: 1.72, image: image, canvas: canvas)
        XCTAssertEqual(state.nextSmaller, 1.5)
        XCTAssertEqual(state.nextLarger, 2)
        state.zoom(to: 200, image: image, canvas: canvas)
        XCTAssertEqual(state.scale, 16)
        XCTAssertFalse(state.canZoomIn)
        state.zoom(to: .nan, image: image, canvas: canvas)
        XCTAssertEqual(state.scale, 16)
        state.zoom(to: -5, image: image, canvas: canvas)
        XCTAssertTrue(state.isFitted)
        XCTAssertEqual(state.center, CGPoint(x: 0.5, y: 0.5))
    }
    func testPinchKeepsFocalImagePointStationary() {
        var state = ImageViewport()
        let anchor = CGPoint(x: 260, y: 230)
        let before = state.imageRect(image: image, canvas: canvas)
        let x = (anchor.x - before.minX) / before.width
        let y = (anchor.y - before.minY) / before.height
        for scale in [1.2, 1.7, 2.4, 4.1] {
            state.zoom(to: scale, anchor: anchor, image: image, canvas: canvas)
            let rect = state.imageRect(image: image, canvas: canvas)
            XCTAssertEqual(rect.minX + x * rect.width, anchor.x, accuracy: 1e-8)
            XCTAssertEqual(rect.minY + y * rect.height, anchor.y, accuracy: 1e-8)
        }
    }
    func testPanClampsAndResizingPreservesValidBounds() {
        var state = ImageViewport()
        state.pan(by: CGSize(width: 100, height: 100), image: image, canvas: canvas)
        XCTAssertEqual(state.center, CGPoint(x: 0.5, y: 0.5))
        state.zoom(to: 3, image: image, canvas: canvas)
        state.pan(by: CGSize(width: 9000, height: 9000), image: image, canvas: canvas)
        var rect = state.imageRect(image: image, canvas: canvas)
        XCTAssertEqual(rect.minX, 0); XCTAssertEqual(rect.minY, 0)
        state.pan(by: CGSize(width: -9000, height: -9000), image: image, canvas: canvas)
        rect = state.imageRect(image: image, canvas: canvas)
        XCTAssertEqual(rect.maxX, canvas.width); XCTAssertEqual(rect.maxY, canvas.height)
        let resized = CGSize(width: 600, height: 400)
        rect = state.imageRect(image: image, canvas: resized)
        XCTAssertLessThanOrEqual(rect.minX, 0); XCTAssertGreaterThanOrEqual(rect.maxX, resized.width)
        let portrait = CGSize(width: image.height, height: image.width)
        rect = state.imageRect(image: portrait, canvas: canvas)
        XCTAssertLessThanOrEqual(rect.minY, 0); XCTAssertGreaterThanOrEqual(rect.maxY, canvas.height)
        state.fit()
        XCTAssertEqual(state.imageRect(image: image, canvas: canvas).midX, canvas.width / 2)
    }
    @MainActor func testViewportActionsDoNotEditPhotoAndCloseResetsZoom() {
        let model = EditorModel()
        model.updateViewportGeometry(image: image, canvas: canvas)
        let original = model.adjustments
        model.zoomImageIn(); XCTAssertEqual(model.viewport.scale, 1.25)
        model.magnifyImage(by: 1.25, anchor: CGPoint(x: 400, y: 300))
        XCTAssertEqual(model.viewport.scale, 2.5)
        model.panImage(by: CGSize(width: 100, height: 70))
        model.zoomImageOut(); XCTAssertEqual(model.viewport.scale, 2)
        model.toggleImageFit(); XCTAssertTrue(model.viewport.isFitted)
        model.toggleImageFit(); XCTAssertEqual(model.viewport.scale, 2)
        XCTAssertEqual(model.adjustments, original)
        XCTAssertFalse(model.dirty)
        XCTAssertTrue(model.undoStack.isEmpty)
        model.closeDocument(); XCTAssertTrue(model.viewport.isFitted)
    }
    @MainActor func testRotatedComparisonKeepsOriginalAligned() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let sample = try TestSamples.require(TestSamples.landscape)
        let model = EditorModel()
        await model.open(sample)
        XCTAssertNil(model.error)
        let width = try XCTUnwrap(model.preview).width
        model.comparing = true
        model.edit { $0.quarterTurns = 1; $0.exposure = 0.5 }
        for _ in 0..<100 where model.isRendering { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.isRendering)
        XCTAssertEqual(model.preview?.height, width)
        XCTAssertEqual(model.originalPreview?.height, model.preview?.height)
        XCTAssertEqual(model.originalPreview?.width, model.preview?.width)
        model.closeDocument()
    }
    @MainActor func testSpacePanOverridesToolsWithoutEditing() throws {
        let model = EditorModel()
        let view = ImageCanvas(frame: CGRect(origin: .zero, size: canvas)); view.model = model
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 20, height: 14, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.image = try XCTUnwrap(pixels.makeImage())
        model.toolTab = .remove
        view.updateGeometry(); model.zoomImage(to: 2)
        let before = model.viewport, adjustments = model.adjustments
        model.spaceHeld = true
        func mouse(_ type: NSEvent.EventType, x: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: 250), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, x: 500))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 550))
        view.mouseUp(with: mouse(.leftMouseUp, x: 550))
        XCTAssertTrue(model.spaceDragged)
        XCTAssertNotEqual(model.viewport.center, before.center)
        XCTAssertEqual(model.viewport.scale, before.scale)
        XCTAssertEqual(model.adjustments, adjustments)
        XCTAssertTrue(model.undoStack.isEmpty)
        model.cancelHeldViewKeys()
        XCTAssertFalse(model.spaceHeld)
    }
    @MainActor func testSplitDividerDragKeepsViewportAndEdits() {
        let model = EditorModel(); model.comparing = true
        let view = ImageCanvas(frame: CGRect(origin: .zero, size: canvas)); view.model = model
        model.updateViewportGeometry(image: image, canvas: canvas); model.zoomImageIn()
        let viewport = model.viewport, adjustments = model.adjustments
        func mouse(_ type: NSEvent.EventType, x: Double, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: 250), to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, x: 500))
        view.mouseDragged(with: mouse(.leftMouseDragged, x: 720))
        view.mouseUp(with: mouse(.leftMouseUp, x: 720))
        XCTAssertEqual(model.comparisonSplit, 0.72)
        XCTAssertEqual(model.viewport, viewport); XCTAssertEqual(model.adjustments, adjustments)
        XCTAssertFalse(model.dirty); XCTAssertTrue(model.undoStack.isEmpty)
        view.mouseDown(with: mouse(.leftMouseDown, x: 720, clicks: 2))
        XCTAssertEqual(model.comparisonSplit, 0.5)
        model.setComparisonSplit(-10); XCTAssertEqual(model.comparisonSplit, 0.02)
        model.setComparisonSplit(10); XCTAssertEqual(model.comparisonSplit, 0.98)
    }
    @MainActor func testNativePinchSmartZoomAndDrag() throws {
        let model = EditorModel()
        let view = ImageCanvas(frame: CGRect(origin: .zero, size: canvas))
        let context = CGContext(data: nil, width: 220, height: 147, bitsPerComponent: 8, bytesPerRow: 880, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        view.image = try XCTUnwrap(context.makeImage()); view.model = model; view.updateGeometry()
        let event = TestMagnificationEvent()
        event.focalPoint = view.convert(CGPoint(x: 300, y: 250), to: nil)
        event.delta = 0.5
        view.magnify(with: event)
        XCTAssertEqual(model.viewport.scale, 1.5)
        event.delta = 1
        view.magnify(with: event)
        XCTAssertEqual(model.viewport.scale, 2.5)
        let before = model.viewport.center
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 440, y: 330)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 440, y: 330)))
        XCTAssertLessThan(model.viewport.center.x, before.x)
        XCTAssertLessThan(model.viewport.center.y, before.y)
        let beforeScroll = model.viewport.center
        let scroll = TestScrollEvent()
        view.scrollWheel(with: scroll)
        XCTAssertLessThan(model.viewport.center.x, beforeScroll.x)
        XCTAssertLessThan(model.viewport.center.y, beforeScroll.y)
        view.smartMagnify(with: event)
        XCTAssertTrue(model.viewport.isFitted)
        view.smartMagnify(with: event)
        XCTAssertEqual(model.viewport.scale, 2)
    }
    /// After a crop turn the photo stays where the turn left it, larger than fitted and past the canvas edge.
    func testShowPlacesTheImageExactly() {
        var state = ImageViewport(); state.inset = 40
        let image = CGSize(width: 1200, height: 800), canvas = CGSize(width: 1000, height: 700)
        let target = CGRect(x: -30, y: 20, width: 1100, height: 1100.0 * 800 / 1200)
        state.show(at: target, image: image, canvas: canvas)
        let rect = state.imageRect(image: image, canvas: canvas)
        XCTAssertEqual(rect.minX, target.minX, accuracy: 0.01); XCTAssertEqual(rect.minY, target.minY, accuracy: 0.01)
        XCTAssertEqual(rect.width, target.width, accuracy: 0.01)
        // Smaller than fitted is never kept: the photo fits instead.
        state.show(at: CGRect(x: 0, y: 0, width: 100, height: 66), image: image, canvas: canvas)
        XCTAssertTrue(state.isFitted)
    }
}

private final class TestMagnificationEvent: NSEvent {
    var delta: CGFloat = 0
    var focalPoint = CGPoint.zero
    override var magnification: CGFloat { delta }
    override var locationInWindow: NSPoint { focalPoint }
}

private final class TestScrollEvent: NSEvent {
    override var hasPreciseScrollingDeltas: Bool { true }
    override var scrollingDeltaX: CGFloat { 12 }
    override var scrollingDeltaY: CGFloat { 8 }
}
