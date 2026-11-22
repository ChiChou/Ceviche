import XCTest
@testable import CevicheCore

/// A preset at part of its strength: `Adjustments.blended(toward:amount:)`.
final class PresetStrengthTests: XCTestCase {
    private func lut(_ name: String) throws -> CreativeLUT {
        let cube = "LUT_3D_SIZE 2\n" + (0..<8).map { i in "\(i & 1) \((i >> 1) & 1) \(i >> 2)" }.joined(separator: "\n")
        return try CreativeLUT(cube: Data(cube.utf8), name: name)
    }

    func testSettingsMoveInProportionAndSwitchesAtHalf() throws {
        var before = Adjustments(); before.contrast = 10; before.temperature = 5000
        var full = before; full.exposure = 1; full.contrast = 30; full.temperature = 6000; full.monochrome = true
        full.splitToning.highlightSaturation = 40; full.grain.amount = 20
        let half = try before.blended(toward: full, amount: 0.5)
        XCTAssertEqual(half.exposure, 0.5, accuracy: 1e-9); XCTAssertEqual(half.contrast, 20, accuracy: 1e-9)
        XCTAssertEqual(half.temperature, 5500, accuracy: 1e-9); XCTAssertEqual(half.splitToning.highlightSaturation, 20, accuracy: 1e-9)
        XCTAssertEqual(half.grain.amount, 10, accuracy: 1e-9); XCTAssertTrue(half.monochrome)
        XCTAssertFalse(try before.blended(toward: full, amount: 0.25).monochrome)
        XCTAssertEqual(try before.blended(toward: full, amount: 0), before)
        XCTAssertEqual(try before.blended(toward: full, amount: 1), full)
    }

    func testCurvesMixThroughTheirShape() throws {
        let before = Adjustments()
        var full = before; full.curve = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.3, y: 0.2), CurvePoint(x: 0.7, y: 0.85), CurvePoint(x: 1, y: 1)])
        let half = try before.blended(toward: full, amount: 0.5)
        for x in [0.0, 0.3, 0.7, 1] { XCTAssertEqual(half.curve.value(at: x), (x + full.curve.value(at: x)) / 2, accuracy: 1e-9) }
        // Between the points the mixed curve stays close to halfway between the two.
        XCTAssertEqual(half.curve.value(at: 0.5), (0.5 + full.curve.value(at: 0.5)) / 2, accuracy: 0.02)
    }

    func testAddedLooksComeInByTheirAmountAndTheRestStays() throws {
        var before = Adjustments(); before.retouch = [RetouchStroke(mode: .heal, source: MaskPoint(x: 0.2, y: 0.2), target: MaskPoint(x: 0.5, y: 0.5), radius: 0.02, softness: 0.5, opacity: 1)]
        before.geometry.straighten = 2
        var full = before; full.lut = try lut("Teal"); full.exposure = 1
        full.geometry.straighten = 0; full.retouch = []
        let blended = try before.blended(toward: full, amount: 0.3)
        XCTAssertEqual(try XCTUnwrap(blended.lut).amount, 0.3, accuracy: 1e-9); XCTAssertEqual(blended.lut?.name, "Teal")
        XCTAssertEqual(blended.geometry, before.geometry, "Presets never carry geometry"); XCTAssertEqual(blended.retouch, before.retouch)
        // The same LUT changes its amount in proportion; another one replaces it at half.
        var tinted = before; tinted.lut = try lut("Teal"); tinted.lut?.amount = 0.2
        XCTAssertEqual(try tinted.blended(toward: full, amount: 0.5).lut?.amount ?? 0, 0.6, accuracy: 1e-9)
        var other = before; other.lut = try lut("Warm")
        XCTAssertEqual(try other.blended(toward: full, amount: 0.4).lut?.name, "Warm")
        XCTAssertEqual(try other.blended(toward: full, amount: 0.6).lut?.name, "Teal")
    }
}
