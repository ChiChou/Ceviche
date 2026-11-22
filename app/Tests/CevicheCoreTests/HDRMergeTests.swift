import XCTest
import CevicheTestSupport
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import CevicheCore

final class HDRMergeTests: XCTestCase {
    /// A scene with radiance from 0.005 to 5 (about 10 stops), with irregular texture so alignment has corners to find.
    private func scene(width: Int, height: Int, x: Double, y: Double) -> SIMD3<Float> {
        let u = x / Double(width), v = y / Double(height)
        let ramp = 0.005 * pow(1000, u)
        var texture = 0.75
        for k in 0..<24 {
            let cx = Double((k * 7919) % width), cy = Double((k * 104_729) % height), radius = 18 + Double((k * 31) % 40)
            if hypot(x - cx, y - cy) < radius { texture += k % 2 == 0 ? 0.2 : -0.25 }
            if abs(x - cx) < radius * 1.5, abs(y - cy - radius * 2) < 4 { texture += 0.15 }
        }
        let r = ramp * max(0.3, texture)
        return SIMD3(Float(r), Float(r * (0.8 + 0.2 * v)), Float(r * 0.7))
    }

    /// Writes 16-bit linear TIFF brackets of `scene` at the given stops, clipped at 1, shifted by `shifts`.
    private func writeBrackets(_ stops: [Double], shifts: [SIMD2<Double>], width: Int = 900, height: Int = 600,
                               moving: Int? = nil, in directory: URL) throws -> [URL] {
        try stops.enumerated().map { k, stop in
            var pixels = [UInt16](repeating: 0, count: width * height * 3)
            for y in 0..<height { for x in 0..<width {
                var radiance = scene(width: width, height: height, x: Double(x) + shifts[k].x, y: Double(y) + shifts[k].y)
                // Something in one bracket that isn't in the others, like a passer-by.
                if k == moving, (400..<520).contains(x), (250..<400).contains(y) { radiance = SIMD3(0.02, 0.3, 0.02) }
                let value = simd_min(radiance * Float(exp2(stop)), SIMD3(repeating: 1))
                for c in 0..<3 { pixels[(y * width + x) * 3 + c] = UInt16((value[c] * 65535).rounded()) }
            }}
            let url = directory.appendingPathComponent("bracket-\(k).tif")
            let provider = CGDataProvider(data: pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                                space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HDRMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testSimilarityFitRecoversTransform() throws {
        let truth = HDRSimilarity(linear: simd_double2x2(columns: (SIMD2(cos(0.02), sin(0.02)), SIMD2(-sin(0.02), cos(0.02)))) * 1.01,
                                  translation: SIMD2(12.5, -7.25))
        let matches = (0..<40).map { i -> PanoramaMatch in
            let p = SIMD2(Double(i * 37 % 900), Double(i * 53 % 600))
            return PanoramaMatch(a: p, b: truth.apply(p), distance: 0)
        }
        let fitted = try XCTUnwrap(HDRMergeAlignment.fit(matches))
        XCTAssertEqual(fitted.rotationDegrees, 0.02 * 180 / .pi, accuracy: 1e-6)
        XCTAssertEqual(fitted.scale, 1.01, accuracy: 1e-9)
        XCTAssertLessThan(simd_distance(fitted.translation, truth.translation), 1e-6)
        XCTAssertLessThan(simd_distance(fitted.inverse.apply(truth.apply(SIMD2(5, 9))), SIMD2(5, 9)), 1e-9)
    }

    func testMergeMeasuresExposuresAlignsAndRecoversRange() throws {

        try TestTier.requireSlow()
        let directory = try temporaryDirectory()
        let urls = try writeBrackets([-3, 0, 2], shifts: [SIMD2(3, -2), .zero, SIMD2(-4, 1)], in: directory)
        let merger = try HDRMerger(urls: urls)
        let analysis = try merger.analyze()
        XCTAssertEqual(analysis.frames.map(\.index), [0, 1, 2])
        XCTAssertEqual(analysis.suggestedReference, 1)
        XCTAssertEqual(analysis.frames[1].stops, 3, accuracy: 0.05)
        XCTAssertEqual(analysis.frames[2].stops, 5, accuracy: 0.05)
        // The shifted brackets are found within a pixel: each transform maps the bracket onto the reference.
        let shift0 = try XCTUnwrap(analysis.frames[0].shift), shift2 = try XCTUnwrap(analysis.frames[2].shift)
        XCTAssertLessThan(simd_distance(shift0, SIMD2(3, -2)), 1)
        XCTAssertLessThan(simd_distance(shift2, SIMD2(-4, 1)), 1)

        var settings = HDRMergeSettings(); settings.deghosting = .off
        let output = directory.appendingPathComponent("merged.dng")
        try merger.merge(settings, to: output)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: output))
        XCTAssertEqual(Int(raw.nativeSize.width), 900)
        XCTAssertEqual(Int(raw.nativeSize.height), 600)
        // The scene at the reference exposure, including what the reference itself clipped (right) or lost in noise (left).
        let values = try mergedRaster(merger, settings)
        for (x, y) in [(60, 300), (450, 300), (840, 300), (870, 120)] {
            let truth = scene(width: 900, height: 600, x: Double(x) + 0.5, y: Double(y) + 0.5)
            let merged = values(x, y)
            XCTAssertEqual(log2(merged.y / truth.y), 0, accuracy: 0.12, "at \(x), \(y): \(merged) vs \(truth)")
        }
    }

    /// The merged linear values at analysis size (the full size for these small brackets).
    private func mergedRaster(_ merger: HDRMerger, _ settings: HDRMergeSettings) throws -> (Int, Int) -> SIMD3<Float> {
        let raster = try merger.previewRaster(settings)
        return { x, y in
            let p = (y * raster.width + x) * 4
            return SIMD3(raster.rgba[p], raster.rgba[p + 1], raster.rgba[p + 2])
        }
    }

    func testDeghostingTakesMovingAreaFromReference() throws {

        try TestTier.requireSlow()
        let directory = try temporaryDirectory()
        let urls = try writeBrackets([-1.5, 0, 1.5], shifts: [.zero, .zero, .zero], moving: 2, in: directory)
        let merger = try HDRMerger(urls: urls)
        _ = try merger.analyze()
        var settings = HDRMergeSettings()
        settings.deghosting = .off
        let ghosted = try mergedRaster(merger, settings)(460, 320)
        settings.deghosting = .medium
        let preview = try merger.preview(settings)
        XCTAssertGreaterThan(preview.motionCoverage, 0.02)
        let clean = try mergedRaster(merger, settings)(460, 320)
        let truth = scene(width: 900, height: 600, x: 460.5, y: 320.5)
        XCTAssertGreaterThan(abs(log2(ghosted.y / truth.y)), 0.3, "the passer-by should show without deghosting")
        XCTAssertEqual(log2(clean.y / truth.y), 0, accuracy: 0.1)
    }

    /// Painting a layer in takes the area from that exposure alone, passer-by and all; painting it out leaves the area to
    /// the others. The layers' shares add up to the whole picture.
    func testLayerBrushAddsAndRemovesExposure() throws {
        try TestTier.requireSlow()
        let directory = try temporaryDirectory()
        let urls = try writeBrackets([-1.5, 0, 1.5], shifts: [.zero, .zero, .zero], moving: 2, in: directory)
        let merger = try HDRMerger(urls: urls)
        _ = try merger.analyze()
        let truth = scene(width: 900, height: 600, x: 460.5, y: 320.5)
        let passerBy: Float = 0.3
        let dab = { (add: Bool) in HDRMergeStroke(x: 460.5 / 900, y: 325.5 / 900, radius: 40 / 900, photo: 2, add: add) }

        var settings = HDRMergeSettings()
        settings.deghosting = .medium
        settings.strokes = [dab(true)]
        let added = try mergedRaster(merger, settings)(460, 320)
        XCTAssertEqual(log2(added.y / passerBy), 0, accuracy: 0.1, "painted in: \(added)")
        let preview = try merger.preview(settings)
        XCTAssertEqual(preview.layers.count, 3)
        XCTAssertEqual(preview.contributions.values.reduce(0, +), 1, accuracy: 0.01)

        settings.deghosting = .off
        settings.strokes = [dab(false)]
        let removed = try mergedRaster(merger, settings)(460, 320)
        XCTAssertEqual(log2(removed.y / truth.y), 0, accuracy: 0.1, "painted out: \(removed)")
        // A later dab wins: painted in, then out again, the area is the blend's once more.
        settings.strokes = [dab(true), dab(false)]
        XCTAssertEqual(log2(try mergedRaster(merger, settings)(460, 320).y / truth.y), 0, accuracy: 0.1)
    }

    /// The GPU blend is the CPU's arithmetic: shifted brackets with deghosting and per-tone responses agree closely.
    func testGPUMergeMatchesCPU() throws {
        try TestTier.requireSlow()
        let directory = try temporaryDirectory()
        let urls = try writeBrackets([-3, 0, 2], shifts: [SIMD2(3, -2), .zero, SIMD2(-4, 1)], moving: 2, in: directory)
        let merger = try HDRMerger(urls: urls)
        _ = try merger.analyze()
        var settings = HDRMergeSettings()
        for strokes in [[], [HDRMergeStroke(x: 0.5, y: 0.35, radius: 0.06, photo: 2, add: true),
                             HDRMergeStroke(x: 0.2, y: 0.3, radius: 0.08, photo: 0, add: false),
                             HDRMergeStroke(x: 0.55, y: 0.35, radius: 0.03, photo: 1, add: true)]] {
            settings.strokes = strokes
            let cpu = try merger.mergedRaster(settings, engine: .cpu).0
            let gpu: PanoramaRaster
            do { gpu = try merger.mergedRaster(settings, engine: .gpu).0 } catch { throw XCTSkip("No GPU: \(error)") }
            XCTAssertEqual(gpu.width, cpu.width); XCTAssertEqual(gpu.height, cpu.height)
            let difference = Self.difference(cpu, gpu)
            XCTAssertLessThan(difference.worst, 1e-3, "\(strokes.count) dabs: worst relative difference \(difference)")
        }
    }

    /// Relative difference per channel, ignoring values in the noise floor.
    static func difference(_ a: PanoramaRaster, _ b: PanoramaRaster) -> (worst: Float, mean: Double, over1e3: Int) {
        var worst: Float = 0, total = 0.0, over = 0
        for i in a.rgba.indices where i % 4 != 3 {
            let d = abs(a.rgba[i] - b.rgba[i]) / max(abs(a.rgba[i]), 1e-3)
            worst = max(worst, d); total += Double(d); if d > 1e-3 { over += 1 }
        }
        return (worst, total / Double(a.rgba.count * 3 / 4), over)
    }

    func testDifferentSizesAreRefused() throws {
        let first = try writeBrackets([0], shifts: [.zero], width: 64, height: 48, in: try temporaryDirectory())
        let second = try writeBrackets([1], shifts: [.zero], width: 48, height: 64, in: try temporaryDirectory())
        XCTAssertThrowsError(try HDRMerger(urls: first + second).analyze())
        XCTAssertThrowsError(try HDRMerger(urls: first))
    }
}
