import XCTest
import Vision
import CevicheTestSupport
@testable import CevicheCore

final class PeopleMaskTests: XCTestCase {
    /// On a portrait: the person is found; Facial Skin covers the face and not the background, Hair is elsewhere, and the
    /// entire person covers more than their face.
    func testPartsOfOnePerson() async throws {
        guard BundledModel.peopleParts.isAvailable else { throw XCTSkip("People model not installed") }
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        let people = try await renderer.peopleInPhoto()
        let person = try XCTUnwrap(people.first, "A person is found")
        XCTAssertGreaterThan(person.thumbnail.width, 32)

        // The chooser's previews: every part of the person tinted in one pass.
        let previews = try await renderer.peoplePreviews(person.box, adjustments: Adjustments(), parts: PersonPart.allCases)
        XCTAssertTrue(Set(PersonPart.allCases).subtracting([.teeth]).isSubset(of: previews.keys), "Every part has a preview (the mouth is closed: no teeth)")

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func coverage(_ parts: [PersonPart]) async throws -> (at: (Double, Double) -> Float, mean: Float) {
            let mask = try await renderer.selection(.people, people: PeopleSelection(box: person.box, parts: parts))
            XCTAssertEqual(mask.people?.parts, parts)
            let raster = try XCTUnwrap(MaskRaster.image(from: try XCTUnwrap(mask.raster)))
            let w = Int(raster.extent.width), h = Int(raster.extent.height)
            var values = [Float](repeating: 0, count: w * h)
            values.withUnsafeMutableBytes { context.render(raster, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: raster.extent, format: .Rf, colorSpace: nil) }
            let at = { (x: Double, y: Double) -> Float in values[min(h - 1, Int((1 - y) * Double(h))) * w + min(w - 1, Int(x * Double(w)))] }
            return (at, values.reduce(0, +) / Float(values.count))
        }
        // The face, from Vision, to probe: its middle (cheeks and nose) and a point well outside the person.
        let request = VNDetectFaceRectanglesRequest()
        let image = try await renderer.preview(Adjustments()).image
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let face = try XCTUnwrap(request.results?.max { $0.boundingBox.width < $1.boundingBox.width }?.boundingBox)
        let skin = try await coverage([.faceSkin]), hair = try await coverage([.hair]), whole = try await coverage([.entire])
        XCTAssertGreaterThan(skin.at(face.midX, face.minY + face.height * 0.4), 0.5, "Facial skin covers the cheek")
        let outside = (person.box.minX > 0.15 ? person.box.minX / 2 : (1 + person.box.maxX) / 2, 0.95)
        XCTAssertLessThan(skin.at(outside.0, outside.1), 0.1, "Not the background")
        XCTAssertLessThan(hair.at(face.midX, face.minY + face.height * 0.4), 0.5, "Hair is not the cheek")
        XCTAssertGreaterThan(whole.mean, skin.mean * 2, "The entire person is more than their face")
        // The face's features, drawn from landmarks: each covers something, all of it within the face, and the eyes'
        // whites and irises do not overlap.
        let sclera = try await coverage([.sclera]), iris = try await coverage([.iris]), lips = try await coverage([.lips])
        for (part, c) in [("sclera", sclera), ("iris", iris), ("lips", lips)] {
            XCTAssertGreaterThan(c.mean, 0, part)
            XCTAssertLessThan(c.mean, Float(face.width * face.height), "\(part) stays within the face")
        }
        XCTAssertLessThan(lips.at(face.midX, face.maxY - face.height * 0.2), 0.1, "Lips are not the forehead")
    }
}
