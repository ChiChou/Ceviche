import XCTest
import CevicheTestSupport
import CoreImage
@testable import CevicheCore

/// Runs when the compiled NAFNet model is available (CEVICHE_MODELS=…/models/build/compiled); skipped otherwise.
final class AIDenoiseTests: XCTestCase {
    private var dusk: URL {
        TestSamples.url(TestSamples.developedSidecar)
    }
    /// Mean absolute difference from the 3×3 neighbourhood mean: high-frequency energy, which noise dominates in flat sky.
    private func roughness(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func luma(_ x: Int, _ y: Int) -> Double { let i = (y * w + x) * 4; return 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2]) }
        var total = 0.0, count = 0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            var mean = 0.0; for j in -1...1 { for i in -1...1 { mean += luma(x + i, y + j) } }
            total += abs(luma(x, y) - mean / 9); count += 1
        } }
        return total / Double(count)
    }
    func testExportDenoiseSmoothsSkyNoise() async throws {
        try TestTier.requireSlow("NAFNet on a full RAW")
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        _ = try TestSamples.require(TestSamples.developedSidecar)
        let renderer = try RawRenderer(sourceURL: dusk)
        var noisy = renderer.info.defaults; noisy.exposure = 3; noisy.noiseReduction = 0; noisy.colorNoiseReduction = 0
        let plain = ExportSettings()
        var cleaned = plain; cleaned.aiDenoise = 100
        // A flat patch of sky near the top of the frame, at export resolution.
        let region = CGRect(x: 0.45, y: 0.05, width: 0.06, height: 0.06)
        let plainJob = try await renderer.prepareExportDetail(noisy, settings: plain, region: region)
        let before = try XCTUnwrap(plainJob).render().image
        let cleanedJob = try await renderer.prepareExportDetail(noisy, settings: cleaned, region: region)
        let after = try XCTUnwrap(cleanedJob).render().image
        let r0 = roughness(before), r1 = roughness(after)
        XCTAssertLessThan(r1, r0 * 0.6)
    }
    /// Colors outside sRGB have negative working-space channels; the network sees them clamped, but only its change is applied.
    func testDenoiseKeepsColorsOutsideSRGB() throws {
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = CIImage(color: CIColor(red: 0.6, green: -0.08, blue: 0.05, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 96, height: 96))
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(try NAFNetDenoiseKernel.denoised(image, amount: 100), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 48, y: 48, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        XCTAssertEqual(pixel[1], -0.08, accuracy: 0.01)
        XCTAssertEqual(pixel[0], 0.6, accuracy: 0.01)
    }
    /// A preview's run keeps the tiles: the next render of the same picture skips the network and gives the same pixels,
    /// and the progress it reports climbs to the whole.
    func testRunKeepsTilesAndReportsProgress() throws {
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let width = 1200, height = 800
        var generator = SystemRandomNumberGenerator()
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) { for c in 0..<3 { pixels[i * 4 + c] = 0.2 + Float.random(in: -0.05...0.05, using: &generator) } }
        let image = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        func render(_ run: DenoiseRun) throws -> (pixels: [Float], seconds: Double) {
            let start = Date()
            var out = [Float](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes { context.render(try! NAFNetDenoiseKernel.denoised(image, amount: 100, run: run), toBitmap: $0.baseAddress!, rowBytes: width * 16,
                                                        bounds: image.extent, format: .RGBAf, colorSpace: linear) }
            return (out, Date().timeIntervalSince(start))
        }
        let reports = Reports()
        let first = try render(DenoiseRun { reports.add($0) })
        XCTAssertEqual(try XCTUnwrap(reports.values.last), 1, accuracy: 0.001)
        XCTAssertEqual(reports.values, reports.values.sorted(), "progress only climbs")
        let run = DenoiseRun(keepsTiles: true)
        let fresh = try render(run), kept = try render(run)
        func difference(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) } }
        // A tile runs on the Neural Engine or the GPU, which differ in the last bits; a kept tile is the same one, as
        // half floats.
        XCTAssertLessThan(difference(fresh.pixels, first.pixels), 0.01)
        XCTAssertLessThan(difference(kept.pixels, fresh.pixels), 0.001)
        XCTAssertLessThan(kept.seconds, fresh.seconds / 3, "the kept tiles skip the network")
    }
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Double] = []
        func add(_ value: Double) { lock.withLock { stored.append(value) } }
        var values: [Double] { lock.withLock { stored } }
    }
}
