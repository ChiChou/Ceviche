import XCTest
import CoreImage
@testable import CevicheCore

final class MaskRasterTests: XCTestCase {
    /// A sky-like matte: solid at the top, a soft noisy horizon band, empty below.
    private func matte(width: Int = 600, height: Int = 400) -> [UInt16] {
        var values = [UInt16](repeating: 0, count: width * height)
        var seed: UInt64 = 42
        for y in 0..<height { for x in 0..<width {
            let horizon = 150.0 + 20 * sin(Double(x) / 40)
            let t = min(1, max(0, (horizon - Double(y)) / 30))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = t > 0 && t < 1 ? Double(seed >> 54) / 1023 * 0.01 : 0
            values[y * width + x] = UInt16(min(1, t + noise) * 65535)
        } }
        return values
    }
    func testRoundTripStaysWithinTwelveBitPrecision() throws {
        let values = matte()
        let data = try MaskRaster.encode(values, width: 600, height: 400)
        XCTAssertTrue(MaskRaster.isCompact(data))
        let decoded = try MaskRaster.decode(data)
        XCTAssertEqual(decoded.width, 600); XCTAssertEqual(decoded.height, 400)
        let worst = zip(values, decoded.values).map { abs(Int($0) - Int($1)) }.max()!
        XCTAssertLessThanOrEqual(worst, 129, "Snapping near black/white (1/512) bounds the error")
        let png = try XCTUnwrap(CIContext().pngRepresentation(of: CIImage(cgImage: grayImage(values, 600, 400)), format: .L16, colorSpace: CGColorSpaceCreateDeviceGray()))
        XCTAssertLessThan(data.count, png.count, "compact \(data.count) vs png \(png.count)")
    }
    func testSolidMasksCostOneByteAPerTile() throws {
        let data = try MaskRaster.encode([UInt16](repeating: 65535, count: 3000 * 2000), width: 3000, height: 2000)
        XCTAssertLessThan(data.count, 200)
    }
    func testImageKeepsOrientation() throws {
        let values = matte()
        let compact = try XCTUnwrap(MaskRaster.image(from: try MaskRaster.encode(values, width: 600, height: 400)))
        func top(_ image: CIImage) -> Float {
            var v: Float = 0
            CIContext().render(image, toBitmap: &v, rowBytes: 4, bounds: CGRect(x: 300, y: 399, width: 1, height: 1), format: .Rf, colorSpace: nil)
            return v
        }
        XCTAssertEqual(top(compact), 1, accuracy: 0.002, "The first stored row is the top of the image")
    }
    private func grayImage(_ values: [UInt16], _ width: Int, _ height: Int) -> CGImage {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Little.rawValue), provider: CGDataProvider(data: data as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
