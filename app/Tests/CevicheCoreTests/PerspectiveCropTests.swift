import XCTest
import CoreImage
@testable import CevicheCore

final class PerspectiveCropTests: XCTestCase {
    /// A work leaning in the frame: top left, top right, bottom right, bottom left, y up.
    private let work = [MaskPoint(x: 0.2, y: 0.9), MaskPoint(x: 0.8, y: 0.85), MaskPoint(x: 0.85, y: 0.1), MaskPoint(x: 0.15, y: 0.2)]

    /// The corners are solved in the same order whatever order they are kept in, and four points that make no
    /// convex quadrilateral are refused.
    func testCornerOrderAndValidity() throws {
        let size = CGSize(width: 1000, height: 800)
        let expected = work.map { CGPoint(x: $0.x * 1000, y: $0.y * 800) }
        for shift in 0..<4 {
            let turned = (0..<4).map { work[($0 + shift) % 4] }
            for corners in [turned, turned.reversed()] {
                let solved = try PerspectiveCrop(corners: corners).rectification(source: size).corners
                for (a, b) in zip(solved, expected) { XCTAssertEqual(a.x, b.x, accuracy: 1e-9); XCTAssertEqual(a.y, b.y, accuracy: 1e-9) }
            }
        }
        XCTAssertTrue(PerspectiveCrop(corners: work).isValid)
        XCTAssertTrue(PerspectiveCrop().isValid)
        XCTAssertFalse(PerspectiveCrop(corners: [work[0], work[1], MaskPoint(x: 0.5, y: 0.6), work[3]]).isValid, "a dented corner")
        XCTAssertFalse(PerspectiveCrop(corners: Array(work.prefix(3))).isValid)
        XCTAssertFalse(PerspectiveCrop(corners: [work[0], work[0], work[2], work[3]]).isValid)
        var geometry = GeometryAdjustments(); geometry.perspective = PerspectiveCrop(corners: Array(work.prefix(3)))
        XCTAssertThrowsError(try geometry.validate())
    }

