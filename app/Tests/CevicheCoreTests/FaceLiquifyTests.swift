import XCTest
import CoreImage
import CevicheTestSupport
@testable import CevicheCore

final class FaceLiquifyTests: XCTestCase {
    private let size = 400
    /// The face fills the middle of a 400 px square, y up; the features keep their usual proportions.
    private let region = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)

    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])
    }
    /// A pattern that changes in both directions, so any shift changes the pixels it moves.
    private func pattern() -> CIImage {
        var values = [Float](repeating: 1, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let v = Float(0.5 + 0.25 * sin(Double(x) / 5) + 0.2 * cos(Double(y) / 7))
            let i = (y * size + x) * 4
            values[i] = v; values[i + 1] = v; values[i + 2] = v
        } }
        return CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: size * 16,
                       size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
    }
    /// Red values, row 0 at the top.
    private func render(_ image: CIImage, _ context: CIContext) -> [Float] {
        var out = [Float](repeating: 0, count: size * size * 4)
        context.render(image, toBitmap: &out, rowBytes: size * 16, bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: out.count, by: 4).map { out[$0] }
    }
    /// The pixel at a point of the region (fractions, y up).
    private func index(_ u: Double, _ v: Double) -> Int {
        let x = Int((region.minX + u * region.width) * Double(size)), y = Int((region.minY + v * region.height) * Double(size))
        return (size - 1 - y) * size + x
    }

    func testFirstVersionDocumentsLoadAsFaceWidth() throws {
        let old = #"{"region":[[0.1,0.2],[0.4,0.5]],"width":-0.6}"#
        let warp = try JSONDecoder().decode(FaceLiquify.self, from: Data(old.utf8))
        XCTAssertEqual(warp.width, -0.6)
        XCTAssertEqual(warp.features, FaceLiquify.Features())
        XCTAssertTrue(FaceLiquify.amounts.filter { $0 != \.width }.allSatisfy { warp[keyPath: $0] == 0 })
        var changed = warp; changed.smile = 0.4; changed.features.nose = MaskPoint(x: 0.48, y: 0.41)
        XCTAssertEqual(try JSONDecoder().decode(FaceLiquify.self, from: JSONEncoder().encode(changed)), changed)
        XCTAssertTrue(changed.valid)
        changed.eyeSize = 1.5
        XCTAssertFalse(changed.valid)
    }

    func testEachControlMovesOnlyItsOwnPart() throws {
        let context = try context(), input = pattern(), before = render(input, context)
        XCTAssertEqual(render(try FaceLiquify(region: region).apply(to: input), context), before, "Nothing set leaves the photo alone")
        // Where each control must act, and a point it must leave alone.
        let cases: [(WritableKeyPath<FaceLiquify, Double>, acts: (Double, Double), keeps: (Double, Double))] = [
            (\.eyeSize, (0.3 + 0.05, 0.62), (0.5, 0.24)),
            (\.eyeDistance, (0.7 + 0.04, 0.62), (0.5, 0.24)),
            (\.noseWidth, (0.5 + 0.08, 0.4), (0.5, 0.9)),
            (\.mouthWidth, (0.36 + 0.03, 0.24), (0.5, 0.62)),
            (\.smile, (0.36, 0.24 + 0.01), (0.5, 0.62)),
            (\.width, (0.5 + 0.32, 0.35), (0.5, 0.62)),
            (\.jawline, (0.5 + 0.34, 0.14), (0.5, 0.62)),
            // Chin height must not move the mouth, nor forehead height the brows.
            (\.chinHeight, (0.5, 0.06), (0.5, 0.24)),
            (\.forehead, (0.5, 0.92), (0.5, 0.72)),
        ]
        for (path, acts, keeps) in cases {
            var warp = FaceLiquify(region: region)
            warp[keyPath: path] = 1
            let after = render(try warp.apply(to: input), context)
            let name = "\(path)"
            XCTAssertGreaterThan(abs(after[index(acts.0, acts.1)] - before[index(acts.0, acts.1)]), 1e-3, "\(name) moves its part")
            XCTAssertEqual(after[index(keeps.0, keeps.1)], before[index(keeps.0, keeps.1)], accuracy: 1e-4, "\(name) leaves the rest")
            // The corners of the photo stay where they were.
            XCTAssertEqual(after[0], before[0], accuracy: 1e-5)
            XCTAssertEqual(after[size * size - 1], before[size * size - 1], accuracy: 1e-5)
        }
    }

    /// A handle stays on its feature: after the warp, what is under the handle's new position is what was under its
    /// old one, so the handle follows the pointer while the face moves with it.
    func testHandlesFollowTheContentTheyMove() throws {
        let context = try context(), input = pattern(), before = render(input, context)
        func sample(_ values: [Float], _ p: MaskPoint) -> Float {
            values[(size - 1 - Int(p.y * Double(size))) * size + Int(p.x * Double(size))]
        }
        let plain = FaceLiquify(region: region)
        let handles = plain.handles(aspect: 1)
        // Two per eye, two on the nose, the mouth's corners, cheeks and jaw on each side, the chin and the hairline.
        XCTAssertEqual(handles.count, 14)
        for handle in handles {
            for axis in handle.axes {
                var warp = plain
                warp[keyPath: axis.path] = 1
                let moved = warp.position(of: handle)
                // Far enough to tell apart in the pattern.
                XCTAssertGreaterThan(hypot(moved.x - handle.base.x, moved.y - handle.base.y) * Double(size), 1.5, "\(axis.path) moves its handle")
                let after = render(try warp.apply(to: input), context)
                let tracked = abs(sample(after, moved) - sample(before, handle.base)), stayed = abs(sample(after, moved) - sample(before, moved))
                XCTAssertLessThan(tracked, stayed + 0.02, "\(axis.path): the handle lands on the content it started on")
            }
        }
    }
}

