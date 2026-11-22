import XCTest
import Vision
import CevicheTestSupport
@testable import CevicheCore

final class PortraitFramingTests: XCTestCase {
    /// Each framing, on the photo as is and straightened 5°, keeps the whole face in the crop with the eyes near the
    /// upper third (or higher, where the photo's top edge stops it), and a wider framing crops larger.
    func testFramingsKeepTheFace() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        let info = await renderer.info
        let faceValue = try await renderer.portraitFace(Adjustments())
        let face = try XCTUnwrap(faceValue, "A face is found")
        for straighten in [0.0, 5] {
            var areas: [Double] = []
            for framing in PortraitFraming.allCases {
                var settings = Adjustments(); settings.geometry.straighten = straighten; settings.geometry.constrainCrop = false
                let plan = try GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: settings.geometry, quarterTurns: 0)
                settings.geometry.crop = framing.crop(for: face, plan: plan, aspect: 4.0 / 5)
                XCTAssertNoThrow(try settings.validated())
                areas.append(settings.geometry.crop.width * settings.geometry.crop.height)
                let image = try await renderer.preview(settings, sdr: true).image
                XCTAssertEqual(Double(image.width) / Double(image.height), 0.8, accuracy: 0.02, "\(framing) keeps 4:5")
                let request = VNDetectFaceLandmarksRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let found = try XCTUnwrap(request.results?.max { $0.boundingBox.width < $1.boundingBox.width }, "\(framing) \(straighten)°: the face is in the crop")
                let box = found.boundingBox
                XCTAssertTrue(box.minX >= -0.01 && box.maxX <= 1.01 && box.minY >= -0.01 && box.maxY <= 1.01, "\(framing): whole face inside \(box)")
                let eyes = found.landmarks?.leftPupil?.normalizedPoints.first.map { box.minY + $0.y * box.height } ?? box.midY
                print("FRAMING", framing, straighten, "eyes from top", String(format: "%.2f", 1 - eyes), "face height", String(format: "%.2f", box.height))
                XCTAssertLessThan(abs((1 - eyes) - 1.0 / 3), 0.12, "\(framing): eyes near the upper third")
            }
            XCTAssertTrue(areas[0] < areas[1] && areas[1] <= areas[2] + 1e-9, "Wider framings crop larger: \(areas)")
        }
    }

    /// A group's framings hold every face with room beside the outermost, at the asked aspect, wider ones larger.
    func testGroupFramingHoldsEveryFace() throws {
        func face(_ x: Double) -> PortraitFraming.Face {
            PortraitFraming.Face(leftEye: MaskPoint(x: x - 0.02, y: 0.6), rightEye: MaskPoint(x: x + 0.02, y: 0.6),
                                 headTop: MaskPoint(x: x, y: 0.72), chin: MaskPoint(x: x, y: 0.5), nose: MaskPoint(x: x, y: 0.56))
        }
        let faces = [face(0.3), face(0.55), face(0.7)]
        let plan = try GeometryPlan(size: CGSize(width: 6000, height: 4000), settings: GeometryAdjustments(), quarterTurns: 0)
        var areas: [Double] = []
        for framing in PortraitFraming.allCases {
            let crop = try XCTUnwrap(framing.crop(for: faces, plan: plan, aspect: 4.0 / 5)).rect
            XCTAssertEqual(crop.width * 6000 / (crop.height * 4000), 0.8, accuracy: 0.01, "\(framing) keeps 4:5")
            for f in faces {
                XCTAssertTrue(crop.minX < f.leftEye.x - 0.02 && crop.maxX > f.rightEye.x + 0.02, "\(framing): every face across \(crop)")
                XCTAssertTrue(crop.minY < f.chin.y && crop.maxY > f.headTop.y, "\(framing): every head and chin \(crop)")
            }
            areas.append(crop.width * crop.height)
        }
        XCTAssertTrue(areas[0] < areas[1] && areas[1] <= areas[2] + 1e-9, "Wider framings crop larger: \(areas)")
    }
}
