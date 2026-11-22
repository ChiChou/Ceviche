import XCTest
import CoreGraphics
@testable import CevicheCore

final class ZoneMapTests: XCTestCase {
    private func grey(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let p = (y * width + x) * 4, v = value(x, y); bytes[p] = v; bytes[p + 1] = v; bytes[p + 2] = v } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testMiddleGreyIsZoneFive() {
        // 18 % reflectance is L* 50: sRGB 119.
        XCTAssertEqual(ZoneMap.zone(luminance: 0.18), 5)
        XCTAssertEqual(ZoneMap.zone(luminance: 0), 0)
        XCTAssertEqual(ZoneMap.zone(luminance: 1), 10)
        XCTAssertEqual(ZoneMap.zone(luminance: 4), 10, "HDR above white is zone X")
        XCTAssertEqual(ZoneMap.grey(5) * 255, 119, accuracy: 1)
        for zone in 0..<ZoneMap.count {
            // Each zone's grey measures as that zone.
            let y = pow((ZoneMap.grey(zone) + 0.055) / 1.055, 2.4)
            XCTAssertEqual(ZoneMap.zone(luminance: zone == 0 ? 0 : y), zone)
        }
    }

    func testMapsEachPixelInPlaceAndCountsShares() {
        // Black on the top half, white on the bottom; the left quarter of the bottom middle grey.
        let image = grey(width: 40, height: 20) { x, y in y < 10 ? 0 : x < 10 ? 119 : 255 }
        let map = ZoneMap(image)
        XCTAssertEqual(map.width, 40); XCTAssertEqual(map.height, 20)
        XCTAssertEqual(map.zone(at: CGPoint(x: 0.5, y: 0.2)), 0)
        XCTAssertEqual(map.zone(at: CGPoint(x: 0.1, y: 0.8)), 5)
        XCTAssertEqual(map.zone(at: CGPoint(x: 0.8, y: 0.8)), 10)
        XCTAssertEqual(map.shares[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(map.shares[5], 0.125, accuracy: 0.001)
        XCTAssertEqual(map.shares[10], 0.375, accuracy: 0.001)
        XCTAssertEqual(map.shares.reduce(0, +), 1, accuracy: 0.0001)
    }

    func testIsolatingTintsOneZoneAndDimsTheRest() throws {
        let image = grey(width: 20, height: 1) { x, _ in x < 10 ? 119 : 255 }
        let map = ZoneMap(image)
        let plain = try XCTUnwrap(map.image()), isolated = try XCTUnwrap(map.image(isolating: 5, tint: (1, 0, 0)))
        func pixel(_ image: CGImage, _ x: Int) -> [UInt8] {
            let data = image.dataProvider!.data! as Data
            return Array(data[(x * 4)..<(x * 4 + 3)])
        }
        XCTAssertEqual(pixel(plain, 2), [119, 119, 119])
        XCTAssertEqual(pixel(isolated, 2), [255, 0, 0])
        XCTAssertLessThan(pixel(isolated, 15)[0], 100)
    }
}
