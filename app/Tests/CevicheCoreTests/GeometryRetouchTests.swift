import XCTest
import CoreImage
import Metal
import ImageIO
@testable import CevicheCore

final class GeometryRetouchTests: XCTestCase {
    func testCoordinatesRoundTripThroughCropFlipRotationAndUpright() throws {
        var g = GeometryAdjustments()
        g.crop = CropRect(x: 0.1, y: 0.15, width: 0.7, height: 0.65); g.straighten = 7; g.flipHorizontal = true
        g.uprightMode = .guided
        g.guides = [UprightGuide(axis: .vertical, start: .init(x: 0.15, y: 0.1), end: .init(x: 0.3, y: 0.9)),
                    UprightGuide(axis: .vertical, start: .init(x: 0.85, y: 0.1), end: .init(x: 0.7, y: 0.9))]
        for turn in 0..<4 {
            let plan = try GeometryPlan(size: CGSize(width: 600, height: 400), settings: g, quarterTurns: turn)
            for p in [MaskPoint(x: 0.2, y: 0.3), MaskPoint(x: 0.7, y: 0.8)] {
                let q = plan.sourcePoint(plan.displayPoint(p))
                XCTAssertEqual(q.x, p.x, accuracy: 1e-10); XCTAssertEqual(q.y, p.y, accuracy: 1e-10)
            }
        }
        g.crop = .full; g.straighten = 0; g.flipHorizontal = false
        let plan = try GeometryPlan(size: CGSize(width: 600, height: 400), settings: g, quarterTurns: 0)
        for guide in g.guides {
            XCTAssertEqual(plan.displayPoint(guide.start).x, plan.displayPoint(guide.end).x, accuracy: 1e-10)
        }
        g.guides[1] = g.guides[0]; g.guides[1].id = UUID()
        XCTAssertThrowsError(try GeometryPlan(size: CGSize(width: 600, height: 400), settings: g, quarterTurns: 0))
    }
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device)
    }
    private func value(_ image: CIImage, _ x: Double, _ y: Double, _ context: CIContext) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return Double(pixel[0])
    }
    func testGeometryPixelsFollowSameMappingAsCanvas() throws {
        let context = try context(), extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let image = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 30, y: 60, width: 20, height: 20))
            .composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: extent))
        for turn in 0..<4 {
            var g = GeometryAdjustments(); g.flipHorizontal = true; g.crop = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
            let plan = try GeometryPlan(size: extent.size, settings: g, quarterTurns: turn)
            let output = plan.apply(to: image), p = plan.displayPoint(MaskPoint(x: 0.2, y: 0.7))
            XCTAssertEqual(output.extent.size, plan.outputSize)
            XCTAssertGreaterThan(value(output, p.x * plan.outputSize.width, p.y * plan.outputSize.height, context), 0.5)
        }
    }
    func testCloneAndHealAreLocalAndHealMatchesTargetTone() throws {
        let context = try context(), engine = RetouchRenderer(context: context), extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let image = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            .composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: extent))
        var stroke = RetouchStroke(mode: .clone, source: .init(x: 0.25, y: 0.5), target: .init(x: 0.75, y: 0.5), radius: 0.12, softness: 0.3, opacity: 1)
        let clone = try engine.apply([stroke], to: image)
        XCTAssertEqual(value(clone, 150, 50, context), value(image, 50, 50, context), accuracy: 0.005)
        XCTAssertEqual(value(clone, 150, 15, context), value(image, 150, 15, context), accuracy: 0.005)
        stroke.mode = .heal
        let heal = try engine.apply([stroke], to: image)
        XCTAssertEqual(value(heal, 150, 50, context), value(image, 150, 50, context), accuracy: 0.015)
        stroke.enabled = false
        XCTAssertEqual(value(try engine.apply([stroke], to: image), 150, 50, context), value(image, 150, 50, context), accuracy: 0.005)
    }
    func testSaveReopenAndExportKeepGeometryAndRetouch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try context(), rect = CGRect(x: 0, y: 0, width: 240, height: 160)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: rect)
        let source = dir.appendingPathComponent("image.png")
        try XCTUnwrap(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: RGBProfile.sRGB.space)).write(to: source)
        let renderer = try RawRenderer(sourceURL: source)
        var edits = renderer.info.defaults
        edits.quarterTurns = 1; edits.geometry.straighten = 4; edits.geometry.flipHorizontal = true
        edits.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.7, height: 0.8)
        edits.retouch = [RetouchStroke(mode: .clone, source: .init(x: 0.2, y: 0.3), target: .init(x: 0.6, y: 0.5), radius: 0.04, softness: 0.5, opacity: 1)]
        let (reopened, stored) = try await reopenThroughCatalog(renderer, edits)
        XCTAssertEqual(stored, edits)
        let preview = try await reopened.preview(stored)
        let plan = try GeometryPlan(size: rect.size, settings: edits.geometry, quarterTurns: 1)
        XCTAssertEqual(preview.image.width, Int(plan.outputSize.width)); XCTAssertEqual(preview.image.height, Int(plan.outputSize.height))
        var settings = ExportSettings(); settings.select(.tiff); settings.depth = 16; settings.profile = stored.colorProfile
        let output = dir.appendingPathComponent("export.tiff")
        try await reopened.export(to: output, adjustments: stored, settings: settings)
        let file = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil)), exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, nil))
        XCTAssertEqual(exported.width, preview.image.width); XCTAssertEqual(exported.height, preview.image.height)
        XCTAssertEqual(value(CIImage(cgImage: exported), 40, 40, context), value(CIImage(cgImage: preview.image), 40, 40, context), accuracy: 0.005)
    }
    func testNewEditsPersistAndOldEditsDefaultToIdentity() throws {
        let old = try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8))
        XCTAssertEqual(old.geometry, GeometryAdjustments()); XCTAssertTrue(old.retouch.isEmpty)
        var a = old; a.geometry.straighten = 3; a.geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        a.retouch = [RetouchStroke(mode: .heal, source: .init(x: 0.2, y: 0.3), target: .init(x: 0.7, y: 0.8), radius: 0.03, softness: 0.6, opacity: 1)]
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a)), a)
        _ = try a.validated()
        a.geometry.crop.width = 1
        XCTAssertThrowsError(try a.validated())
    }
}
