import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class EyeLevelTests: XCTestCase {
    /// Turning a portrait 5° counterclockwise tilts its eye line up to the right: the correction grows by 5°, the
    /// sign Straighten's Auto and ruler use.
    func testEyeLineFollowsARotation() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        let image = try await renderer.preview(Adjustments(), sdr: true).image
        let levelValue = try await renderer.eyeCorrection(for: image)
        let level = try XCTUnwrap(levelValue, "Eyes are found")
        let source = CIImage(cgImage: image)
        let turned = source.transformed(by: CGAffineTransform(translationX: source.extent.midX, y: source.extent.midY).rotated(by: 5 * .pi / 180).translatedBy(x: -source.extent.midX, y: -source.extent.midY))
        let rotated = try XCTUnwrap(CIContext().createCGImage(turned, from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let tiltedValue = try await renderer.eyeCorrection(for: rotated)
        let tilted = try XCTUnwrap(tiltedValue, "Eyes are found after turning")
        XCTAssertEqual(tilted - level, 5, accuracy: 1.5, "level \(level), tilted \(tilted)")
    }

    /// Straighten set to the correction leaves the eye line level (with a little tilt added first, so there is
    /// something to correct).
    func testStraightenLevelsTheEyes() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = Adjustments(); settings.geometry.straighten = 6
        let tilted = try await renderer.preview(settings, sdr: true).image
        let correctionValue = try await renderer.eyeCorrection(for: tilted)
        let correction = try XCTUnwrap(correctionValue)
        settings.geometry.straighten += correction
        let leveled = try await renderer.preview(settings, sdr: true).image
        let leftValue = try await renderer.eyeCorrection(for: leveled)
        let left = try XCTUnwrap(leftValue)
        XCTAssertEqual(left, 0, accuracy: 1, "straighten \(settings.geometry.straighten), still off \(left)")
    }
}
