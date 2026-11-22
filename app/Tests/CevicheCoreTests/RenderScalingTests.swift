import XCTest
import CoreImage
@testable import CevicheCore

/// Shrinking must not ring: Lanczos-style filters undershoot next to bright points, which draws dark rings around
/// stars and lights that shimmer between timelapse frames.
final class RenderScalingTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])

    /// A dark gray sky (sRGB 0.2) with one 4×4 star at 1.0.
    private func star() -> CIImage {
        let sky = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        return CIImage(color: .white).cropped(to: CGRect(x: 198, y: 198, width: 4, height: 4)).composited(over: sky)
    }
    private func darkest(_ image: CIImage) -> Float {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil) }
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0 + 1] }.min()!
    }

    func testShrinkingAveragesWithoutRinging() {
        let sky = darkest(star())
        for scale in [0.5, 0.28, 0.08] {
            let shrunk = RawRenderer.resized(star(), scaleX: scale, scaleY: scale)
            XCTAssertEqual(shrunk.extent.width, (400 * scale).rounded())
            XCTAssertGreaterThan(darkest(shrunk), sky * 0.98, "scale \(scale)")
            XCTAssertGreaterThan(darkest(RawRenderer.scaled(star(), limit: 400 * scale)), sky * 0.98, "scale \(scale)")
        }
        // The filter that used to shrink exports and video frames, for comparison.
        let lanczos = star().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.28, kCIInputAspectRatioKey: 1])
        XCTAssertLessThan(darkest(lanczos.cropped(to: lanczos.extent.insetBy(dx: 4, dy: 4))), sky * 0.9)
    }

    func testRAWDecoderIsNeverAskedForLessThanHalfSize() {
        XCTAssertEqual(RawRenderer.decodeScale(0.08), 0.5)
        XCTAssertEqual(RawRenderer.decodeScale(0.277), 0.5)
        XCTAssertEqual(RawRenderer.decodeScale(0.7), 0.7)
        XCTAssertEqual(RawRenderer.decodeScale(2), 1)
    }
}
