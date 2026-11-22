import XCTest
import CoreImage
import Metal
import simd
import ImageIO
@testable import CevicheCore

final class FilmAdjustmentsTests: XCTestCase {
    func testMissingFieldsDecodeWithDefaultsAndSixBandsAreRejected() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments())) as! [String: Any]
        for key in ["redCurve", "greenCurve", "blueCurve", "parametricCurve", "splitToning", "calibration", "blackWhiteMixer", "grain", "sharpenRadius", "sharpenDetail", "sharpenMasking", "colorNoiseReduction"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.grain.amount, 0)
        XCTAssertTrue(restored.redCurve.isIdentity)
        XCTAssertNil(restored.colorNoiseReduction)
        json["selectiveColors"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(repeating: SelectiveColorAdjustment(), count: 6)))
        XCTAssertThrowsError(try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: json)))
        let local = try JSONDecoder().decode(LocalAdjustments.self, from: Data("{\"exposure\":1}".utf8))
        XCTAssertEqual(local.exposure, 1); XCTAssertEqual(local.noiseReduction, 0)
    }

    func testEightBandsIsolateOrangePurpleAndBlackWhiteMix() {
        var bands = SelectiveColor.defaults
        bands[1].luminance = 50
        let orange = SIMD3(0.8, 0.5, 0.2), purple = SIMD3(0.5, 0.2, 0.8)
        XCTAssertNotEqual(SelectiveColor.transform(orange, adjustments: bands), orange)
        XCTAssertEqual(SelectiveColor.transform(purple, adjustments: bands), purple)
        XCTAssertEqual(SelectiveColor.transform(SIMD3(0.2, 0.2, 0.8), adjustments: bands), SIMD3(0.2, 0.2, 0.8))
        var mixer = BlackWhiteMixer(); mixer.values[1] = 60
        XCTAssertGreaterThan(mixer.transform(orange).x, BlackWhiteMixer().transform(orange).x)
        XCTAssertEqual(mixer.transform(purple), BlackWhiteMixer().transform(purple))
        XCTAssertEqual(mixer.transform(SIMD3(repeating: 0.5)), SIMD3(repeating: 0.5))
        for h in stride(from: 0.0, through: 1.0, by: 0.005) { XCTAssertEqual(FilmMath.hueWeights(h).reduce(0, +), 1, accuracy: 1e-12) }
    }

    func testToningCalibrationAndParametricRegions() throws {
        var tone = SplitToning(); tone.shadowHue = 240; tone.shadowSaturation = 80; tone.highlightHue = 40; tone.highlightSaturation = 80
        let dark = tone.transform(SIMD3(repeating: 0.2)), light = tone.transform(SIMD3(repeating: 0.8))
        XCTAssertGreaterThan(dark.z, dark.x); XCTAssertGreaterThan(light.x, light.z)
        XCTAssertEqual(tone.transform(.zero), .zero)
        let mid = tone.transform(SIMD3(repeating: 0.5)); tone.balance = 80
        XCTAssertGreaterThan(tone.transform(SIMD3(repeating: 0.5)).x, mid.x)
        var calibration = PrimaryCalibration(); calibration.redHue = 50
        XCTAssertEqual(calibration.transform(SIMD3(repeating: 0.4)), SIMD3(repeating: 0.4))
        XCTAssertNotEqual(calibration.transform(SIMD3(0.8, 0.2, 0.2)), SIMD3(0.8, 0.2, 0.2))
        var curve = ParametricCurve(); curve.shadows = 60
        XCTAssertGreaterThan(curve.value(at: 0.1), 0.1)
        XCTAssertEqual(curve.value(at: 0.9), 0.9, accuracy: 1e-12)
        let before = curve.value(at: 0.25); curve.shadowSplit = 35
        XCTAssertNotEqual(curve.value(at: 0.25), before)
        XCTAssertEqual(curve.value(at: 0), 0); XCTAssertEqual(curve.value(at: 1), 1)
        curve.midtoneSplit = 30
        XCTAssertThrowsError(try curve.validate())
    }

    func testRoundTripValidationAndSectionBypasses() throws {
        var a = filmSettings()
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a)), a)
        let saved = a
        a.disabledSections = Set(AdjustmentGroup.allCases)
        var effective = a.effective(defaults: Adjustments()); effective.disabledSections = []
        XCTAssertEqual(effective, Adjustments())
        a.disabledSections = []; XCTAssertEqual(a, saved)
        a.grain.amount = .nan; XCTAssertThrowsError(try a.validated())
        a = saved; a.blackWhiteMixer.values.removeLast(); XCTAssertThrowsError(try a.validated())
        a = saved; a.sharpenRadius = 4; XCTAssertThrowsError(try a.validated())
        a = saved; a.splitToning.shadowHue = 361; XCTAssertThrowsError(try a.validated())
        a = saved; a.colorNoiseReduction = -1; XCTAssertThrowsError(try a.validated())
    }

    func testChannelCurveRunsOnProPhotoAndLeavesItsOtherChannels() throws {
        let context = try context(), renderer = FilmRenderer()
        var settings = Adjustments(); settings.redCurve.insert(x: 0.5, y: 0.75)
        let input = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let baseline = pixels(input, context: context)
        let result = pixels(renderer.curves(input, settings: settings), context: context)
        func proPhoto(_ p: [Float]) -> SIMD3<Double> { FilmMath.encode(FilmMath.toProPhoto * FilmMath.decode(SIMD3(Double(p[0]), Double(p[1]), Double(p[2])))) }
        let before = proPhoto(baseline), after = proPhoto(result)
        XCTAssertEqual(after.x, settings.redCurve.value(at: before.x), accuracy: 0.005)
        XCTAssertEqual(after.y, before.y, accuracy: 0.003)
        XCTAssertEqual(after.z, before.z, accuracy: 0.003)
    }

    func testMasterCurveKeepsHueAndRefineSaturationKeepsChroma() {
        let input = SIMD3(0.3, 0.5, 0.7)
        let curved = FilmMath.huePreserving(input) { $0 * $0 }
        XCTAssertEqual(curved.x, 0.09, accuracy: 1e-12); XCTAssertEqual(curved.z, 0.49, accuracy: 1e-12)
        XCTAssertEqual((curved.y - curved.x) / (curved.z - curved.x), 0.5, accuracy: 1e-12, "The middle channel keeps its place")
        let kept = FilmMath.refineSaturation(input, curved, amount: 0)
        let luma = { (c: SIMD3<Double>) in (c * SIMD3(0.299, 0.587, 0.114)).sum() }
        XCTAssertEqual(luma(kept), luma(curved), accuracy: 1e-12)
        XCTAssertEqual(kept.z - kept.x, input.z - input.x, accuracy: 1e-12)
        XCTAssertEqual(FilmMath.refineSaturation(input, curved, amount: 1), curved)
    }

    func testGrainDeterminismControlsScaleAndAlpha() throws {
        let context = try context(), renderer = FilmRenderer()
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        var grain = FilmGrain(); grain.amount = 70
        let result = pixels(renderer.grain(input, settings: grain, scale: 1), context: context)
        XCTAssertEqual(result, pixels(FilmRenderer().grain(input, settings: grain, scale: 1), context: context))
        XCTAssertLessThan(stride(from: 3, to: result.count, by: 4).map { abs(result[$0] - 0.5) }.max()!, 0.001)
        for key in [\FilmGrain.size, \.roughness] {
            var next = grain; next[keyPath: key] = 80
            XCTAssertNotEqual(result, pixels(renderer.grain(input, settings: next, scale: 1), context: context))
        }
        var nearZero = grain; nearZero.amount = 0.0001
        let nearlyUnchanged = pixels(renderer.grain(input, settings: nearZero, scale: 1), context: context)
        XCTAssertLessThan(zip(nearlyUnchanged, pixels(input, context: context)).map { abs($0 - $1) }.max()!, 0.001)
        grain.seed = 4000
        XCTAssertNotEqual(result, pixels(renderer.grain(input, settings: grain, scale: 1), context: context))
        XCTAssertNotEqual(result, pixels(renderer.grain(input, settings: grain, scale: 0.5), context: context))
        grain.amount = 0
        XCTAssertEqual(pixels(renderer.grain(input, settings: grain, scale: 1), context: context), pixels(input, context: context))
    }

    func testNegativeClarityAndSharpeningControlsAffectTexture() throws {
        let context = try context()
        let input = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 4])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8]).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let normal = pixels(input, context: context)
        let soft = pixels(FilmRenderer.clarity(input, amount: -80), context: context)
        XCTAssertLessThan(variance(soft), variance(normal))
        var a = Adjustments(); a.sharpness = 80; a.sharpenRadius = 2
        let sharp = pixels(FilmRenderer.sharpen(input, settings: a, scale: 1), context: context)
        for key in [\Adjustments.sharpenRadius, \.sharpenDetail, \.sharpenMasking] {
            var next = a; next[keyPath: key] = key == \Adjustments.sharpenRadius ? 0.5 : 90
            XCTAssertNotEqual(pixels(FilmRenderer.sharpen(input, settings: next, scale: 1), context: context), sharp)
        }
    }

    func testTextureScalesFineDetailOnLuminanceAndLeavesFlatAreas() throws {
        let context = try context(), rect = CGRect(x: 0, y: 0, width: 2048, height: 64)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 6, "inputColor0": CIColor(red: 0.5, green: 0.3, blue: 0.15), "inputColor1": CIColor(red: 0.35, green: 0.21, blue: 0.105)])!
        let input = checker.outputImage!.cropped(to: rect).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 0.8]).cropped(to: rect)
        let normal = pixels(input, context: context)
        let crisp = pixels(FilmRenderer.texture(input, amount: 80), context: context)
        let smooth = pixels(FilmRenderer.texture(input, amount: -80), context: context)
        XCTAssertGreaterThan(variance(crisp), variance(normal) * 1.1)
        XCTAssertLessThan(variance(smooth), variance(normal) * 0.9)
        // Luminance only: every channel is scaled alike, so the color's hue and saturation stay.
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let crispLinear = pixels(FilmRenderer.texture(input, amount: 80), context: context, space: linear), normalLinear = pixels(input, context: context, space: linear)
        for index in stride(from: 0, to: crisp.count, by: 4 * 997) {
            XCTAssertEqual(crispLinear[index] / crispLinear[index + 2], normalLinear[index] / normalLinear[index + 2], accuracy: 0.01)
        }
        let flat = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: rect)
        // Within the precision of Core Image's intermediate buffers.
        XCTAssertLessThan(zip(pixels(FilmRenderer.texture(flat, amount: 100), context: context), pixels(flat, context: context)).map { abs($0 - $1) }.max()!, 0.001)
        var settings = PixelAdjustments(); settings.texture = 60
        XCTAssertEqual(pixels(PixelRenderer().apply(settings, to: input, scale: 1, local: false), context: context), pixels(FilmRenderer.texture(input, amount: 60), context: context))
        settings.disabledSections = [.detail]
        XCTAssertEqual(pixels(PixelRenderer().apply(settings, to: input, scale: 1, local: false), context: context), normal)
    }

    func testDehazeRestoresContrastUnderHazeAndKeepsWhite() throws {
        XCTAssertNotNil(CIFilter(name: "CIGuidedFilter"), "the haze map follows edges with the guided filter")
        let context = try context(), rect = CGRect(x: 0, y: 0, width: 1024, height: 64)
        // A scene under haze: its darks lifted toward a pale gray veil.
        let hazy = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 8, "inputColor0": CIColor(red: 0.42, green: 0.45, blue: 0.5), "inputColor1": CIColor(red: 0.62, green: 0.64, blue: 0.68)])!
            .outputImage!.cropped(to: rect)
        let normal = pixels(hazy, context: context)
        let clear = pixels(FilmRenderer.dehaze(hazy, amount: 80), context: context)
        let thicker = pixels(FilmRenderer.dehaze(hazy, amount: -80), context: context)
        XCTAssertGreaterThan(variance(clear), variance(normal) * 1.5)
        XCTAssertLessThan(variance(thicker), variance(normal) * 0.7)
        XCTAssertLessThan(clear.reduce(0, +), normal.reduce(0, +))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        XCTAssertLessThan(zip(pixels(FilmRenderer.dehaze(white, amount: 100), context: context), pixels(white, context: context)).map { abs($0 - $1) }.max()!, 0.001)
        var settings = PixelAdjustments(); settings.dehaze = 80
        XCTAssertNotEqual(pixels(PixelRenderer().apply(settings, to: hazy, scale: 1, local: false), context: context), normal)
        settings.disabledSections = [.detail]
        XCTAssertEqual(pixels(PixelRenderer().apply(settings, to: hazy, scale: 1, local: false), context: context), normal)
    }

    func testFullPipelineSaveReopenAndExportPreserveFilmEdits() async throws {
        let context = try context()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        let input = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 12, "inputColor0": CIColor(red: 0.6, green: 0.3, blue: 0.1), "inputColor1": CIColor(red: 0.2, green: 0.4, blue: 0.7)])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96))
        try context.writePNGRepresentation(of: input, to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let (renderer, defaults) = try RawRenderer.open(source)
        let baseline = try await renderer.preview(defaults)
        var settings = filmSettings(); settings.colorProfile = defaults.colorProfile
        let edited = try await renderer.preview(settings)
        XCTAssertNotEqual(edited.thumbnail, baseline.thumbnail)
        let (reopened, restored) = try await reopenThroughCatalog(renderer, settings)
        XCTAssertEqual(restored, settings)
        let preview = try await reopened.preview(restored)
        XCTAssertEqual(preview.thumbnail, edited.thumbnail)
        var export = ExportSettings(); export.select(.tiff); export.depth = 16; export.profile = settings.colorProfile
        let url = dir.appendingPathComponent("film.tiff")
        try await reopened.export(to: url, adjustments: restored, settings: export)
        let exported = try XCTUnwrap(CIImage(contentsOf: url))
        let expected = pixels(CIImage(cgImage: edited.image), context: context)
        let actual = pixels(exported, context: context)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThan(zip(actual, expected).map { abs($0 - $1) }.max()!, 0.003)
    }

    func testLocalDetailIsConfinedToMaskAndSurvivesSerialization() throws {
        let context = try context()
        let source = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 4])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        var mask = PhotoMask(kind: .linear)
        mask.feather = 0; mask.start = MaskPoint(x: 0.4, y: 0); mask.end = MaskPoint(x: 0.6, y: 0)
        mask.adjustments.clarity = -50; mask.adjustments.sharpness = -60; mask.adjustments.noiseReduction = 40
        let decoded = try JSONDecoder().decode(PhotoMask.self, from: JSONEncoder().encode(mask))
        XCTAssertEqual(decoded, mask)
        let edited = try MaskRenderer(context: context).apply([decoded], to: source)
        let before = pixels(source, context: context), after = pixels(edited, context: context)
        let left = (0..<64).flatMap { y in (0..<40).map { (y * 128 + $0) * 4 } }
        let right = (0..<64).flatMap { y in (90..<128).map { (y * 128 + $0) * 4 } }
        XCTAssertGreaterThan(left.map { abs(before[$0] - after[$0]) }.max()!, 0.05)
        XCTAssertLessThan(right.map { abs(before[$0] - after[$0]) }.max()!, 0.001)
    }

    private func filmSettings() -> Adjustments {
        var a = Adjustments()
        a.redCurve.insert(x: 0.4, y: 0.5); a.blueCurve.insert(x: 0.5, y: 0.4)
        a.parametricCurve.darks = -20; a.parametricCurve.lights = 15
        a.splitToning.shadowHue = 220; a.splitToning.shadowSaturation = 25
        a.calibration.greenHue = 40; a.calibration.redSaturation = 15
        a.grain.amount = 35; a.grain.seed = 4197599114
        a.blackWhiteMixer.values[5] = -20
        a.clarity = -5; a.sharpenRadius = 1.5; a.sharpenDetail = 40; a.sharpenMasking = 20
        a.colorNoiseReduction = 25; a.sharpness = 40
        return a
    }
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    }
    private func pixels(_ image: CIImage, context: CIContext, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> [Float] {
        var values = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(image.extent.width) * 16, bounds: image.extent, format: .RGBAf, colorSpace: space) }
        return values
    }
    private func variance(_ values: [Float]) -> Float {
        let reds = stride(from: 0, to: values.count, by: 4).map { values[$0] }
        let mean = reds.reduce(0, +) / Float(reds.count)
        return reds.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(reds.count)
    }
}
