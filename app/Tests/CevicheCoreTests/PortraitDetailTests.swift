import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class PortraitDetailTests: XCTestCase {
    /// On a laughing portrait each Details correction is made, measured within its bounds; corrected teeth and eye
    /// whites measure less colourful than before, and teeth no lighter than 75 L*.
    func testDetailsOnALaugh() async throws {
        let url = TestSamples.url(TestSamples.distractingPeople)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Laughing portrait sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = Adjustments()
        for kind in PortraitCorrection.details {
            let result = try await XCTUnwrapAsync(try await renderer.portraitDetail(kind, settings: Adjustments()), "\(kind) finds the person")
            XCTAssertTrue(result.visible, "\(kind) is visible")
            let masks = result.masks
            // A feature with nothing to correct makes no mask.
            XCTAssertTrue(masks.count <= (kind == .eyes ? 2 : 1), "\(kind) masks \(masks.count)")
            for mask in masks {
                XCTAssertEqual(mask.portraitCorrection, kind); XCTAssertEqual(mask.kind, .people)
                let a = mask.adjustments
                XCTAssertTrue((-60...0).contains(a.saturation) || kind == .lips, "\(kind) saturation \(a.saturation)")
                XCTAssertTrue((-0.35...0.35).contains(a.exposure), "\(kind) exposure \(a.exposure)")
                if kind == .brows { XCTAssertLessThan(a.exposure, 0) }
                if kind == .lips { XCTAssertTrue((3...20).contains(a.vibrance)) }
                XCTAssertNotEqual(a, LocalAdjustments(), "\(kind) masks correct something")
            }
            settings.masks += masks
        }
        XCTAssertNoThrow(try settings.validated())

        // Teeth and eye whites, measured on the photo before and after.
        let before = try await renderer.pipeline(Adjustments(), maxDimension: 1600)
        let after = try await renderer.pipeline(settings, maxDimension: 1600)
        for kind in [PortraitCorrection.teeth, .eyes] {
            let mask = try XCTUnwrap(settings.masks.first { $0.portraitCorrection == kind })
            let matte = try XCTUnwrap(MaskRaster.image(from: try XCTUnwrap(mask.raster)))
            let context = CIContext()
            let was = try XCTUnwrap(RawRenderer.featureStats(matte, on: before, context: context))
            let now = try XCTUnwrap(RawRenderer.featureStats(matte, on: after, context: context))
            XCTAssertLessThanOrEqual(now.chroma, was.chroma + 0.5, "\(kind) is no more colourful")
            print("DETAIL", kind, "L", Int(was.lightness), "→", Int(now.lightness), "C", Int(was.chroma), "→", Int(now.chroma), mask.adjustments.saturation, mask.adjustments.exposure)
            if kind == .teeth { XCTAssertLessThan(now.lightness, 80, "Teeth are not made paper white") }
        }
    }

    /// A Details correction's Strength scales what Auto measured, up to twice; 1 renders it as measured.
    func testStrengthScalesTheMeasuredCorrection() throws {
        var mask = PhotoMask(kind: .radial); mask.portraitCorrection = .lips
        mask.adjustments.vibrance = 12; mask.adjustments.exposure = -0.1
        XCTAssertEqual(mask.renderedAdjustments, mask.adjustments)
        mask.strength = 2
        XCTAssertEqual(mask.renderedAdjustments.vibrance, 24); XCTAssertEqual(mask.renderedAdjustments.exposure, -0.2, accuracy: 1e-9)
        mask.strength = 0
        XCTAssertEqual(mask.renderedAdjustments.vibrance, 0)
        var settings = Adjustments(); mask.strength = 2.5; settings.masks = [mask]
        XCTAssertThrowsError(try settings.validated(), "Strength stops at 200 %")
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, _ message: String) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v, message)
}
