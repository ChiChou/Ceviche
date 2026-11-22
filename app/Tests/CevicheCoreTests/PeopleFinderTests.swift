import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class PeopleFinderTests: XCTestCase {
    /// A person's mask becomes strokes whose path steps only between neighbouring dabs inside it, whose footprint
    /// covers all of it, and which keep off the subject beside it.
    func testStrokesWalkInsideTheMaskAndKeepOffTheSubject() {
        let W = 400, H = 300
        // An upside-down U: two legs and a bar, so a straight path between far dabs would cross the gap.
        var person = PeopleFinder.Mask(x: 100, y: 50, w: 100, h: 200)
        person.v = [UInt8](repeating: 0, count: person.w * person.h)
        for ly in 0..<person.h { for lx in 0..<person.w where ly < 40 || lx < 30 || lx >= 70 { person.v[ly * person.w + lx] = 255 } }
        var subject = PeopleFinder.Mask(x: 230, y: 50, w: 100, h: 200)
        subject.v = [UInt8](repeating: 255, count: subject.w * subject.h)
        let radius = 10.0
        let strokes = PeopleFinder.strokes(covering: person, radius: radius, protect: subject, width: W, height: H)
        XCTAssertEqual(strokes.count, 1)
        let stroke = strokes[0]
        XCTAssertTrue(stroke.person && stroke.mode == .remove)
        let points = stroke.points.map { CGPoint(x: $0.x * Double(W), y: (1 - $0.y) * Double(H)) }
        // Neighbouring dabs only, and none in the gap between the legs.
        for (a, b) in zip(points, points.dropFirst()) { XCTAssertLessThanOrEqual(hypot(a.x - b.x, a.y - b.y), radius * 0.7 * 1.5) }
        XCTAssertFalse(points.contains { $0.x > 135 && $0.x < 165 && $0.y > 100 })
        // Every pixel of the person lies within half a radius of a dab: inside the soft edge's full part.
        for ly in stride(from: 0, to: person.h, by: 3) { for lx in stride(from: 0, to: person.w, by: 3) where person.v[ly * person.w + lx] > 127 {
            let p = CGPoint(x: Double(person.x + lx), y: Double(person.y + ly))
            XCTAssertLessThanOrEqual(points.map { hypot($0.x - p.x, $0.y - p.y) }.min()!, radius * 0.5 + 0.5)
        } }
        // No dab reaches the subject.
        XCTAssertGreaterThanOrEqual(points.map { Double(subject.x) - $0.x }.min()!, radius)
        XCTAssertNoThrow(try stroke.validate())
    }

    /// On a portrait with tourists behind, the subject is kept and the others are covered by People strokes.
    func testStrangersBehindTheSubjectBecomePeopleStrokes() async throws {
        let url = TestSamples.url(TestSamples.distractingPeople)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("People sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        let start = Date()
        let (people, strokes) = try await renderer.distractingPeople(Adjustments())
        print("people \(people), strokes \(strokes.count), \(String(format: "%.1f", Date().timeIntervalSince(start)))s, points \(strokes.map(\.points.count))")
        XCTAssertGreaterThanOrEqual(people, 4)
        XCTAssertGreaterThanOrEqual(strokes.count, 3)
        XCTAssertTrue(strokes.allSatisfy { $0.group == .people && $0.mode == .remove })
        for stroke in strokes { XCTAssertNoThrow(try stroke.validate()) }
        var settings = Adjustments(); settings.retouch = strokes
        XCTAssertNoThrow(try settings.validated())
    }
}
