import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class ExposureRampTests: XCTestCase {
    /// 50 day frames, a `fall` in EV over 100 frames, 50 night frames, with up to ±0.25 EV of flicker.
    private func sunset(fall: Double = 8) -> [Double] {
        (0..<200).map { index in
            let trend = index < 50 ? 0 : index < 150 ? -fall * Double(index - 50) / 100 : -fall
            // Deterministic flicker.
            return trend + 0.25 * sin(Double(index) * 2.3) * cos(Double(index) * 0.7)
        }
    }

    func testFindsTheSunsetAsOneTransition() {
        let ramp = ExposureRamp(measured: sunset(), current: Array(repeating: 0, count: 200))
        XCTAssertEqual(ramp.transitions.count, 1)
        let transition = try! XCTUnwrap(ramp.transitions.first)
        XCTAssertEqual(transition.start, 50, accuracy: 12)
        XCTAssertEqual(transition.end, 150, accuracy: 12)
        XCTAssertEqual(transition.change, -8, accuracy: 0.6)
    }

    func testKeepsPartOfTheChangeAndRemovesFlicker() {
        // Holding three quarters of 6 EV back needs up to 4.5 EV more, inside the slider's range.
        let measured = sunset(fall: 6)
        let ramp = ExposureRamp(measured: measured, current: Array(repeating: 0.2, count: 200))
        var options = ExposureRamp.Options(); options.keep = 0.25
        let (exposures, clamped) = ramp.exposures(reference: 20, options: options)
        XCTAssertEqual(clamped, 0)
        XCTAssertEqual(exposures[20], 0.2, "the reference frame keeps its Exposure")
        let result = ramp.result(exposures)
        // A quarter of the fall remains.
        XCTAssertEqual(result[10] - result[190], 1.5, accuracy: 0.3)
        // Neighbouring frames now differ by little more than the slope of the remaining ramp.
        let jumps = zip(result, result.dropFirst()).map { abs($1 - $0) }
        XCTAssertLessThan(jumps.max()!, 0.08)
        let rawJumps = zip(measured, measured.dropFirst()).map { abs($1 - $0) }
        XCTAssertGreaterThan(rawJumps.max()!, 0.3)
    }

    func testWithoutDeflickerOnlyTheTrendChanges() {
        let measured = sunset()
        let ramp = ExposureRamp(measured: measured, current: Array(repeating: 0, count: 200))
        var options = ExposureRamp.Options(); options.keep = 0.5; options.deflicker = false
        let result = ramp.result(ramp.exposures(reference: 0, options: options).values)
        // Each frame keeps its own flicker around the halved trend.
        for index in [60, 100, 140] {
            XCTAssertEqual(result[index] - result[index - 1], (measured[index] - measured[index - 1]) - 0.5 * (ramp.smoothed[index] - ramp.smoothed[index - 1]), accuracy: 0.02)
        }
    }

    func testLevelSeriesHasNoTransitionAndExposureStaysInRange() {
        let level = (0..<120).map { 0.1 * sin(Double($0)) }
        XCTAssertTrue(ExposureRamp(measured: level, current: Array(repeating: 0, count: 120)).transitions.isEmpty)
        // A 14 EV fall held level needs more than the slider's range.
        let deep = (0..<100).map { -14 * Double($0) / 99 }
        let ramp = ExposureRamp(measured: deep, current: Array(repeating: 0, count: 100))
        var options = ExposureRamp.Options(); options.keep = 0
        let (exposures, clamped) = ramp.exposures(reference: 0, options: options)
        XCTAssertGreaterThan(clamped, 0)
        XCTAssertTrue(exposures.allSatisfy { ExposureRamp.exposureRange.contains($0) })
    }

    /// The light is measured before Exposure, so the slider doesn't move it.
    func testMeasuredLightIgnoresExposure() async throws {
        let (renderer, defaults) = try RawRenderer.open(try TestSamples.require(TestSamples.landscape))
        var brighter = defaults; brighter.exposure = 2
        let base = try await renderer.sceneBrightness(defaults), again = try await renderer.sceneBrightness(brighter)
        XCTAssertEqual(base, again, accuracy: 0.001)
    }

    /// Keyframes pin the target at their frames, ease between them without overshoot, and hold beyond them.
    func testKeyframeOffsets() {
        XCTAssertEqual(ExposureRamp.offsets([:], count: 4), [0, 0, 0, 0])
        let offsets = ExposureRamp.offsets([2: 1, 6: -1], count: 9)
        XCTAssertEqual(offsets[0], 1); XCTAssertEqual(offsets[2], 1); XCTAssertEqual(offsets[6], -1); XCTAssertEqual(offsets[8], -1)
        XCTAssertEqual(offsets[4], 0, accuracy: 1e-12)
        for k in 2..<6 { XCTAssertGreaterThanOrEqual(offsets[k], offsets[k + 1]) }
        XCTAssertTrue(offsets.allSatisfy { (-1...1).contains($0) })

        let ramp = ExposureRamp(measured: [-3, -3.1, -2.9, -3, -3.05], current: [0, 0, 0, 0, 0], smoothing: 3)
        let plain = ramp.exposures(reference: 0, options: .init()).values
        let lifted = ramp.exposures(reference: 0, options: .init(), keyframes: [3: 0.5]).values
        // One keyframe lifts the whole series by its offset, the reference too.
        for k in plain.indices { XCTAssertEqual(lifted[k], plain[k] + 0.5, accuracy: 0.011) }
        XCTAssertEqual(ramp.exposures(reference: 0, options: .init(), keyframes: [3: 9]).clamped, 5)
    }
}
