import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class HDRCurveTests: XCTestCase {
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingFormat: CIFormat.RGBAf])
    private func render(_ value: Float, _ settings: Adjustments) -> Float {
        let pixel = CIImage(bitmapData: [Float](repeating: value, count: 3).withUnsafeBytes { Data($0) } + [Float(1)].withUnsafeBytes { Data($0) },
                            bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let out = HDRCurves.apply(pixel, table: HDRCurves.table(settings), saturation: settings.curveSaturation / 100)
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { context.render(out, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return result[0]
    }
    func testKernelLoadsAndTableIsShaped() {
        var settings = Adjustments(); _ = settings.curve.insert(x: 3, y: 2, upper: 5)
        let pixel = CIImage(bitmapData: [Float](repeating: 4, count: 3).withUnsafeBytes { Data($0) } + [Float(1)].withUnsafeBytes { Data($0) }, bytesPerRow: 16, size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let table = HDRCurves.table(settings)
        let applied = HDRCurves.kernel.apply(extent: pixel.extent, roiCallback: { i, r in i == 0 ? r : table.extent }, arguments: [pixel, table, Float(1024), Float(10), Float(1)])
        XCTAssertNotNil(applied)
        var row = [Float](repeating: 0, count: 4)
        let s = 0.5 + 2.0 / 20   // d = 3
        row.withUnsafeMutableBytes { context.render(table, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: Int(s * 1023), y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        XCTAssertEqual(row[0], 2, accuracy: 0.02, "Row y = 1 is the master curve")
    }
    func testIdentityKeepsHDRValues() {
        for v: Float in [0.05, 0.18, 0.5, 1, 2, 4, 16] { XCTAssertEqual(render(v, Adjustments()), v, accuracy: v * 0.01 + 0.002, "\(v)") }
    }
    func testPointsBeyondWhiteShapeHighlights() throws {
        var settings = Adjustments()
        XCTAssertNotNil(settings.curve.insert(x: 3, y: 2, upper: 5))     // 4.0 (two stops over white) → 2.0
        try settings.curve.validate()
        XCTAssertEqual(render(4, settings), 2, accuracy: 0.05)
        XCTAssertEqual(render(0.18, settings), 0.18, accuracy: 0.01, "SDR tones stay put")
    }
    func testSDRCurvesCarryHDRHighlightsAlong() {
        var settings = Adjustments()
        settings.curve.move(at: settings.curve.whiteIndex, x: 1, y: 0.9)  // lower SDR white
        // 4.0 sits at 3 on the curve; past the last point the curve keeps slope 1 → 2.9 → 2^1.9.
        XCTAssertEqual(render(4, settings), pow(2, 1.9), accuracy: 0.05)
        XCTAssertLessThan(settings.curve.value(at: 0.5), 0.5)
    }
    func testAnchorsAndLimits() {
        var curve = ToneCurve()
        XCTAssertNil(curve.insert(x: 1.5, y: 1.5), "Beyond white needs the HDR range")
        XCTAssertNotNil(curve.insert(x: 1.5, y: 1.5, upper: 3))
        curve.remove(at: curve.whiteIndex)
        XCTAssertEqual(curve.points.count, 3, "SDR white cannot be removed")
        curve.move(at: 2, x: 0.5, y: 9, upper: 3)
        XCTAssertGreaterThan(curve.points[2].x, 1, "A highlight point stays beyond white")
        XCTAssertEqual(curve.sdrPoints.count, 2)
    }
}
