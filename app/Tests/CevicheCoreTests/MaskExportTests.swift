import XCTest
import CevicheTestSupport
import CoreImage
import Metal
import ImageIO
@testable import CevicheCore

final class MaskExportTests: XCTestCase {
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device)
    }
    private func value(_ image: CIImage, x: Double, y: Double, context: CIContext) -> Double {
        var v = [Float](repeating: 0, count: 4)
        v.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return Double(v[0])
    }
    func testGradientsBrushErasingAndRotationCoordinates() throws {
        let context = try context(), engine = MaskRenderer()
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var mask = PhotoMask(kind: .linear); mask.feather = 0; mask.start = MaskPoint(x: 0, y: 0.5); mask.end = MaskPoint(x: 1, y: 0.5)
        let linear = try engine.image(for: mask, source: source)
        XCTAssertGreaterThan(value(linear, x: 10, y: 50, context: context), 0.9)
        XCTAssertLessThan(value(linear, x: 190, y: 50, context: context), 0.1)
        mask.inverted = true
        XCTAssertLessThan(value(try engine.image(for: mask, source: source), x: 10, y: 50, context: context), 0.1)
        mask = PhotoMask(kind: .radial); mask.feather = 0.1
        let radial = try engine.image(for: mask, source: source)
        XCTAssertGreaterThan(value(radial, x: 100, y: 50, context: context), 0.99)
        XCTAssertLessThan(value(radial, x: 10, y: 10, context: context), 0.01)
        // A tall, narrow ellipse turned 90° becomes wide: a point far out along x is covered, far out along y is not.
        mask.start = MaskPoint(x: 0.45, y: 0.1); mask.end = MaskPoint(x: 0.55, y: 0.9); mask.feather = 0
        XCTAssertLessThan(value(try engine.image(for: mask, source: source), x: 140, y: 50, context: context), 0.01)
        mask.rotation = 90
        let turned = try engine.image(for: mask, source: source)
        XCTAssertGreaterThan(value(turned, x: 130, y: 50, context: context), 0.99)
        XCTAssertLessThan(value(turned, x: 100, y: 15, context: context), 0.01)
        mask = PhotoMask(kind: .brush); mask.feather = 0
        mask.strokes = [MaskStroke(points: [MaskPoint(x: 0.2, y: 0.8), MaskPoint(x: 0.8, y: 0.8)], radius: 0.1, softness: 0.3, erase: false)]
        let brushed = try engine.image(for: mask, source: source)
        XCTAssertGreaterThan(value(brushed, x: 100, y: 80, context: context), 0.95, "Brush paths must fill between samples")
        XCTAssertLessThan(value(brushed, x: 100, y: 20, context: context), 0.01, "Brush Y must use source coordinates")
        mask.strokes.append(MaskStroke(points: [MaskPoint(x: 0.5, y: 0.8)], radius: 0.1, softness: 0.3, erase: true))
        XCTAssertLessThan(value(try engine.image(for: mask, source: source), x: 100, y: 80, context: context), 0.05)
        for turn in 0..<4 {
            let point = MaskPoint(x: 0.15, y: 0.7)
            let roundtrip = point.rotated(turn).unrotated(turn)
            XCTAssertEqual(roundtrip.x, point.x, accuracy: 1e-12); XCTAssertEqual(roundtrip.y, point.y, accuracy: 1e-12)
        }
    }
    func testMultipleMasksApplyOnlyInsideSelectionsAndCanDisable() throws {
        let context = try context(), engine = MaskRenderer()
        let source = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        var left = PhotoMask(kind: .linear); left.feather = 0; left.start = MaskPoint(x: 0.4, y: 0); left.end = MaskPoint(x: 0.6, y: 0); left.adjustments.exposure = 1
        var right = left; right.id = UUID(); right.inverted = true; right.adjustments.exposure = 2
        let edited = try engine.apply([left, right], to: source)
        let base = value(source, x: 10, y: 50, context: context)
        XCTAssertEqual(value(edited, x: 10, y: 50, context: context), base * 2, accuracy: 0.005)
        XCTAssertEqual(value(edited, x: 190, y: 50, context: context), base * 4, accuracy: 0.005)
        right.enabled = false
        XCTAssertEqual(value(try engine.apply([left, right], to: source), x: 190, y: 50, context: context), base, accuracy: 0.005)
    }
    private func fixture(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.png")
        let ctx = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 16, bytesPerRow: 256*8, space: RGBProfile.displayP3.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }
    func testExportActualDepthProfileDimensionsAndOriginalProtection() async throws {
        _ = try context()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir), renderer = try RawRenderer(sourceURL: source)
        let original = try Data(contentsOf: source)
        var adjustments = renderer.info.defaults; adjustments.quarterTurns = 1
        for format in ExportFormat.allCases where format.isAvailable {
            for depth in format.depths {
                var settings = ExportSettings(); settings.select(format); settings.depth = depth
                let url = dir.appendingPathComponent("\(depth).\(format.fileExtension)")
                try await renderer.export(to: url, adjustments: adjustments, settings: settings)
                let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any])
                XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, depth, format.rawValue)
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 128)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 256)
                // Automatic: sRGB, except HEIF, which phones with P3 screens open.
                XCTAssertEqual(properties[kCGImagePropertyProfileName as String] as? String, format == .heif ? "Display P3" : "sRGB IEC61966-2.1", format.rawValue)
            }
        }
        do { try await renderer.export(to: source, adjustments: adjustments, settings: ExportSettings()); XCTFail("Overwrote original") } catch { }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testSavedMaskRasterAndICCReopenWithoutInference() async throws {
        _ = try context()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = try fixture(dir), renderer = try RawRenderer(sourceURL: source)
        var a = renderer.info.defaults
        var mask = PhotoMask(kind: .subject); mask.adjustments.exposure = 1; mask.cutsOutBackground = true
        let matte = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: 128, y: 64), "inputRadius0": 20, "inputRadius1": 50, "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 128))
        mask.raster = try MaskRaster.encode(matte, context: context())
        XCTAssertNotNil(mask.raster)
        a.masks = [mask]
        a.colorProfile.preset = .custom; a.colorProfile.iccData = RGBProfile.adobeRGB.space.copyICCData() as Data?; a.colorProfile.name = "Embedded test"
        let (reopened, loaded) = try await reopenThroughCatalog(renderer, a)
        XCTAssertEqual(loaded, a)
        let before = try await renderer.preview(a), after = try await reopened.preview(loaded)
        XCTAssertEqual(before.thumbnail, after.thumbnail)
        var settings = ExportSettings(); settings.select(.png)
        let output = dir.appendingPathComponent("cutout.png")
        try await reopened.export(to: output, adjustments: loaded, settings: settings)
        let data = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(data, 0, nil))
        var p = [Float](repeating: 0, count: 4)
        let ctx = try context()
        p.withUnsafeMutableBytes { ctx.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        XCTAssertLessThan(p[3], 0.01)
        let auto = try await reopened.autoAdjust(loaded)
        XCTAssertEqual(auto.masks, a.masks); XCTAssertEqual(auto.colorProfile, a.colorProfile); XCTAssertNoThrow(try auto.validated())
    }
    func testLocalVisionSelectionsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_TEST_LOCAL_VISION"] == "1" else { throw XCTSkip("Set CEVICHE_TEST_LOCAL_VISION=1 to exercise local model assets") }
        _ = try context()
        let renderer = try RawRenderer(sourceURL: try TestSamples.require(TestSamples.landscape))
        let object = try await renderer.selection(.object, point: MaskPoint(x: 0.5, y: 0.5))
        XCTAssertNotNil(object.raster)
        var settings = renderer.info.defaults; settings.masks = [object]
        _ = try await renderer.maskOverlay(object, adjustments: settings)
        // Some landscape fixtures have no salient foreground. That must be a recoverable error.
        for kind in [MaskKind.subject, .background] {
            do {
                let mask = try await renderer.selection(kind)
                XCTAssertNotNil(mask.raster)
                XCTAssertEqual(mask.selection.inverted, kind == .background)
            } catch EditorError.invalidDocument(let message) {
                XCTAssertTrue(message.contains("No foreground subject was found"), message)
            }
        }
    }
    func testColorRangeSelectsPickedColor() throws {
        let ctx = try context(), engine = MaskRenderer()
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: red.extent)
        var mask = PhotoMask(kind: .color); mask.color = [1,0,0]; mask.feather = 0; mask.tolerance = 0.1
        XCTAssertGreaterThan(value(try engine.image(for: mask, source: red), x: 30, y: 30, context: ctx), 0.99)
        XCTAssertLessThan(value(try engine.image(for: mask, source: blue), x: 30, y: 30, context: ctx), 0.01)
    }
    func testInvalidMaskAndProfileRejected() throws {
        let empty = Adjustments()
        var a = empty; var mask = PhotoMask(kind: .brush); mask.opacity = .nan; a.masks = [mask]
        XCTAssertThrowsError(try a.validated())
        a = empty; a.colorProfile.preset = .custom; a.colorProfile.iccData = Data([1,2,3]); XCTAssertThrowsError(try a.validated())
        var options = ExportSettings(); options.format = .jpeg; options.depth = 16
        XCTAssertThrowsError(try options.validate())
    }
}
