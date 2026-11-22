import XCTest
import CevicheTestSupport
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import CevicheCore

final class PhotoStackTests: XCTestCase {
    func testMedianSelectsMiddleValue() {
        var odd: [Float] = [5, 1, 9, 3, 7]
        XCTAssertEqual(PhotoStackReduce.median(&odd, 5), 5)
        var even: [Float] = [8, 2, 6, 4]
        XCTAssertEqual(PhotoStackReduce.median(&even, 4), 5)
        var repeated: [Float] = [2, 2, 2, 9, 2, 2]
        XCTAssertEqual(PhotoStackReduce.median(&repeated, 6), 2)
        // Only the first n values count.
        var prefix: [Float] = [3, 1, 2, 100, 100]
        XCTAssertEqual(PhotoStackReduce.median(&prefix, 3), 2)
    }

    func testReduceModesSkipUncoveredSamples() {
        let samples: [SIMD3<Float>?] = [SIMD3(1, 2, 3), nil, SIMD3(3, 6, 1), SIMD3(2, 4, 2)]
        var scratch = PhotoStackReduce.Scratch(count: samples.count)
        func reduce(_ mode: PhotoStackMode) -> SIMD3<Float> { PhotoStackReduce.pixel(mode, count: samples.count, scratch: &scratch) { samples[$0] } }
        XCTAssertEqual(reduce(.median), SIMD3(2, 4, 2))
        XCTAssertEqual(reduce(.mean), SIMD3(2, 4, 2))
        XCTAssertEqual(reduce(.maximum), SIMD3(3, 6, 3))
        XCTAssertEqual(reduce(.minimum), SIMD3(1, 2, 1))
        XCTAssertEqual(PhotoStackReduce.pixel(.median, count: 2, scratch: &scratch) { _ in nil }, .zero)
    }

    /// Action Sequence shows each subject whole from its own photo: where two overlap, one is left out instead of the
    /// two being mixed, and Overlaps decides which.
    func testSequenceChoosesWholeRegions() {
        let width = 200, height = 120
        let background = [Float](repeating: 0.3, count: width * height * 4)
        func frame(_ x0: Int, _ value: Float) -> [Float] {
            var pixels = [Float](repeating: 0.3, count: width * height * 4)
            for i in 0..<(width * height) { pixels[i * 4 + 3] = 1 }
            for y in 40..<80 { for x in x0..<(x0 + 40) { for c in 0..<3 { pixels[(y * width + x) * 4 + c] = value } } }
            return pixels
        }
        // Photo 0's subject is the strongest; photo 1's covers half of it; photo 2's stands apart.
        let frames = [frame(40, 0.9), frame(60, 0.05), frame(140, 0.6)]
        func choose(_ overlap: PhotoStackOverlap) -> PhotoStackRegions.Choice {
            PhotoStackRegions.choose(frames: frames, gains: [1, 1, 1], photos: [0, 1, 2], background: background, width: width, height: height, overlap: overlap)
        }
        for (overlap, shown) in [(PhotoStackOverlap.strongest, [0, 2]), (.earliest, [0, 2]), (.latest, [1, 2])] {
            let choice = choose(overlap)
            XCTAssertEqual(choice.planes.keys.sorted(), shown, "\(overlap)")
            XCTAssertEqual(choice.leftOut, 1)
            // The winner is whole, including the half the other covers, and nothing sums past 1.
            let winner = choice.planes[shown[0]]!
            for x in (shown[0] == 0 ? [45, 60, 75] : [65, 80, 95]) { XCTAssertEqual(winner[60 * width + x], 1, "\(overlap) at x \(x)") }
            XCTAssertEqual(choice.planes[2]![60 * width + 155], 1)
            for i in 0..<(width * height) { XCTAssertLessThanOrEqual(choice.planes.values.reduce(0) { $0 + $1[i] }, 1.0001) }
            XCTAssertEqual(winner[20 * width + 60], 0, "the scene away from the subjects stays the background's")
        }
        // Noise alone makes no region.
        var noisy = frame(0, 0.3)
        for i in stride(from: 0, to: noisy.count, by: 4) { noisy[i] += Float(i % 7) * 0.002 }
        let still = PhotoStackRegions.choose(frames: [noisy, noisy], gains: [1, 1], photos: [0, 1], background: background, width: width, height: height, overlap: .strongest)
        XCTAssertTrue(still.planes.isEmpty)
    }

