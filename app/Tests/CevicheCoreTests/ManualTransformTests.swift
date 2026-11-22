import XCTest
import CoreImage
@testable import CevicheCore

final class ManualTransformTests: XCTestCase {
    private let size = CGSize(width: 600, height: 400)
    private func plan(_ transform: ManualTransform, turns: Int = 0) throws -> GeometryPlan {
        var geometry = GeometryAdjustments(); geometry.transform = transform
        return try GeometryPlan(size: size, settings: geometry, quarterTurns: turns)
    }
    func testScaleAndOffsetsKeepTheCanvasFixedAndFollowDisplayedAxes() throws {
        var t = ManualTransform(); t.scale = 50; t.offsetX = 20; t.offsetY = -10
        for turns in 0..<4 {
            let p = try plan(t, turns: turns)
            XCTAssertEqual(p.fullSize, turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width))
            let center = p.displayPoint(.init(x: 0.5, y: 0.5))
            XCTAssertEqual(center.x, 0.5 + 0.2*0.811, accuracy: 1e-10)
            XCTAssertEqual(center.y, 0.5 - 0.1*0.811, accuracy: 1e-10)
            XCTAssertEqual(p.imageCorners.map(\.x).max()! - p.imageCorners.map(\.x).min()!, p.fullSize.width/2, accuracy: 1e-9)
        }
    }
    func testPerspectiveRotationAndAspectHaveIndependentEffects() throws {
        var t = ManualTransform(); t.vertical = 60
        let vertical = try plan(t)
        let a = vertical.displayPoint(.init(x: 0.2, y: 0)), b = vertical.displayPoint(.init(x: 0.2, y: 1))
        XCTAssertLessThan(a.x, b.x, "Positive Vertical widens the bottom")
        t = ManualTransform(); t.horizontal = 60
        let horizontal = try plan(t)
        XCTAssertGreaterThan(horizontal.displayPoint(.init(x: 0, y: 0.2)).y, horizontal.displayPoint(.init(x: 1, y: 0.2)).y)
        t = ManualTransform(); t.rotate = 10
        let rotated = try plan(t)
        XCTAssertLessThan(rotated.displayPoint(.init(x: 1, y: 0.5)).y, 0.5, "Positive Rotate is clockwise")
        t = ManualTransform(); t.aspect = 100
        let aspect = try plan(t)
        XCTAssertLessThan(aspect.displayPoint(.init(x: 1, y: 0.5)).x, 1)
        XCTAssertGreaterThan(aspect.displayPoint(.init(x: 0.5, y: 1)).y, 1)
        t.enabled = false
        XCTAssertEqual(try plan(t).displayPoint(.init(x: 0.2, y: 0.7)), MaskPoint(x: 0.2, y: 0.7))
    }
    func testCombinedTransformPixelsAndMaskCoordinatesAgree() throws {
        var g = GeometryAdjustments()
        g.crop = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        g.straighten = 3; g.flipHorizontal = true
        g.uprightMode = .guided
        g.guides = [UprightGuide(axis: .vertical, start: .init(x: 0.2, y: 0.1), end: .init(x: 0.23, y: 0.9)),
                    UprightGuide(axis: .vertical, start: .init(x: 0.8, y: 0.1), end: .init(x: 0.77, y: 0.9))]
        g.transform.vertical = 20; g.transform.horizontal = -10; g.transform.rotate = 2
        g.transform.aspect = 30; g.transform.scale = 80; g.transform.offsetX = 5; g.transform.offsetY = -3
        let source = MaskPoint(x: 0.45, y: 0.55)
        let image = CIImage(color: .white).cropped(to: CGRect(x: 260, y: 210, width: 20, height: 20))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        let context = CIContext()
        for turn in 0..<4 {
            let p = try GeometryPlan(size: size, settings: g, quarterTurns: turn)
            let displayed = p.displayPoint(source), roundTrip = p.sourcePoint(displayed)
            XCTAssertEqual(roundTrip.x, source.x, accuracy: 1e-10); XCTAssertEqual(roundTrip.y, source.y, accuracy: 1e-10)
            let output = p.apply(to: image)
            XCTAssertEqual(output.extent.size, p.outputSize)
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                context.render(output, toBitmap: $0.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: displayed.x*p.outputSize.width, y: displayed.y*p.outputSize.height, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            }
            XCTAssertGreaterThan(pixel[0], 0.9)
        }
    }
    func testConstrainedCropRemainsInsideBothPhotoAndCanvas() throws {
        for scale in [50.0, 80, 150] {
            for offset in [-40.0, 0, 40] {
                var g = GeometryAdjustments(); g.transform.scale = scale; g.transform.offsetX = offset; g.transform.vertical = 30
                g.crop = g.constrainedCrop(sourceSize: size, quarterTurns: 1)
                try g.validate()
                XCTAssertTrue(g.cropFitsImage(sourceSize: size, quarterTurns: 1), "\(scale), \(offset)")
                XCTAssertLessThanOrEqual(g.crop.x + g.crop.width, 1.000001)
                XCTAssertLessThanOrEqual(g.crop.y + g.crop.height, 1.000001)
            }
        }
    }
    func testPersistenceLegacyDefaultsAndValidation() throws {
        let old = try JSONDecoder().decode(GeometryAdjustments.self, from: Data("{}".utf8))
        XCTAssertTrue(old.transform.isIdentity)
        var g = old; g.transform.vertical = 30; g.transform.scale = 120; g.transform.offsetY = -10
        XCTAssertEqual(try JSONDecoder().decode(GeometryAdjustments.self, from: JSONEncoder().encode(g)), g)
        var a = Adjustments(); a.geometry = g
        let exported = try XMPCodec.encode(adjustments: a)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(data: exported), to: Adjustments()).adjustments.geometry, g)
        XCTAssertEqual(try EditTransfer(sourceName: "test", adjustments: a, items: [.crop, .transform]).applying(to: Adjustments()).geometry, g)
        g.transform.scale = 0; XCTAssertThrowsError(try g.validate())
        g.transform.scale = 100; g.transform.offsetX = .nan; XCTAssertThrowsError(try g.validate())
        g.transform.offsetX = 0; g.transform.rotate = 11; XCTAssertThrowsError(try g.validate())
        g.transform.rotate = 0; g.transform.vertical = 100; g.transform.horizontal = 100
        XCTAssertThrowsError(try GeometryPlan(size: CGSize(width: 400, height: 400), settings: g, quarterTurns: 0), "Reject a horizon crossing instead of passing infinities to Core Image")
    }
}
