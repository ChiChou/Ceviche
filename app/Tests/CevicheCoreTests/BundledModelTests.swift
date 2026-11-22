import XCTest
import CevicheTestSupport
import CoreImage
@testable import CevicheCore

/// Runs when the compiled models are available (CEVICHE_MODELS=…/models/build/compiled); skipped otherwise.
final class BundledModelTests: XCTestCase {
    private func renderer() throws -> RawRenderer {
        try TestTier.requireSlow("Core ML on a full RAW")
        let landscape = try TestSamples.require(TestSamples.burst.second)
        return try RawRenderer(sourceURL: landscape)
    }
    /// Mean coverage of the top and bottom fifths of a mask.
    private func bands(_ mask: PhotoMask) throws -> (top: Double, bottom: Double) {
        let image = try XCTUnwrap(mask.raster.flatMap(MaskRaster.image(from:)))
        let small = image.transformed(by: CGAffineTransform(scaleX: 100 / image.extent.width, y: 100 / image.extent.height))
        var values = [Float](repeating: 0, count: 100 * 100)
        values.withUnsafeMutableBytes { CIContext().render(small, toBitmap: $0.baseAddress!, rowBytes: 400, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), format: .Rf, colorSpace: nil) }
        // The bitmap's first row is the top of the image.
        func mean(_ rows: Range<Int>) -> Double { rows.flatMap { r in (0..<100).map { Double(min(1, values[r * 100 + $0])) } }.reduce(0, +) / Double(rows.count * 100) }
        return (mean(0..<20), mean(80..<100))
    }
    func testDepthMaskSelectsTheForegroundByDefault() async throws {
        guard BundledModel.depth.isAvailable else { throw XCTSkip("Depth model not installed") }
        let mask = try await renderer().selection(.depth)
        XCTAssertEqual(mask.selection.depthRange, [0.5, 1]); XCTAssertEqual(mask.refinement, .edgeAware)
        XCTAssertLessThan(mask.raster!.count, 300_000, "Only the model's 518 × 392 output is stored")
        let depth = try bands(mask)
        XCTAssertGreaterThan(depth.bottom, depth.top + 0.3, "The road in front should be nearer than the mountains")
    }
    func testSceneMaskFindsSkyAtTheTop() async throws {
        guard BundledModel.scene.isAvailable else { throw XCTSkip("Scene model not installed") }
        let mask = try await renderer().selection(.scene, scene: .sky)
        XCTAssertEqual(mask.selection.scene, .sky); XCTAssertEqual(mask.name, "Sky"); XCTAssertEqual(mask.refinement, .edgeAware)
        XCTAssertLessThan(mask.raster!.count, 50_000)
        let sky = try bands(mask)
        XCTAssertGreaterThan(sky.top, 0.3); XCTAssertLessThan(sky.bottom, 0.05)
    }
    func testDepthBandKeepsOnlyTheChosenRange() {
        let ramp = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { CIContext().render(MaskRenderer.depthBand(ramp, range: [0.5, 1], softness: 0.1), toBitmap: $0.baseAddress!, rowBytes: 16, bounds: ramp.extent, format: .RGBAf, colorSpace: nil) }
        XCTAssertEqual(pixel[0], 0, accuracy: 0.02, "Depth 0.2 lies outside [0.5, 1]")
    }
}
