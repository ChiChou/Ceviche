import XCTest
import CevicheTestSupport
import CoreImage
import Metal
@testable import CevicheCore

final class ExtendedXMPTests: XCTestCase {
    private func packet(_ attrs: String = "", _ children: String = "") throws -> XMPPacket { try XMPTests().packet(attrs, children) }
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    }
    private func pixel(_ image: CIImage, _ context: CIContext, x: Int = 32, y: Int = 32) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return values
    }
    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage { CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)) }
    func testExtendedScalarImportAndNativePortableRoundTrip() throws {
        let imported = try XMPCodec.apply(packet("""
        crs:ColorGradeBlending="80" crs:ColorGradeGlobalHue="45" crs:ColorGradeGlobalSat="12" crs:ColorGradeGlobalLum="-8"
        crs:ColorGradeMidtoneHue="190" crs:ColorGradeMidtoneSat="20" crs:ColorGradeMidtoneLum="-6" crs:ColorGradeShadowLum="10" crs:ColorGradeHighlightLum="-3"
        crs:ColorNoiseReduction="25" crs:ColorNoiseReductionDetail="68" crs:ColorNoiseReductionSmoothness="75" crs:CurveRefineSaturation="25"
        crs:DefringeGreenAmount="4" crs:DefringeGreenHueLo="30" crs:DefringeGreenHueHi="70" crs:DefringePurpleAmount="8" crs:DefringePurpleHueLo="20" crs:DefringePurpleHueHi="80"
        crs:PostCropVignetteAmount="-40" crs:PostCropVignetteFeather="70" crs:PostCropVignetteMidpoint="52" crs:PostCropVignetteHighlightContrast="27"
        crs:CompatibleVersion="268435456" crs:HDRMaxValue="4" crs:HDREditMode="0"
        """), to: Adjustments())
        let a = imported.adjustments
        XCTAssertEqual(a.splitToning.midtoneLuminance, -6); XCTAssertEqual(a.splitToning.globalHue, 45); XCTAssertEqual(a.splitToning.blending, 80)
        XCTAssertEqual(a.colorNoiseDetail, 68); XCTAssertEqual(a.curveSaturation, 25)
        XCTAssertEqual(a.defringe.purpleAmount, 8); XCTAssertEqual(a.postCropVignette.highlights, 27); XCTAssertEqual(a.vignette, 0)
        XCTAssertFalse(imported.warnings.joined().contains("Unsupported: "))
        let data = try XMPCodec.encode(adjustments: a)
        let exported = try XMPPacket(data: data)
        for control in XMPCodec.controls { XCTAssertEqual(exported.value(control.name), String(a[keyPath: control.key]), control.name) }
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(data: data), to: Adjustments()).adjustments, a)
        // Remove the native recipe to exercise the real portable mapping, rather than self round-tripping JSON.
        let xml = try XMLDocument(data: data), nodes = try xml.nodes(forXPath: "//*[local-name()='Description']/@*[local-name()='Recipe']")
        nodes.forEach { $0.detach() }
        XCTAssertEqual(try XMPPacket(data: xml.xmlData).value("CurveRefineSaturation"), "25.0")
        let portable = try XMPCodec.apply(XMPPacket(data: xml.xmlData), to: Adjustments()).adjustments
        XCTAssertEqual(portable.splitToning, a.splitToning); XCTAssertEqual(portable.defringe, a.defringe)
        XCTAssertEqual(portable.postCropVignette, a.postCropVignette); XCTAssertEqual(portable.curveSaturation, 25)
        var local = a.pixels; local.disabledSections = [.splitToning, .curve, .noiseReduction, .defringe, .vignette]
        let bypass = local.effective()
        XCTAssertTrue(bypass.splitToning.isIdentity); XCTAssertTrue(bypass.defringe.isIdentity)
        XCTAssertEqual(bypass.curveSaturation, 100); XCTAssertEqual(bypass.colorNoiseSmoothness, 50); XCTAssertEqual(bypass.postCropVignette.amount, 0)
        let partial = try JSONDecoder().decode(SplitToning.self, from: Data("{\"shadowHue\":45,\"shadowSaturation\":20}".utf8))
        XCTAssertEqual(partial.blending, 50); XCTAssertEqual(partial.midtoneLuminance, 0)
        XCTAssertThrowsError(try XMPCodec.apply(packet("crs:ColorGradeGlobalLum=\"nan\""), to: Adjustments()))
        XCTAssertThrowsError(try XMPCodec.apply(packet("crs:DefringeGreenHueLo=\"90\" crs:DefringeGreenHueHi=\"10\""), to: Adjustments()))
    }
    func testPointColorsSentinelsTargetingVarianceAndMalformedData() throws {
        let empty = Array(repeating: "-1", count: 19).joined(separator: ",")
        let placeholder = try XMPCodec.apply(packet("", "<crs:PointColors><rdf:Seq><rdf:li>\(empty)</rdf:li></rdf:Seq></crs:PointColors><crs:ColorVariance><rdf:Seq><rdf:li>-50</rdf:li></rdf:Seq></crs:ColorVariance>"), to: Adjustments())
        XCTAssertTrue(placeholder.adjustments.pointColors.isEmpty); XCTAssertFalse(placeholder.warnings.joined().contains("Preserved"))
        let values = "0, 0.8, 0.5, 0.1, -0.2, 0.1, 0.25, 0.4, 0.48, 0.52, 0.6, 0, 0.1, 0.9, 1, 0, 0.1, 0.9, 1"
        let p = try packet("", "<crs:PointColors><rdf:Seq><rdf:li>\(values)</rdf:li></rdf:Seq></crs:PointColors><crs:ColorVariance><rdf:Seq><rdf:li>-35</rdf:li></rdf:Seq></crs:ColorVariance>")
        let a = try XMPCodec.apply(p, to: Adjustments()).adjustments, point = try XCTUnwrap(a.pointColors.first)
        XCTAssertEqual(point.variance, -35)
        let red = SIMD3<Double>(0.9, 0.1, 0.1), blue = SIMD3<Double>(0.1, 0.1, 0.9)
        XCTAssertGreaterThan(abs(point.transform(red).y - red.y), 0.02); XCTAssertEqual(point.transform(blue), blue)
        let data = try XMPCodec.encode(adjustments: a), restored = try XMPCodec.apply(XMPPacket(data: data), to: Adjustments()).adjustments
        XCTAssertEqual(restored, a)
        var variance = point; variance.hueShift = 0; variance.saturationShift = 0; variance.luminanceShift = 0
        let orange = SIMD3<Double>(0.9, 0.2, 0.1)
        XCTAssertNotEqual(variance.transform(orange), orange)
        let ctx = try context(), image = solid(0.9, 0.1, 0.1), engine = ExtendedRenderer()
        XCTAssertNotEqual(pixel(engine.pointColors(image, settings: [point]), ctx), pixel(image, ctx))
        let malformed = try packet("", "<crs:PointColors><rdf:Seq><rdf:li>0, 1</rdf:li></rdf:Seq></crs:PointColors>")
        XCTAssertThrowsError(try XMPCodec.apply(malformed, to: Adjustments()))
    }
    func testColorGradingCurveRefinementAndDefringeRender() throws {
        let ctx = try context(), gray = solid(0.3, 0.3, 0.3), engine = PixelRenderer()
        var a = PixelAdjustments(); a.splitToning.midtoneHue = 220; a.splitToning.midtoneSaturation = 40; a.splitToning.midtoneLuminance = 20
        let graded = pixel(engine.apply(a, to: gray, scale: 1, local: true), ctx)
        XCTAssertGreaterThan(graded[2], graded[0]); XCTAssertGreaterThan(graded[2], pixel(gray, ctx)[2])
        a = PixelAdjustments(); a.curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.8), .init(x: 1, y: 1)])
        let color = solid(0.5, 0.2, 0.05), full = pixel(engine.apply(a, to: color, scale: 1, local: true), ctx)
        a.curveSaturation = 0
        XCTAssertNotEqual(pixel(engine.apply(a, to: color, scale: 1, local: true), ctx), full)
        let purple = solid(0.8, 0.1, 0.9).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64)).composited(over: solid(1, 1, 1))
        var settings = Defringe(); settings.purpleAmount = 20
        let defringed = ExtendedRenderer.defringe(purple, settings: settings, scale: 1)
        let before = pixel(purple, ctx, x: 31), after = pixel(defringed, ctx, x: 31)
        XCTAssertLessThan(after[2] - after[1], before[2] - before[1] - 0.01, "Metal defringe must neutralize a purple edge")
        XCTAssertEqual(pixel(defringed, ctx, x: 10), pixel(purple, ctx, x: 10), "Flat purple objects must remain unchanged")
    }
    func testDefringeReachesFaintRimOutsideTheEdge() throws {
        let ctx = try context()
        let rim = solid(0.24, 0.06, 0.31)
        let core = solid(0.4, 0.4, 0.4).cropped(to: CGRect(x: 32, y: 0, width: 3, height: 64))
        let image = core.composited(over: rim)
        var settings = Defringe()
        settings.purpleAmount = 20; settings.purpleLow = 0; settings.purpleHigh = 100
        let corrected = ExtendedRenderer.defringe(image, settings: settings, scale: 1)
        let before = pixel(image, ctx, x: 29), after = pixel(corrected, ctx, x: 29)
        XCTAssertLessThan(after[2] - after[1], (before[2] - before[1]) * 0.5)
        XCTAssertEqual(pixel(corrected, ctx, x: 24), pixel(image, ctx, x: 24))
        XCTAssertEqual(pixel(corrected, ctx, x: 33), pixel(image, ctx, x: 33))
    }
    func testDefringeRemovesAsMuchAtPreviewSizeAsAtFullSize() throws {
        let ctx = try context()
        // A star: a white core inside a purple halo 4 px wide, on a dark sky.
        let field = CGRect(x: 0, y: 0, width: 256, height: 256)
        let sky = CIImage(color: CIColor(red: 0.01, green: 0.01, blue: 0.012)).cropped(to: field)
        let halo = CIImage(color: CIColor(red: 0.3, green: 0.05, blue: 0.6)).cropped(to: CGRect(x: 112, y: 112, width: 32, height: 32))
        let star = CIImage(color: .white).cropped(to: CGRect(x: 116, y: 116, width: 24, height: 24)).composited(over: halo).composited(over: sky)
        var settings = Defringe(); settings.purpleAmount = 10; settings.purpleLow = 0; settings.purpleHigh = 100
        func chroma(_ image: CIImage) -> Float {
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var px = [Float](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
            return stride(from: 0, to: px.count, by: 4).reduce(0) { $0 + max(px[$1], px[$1 + 1], px[$1 + 2]) - min(px[$1], px[$1 + 1], px[$1 + 2]) }
        }
        func remaining(_ image: CIImage, scale: Double) -> Float {
            chroma(ExtendedRenderer.defringe(image, settings: settings, scale: scale)) / chroma(image)
        }
        let preview = star.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25), highQualityDownsample: true).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let full = remaining(star, scale: 1), small = remaining(preview, scale: 0.25)
        XCTAssertLessThan(full, 0.25, "The whole halo is corrected, not only its steepest edge")
        XCTAssertEqual(small, full, accuracy: 0.15, "The preview shows what the export will do")
    }
    func testHighlightsAndWhitesMoveBrightTonesBothWays() throws {
        let ctx = try context(), bright = solid(0.5, 0.5, 0.5), dark = solid(0.02, 0.02, 0.02), engine = PixelRenderer()
        func render(_ configure: (inout PixelAdjustments) -> Void, _ image: CIImage) -> Float {
            var p = PixelAdjustments(); configure(&p); return pixel(engine.apply(p, to: image, scale: 1, local: false), ctx)[0]
        }
        let base = render({ _ in }, bright)
        XCTAssertGreaterThan(render({ $0.highlights = 100 }, bright), base + 0.05)
        XCTAssertLessThan(render({ $0.highlights = -100 }, bright), base - 0.05)
        XCTAssertGreaterThan(render({ $0.whites = 100 }, bright), base + 0.05)
        XCTAssertLessThan(render({ $0.whites = -100 }, bright), base - 0.05)
        // Deep shadows stay put.
        XCTAssertEqual(render({ $0.highlights = 100; $0.whites = 100 }, dark), render({ _ in }, dark), accuracy: 0.01)
    }
    func testPostCropVignetteRenders() throws {
        let ctx = try context(), image = solid(0.9, 0.9, 0.9)
        var v = PostCropVignette(); v.amount = -70; v.feather = 70; v.midpoint = 50
        let dark = ExtendedRenderer.vignette(image, settings: v)
        XCTAssertLessThan(pixel(dark, ctx, x: 1, y: 1)[0], 0.4); XCTAssertEqual(pixel(dark, ctx)[0], pixel(image, ctx)[0], accuracy: 0.001)
        v.highlights = 100
        XCTAssertGreaterThan(pixel(ExtendedRenderer.vignette(image, settings: v), ctx, x: 1, y: 1)[0], pixel(dark, ctx, x: 1, y: 1)[0])
        v.amount = 50
        XCTAssertGreaterThan(pixel(ExtendedRenderer.vignette(image, settings: v), ctx, x: 1, y: 1)[0], pixel(image, ctx)[0])
    }
    func testNestedLookAndStructuredDigestDoNotOverwriteGlobalCurve() throws {
        let children = """
        <crs:Look><rdf:Description crs:Name="Embedded look" crs:Amount="0.6"><crs:Parameters><rdf:Description crs:CameraProfile="Adobe Standard" crs:ColorGradeGlobalSat="10">
        <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0,0</rdf:li><rdf:li>128,180</rdf:li><rdf:li>255,255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
        </rdf:Description></crs:Parameters></rdf:Description></crs:Look>
        """
        let p = try packet("crs:Exposure2012=\"1\"", children), imported = try XMPCodec.apply(p, to: Adjustments())
        XCTAssertTrue(imported.adjustments.curve.isIdentity); XCTAssertFalse(try XCTUnwrap(imported.adjustments.look).adjustments.curve.isIdentity)
        XCTAssertEqual(imported.adjustments.look?.amount, 0.6)
        XCTAssertTrue(imported.warnings.joined().contains("default camera color"))
        XCTAssertNotEqual(p.portableDigest, try packet("crs:Exposure2012=\"1\"", children.replacingOccurrences(of: "128,180", with: "128,90")).portableDigest)
    }
    func testGradientMaskAndRetouchConversionAndUnsupportedGroupIsolation() throws {
        let gradient = "<rdf:li crs:What=\"Mask/Gradient\" crs:FullX=\"0.5\" crs:FullY=\"0.2\" crs:ZeroX=\"0.5\" crs:ZeroY=\"0.8\"/>"
        let data = """
        <crs:MaskGroupBasedCorrections><rdf:Seq>
        <rdf:li><rdf:Description crs:CorrectionName="Sky light" crs:CorrectionSyncID="00112233445566778899AABBCCDDEEFF" crs:LocalExposure2012="0.25" crs:LocalShadows2012="0.3">
        <crs:MainCurve><rdf:Seq><rdf:li>0,0</rdf:li><rdf:li>128,160</rdf:li><rdf:li>255,255</rdf:li></rdf:Seq></crs:MainCurve>
        <crs:CorrectionMasks><rdf:Seq>\(gradient)</rdf:Seq></crs:CorrectionMasks></rdf:Description></rdf:li>
        <rdf:li><rdf:Description crs:CorrectionName="Opaque AI" crs:LocalExposure2012="1"><crs:CorrectionMasks><rdf:Seq>\(gradient)<rdf:li crs:What="Mask/Image"/></rdf:Seq></crs:CorrectionMasks></rdf:Description></rdf:li>
        </rdf:Seq></crs:MaskGroupBasedCorrections>
        <crs:RetouchAreas><rdf:Seq><rdf:li><rdf:Description crs:SpotType="heal" crs:SourceX="0.2" crs:OffsetY="0.3"><crs:Masks><rdf:Seq><rdf:li crs:What="Mask/Paint" crs:Radius="0.02" crs:CenterWeight="0.5"><crs:Dabs><rdf:Seq><rdf:li>d 0.4 0.5</rdf:li><rdf:li>d 0.45 0.5</rdf:li></rdf:Seq></crs:Dabs></rdf:li></rdf:Seq></crs:Masks></rdf:Description></rdf:li></rdf:Seq></crs:RetouchAreas>
        """
        let p = try packet("", data), imported = try XMPCodec.apply(p, to: Adjustments()), a = imported.adjustments
        XCTAssertEqual(a.masks.count, 1); XCTAssertEqual(a.masks[0].start.y, 0.8)
        XCTAssertEqual(a.masks[0].adjustments.exposure, 1); XCTAssertEqual(a.masks[0].adjustments.shadows, 30)
        XCTAssertFalse(a.masks[0].adjustments.curve.isIdentity); XCTAssertTrue(imported.warnings.joined().contains("Opaque AI"))
        XCTAssertEqual(a.retouch.count, 1); XCTAssertEqual(a.retouch[0].source, MaskPoint(x: 0.2, y: 0.7)); XCTAssertEqual(a.retouch[0].points.count, 2)
        XCTAssertEqual(try XMPCodec.apply(p, to: a).adjustments.masks.count, 1)
        let ctx = try context(), source = solid(0.2, 0.2, 0.2), rendered = try MaskRenderer(context: ctx).apply(a.masks, to: source)
        XCTAssertGreaterThan(pixel(rendered, ctx, x: 32, y: 60)[0], pixel(rendered, ctx, x: 32, y: 1)[0])
    }
    func testExpandedDevelopmentSaveReopenAndPostCropExport() async throws {
        let ctx = try context(), (directory, source) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try RawRenderer(sourceURL: source)
        var a = renderer.info.defaults
        a.geometry.crop = CropRect(x: 0.35, y: 0.1, width: 0.5, height: 0.75)
        a.postCropVignette.amount = -60; a.postCropVignette.midpoint = 65; a.postCropVignette.feather = 80
        a.splitToning.globalHue = 190; a.splitToning.globalSaturation = 8; a.colorNoiseDetail = 70; a.colorNoiseReduction = 30
        a.curve.insert(x: 0.4, y: 0.55); a.curveSaturation = 40
        var look = ImportedLook(name: "Test look"); look.adjustments.splitToning.midtoneLuminance = 12; a.look = look
        let (reopened, restored) = try await reopenThroughCatalog(renderer, a); XCTAssertEqual(restored, a)
        let preview = try await reopened.preview(restored)
        let output = directory.appendingPathComponent("expanded.tiff")
        var settings = ExportSettings(); settings.select(.tiff); settings.depth = 16; settings.profile = a.colorProfile
        try await reopened.export(to: output, adjustments: restored, settings: settings)
        let actual = try XCTUnwrap(CIImage(contentsOf: output)), expected = CIImage(cgImage: preview.image)
        XCTAssertEqual(actual.extent, expected.extent)
        for point in [(1, 1), (16, 18), (30, 34)] {
            let l = pixel(actual, ctx, x: point.0, y: point.1), r = pixel(expected, ctx, x: point.0, y: point.1)
            XCTAssertLessThan(zip(l, r).map { abs($0 - $1) }.max()!, 0.003)
        }
        // A crop's new center must remain unaffected by the global vignette.
        var noVignette = a; noVignette.postCropVignette.amount = 0
        let clean = try await reopened.preview(noVignette)
        XCTAssertEqual(pixel(expected, ctx, x: 16, y: 18)[2], pixel(CIImage(cgImage: clean.image), ctx, x: 16, y: 18)[2], accuracy: 0.003)
        XCTAssertLessThan(pixel(expected, ctx, x: 1, y: 1)[2], pixel(CIImage(cgImage: clean.image), ctx, x: 1, y: 1)[2])
    }
    func testRealSamplesApplyGradientMasksRetouchAndLook() throws {
        let masks = try XMPCodec.apply(XMPPacket(url: TestSamples.requireSidecar(TestSamples.hdrSidecar)), to: Adjustments())
        XCTAssertEqual(masks.adjustments.masks.count, 2); XCTAssertFalse(masks.adjustments.masks[0].adjustments.curve.isIdentity)
        let retouch = try XMPCodec.apply(XMPPacket(url: TestSamples.requireSidecar(TestSamples.retouchSidecar)), to: Adjustments())
        XCTAssertEqual(retouch.adjustments.retouch.count, 1)
        XCTAssertEqual(retouch.adjustments.retouch[0].source.y, 1 - 0.100911, accuracy: 1e-8)
        // Adobe Color names its tables by digest, so the look stays out and is reported.
        XCTAssertNil(retouch.adjustments.look)
        XCTAssertTrue(retouch.warnings.contains { $0.contains("Adobe Color") }, retouch.warnings.joined(separator: "\n"))
    }
}
