import XCTest
import CoreImage
@testable import CevicheCore

final class WideAngleFacesTests: XCTestCase {
    private func analysis(aspect: Double = 1.5) -> WideAngleAnalysis {
        WideAngleAnalysis(people: [], mask: [], maskWidth: 0, maskHeight: 0, aspect: aspect)
    }
    /// A person at `x` across a 3:2 frame, head about a twentieth of the height.
    private func person(_ id: Int, x: Double, enabled: Bool = true) -> WideAnglePerson {
        WideAnglePerson(id: id, head: CGPoint(x: x, y: 0.35), headRadius: CGSize(width: 0.022, height: 0.035),
                        body: CGRect(x: x - 0.05, y: 0.35, width: 0.1, height: 0.5), enabled: enabled)
    }

    func testRefusesLongLenses() {
        XCTAssertNotNil(WideAngleFaces.refusal(focal: 50))
        XCTAssertNil(WideAngleFaces.refusal(focal: 35))
        XCTAssertNil(WideAngleFaces.refusal(focal: 14))
    }

    func testNobodyToCorrectLeavesThePhotoAsShot() {
        for people in [[], [person(0, x: 0.9, enabled: false)]] {
            let mesh = WideAngleFaces.solve(analysis(), people: people, focal: 14, settings: WideAngleSettings())
            let moved = zip(mesh.source, mesh.target).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
            XCTAssertEqual(moved, 0, accuracy: 1e-12)
        }
    }

    /// A head near the edge of a 14 mm frame is stretched outward by about 1/cos θ; corrected, it is narrower across
    /// (the radial direction there) by about that much, while the head in the middle and the far corners barely move.
    func testOffAxisHeadLosesItsStretch() {
        let edge = person(0, x: 0.88), middle = person(1, x: 0.5)
        var settings = WideAngleSettings(); settings.bodies = false
        let mesh = WideAngleFaces.solve(analysis(), people: [edge, middle], focal: 14, settings: settings)
        func width(_ p: WideAnglePerson) -> Double {
            let l = mesh.forward(CGPoint(x: p.head.x - p.headRadius.width, y: p.head.y)), r = mesh.forward(CGPoint(x: p.head.x + p.headRadius.width, y: p.head.y))
            return (r.x - l.x) / (2 * p.headRadius.width)
        }
        func height(_ p: WideAnglePerson) -> Double {
            let t = mesh.forward(CGPoint(x: p.head.x, y: p.head.y - p.headRadius.height)), b = mesh.forward(CGPoint(x: p.head.x, y: p.head.y + p.headRadius.height))
            return (b.y - t.y) / (2 * p.headRadius.height)
        }
        // θ at the edge head: ~45° on a 14 mm 3:2 frame, a 1.4× radial stretch over the tangential one.
        let ratioEdge = width(edge) / height(edge), ratioMiddle = width(middle) / height(middle)
        XCTAssertLessThan(ratioEdge, 0.85, "edge head narrows against its height")
        XCTAssertEqual(ratioMiddle, 1, accuracy: 0.05, "middle head keeps its shape")
        let corner = mesh.forward(CGPoint(x: 0.02, y: 0.98))
        XCTAssertEqual(corner.x, 0.02, accuracy: 0.01); XCTAssertEqual(corner.y, 0.98, accuracy: 0.01)
    }

    func testStrengthScalesTheMove() {
        var full = WideAngleSettings(); full.bodies = false
        var half = full; half.strength = 0.5
        let people = [person(0, x: 0.88)]
        let a = WideAngleFaces.solve(analysis(), people: people, focal: 14, settings: full)
        let b = WideAngleFaces.solve(analysis(), people: people, focal: 14, settings: half)
        let k = a.source.indices.max { hypot(a.target[$0].x - a.source[$0].x, 0) < hypot(a.target[$1].x - a.source[$1].x, 0) }!
        XCTAssertEqual(b.target[k].x - b.source[k].x, 0.5 * (a.target[k].x - a.source[k].x), accuracy: 1e-9)
    }

    func testIdentityMeshWarpsToTheSamePicture() throws {
        let mesh = WideAngleFaces.solve(analysis(aspect: 4.0 / 3), people: [], focal: 14, settings: WideAngleSettings())
        let gradient = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 400, y: 300),
                                                                      "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let warped = try WideAngleFaces.warped(gradient, mesh: mesh)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func pixels(_ i: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: 400 * 300 * 4)
            context.render(i, toBitmap: &out, rowBytes: 400 * 16, bounds: i.extent, format: .RGBAf, colorSpace: nil)
            return out
        }
        let a = pixels(gradient), b = pixels(warped)
        let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 0.01)
    }

    /// Set CEVICHE_WIDE_PHOTO to one or more wide-angle group photos (RAW, HEIC or JPEG; several separated by `|`) and
    /// CEVICHE_WIDE_OUTPUT to a folder: writes each corrected copy and the dialog's before and after previews there.
    func testCorrectsRealPhotos() throws {
        let env = ProcessInfo.processInfo.environment
        guard let photos = env["CEVICHE_WIDE_PHOTO"], let folder = env["CEVICHE_WIDE_OUTPUT"] else { throw XCTSkip("Set CEVICHE_WIDE_PHOTO and CEVICHE_WIDE_OUTPUT") }
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for photo in photos.split(separator: "|").map(String.init) {
            let source = URL(fileURLWithPath: photo)
            let stem = source.deletingPathExtension().lastPathComponent
            var start = Date()
            let previewer = try WideAnglePreviewer(source, exposure: 1)
            print("\(stem): developed and searched \(Date().timeIntervalSince(start)) s, \(previewer.analysis.people.count) people, \(previewer.focalLength ?? 0) mm")
            let mesh = WideAngleFaces.solve(previewer.analysis, people: previewer.analysis.people, focal: previewer.focalLength ?? 24, settings: WideAngleSettings())
            let after = try previewer.corrected(mesh)
            for (name, image) in [("before", previewer.before), ("after", after)] {
                let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(stem)-\(name).jpg") as CFURL, "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
            guard previewer.analysis.people.contains(where: \.enabled) else { print("\(stem): nobody found"); continue }
            start = Date()
            let copy = out.appendingPathComponent("\(stem)-WA.\(WideAngleFaces.outputExtension(for: source))")
            try? FileManager.default.removeItem(at: copy)
            try WideAngleFaces.correct(source, to: copy, settings: WideAngleSettings(), people: nil)
            let written = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [String: Any])
            let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(written, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            print("\(stem): wrote \(copy.lastPathComponent) in \(Date().timeIntervalSince(start)) s, \(properties[kCGImagePropertyPixelWidth as String] ?? 0)×\(properties[kCGImagePropertyPixelHeight as String] ?? 0), orientation \(properties[kCGImagePropertyOrientation as String] ?? 1), gain map \(gainMap)")
            let original = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(original, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { XCTAssertTrue(gainMap, "\(stem) keeps its HDR gain map") }
        }
    }
}
