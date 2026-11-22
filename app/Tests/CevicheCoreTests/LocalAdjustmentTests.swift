import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class LocalAdjustmentTests: XCTestCase {
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAf])
    }
    private let rect = CGRect(x: 0, y: 0, width: 160, height: 100)
    private func pixels(_ image: CIImage, _ ctx: CIContext) -> [Float] {
        var v = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        v.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
        return v
    }
    private func value(_ image: CIImage, _ x: Double, _ y: Double, _ ctx: CIContext) -> Float {
        var v = [Float](repeating: 0, count: 4)
        v.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return v[0]
    }
    private func left() -> PhotoMask {
        var m = PhotoMask(kind: .linear); m.feather = 0; m.start = .init(x: 0.45, y: 0.5); m.end = .init(x: 0.55, y: 0.5); return m
    }
    func testExpandedLocalToolsMatchSharedEngineAndStayInsideMask() throws {
        let ctx = try context(), renderer = MaskRenderer(context: ctx)
        let source = CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.1)).cropped(to: rect)
        var mask = left()
        mask.adjustments.redCurve.insert(x: 0.4, y: 0.7)
        mask.adjustments.parametricCurve.lights = 15; mask.adjustments.whites = 20
        mask.adjustments.vibrance = 25; mask.adjustments.selectiveColors[1].hue = 35
        mask.adjustments.splitToning.highlightHue = 220; mask.adjustments.splitToning.highlightSaturation = 50
        mask.adjustments.calibration.greenSaturation = 20; mask.adjustments.grain.amount = 15
        mask.adjustments.sharpness = 20; mask.adjustments.sharpenRadius = 2
        let output = try renderer.apply([mask], to: source)
        let full = PixelRenderer().apply(mask.adjustments, to: source, scale: 1, local: true)
        XCTAssertEqual(value(output, 20, 50, ctx), value(full, 20, 50, ctx), accuracy: 0.001)
        XCTAssertGreaterThan(abs(value(output, 20, 50, ctx) - value(source, 20, 50, ctx)), 0.01)
        XCTAssertEqual(value(output, 140, 50, ctx), value(source, 140, 50, ctx), accuracy: 0.001)
        var settings = mask.adjustments; settings.disabledSections = Set(AdjustmentGroup.allCases)
        let bypass = PixelRenderer().apply(settings, to: source, scale: 1, local: true)
        XCTAssertEqual(value(bypass, 20, 50, ctx), value(source, 20, 50, ctx), accuracy: 0.001)
    }
    func testCompoundAddSubtractIntersectAndInversion() throws {
        let ctx = try context(), renderer = MaskRenderer(context: ctx), source = CIImage(color: .white).cropped(to: rect)
        var mask = left(), right = left().selection; right.inverted = true
        mask.components = [MaskComponent(operation: .add, selection: right)]
        var output = try renderer.image(for: mask, source: source)
        XCTAssertGreaterThan(value(output, 20, 50, ctx), 0.99); XCTAssertGreaterThan(value(output, 140, 50, ctx), 0.99)
        var center = MaskSelection(kind: .radial); center.feather = 0; center.start = .init(x: 0.2, y: 0.2); center.end = .init(x: 0.8, y: 0.8)
        mask.components.append(MaskComponent(operation: .subtract, selection: center))
        output = try renderer.image(for: mask, source: source)
        XCTAssertLessThan(value(output, 80, 50, ctx), 0.01); XCTAssertGreaterThan(value(output, 20, 50, ctx), 0.99)
        mask.components = [MaskComponent(operation: .intersect, selection: center)]
        output = try renderer.image(for: mask, source: source)
        XCTAssertGreaterThan(value(output, 60, 50, ctx), 0.95); XCTAssertLessThan(value(output, 20, 50, ctx), 0.01)
        mask.inverted = true; mask.opacity = 0.5
        output = try renderer.image(for: mask, source: source)
        XCTAssertEqual(value(output, 20, 50, ctx), 0.5, accuracy: 0.005)
        XCTAssertLessThan(value(output, 60, 50, ctx), 0.03)
    }
    func testColorComponentsDoNotReuseCoverageFromDifferentPixels() throws {
        let ctx = try context(), renderer = MaskRenderer(context: ctx)
        var mask = left(), color = MaskSelection(kind: .color); color.color = [1, 0, 0]; color.tolerance = 0.1; color.feather = 0
        mask.components = [MaskComponent(operation: .intersect, selection: color)]
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: rect), blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect)
        XCTAssertGreaterThan(value(try renderer.image(for: mask, source: red), 20, 50, ctx), 0.9)
        XCTAssertLessThan(value(try renderer.image(for: mask, source: blue), 20, 50, ctx), 0.01)
    }
    func testPartialAndExpandedMaskSerialization() throws {
        let partial = try JSONDecoder().decode(LocalAdjustments.self, from: Data("{\"exposure\":0.5,\"sharpness\":-30,\"warmth\":20}".utf8))
        XCTAssertEqual(partial.exposure, 0.5); XCTAssertTrue(partial.curve.isIdentity); XCTAssertNil(partial.colorNoiseReduction)
        var a = Adjustments(), mask = left(); mask.adjustments = partial
        mask.adjustments.blueCurve.insert(x: 0.6, y: 0.4); mask.adjustments.monochrome = true; mask.adjustments.blackWhiteMixer.values[0] = 30
        mask.components = [MaskComponent(operation: .intersect, selection: MaskSelection(kind: .radial))]
        a.masks = [mask]; a.exposure = 1.25
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(restored, a)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        XCTAssertEqual(json["exposure"] as? Double, 1.25); XCTAssertNil(json["pixels"])
        a.masks[0].adjustments.redCurve.points[0].y = .nan
        XCTAssertThrowsError(try a.validated())
    }
    func testLocalPipelineSaveReopenAndExport() async throws {
        let ctx = try context(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try XCTUnwrap(ctx.pngRepresentation(of: CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.1)).cropped(to: rect), format: .RGBA8, colorSpace: RGBProfile.sRGB.space)).write(to: source)
        let renderer = try RawRenderer(sourceURL: source)
        var a = renderer.info.defaults, m = left(); m.adjustments.greenCurve.insert(x: 0.3, y: 0.5); m.adjustments.selectiveColors[1].saturation = -50
        m.adjustments.grain.amount = 20; m.components = [MaskComponent(operation: .intersect, selection: MaskSelection(kind: .radial))]; a.masks = [m]
        let (reopened, restored) = try await reopenThroughCatalog(renderer, a); XCTAssertEqual(restored, a)
        let preview = try await reopened.preview(restored), output = dir.appendingPathComponent("local.tiff")
        var export = ExportSettings(); export.select(.tiff); export.depth = 16; export.profile = a.colorProfile
        try await reopened.export(to: output, adjustments: restored, settings: export)
        let expected = pixels(CIImage(cgImage: preview.image), ctx), actual = pixels(try XCTUnwrap(CIImage(contentsOf: output)), ctx)
        XCTAssertEqual(actual.count, expected.count); XCTAssertLessThan(zip(actual, expected).map { abs($0 - $1) }.max()!, 0.003)
    }
}
