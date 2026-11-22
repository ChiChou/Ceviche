import XCTest
import CevicheTestSupport
import CoreImage
import Metal
import ImageIO
@testable import CevicheCore

final class HDRTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func context() throws -> CIContext {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return CIContext(mtlDevice: device, options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
    }
    private func solid(_ r: Float, _ g: Float, _ b: Float, alpha: Float = 1) -> CIImage {
        let pixels = [r * alpha, g * alpha, b * alpha, alpha]
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: space)
            .transformed(by: CGAffineTransform(scaleX: 64, y: 64))
    }
    private func pixel(_ image: CIImage, _ context: CIContext) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: space) }
        return result
    }
    func testOnlyBitmapsThatCanExceedWhiteOpenAsHDR() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try context(), bright = solid(3, 2.5, 2).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let float = folder.appendingPathComponent("float.tiff"), integer = folder.appendingPathComponent("integer.tiff")
        try context.writeTIFFRepresentation(of: bright, to: float, format: .RGBAf, colorSpace: space)
        try context.writeTIFFRepresentation(of: bright, to: integer, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        XCTAssertTrue(try RawRenderer.open(float).1.hdr.enabled, "Floating-point values above white")
        XCTAssertFalse(try RawRenderer.open(integer).1.hdr.enabled, "Integer samples end at white")
    }
    func testHDRImportModeIsExplicitAndRoundTrips() throws {
        let packet = try XMPTests().packet("crs:HDREditMode=\"1\" crs:HDRMaxValue=\"4\"")
        var a = try XMPCodec.apply(packet, to: Adjustments()).adjustments
        XCTAssertTrue(a.hdr.enabled); XCTAssertEqual(a.hdr.headroom, 4)
        a.hdr.sdrExposure = -0.7
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a)), a)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(data: XMPCodec.encode(adjustments: a)), to: Adjustments()).adjustments, a)
        XCTAssertFalse(try XMPCodec.apply(XMPTests().packet("crs:HDRMaxValue=\"4\""), to: Adjustments()).adjustments.hdr.enabled)
        XCTAssertTrue(try XMPCodec.apply(XMPTests().packet("crs:HDREditMode=\"1\""), to: Adjustments()).adjustments.hdr.enabled)
        XCTAssertFalse(try XMPCodec.apply(XMPTests().packet("crs:HDREditMode=\"0\""), to: a).adjustments.hdr.enabled)
        XCTAssertFalse(try JSONDecoder().decode(Adjustments.self, from: Data("{}".utf8)).hdr.enabled)
        XCTAssertThrowsError(try XMPCodec.apply(XMPTests().packet("crs:HDREditMode=\"maybe\""), to: a))
        a.hdr.headroom = .nan; XCTAssertThrowsError(try a.validated())
    }
    func testFloatPixelsSurviveColorToolsAndLocalAdjustments() throws {
        let ctx = try context(), image = solid(4, 2, 1)
        let renderer = PixelRenderer()
        let identity = pixel(renderer.apply(PixelAdjustments(), to: image, scale: 1, local: false, hdr: true), ctx)
        XCTAssertEqual(identity[0], 4, accuracy: 0.02); XCTAssertEqual(identity[1], 2, accuracy: 0.02)
        var settings = PixelAdjustments()
        settings.calibration.redHue = 12
        settings.curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)])
        settings.selectiveColors[0].saturation = 15
        settings.splitToning.highlightHue = 35; settings.splitToning.highlightSaturation = 10
        settings.vibrance = 12
        let edited = pixel(renderer.apply(settings, to: image, scale: 1, local: false, hdr: true), ctx)
        XCTAssertTrue(edited.allSatisfy(\.isFinite)); XCTAssertGreaterThan(edited[0], 2)
        XCTAssertGreaterThan(edited[1], 1); XCTAssertNotEqual(edited, identity)
        var local = PixelAdjustments(); local.exposure = 1
        let brighter = pixel(renderer.apply(local, to: image, scale: 1, local: true, hdr: true), ctx)
        XCTAssertEqual(brighter[0], 8, accuracy: 0.04)
        local.exposure = 0; local.highlights = -50
        let darker = pixel(renderer.apply(local, to: image, scale: 1, local: true, hdr: true), ctx)
        XCTAssertLessThan(darker[0], identity[0]); XCTAssertGreaterThan(darker[0], 1)
        let transparent = solid(4, 2, 1, alpha: 0.5)
        let restored = HDRRenderer.bounded(transparent, enabled: true) { $0.applyingFilter("CIExposureAdjust", parameters: ["inputEV": -1]) }
        let result = pixel(restored, ctx)
        XCTAssertEqual(result[0], 1, accuracy: 0.01); XCTAssertEqual(result[3], 0.5, accuracy: 0.001)
    }
    func testHDRDetailAndFilmToolsKeepHeadroom() throws {
        let ctx = try context(), image = solid(4, 3, 2), renderer = PixelRenderer()
        let edits: [(String, (inout PixelAdjustments) -> Void)] = [
            ("noise", { $0.noiseReduction = 40; $0.colorNoiseReduction = 40; $0.colorNoiseDetail = 75; $0.colorNoiseSmoothness = 75 }),
            ("grain", { $0.grain.amount = 35 }),
            ("sharpen", { $0.sharpness = 40; $0.sharpenDetail = 50 }),
            ("clarity", { $0.clarity = 20 }),
            ("monochrome", { $0.monochrome = true }),
            ("point color", { var point = PointColor(red: 1, green: 0.88, blue: 0.735); point.hueShift = 0.1; $0.pointColors = [point] })
        ]
        for (name, edit) in edits {
            var settings = PixelAdjustments(); edit(&settings)
            let rgb = pixel(renderer.apply(settings, to: image, scale: 1, local: true, hdr: true), ctx)
            XCTAssertTrue(rgb.allSatisfy(\.isFinite), name)
            XCTAssertGreaterThan(rgb.prefix(3).max() ?? 0, 2, name)
        }
    }
    func testHDRColorMaskUsesUnclippedColor() throws {
        let ctx = try context(), source = solid(4, 2, 1)
        var mask = PhotoMask(kind: .color)
        mask.color = [1, 0.735357, 0.537099]; mask.tolerance = 0.1
        let renderer = MaskRenderer(context: ctx)
        let selected = pixel(try renderer.image(for: mask, source: source, hdr: true), ctx)
        XCTAssertGreaterThan(selected[0], 0.9)
        let rejected = pixel(try renderer.image(for: mask, source: solid(1, 2, 4), hdr: true), ctx)
        XCTAssertLessThan(rejected[0], 0.1)
    }
    func testToneMappingPreservesHighlightOrderingAndNeutrality() throws {
        let ctx = try context()
        var values: [Float] = []
        for level: Float in [0.18, 1, 2, 4, 8, 16] {
            let mapped = HDRRenderer.toneMap(solid(level, level, level), source: 16)
            let rgb = pixel(mapped, ctx)
            XCTAssertTrue(rgb.allSatisfy(\.isFinite))
            XCTAssertEqual(rgb[0], rgb[1], accuracy: 0.001); XCTAssertEqual(rgb[1], rgb[2], accuracy: 0.001)
            XCTAssertLessThanOrEqual(rgb[0], 1.002); values.append(rgb[0])
        }
        for (low, high) in zip(values, values.dropFirst()) { XCTAssertLessThan(low, high) }
        XCTAssertEqual(HDRRenderer.headroom(solid(8, 4, 2), context: ctx), 8, accuracy: 0.01)
        XCTAssertEqual(HDRRenderer.headroom(solid(8, 4, 2, alpha: 0.5), context: ctx), 8, accuracy: 0.01)
    }
    func testPreviewExportAndDocumentRetainHDR() async throws {
        let ctx = try context()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.tiff")
        try XCTUnwrap(ctx.tiffRepresentation(of: solid(4, 2, 1), format: .RGBAf, colorSpace: space)).write(to: source)
        let renderer = try RawRenderer(sourceURL: source)
        XCTAssertTrue(renderer.info.defaults.hdr.enabled)
        var a = renderer.info.defaults; a.hdr.enabled = true; a.colorProfile.preset = .sRGB
        let hdr = try await renderer.preview(a)
        XCTAssertTrue(hdr.image.bitmapInfo.contains(.floatComponents))
        XCTAssertGreaterThan(hdr.image.contentHeadroom, 1)
        let sdr = try await renderer.preview(a, sdr: true)
        XCTAssertFalse(sdr.image.bitmapInfo.contains(.floatComponents))
        XCTAssertLessThanOrEqual(pixel(CIImage(cgImage: sdr.image), ctx)[0], 1.01)
        XCTAssertGreaterThan(pixel(CIImage(cgImage: hdr.image), ctx)[0], 1.5)
        let restored = try await reopenThroughCatalog(renderer, a).1
        XCTAssertEqual(restored.hdr, a.hdr)
        var options = ExportSettings(); options.profile = a.colorProfile; options.setHDR(true)
        let export = directory.appendingPathComponent("hdr.tiff")
        try await renderer.export(to: export, adjustments: a, settings: options)
        let decoded = try XCTUnwrap(CIImage(contentsOf: export))
        XCTAssertGreaterThan(pixel(decoded, ctx)[0], 1.5)
        let sourceRef = try XCTUnwrap(CGImageSourceCreateWithURL(export as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceRef, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary))
        XCTAssertEqual(cg.bitsPerComponent, 32); XCTAssertTrue(cg.bitmapInfo.contains(.floatComponents))
        options.select(.png)
        options.setHDR(false)
        XCTAssertFalse(options.hdr); XCTAssertEqual(options.depth, 16)
        let png = directory.appendingPathComponent("sdr.png")
        try await renderer.export(to: png, adjustments: a, settings: options)
        XCTAssertLessThanOrEqual(pixel(try XCTUnwrap(CIImage(contentsOf: png)), ctx)[0], 1.01)
    }
    /// Before macOS 26 a CIImage cannot carry a headroom tag, so the render path measures the pixels and stamps the
    /// CGImage; the sparse highlight must count, and a rect sees only its own pixels.
    func testLegacyRenderStampsMeasuredHeadroom() throws {
        let ctx = try context()
        let star = solid(4, 4, 4).cropped(to: CGRect(x: 30, y: 30, width: 2, height: 2))
        let scene = star.composited(over: solid(0.2, 0.2, 0.2).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)))
        let whole = try XCTUnwrap(ctx.legacyCGImage(scene, from: scene.extent, format: .RGBAh, colorSpace: HDRRenderer.space, hdr: true))
        XCTAssertEqual(whole.contentHeadroom, 4, accuracy: 0.05)
        // `solid` is 64 × 64; this corner misses the star.
        let corner = try XCTUnwrap(ctx.legacyCGImage(scene, from: CGRect(x: 0, y: 0, width: 16, height: 16), format: .RGBAh, colorSpace: HDRRenderer.space, hdr: true))
        XCTAssertEqual(corner.contentHeadroom, 1, accuracy: 0.001)
        XCTAssertEqual(corner.width, 16)
        // An SDR render in a non-extended space is left as Core Image made it.
        let sdr = try XCTUnwrap(ctx.legacyCGImage(scene, from: scene.extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, hdr: false))
        XCTAssertEqual(sdr.width, 64)
    }
    /// A photo whose only HDR content is a few bright pixels (stars, speculars) must still be flagged HDR for display:
    /// Core Image's HDR statistics round such an image to a headroom of 1, which Core Animation shows as SDR.
    func testPreviewHeadroomFollowsSparseHighlights() async throws {
        let ctx = try context()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let star = solid(4, 4, 4).cropped(to: CGRect(x: 30, y: 30, width: 2, height: 2))
        let scene = star.composited(over: solid(0.2, 0.2, 0.2).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)))
        let source = directory.appendingPathComponent("sparse.tiff")
        try XCTUnwrap(ctx.tiffRepresentation(of: scene, format: .RGBAf, colorSpace: space)).write(to: source)
        let renderer = try RawRenderer(sourceURL: source)
        var a = renderer.info.defaults; a.hdr.enabled = true; a.colorProfile.preset = .sRGB
        if #available(macOS 26, *) {
            let statistic = try XCTUnwrap(ctx.createCGImage(scene, from: scene.extent, format: .RGBAh, colorSpace: HDRRenderer.space, deferred: false, calculateHDRStats: true))
            XCTAssertLessThan(statistic.contentHeadroom, 1.5, "the statistic ignores the sparse highlight; the preview must not rely on it")
        }
        let preview = try await renderer.preview(a)
        XCTAssertEqual(preview.image.contentHeadroom, 4, accuracy: 0.05)
        let detail = try await renderer.detail(a, region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(try XCTUnwrap(detail).image.contentHeadroom, 4, accuracy: 0.05)
        let display = try await renderer.displayImage(a, maxDimension: 128)
        XCTAssertEqual(display.contentHeadroom, 4, accuracy: 0.05)
        // The headroom is capped by the output headroom setting, and SDR previews report none.
        a.hdr.headroom = 1
        let capped = try await renderer.preview(a), sdr = try await renderer.preview(a, sdr: true)
        XCTAssertEqual(capped.image.contentHeadroom, 2, accuracy: 0.05)
        XCTAssertEqual(sdr.image.contentHeadroom, 1)
    }
    func testRealHDRSidecarsRenderFloatPreviews() async throws {
        for url in [try TestSamples.require(TestSamples.hdrSidecar)] {
            let name = url.lastPathComponent
            let renderer = try RawRenderer(sourceURL: url)
            let settings = try XMPCodec.apply(XMPPacket(url: url.deletingPathExtension().appendingPathExtension("xmp")), to: renderer.info.defaults).adjustments
            XCTAssertTrue(settings.hdr.enabled)
            let preview = try await renderer.preview(settings)
            XCTAssertTrue(preview.image.bitmapInfo.contains(.floatComponents))
            // Enabling HDR permits extended values; an image whose highlights have
            // been reduced need not actually exceed SDR white.
            XCTAssertGreaterThanOrEqual(preview.image.contentHeadroom, 1, name)
            var brighter = settings; brighter.exposure = min(5, settings.exposure + 3)
            let lifted = try await renderer.preview(brighter)
            XCTAssertGreaterThan(lifted.image.contentHeadroom, 1, name)
            XCTAssertEqual(preview.histogram.count, 3)
            XCTAssertFalse(preview.thumbnail.isEmpty)
        }
    }

}
