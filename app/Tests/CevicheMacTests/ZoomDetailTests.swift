import XCTest
import SwiftUI
@testable import CevicheMac

final class ZoomDetailTests: XCTestCase {
    /// A picture whose red is its column and green its row, so a pixel says where it came from.
    private func ramp(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            bytes[(y * width + x) * 4] = UInt8(x * 255 / (width - 1)); bytes[(y * width + x) * 4 + 1] = UInt8(y * 255 / (height - 1)); bytes[(y * width + x) * 4 + 2] = 0
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (Int, Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (Int(bytes[(y * image.width + x) * 4]), Int(bytes[(y * image.width + x) * 4 + 1]))
    }

    /// Turning a rectangle to the shown picture and back gives it again, and the corners land where a turned photo's do.
    func testOrientationMapsBothWays() throws {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25)
        for orientation in [Image.Orientation.up, .down, .left, .right] {
            let there = try XCTUnwrap(ZoomDetail.shown(r, orientation)), back = try XCTUnwrap(ZoomDetail.stored(there, orientation))
            for (a, b) in [(back.minX, r.minX), (back.minY, r.minY), (back.width, r.width), (back.height, r.height)] { XCTAssertEqual(a, b, accuracy: 1e-12) }
        }
        // A quarter turn clockwise puts the stored top left at the shown top right.
        let corner = try XCTUnwrap(ZoomDetail.shown(CGRect(x: 0, y: 0, width: 0.1, height: 0.2), .right))
        XCTAssertEqual(corner.maxX, 1, accuracy: 1e-12); XCTAssertEqual(corner.minY, 0, accuracy: 1e-12); XCTAssertEqual(corner.width, 0.2, accuracy: 1e-12)
        XCTAssertNil(ZoomDetail.shown(r, .upMirrored))
    }

    /// The piece covers what is in view and a margin, lies where it says it does, and holds no more pixels than the
    /// screen needs.
    func testPieceCoversTheViewAtTheNeededResolution() throws {
        let image = try ramp(width: 2000, height: 1000)
        let visible = CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.2)
        let full = try XCTUnwrap(ZoomDetail.piece(of: image, orientation: .up, visible: visible, density: 1))
        XCTAssertTrue(full.region.contains(visible)); XCTAssertEqual(full.density, 1)
        XCTAssertEqual(full.region.width, 0.3, accuracy: 0.002, "a quarter of the view on each side")
        XCTAssertEqual(full.image.width, Int((full.region.width * 2000).rounded()))
        // Its top left pixel is the picture's pixel at its region's corner.
        let (red, green) = try pixel(full.image, 0, 0)
        XCTAssertEqual(red, Int(full.region.minX * 2000) * 255 / 1999, accuracy: 1); XCTAssertEqual(green, Int(full.region.minY * 1000) * 255 / 999, accuracy: 1)

        let half = try XCTUnwrap(ZoomDetail.piece(of: image, orientation: .up, visible: visible, density: 0.5))
        XCTAssertEqual(half.density, 0.5); XCTAssertEqual(half.image.width, full.image.width / 2, accuracy: 1)
        // At the edge the margin stops at the picture.
        let edge = try XCTUnwrap(ZoomDetail.piece(of: image, orientation: .up, visible: CGRect(x: 0, y: 0, width: 0.2, height: 0.2), density: 1))
        XCTAssertEqual(edge.region.minX, 0); XCTAssertEqual(edge.region.minY, 0)

        // Turned: the same view of the shown picture comes from the stored picture's matching part.
        let turned = try XCTUnwrap(ZoomDetail.piece(of: image, orientation: .right, visible: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2), density: 1))
        XCTAssertTrue(turned.region.contains(CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)))
        let stored = try XCTUnwrap(ZoomDetail.stored(turned.region, .right))
        XCTAssertEqual(turned.image.width, Int((stored.width * 2000).rounded()), accuracy: 1); XCTAssertEqual(turned.image.height, Int((stored.height * 1000).rounded()), accuracy: 1)
    }

    func testReducedCopyAndLimit() throws {
        let image = try ramp(width: 6000, height: 3000)
        XCTAssertTrue(ZoomDetail.isLarge(image))
        let reduced = try XCTUnwrap(ZoomDetail.reduced(image))
        XCTAssertEqual([reduced.width, reduced.height], [2400, 1200])
        XCTAssertFalse(ZoomDetail.isLarge(reduced))
        // The whole picture in view at full resolution would pass the limit: the piece is thinned to it.
        let whole = try XCTUnwrap(ZoomDetail.piece(of: image, orientation: .up, visible: CGRect(x: 0, y: 0, width: 1, height: 1), density: 1))
        XCTAssertLessThanOrEqual(whole.image.width * whole.image.height, ZoomDetail.limit + 6000)
        XCTAssertLessThan(whole.density, 1)
    }
}