    /// The result is as large as the longest edges, then stretched to the chosen proportions the way the work lies.
    func testOutputSizeFollowsTheProportions() {
        let source = CGSize(width: 1000, height: 1000)
        // 600 × 300 px on the photo, a little narrower at the bottom.
        let wide = [MaskPoint(x: 0.1, y: 0.9), MaskPoint(x: 0.7, y: 0.9), MaskPoint(x: 0.65, y: 0.6), MaskPoint(x: 0.15, y: 0.6)]
        let kept = PerspectiveCrop(corners: wide).outputSize(source: source)
        XCTAssertEqual(kept.width, 600); XCTAssertEqual(kept.height, 304, accuracy: 2)
        let square = PerspectiveCrop(corners: wide, proportion: .square).outputSize(source: source)
        XCTAssertEqual(square.width, 600); XCTAssertEqual(square.height, 600)
        // Lying wide, an A-series sheet is √2 wide to 1 tall; nothing is made smaller to get there.
        let sheet = PerspectiveCrop(corners: wide, proportion: .iso).outputSize(source: source)
        XCTAssertEqual(sheet.width / sheet.height, 2.0.squareRoot(), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(sheet.width, 600); XCTAssertGreaterThanOrEqual(sheet.height, 304)
        let custom = PerspectiveCrop(corners: wide, proportion: .custom(width: 30, height: 20)).outputSize(source: source)
        XCTAssertEqual(custom.width / custom.height, 1.5, accuracy: 0.01)
        // Standing tall, the same sheet is 1 wide to √2 tall.
        let tall = [MaskPoint(x: 0.1, y: 0.9), MaskPoint(x: 0.4, y: 0.9), MaskPoint(x: 0.4, y: 0.3), MaskPoint(x: 0.1, y: 0.3)]
        let upright = PerspectiveCrop(corners: tall, proportion: .iso).outputSize(source: source)
        XCTAssertEqual(upright.height / upright.width, 2.0.squareRoot(), accuracy: 0.01)
    }

    /// In the plan the work is the photo: its corners land on the canvas's corners, the canvas has its proportions,
    /// points map there and back, and Upright stands aside.
    func testThePlanWorksOnTheRectifiedWork() throws {
        let source = CGSize(width: 1000, height: 800)
        var geometry = GeometryAdjustments()
        geometry.perspective = PerspectiveCrop(corners: work, proportion: .square)
        geometry.uprightMode = .guided
        geometry.guides = [UprightGuide(axis: .vertical, start: MaskPoint(x: 0.3, y: 0.1), end: MaskPoint(x: 0.4, y: 0.9))]
        let plan = try GeometryPlan(size: source, settings: geometry, quarterTurns: 0)
        XCTAssertEqual(plan.fullSize.width, plan.fullSize.height)
        XCTAssertEqual(plan.outputSize, plan.fullSize)
        for (corner, expected) in zip(work, [MaskPoint(x: 0, y: 1), MaskPoint(x: 1, y: 1), MaskPoint(x: 1, y: 0), MaskPoint(x: 0, y: 0)]) {
            let shown = plan.displayPoint(corner)
            XCTAssertEqual(shown.x, expected.x, accuracy: 1e-6); XCTAssertEqual(shown.y, expected.y, accuracy: 1e-6)
            let back = plan.sourcePoint(shown)
            XCTAssertEqual(back.x, corner.x, accuracy: 1e-6); XCTAssertEqual(back.y, corner.y, accuracy: 1e-6)
        }
        // Constrain Crop sees a canvas with no empty corners, and a quarter turn turns the work.
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: source, quarterTurns: 0))
        geometry.perspective?.proportion = .twoByThree
        let level = try GeometryPlan(size: source, settings: geometry, quarterTurns: 0), turned = try GeometryPlan(size: source, settings: geometry, quarterTurns: 1)
        XCTAssertEqual(turned.fullSize.width, level.fullSize.height); XCTAssertEqual(turned.fullSize.height, level.fullSize.width)
        // The edit survives a round trip, and an edit without one reads as none.
        XCTAssertEqual(try JSONDecoder().decode(GeometryAdjustments.self, from: JSONEncoder().encode(geometry)), geometry)
        XCTAssertNil(try JSONDecoder().decode(GeometryAdjustments.self, from: Data("{}".utf8)).perspective)
    }

    /// Rendered: a red work on grey, seen at an angle steep enough that the photo's own corners are past its horizon,
    /// fills the result edge to edge with its four quadrants where they belong.
    func testRendersTheWorkEdgeToEdge() throws {
        let width = 400, height = 300
        let quad = [CGPoint(x: 180, y: 260), CGPoint(x: 220, y: 260), CGPoint(x: 390, y: 40), CGPoint(x: 10, y: 40)]
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.addLines(between: quad); context.closePath(); context.fillPath()
        // The top edge's middle, marked blue: it must come out at the top.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 190, y: 252, width: 20, height: 8))
        let image = CIImage(cgImage: try XCTUnwrap(context.makeImage()))
        var geometry = GeometryAdjustments()
        geometry.perspective = PerspectiveCrop(corners: quad.map { MaskPoint(x: $0.x / 400, y: $0.y / 300) })
        let plan = try GeometryPlan(size: image.extent.size, settings: geometry, quarterTurns: 0)
        let output = plan.apply(to: image)
        XCTAssertEqual(output.extent, CGRect(origin: .zero, size: plan.outputSize))
        let w = Int(output.extent.width), h = Int(output.extent.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(output, toBitmap: &pixels, rowBytes: w * 4, bounds: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        // Bitmap rows run top down.
        func pixel(_ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
            let i = (Int(y * Double(h - 1)) * w + Int(x * Double(w - 1))) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        for (x, y) in [(0.04, 0.04), (0.96, 0.04), (0.04, 0.96), (0.96, 0.96), (0.5, 0.5), (0.5, 0.96)] {
            let p = pixel(x, y)
            XCTAssertGreaterThan(p.r, 200, "\(x), \(y)"); XCTAssertLessThan(p.g, 60, "\(x), \(y)"); XCTAssertLessThan(p.b, 60, "\(x), \(y)")
        }
        let mark = pixel(0.5, 0.02)
        XCTAssertGreaterThan(mark.b, 200); XCTAssertLessThan(mark.r, 60)
    }
}
