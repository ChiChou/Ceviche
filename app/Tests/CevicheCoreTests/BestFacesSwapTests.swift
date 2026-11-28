import XCTest
@testable import CevicheCore

/// Laying one face onto another by the face mesh: the fit, its use in Core Image's coordinates, and the outline.
final class BestFacesSwapTests: XCTestCase {
    private let points = [CGPoint(x: 100, y: 120), CGPoint(x: 180, y: 118), CGPoint(x: 140, y: 170), CGPoint(x: 120, y: 210),
                          CGPoint(x: 165, y: 212), CGPoint(x: 90, y: 160), CGPoint(x: 195, y: 165)]

    func testSimilarityFindsTheMoveScaleAndTurn() {
        let angle = 12 * Double.pi / 180, scale = 1.1
        let truth = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle), c: -scale * sin(angle), d: scale * cos(angle), tx: 37, ty: -21)
        let (found, error) = BestFacesMerger.similarity(from: points, to: points.map { $0.applying(truth) })
        XCTAssertLessThan(error, 1e-6)
        for p in points {
            let a = p.applying(found), b = p.applying(truth)
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6); XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testSimilarityReportsPointsThatDisagree() {
        var moved = points.map { CGPoint(x: $0.x + 5, y: $0.y) }
        moved[2].x += 30
        XCTAssertGreaterThan(BestFacesMerger.similarity(from: points, to: moved).1, 5)
    }

    /// A source pixel lands where the transform puts it in the base, both counted from the top, though Core Image counts
    /// from the bottom of images of different heights.
    func testFlippedCarriesTopLeftPixelsIntoCoreImage() {
        let transform = CGAffineTransform(a: 0.9, b: 0.2, c: -0.2, d: 0.9, tx: 40, ty: 15)
        let (source, base) = (3000.0, 2800.0)
        let ci = BestFacesMerger.flipped(transform, from: source, to: base)
        for p in points {
            let expected = p.applying(transform)
            let got = CGPoint(x: p.x, y: source - p.y).applying(ci)
            XCTAssertEqual(got.x, expected.x, accuracy: 1e-6)
            XCTAssertEqual(got.y, base - expected.y, accuracy: 1e-6)
        }
    }

    func testContainsAPointInsideTheOutline() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        XCTAssertTrue(BestFacesMerger.contains(square, 0.5, 0.5))
        XCTAssertFalse(BestFacesMerger.contains(square, 1.5, 0.5))
    }
}
