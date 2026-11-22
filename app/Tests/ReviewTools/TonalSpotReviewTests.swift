import XCTest
import ImageIO
@testable import CevicheCore

final class TonalSpotReviewTests: XCTestCase {
    func testSpotOnRAW() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["CEVICHE_SPOT_RAW"], let output = env["CEVICHE_SPOT_REVIEW"],
              let x = Double(env["CEVICHE_SPOT_X"] ?? ""), let y = Double(env["CEVICHE_SPOT_Y"] ?? ""),
              let radius = Double(env["CEVICHE_SPOT_RADIUS"] ?? "") else { throw XCTSkip("Supply a RAW, spot geometry and local review folder") }
        let url = URL(fileURLWithPath: source), folder = URL(fileURLWithPath: output)
        let renderer = try RawRenderer(sourceURL: url)
        let spot = DustSpot(center: MaskPoint(x: x, y: 1-y), radius: radius)
        var edits = renderer.info.defaults
        let strokes = try await renderer.dustStrokes([spot], settings: edits, tonal: true)
        let stroke = try XCTUnwrap(strokes.first)
        print("Spot exposure \(url.lastPathComponent) \(stroke.exposure) EV")
        for state in ["before", "after"] {
            if state == "after" { edits.retouch = strokes }
            let image = try await renderer.displayImage(edits, maxDimension: 4000, sdr: true)
            print("Review image size \(image.width) × \(image.height)")
            if state == "before" {
                let full = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-frame.jpg")
                let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(full as CFURL, "public.jpeg" as CFString, 1, nil))
                CGImageDestinationAddImage(writer, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(writer))
            }
            let side = max(100, Int(10 * radius * Double(min(image.width, image.height))))
            let rect = CGRect(x: Int(x * Double(image.width)) - side/2, y: Int(y * Double(image.height)) - side/2, width: side, height: side)
            let crop = try XCTUnwrap(image.cropping(to: rect))
            let target = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-" + state + ".png")
            let file = try XCTUnwrap(CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(file, crop, nil)
            XCTAssertTrue(CGImageDestinationFinalize(file))
        }
    }
}
