import XCTest
import CoreGraphics
import CoreImage
@testable import CevicheCore

final class StraightenEstimatorTests: XCTestCase {
    func testFlatImageHasNoCorrectionAndTiltedEdgesLevel() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 600 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertNil(StraightenEstimator.correction(for: try XCTUnwrap(context.makeImage())))
        context.translateBy(x: 300, y: 200); context.rotate(by: 10 * .pi / 180)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1)); context.setLineWidth(3)
        for y in [-100.0, 0, 100] { context.move(to: CGPoint(x: -200, y: y)); context.addLine(to: CGPoint(x: 200, y: y)); context.strokePath() }
        let source = try XCTUnwrap(context.makeImage())
        let angle = try XCTUnwrap(StraightenEstimator.correction(for: source))
        XCTAssertEqual(abs(angle), 10, accuracy: 1.5)
        var settings = GeometryAdjustments(); settings.straighten = angle
        let size = CGSize(width: 600, height: 400)
        settings.crop = settings.constrainedCrop(sourceSize: size, quarterTurns: 0)
        let output = try GeometryPlan(size: size, settings: settings, quarterTurns: 0).apply(to: CIImage(cgImage: source))
        let rendered = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        XCTAssertEqual(try XCTUnwrap(StraightenEstimator.correction(for: rendered)), 0, accuracy: 1.5, "Applying Auto must level the measured edges")
    }
}
