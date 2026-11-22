import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class SkinToneTests: XCTestCase {
    /// On a portrait, Even tone changes the face and nothing far from it; Amount 0 changes nothing; the edit round-trips.
    func testEvenToneChangesOnlyTheFace() async throws {
        guard BundledModel.skinTone.isAvailable else { throw XCTSkip("Skin tone model not installed") }
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = Adjustments()
        let faces = try await renderer.skinToneFaces(settings)
        let face = try XCTUnwrap(faces.first, "A face is found")
        XCTAssertLessThan(face.layer.count, 1_000_000)
        settings.skinTone = SkinTone(faces: faces.map { var f = $0; f.amount = 1; return f })
        XCTAssertNoThrow(try settings.validated())
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings)), settings)

        func bytes(_ a: Adjustments) async throws -> (pixels: [UInt8], width: Int, height: Int) {
            let image = try await renderer.preview(a).image
            var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (out, image.width, image.height)
        }
        let plain = try await bytes(Adjustments())
        let toned = try await bytes(settings)
        var zero = settings; for i in zero.skinTone?.faces.indices ?? 0..<0 { zero.skinTone?.faces[i].amount = 0 }
        let none = try await bytes(zero)
        XCTAssertEqual(none.pixels, plain.pixels, "Amount 0 leaves the photo alone")
        // Changed pixels inside the face square, none outside it (rows top down in the bitmap).
        let w = plain.width, h = plain.height
        let square = CGRect(x: face.x * Double(w), y: (1 - face.y - face.height) * Double(h), width: face.width * Double(w), height: face.height * Double(h)).insetBy(dx: -2, dy: -2)
        var inside = 0, outside = 0
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            guard (0..<3).contains(where: { abs(Int(toned.pixels[i + $0]) - Int(plain.pixels[i + $0])) > 2 }) else { continue }
            if square.contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 }
        } }
        XCTAssertGreaterThan(inside, 500, "The face changes")
        XCTAssertEqual(outside, 0, "Nothing outside the face's square changes")
    }

    func testInvalidLayersAreRefused() {
        var settings = Adjustments()
        settings.skinTone = SkinTone(faces: [SkinTone.Face(x: 0.2, y: 0.2, width: 0.3, height: 0.3, layer: Data("not a png".utf8), amount: 0.5)])
        XCTAssertThrowsError(try settings.validated())
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        settings.skinTone = SkinTone(faces: [SkinTone.Face(x: 0.2, y: 0.2, width: 0.3, height: 0.3, layer: png, amount: 1.5)])
        XCTAssertThrowsError(try settings.validated())
    }

    /// An edit saved before Even tone had an Amount per face reads as unreadable edits, naming what is missing.
    func testOlderEditsSayWhatIsMissing() throws {
        let json = #"{"skinTone":{"amount":0.7,"faces":[{"x":0.1,"y":0.1,"width":0.2,"height":0.2,"layer":""}]}}"#
        do {
            _ = try JSONDecoder().decode(Adjustments.self, from: Data(json.utf8))
            XCTFail("The older edit decodes")
        } catch let error as DecodingError {
            let detail = EditorError.describe(error)
            XCTAssertTrue(detail.contains("skinTone › faces › 1 › amount"), detail)
            XCTAssertTrue(EditorError.unreadableEdits(detail).localizedDescription.contains(detail))
        }
    }

    /// Reset Unreadable keeps what still reads: the face without an Amount goes, a setting of the wrong kind returns
    /// to the defaults, and Exposure stays.
    func testSalvageKeepsTheReadableEdits() throws {
        let json = #"{"exposure":1.5,"temperature":"warm","skinTone":{"amount":0.7,"faces":[{"x":0.1,"y":0.1,"width":0.2,"height":0.2,"layer":""}]}}"#
        var defaults = Adjustments(); defaults.temperature = 5200
        let salvaged = try XCTUnwrap(RevisionPayload.salvage(Data(json.utf8), defaults: defaults) { try JSONDecoder().decode(Adjustments.self, from: $0) })
        XCTAssertEqual(salvaged.settings.exposure, 1.5)
        XCTAssertEqual(salvaged.settings.temperature, 5200)
        XCTAssertTrue(salvaged.dropped.contains("temperature"), "\(salvaged.dropped)")
        XCTAssertTrue(salvaged.dropped.contains { $0.hasPrefix("skinTone") }, "\(salvaged.dropped)")
        XCTAssertNil(RevisionPayload.salvage(Data("[]".utf8)) { try JSONDecoder().decode(Adjustments.self, from: $0) })
    }
}