final class FaceLiquifyPipelineTests: XCTestCase {
    /// The warp reaches the developed preview of a real portrait, placed on the face Vision finds.
    func testDetectedFaceWarpChangesThePreview() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = Adjustments()
        let face = try await renderer.liquifyFace(settings)
        var warp = try XCTUnwrap(face)
        XCTAssertNotEqual(warp.features, FaceLiquify.Features(), "Placed from landmarks, not the usual proportions")
        warp.eyeSize = 1; warp.chinHeight = 1
        let plain = try await renderer.preview(settings).image
        settings.faceLiquify = warp
        let warped = try await renderer.preview(settings).image
        func bytes(_ image: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return out
        }
        let a = bytes(plain), b = bytes(warped)
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count
        XCTAssertGreaterThan(changed, 1000, "The warp shows in the preview")
    }
}

final class FaceLightBalanceTests: XCTestCase {
    /// A daylight portrait set far too cool: balancing on the face brings Temperature back up, Tint stays near.
    func testWholePhotoBalanceTakesTheCastOffTheFace() async throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = Adjustments()
        settings.temperature = 3000
        let balanced = try await renderer.faceLightBalance(settings, region: nil)
        let result = try XCTUnwrap(balanced)
        XCTAssertGreaterThan(result.temperature, 4000)
        XCTAssertEqual(result.exposure, settings.exposure)
        // Balanced already: measuring again changes little.
        let again = try await renderer.faceLightBalance(result, region: nil)
        XCTAssertEqual(try XCTUnwrap(again).temperature, result.temperature, accuracy: result.temperature * 0.03)
    }

}

final class RemovedPortraitCorrectionTests: XCTestCase {
    /// Face exposure and Face Only white balance are gone; a photo edited with them still opens, their masks plain ones.
    func testRemovedCorrectionsDecodeAsPlainMasks() throws {
        for kind in ["exposure", "whiteBalance"] {
            var mask = PhotoMask(kind: .radial); mask.adjustments.exposure = 0.4
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mask)) as? [String: Any])
            object["portraitCorrection"] = kind
            let decoded = try JSONDecoder().decode(PhotoMask.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.portraitCorrection)
            XCTAssertEqual(decoded.adjustments.exposure, 0.4)
        }
    }

    /// Each face's warp is saved, and clearing the warp clears every face's.
    func testSeveralFacesSave() throws {
        var settings = Adjustments()
        settings.faceLiquifies = [FaceLiquify(region: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), width: -0.5),
                                  FaceLiquify(region: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3), width: 0.4)]
        let back = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.faceLiquifies, settings.faceLiquifies)
        settings.faceLiquify = nil
        XCTAssertTrue(settings.faceLiquifies.isEmpty, "Clearing the warp clears every face's")
    }
}
