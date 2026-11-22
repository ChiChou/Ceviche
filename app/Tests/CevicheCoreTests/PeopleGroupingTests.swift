import XCTest
@testable import CevicheCore

final class PeopleGroupingTests: XCTestCase {
    /// A unit vector near axis `axis`, nudged by `noise` along `wobble`.
    static func vector(_ axis: Int, noise: Float = 0, wobble: Int = 100) -> [Float] {
        var v = [Float](repeating: 0, count: FaceEmbedding.count)
        v[axis] = 1; v[wobble] = noise
        let length = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / length }
    }
    func face(_ photo: String, _ index: Int = 0, _ vector: [Float], time: String? = nil, person: String? = nil, pinned: Bool = false) -> PeopleGrouping.Face {
        PeopleGrouping.Face(key: CatalogFaceKey(assetID: photo, index: index), vector: vector, captureTime: time ?? photo, personID: person, pinned: pinned)
    }

    func testFacesOfTwoPeopleMakeTwoPeopleAndALoneFaceWaits() {
        let faces = [face("a", 0, Self.vector(0, noise: 0.2)), face("b", 0, Self.vector(0, noise: -0.3, wobble: 101)), face("c", 0, Self.vector(0)),
                     face("a", 1, Self.vector(1)), face("d", 0, Self.vector(1, noise: 0.4)),
                     face("e", 0, Self.vector(2))]
        let result = PeopleGrouping.group(faces)
        XCTAssertTrue(result.joined.isEmpty)
        XCTAssertEqual(Set(result.created.map { Set($0.map(\.assetID)) }), [["a", "b", "c"], ["a", "d"]])
    }

    func testOnePhotoNeverGivesAPersonTwoFaces() {
        // Twins at one table: alike enough to group, but in the same photo.
        let faces = [face("a", 0, Self.vector(0)), face("a", 1, Self.vector(0, noise: 0.1))]
        XCTAssertTrue(PeopleGrouping.group(faces).created.isEmpty)
    }

    func testPeopleKeepTheirFacesAndGainNewOnes() {
        let faces = [face("a", 0, Self.vector(0), person: "P"), face("b", 0, Self.vector(1), person: "P", pinned: true),
                     face("c", 0, Self.vector(0, noise: 0.3))]
        let result = PeopleGrouping.group(faces)
        XCTAssertEqual(result.joined, [CatalogFaceKey(assetID: "c", index: 0): "P"])
        XCTAssertTrue(result.created.isEmpty)
    }

    func testFacesTakenOutByHandStayOut() {
        let faces = [face("a", 0, Self.vector(0), pinned: true), face("b", 0, Self.vector(0), pinned: true)]
        XCTAssertEqual(PeopleGrouping.group(faces), PeopleGrouping.Result())
    }

    func testAFaceBetweenTwoPeopleIsLeftAlone() {
        // Halfway between P and Q: 0.71 to each, no lead.
        var between = [Float](repeating: 0, count: FaceEmbedding.count); between[0] = 1; between[1] = 1
        between = between.map { $0 / sqrt(2) }
        let faces = [face("a", 0, Self.vector(0), person: "P"), face("b", 0, Self.vector(1), person: "Q"), face("c", 0, between)]
        let result = PeopleGrouping.group(faces)
        XCTAssertTrue(result.joined.isEmpty); XCTAssertTrue(result.created.isEmpty)
    }

    func testFacesBelowTheThresholdDoNotGroup() {
        // cos = 0.4
        var other = [Float](repeating: 0, count: FaceEmbedding.count); other[0] = 0.4; other[1] = sqrt(1 - 0.16)
        XCTAssertTrue(PeopleGrouping.group([face("a", 0, Self.vector(0)), face("b", 0, other)]).created.isEmpty)
    }

    func testStoredEmbeddingsRoundTripAtHalfPrecision() {
        let v = Self.vector(3, noise: 0.25)
        let back = FaceEmbedding.vector(FaceEmbedding.data(v))!
        XCTAssertEqual(back.count, FaceEmbedding.count)
        for (a, b) in zip(v, back) { XCTAssertEqual(a, b, accuracy: 1e-3) }
        XCTAssertNil(FaceEmbedding.vector(Data()))
    }

    func testAlignmentMapsTheFivePointsOntoTheTemplate() {
        // The template itself, shrunk, turned and moved: the estimate undoes it exactly.
        let turn = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 1.7, y: 1.7).translatedBy(x: 20, y: -8)
        let source = FaceEmbedding.template.map { $0.applying(turn) }
        let estimate = FaceEmbedding.similarity(from: source, to: FaceEmbedding.template)
        for (s, t) in zip(source, FaceEmbedding.template) {
            let p = s.applying(estimate)
            XCTAssertEqual(p.x, t.x, accuracy: 1e-6); XCTAssertEqual(p.y, t.y, accuracy: 1e-6)
        }
    }
}
