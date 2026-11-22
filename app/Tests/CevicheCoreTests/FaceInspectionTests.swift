import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class FaceInspectionTests: XCTestCase {
    func testCropKeepsSmallFacesWholeAndCutsLargeOnesToTheEyes() {
        let size = CGSize(width: 6000, height: 4000)
        // A 180 px face: whole, with room around it, at actual pixels.
        let small = FaceInspection.cropRect(face: CGRect(x: 0.5, y: 0.3, width: 0.03, height: 0.045), imageSize: size, maxSide: 420)
        XCTAssertEqual(small.width, 243, accuracy: 1)
        XCTAssertEqual(small.width, small.height)
        XCTAssertTrue(small.contains(CGPoint(x: 0.515 * 6000, y: 0.32 * 4000)))
        // A 1200 px face: cut to the side limit around its eyes, 40 % down the box.
        let large = FaceInspection.cropRect(face: CGRect(x: 0.3, y: 0.2, width: 0.2, height: 0.3), imageSize: size, maxSide: 420)
        XCTAssertEqual(large.size, CGSize(width: 420, height: 420))
        XCTAssertEqual(large.midY, 0.2 * 4000 + 0.4 * 1200, accuracy: 1)
        // At the edge: moved inside, never past it.
        let edge = FaceInspection.cropRect(face: CGRect(x: 0.98, y: 0.0, width: 0.02, height: 0.03), imageSize: size, maxSide: 420)
        XCTAssertEqual(edge.maxX, 6000)
        XCTAssertEqual(edge.minY, 0)
    }

    func testFindsTheFaceAndCropsItFromTheFullOriginal() throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let faces = try FaceInspection.faces(at: url)
        XCTAssertEqual(faces.count, 1)
        let face = try XCTUnwrap(faces.first)
        // Full-resolution pixels: on a 42 MP frame this face is about 840 px wide, over the side limit.
        XCTAssertEqual(face.crop.width, FaceInspection.maxCropSide)
        XCTAssertEqual(face.crop.height, FaceInspection.maxCropSide)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(face.bounds))
    }
}
