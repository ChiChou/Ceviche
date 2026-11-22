import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class PortraitPeopleTests: XCTestCase {
    /// A correction tagged with a face belongs to that face; an untagged one (made before faces were known, or for a
    /// drawn region) belongs to everyone.
    func testCovers() {
        let left = CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.3), right = CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.3)
        XCTAssertTrue(PortraitFace.covers(nil, [left]))
        XCTAssertTrue(PortraitFace.covers(left, [left]))
        XCTAssertTrue(PortraitFace.covers(left.insetBy(dx: 0.02, dy: 0.02), [left]), "Found again a little differently")
        XCTAssertFalse(PortraitFace.covers(left, [right]))
        XCTAssertFalse(PortraitFace.covers(left, []))
    }

    /// On a portrait the face list has the face with a picture, and Reduce shine for it is one mask tagged with it.
    func testFacesAndTaggedShine() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        let faces = try await renderer.portraitFaces(Adjustments())
        let face = try XCTUnwrap(faces.first, "A face is found")
        XCTAssertGreaterThan(face.thumbnail.width, 32)
        let shine = try await renderer.portraitMask(.shine, settings: Adjustments(), region: nil, faces: [face.box])
        XCTAssertEqual(shine.count, 1)
        XCTAssertEqual(shine.first?.face, face.box)
        XCTAssertTrue(shine.allSatisfy { $0.adjustments.dehaze > 0 && $0.adjustments.exposure == 0 }, "Shine is taken out, not darkened")
    }
}
