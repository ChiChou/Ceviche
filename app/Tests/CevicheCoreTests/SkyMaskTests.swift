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
}
