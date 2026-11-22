import XCTest
import CevicheTestSupport
import CoreImage
import simd
@testable import CevicheCore

/// Match Series on real series: the chart shots and a portrait series (`TestSamples`).
final class SeriesMatcherTests: XCTestCase {
    private func asShot(_ url: URL) throws -> SeriesMatchValues {
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        return SeriesMatchValues(exposure: 0, temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
    }

    func testNewtonSolvesInTheAppsUnits() {
        // A made-up decoder: the residual is linear in stops, mired and tint.
        let goal = SeriesMatchValues(exposure: 0.8, temperature: 5200, tint: 12)
        let solved = SeriesMatcher.newton(start: SeriesMatchValues(exposure: 0, temperature: 6500, tint: 0)) { v in
            SIMD3((v.exposure - goal.exposure) * log(2), (v.mired - goal.mired) * 0.004, (v.tint - goal.tint) * 0.003)
        }
        XCTAssertEqual(solved.exposure, 0.8, accuracy: 0.011)
        XCTAssertEqual(solved.temperature, 5200, accuracy: 15)
        XCTAssertEqual(solved.tint, 12, accuracy: 0.6)
    }

    func testHomographyFit() throws {
        let rows: [SIMD3<Double>] = [SIMD3(1.1, 0.05, 12), SIMD3(-0.03, 0.95, -7), SIMD3(1e-5, -2e-5, 1)]
        let truth = SeriesMatcher.Homography(m: simd_double3x3(rows: rows))
        var points: [SIMD2<Double>] = []
        for k in 0..<12 { points.append(SIMD2<Double>(Double(k % 4) * 211 + 17, Double(k / 4) * 173 + 31)) }
        let fitted = try XCTUnwrap(SeriesMatcher.Homography.fit(points, points.map(truth.map)))
        for p in [SIMD2<Double>(50, 60), SIMD2<Double>(700, 400)] { XCTAssertLessThan(simd_distance(fitted.map(p), truth.map(p)), 1e-6) }
    }

    /// The same scene a stop apart: matched on the scene, to the exposure the chart itself asks for (the daylight
    /// changed between the shots, so the recorded difference is off).
    func testOverlapMatchesBracketedScene() throws {
        try TestTier.requireSlow()
        let reference = try TestSamples.require(TestSamples.chart.daylight)
        let matcher = try SeriesMatcher(reference: reference, values: try asShot(reference))
        let dark = try TestSamples.require(TestSamples.chart.daylightUnder)
        let result = try matcher.match(dark, current: try asShot(dark))
        XCTAssertEqual(result.method, .overlap)
        XCTAssertEqual(result.values.exposure, 0.91, accuracy: 0.12)
        // Another scene under another light shares only the chart: overlap is refused, and the light is too far off for the recorded values.
        let tungsten = try TestSamples.require(TestSamples.chart.tungsten)
        let other = try matcher.match(tungsten, current: try asShot(tungsten))
        XCTAssertEqual(other.method, .unmatched)
        XCTAssertEqual(other.values, try asShot(tungsten))
        let bright = try TestSamples.require(TestSamples.chart.daylightOver)
        XCTAssertEqual(try matcher.match(bright, current: try asShot(bright), prefer: .exif).values.temperature, try asShot(reference).temperature, accuracy: 1)
        // Asked for the recorded values, the scene isn't consulted.
        XCTAssertEqual(try matcher.match(dark, current: try asShot(dark), prefer: .exif).method, .exif)
    }

    /// A portrait series with a face in both: skin is matched when asked, and not otherwise.
    func testSkinWhenAsked() throws {
        try TestTier.requireSlow()
        let reference = try TestSamples.require(TestSamples.faceSeries.reference), target = try TestSamples.require(TestSamples.faceSeries.target)
        let matcher = try SeriesMatcher(reference: reference, values: try asShot(reference))
        XCTAssertTrue(matcher.referenceHasFace)
        let skin = try matcher.match(target, current: try asShot(target), prefer: .skin)
        XCTAssertEqual(skin.method, .skin)
        XCTAssertEqual(skin.values.exposure, -0.09, accuracy: 0.25)
        XCTAssertNotEqual(try matcher.match(target, current: try asShot(target)).method, .skin)
    }
}
