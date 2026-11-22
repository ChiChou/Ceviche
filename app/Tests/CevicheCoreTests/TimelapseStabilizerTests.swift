import XCTest
import CoreGraphics
import simd
@testable import CevicheCore
import CevicheTestSupport

final class TimelapseStabilizerTests: XCTestCase {
    private let width = 640, height = 400

    /// Land below a wavy horizon, textured with soft blobs that hold still, under a sky of stars that turn with time.
    /// The camera's motion `shift` (in pixels) and `angle` move all of it.
    private func frame(_ index: Int, shift: SIMD2<Double>, angle: Double = 0, landless: Bool = false) -> CGImage {
        var generator = SeededGenerator(seed: 7)
        let blobs = (0..<160).map { _ in (SIMD2(Double.random(in: 0..<Double(width), using: &generator), Double.random(in: 180..<Double(height), using: &generator)),
                                         Double.random(in: 2.5...7, using: &generator), Double.random(in: -0.35...0.35, using: &generator)) }
        let stars = (0..<400).map { _ in SIMD2(Double.random(in: -100..<Double(width + 100), using: &generator), Double.random(in: -100..<Double(height), using: &generator)) }
        // The sky drifts three pixels a frame, as a wide lens sees the stars turn in half a minute.
        let sky = SIMD2(3.0, 1.0) * Double(index)
        // Stars by 8-pixel cell of the scene, so each pixel looks only at its own neighborhood.
        var cells: [SIMD2<Int>: [SIMD2<Double>]] = [:]
        for star in stars { let p = star + sky; cells[SIMD2(Int((p.x / 8).rounded(.down)), Int((p.y / 8).rounded(.down))), default: []].append(p) }
        let centre = SIMD2(Double(width), Double(height)) / 2
        let c = cos(angle), s = sin(angle)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            // The scene point this pixel sees: the motion undone.
            let p = SIMD2(Double(x), Double(y)) - shift - centre
            let q = SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y) + centre
            let horizon = 190 + 18 * sin(q.x / 53) + 9 * sin(q.x / 17 + 1)
            var value = 0.08
            if !landless && q.y > horizon {
                value = 0.3 + blobs.reduce(0) { sum, blob in
                    let d = simd_length_squared(q - blob.0)
                    return d > 400 ? sum : sum + blob.2 * exp(-d / (2 * blob.1 * blob.1))
                }
            } else {
                let cell = SIMD2(Int((q.x / 8).rounded(.down)), Int((q.y / 8).rounded(.down)))
                for dy in -1...1 { for dx in -1...1 {
                    for star in cells[cell &+ SIMD2(dx, dy)] ?? [] {
                        let d = simd_length_squared(q - star)
                        if d < 9 { value += 0.8 * exp(-d / 1.2) }
                    }
                } }
            }
            pixels[y * width + x] = UInt8(max(0, min(255, value * 255)))
        } }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return context.makeImage()!
    }
    private func times(_ count: Int, every seconds: Double = 30) -> [Date?] { (0..<count).map { Date(timeIntervalSince1970: 1_728_600_000 + Double($0) * seconds) } }

    func testTripodDriftIsMeasuredOnTheLandNotTheStars() {
        // A knock out and back at frame 3, then the tripod settles by 2.5 pixels from frame 7.
        let motion: [SIMD2<Double>] = [.zero, .zero, .zero, SIMD2(6, -3), .zero, .zero, .zero, SIMD2(2.5, 0), SIMD2(2.5, 0.4), SIMD2(2.5, 0)]
        let result = TimelapseStabilizer.stabilize(motion.indices.map { frame($0, shift: motion[$0]) }, times: times(motion.count))
        XCTAssertFalse(result.followedSky)
        XCTAssertEqual(result.unsteadied, [])
        for (index, expected) in motion.enumerated() {
            guard let shift = result.shifts[index] else { return XCTFail("frame \(index) unmeasured") }
            // The series' view is where most frames were: no motion.
            XCTAssertEqual(shift.dx * Double(width), expected.x, accuracy: 0.1, "frame \(index)")
            XCTAssertEqual(shift.dy * Double(height), expected.y, accuracy: 0.1, "frame \(index)")
        }
        XCTAssertEqual(result.margin.width * Double(width), 6, accuracy: 1)
        XCTAssertEqual(result.margin.height * Double(height), 3, accuracy: 1)
    }

    func testRollIsMeasured() throws {
        try TestTier.requireSlow("Registers synthetic frames in a debug build")
        let angles = [0, 0, 0.004, 0.004, 0]
        let result = TimelapseStabilizer.stabilize(angles.indices.map { frame($0, shift: .zero, angle: angles[$0]) }, times: times(angles.count))
        for (index, angle) in angles.enumerated() { XCTAssertEqual(result.shifts[index]?.angle ?? .nan, angle, accuracy: 0.0002, "frame \(index)") }
    }

    func testAMovePastATripodsDriftIsLeftAlone() throws {
        try TestTier.requireSlow("Registers synthetic frames in a debug build")
        // 8 % of the width is a camera that was picked up, not drift.
        let motion: [SIMD2<Double>] = [.zero, .zero, SIMD2(51, 0), .zero, .zero]
        let result = TimelapseStabilizer.stabilize(motion.indices.map { frame($0, shift: motion[$0]) }, times: times(motion.count))
        XCTAssertEqual(result.unsteadied, [2])
        XCTAssertLessThan(result.margin.width, 0.005, "The frame left alone takes no margin")
    }

    func testStarsAloneAreNotHeldStill() {
        let result = TimelapseStabilizer.stabilize((0..<8).map { frame($0, shift: .zero, landless: true) }, times: times(8))
        XCTAssertTrue(result.followedSky)
        XCTAssertEqual(result.margin, .zero)
        XCTAssertTrue(result.shifts.allSatisfy { $0 == .zero })
    }

    func testSteadyingTakesTheFrameBackToTheSeriesView() {
        let size = CGSize(width: 1000, height: 500)
        let shift = TimelapseShift(dx: 0.01, dy: 0.02, angle: 0.01)
        // A point of the series' view (top-left origin) and where this frame shows it.
        let q = CGPoint(x: 300, y: 120), centre = CGPoint(x: 500, y: 250)
        let p = CGPoint(x: cos(0.01) * (q.x - centre.x) - sin(0.01) * (q.y - centre.y) + centre.x + 10,
                        y: sin(0.01) * (q.x - centre.x) + cos(0.01) * (q.y - centre.y) + centre.y + 10)
        // Core Image counts y from the bottom.
        let moved = CGPoint(x: p.x, y: size.height - p.y).applying(RawRenderer.steadying(shift, size: size))
        XCTAssertEqual(moved.x, q.x, accuracy: 1e-6)
        XCTAssertEqual(moved.y, size.height - q.y, accuracy: 1e-6)
        XCTAssertEqual(RawRenderer.steadying(.zero, size: size), .identity)
    }

    func testStabilizeIsOffUnlessChosen() throws {
        let old = try JSONDecoder().decode(TimelapseSettings.self, from: Data(#"{"temporalDenoise":true}"#.utf8))
        XCTAssertFalse(old.stabilize)
        var settings = TimelapseSettings(); settings.stabilize = true
        XCTAssertTrue(try JSONDecoder().decode(TimelapseSettings.self, from: JSONEncoder().encode(settings)).stabilize)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
