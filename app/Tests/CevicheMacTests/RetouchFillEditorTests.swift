import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

/// Runs when the compiled models are available (CEVICHE_MODELS=…/models/build/compiled); skipped otherwise.
final class RetouchFillEditorTests: XCTestCase {
    /// A 900 × 600 PNG of stripes with a dark disc at the middle.
    private func photo() throws -> URL {
        let width = 900, height = 600
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                var value = 0.4 + 0.15 * sin(Double(x) / 7)
                if hypot(Double(x) - 450, Double(y) - 300) < 30 { value = 0.05 }
                let p = pixels + (y * width + x) * 4
                p[0] = UInt8(value * 255); p[1] = UInt8(value * 0.9 * 255); p[2] = UInt8(value * 0.8 * 255); p[3] = 255
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    @MainActor private func settle(_ model: EditorModel) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !model.pendingFills.isEmpty || model.fillTask != nil {
            guard Date() < deadline else { return XCTFail("The fill did not finish") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor func testPaintingQueuesAFillThatLandsWithoutAnUndoStep() async throws {
        guard BundledModel.inpaint.isAvailable else { throw XCTSkip("Inpainting model not installed") }
        let url = try photo(); defer { try? FileManager.default.removeItem(at: url) }
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        let model = EditorModel(preferences: preferences)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        model.toolTab = .remove; model.retouchTool = .remove; model.retouchRadius = 0.06
        model.startRetouch(MaskPoint(x: 0.5, y: 0.5)); model.dragRetouch(MaskPoint(x: 0.505, y: 0.5))
        XCTAssertTrue(model.pendingFills.isEmpty, "Nothing runs while the stroke is painted")
        model.endRetouch()
        let id = try XCTUnwrap(model.selectedRetouchID)
        XCTAssertEqual(model.pendingFills, [id])
        let steps = model.undoStack.count
        try await settle(model)
        let first = try XCTUnwrap(model.adjustments.retouch[0].fill)
        XCTAssertFalse(model.adjustments.retouch[0].needsFill); XCTAssertEqual(model.undoStack.count, steps)

        // Refresh makes another from another window, as an undoable edit.
        model.refreshRetouch(id)
        try await settle(model)
        let second = try XCTUnwrap(model.adjustments.retouch[0].fill)
        XCTAssertNotEqual(first.raster, second.raster); XCTAssertEqual(model.undoStack.count, steps + 1)
        model.undo(); XCTAssertEqual(model.adjustments.retouch[0].fill, first)
        try await settle(model); XCTAssertEqual(model.adjustments.retouch[0].fill, first, "Undo does not make a fill again")

        // Turning AI fill off is "use patch fill"; a stroke whose fill is lost (XMP, a paste) gets it made again.
        model.setGenerative(id, false)
        XCTAssertNil(model.adjustments.retouch[0].fill); XCTAssertTrue(model.pendingFills.isEmpty)
        model.undo(); XCTAssertEqual(model.adjustments.retouch[0].fill, first)
        model.edit { $0.retouch[0].fill = nil }
        XCTAssertEqual(model.pendingFills, [id])
        // Escape stops it and keeps a patch, as one undo step; Undo asks for the fill again.
        let beforeCancel = model.undoStack.count
        XCTAssertTrue(model.dismissTool())
        XCTAssertTrue(model.pendingFills.isEmpty); XCTAssertFalse(model.adjustments.retouch[0].generative)
        XCTAssertEqual(model.undoStack.count, beforeCancel + 1); XCTAssertEqual(model.toolTab, .remove)
        model.undo(); XCTAssertEqual(model.pendingFills, [id])
        try await settle(model)
        XCTAssertNotNil(model.adjustments.retouch[0].fill)
    }

    /// Placing the Face region draws no brush, so the pointer must stay visible: it once kept the brush's blank cursor.
    @MainActor func testFaceRegionKeepsAVisiblePointer() async throws {
        let url = try photo()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        model.toolTab = .face
        XCTAssertEqual(model.retouchTool, .heal)
        func move(to p: MaskPoint) throws -> NSCursor {
            let point = canvas.convert(canvas.sourceCanvasPoint(p), to: nil)
            canvas.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            return NSCursor.current
        }
        // No brush in Portrait: the photo takes a click that adds a spot.
        XCTAssertEqual(try move(to: MaskPoint(x: 0.5, y: 0.5)), .crosshair)
        // Reshape Face shows only the face's handles, placed from its landmarks: the frame is never drawn or dragged,
        // so off a handle the pointer is the plain one, never the brush's blank cursor.
        model.portraitTool = .reshape
        XCTAssertTrue(model.placingFaceRegion)
        model.faceRegion = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        // Choosing Reshape measures the face; the photo takes clicks again once that is done.
        let deadline = Date().addingTimeInterval(60)
        while model.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(try move(to: MaskPoint(x: 0.5, y: 0.5)), .arrow)
        XCTAssertEqual(try move(to: MaskPoint(x: 0.9, y: 0.9)), .arrow)
        // A click away closes the handles and leaves the plain pointer; the region stays.
        let away = canvas.convert(canvas.sourceCanvasPoint(MaskPoint(x: 0.9, y: 0.9)), to: nil)
        canvas.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: away, modifierFlags: [], timestamp: 0,
                                                                 windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertFalse(model.editingFaceRegion)
        XCTAssertEqual(model.currentFaceRegion, CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), "The region stays as it was")
        XCTAssertEqual(try move(to: MaskPoint(x: 0.9, y: 0.9)), .arrow)
        // Picking Spots again: a click adds a spot.
        model.portraitTool = .spots
        XCTAssertEqual(try move(to: MaskPoint(x: 0.9, y: 0.9)), .crosshair)
        // Remove's brushes still hide the pointer and draw their own footprint.
        model.toolTab = .remove; model.retouchTool = .heal
        XCTAssertLessThanOrEqual(try move(to: MaskPoint(x: 0.5, y: 0.5)).image.size.width, 1)
    }

    /// Portrait has no brushes: a click adds a face spot (a Heal dab with its own source), a drag moves a spot
    /// without painting, and Delete removes it.
    @MainActor func testFaceSpotsAreAddedMovedAndDeletedNotPainted() async throws {
        let url = try photo()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        model.toolTab = .face
        func mouse(_ type: NSEvent.EventType, _ p: MaskPoint) throws {
            let point = canvas.convert(canvas.sourceCanvasPoint(p), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        // A click on bare skin: one dab, not a painted stroke.
        try mouse(.leftMouseDown, MaskPoint(x: 0.3, y: 0.5))
        try mouse(.leftMouseUp, MaskPoint(x: 0.3, y: 0.5))
        let spot = try XCTUnwrap(model.adjustments.retouch.first)
        XCTAssertEqual(model.adjustments.retouch.count, 1)
        XCTAssertEqual(spot.group, .face)
        XCTAssertEqual(spot.mode, .heal)
        XCTAssertEqual(spot.points.count, 1)
        // Its source arrives on its own.
        let deadline = Date().addingTimeInterval(8)
        while model.adjustments.retouch.first?.source == spot.source, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertNotEqual(model.adjustments.retouch.first?.source, spot.source)
        // Dragging the spot moves it.
        try mouse(.leftMouseDown, MaskPoint(x: 0.3, y: 0.5))
        try mouse(.leftMouseDragged, MaskPoint(x: 0.4, y: 0.6))
        try mouse(.leftMouseUp, MaskPoint(x: 0.4, y: 0.6))
        let moved = try XCTUnwrap(model.adjustments.retouch.first)
        XCTAssertEqual(model.adjustments.retouch.count, 1)
        XCTAssertEqual(moved.points[0].x, 0.4, accuracy: 0.01)
        XCTAssertEqual(moved.points[0].y, 0.6, accuracy: 0.01)
        // A second spot, then a drag on bare skin boxes both for one Delete, adding none.
        try mouse(.leftMouseDown, MaskPoint(x: 0.6, y: 0.4))
        try mouse(.leftMouseUp, MaskPoint(x: 0.6, y: 0.4))
        XCTAssertEqual(model.adjustments.retouch.count, 2)
        try mouse(.leftMouseDown, MaskPoint(x: 0.2, y: 0.2))
        try mouse(.leftMouseDragged, MaskPoint(x: 0.5, y: 0.5))
        try mouse(.leftMouseDragged, MaskPoint(x: 0.8, y: 0.8))
        try mouse(.leftMouseUp, MaskPoint(x: 0.8, y: 0.8))
        XCTAssertEqual(model.adjustments.retouch.count, 2)
        XCTAssertEqual(model.selectedRetouchIDs, Set(model.adjustments.retouch.map(\.id)))
        model.deleteSelectedRetouch()
        XCTAssertTrue(model.adjustments.retouch.isEmpty)
        // Escape puts the spot tool down: a click on the photo adds nothing, and the pointer is the plain one.
        XCTAssertTrue(model.dismissTool())
        XCTAssertTrue(model.retouchPointer)
        XCTAssertFalse(model.editsFaceSpots)
        try mouse(.leftMouseDown, MaskPoint(x: 0.5, y: 0.5))
        try mouse(.leftMouseUp, MaskPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(model.adjustments.retouch.isEmpty)
        XCTAssertEqual(model.toolTab, .face, "The first Escape only puts the tool down")
        // The same in Remove: no brush, no stroke.
        model.toolTab = .remove; model.retouchTool = .heal
        XCTAssertTrue(model.paintsRetouch)
        XCTAssertTrue(model.dismissTool())
        XCTAssertFalse(model.paintsRetouch)
        try mouse(.leftMouseDown, MaskPoint(x: 0.5, y: 0.5))
        try mouse(.leftMouseUp, MaskPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(model.adjustments.retouch.isEmpty)
        // Picking a brush takes it up again.
        model.retouchPointer = false
        XCTAssertTrue(model.paintsRetouch)
    }

    /// Remove's Select tool boxes several strokes for one Delete, and never paints or pans.
    @MainActor func testSelectToolBoxesStrokesForOneDelete() async throws {
        let url = try photo()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        model.toolTab = .remove
        let strokes = [MaskPoint(x: 0.3, y: 0.4), MaskPoint(x: 0.4, y: 0.45), MaskPoint(x: 0.8, y: 0.8)].map {
            RetouchStroke(mode: .heal, source: MaskPoint(x: $0.x + 0.05, y: $0.y), target: $0, radius: 0.02, softness: 0.5, opacity: 1)
        }
        model.edit { $0.retouch = strokes }
        model.retouchSelecting = true
        XCTAssertFalse(model.paintsRetouch)
        func mouse(_ type: NSEvent.EventType, _ p: MaskPoint) throws {
            let point = canvas.convert(canvas.sourceCanvasPoint(p), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        // A box over the first two pins.
        try mouse(.leftMouseDown, MaskPoint(x: 0.2, y: 0.55))
        try mouse(.leftMouseDragged, MaskPoint(x: 0.5, y: 0.3))
        try mouse(.leftMouseUp, MaskPoint(x: 0.5, y: 0.3))
        XCTAssertEqual(model.selectedRetouchIDs, Set(strokes.prefix(2).map(\.id)))
        XCTAssertEqual(model.adjustments.retouch.count, 3, "Boxing paints nothing")
        model.deleteSelectedRetouch()
        XCTAssertEqual(model.adjustments.retouch.map(\.id), [strokes[2].id])
        // A click on empty photo clears the selection; a click on a pin picks it.
        try mouse(.leftMouseDown, MaskPoint(x: 0.8, y: 0.8)); try mouse(.leftMouseUp, MaskPoint(x: 0.8, y: 0.8))
        XCTAssertEqual(model.selectedRetouchIDs, [strokes[2].id])
        try mouse(.leftMouseDown, MaskPoint(x: 0.1, y: 0.1)); try mouse(.leftMouseUp, MaskPoint(x: 0.1, y: 0.1))
        XCTAssertTrue(model.selectedRetouchIDs.isEmpty)
        XCTAssertEqual(model.adjustments.retouch.count, 1)
    }

    @MainActor func testSpotDabMetersThroughBothToolTabs() async throws {
        let url = try photo()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        for tab in [ToolTab.remove] {
            model.toolTab = tab
            model.retouchTool = .tone
            model.retouchRadius = 0.06
            let point = canvas.convert(canvas.sourceCanvasPoint(MaskPoint(x: 0.5, y: 0.5)), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
            XCTAssertEqual(model.selectedRetouch?.mode, .tone)
            let deadline = Date().addingTimeInterval(8)
            while model.selectedRetouch?.exposure == 0 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertGreaterThan(try XCTUnwrap(model.selectedRetouch?.exposure), 0)
            model.undo()
            XCTAssertTrue(model.adjustments.retouch.isEmpty)
        }
    }

    @MainActor func testWithoutTheModelStrokesUsePatchFill() async throws {
        guard !BundledModel.inpaint.isAvailable else { throw XCTSkip("Inpainting model installed") }
        let url = try photo(); defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(url)
        XCTAssertTrue(opened)
        model.toolTab = .remove; model.retouchTool = .remove
        model.startRetouch(MaskPoint(x: 0.5, y: 0.5)); model.endRetouch()
        XCTAssertFalse(model.adjustments.retouch[0].generative); XCTAssertTrue(model.pendingFills.isEmpty)
        // A stroke that asks for a fill (from XMP or a paste) waits for the model instead of failing.
        model.edit { $0.retouch[0].generative = true }
        XCTAssertTrue(model.pendingFills.isEmpty); XCTAssertTrue(model.fillFailures.isEmpty)
    }
}