    /// Lighten adds a pass's light without collecting the brightest noise of every pass, which the plain maximum
    /// does; strength, the brush and Strokes Only each hold a pass's light back, and Darken mirrors it.
    func testLightenKeepsTheShadowsWhereTheyAre() {
        let width = 256, height = 192, count = width * height
        var state: UInt64 = 0x9E3779B97F4A7C15
        func uniform() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(state >> 40) / Float(1 << 24) }
        func gaussian() -> Float { (-2 * log(max(uniform(), 1e-7))).squareRoot() * cos(2 * .pi * uniform()) }
        func level(_ i: Int) -> Float { 0.004 + 0.016 * Float(i % width) / Float(width) }
        func patch(_ i: Int) -> Bool { (100..<140).contains(i % width) && (60..<100).contains(i / width) }
        /// One exposure of the scene with its own noise; `light` is what the pass adds.
        func frame(_ light: (Int) -> Float = { _ in 0 }) -> [Float] {
            var pixels = [Float](repeating: 1, count: count * 4)
            for i in 0..<count {
                let truth = level(i) + light(i)
                for c in 0..<3 { pixels[i * 4 + c] = max(0, truth + gaussian() * (0.0004 + 0.25 * level(i))) }
            }
            return pixels
        }
        func blended(_ frames: [[Float]], passes: [PhotoStackBlend.Pass]? = nil, darken: Bool = false, strokesOnly: Bool = false) -> [Float] {
            let rows: PhotoStackBlend.Rows = { k, y, row in frames[k].withUnsafeBufferPointer { row.update(from: $0.baseAddress! + y * width * 4, count: width * 4) } }
            let noise = PhotoStackBlend.noise(frames: frames.count, rows: rows, width: width, height: height, radius: 4)
            var out = [Float](repeating: 0, count: count * 4)
            out.withUnsafeMutableBufferPointer {
                PhotoStackBlend.blend(passes: passes ?? .init(repeating: .init(), count: frames.count - 1), rows: rows, width: width, height: height, radius: 4,
                                      noise: noise, darken: darken, strokesOnly: strokesOnly, into: $0.baseAddress!)
            }
            return out
        }
        /// Mean green over the patch's middle, or over the shadows well away from it.
        func mean(_ pixels: [Float], inPatch: Bool) -> Float {
            var sum: Float = 0, n: Float = 0
            for i in 0..<count {
                let x = i % width, y = i / width
                let inside = (108..<132).contains(x) && (68..<92).contains(y), away = y > 120 && y < height - 8 && x > 8 && x < width - 8
                if inPatch ? inside : away { sum += pixels[i * 4 + 1]; n += 1 }
            }
            return sum / n
        }
        var truth = [Float](repeating: 1, count: count * 4)
        for i in 0..<count { for c in 0..<3 { truth[i * 4 + c] = level(i) } }

        var frames = (0..<6).map { _ in frame() }
        frames[3] = frame { patch($0) ? 0.3 : 0 }
        let soft = blended(frames)
        var plain = frames[0]
        for f in frames.dropFirst() { for i in 0..<plain.count { plain[i] = max(plain[i], f[i]) } }
        XCTAssertGreaterThan(log2(mean(plain, inPatch: false) / mean(truth, inPatch: false)), 0.3, "the plain maximum lifts the shadows")
        XCTAssertEqual(log2(mean(soft, inPatch: false) / mean(truth, inPatch: false)), 0, accuracy: 0.06, "the soft maximum doesn't")
        XCTAssertEqual(mean(soft, inPatch: true), mean(truth, inPatch: true) + 0.3, accuracy: 0.01, "a clearly brighter pass wins outright")

        // Half strength adds half the light; brushed out, none.
        var passes = [PhotoStackBlend.Pass](repeating: .init(), count: 5)
        passes[2].strength = 0.5
        XCTAssertEqual(mean(blended(frames, passes: passes), inPatch: true), mean(truth, inPatch: true) + 0.15, accuracy: 0.01)
        passes[2] = .init(strength: 1, hidden: [Float](repeating: 1, count: 64 * 48), hiddenWidth: 64)
        XCTAssertEqual(mean(blended(frames, passes: passes), inPatch: true), mean(truth, inPatch: true), accuracy: 0.004)

