import XCTest
import CevicheTestSupport
import CoreImage
import Metal
@testable import CevicheCore

final class SkyMaskTests: XCTestCase {
    func testBundledSkyModelOnRealRAW() async throws {
        guard BundledModel.sky.isAvailable else { throw XCTSkip("Supply compiled bundled models with CEVICHE_MODELS") }
        try TestTier.requireSlow("Sky model on a full RAW")
        let sample = try TestSamples.require(TestSamples.landscape)
        let renderer = try RawRenderer(sourceURL: sample)
        let available = await renderer.hasSkyMatte; XCTAssertTrue(available)
        let mask = try await renderer.selection(.sky)
        let raster = try XCTUnwrap(mask.raster)
        XCTAssertEqual(mask.refinement, .sky)
        let image = try XCTUnwrap(MaskRaster.image(from: raster))
        // The stored matte is the model's probability map at its own size; refinement happens at render time.
        XCTAssertEqual(image.extent.size, CGSize(width: SkyMaskModel.size, height: SkyMaskModel.size))
        let ctx = CIContext(), e = image.extent
        func value(_ x: Double, _ y: Double) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x * e.width, y: y * e.height, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return pixel[0]
        }
        // The map holds the network's probabilities before refinement; this overcast sky scores about 0.3 and the
        // guided filter brings it to full coverage at render time.
        XCTAssertGreaterThan(value(0.65, 0.93), 0.2, "Open sky at the top should be selected")
        XCTAssertLessThan(value(0.5, 0.2), 0.05, "Foreground vegetation should be excluded")
        var settings = renderer.info.defaults; settings.masks = [mask]
        let overlay = try await renderer.maskOverlay(mask, adjustments: settings)
        XCTAssertGreaterThan(overlay.width, 0)
    }

    /// The matte a RAW carries is stored as the sensor was held. On a photo taken upright the mask must stand upright
    /// too, with the sky at the top: it used to lie on its side.
    func testEmbeddedSkyMatteFollowsThePhotosOrientation() async throws {
        let sample = try TestSamples.require(TestSamples.skyMatte)
        let renderer = try RawRenderer(sourceURL: sample)
        guard await renderer.hasEmbeddedSkyMatte else { throw XCTSkip("The sample carries no sky matte") }
        XCTAssertGreaterThan(renderer.info.height, renderer.info.width, "The sample should be a photo taken upright")
        let mask = try await renderer.selection(.sky)
        let image = try XCTUnwrap(MaskRaster.image(from: try XCTUnwrap(mask.raster)))
        XCTAssertGreaterThan(image.extent.height, image.extent.width, "The mask has the photo's shape")
        let ctx = CIContext(), e = image.extent
        func value(_ x: Double, _ y: Double) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: e.minX + x * e.width, y: e.minY + y * e.height, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return pixel[0]
        }
        XCTAssertGreaterThan(value(0.5, 0.95), 0.8, "Sky at the top is selected")
        XCTAssertLessThan(value(0.5, 0.05), 0.2, "The ground at the bottom is not")
    }

    func testSkyMaskThumbnailShowsTheSelection() async throws {
        let sample = try TestSamples.require(TestSamples.skyMatte)
        let renderer = try RawRenderer(sourceURL: sample)
        guard await renderer.hasEmbeddedSkyMatte else { throw XCTSkip("The sample carries no sky matte") }
        let mask = try await renderer.selection(.sky)
        var settings = await renderer.info.defaults; settings.masks = [mask]
        let made = try await renderer.maskThumbnails([mask], adjustments: settings)
        let thumbnail = try XCTUnwrap(made[mask.id])
        let image = CIImage(cgImage: thumbnail), e = image.extent
        XCTAssertGreaterThan(e.height, e.width, "The thumbnail has the photo's shape")
        func value(_ x: Double, _ y: Double) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: e.minX + x * e.width, y: e.minY + y * e.height, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return pixel[0]
        }
        XCTAssertGreaterThan(value(0.5, 0.95), 0.8, "Sky at the top is white")
        XCTAssertLessThan(value(0.5, 0.05), 0.2, "The ground at the bottom is black")
    }
}
