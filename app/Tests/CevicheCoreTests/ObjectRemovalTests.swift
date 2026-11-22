import XCTest
import CoreImage
@testable import CevicheCore

/// Remove › Object's wire tracer on a drawn street: a sagging cable across a sky, meeting a roof.
final class ObjectRemovalTests: XCTestCase {
    private let W = 1200, H = 800
    /// The cable's height at x, rows from the top.
    private func cable(_ x: Double) -> Double { 200 + 0.00015 * (x - 600) * (x - 600) }

    private func street() -> CIImage {
        let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0.55, green: 0.65, blue: 0.85, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // A wall with a patterned facade in the lower half (CG counts rows from the bottom).
        c.setFillColor(CGColor(red: 0.8, green: 0.7, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: 380))
        c.setFillColor(CGColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 1))
        for i in 0..<400 { c.fill(CGRect(x: (i * 97) % W, y: (i * 53) % 360, width: 3 + i % 5, height: 2 + i % 7)) }
        // The cable: 2 pixels wide, from edge to edge.
        c.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)); c.setLineWidth(2)
        c.move(to: CGPoint(x: 0, y: Double(H) - cable(0)))
        for x in stride(from: 10.0, through: Double(W), by: 10) { c.addLine(to: CGPoint(x: x, y: Double(H) - cable(x))) }
        c.strokePath()
        return CIImage(cgImage: c.makeImage()!)
    }

    func testAClickNearTheCableFollowsItEdgeToEdge() throws {
        let lines = ObjectRemoval.lines(street(), context: CIContext())
        // Three pixels off the cable.
        let point = MaskPoint(x: 300.0 / Double(W), y: 1 - (cable(300) + 3) / Double(H))
        let wire = try XCTUnwrap(ObjectRemoval.traceLine(lines, width: W, height: H, from: point))
        let xs = wire.points.map { $0.x * Double(W) }
        XCTAssertLessThan(xs.min()!, 20); XCTAssertGreaterThan(xs.max()!, Double(W) - 20)
        for p in wire.points {
            XCTAssertEqual((1 - p.y) * Double(H), cable(p.x * Double(W)), accuracy: 3, "the stroke stays on the cable")
        }
        // A brush a little wider than the cable, not sized by its length.
        XCTAssertLessThan(wire.radius * Double(min(W, H)), 8)
    }

    func testOpenSkyAndTextureAreNotLines() {
        let lines = ObjectRemoval.lines(street(), context: CIContext())
        XCTAssertNil(ObjectRemoval.traceLine(lines, width: W, height: H, from: MaskPoint(x: 0.5, y: 0.9)), "sky")
        XCTAssertNil(ObjectRemoval.traceLine(lines, width: W, height: H, from: MaskPoint(x: 0.4, y: 0.2)), "facade texture")
    }

    func testTheSkyIsNotAnObject() {
        // A mask over the top of the frame, as the object segmentation gives for a click on the sky.
        var v = [UInt8](repeating: 0, count: W * H)
        for y in 0..<300 { for x in 0..<W { v[y * W + x] = 255 } }
        let sky = PeopleFinder.Mask(x: 0, y: 0, w: W, h: H, v: v)
        XCTAssertGreaterThan(ObjectRemoval.borderShare(sky, width: W, height: H), 0.12)
        XCTAssertEqual(ObjectRemoval.halfThickness(sky), 150, accuracy: 2, "the frame edge counts as outside")
    }

    func testOutlineTracesTheMatteEdge() {
        // A white square over the middle of a 200 × 100 matte.
        let matte = CIImage(color: .white).cropped(to: CGRect(x: 50, y: 25, width: 100, height: 50))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let segments = ObjectRemoval.outline(matte, context: CIContext())
        XCTAssertFalse(segments.isEmpty)
        let points = segments.flatMap { [$0.0, $0.1] }
        XCTAssertEqual(points.map(\.x).min()!, 0.25, accuracy: 0.01); XCTAssertEqual(points.map(\.x).max()!, 0.75, accuracy: 0.01)
        XCTAssertEqual(points.map(\.y).min()!, 0.25, accuracy: 0.02); XCTAssertEqual(points.map(\.y).max()!, 0.75, accuracy: 0.02)
    }
}