        // Strokes Only drops a pass's faint spill and keeps its stroke.
        frames[3] = frame { patch($0) ? 0.3 : 0.006 }
        XCTAssertGreaterThan(mean(blended(frames), inPatch: false), mean(truth, inPatch: false) + 0.004)
        let strokes = blended(frames, strokesOnly: true)
        XCTAssertEqual(mean(strokes, inPatch: false), mean(truth, inPatch: false), accuracy: 0.001)
        XCTAssertEqual(mean(strokes, inPatch: true), mean(truth, inPatch: true) + 0.3, accuracy: 0.01)

        // Darken: the pass's shadow shows, and the rest isn't pulled down as the plain minimum pulls it.
        frames[3] = frame { patch($0) ? -0.8 * level($0) : 0 }
        let dark = blended(frames, darken: true)
        XCTAssertEqual(mean(dark, inPatch: true), 0.2 * mean(truth, inPatch: true), accuracy: 0.002)
        XCTAssertEqual(log2(mean(dark, inPatch: false) / mean(truth, inPatch: false)), 0, accuracy: 0.06)
    }

    /// A long exposure with the ground kept: the sky is the mean's, and below it the median's or the base photo's.
    func testLongExposureKeepsTheGround() throws {
        try TestTier.requireSlow("Sky model on a RAW series")
        let directory = try TestSamples.requireFolder(TestSamples.tripodSequence)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(5)
        let stacker = try PhotoStacker(urls: Array(urls))
        let analysis = try stacker.analyze()
        var settings = PhotoStackSettings()
        settings.mode = .mean
        let mean = try stacker.previewRaster(settings)
        settings.mode = .median
        let median = try stacker.previewRaster(settings)
        settings.mode = .mean; settings.ground = .median
        let kept: PanoramaRaster
        do { kept = try stacker.previewRaster(settings) } catch { throw XCTSkip("No sky model: \(error.localizedDescription)") }
        // Open sky at the top of the frame, the plaza at the bottom.
        let width = kept.width, sky = (kept.height / 12 * width + width / 2) * 4, plaza = (kept.height * 15 / 16 * width + width / 2) * 4
        for c in 0..<3 {
            XCTAssertEqual(kept.rgba[sky + c], mean.rgba[sky + c], accuracy: 0.02 * mean.rgba[sky + c] + 1e-4, "the sky blends")
            XCTAssertEqual(kept.rgba[plaza + c], median.rgba[plaza + c], accuracy: 0.02 * median.rgba[plaza + c] + 1e-4, "the ground is the median's")
        }
        let planes = try stacker.weights(settings, included: Array(0..<5)).planes
        XCTAssertEqual(Array(planes.keys), [PhotoStackRegions.median])
        let share = planes[PhotoStackRegions.median]!.reduce(0, +) / Float(planes[PhotoStackRegions.median]!.count)
        XCTAssertGreaterThan(share, 0.2); XCTAssertLessThan(share, 0.6, "the sky is most of this frame")
        // At full size the same picture: the mean of a patch of sky and of plaza agree with the preview's.
        let full = try stacker.stackedRaster(settings)
        func patch(_ raster: PanoramaRaster, _ fx: Double, _ fy: Double) -> Float {
            let r = max(2, raster.width / 200), cx = Int(fx * Double(raster.width)), cy = Int(fy * Double(raster.height))
            var sum: Float = 0
            for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) { sum += raster.rgba[(y * raster.width + x) * 4 + 1] } }
            return sum / Float((2 * r + 1) * (2 * r + 1))
        }
        for (fx, fy) in [(0.5, 1.0 / 12), (0.5, 15.0 / 16)] {
            XCTAssertEqual(patch(full, fx, fy), patch(kept, fx, fy), accuracy: 0.05 * patch(kept, fx, fy), "full size at \(fx), \(fy)")
        }
        settings.ground = .base
        XCTAssertEqual(Array(try stacker.weights(settings, included: Array(0..<5)).planes.keys), [analysis.reference])
        // The brush gives part of the ground back to the stack.
        settings.strokes = [PhotoStackStroke(x: 0.5, y: 15.0 / 16 * Double(kept.height) / Double(width), radius: 0.05, photo: nil)]
        let brushed = try stacker.previewRaster(settings)
        XCTAssertEqual(brushed.rgba[plaza + 1], mean.rgba[plaza + 1], accuracy: 0.02 * mean.rgba[plaza + 1] + 1e-4)
    }

    /// Sigma clipping averages the noisy samples and leaves out the one bright passer-by.
    func testClippedMean() {
        let background: [SIMD3<Float>] = [0.200, 0.204, 0.198, 0.202, 0.196, 0.201, 0.199].map { SIMD3(repeating: $0) }
        var samples = background
        samples[3] = SIMD3(0.9, 0.8, 0.7)
        var scratch = PhotoStackReduce.Scratch(count: samples.count)
        let clipped = PhotoStackReduce.pixel(.clippedMean, count: samples.count, scratch: &scratch) { samples[$0] }
        let expected = (background.reduce(.zero, +) - background[3]) / Float(background.count - 1)
        XCTAssertEqual(clipped.x, expected.x, accuracy: 1e-5)
        XCTAssertLessThan(PhotoStackReduce.pixel(.mean, count: samples.count, scratch: &scratch) { samples[$0] }.x, 0.3)
        XCTAssertGreaterThan(PhotoStackReduce.pixel(.mean, count: samples.count, scratch: &scratch) { samples[$0] }.x, 0.29)
    }

    /// A textured scene with someone standing in a different place in each photo, shifted a little as from the hand.
    /// `dust` is a dark speck at the same pixel of every photo, as dust on the sensor is.
    private func writeSeries(count: Int, width: Int = 600, height: Int = 400, dust: (x: Int, y: Int)? = nil, in directory: URL) throws -> [URL] {
        func scene(_ x: Double, _ y: Double) -> SIMD3<Float> {
            var v = 0.25 + 0.1 * sin(x / 13) * cos(y / 17)
            for k in 0..<30 {
                let cx = Double((k * 7919) % width), cy = Double((k * 104_729) % height), radius = 10 + Double((k * 31) % 25)
                if hypot(x - cx, y - cy) < radius { v += k % 2 == 0 ? 0.2 : -0.12 }
            }
            return SIMD3(Float(v), Float(v * 0.9), Float(v * 0.8))
        }
        return try (0..<count).map { k in
            let shift = SIMD2(Double(k % 3) - 1, Double(k % 2))
            var pixels = [UInt16](repeating: 0, count: width * height * 3)
            for y in 0..<height { for x in 0..<width {
                var value = scene(Double(x) + shift.x, Double(y) + shift.y)
                // The passer-by: a dark figure at a different place in every photo.
                let px = 60 + k * 90
                if (px..<px + 40).contains(x), (150..<300).contains(y) { value = SIMD3(0.02, 0.02, 0.05) }
                if let dust, hypot(Double(x - dust.x), Double(y - dust.y)) < 5 { value = SIMD3(0.02, 0.02, 0.02) }
                for c in 0..<3 { pixels[(y * width + x) * 3 + c] = UInt16((min(1, value[c]) * 65535).rounded()) }
            }}
            let url = directory.appendingPathComponent("frame-\(k).tif")
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoStackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Dust on the sensor is at the same pixel of every photo, so no stack takes it out. Each photo's own dust removal
    /// does, before the photos are aligned, in the preview and at full size.
    func testEachPhotosRetouchingIsTakenOutBeforeStacking() throws {
        let directory = try temporaryDirectory()
        let urls = try writeSeries(count: 5, dust: (520, 200), in: directory)
        func speck(_ stacker: PhotoStacker) throws -> [Float] {
            _ = try stacker.analyze()
            return try [stacker.previewRaster(PhotoStackSettings()), stacker.stackedRaster(PhotoStackSettings(), engine: .cpu), stacker.stackedRaster(PhotoStackSettings())]
                .map { raster in
                    let x = 520 * raster.width / 600, y = 200 * raster.height / 400
                    return raster.rgba[(y * raster.width + x) * 4 + 1]
                }
        }
        for value in try speck(PhotoStacker(urls: urls)) { XCTAssertLessThan(value, 0.08, "the median keeps what every photo has") }
        let cleaned = try PhotoStacker(urls: urls)
        let spot = RetouchStroke(mode: .heal, source: .init(x: 560.0 / 600, y: 0.5), target: .init(x: 520.0 / 600, y: 0.5), radius: 12.0 / 400, softness: 0.5, opacity: 1)
        cleaned.retouch = Dictionary(uniqueKeysWithValues: urls.map { ($0, [spot]) })
        let after = try speck(cleaned)
        for value in after { XCTAssertGreaterThan(value, 0.15, "each photo was cleaned first") }
    }

    /// The frame brush shows one photo where it is painted: the passer-by the median removed comes back there, in the
    /// preview and at full size, and nowhere else; the eraser gives the area back.
    func testBrushShowsOnePhoto() throws {
        let directory = try temporaryDirectory()
        let urls = try writeSeries(count: 5, in: directory)
        let stacker = try PhotoStacker(urls: urls)
        _ = try stacker.analyze()
        var settings = PhotoStackSettings()
        // Photo 0's figure stands at x 60..<100, y 150..<300; photo 4's at x 420..<460. Positions in fractions of the width.
        let figure = (150...300).filter { $0 % 12 == 0 }.map { PhotoStackStroke(x: 80.0 / 600, y: Double($0) / 600, radius: 40.0 / 600, photo: 0) }
        settings.strokes = figure
        for raster in [try stacker.previewRaster(settings), try stacker.stackedRaster(settings, engine: .cpu), try stacker.stackedRaster(settings)] {
            XCTAssertLessThan(raster.rgba[(220 * raster.width + 80) * 4 + 1], 0.06, "photo 0's figure shows where it was painted")
            XCTAssertGreaterThan(raster.rgba[(220 * raster.width + 440) * 4 + 1], 0.1, "photo 4's figure stays removed")
            XCTAssertGreaterThan(raster.rgba[(220 * raster.width + 260) * 4 + 1], 0.1)
        }
        let preview = try stacker.preview(settings)
        XCTAssertEqual(Array(preview.painted.keys), [0])
        // Another photo painted over the same place takes it; the eraser gives it back to the stack. Both with a brush
        // twice the size, whose solid core covers the first one's soft edge: a soft edge only thins what is under it.
        settings.strokes = figure + figure.map { PhotoStackStroke(x: $0.x, y: $0.y, radius: $0.radius * 2, photo: 3) }
        XCTAssertGreaterThan(try stacker.previewRaster(settings).rgba[(220 * 600 + 80) * 4 + 1], 0.1, "photo 3 has no figure there")
        XCTAssertEqual(try stacker.weights(settings, included: [0, 1, 2, 3, 4]).planes.keys.sorted(), [3])
        settings.strokes = figure + figure.map { PhotoStackStroke(x: $0.x, y: $0.y, radius: $0.radius * 2, photo: nil) }
        XCTAssertTrue(try stacker.weights(settings, included: [0, 1, 2, 3, 4]).planes.isEmpty)
        XCTAssertEqual(try stacker.previewRaster(settings).rgba, try stacker.previewRaster(PhotoStackSettings()).rgba)
        // A photo left out of the stack can't be brushed in.
        settings.strokes = figure; settings.excluded = [0]
        XCTAssertGreaterThan(try stacker.previewRaster(settings).rgba[(220 * 600 + 80) * 4 + 1], 0.1)
        XCTAssertNotNil(stacker.picture(of: 0))
    }

    func testMedianRemovesPasserByAndGPUMatchesCPU() throws {
        try TestTier.requireSlow()
        let directory = try temporaryDirectory()
        let urls = try writeSeries(count: 5, in: directory)
        let stacker = try PhotoStacker(urls: urls)
        let analysis = try stacker.analyze()
        XCTAssertEqual(analysis.reference, 2)
        XCTAssertTrue(analysis.frames.allSatisfy { $0.shift != nil })
        var settings = PhotoStackSettings()
        settings.mode = .median
        let cpu = try stacker.stackedRaster(settings, engine: .cpu)
        // Where the reference photo has the figure (x 240..<280), the median shows the scene behind it.
        let p = (220 * cpu.width + 260) * 4
        XCTAssertGreaterThan(cpu.rgba[p + 1], 0.1, "the passer-by should be gone")
        settings.mode = .mean
        let mean = try stacker.stackedRaster(settings, engine: .cpu)
        XCTAssertLessThan(mean.rgba[p + 1], cpu.rgba[p + 1], "the mean keeps a ghost of the figure")
        settings.mode = .clippedMean
        let clipped = try stacker.stackedRaster(settings, engine: .cpu)
        XCTAssertGreaterThan(clipped.rgba[p + 1], 0.1, "sigma clipping drops the passer-by too")
        settings.mode = .sequence
        let sequence = try stacker.stackedRaster(settings, engine: .cpu)
        // Every photo's figure shows: here the first photo's (x 60..<100) and the last one's (x 420..<460).
        for x in [80, 440] { XCTAssertLessThan(sequence.rgba[(220 * sequence.width + x) * 4 + 1], 0.06, "figure at x \(x)") }
        XCTAssertGreaterThan(sequence.rgba[(100 * sequence.width + 260) * 4 + 1], 0.1, "the scene above the figures stays")
        // Over the base photo (figure at x 240..<280): Lighten takes the scene the others show behind its figure,
        // Darken takes every photo's figure.
        settings.mode = .lighten
        XCTAssertGreaterThan(try stacker.stackedRaster(settings, engine: .cpu).rgba[p + 1], 0.1)
        XCTAssertGreaterThan(try stacker.previewRaster(settings).rgba[p + 1], 0.1)
        settings.mode = .darken
        let darken = try stacker.stackedRaster(settings, engine: .cpu)
        for x in [80, 260, 440] { XCTAssertLessThan(darken.rgba[(220 * darken.width + x) * 4 + 1], 0.06, "figure at x \(x)") }
        for mode in PhotoStackMode.allCases {
            settings.mode = mode
            let cpu = try stacker.stackedRaster(settings, engine: .cpu)
            let gpu: PanoramaRaster
            do { gpu = try stacker.stackedRaster(settings, engine: .gpu) } catch { throw XCTSkip("No GPU: \(error)") }
            var worst: Float = 0
            for i in stride(from: 0, to: cpu.rgba.count, by: 4) { for c in 0..<3 { worst = max(worst, abs(cpu.rgba[i + c] - gpu.rgba[i + c])) } }
            // Half-float storage on both paths; the difference is rounding (a sample right at a threshold can differ).
            XCTAssertLessThan(worst, mode == .median || mode == .mean || mode == .maximum || mode == .minimum ? 2e-3 : 0.05, "\(mode)")
        }
        settings.mode = .median
        // Switching the reference re-expresses alignment and exposure against photo 0 without analysing again.
        let before = try XCTUnwrap(analysis.frames[0].shift)
        let switched = try XCTUnwrap(stacker.setReference(0))
        XCTAssertEqual(switched.reference, 0)
        XCTAssertEqual(switched.frames[0].stops, 0, accuracy: 1e-9)
        XCTAssertLessThan(simd_length(try XCTUnwrap(switched.frames[0].shift)), 1e-9)
        XCTAssertLessThan(simd_distance(try XCTUnwrap(switched.frames[2].shift), -before), 0.05)
        settings.mode = .median
        let rereferenced = try stacker.stackedRaster(settings, engine: .cpu)
        XCTAssertGreaterThan(rereferenced.rgba[p + 1], 0.1, "the passer-by stays gone")
        _ = try stacker.preview(settings)
        let output = directory.appendingPathComponent("stack.dng")
        try stacker.stack(settings, to: output)
        XCTAssertNotNil(CIRAWFilter(imageURL: output))
    }

    func testStraighteningLevelsTiltedSweep() {
        // A horizontal sweep of five photos with the camera pitched 10° down and rolled about the sweep axis.
        func rotation(axis: SIMD3<Double>, angle: Double) -> simd_double3x3 { simd_double3x3(simd_quatd(angle: angle, axis: simd_normalize(axis))) }
        let tilt = rotation(axis: SIMD3(1, 0, 0.3), angle: 0.17)
        let rotations = (0..<5).map { k in tilt * rotation(axis: SIMD3(0, 1, 0), angle: Double(k - 2) * 0.5) }
        let straightening = PanoramaGeometry.straighten(rotations: rotations, members: Array(0..<5))
        XCTAssertFalse(straightening.transposed)
        // Every camera's x axis ends up level: no vertical component in the straightened world.
        for r in rotations { XCTAssertEqual((straightening.world * r)[0].y, 0, accuracy: 1e-6) }

        // A sweep from the horizon through the zenith turns about the photos' x axis and is laid out down the canvas.
        let vertical = (0..<5).map { k in rotation(axis: SIMD3(1, 0, 0), angle: Double(k) * -0.6) }
        XCTAssertTrue(PanoramaGeometry.straighten(rotations: vertical, members: Array(0..<5)).transposed)
    }
}
