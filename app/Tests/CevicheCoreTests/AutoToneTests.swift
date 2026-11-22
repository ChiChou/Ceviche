import XCTest
import CoreImage
@testable import CevicheCore

final class AutoToneTests: XCTestCase {
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device)
    }
    /// An underexposed picture: a vertical ramp from 0.2 % to 25 % linear gray, weighted toward the dark end like a photo.
    private func fixture(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("flat.png")
        let width = 256, height = 160
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8, space: RGBProfile.sRGB.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<height {
            let linear = 0.002 + 0.248 * pow(Double(row) / Double(height - 1), 2.2)
            let value = FilmMath.encode(linear)
            ctx.setFillColor(CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
            ctx.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func testAutoSetsEveryLightSliderAndBringsTheTonesToTheirTargets() async throws {
        _ = try context()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try RawRenderer(sourceURL: try fixture(directory))
        var start = renderer.info.defaults; start.saturation = 12; start.disabledSections.insert(.light)
        let startLevels = try await renderer.toneLevels(start)
        let before = try XCTUnwrap(startLevels)
        let auto = try await renderer.autoAdjust(start)
        // The light sliders take part in the directions this picture needs, and the result is a normal, enabled edit.
        XCTAssertGreaterThan(auto.exposure, 0.3); XCTAssertGreaterThan(auto.whites, 5); XCTAssertGreaterThan(auto.shadows, 0)
        XCTAssertFalse(auto.disabledSections.contains(.light)); XCTAssertEqual(auto.saturation, 12)
        XCTAssertEqual(auto.exposure, (auto.exposure * 100).rounded() / 100); XCTAssertEqual(auto.whites, auto.whites.rounded())
        // Conservative: no slider goes to an extreme, however far the picture is from balanced.
        XCTAssertLessThanOrEqual(abs(auto.exposure), 1.5); XCTAssertTrue((0...25).contains(auto.contrast))
        XCTAssertTrue((-75...25).contains(auto.highlights)); XCTAssertTrue((-25...60).contains(auto.shadows))
        XCTAssertTrue((-40...50).contains(auto.whites)); XCTAssertTrue((-40...30).contains(auto.blacks))
        // The tones move toward a balanced photo's levels without reaching them: the white point rises but stays short
        // of white, the median rises toward middle gray, and the midtones spread.
        let autoLevels = try await renderer.toneLevels(auto)
        let after = try XCTUnwrap(autoLevels)
        XCTAssertGreaterThan(after.white, before.white + 0.1); XCTAssertLessThan(after.white, 0.97)
        XCTAssertGreaterThan(after.median, before.median + 0.05); XCTAssertLessThan(after.median, 0.5)
        XCTAssertGreaterThan(after.spread, before.spread)
        // Deterministic.
        let again = try await renderer.autoAdjust(start)
        XCTAssertEqual(again, auto)
    }
}
