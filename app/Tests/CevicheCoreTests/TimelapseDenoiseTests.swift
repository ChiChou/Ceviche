#if os(macOS)
import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class TimelapseDenoiseTests: XCTestCase {
    func testOptInAndLegacySettings() throws {
        XCTAssertFalse(TimelapseSettings().temporalDenoise)
        let legacy = try JSONDecoder().decode(TimelapseSettings.self, from: Data(#"{"codec":"hevc"}"#.utf8))
        XCTAssertFalse(legacy.temporalDenoise)
        var selected = legacy; selected.temporalDenoise = true
        XCTAssertEqual(try JSONDecoder().decode(TimelapseSettings.self, from: JSONEncoder().encode(selected)), selected)
    }

    func testWindowsRespectSequenceBoundaries() {
        var captures = (0..<8).map { TimelapseCapture(filename: "\($0)", date: Date(timeIntervalSince1970: Double($0 * 15)),
                                                    camera: "camera", size: CGSize(width: 6000, height: 4000)) }
        func window(_ i: Int) -> [Int] { TimelapseDenoiser.window(around: i, captures: captures, interval: 15) }
        XCTAssertEqual(window(0), [0, 1, 2]); XCTAssertEqual(window(3), [1, 2, 3, 4, 5]); XCTAssertEqual(window(7), [5, 6, 7])
        for i in 4..<8 { captures[i].date = captures[i].date!.addingTimeInterval(300) }
        XCTAssertEqual(window(3), [1, 2, 3]); XCTAssertEqual(window(4), [4, 5, 6])
        captures[5].camera = "other"
        XCTAssertEqual(window(4), [4]); XCTAssertEqual(window(5), [5])
        captures[5].camera = "camera"; captures[5].date = captures[4].date
        XCTAssertEqual(window(4), [4])
        captures[5].date = nil
        XCTAssertEqual(window(5), [5])
        captures[1].size = CGSize(width: 4000, height: 6000)
        XCTAssertEqual(window(0), [0])
        XCTAssertEqual(TimelapseDenoiser.window(around: 3, captures: captures, count: 1, interval: 15), [3])
        XCTAssertEqual(TimelapseDenoiser.window(around: 3, captures: captures, interval: nil), [3])
    }

    func testAlignmentAndCacheLimits() {
        let size = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(TimelapseDenoiser.fittingWindow(size: size, allowance: 1_100_000_000), 5)
        XCTAssertEqual(TimelapseDenoiser.fittingWindow(size: size, allowance: 800_000_000), 3)
        XCTAssertEqual(TimelapseDenoiser.fittingWindow(size: size, allowance: 500_000_000), 1)
        var alignment = NightSkyAlignment.identity; alignment.matches = 50
        XCTAssertTrue(TimelapseDenoiser.accepts(alignment, size: size))
        alignment.heldOutP95 = 0.8
        XCTAssertFalse(TimelapseDenoiser.accepts(alignment, size: size))
        alignment.heldOutP95 = 0.1
        alignment.inverse = NightSkyHomography([1, 0, 400, 0, 1, 0, 0, 0, 1])
        XCTAssertFalse(TimelapseDenoiser.accepts(alignment, size: size), "A moved camera starts a new view even if stars match")
    }

    private func pixels(_ photo: TimelapsePhoto, context: CIContext) -> [Float] {
        let w = CVPixelBufferGetWidth(photo.pixels), h = CVPixelBufferGetHeight(photo.pixels)
        var values = [Float](repeating: 0, count: w * h * 4)
        values.withUnsafeMutableBytes {
            context.render(photo.image, toBitmap: $0.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: TimelapsePhoto.space)
        }
        return values
    }

    func testProductionMergePreservesGroundTransientsHDRAndOrientation() throws {
        let w = 192, h = 128, size = CGSize(width: w, height: h), sigma: Float = 0.003
        let gpu = try TimelapseDenoiseGPU(size: size)
        var state: UInt64 = 61741
        func uniform() -> Double { state = state &* 6364136223846793005 &+ 1; return Double(state >> 11) / Double(UInt64(1) << 53) }
        func normal() -> Float { Float(sqrt(-2 * log(max(1e-10, uniform()))) * cos(2 * .pi * uniform())) }
        // Bitmap rows run top to bottom; Core Image rectangles use a bottom-left origin. An asymmetric signal detects flips.
        let sky = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: h / 2, width: w, height: h / 2))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        var prepared: [TimelapseDenoiseGPU.Frame] = [], originals: [[Float]] = []
        for i in 0..<5 {
            var values = [Float](repeating: 1, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                for c in 0..<3 {
                    let signal: Float = y >= h / 2 ? 0.2 : (x > 160 ? 3 : 0.04)
                    values[(y * w + x) * 4 + c] = signal + sigma * normal()
                }
            } }
            // A thin bright event in the current frame alone; other moments must not acquire a ghost of it.
            if i == 2 { for y in 15..<45 { for c in 0..<3 { values[(y * w + 96) * 4 + c] = 0.8 } } }
            // A moving patch, separated by more than its width between captures.
            for y in 15..<30 { for x in (110 + i * 15)..<(118 + i * 15) { for c in 0..<3 {
                values[(y * w + x) * 4 + c] = 0.7
            } } }
            let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16, size: size, format: .RGBAf, colorSpace: TimelapsePhoto.space)
            let photo = try TimelapsePhoto.render(image, size: size, context: gpu.context)
            originals.append(pixels(photo, context: gpu.context))
            let frame = try gpu.prepare(photo, skyOverride: sky)
            prepared.append(.init(pixels: frame.pixels, means: frame.means, sky: frame.sky, stars: frame.stars, sigma: SIMD3(repeating: sigma)))
        }
        let merged = try gpu.photo(gpu.merge(reference: prepared[2], neighbors: [0, 1, 3, 4].map { .init(frame: prepared[$0], alignment: .identity) }))
        let output = pixels(merged, context: gpu.context), reference = originals[2]
        var before = 0.0, after = 0.0
        for y in 8..<55 { for x in 10..<75 {
            before += pow(Double(reference[(y * w + x) * 4] - 0.04), 2)
            after += pow(Double(output[(y * w + x) * 4] - 0.04), 2)
        } }
        XCTAssertLessThan(after, before * 0.35, "Static sky improves, without a spatial blur")
        var groundError: Float = 0
        for y in h / 2..<h { for x in 0..<w { for c in 0..<3 {
            let k = (y * w + x) * 4 + c
            groundError = max(groundError, abs(output[k] - reference[k]))
        } } }
        XCTAssertLessThan(groundError, 0.00001)
        XCTAssertGreaterThan(output[(30 * w + 180) * 4], 2.9, "HDR is not clipped at SDR white")
        XCTAssertEqual(output[(30 * w + 96) * 4], reference[(30 * w + 96) * 4], accuracy: 0.00001)
        XCTAssertEqual(output[(20 * w + 143) * 4], reference[(20 * w + 143) * 4], accuracy: 0.00001)
        XCTAssertLessThan(output[(20 * w + 113) * 4], 0.055, "An earlier moving patch must not leave a ghost")
        let next = pixels(try gpu.photo(gpu.merge(reference: prepared[3], neighbors: [.init(frame: prepared[2], alignment: .identity)])), context: gpu.context)
        XCTAssertEqual(next[(30 * w + 96) * 4], originals[3][(30 * w + 96) * 4], accuracy: 0.00001)
        let fallback = pixels(try gpu.photo(gpu.merge(reference: prepared[2], neighbors: [])), context: gpu.context)
        XCTAssertEqual(fallback, reference, "No usable neighbors returns the current photo, including its orientation")
        // A later merge cannot mutate an output retained for capture-time blending.
        XCTAssertEqual(pixels(merged, context: gpu.context), output)
    }

    func testCancellationStopsPreparation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let gpu = try TimelapseDenoiseGPU(size: CGSize(width: 32, height: 32))
            return try gpu.photo(gpu.texture())
        }
        do { _ = try await task.value; XCTFail("Cancelled work must not render an output") }
        catch is CancellationError { }
    }

    func testSkyMasksAreComputedOnceStoredOnDiskAndCleanedUp() throws {
        let context = CIContext(), size = CGSize(width: 32, height: 16)
        var directory: URL?
        try autoreleasepool {
            let cache = try TimelapseSkyCache(); directory = cache.directory
            var calls = 0
            func make() -> CIImage {
                calls += 1
                let probabilities = [Float](repeating: 0.75, count: 32 * 16)
                return CIImage(bitmapData: probabilities.withUnsafeBytes { Data($0) }, bytesPerRow: 32 * 4,
                               size: size, format: .Rf, colorSpace: nil)
            }
            let first = try cache.mask(key: "source/edit/crop", context: context, make: make)
            let second = try cache.mask(key: "source/edit/crop", context: context, make: make)
            XCTAssertEqual(calls, 1, "Revisiting an evicted photo or a new encoder pass must reuse its mask")
            func values(_ image: CIImage) -> [Float] {
                var result = [Float](repeating: 0, count: 32 * 16)
                result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 32 * 4,
                    bounds: CGRect(origin: .zero, size: size), format: .Rf, colorSpace: nil) }
                return result
            }
            XCTAssertEqual(values(first), values(second))
            XCTAssertEqual(values(second)[0], 0.75, accuracy: 0.001)
            let files = try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: files[0]).count, 8 + 32 * 16 * 2)
            _ = try cache.mask(key: "source/changed-edit/crop", context: context, make: make)
            XCTAssertEqual(calls, 2, "Different edits/crops must not reuse stale masks")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory).path))
    }
}
#endif
