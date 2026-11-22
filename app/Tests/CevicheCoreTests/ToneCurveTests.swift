import XCTest
@testable import CevicheCore

final class ToneCurveTests: XCTestCase {
    func testArbitraryAnchorsInterpolationAndEditing() throws {
        var curve = ToneCurve()
        for (x, y) in [(0.08, 0.03), (0.19, 0.12), (0.31, 0.27), (0.43, 0.55), (0.62, 0.71), (0.79, 0.82), (0.93, 0.97)] {
            XCTAssertNotNil(curve.insert(x: x, y: y))
        }
        XCTAssertEqual(curve.points.count, 9)
        try curve.validate()
        for point in curve.points { XCTAssertEqual(curve.value(at: point.x), point.y, accuracy: 1e-9) }
        let values = (0...1000).map { curve.value(at: Double($0) / 1000) }
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertNil(curve.insert(x: 0.31, y: 0.8))
        curve.move(at: 3, x: 0.9, y: -1)
        XCTAssertLessThan(curve.points[3].x, curve.points[4].x)
        XCTAssertEqual(curve.points[3].y, 0)
        curve.move(at: 0, x: 0.2, y: 0.1)
        XCTAssertEqual(curve.points[0].x, 0)
        curve.remove(at: 0); curve.remove(at: curve.points.count - 1)
        XCTAssertEqual(curve.points.count, 9)
        curve.remove(at: 3)
        XCTAssertEqual(curve.points.count, 8)
        try curve.validate()
    }
    func testSDRCurveIsANaturalSplineClippedToRange() throws {
        let lift = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.75), .init(x: 1, y: 1)])
        // Second derivative −3 at the middle point and 0 at both ends.
        XCTAssertEqual(lift.value(at: 0.25), 0.421875, accuracy: 1e-12)
        XCTAssertEqual(lift.value(at: 0.75), 0.921875, accuracy: 1e-12)
        let wave = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.3, y: 0.9), .init(x: 0.7, y: 0.2), .init(x: 1, y: 1)])
        try wave.validate()
        let values = (0...1000).map { wave.value(at: Double($0) / 1000) }
        XCTAssertGreaterThan(values.max()!, 0.9, "A natural spline overshoots between points")
        XCTAssertTrue(values.allSatisfy { (0...1).contains($0) })
        for point in wave.points { XCTAssertEqual(wave.value(at: point.x), point.y, accuracy: 1e-12) }
    }
    func testPointListRoundTripsAndValueListsAreRejected() throws {
        var edited = Adjustments()
        edited.curve.insert(x: 0.63, y: 0.76)
        let reopened = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(reopened, edited)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments())) as! [String: Any]
        json["curve"] = [0, 0.17, 0.51, 0.82, 1]
        XCTAssertThrowsError(try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0, y: 0.5), .init(x: 1, y: 1)]).validate())
    }
}
