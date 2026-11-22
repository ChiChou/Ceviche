import XCTest
import CoreGraphics
import CoreImage
import simd
@testable import CevicheCore

final class UprightAnalyzerTests: XCTestCase {
    typealias V = SIMD3<Double>

    /// A photo of vertical edges taken with the camera tilted by `tilt` degrees and rolled by `roll`: light and
    /// dark wedges meeting at the vertical vanishing point. Returns the image, the vanishing direction, and the
    /// vanishing point in centred long-edge units (y down).
    private func tilted(tilt: Double, roll: Double, f: Double, w: Int = 900, h: Int = 600) -> (CGImage, V, SIMD2<Double>) {
        let camera = UprightAnalyzer.mul(UprightAnalyzer.rotation(V(0, 0, 1), roll * .pi / 180), UprightAnalyzer.rotation(V(1, 0, 0), tilt * .pi / 180))
        var d = UprightAnalyzer.apply(camera, V(0, 1, 0))
        let vp = SIMD2(d.x * f / d.z, d.y * f / d.z)
        if d.y < 0 { d = -d }
        let long = Double(w)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var sum = 0.0
            for j in 0..<16 {
                let x = (Double(i % w) + Double(j % 4) / 4 + 0.125 - Double(w) / 2) / long
                let y = (Double(i / w) + Double(j / 4) / 4 + 0.125 - Double(h) / 2) / long
                let a = atan2(x - vp.x, vp.y - y)
                sum += sin(a * 180) > 0 ? 200 : 40
            }
            pixels[i] = UInt8(sum / 16)
        }
        return (image(pixels, w: w, h: h), d, vp)
    }
    private func image(_ pixels: [UInt8], w: Int, h: Int) -> CGImage {
        var pixels = pixels
        return pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.makeImage()!
        }
    }
    /// A wedge edge at `degrees` from the vanishing point, as two points in 0–1 coordinates of the 900 × 600
    /// displayed photo (bottom-left origin).
    private func edge(_ degrees: Double, vp: SIMD2<Double>) -> [MaskPoint] {
        let a = degrees * .pi / 180
        return [0.25, 0.45].map { r in
            let x = vp.x + r * sin(a), y = vp.y - r * cos(a)
            return MaskPoint(x: x + 0.5, y: 0.5 - y / (600.0 / 900))
        }
    }

    func testFindsTheVerticalOfATiltedCamera() throws {
        let (photo, truth, _) = tilted(tilt: 8, roll: 1.5, f: 1)
        let lines = try XCTUnwrap(UprightAnalyzer.lineSegments(photo))
        XCTAssertGreaterThan(lines.count, 5)
        let found = UprightAnalyzer.vanishingPoints(lines, focal: 1)
        let d = try XCTUnwrap(found.vertical)
        let error = acos(min(1, max(-1, simd_dot(d, truth)))) * 180 / .pi
        XCTAssertLessThan(error, 0.2, "\(d) vs \(truth)")
    }
    func testHorizonFromASingleEdgeAndEigenvectorEdgeCases() throws {
        // Sky over ground, the horizon rising to the right by 3°: a falling slope in the analyser's y-down frame.
        let w = 600, h = 400
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.3, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: 300, y: 200); context.rotate(by: 3 * .pi / 180)
        context.setFillColor(gray: 0.9, alpha: 1); context.fill(CGRect(x: -600, y: 0, width: 1200, height: 600))
        let photo = try XCTUnwrap(context.makeImage())
        let horizon = try XCTUnwrap(UprightAnalyzer.vanishingPoints(try XCTUnwrap(UprightAnalyzer.lineSegments(photo)), focal: 1).horizon)
        XCTAssertEqual(horizon * 180 / .pi, -3, accuracy: 0.2)
        XCTAssertEqual(UprightAnalyzer.smallestEigenvector(simd_double3x3(diagonal: SIMD3(3, 0.5, 2))).map { abs($0.y) }, 1)
        XCTAssertNil(UprightAnalyzer.smallestEigenvector(matrix_identity_double3x3), "No direction is distinguished")
    }
    func testVerticalMakesConvergingEdgesParallelAndLevelOnlyRolls() throws {
        let f = 1.2
        let camera = UprightAnalyzer.mul(UprightAnalyzer.rotation(V(0, 0, 1), 2 * .pi / 180), UprightAnalyzer.rotation(V(1, 0, 0), -6 * .pi / 180))
        var d = UprightAnalyzer.apply(camera, V(0, 1, 0)); if d.y < 0 { d = -d }
        let r = UprightAnalyzer.rotations(UprightAnalyzer.Vanishing(vertical: d, horizontal: nil, horizon: nil))
        func project(_ m: UprightAnalyzer.Mat, _ p: V) -> SIMD2<Double> {
            let q = UprightAnalyzer.apply(UprightAnalyzer.cameraTurn(m, focal: f), p); return SIMD2(q.x / q.z, q.y / q.z)
        }
        for x in [-0.4, 0, 0.4] {
            let a = V(x, 0.2, 1), b = V(a.x + 0.1 * d.x * f, a.y + 0.1 * d.y * f, 1 + 0.1 * d.z)
            let p = project(r.vertical, a), q = project(r.vertical, b)
            XCTAssertEqual(atan2(q.x - p.x, q.y - p.y) * 180 / .pi, 0, accuracy: 0.01)
        }
        XCTAssertEqual(r.level[2].x, 0, accuracy: 1e-6); XCTAssertEqual(r.level[2].y, 0, accuracy: 1e-6)
        XCTAssertEqual(asin(r.level[0].y) * 180 / .pi, 2, accuracy: 0.01)
        // Auto corrects part of the tilt: between Level and Vertical.
        let tilt = { (m: UprightAnalyzer.Mat) -> Double in let v = UprightAnalyzer.apply(m, d); return atan2(abs(v.z), v.y) * 180 / .pi }
        XCTAssertLessThan(tilt(r.auto), tilt(r.level)); XCTAssertGreaterThan(tilt(r.auto), tilt(r.vertical))
    }
    func testStoredCorrectionPlumbsEdgesThroughEveryOrientation() throws {
        let (photo, _, vp) = tilted(tilt: 7, roll: 2, f: 1)
        for (turns, flipH, flipV) in [(0, false, false), (1, false, false), (2, true, false), (3, false, true), (0, true, true)] {
            let source = turns % 2 == 0 ? CGSize(width: 900, height: 600) : CGSize(width: 600, height: 900)
            let analysis = try XCTUnwrap(UprightAnalyzer.analyze(photo, focal: 1, sourceSize: source, quarterTurns: turns, flipHorizontal: flipH, flipVertical: flipV))
            XCTAssertFalse(analysis.empty)
            var oriented = GeometryAdjustments(); oriented.flipHorizontal = flipH; oriented.flipVertical = flipV
            let plain = try GeometryPlan(size: source, settings: oriented, quarterTurns: turns)
            var settings = oriented; settings.uprightMode = .vertical; settings.uprightAnalysis = analysis
            let plan = try GeometryPlan(size: source, settings: settings, quarterTurns: turns)
            for degrees in [-20.0, 0, 15] {
                // The edge as displayed, taken back to the untransformed photo, must come out plumb on screen.
                let points = edge(degrees, vp: vp).map { plain.sourcePoint($0) }.map(plan.displayPoint)
                let lean = atan2((points[1].x - points[0].x) * plan.outputSize.width, (points[1].y - points[0].y) * plan.outputSize.height) * 180 / .pi
                XCTAssertEqual(lean, 0, accuracy: 0.3, "turns \(turns) flips \(flipH) \(flipV), edge \(degrees)°")
            }
            try settings.validate()
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(GeometryAdjustments.self, from: data), settings)
        }
    }
    func testLevelLevelsRolledLinesAndFlatImageIsEmpty() throws {
        let w = 600, h = 400
        let roll = 3.0 * .pi / 180
        // Anti-aliased strokes, as edges are in a photo; hard pixel steps would read as many tiny level runs.
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: 300, y: 200); context.rotate(by: roll)
        context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(3)
        for y in [-100.0, 0, 100] { context.move(to: CGPoint(x: -400, y: y)); context.addLine(to: CGPoint(x: 400, y: y)); context.strokePath() }
        let rolled = try XCTUnwrap(context.makeImage())
        let analysis = try XCTUnwrap(UprightAnalyzer.analyze(rolled, focal: 1, sourceSize: CGSize(width: w, height: h), quarterTurns: 0, flipHorizontal: false, flipVertical: false))
        XCTAssertFalse(analysis.empty)
        var settings = GeometryAdjustments(); settings.uprightMode = .level; settings.uprightAnalysis = analysis
        let plan = try GeometryPlan(size: CGSize(width: w, height: h), settings: settings, quarterTurns: 0)
        // Two points of the middle line, in bottom-left 0–1 coordinates, must come out level.
        let a = plan.displayPoint(MaskPoint(x: 0.2, y: 0.5 - (0.3 * 600) * tan(roll) / 400)), b = plan.displayPoint(MaskPoint(x: 0.8, y: 0.5 + (0.3 * 600) * tan(roll) / 400))
        XCTAssertEqual(atan2((b.y - a.y) * Double(h), (b.x - a.x) * Double(w)) * 180 / .pi, 0, accuracy: 0.3)
        let flat = try XCTUnwrap(UprightAnalyzer.analyze(image([UInt8](repeating: 128, count: w * h), w: w, h: h), focal: 1, sourceSize: CGSize(width: w, height: h), quarterTurns: 0, flipHorizontal: false, flipVertical: false))
        XCTAssertTrue(flat.empty)
        XCTAssertEqual(flat.correction(for: .full), UprightAnalysis.identity)
    }
    func testFocalLengthFallsBackSensibly() {
        XCTAssertEqual(UprightAnalyzer.focal(equivalent35mm: 24, focalLength: 16, make: "SONY", model: "ILCE-7M4"), 24.0 / 36, accuracy: 1e-12)
        XCTAssertEqual(UprightAnalyzer.focal(equivalent35mm: nil, focalLength: 23, make: "FUJIFILM", model: "X-T5"), 23 * 1.5226 / 36, accuracy: 1e-12)
        XCTAssertEqual(UprightAnalyzer.focal(equivalent35mm: nil, focalLength: 63, make: "FUJIFILM", model: "GFX100S"), 63 * 0.79 / 36, accuracy: 1e-12)
        XCTAssertEqual(UprightAnalyzer.focal(equivalent35mm: nil, focalLength: nil, make: nil, model: nil), 35.0 / 36, accuracy: 1e-12)
    }
    func testModesPersistAndValidate() throws {
        XCTAssertEqual(try JSONDecoder().decode(GeometryAdjustments.self, from: Data("{}".utf8)).uprightMode, .off)
        var settings = GeometryAdjustments(); settings.uprightMode = .auto
        XCTAssertTrue(settings.needsUprightAnalysis); XCTAssertFalse(settings.uprightActive)
        XCTAssertEqual(try GeometryPlan(size: CGSize(width: 600, height: 400), settings: settings, quarterTurns: 0).displayPoint(MaskPoint(x: 0.3, y: 0.7)), MaskPoint(x: 0.3, y: 0.7), "Unanalysed modes render the photo as it is")
        settings.uprightAnalysis = UprightAnalysis(auto: UprightAnalysis.identity, level: UprightAnalysis.identity, vertical: UprightAnalysis.identity, full: [1, 0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertThrowsError(try settings.validate(), "A singular correction is rejected")
        settings.uprightAnalysis?.full = UprightAnalysis.identity
        XCTAssertNoThrow(try settings.validate()); XCTAssertTrue(settings.uprightActive); XCTAssertFalse(settings.needsUprightAnalysis)
        settings.uprightEnabled = false; XCTAssertFalse(settings.uprightActive)
    }
}
