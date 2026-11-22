import XCTest
import CoreImage
@testable import CevicheCore

final class VolumeTests: XCTestCase {
    private let size = CGSize(width: 6000, height: 4000)
    private func volume(_ mode: VolumeMode, _ amount: Double, focal: Double = 14) -> VolumeCorrection {
        var v = VolumeCorrection(); v.mode = mode; v.amount = amount; v.focalLength = focal; return v
    }

    func testForwardAndInverseAgreeAndMoveInward() throws {
        for mode in VolumeMode.allCases {
            let p = try XCTUnwrap(VolumeProjection(volume(mode, 70), size: size, turned: false))
            for point in [CGPoint(x: 3000, y: 2000), CGPoint(x: 100, y: 2000), CGPoint(x: 5900, y: 150), CGPoint(x: 2500, y: 3990)] {
                let moved = p.forward(point), back = try XCTUnwrap(p.inverse(moved))
                XCTAssertEqual(back.x, point.x, accuracy: 0.01, "\(mode)"); XCTAssertEqual(back.y, point.y, accuracy: 0.01, "\(mode)")
                // Everything moves toward the centre, so the reprojected photo fits the frame.
                XCTAssertLessThanOrEqual(hypot(moved.x - 3000, moved.y - 2000), hypot(point.x - 3000, point.y - 2000) + 1e-6, "\(mode)")
            }
            XCTAssertEqual(p.forward(CGPoint(x: 3000, y: 2000)).x, 3000, accuracy: 1e-9, "The centre stays put")
        }
    }
    func testHorizontalKeepsVerticalsStraightAndFollowsAQuarterTurn() throws {
        let p = try XCTUnwrap(VolumeProjection(volume(.horizontal, 100), size: size, turned: false))
        let xs = stride(from: 0.0, through: 4000, by: 500).map { p.forward(CGPoint(x: 5500, y: $0)).x }
        XCTAssertLessThan(xs.max()! - xs.min()!, 1e-6, "A vertical line stays vertical")
        // Shown a quarter turn round, Horizontal works down the photo as shot.
        let turned = try XCTUnwrap(VolumeProjection(volume(.horizontal, 100), size: size, turned: true))
        let ys = stride(from: 0.0, through: 6000, by: 500).map { turned.forward(CGPoint(x: $0, y: 3800)).y }
        XCTAssertLessThan(ys.max()! - ys.min()!, 1e-6)
    }
    func testNothingHappensWithoutAnAmountOrAFocalLength() {
        XCTAssertNil(VolumeProjection(volume(.spherical, 0), size: size, turned: false))
        var unknown = volume(.spherical, 50); unknown.focalLength = nil
        XCTAssertNil(VolumeProjection(unknown, size: size, turned: false))
        var bad = volume(.spherical, 50); bad.focalLength = 1000
        XCTAssertThrowsError(try bad.validate())
    }
    func testPlanMapsPointsThroughVolumeAndConstrainCropKeepsCornersFilled() throws {
        var geometry = GeometryAdjustments(); geometry.volume = volume(.spherical, 100)
        let plan = try GeometryPlan(size: size, settings: geometry, quarterTurns: 0)
        let point = MaskPoint(x: 0.1, y: 0.15)
        let back = plan.sourcePoint(plan.displayPoint(point))
        XCTAssertEqual(back.x, point.x, accuracy: 1e-6); XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
        XCTAssertGreaterThan(plan.imageOutline.count, 4)
        // The whole frame now shows empty corners; Constrain Crop fits the largest crop of its shape inside.
        XCTAssertFalse(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
        let fitted = geometry.constrainedCrop(sourceSize: size, quarterTurns: 0)
        geometry.crop = fitted
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
        XCTAssertEqual(fitted.width / fitted.height, 1, accuracy: 0.01, "It keeps the frame's proportions (normalized)")
        // As the prototype rendered it at 14 mm: 1689 of 2400 px across (89 % of the scene's width, drawn smaller).
        XCTAssertEqual(fitted.width, 0.70, accuracy: 0.02)
    }
    func testKernelKeepsTheCentreAndEmptiesTheCorners() throws {
        let image = CIImage(color: CIColor(red: 1, green: 0.5, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let p = try XCTUnwrap(VolumeProjection(volume(.spherical, 100), size: CGSize(width: 300, height: 200), turned: false))
        let out = p.apply(to: image)
        XCTAssertEqual(out.extent, image.extent)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func pixel(_ x: Int, _ y: Int) -> [Float] {
            var v = [Float](repeating: 0, count: 4)
            context.render(out, toBitmap: &v, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return v
        }
        XCTAssertEqual(pixel(150, 100)[0], 1, accuracy: 0.01); XCTAssertEqual(pixel(150, 100)[3], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(0, 0)[3], 0, accuracy: 0.01, "A corner moved inward leaves the frame's corner empty")
    }
    func testOlderDocumentsDecodeWithoutVolume() throws {
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: Data(#"{"straighten": 2}"#.utf8))
        XCTAssertEqual(decoded.volume, VolumeCorrection())
        var geometry = GeometryAdjustments(); geometry.volume = volume(.vertical, 40, focal: 16)
        XCTAssertEqual(try JSONDecoder().decode(GeometryAdjustments.self, from: JSONEncoder().encode(geometry)), geometry)
    }
}
