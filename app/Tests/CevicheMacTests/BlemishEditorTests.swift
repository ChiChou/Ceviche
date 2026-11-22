import XCTest
import CevicheCore
@testable import CevicheMac

final class BlemishEditorTests: XCTestCase {
    @MainActor func testPortraitCorrectionsSurviveReanalysisAndEncoding() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_FACE_RAW"] else {
            throw XCTSkip("Supply a RAW portrait")
        }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(URL(fileURLWithPath: path))
        XCTAssertTrue(opened)
        for kind in [PortraitCorrection.shine] {
            model.applyPortraitCorrection(kind)
            await model.faceTask?.value
            let mask = try XCTUnwrap(model.adjustments.masks.last)
            XCTAssertEqual(mask.portraitCorrection, kind)
            if kind == .shine { XCTAssertNotNil(mask.raster) }
            model.applyPortraitCorrection(kind)
            await model.faceTask?.value
            XCTAssertEqual(model.adjustments.masks.last?.id, mask.id)
        }
        XCTAssertEqual(model.adjustments.masks.count, 3)
        model.toolTab = .face
        model.prepareLiquify()
        await model.faceTask?.value
        let rect = try XCTUnwrap(model.currentFaceRegion)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        let handle = MaskPoint(x: rect.midX - 0.32 * rect.width, y: rect.minY + 0.35 * rect.height)
        let target = MaskPoint(x: handle.x + 0.022 * rect.width, y: handle.y)
        canvas.beginFaceRegion(at: canvas.sourceCanvasPoint(handle), model: model)
        canvas.dragFaceRegion(to: canvas.sourceCanvasPoint(target), model: model)
        model.endGesture()
        XCTAssertEqual(try XCTUnwrap(model.adjustments.faceLiquify?.width), -0.4, accuracy: 0.005)
        let data = try JSONEncoder().encode(model.adjustments)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: data), model.adjustments)
    }

    @MainActor func testAutomaticHealIsOneEditableSelection() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_BLEMISH_TEST_FACE"],
              let detector = BlemishDetector.modelURL else { throw XCTSkip("Supply a portrait with visible spots and the detector") }
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let opened = await model.open(URL(fileURLWithPath: path))
        XCTAssertTrue(opened)
        model.toolTab = .face
        XCTAssertEqual(model.retouchTool, .heal)
        let canvas = ImageCanvas(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        canvas.model = model
        canvas.setPreview(try XCTUnwrap(model.preview), geometry: model.renderedGeometry)
        canvas.updateGeometry()
        model.editingFaceRegion = true
        func drag(_ a: MaskPoint, _ b: MaskPoint) {
            canvas.beginFaceRegion(at: canvas.sourceCanvasPoint(a), model: model)
            canvas.dragFaceRegion(to: canvas.sourceCanvasPoint(b), model: model)
            model.finishFaceRegion()
            canvas.faceRegionDrag = nil
        }
        drag(.init(x: 0.2, y: 0.1), .init(x: 0.8, y: 0.9))
        XCTAssertEqual(try XCTUnwrap(model.faceRegion).width, 0.6, accuracy: 0.001)
        drag(.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.5))
        XCTAssertEqual(try XCTUnwrap(model.faceRegion).minX, 0.3, accuracy: 0.001)
        drag(.init(x: 0.3, y: 0.1), .init(x: 0.2, y: 0.05))
        XCTAssertEqual(try XCTUnwrap(model.faceRegion).height, 0.85, accuracy: 0.001)
        model.clearFaceRegion()
        let initial = model.adjustments
        model.findBlemishes(detector)
        await model.faceTask?.value
        let strokes = model.selectedStrokes
        XCTAssertFalse(strokes.isEmpty)
        XCTAssertTrue(strokes.allSatisfy { $0.mode == .heal && !$0.suggested && $0.source != $0.points.first })
        XCTAssertEqual(model.retouchHandleIDs.count, strokes.count)
        XCTAssertFalse(model.isSelecting)
        model.undo()
        XCTAssertEqual(model.adjustments, initial)
        model.prepareLiquify()
        await model.faceTask?.value
        let rect = try XCTUnwrap(model.currentFaceRegion)
        _ = rect; model.setLiquify(\.width, -0.6)
        let saved = try JSONEncoder().encode(model.adjustments)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: saved), model.adjustments)
        model.undo()
        XCTAssertEqual(model.adjustments, initial)
    }
}
