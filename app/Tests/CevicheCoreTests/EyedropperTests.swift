import XCTest
import CoreImage
import Metal
import CevicheTestSupport
@testable import CevicheCore

final class EyedropperTests: XCTestCase {
    private var sample: URL {
        TestSamples.url(TestSamples.landscape)
    }
    func testPickedWhiteBalanceNeutralizesTheSpot() async throws {
        _ = try TestSamples.require(TestSamples.landscape)
        let renderer = try RawRenderer(sourceURL: sample)
        var adjustments = renderer.info.defaults
        let point = MaskPoint(x: 0.5, y: 0.5)
        func spread(_ rgb: [Double]) -> Double { (rgb.max()! - rgb.min()!) / max(0.001, rgb.reduce(0, +) / 3) }
        let before = try await renderer.sampleColor(at: point, adjustments: adjustments, radius: 2)
        let balance = try await renderer.neutralWhiteBalance(at: point, adjustments: adjustments)
        let picked = try XCTUnwrap(balance.map { (temperature: $0.temperature, tint: $0.tint) })
        adjustments.temperature = picked.temperature; adjustments.tint = picked.tint
        let after = try await renderer.sampleColor(at: point, adjustments: adjustments, radius: 2)
        XCTAssertLessThan(spread(after), max(0.06, spread(before) * 0.5), "before \(before) after \(after) wb \(picked)")
    }

    func testDefringePicksNativeRimBeforeCorrection() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let context = CIContext(mtlDevice: device)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let field = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 4400, height: 16))
        let rim = CIImage(color: CIColor(red: 0.8, green: 0.25, blue: 0.9))
            .cropped(to: CGRect(x: 2201, y: 4, width: 1, height: 1)).composited(over: field)
        try context.writePNGRepresentation(of: rim, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let renderer = try RawRenderer(sourceURL: url)
        var a = renderer.info.defaults
        let point = MaskPoint(x: 2201.5 / 4400, y: 4.5 / 16)
        let initialSample = try await renderer.sampleDefringe(at: point, band: .purple, adjustments: a)
        let range = try XCTUnwrap(initialSample)
        XCTAssertTrue(range.contains(37))
        XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound, 17)
        a.defringe.setPickedRange(range, for: .purple)
        XCTAssertGreaterThan(a.defringe.purpleAmount, 0)
        XCTAssertEqual(a.defringe.greenAmount, 0)
        a.defringe.purpleAmount = 20
        a.defringe.setPickedRange(range, for: .purple)
        XCTAssertEqual(a.defringe.purpleAmount, 20)
        a.quarterTurns = 1
        let correctedSample = try await renderer.sampleDefringe(at: point, band: .purple, adjustments: a)
        XCTAssertEqual(correctedSample, range)
        let wrongBand = try await renderer.sampleDefringe(at: point, band: .green, adjustments: a)
        XCTAssertNil(wrongBand)
        let neutral = try await renderer.sampleDefringe(at: MaskPoint(x: 0.25, y: 0.75), band: .purple, adjustments: a)
        XCTAssertNil(neutral)
    }
}
