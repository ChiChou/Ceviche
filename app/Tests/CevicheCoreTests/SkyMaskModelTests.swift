import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class SkyMaskModelTests: XCTestCase {
    func testResamplePreservesConstantImageAtBorders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let context = CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAf])
        let constant = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: SkyMaskModel.size, height: SkyMaskModel.size))
        for size in [CGSize(width: 3000, height: 2000), CGSize(width: SkyMaskModel.size, height: SkyMaskModel.size)] {
            let result = SkyMaskModel.resample(constant, to: size)
            XCTAssertEqual(result.extent, CGRect(origin: .zero, size: size))
            let width = Int(size.width), height = Int(size.height)
            for y in [0, 1, height / 2, height - 2, height - 1] {
                var row = [Float](repeating: 0, count: width * 4)
                row.withUnsafeMutableBytes {
                    context.render(result, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: y, width: width, height: 1), format: .RGBAf, colorSpace: nil)
                }
                for x in [0, 1, width / 2, width - 2, width - 1] { XCTAssertEqual(row[x * 4], 1, accuracy: 0.001, "(\(x),\(y)) at \(size)") }
            }
        }
        let large = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        var corner = [Float](repeating: 0, count: 4)
        corner.withUnsafeMutableBytes {
            context.render(SkyMaskModel.resample(large, to: CGSize(width: SkyMaskModel.size, height: SkyMaskModel.size)), toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: SkyMaskModel.size - 1, y: SkyMaskModel.size - 1, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        XCTAssertEqual(corner[0], 1, accuracy: 0.001, "Downsampling keeps the far corner")
    }
    func testBundledModelIsLoadedOnce() throws {
        guard BundledModel.sky.isAvailable else { throw XCTSkip("Run with CEVICHE_MODELS pointing at compiled bundled models") }
        XCTAssertTrue(try SkyMaskModel.loadBundled() === SkyMaskModel.loadBundled())
    }
}
