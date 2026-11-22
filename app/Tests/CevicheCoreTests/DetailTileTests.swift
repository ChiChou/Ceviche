import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

/// The tile the zoomed editor lays over its preview once the view rests.
final class DetailTileTests: XCTestCase {
    /// A 1200 × 800 PNG whose red rises left to right and green top to bottom, so any shift shows as a color error.
    private func gradient() throws -> URL {
        let width = 1200, height = 800
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let p = pixels + (y * width + x) * 4
            p[0] = UInt8(x * 255 / (width - 1)); p[1] = UInt8(y * 255 / (height - 1)); p[2] = 128; p[3] = 255
        } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &values, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return values
    }

    /// Shown smaller than the source, the tile is rendered scaled down; away from the photo's bottom-left corner it must
    /// still hold its own region, as the full-size tile of that region does.
    func testAReducedTileShowsItsOwnRegion() async throws {
        let url = try gradient(); defer { try? FileManager.default.removeItem(at: url) }
        let renderer = try RawRenderer(sourceURL: url), settings = renderer.info.defaults
        // The top right of the photo; rows top down, as the editor asks.
        let region = CGRect(x: 0.5, y: 0, width: 0.4, height: 0.4)
        let fullJob = try await renderer.prepareDetail(settings, region: region), halfJob = try await renderer.prepareDetail(settings, region: region, photoWidth: 600)
        let full = try XCTUnwrap(fullJob).render(), half = try XCTUnwrap(halfJob).render()
        XCTAssertEqual(full.image.width, 480); XCTAssertEqual(half.image.width, 240); XCTAssertEqual(half.image.height, 160)
        XCTAssertEqual(half.region, full.region)
        let large = pixels(full.image), small = pixels(half.image)
        var worst = 0
        for y in stride(from: 4, to: 156, by: 8) { for x in stride(from: 4, to: 236, by: 8) { for c in 0..<2 {
            let expected = (0..<4).reduce(0) { $0 + Int(large[((2 * y + $1 / 2) * 480 + 2 * x + $1 % 2) * 4 + c]) } / 4
            worst = max(worst, abs(Int(small[(y * 240 + x) * 4 + c]) - expected))
        } } }
        XCTAssertLessThanOrEqual(worst, 3, "The reduced tile holds the same part of the photo")
    }
}
