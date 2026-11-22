import XCTest
import CevicheTestSupport
import CoreImage
import Metal
@testable import CevicheCore

/// Opt-in visual comparison of both fringe colors on the landscape sample.
final class DefringeVisualTests: XCTestCase {
    func testFringeComparisons() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CEVICHE_DEFRINGE_REVIEW_DIR"] else {
            throw XCTSkip("Set CEVICHE_DEFRINGE_REVIEW_DIR to retain visual comparisons")
        }
        let source = try TestSamples.require(TestSamples.landscape)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = try RawRenderer(sourceURL: source)
        try await renderer.fringeComparisons(output: output)
    }
}

private extension RawRenderer {
    func fringeComparisons(output: URL) throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var variants: [(String, Defringe)] = [("before", Defringe()), ("local-alignment-probe", Defringe())]
        var p = Defringe(); p.purpleAmount = 20; p.greenAmount = 20
        p.purpleLow = 0; p.purpleHigh = 100; p.greenLow = 0; p.greenHigh = 100
        variants.append(("hue-both-wide", p))
        for (name, defringe) in variants {
            var settings = info.defaults; settings.defringe = defringe
            var image = try pipeline(settings, maxDimension: nil)
            if name == "local-alignment-probe" {
                // Diagnostic offsets fitted to THIS crop, not production correction settings.
                // The numerical fit uses bitmap rows; Core Image's vertical sign is opposite.
                let combine = try XCTUnwrap(CIKernel.kernels(withMetalString: """
                #include <CoreImage/CoreImage.h>
                extern "C" [[stitchable]] float4 alignDiagnostic(coreimage::sample_t r,coreimage::sample_t g,coreimage::sample_t b) {
                    return float4(r.r,g.g,b.b,g.a);
                }
                """).first)
                image = try XCTUnwrap(combine.apply(extent: image.extent, roiCallback: { _, r in r }, arguments: [
                    image.transformed(by: CGAffineTransform(translationX: -1.4, y: 1.1)), image,
                    image.transformed(by: CGAffineTransform(translationX: -0.55, y: 0.1))]))
            }
            let corner = CGRect(x: image.extent.maxX - 1200, y: image.extent.minY, width: 1200, height: 900)
            let edge = CGRect(x: corner.minX + 250, y: corner.minY + 390, width: 480, height: 360)
            if name == "before", let rawImage = raw?.outputImage {
                var pixels = [Float](repeating: 0, count: 480 * 360 * 4)
                pixels.withUnsafeMutableBytes { context.render(rawImage, toBitmap: $0.baseAddress!, rowBytes: 480 * 16, bounds: edge, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) }
                try pixels.withUnsafeBytes { Data($0) }.write(to: output.appendingPathComponent("raw-edge.rgba32f"))
            }
            for (suffix, rect) in [("corner", corner), ("edge", edge)] {
                let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                try context.writePNGRepresentation(of: crop, to: output.appendingPathComponent(name + "-" + suffix + ".png"), format: .RGBA16, colorSpace: srgb)
            }
        }
    }
}
