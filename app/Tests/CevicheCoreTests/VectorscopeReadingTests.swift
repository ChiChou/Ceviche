import XCTest
@testable import CevicheCore

final class VectorscopeReadingTests: XCTestCase {
    func testTargetsReadAsFullySaturatedPrimaries() {
        for (target, hue) in zip(Scopes.targets, [0.0, 60, 120, 180, 240, 300]) {
            let reading = Scopes.reading(cb: target.cb, cr: target.cr)
            XCTAssertEqual(reading.hue, hue, accuracy: 0.5, target.name)
            XCTAssertEqual(reading.saturation, 1, accuracy: 0.001, target.name)
        }
    }

    func testHalfwayAndBeyondTheEdge() {
        let red = Scopes.targets[0], cyan = Scopes.targets[3]
        XCTAssertEqual(Scopes.reading(cb: red.cb / 2, cr: red.cr / 2).saturation, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(Scopes.reading(cb: cyan.cb * 1.2, cr: cyan.cr * 1.2).saturation, 1.19)
        XCTAssertEqual(Scopes.reading(cb: 0, cr: 0).saturation, 0)
    }

    func testEdgesBetweenTargetsAreStraight() {
        // The midpoint of the red–yellow side is on the edge: saturation 1, hue between them.
        let red = Scopes.targets[0], yellow = Scopes.targets[1]
        let reading = Scopes.reading(cb: (red.cb + yellow.cb) / 2, cr: (red.cr + yellow.cr) / 2)
        XCTAssertEqual(reading.saturation, 1, accuracy: 0.001)
        XCTAssertEqual(reading.hue, 30, accuracy: 6)
    }

    func testSkinLineSitsBetweenRedAndYellow() {
        let reading = Scopes.reading(cb: cos(Scopes.skinLineAngle) * 0.1, cr: sin(Scopes.skinLineAngle) * 0.1)
        XCTAssertGreaterThan(reading.hue, 10); XCTAssertLessThan(reading.hue, 40)
    }
}
