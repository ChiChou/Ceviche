import XCTest
import CevicheTestSupport
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
import Metal
import AVFoundation
import Photos
@testable import CevicheCore

/// A synthetic night: stars turning about a pole above the frame, a still textured ground under a wavy skyline, sensor
/// noise, a meteor in one photo and an aircraft crossing three in a row. Written as 16-bit linear TIFFs with EXIF times.
private struct SyntheticNight {
    static let width = 960, height = 640
    static let pole = SIMD2<Double>(480, -1500)
    /// Radians per second about the pole: about 7 pixels between photos at the frame's middle.
    static let rate = 0.0002
    static let interval = 20.0
    let count: Int
    let stars: [(position: SIMD2<Double>, flux: Float, color: SIMD3<Float>)]
    let meteorFrame = 2
    let meteor = (start: SIMD2<Double>(200, 150), end: SIMD2<Double>(330, 235))
    let aircraftFrames = [4, 5, 6]
    /// A broad glow in the last photo, as from dawn or an aurora: the literal maximum keeps it, trails over one photo's sky don't.
    static let glow = (frame: 6, center: SIMD2<Double>(250, 250), sigma: 60.0, level: Float(0.05))
    /// Sensor defects: the same single pixels bright in every photo.
    static let hotPixels = [(130, 90), (402, 211), (777, 333), (845, 60), (300, 560)]
    /// A round flash in one photo, as from a passing light: not a line, so only outlier rejection removes it.
    let flash = (frame: 3, center: SIMD2<Double>(700, 140))

    init(count: Int = 7) {
        self.count = count
        var state: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        stars = (0..<900).map { _ in
            let flux = Float(0.03 + 0.6 * pow(random(), 3))
            return (SIMD2(random() * 1100 - 70, random() * 620 - 40), flux, SIMD3(Float(0.85 + 0.3 * random()), 1, Float(0.85 + 0.3 * random())))
        }
    }

    /// Where the aircraft's line starts in its `k`th photo: one straight path, crossed at a steady pace.
    func aircraft(_ k: Int) -> SIMD2<Double> { SIMD2(520, 330) + Double(k) * SIMD2(95, -14.25) }

    static func skyline(_ x: Double) -> Double { 470 + 22 * sin(x / 61) + 9 * sin(x / 17) }
    static func angle(_ frame: Int) -> Double { rate * interval * Double(frame) }

    /// Where a star at `p` (frame 0 coordinates) sits in `frame`.
    static func move(_ p: SIMD2<Double>, to frame: Int) -> SIMD2<Double> {
        let a = angle(frame), d = p - pole
        return pole + SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
    }
    /// Maps a point of `frame`'s sky to `target`'s.
    static func map(_ p: SIMD2<Double>, from frame: Int, to target: Int) -> SIMD2<Double> {
        let a = angle(target) - angle(frame), d = p - pole
        return pole + SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
    }

    /// Linear RGB, top row first, with or without noise.
    func pixels(_ frame: Int, noise: Bool) -> [SIMD3<Float>] {
        let w = Self.width, h = Self.height
        var image = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let sky = Double(y) < Self.skyline(Double(x))
            image[y * w + x] = sky ? SIMD3(0.030, 0.032, 0.040) * Float(1 + 0.3 * Double(y) / Double(h))
                                   : SIMD3(0.012, 0.010, 0.008) * Float(1.2 + 0.8 * sin(Double(x) / 7) * cos(Double(y) / 5))
        }}
        func splat(_ center: SIMD2<Double>, _ flux: Float, _ color: SIMD3<Float>, sigma: Double = 1.1) {
            let x0 = Int(center.x) - 4, y0 = Int(center.y) - 4
            guard x0 + 9 > 0, y0 + 9 > 0, x0 < w, y0 < h else { return }
            for y in max(0, y0)..<min(h, y0 + 9) { for x in max(0, x0)..<min(w, x0 + 9) where Double(y) < Self.skyline(Double(x)) {
                let d = simd_distance(SIMD2(Double(x), Double(y)), center)
                image[y * w + x] += color * flux * Float(exp(-d * d / (2 * sigma * sigma)))
            }}
        }
        for star in stars { splat(Self.move(star.position, to: frame), star.flux, star.color) }
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ brightness: Float) {
            let steps = Int(simd_distance(a, b) * 2)
            for k in 0...steps { splat(a + (b - a) * Double(k) / Double(steps), brightness / Float(steps) * Float(simd_distance(a, b)) * 0.5, SIMD3(0.9, 1, 0.8), sigma: 0.9) }
        }
        if frame == meteorFrame { line(meteor.start, meteor.end, 0.5) }
        if let k = aircraftFrames.firstIndex(of: frame) { line(aircraft(k), aircraft(k) + SIMD2(80, -12), 0.4) }
        if frame == flash.frame { splat(flash.center, 0.6, SIMD3(1, 0.9, 0.8), sigma: 2.2) }
        for (x, y) in Self.hotPixels { image[y * w + x] += SIMD3(0.45, 0.4, 0.5) }
        if frame == Self.glow.frame {
            for y in 0..<h { for x in 0..<w where Double(y) < Self.skyline(Double(x)) {
                let d = simd_distance(SIMD2(Double(x), Double(y)), Self.glow.center)
                image[y * w + x] += SIMD3(0.6, 1, 0.7) * Self.glow.level * Float(exp(-d * d / (2 * Self.glow.sigma * Self.glow.sigma)))
            }}
        }
        if noise {
            var state = UInt64(frame + 1) &* 0x2545F4914F6CDD1D
            func gaussian() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let u = max(1e-12, Double(state >> 11) / Double(1 << 53))
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = Double(state >> 11) / Double(1 << 53)
                return Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
            }
            for i in image.indices { image[i] += SIMD3(gaussian(), gaussian(), gaussian()) * 0.006 }
        }
        return image
    }

    func write(to directory: URL) throws -> [URL] {
        try (0..<count).map { frame in
            let w = Self.width, h = Self.height
            var values = [UInt16](repeating: 0, count: w * h * 3)
            for (i, p) in pixels(frame, noise: true).enumerated() {
                for c in 0..<3 { values[i * 3 + c] = UInt16((max(0, min(1, p[c])) * 65535).rounded()) }
            }
            let url = directory.appendingPathComponent(String(format: "night-%02d.tif", frame))
            let provider = CGDataProvider(data: values.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!
            let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let seconds = Int(Self.interval) * frame
            let exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: String(format: "2024:08:12 23:%02d:%02d", seconds / 60, seconds % 60),
                                       kCGImagePropertyExifExposureTime as String: 15.0, kCGImagePropertyExifFNumber as String: 2.8,
                                       kCGImagePropertyExifISOSpeedRatings as String: [3200]]
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary as String: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
    }
}

private actor StarTrailFrameFiles {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

final class NightSkyTests: XCTestCase {
    private static var cached: [URL]?
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NightSkyTests-\(UUID().uuidString)")
    private let night = SyntheticNight()

    override class func setUp() {
        // The scene's own sky, softened over a few pixels, so results don't depend on an installed model.
        NightSkyAnalyzer.usesSkyModel = false
        NightSkyAnalyzer.skyOverride = { width, height in
            (0..<(width * height)).map { i in
                let x = Double(i % width), y = Double(i / width)
                return Float(max(0, min(1, (SyntheticNight.skyline(x) - y) / 4 + 0.5)))
            }
        }
    }
    override class func tearDown() {
        NightSkyAnalyzer.usesSkyModel = true
        NightSkyAnalyzer.skyOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }
    /// The sequence, written once for the whole suite.
    private func photos() throws -> [URL] {
        if let cached = Self.cached { return cached }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let urls = try night.write(to: Self.directory)
        Self.cached = urls
        return urls
    }

    func testLatentImageRestoresEveryNightSkyToolWithoutAnalysis() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let urls = try photos()
        for space in [NightSkyAnalyzer.Space.camera, .sky] {
            let original = try NightSkyAnalyzer(urls: urls, space: space)
            try original.analyze { _, _ in }
            let saved = Self.directory.appendingPathComponent(UUID().uuidString)
            try original.saveAnalysis(to: saved)
            let stored = try Data(contentsOf: saved.appendingPathComponent("results.plist"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path), ["results.plist"], "no preview pixels are stored")
            let restored = try NightSkyAnalyzer(urls: original.urls, space: space)
            try restored.restoreAnalysis(from: saved)
            // What analysis found comes back exactly; the masks derive from the found sky as analysis left them.
            XCTAssertEqual(restored.lines, original.lines)
            XCTAssertEqual(restored.starCounts, original.starCounts)
            XCTAssertEqual(restored.hotPixels, original.hotPixels)
            XCTAssertEqual(restored.alignments.map { $0?.transform.m }, original.alignments.map { $0?.transform.m })
            XCTAssertEqual(restored.skyProbability, original.skyProbability)
            XCTAssertEqual(restored.skyValid, original.skyValid)
            XCTAssertEqual(restored.previewProbability, original.previewProbability)
            XCTAssertEqual(restored.displayExposure, original.displayExposure)
            XCTAssertEqual(restored.thumbnails.compactMap { $0 }.count, urls.count)
            // Preview copies are decoded again at preview size: close to analysis's shrunk copies, not identical.
            var plan = NightSkyAnalyzer.Plan(base: original.anchor, ground: Set(original.urls.indices))
            if space == .sky { plan.sky = Set(original.urls.indices) } else { plan.peak = Set(original.urls.indices) }
            let before = try original.preview(plan), after = try restored.preview(plan)
            XCTAssertEqual(before.count, after.count)
            let difference = zip(before, after).reduce(0) { $0 + abs($1.0 - $1.1) }, level = before.reduce(0) { $0 + abs($1) }
            XCTAssertLessThan(difference, level * 0.03, "\(space): restored preview strays \(difference / level)")
            // Taking the results back reuses the copies already made. Aligned copies are warped again from the half-float
            // copies as shot, as after a sky edit, so they round slightly differently from the first warp.
            try restored.reuse(try restored.encodedResults())
            let again = try restored.preview(plan)
            if space == .camera { XCTAssertEqual(again, after) }
            else { XCTAssertLessThan(zip(again, after).map { abs($0 - $1) }.max() ?? 1, 1e-3) }
            if space == .camera {
                let tool = try StarTrailsMerger(urls: original.urls)
                let analysis = try tool.restoreAnalysis(from: saved) { _, _ in }
                var settings = StarTrailsSettings(); settings.excluded = [0]; settings.keepStarColors = true
                settings.skyStrokes = [NightSkyStroke(x: 0.3, y: 0.2, radius: 0.03, sky: false)]
                let preview = try tool.preview(settings)
                XCTAssertEqual(analysis.frames.count, urls.count)
                let second = try StarTrailsMerger(urls: original.urls)
                _ = try second.restoreAnalysis(from: saved) { _, _ in }
                XCTAssertEqual(try second.preview(settings).values, preview.values)
            } else {
                let denoise = try NightSkyDenoiser(urls: original.urls)
                _ = try denoise.restoreAnalysis(from: saved) { _, _ in }
                XCTAssertFalse(try denoise.preview(NightSkyDenoiseSettings()).values.isEmpty)
                let meteors = try MeteorShowerMerger(urls: original.urls)
                _ = try meteors.restoreAnalysis(from: saved) { _, _ in }
                XCTAssertFalse(try meteors.preview(MeteorShowerSettings()).values.isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("results.plist")), stored, "editing never changes what was stored")
            XCTAssertThrowsError(try NightSkyAnalyzer(urls: Array(original.urls.dropLast()), space: space).restoreAnalysis(from: saved),
                                 "another number of photos is rejected")
            try Data([0]).write(to: saved.appendingPathComponent("results.plist"))
            XCTAssertThrowsError(try restored.restoreAnalysis(from: saved), "damaged results are rejected")
        }
    }

    func testLatentImageImportVersionsSourcesAndSettings() async throws {
        let urls = try photos()
        let bundle = Self.directory.appendingPathComponent("Test.cevichelatent")
        let sources = try urls.enumerated().map { try LatentImage.Source(assetID: "source-\($0.offset)", url: $0.element) }
        var settings = StarTrailsSettings(); settings.excluded = [0]; settings.fillGaps = true
        settings.skyStrokes = [NightSkyStroke(x: 0.4, y: 0.2, radius: 0.05, sky: false)]
        var object = LatentImage(type: "starTrails", catalogID: "catalog", sources: sources,
                                   settings: try JSONEncoder().encode(settings), analysisID: UUID().uuidString,
                                   width: 960, height: 640, alignedAllSky: false, alignedStrokes: [])
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let pictures = try LatentImage.pictures(image)
        try object.save(to: bundle, pictures: pictures)
        let loaded = try LatentImage.load(bundle)
        XCTAssertEqual(try JSONDecoder().decode(StarTrailsSettings.self, from: loaded.settings), settings)
        // Catalog only: importing files or folders never takes a package or anything inside it, nor browses into it.
        XCTAssertEqual(try CatalogImporter.files(in: [bundle]), [])
        XCTAssertFalse(try CatalogImporter.files(in: [Self.directory]).contains { LatentImage.isBundle($0) || $0.path.hasPrefix(bundle.path + "/") })
        XCTAssertFalse(try CatalogFolders.list(Self.directory).folders.contains(where: LatentImage.isBundle))
        let store = try CatalogStore(root: Self.directory.appendingPathComponent("Object catalog"))
        let prepared = try CatalogImporter.prepareLatent(bundle, options: .init(mode: .copy, catalogRoot: store.root))
        let imported = try await store.insert(prepared.0, thumbnail: nil)
        let thumbnailOutcome = try await ThumbnailReactor.perform(.decode, imported, store)
        XCTAssertEqual(thumbnailOutcome, .installed)
        XCTAssertTrue(imported.isLatent); XCTAssertTrue(imported.isCopy)
        XCTAssertNotEqual(CatalogImporter.sourceURL(for: imported, root: store.root), bundle)
        try await store.enqueueOutdatedAnalysis(version: "next")
        let job = try await store.analysisJob(assetID: imported.id)
        XCTAssertNil(job)
        try await store.moveToTrash(imported.id)
        let plans = try await store.deletionPlans(for: [imported.id])
        try await store.deletePermanently(XCTUnwrap(plans.first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CatalogImporter.sourceURL(for: imported, root: store.root).path))
        try sources[0].validate(urls[0])
        XCTAssertThrowsError(try sources[0].validate(Self.directory.appendingPathComponent("missing.tif")))
        object.type = "futureTool"; try object.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle))
        object.type = "starTrails"; object.typeVersion = 2; try object.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle))
        object.typeVersion = 1; object.analysisID = "../outside"; try object.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle))
    }

    private func value(_ rgb: [Float], _ width: Int, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let p = (y * width + x) * 3
        return SIMD3(rgb[p], rgb[p + 1], rgb[p + 2])
    }

    /// The averaged sky comes from the photos taken nearest the base, skipping those left out or not aligned.
    func testTheSkyIsAveragedFromTheBasesNeighborsInTime() {
        let times: [Double] = [0, 30, 60, 90, 300, 330, 360]
        let frames = times.indices.map { i in
            NightSkyFrameInfo(index: i, filename: "\(i)", time: times[i], starCount: 100, alignmentError: i == 2 ? nil : 0.5, note: nil, series: [], thumbnail: nil)
        }
        let analysis = MeteorShowerAnalysis(frames: frames, lines: [], timing: nil, suggestedBase: 3, width: 10, height: 10, skyModelInstalled: true)
        var settings = MeteorShowerSettings()
        XCTAssertEqual(analysis.skyFrames(base: 3, settings), [3])
        settings.skyPhotos = 3
        XCTAssertEqual(analysis.skyFrames(base: 3, settings), [0, 1, 3], "photo 2 isn't aligned, and the pause makes photo 4 further away")
        settings.excluded = [1]
        XCTAssertEqual(analysis.skyFrames(base: 3, settings), [0, 3, 4])
        settings.skyPhotos = 15
        XCTAssertEqual(analysis.skyFrames(base: 3, settings), [0, 3, 4, 5, 6])
    }

    /// Agreeing with the base keeps samples within the noise of a difference between two photos, more at brighter pixels,
    /// and measures that noise from as few as two photos a pixel.
    func testSamplesAgreeingWithTheBaseStay() {
        var plan = NightSkyAnalyzer.Plan(base: 0, ground: [0]); plan.sky = [0, 1, 2]; plan.rejectOutliers = true; plan.agreeWithBase = true
        var clipping = NightSkyAnalyzer.Clipping(plan, weights: [1, 1, 1])
        // Two photos at every pixel, luminance 0.1 and 0.12: a deviation of 0.01, or 0.01·√2 corrected for two samples.
        let count = 1000, l: [Float] = [0.1, 0.12]
        var sums = [Float](repeating: 0, count: count * 4), squares = [Float](repeating: 0, count: count)
        for p in 0..<count { for v in l { sums[p * 4] += v; sums[p * 4 + 1] += v; sums[p * 4 + 2] += v; sums[p * 4 + 3] += 1; squares[p] += v * v } }
        sums.withUnsafeBufferPointer { s in squares.withUnsafeBufferPointer { clipping.measureFloor(sums: s, squares: $0) } }
        XCTAssertEqual(clipping.floor, 0.01 * Float(2).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(clipping.level, 0.11, accuracy: 1e-4)
        XCTAssertTrue(clipping.agrees(0.15, base: 0.11), "within 3 · √2 · floor")
        XCTAssertFalse(clipping.agrees(0.2, base: 0.11), "a treetop's sky beside the base's tree")
        XCTAssertTrue(clipping.agrees(0.52, base: 0.44), "a brighter pixel is noisier")
    }

    func testCaptureTimesParseWithFractionsAndOffsets() {
        XCTAssertEqual(NightSkyFrameMetadata.seconds("2024:08:12 23:01:40")! - NightSkyFrameMetadata.seconds("2024:08:12 23:00:00")!, 100)
        XCTAssertEqual(NightSkyFrameMetadata.offset("+02:00"), 7200)
        XCTAssertEqual(NightSkyFrameMetadata.offset("-05:30"), -19800)
        XCTAssertNil(NightSkyFrameMetadata.offset("Z"))
    }

    func testRegistrationRecoversRotationAndRejectsFalseStars() throws {
        let truth = { (p: SIMD2<Double>) -> SIMD2<Double> in SyntheticNight.map(p, from: 0, to: 3) }
        var reference: [NightSkyStar] = [], source: [NightSkyStar] = []
        for star in night.stars where star.position.x > 20 && star.position.x < 940 && star.position.y > 20 && star.position.y < 440 {
            reference.append(NightSkyStar(point: truth(star.position), flux: Double(star.flux), radius: 1, elongation: 1))
            source.append(NightSkyStar(point: star.position, flux: Double(star.flux), radius: 1, elongation: 1))
        }
        // Hot pixels that stay put and stars missing from one list.
        source += (0..<30).map { NightSkyStar(point: SIMD2(Double(31 * $0 % 900), Double(17 * $0 % 400)), flux: 0.5, radius: 0.6, elongation: 1) }
        source.removeLast(60)
        source.sort { $0.flux > $1.flux }; reference.sort { $0.flux > $1.flux }
        let alignment = try NightSkyRegistration.align(source: Array(source.prefix(700)), reference: Array(reference.prefix(700)), width: 960)
        XCTAssertLessThan(alignment.heldOutP95, 0.05)
        for p in [SIMD2(100.0, 100), SIMD2(800, 400), SIMD2(480, 250)] {
            XCTAssertLessThan(simd_distance(alignment.apply(p), truth(p)), 0.05)
            XCTAssertLessThan(simd_distance(alignment.sourcePoint(truth(p)), p), 0.05)
        }
    }

    /// The analysis kernels find the same hot pixels as the CPU code, and warp the sky to the same previews and lines.
    func testAnalysisKernelsMatchTheCPU() throws {
        try TestTier.requireSlow()
        let urls = try photos()
        let gpu = NightSkyAnalysisGPU(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let analyzer = try NightSkyAnalyzer(urls: urls, space: .sky)
        let frame = try HDRMergeDecoder.decode(urls[0], metadata: NightSkyFrameMetadata.read(urls[0]).base, longEdge: nil, whiteBalance: (5000, 0), context: analyzer.context)
        let image = try HDRMergeDecoder.developedImage(urls[0], metadata: NightSkyFrameMetadata.read(urls[0]).base, longEdge: nil, whiteBalance: (5000, 0))
        let spikes = NightSkyAnalyzer.spikes(frame.pixels, width: frame.width, height: frame.height)
        XCTAssertFalse(spikes.isEmpty)
        XCTAssertEqual(try gpu.spikes(image, context: analyzer.context), spikes)

        // The line search's high pass, on planes with gaps.
        let w = 300, h = 200
        func plane(_ seed: Int) -> [Float] {
            (0..<(w * h)).map { i in i % 97 == seed ? .nan : Float(sin(Double(i * (seed + 3)) * 0.37)) * 0.01 + Float(i % w) * 1e-4 }
        }
        let interior = (0..<(w * h)).map { Float($0 % w > 10 ? 1 : 0) }
        let cpuPass = NightSkyTransients.highPass(frame: plane(1), neighbors: [plane(2), plane(3), plane(4), plane(5)], interior: interior, width: w, height: h)
        let gpuPass = try gpu.lineHighPass(frame: plane(1), neighbors: [plane(2), plane(3), plane(4), plane(5)], interior: interior, width: w, height: h)
        XCTAssertLessThan(zip(cpuPass.high, gpuPass.high).map { abs($0 - $1) }.max()!, 1e-5)
        XCTAssertLessThan(zip(cpuPass.inside, gpuPass.inside).map { abs($0 - $1) }.max()!, 1e-5)
        // The filters: a minimum exactly, a mean to float rounding.
        let values = plane(7).map { $0.isFinite ? $0 : 0.5 }
        XCTAssertEqual(try gpu.filter(values, width: w, height: h, radius: 9, minimum: true), HDRMerger.minFilter(values, width: w, height: h, radius: 9))
        XCTAssertLessThan(zip(try gpu.filter(values, width: w, height: h, radius: 30), HDRMerger.boxBlur(values, width: w, height: h, radius: 30)).map { abs($0 - $1) }.max()!, 1e-5)

        func analysis(onGPU: Bool) throws -> NightSkyAnalyzer {
            NightSkyAnalyzer.analyzesOnGPU = onGPU
            defer { NightSkyAnalyzer.analyzesOnGPU = true }
            let analyzer = try NightSkyAnalyzer(urls: urls, space: .sky)
            try analyzer.analyze { _, _ in }
            return analyzer
        }
        let kernels = try analysis(onGPU: true), cpu = try analysis(onGPU: false)
        XCTAssertEqual(kernels.hotPixels, cpu.hotPixels)
        XCTAssertEqual(kernels.lines.count, cpu.lines.count)
        for (a, b) in zip(kernels.lines, cpu.lines) {
            XCTAssertEqual(a.frame, b.frame)
            XCTAssertLessThan(max(simd_distance(a.start, b.start), simd_distance(a.end, b.end)), 1)
        }
        let all = Set(cpu.urls.indices)
        let plan = NightSkyAnalyzer.Plan(base: cpu.anchor, sky: all, ground: all)
        let a = try kernels.preview(plan), b = try cpu.preview(plan)
        XCTAssertEqual(a.count, b.count)
        let difference = zip(a, b).map { $0.isFinite && $1.isFinite ? abs($0 - $1) : ($0.isFinite == $1.isFinite ? 0 : .infinity) }.max() ?? 0
        XCTAssertLessThan(difference, 0.002, "the warped sky should match the CPU's")
    }

    func testLinesAreFoundAgainstNeighborsAndTracksAreGrouped() throws {
        let w = 300, h = 200
        func plane(_ line: Bool) -> [Float] {
            var values = [Float](repeating: 0.02, count: w * h)
            var state: UInt64 = line ? 7 : 11
            for i in values.indices { state = state &* 6364136223846793005 &+ 1442695040888963407; values[i] += Float(state >> 40) / Float(1 << 24) * 0.004 }
            if line { for k in 0..<80 { values[(60 + k / 2) * w + 80 + k] += 0.2 } }
            return values
        }
        let interior = [Float](repeating: 1, count: w * h)
        let found = try NightSkyTransients.detect(frame: plane(true), neighbors: [plane(false), plane(false)], interior: interior, stars: [], width: w, height: h, index: 3)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.length ?? 0, (80.0 * 80 + 40 * 40).squareRoot(), accuracy: 6)
        let track = (0..<3).map { k in NightSkyLine(frame: 4 + k, start: SIMD2(100 + 50 * Double(k), 50), end: SIMD2(140 + 50 * Double(k), 50), width: 2, pixels: 40, peak: 10) }
        let meteor = NightSkyLine(frame: 5, start: SIMD2(20, 150), end: SIMD2(60, 190), width: 2, pixels: 40, peak: 10)
        let grouped = NightSkyTransients.groupTracks(track + [meteor])
        XCTAssertEqual(grouped.map(\.kind), [.track, .track, .track, .meteor])
        // Two collinear lines in neighboring photos are one aircraft, not two meteors.
        let pair = NightSkyTransients.groupTracks(Array(track.prefix(2)))
        XCTAssertEqual(pair.map(\.kind), [.track, .track])
        // A bump trails the bright stars: several short lines in one photo.
        let bump = (0..<5).map { k in NightSkyLine(frame: 9, start: SIMD2(30 + 40 * Double(k), 20 + 25 * Double(k)), end: SIMD2(52 + 40 * Double(k), 31 + 25 * Double(k)), width: 2, pixels: 30, peak: 8) }
        XCTAssertEqual(NightSkyTransients.groupTracks(bump + [meteor]).map(\.kind), Array(repeating: .shake, count: 5) + [.meteor])
        // A branch that moved: the same short line in two photos isn't something in the sky.
        let branch = [2, 6].map { NightSkyLine(frame: $0, start: SIMD2(10, 80), end: SIMD2(30, 81), width: 2, pixels: 20, peak: 9) }
        XCTAssertEqual(NightSkyTransients.groupTracks(branch + [meteor]).map(\.frame), [5])
        // An aircraft close by strays sideways from one photo's line to the next, further the further along.
        let near = [NightSkyLine(frame: 1, start: SIMD2(100, 100), end: SIMD2(100, 400), width: 2, pixels: 300, peak: 20),
                    NightSkyLine(frame: 2, start: SIMD2(115, 520), end: SIMD2(122, 900), width: 2, pixels: 380, peak: 20)]
        XCTAssertEqual(NightSkyTransients.groupTracks(near).map(\.kind), [.track, .track])
        // Two lights side by side in one photo are an aircraft's wingtips, not a meteor.
        let wingtips = [NightSkyLine(frame: 3, start: SIMD2(100, 300), end: SIMD2(400, 300), width: 2, pixels: 300, peak: 20),
                        NightSkyLine(frame: 3, start: SIMD2(110, 303.5), end: SIMD2(390, 303.5), width: 2, pixels: 280, peak: 20)]
        let joined = NightSkyTransients.joinCollinear(wingtips)
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(NightSkyTransients.groupTracks(joined + [meteor]).map(\.kind), [.track, .meteor])
        // Further apart they stay two lines, still an aircraft's.
        let apart = wingtips.map { var line = $0; if line.start.y > 300 { line.start.y += 6; line.end.y += 6 }; return line }
        XCTAssertEqual(NightSkyTransients.groupTracks(apart + [meteor]).map(\.kind), [.track, .track, .meteor])
        // An aircraft turning into view: a piece at an angle, ending where the track in the next photo starts.
        let turning = NightSkyLine(frame: 3, start: SIMD2(20, 90), end: SIMD2(95, 55), width: 2, pixels: 80, peak: 10)
        let turned = NightSkyTransients.groupTracks([turning] + track + [meteor])
        XCTAssertEqual(turned.map(\.kind), [.track, .track, .track, .track, .meteor])
        // One aircraft, one group: its pieces across photos share it, and the meteor has none.
        XCTAssertEqual(turned.map(\.group), [0, 0, 0, 0, nil])
        XCTAssertEqual(Set(NightSkyTransients.groupTracks(apart + track).compactMap(\.group)).count, 2)
    }

    func testABlinkingAircraftIsOneTrackAndARowOfStarsIsNot() throws {
        let w = 1500, h = 200
        func plane(_ seed: UInt64, flashes: Bool = false, lights: Bool = false) -> [Float] {
            var values = [Float](repeating: 0.02, count: w * h)
            var state = seed
            for i in values.indices { state = state &* 6364136223846793005 &+ 1442695040888963407; values[i] += Float(state >> 40) / Float(1 << 24) * 0.004 }
            // Steady lights too faint to be found as a line, with a beacon flash every 44 pixels.
            if lights { for x in 100...400 { values[100 * w + x] += 0.004 } }
            if flashes { for k in 0..<6 { for dy in -2...2 { for dx in -2...2 { values[(100 + dy) * w + 120 + 44 * k + dx] += 0.05 } } } }
            return values
        }
        let interior = [Float](repeating: 1, count: w * h), neighbors = [plane(11), plane(13)]
        let aircraft = try NightSkyTransients.detect(frame: plane(7, flashes: true, lights: true), neighbors: neighbors, interior: interior, stars: [], width: w, height: h, index: 3)
        XCTAssertEqual(aircraft.map(\.kind), [.track], "\(aircraft)")
        // Followed along the steady lights past the first and last flash.
        let ends = aircraft.flatMap { [$0.start.x, $0.end.x] }
        XCTAssertLessThan(ends.min() ?? .infinity, 115)
        XCTAssertGreaterThan(ends.max() ?? 0, 345)
        // The same spots without the lights between them: bright stars that happen to line up.
        let stars = try NightSkyTransients.detect(frame: plane(7, flashes: true), neighbors: neighbors, interior: interior, stars: [], width: w, height: h, index: 3)
        XCTAssertEqual(stars.count, 0, "\(stars)")
    }

    func testDenoiseAlignsStarsKeepsGroundStillAndLowersNoise() throws {
        let denoiser = try NightSkyDenoiser(urls: try photos())
        let analysis = try denoiser.analyze()
        XCTAssertEqual(analysis.frames.filter(\.isAligned).count, night.count)
        XCTAssertLessThan(analysis.frames.compactMap(\.alignmentError).max() ?? 9, 0.6)
        let settings = NightSkyDenoiseSettings()
        let stacked = try denoiser.previewValues(settings), single = try denoiser.referenceValues(settings)
        let analyzer = denoiser.internalAnalyzer
        let w = analyzer.previewWidth, h = analyzer.previewHeight
        XCTAssertEqual(w, SyntheticNight.width)
        let reference = analysis.suggestedReference, truth = night.pixels(reference, noise: false)
        // Noise in flat sky and ground, against the noise-free scene.
        func error(_ rgb: [Float], sky: Bool) -> Double {
            var sum = 0.0, n = 0
            for y in stride(from: 30, to: h - 10, by: 3) { for x in stride(from: 40, to: w - 40, by: 3) {
                let distance = Double(y) - SyntheticNight.skyline(Double(x))
                guard sky ? distance < -40 : distance > 25, simd_distance(SIMD2(Double(x), Double(y)), night.flash.center) > 12,
                      simd_distance(SIMD2(Double(x), Double(y)), SyntheticNight.glow.center) > 3 * SyntheticNight.glow.sigma else { continue }
                let d = value(rgb, w, x, y).y - truth[y * w + x].y
                sum += Double(d * d); n += 1
            }}
            return (sum / Double(n)).squareRoot()
        }
        let skyGain = error(single, sky: true) / error(stacked, sky: true), groundGain = error(single, sky: false) / error(stacked, sky: false)
        XCTAssertGreaterThan(skyGain, 1.8, "sky noise should fall with seven photos")
        XCTAssertGreaterThan(groundGain, 2.2, "the ground is averaged in place")
        // Bright stars stay sharp points where the reference has them.
        let bright = night.stars.filter { $0.flux > 0.3 }.map { SyntheticNight.move($0.position, to: reference) }
            .filter { $0.x > 60 && $0.x < Double(w - 60) && $0.y > 40 && $0.y < SyntheticNight.skyline($0.x) - 50 }
        XCTAssertGreaterThan(bright.count, 5)
        for p in bright {
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            XCTAssertGreaterThan(value(stacked, w, x, y).y / truth[y * w + x].y, 0.8, "star at \(p)")
        }
        // Faint stars keep their light: aperture flux above the local sky, stack against the noise-free scene.
        let faint = night.stars.filter { $0.flux > 0.03 && $0.flux < 0.1 }.map { SyntheticNight.move($0.position, to: reference) }
            .filter { $0.x > 60 && $0.x < Double(w - 60) && $0.y > 40 && $0.y < SyntheticNight.skyline($0.x) - 50 }
        func aperture(_ rgb: [Float]?, _ p: SIMD2<Double>) -> Float {
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            func at(_ dx: Int, _ dy: Int) -> Float { rgb.map { value($0, w, x + dx, y + dy).y } ?? truth[(y + dy) * w + x + dx].y }
            var core: Float = 0, ring: Float = 0, n: Float = 0
            for dy in -3...3 { for dx in -3...3 { core += at(dx, dy) } }
            for dy in -6...6 { for dx in -6...6 where max(abs(dx), abs(dy)) >= 5 { ring += at(dx, dy); n += 1 } }
            return core - 49 * ring / n
        }
        let ratios = faint.map { Double(aperture(stacked, $0) / aperture(nil, $0)) }.sorted()
        XCTAssertGreaterThan(faint.count, 50)
        XCTAssertEqual(ratios[ratios.count / 2], 1, accuracy: 0.1, "median faint-star flux ratio")
        // The meteor and the aircraft are left out of the average instead of showing as faint streaks.
        let meteorMiddle = SyntheticNight.map((night.meteor.start + night.meteor.end) / 2, from: night.meteorFrame, to: reference)
        let m = value(stacked, w, Int(meteorMiddle.x), Int(meteorMiddle.y)).y, background = truth[Int(meteorMiddle.y) * w + Int(meteorMiddle.x)].y
        XCTAssertLessThan(abs(m - background), 0.015)
    }

    /// A boundary found tens of pixels inside a jagged ridge is moved onto the ridge by brightness, spires included, while
    /// a lit patch in the ground stays ground, starry sky called ground becomes sky, and a thin branch rising from the
    /// ridge into the sky becomes ground.
    func testTheSkyEdgeIsFoundOnTheRidge() {
        let w = 800, h = 600
        var seed: UInt64 = 7
        func random() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        func ridge(_ x: Int) -> Int {
            let spire = x % 100 < 10 ? 30 - abs(x % 100 - 5) * 6 : 0
            return 400 + Int(40 * sin(Double(x) / 37)) - spire
        }
        let hole = (x: 100..<200, y: 50..<150), lit = (x: 390..<410, y: 510..<530)
        // A two-pixel branch from the ridge at x = 250 up 60 pixels, leaning right.
        func onBranch(_ x: Int, _ y: Int) -> Bool { y < ridge(250) && y > ridge(250) - 60 && abs(x - (250 + (ridge(250) - y) / 3)) <= 1 }
        var luminance = [Float](repeating: 0, count: w * h), prior = luminance, starry = luminance
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x, sky = y < ridge(x)
                luminance[i] = (sky ? 0.02 : 0.002) + (random() - 0.5) * 0.006 + (sky && random() < 0.01 ? 0.2 : 0)
                if lit.x.contains(x), lit.y.contains(y) { luminance[i] = 0.03 }
                if onBranch(x, y) { luminance[i] = 0.008 + (random() - 0.5) * 0.006 }
                // The probability's boundary 12 pixels inside the ridge, the spires lost, and a starry patch called ground.
                prior[i] = Float(max(0, min(1, Double(400 + Int(40 * sin(Double(x) / 37)) + 12 - y) / 4 + 0.5)))
                if hole.x.contains(x), hole.y.contains(y) { prior[i] = 0; starry[i] = 1 }
            }
        }
        let snapped = NightSkyAnalyzer.snappedToSkyline(prior, luminance: luminance, starry: starry, width: w, height: h,
                                                        boxBlur: { HDRMerger.boxBlur($0, width: w, height: h, radius: $1) },
                                                        minFilter: { HDRMerger.minFilter($0, width: w, height: h, radius: $1) })
        // Counted at least 3 pixels from the ridge in every direction: spire tips narrower than that may go either way.
        func isSky(_ x: Int, _ y: Int) -> Bool { y < ridge(x) && !onBranch(x, y) }
        var sky = 0, skyRight = 0, ground = 0, groundRight = 0
        for x in 3..<(w - 3) {
            for y in max(3, ridge(x) - 40)..<min(h - 3, ridge(x) + 40) {
                let side = isSky(x, y)
                guard (-3...3).allSatisfy({ dy in (-3...3).allSatisfy { dx in isSky(x + dx, y + dy) == side } }) else { continue }
                if side { sky += 1; if snapped[y * w + x] > 0.5 { skyRight += 1 } } else { ground += 1; if snapped[y * w + x] < 0.5 { groundRight += 1 } }
            }
        }
        XCTAssertGreaterThan(Double(skyRight) / Double(sky), 0.99, "the sky stays sky")
        XCTAssertGreaterThan(Double(groundRight) / Double(ground), 0.99, "the rock and spires the probability called sky are ground")
        XCTAssertLessThan(snapped[520 * w + 400], 0.5, "lit ground inside the silhouette")
        XCTAssertGreaterThan(snapped[100 * w + 150], 0.5, "starry sky the probability called ground")
        let branch = (1..<60).map { ridge(250) - $0 }.filter { y in snapped[y * w + 250 + (ridge(250) - y) / 3] < 0.5 }
        XCTAssertGreaterThan(branch.count, 50, "the branch is ground along its length")
    }

    /// Sky Edge moves the boundary: grown, sky reaches into the ground; shrunk, the ground's average reaches up into the sky.
    func testSkyEdgeMovesTheBoundary() throws {
        try TestTier.requireSlow()
        let denoiser = try NightSkyDenoiser(urls: try photos())
        _ = try denoiser.analyze()
        let w = SyntheticNight.width
        func skyShare(_ edge: Int) throws -> Double {
            var settings = NightSkyDenoiseSettings(); settings.skyEdge = edge
            let preview = try denoiser.preview(settings)
            XCTAssertNotNil(preview.sky)
            let probability = denoiser.internalAnalyzer.previewProbability
            return Double(probability.filter { $0 > 0.5 }.count) / Double(probability.count)
        }
        let found = try skyShare(0), grown = try skyShare(16), shrunk = try skyShare(-16)
        XCTAssertGreaterThan(grown, found); XCTAssertLessThan(shrunk, found)
        // Sixteen pixels along a skyline about the frame's width long.
        XCTAssertEqual((grown - found) * Double(w * SyntheticNight.height), 16 * Double(w), accuracy: 6 * Double(w))
        // Back to zero restores the boundary analysis found.
        XCTAssertEqual(try skyShare(0), found, accuracy: 1e-9)
        // The full size follows the same boundary on both engines.
        var settings = NightSkyDenoiseSettings(); settings.skyEdge = -16
        let gpu = try denoiser.render(settings, engine: .gpu), cpu = try denoiser.render(settings, engine: .cpu)
        var over = 0
        for i in stride(from: 0, to: gpu.rgba.count, by: 4) where abs(gpu.rgba[i + 1] - cpu.rgba[i + 1]) > 2e-3 { over += 1 }
        XCTAssertLessThan(Double(over) / Double(gpu.rgba.count / 4), 0.001)
    }

    /// Everything Is Sky and painted corrections reshape the sky at once for the preview, warping the photos again where
    /// it grew, and analyzing again uses them for the stars.
    func testSkyCorrectionsShapeThePreviewAndTheAnalysis() throws {
        try TestTier.requireSlow()
        let denoiser = try NightSkyDenoiser(urls: try photos())
        _ = try denoiser.analyze()
        let analyzer = denoiser.internalAnalyzer
        let w = analyzer.previewWidth, h = analyzer.previewHeight
        let ground = (x: w / 2, y: h - 8), sky = (x: w / 2, y: h / 5)
        func at(_ p: (x: Int, y: Int)) -> Float { analyzer.previewProbability[p.y * w + p.x] }
        var settings = NightSkyDenoiseSettings()
        _ = try denoiser.preview(settings)
        XCTAssertLessThan(at(ground), 0.1); XCTAssertGreaterThan(at(sky), 0.9)

        settings.allSky = true
        _ = try denoiser.preview(settings)
        XCTAssertGreaterThan(at(ground), 0.99, "everything is sky")
        // The ground of an aligned photo is now warped too.
        var warped = 0
        try analyzer.cache?.read { reader in
            let copy = reader.copy(night.count - 1, 1)
            warped = stride(from: 0, to: copy.count, by: 3).filter { copy[$0].isFinite }.count
        }
        XCTAssertGreaterThan(Double(warped) / Double(w * h), 0.9)

        settings.skyStrokes = [NightSkyStroke(x: (Double(sky.x) + 0.5) / Double(w), y: (Double(sky.y) + 0.5) / Double(h), radius: 0.03, sky: false)]
        _ = try denoiser.preview(settings)
        XCTAssertLessThan(at(sky), 0.01, "painted out of the sky")
        XCTAssertGreaterThan(at(ground), 0.99)

        // Analyzing again with the corrections finds the stars in that sky and aligns every photo still.
        let again = try denoiser.analyze(allSky: true, skyStrokes: settings.skyStrokes)
        XCTAssertTrue(again.frames.allSatisfy(\.isAligned))
        _ = try denoiser.preview(settings)
        XCTAssertLessThan(at(sky), 0.01); XCTAssertGreaterThan(at(ground), 0.99)
    }

    /// Painted areas come from the chosen photo alone: the flash only one photo recorded shows in full where it is painted.
    func testPaintedAreasComeFromOnePhoto() throws {
        try TestTier.requireSlow()
        let denoiser = try NightSkyDenoiser(urls: try photos())
        _ = try denoiser.analyze()
        var settings = NightSkyDenoiseSettings(); settings.reference = night.flash.frame
        let w = SyntheticNight.width, h = SyntheticNight.height, x = Int(night.flash.center.x), y = Int(night.flash.center.y)
        let reference = night.pixels(night.flash.frame, noise: false)
        let stacked = value(try denoiser.previewValues(settings), w, x, y).y
        settings.photoRegions = [NightSkyStroke(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h), radius: 0.03)]
        let painted = value(try denoiser.previewValues(settings), w, x, y).y
        XCTAssertLessThan(stacked, reference[y * w + x].y * 0.6, "the average dilutes the flash")
        XCTAssertEqual(painted, reference[y * w + x].y, accuracy: 0.03, "painted, the reference photo's own flash")
        // Away from the stroke the stack is unchanged, and the full size agrees on both engines.
        XCTAssertEqual(value(try denoiser.previewValues(settings), w, 100, 100).y, value(try denoiser.previewValues(NightSkyDenoiseSettings()), w, 100, 100).y, accuracy: 1e-6)
        let gpu = try denoiser.render(settings, engine: .gpu), cpu = try denoiser.render(settings, engine: .cpu)
        XCTAssertEqual(gpu.rgba[(y * w + x) * 4 + 1], reference[y * w + x].y, accuracy: 0.03)
        XCTAssertEqual(gpu.rgba[(y * w + x) * 4 + 1], cpu.rgba[(y * w + x) * 4 + 1], accuracy: 0.002)
    }

    func testRejectOutliersRemovesAFlashButKeepsStarsAndNoiseGain() throws {

        try TestTier.requireSlow()
        let denoiser = try NightSkyDenoiser(urls: try photos())
        let analysis = try denoiser.analyze()
        var settings = NightSkyDenoiseSettings(); settings.reference = night.flash.frame
        XCTAssertEqual(analysis.suggestedReference, night.flash.frame)
        let plain = try denoiser.previewValues(settings)
        settings.rejectOutliers = true
        let robust = try denoiser.previewValues(settings)
        let w = SyntheticNight.width, truth = night.pixels(night.flash.frame, noise: false)
        let x = Int(night.flash.center.x), y = Int(night.flash.center.y)
        let flash = truth[y * w + x].y - night.pixels(0, noise: false)[y * w + x].y
        // The plain mean keeps a seventh of the flash; the robust mean is back to the sky around it.
        let background = night.pixels(night.flash.frame, noise: false)
        let skyLevel = (background[y * w + x - 12].y + background[y * w + x + 12].y) / 2
        XCTAssertGreaterThan(value(plain, w, x, y).y - skyLevel, flash / 7 * 0.6)
        XCTAssertLessThan(abs(value(robust, w, x, y).y - skyLevel), flash / 7 * 0.35)
        // Stars stay, and the noise gain stays close to the plain mean's.
        var worst: Float = 1
        for star in night.stars where star.flux > 0.3 {
            let p = SyntheticNight.move(star.position, to: night.flash.frame)
            guard p.x > 60, p.x < Double(w - 60), p.y > 40, p.y < SyntheticNight.skyline(p.x) - 50 else { continue }
            let px = Int(p.x.rounded()), py = Int(p.y.rounded())
            worst = min(worst, value(robust, w, px, py).y / value(plain, w, px, py).y)
        }
        XCTAssertGreaterThan(worst, 0.97, "a bright star lost light to rejection")
        var plainError = 0.0, robustError = 0.0
        // Away from the flash and from the hot pixels, whose warped copies the robust mean rightly removes.
        func clear(_ px: Int, _ py: Int) -> Bool {
            hypot(Double(px - x), Double(py - y)) > 12 && SyntheticNight.hotPixels.allSatisfy { hypot(Double(px - $0.0), Double(py - $0.1)) > 40 }
                && simd_distance(SIMD2(Double(px), Double(py)), SyntheticNight.glow.center) > 3 * SyntheticNight.glow.sigma
        }
        for py in stride(from: 30, to: 400, by: 3) { for px in stride(from: 40, to: w - 40, by: 3) where Double(py) < SyntheticNight.skyline(Double(px)) - 40 && clear(px, py) {
            plainError += pow(Double(value(plain, w, px, py).y - truth[py * w + px].y), 2)
            robustError += pow(Double(value(robust, w, px, py).y - truth[py * w + px].y), 2)
        }}
        XCTAssertLessThan(robustError / plainError, 1.15, "rejection should cost little noise")
    }

    func testStarTrailAnimationBuildsToTheSameStack() async throws {
        try TestTier.requireSlow()
        let merger = try StarTrailsMerger(urls: try photos())
        _ = try merger.analyze()
        var settings = StarTrailsSettings()
        settings.excluded = [1]
        settings.fillGaps = true
        settings.keepStarColors = true
        for onePhoto in [false, true] {
            settings.sky = onePhoto ? .onePhoto : .brightest
            settings.skyPhoto = night.count - 1 // A future sky photo must be available from the first frame.
            settings.photoRegions = onePhoto ? [NightSkyStroke(x: 0.9, y: 0.8, radius: 0.03)] : []
            let plan = try merger.plan(settings)
            let expected = try merger.render(settings, engine: .gpu)
            var indices: [Int] = []
            var first: [Float] = [], last: [Float] = []
            try await merger.internalAnalyzer.trailAnimation(plan) { index, raster in
                indices.append(index)
                if index == 0 { first = raster.rgba }
                last = raster.rgba
            }
            XCTAssertEqual(indices, Array(0..<(night.count - 1)))
            XCTAssertEqual(last.count, expected.rgba.count)
            let difference = zip(last, expected.rgba).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThan(difference, 0.0001, "The last frame must match the still stack")
            let ground = ((expected.height - 20) * expected.width + expected.width / 2) * 4
            XCTAssertEqual(first[ground], last[ground], accuracy: 0.0001, "The foreground must stay fixed")
            // A late meteor must not appear at the beginning (One Photo can already contain its own stars).
            let middle = (night.meteor.start + night.meteor.end) / 2
            let p = (Int(middle.y) * expected.width + Int(middle.x)) * 4 + 1
            XCTAssertGreaterThan(last[p] - first[p], 0.05)
        }
        // Exercise the public DNG handoff through the actual movie encoder as well as the linear raster path.
        let movie = Self.directory.appendingPathComponent("trails.mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        var video = TimelapseSettings(); video.framesPerSecond = 12
        let size = CGSize(width: 320, height: 180)
        let writer = try TimelapseWriter(url: movie, settings: video, size: size, frames: night.count - 1)
        let files = StarTrailFrameFiles()
        do {
            _ = await writer.nextPass()
            try await merger.animation(settings) { index, url in
                await files.append(url)
                let renderer = try RawRenderer(sourceURL: url)
                let defaults = renderer.info.defaults
                let buffer = try writer.makeBuffer()
                try await renderer.renderTimelapseFrame(defaults, crop: TimelapseCrop(), ratio: 16.0 / 9, into: buffer)
                try await writer.append(buffer, at: index)
            }
            try await writer.finish(overwriteExisting: false)
        } catch { writer.cancel(); throw error }
        let paths = await files.urls
        XCTAssertEqual(paths.count, night.count - 1)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        XCTAssertEqual(duration, Double(night.count - 1) / 12, accuracy: 0.001)
        // A later encoder pass asks for some frames only; the rest are stacked but not written.
        let even = StarTrailFrameFiles()
        try await merger.animation(settings, frames: { $0 % 2 == 0 }) { _, url in await even.append(url) }
        let evenNames = await even.urls.map(\.lastPathComponent)
        XCTAssertEqual(evenNames, stride(from: 0, to: night.count - 1, by: 2).map { "\($0).dng" })
        let cancelled = StarTrailFrameFiles()
        do {
            try await merger.animation(settings) { _, url in
                await cancelled.append(url)
                throw CancellationError()
            }
            XCTFail("Cancellation must stop the animation")
        } catch is CancellationError {}
        let cancelledPaths = await cancelled.urls
        XCTAssertEqual(cancelledPaths.count, 1)
        if let first = cancelledPaths.first {
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        }
    }

    /// Star Trails' Live Photo: the build-up sampled into 3 seconds, the finished trails cut as the movie is as the
    /// still, the pair one Live Photo to Photos.
    func testStarTrailLivePhotoEndsOnTheFinishedTrails() async throws {
        try TestTier.requireSlow()
        let merger = try StarTrailsMerger(urls: try photos())
        _ = try merger.analyze()
        var settings = StarTrailsSettings()
        settings.excluded = [1]
        let count = night.count - 1, shown = LivePhoto.sample(count), wanted = Set(shown)
        let directory = Self.directory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("trails.heic"), movie = directory.appendingPathComponent("trails.mov"), identifier = UUID().uuidString
        let crop = TimelapseCrop(), ratio = 16.0 / 9, stillSize = CGSize(width: 320, height: 180)
        let writer = try LivePhotoWriter(url: movie, size: CGSize(width: 320, height: 180), frameDuration: LivePhoto.sampleDuration(shown.count),
                                         stillFrame: shown.count - 1, identifier: identifier)
        let files = StarTrailFrameFiles()
        try await merger.animation(settings, trails: .smooth, longEdge: 320, frames: { wanted.contains($0) }) { index, url in
            await files.append(url)
            let renderer = try RawRenderer(sourceURL: url)
            let buffer = try writer.makeBuffer()
            try await renderer.renderTimelapseFrame(renderer.info.defaults, crop: crop, ratio: ratio, into: buffer)
            try await writer.append(buffer)
            if index == count - 1 {
                try LivePhoto.writeStill(try await renderer.livePhotoStill(renderer.info.defaults, crop: crop, ratio: ratio, size: stillSize),
                                         to: still, identifier: identifier, source: nil)
            }
        }
        try await writer.finish()
        let written = await files.urls.map(\.lastPathComponent)
        XCTAssertEqual(written, shown.map { "\($0).dng" })
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(still as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(CGSize(width: image.width, height: image.height), stillSize)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        XCTAssertEqual(duration, LivePhoto.sampleDuration(shown.count).seconds * Double(shown.count), accuracy: 0.01)
        let accepted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var finished = false
            PHLivePhoto.request(withResourceFileURLs: [still, movie], placeholderImage: nil, targetSize: .zero, contentMode: .default) { live, info in
                guard !finished, (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true || info[PHLivePhotoInfoErrorKey] != nil else { return }
                finished = true
                done.resume(returning: live != nil && info[PHLivePhotoInfoErrorKey] == nil)
            }
        }
        XCTAssertTrue(accepted, "Photos reads the files as one Live Photo")
    }

    func testPhotosThatCantBeStackedAreListedAndRefused() throws {
        let directory = Self.directory.appendingPathComponent("cameras-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, model: String?, make: String = "SONY", width: Int = 64) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let context = CGContext(data: nil, width: width, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
            var properties: [String: Any] = [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2024:08:12 23:00:0\(name.prefix(1))"]]
            if let model { properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFMake as String: make, kCGImagePropertyTIFFModel as String: model] }
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
        let one = try write("1.tif", model: "ILCE-7RM3"), other = try write("2.tif", model: "ILCE-7M4"), unnamed = try write("3.tif", model: nil)
        let two = try write("4.tif", model: "ILCE-7RM3"), wide = try write("5.tif", model: "ILCE-7RM3", width: 80)
        let merged = try write("6.tif", model: "Star Trails", make: "Ceviche")
        // Listed before analysis, against what most photos share, so they can be left out.
        XCTAssertEqual(try NightSkyPhotos.unstackable([one, other, two, unnamed, wide, merged]),
                       [1: L10n.tr("Other camera: \("SONY ILCE-7M4")"), 4: L10n.tr("Other size: \("80 × 48")"), 5: L10n.tr("A merged result, not a photo")])
        func cameraError(_ urls: [URL]) throws -> Bool {
            do { _ = try StarTrailsMerger(urls: urls).analyze() } catch { return error.localizedDescription.contains(L10n.tr("These photos come from different cameras. A night sequence needs photos from one camera.")) }
            return false
        }
        XCTAssertTrue(try cameraError([one, other]))
        // A file an editor wrote without the camera doesn't count as another one; these tiny photos fail later for other reasons.
        XCTAssertFalse(try cameraError([one, unnamed]))
    }

    func testSeriesMarksMatchTheTimelapseCheck() {
        // A slow start before the intervalometer settles, a steady run, a pause, a repeat and one photo at other settings.
        let times: [Double] = [0, 48, 121, 194, 251, 267, 284, 301, 318, 335, 352, 452, 469, 469, 486]
        let metadata = times.enumerated().map { i, t in
            var m = NightSkyFrameMetadata(base: HDRMergeFrameMetadata(filename: "\(i).ARW", isRAW: true, make: "SONY", model: "ILCE-7RM3", width: 6000, height: 4000,
                                                                      captureTime: nil, recordedStops: nil, temperature: 4000, tint: 0))
            m.time = t; m.exposure = i == 8 ? 30 : 15; m.fNumber = 2.8; m.iso = i == 10 ? 6400 : 3200; m.focalLength35mm = i == 9 ? 24 : 14
            return m
        }
        let marks = NightSkyAnalyzer.seriesMarks(metadata)
        XCTAssertEqual(marks.indices.filter { marks[$0].contains { if case .pause = $0 { true } else { false } } }, [1, 2, 3, 4, 11])
        XCTAssertEqual(marks[13], [.sameTime])
        XCTAssertEqual(marks[8], [.otherExposure("30 s", usual: "15 s")])
        XCTAssertEqual(marks[9], [.otherSettings("f/\(2.8.formatted(.number.precision(.fractionLength(0...1)))), 24 mm")])
        XCTAssertEqual(marks[10], [], "ISO only scales brightness")
        XCTAssertEqual(marks[5], [])
    }

    func testStarTrailVideoSmoothFillsTheGapsAndGlowsInTheSkyOnly() async throws {
        try TestTier.requireSlow()
        let merger = try StarTrailsMerger(urls: try photos())
        _ = try merger.analyze()
        let settings = StarTrailsSettings() // Fill Gaps off: the photos' own dashes.
        func frames(_ trails: StarTrailsVideoTrails) async throws -> [[Float]] {
            var frames: [[Float]] = []
            try await merger.animationFrames(settings, trails: trails) { _, raster in frames.append(raster.rgba) }
            return frames
        }
        // Dashed is the animation as it was before the option.
        var before: [[Float]] = []
        try await merger.internalAnalyzer.trailAnimation(try merger.plan(settings)) { _, raster in before.append(raster.rgba) }
        let dashed = try await frames(.dashed), smooth = try await frames(.smooth)
        XCTAssertEqual(dashed, before)
        XCTAssertEqual(smooth.count, dashed.count)
        let w = SyntheticNight.width
        func value(_ frame: [Float], _ p: SIMD2<Double>) -> Float { frame[(Int(p.y.rounded()) * w + Int(p.x.rounded())) * 4 + 1] }
        // Halfway between photos 3 and 4 the brightest star well inside the sky is a gap in Dashed and drawn in Smooth.
        let a = SyntheticNight.rate * SyntheticNight.interval * 3.5
        func halfway(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let d = p - SyntheticNight.pole
            return SyntheticNight.pole + SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
        }
        let star = try XCTUnwrap(night.stars.filter { star in
            let p = halfway(star.position)
            return p.x > 20 && p.x < Double(w - 20) && p.y > 20 && p.y < SyntheticNight.skyline(p.x) - 20
        }.max { $0.flux < $1.flux })
        let gap = halfway(star.position), last = dashed.count - 1
        XCTAssertLessThan(value(dashed[last], gap), 0.1, "Dashed keeps the pause dark")
        XCTAssertGreaterThan(value(smooth[last], gap) - value(dashed[last], gap), star.flux * 0.25, "Smooth draws the pause in")
        // The glow only adds light, and only in the sky: Smooth less the still with every pause filled.
        var filled = settings; filled.fillGaps = true
        let still = try merger.render(filled, engine: .gpu).rgba
        let added = zip(smooth[last], still).map { $0 - $1 }
        XCTAssertGreaterThan(added.min() ?? -1, -0.001)
        XCTAssertGreaterThan(added.reduce(0, +), 1)
        // A glow, not a haze: the typical sky pixel, away from the stars, gains nothing.
        let sky = (0..<(w * SyntheticNight.height)).filter { Double($0 / w) < SyntheticNight.skyline(Double($0 % w)) - 10 }.map { added[$0 * 4 + 1] }.sorted()
        XCTAssertLessThan(sky[sky.count / 2], 0.0005)
        let ground = ((SyntheticNight.height - 20) * w + w / 2) * 4
        XCTAssertEqual(added[ground], 0, accuracy: 0.0005, "The ground doesn't glow")
        // Stronger glow adds more of the same halo.
        var glowAdded: [StarTrailsVideoGlow: Float] = [:]
        for glow in [StarTrailsVideoGlow.light, .strong] {
            try await merger.animationFrames(settings, trails: .smooth, glow: glow, frames: { $0 == last }) { _, raster in
                glowAdded[glow] = zip(raster.rgba, still).map { $0 - $1 }.reduce(0, +)
            }
        }
        XCTAssertEqual(try XCTUnwrap(glowAdded[.strong]) / XCTUnwrap(glowAdded[.light]), 4, accuracy: 0.05)
        // Frames are handed over only as large as the video needs.
        var small: PanoramaRaster?
        try await merger.animationFrames(settings, trails: .smooth, longEdge: 480, frames: { $0 == last }) { _, raster in small = raster }
        let shrunk = try XCTUnwrap(small)
        XCTAssertEqual([shrunk.width, shrunk.height], [480, 320])
        let mean = { (rgba: [Float]) in rgba.enumerated().filter { $0.offset % 4 == 1 }.map(\.element).reduce(0, +) / Float(rgba.count / 4) }
        XCTAssertEqual(mean(shrunk.rgba), mean(smooth[last]), accuracy: mean(smooth[last]) * 0.05, "Shrinking keeps the light")
    }

    func testMeteorsFadeOutOfTheVideo() async throws {
        try TestTier.requireSlow()
        let merger = try StarTrailsMerger(urls: try photos())
        let analysis = try merger.analyze()
        let meteor = try XCTUnwrap(analysis.lines.first { $0.kind == .meteor && $0.frame == night.meteorFrame }, "\(analysis.lines)")
        let fade = StarTrailsMeteorFade(hold: 1, fade: 2)
        for (age, strength) in [(0, Float(1)), (1, pow(2 / 3, 2.2)), (2, pow(1 / 3, 2.2)), (3, 0)] { XCTAssertEqual(fade.strength(age: age), strength, accuracy: 0.0001) }
        XCTAssertEqual(StarTrailsMeteorFade(hold: 2, fade: 0).strength(age: 2), 0, "No fade: gone at once")
        XCTAssertLessThan(night.meteorFrame + fade.length, night.count, "The meteor must be gone before the last frame")
        let middle = (night.meteor.start + night.meteor.end) / 2
        let p = (Int(middle.y) * SyntheticNight.width + Int(middle.x)) * 4 + 1
        var staying: [Int: Float] = [:], fading: [Int: Float] = [:], without: [Int: Float] = [:]
        var excluded = StarTrailsSettings(); excluded.choices = [meteor.id: false]
        try await merger.animationFrames(StarTrailsSettings(), trails: .dashed) { index, raster in staying[index] = raster.rgba[p] }
        try await merger.animationFrames(StarTrailsSettings(), trails: .dashed, meteorFade: fade) { index, raster in fading[index] = raster.rgba[p] }
        try await merger.animationFrames(excluded, trails: .dashed) { index, raster in without[index] = raster.rgba[p] }
        let at = night.meteorFrame, last = night.count - 1
        // As bright as ever in its own photo's frame; staying to the end without the fade, gone with it.
        XCTAssertGreaterThan(fading[at]! - without[at]!, 0.05)
        XCTAssertEqual(fading[at]!, staying[at]!, accuracy: 0.05)
        XCTAssertGreaterThan(staying[last]! - without[last]!, 0.05)
        XCTAssertEqual(fading[last]!, without[last]!, accuracy: 0.01)
    }

    func testStarTrailsDrawTrailsAndLeaveOutAircraft() throws {

        try TestTier.requireSlow()
        let merger = try StarTrailsMerger(urls: try photos())
        let analysis = try merger.analyze()
        XCTAssertEqual(analysis.frames.count, night.count)
        var settings = StarTrailsSettings()
        let trails = try merger.previewValues(settings)
        let w = SyntheticNight.width
        // A bright star is bright at its place in the first and the last photo.
        let star = night.stars.filter { $0.flux > 0.4 && $0.position.x > 100 && $0.position.x < 860 && $0.position.y > 60 && $0.position.y < 380 }.first!
        for frame in [0, night.count - 1] {
            let p = SyntheticNight.move(star.position, to: frame)
            XCTAssertGreaterThan(value(trails, w, Int(p.x.rounded()), Int(p.y.rounded())).y, star.flux * 0.6)
        }
        // Aircraft lines continue across three photos: left out by default, kept when included.
        let aircraft = night.aircraft(1) + SIMD2(40, -6)
        let without = value(trails, w, Int(aircraft.x), Int(aircraft.y)).y
        let tracks = analysis.lines.filter { $0.kind == .track }
        XCTAssertEqual(Set(tracks.map(\.frame)), Set(night.aircraftFrames), "\(analysis.lines)")
        XCTAssertFalse(tracks.contains(where: settings.includes))
        settings.choices = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, true) })
        let with = value(try merger.previewValues(settings), w, Int(aircraft.x), Int(aircraft.y)).y
        XCTAssertGreaterThan(with - without, 0.05)
        // The meteor stays in the trails by default, and leaves when excluded.
        let meteor = try XCTUnwrap(analysis.lines.first { $0.kind == .meteor && $0.frame == night.meteorFrame }, "\(analysis.lines)")
        XCTAssertTrue(settings.includes(meteor))
        let middle = (night.meteor.start + night.meteor.end) / 2, mx = Int(middle.x), my = Int(middle.y)
        let kept = value(trails, w, mx, my).y
        settings.choices = [meteor.id: false]
        let excluded = value(try merger.previewValues(settings), w, mx, my).y
        XCTAssertGreaterThan(kept - excluded, 0.1, "the excluded meteor should leave the trails")
        settings = StarTrailsSettings()
        // Hot pixels are found where they stay put, and repaired in the full-size result.
        let hot = Set(merger.internalAnalyzer.hotPixels)
        for (x, y) in SyntheticNight.hotPixels { XCTAssertTrue(hot.contains(y * w + x), "hot pixel at \(x), \(y)") }
        XCTAssertLessThan(hot.count, 40, "stars move, so they are not hot pixels")
        let full = try merger.render(StarTrailsSettings(), engine: .gpu)
        for (x, y) in SyntheticNight.hotPixels {
            let p = (y * w + x) * 4, around = ((y + 3) * w + x) * 4
            XCTAssertLessThan(full.rgba[p + 1] - full.rgba[around + 1], 0.08, "hot pixel at \(x), \(y) left in the trails")
        }
        // One Photo keeps that photo's sky, so the last photo's glow stays out, and the trails stay.
        let clear = night.pixels(0, noise: false)
        let gx = Int(SyntheticNight.glow.center.x), gy = Int(SyntheticNight.glow.center.y)
        let literal = value(try merger.previewValues(settings), w, gx, gy).y
        XCTAssertGreaterThan(literal - clear[gy * w + gx].y, SyntheticNight.glow.level * 0.6, "the literal maximum keeps the glow")
        settings.sky = .onePhoto; settings.skyPhoto = 0
        let overPhoto = try merger.previewValues(settings)
        // Averaged over 9 × 9 pixels: the chosen photo's own noise, plus the slight lift any maximum of noise has.
        func area(_ values: [Float]?, _ scene: [SIMD3<Float>]?) -> Float {
            var sum: Float = 0
            for dy in -4...4 { for dx in -4...4 { sum += values.map { value($0, w, gx + dx, gy + dy).y } ?? scene![(gy + dy) * w + gx + dx].y } }
            return sum / 81
        }
        XCTAssertLessThan(area(overPhoto, nil) - area(nil, clear), SyntheticNight.glow.level * 0.4, "one photo's sky leaves the glow out")
        for frame in [0, night.count - 1] {
            let p = SyntheticNight.move(star.position, to: frame)
            XCTAssertGreaterThan(value(overPhoto, w, Int(p.x.rounded()), Int(p.y.rounded())).y, star.flux * 0.5, "trail over one photo's sky in photo \(frame)")
        }
        let gpuOver = try merger.render(settings, engine: .gpu), cpuOver = try merger.render(settings, engine: .cpu)
        XCTAssertEqual(gpuOver.rgba[(gy * w + gx) * 4 + 1], cpuOver.rgba[(gy * w + gx) * 4 + 1], accuracy: 0.005)
        XCTAssertEqual(gpuOver.rgba[(gy * w + gx) * 4 + 1], value(overPhoto, w, gx, gy).y, accuracy: 0.02)
        // Fill Gaps draws the motion through the pause between photos, midway between a star's places in two photos.
        settings = StarTrailsSettings()
        let pause = (SyntheticNight.move(star.position, to: 2) + SyntheticNight.move(star.position, to: 3)) / 2
        let px = Int(pause.x.rounded()), py = Int(pause.y.rounded())
        let unfilled = value(try merger.previewValues(settings), w, px, py).y
        settings.fillGaps = true
        XCTAssertEqual(merger.filledGaps(settings), night.count - 1)
        let filled = value(try merger.previewValues(settings), w, px, py).y
        XCTAssertGreaterThan(filled - unfilled, star.flux * 0.4, "the pause should be drawn")
        let gpuFilled = try merger.render(settings, engine: .gpu), cpuFilled = try merger.render(settings, engine: .cpu)
        XCTAssertGreaterThan(gpuFilled.rgba[(py * w + px) * 4 + 1] - unfilled, star.flux * 0.4)
        XCTAssertEqual(gpuFilled.rgba[(py * w + px) * 4 + 1], cpuFilled.rgba[(py * w + px) * 4 + 1], accuracy: 0.01)
        settings.fillGaps = false
        // Keep Star Colors takes each pixel's color from one photo.
        settings.keepStarColors = true
        XCTAssertNoThrow(try merger.previewValues(settings))
    }

    func testHandChoicesSurviveAnalyzingAgainOnlyForTheSameLines() {
        func line(_ id: Int, _ frame: Int, _ length: Double) -> NightSkyLineInfo { NightSkyLineInfo(id: id, frame: frame, length: length, kind: .track, group: 0, thumbnail: nil) }
        var settings = StarTrailsSettings(); settings.choices = [1: true]
        let old = [line(0, 2, 120), line(1, 4, 300)]
        settings.keepChoices(from: old, to: [line(0, 2, 120.5), line(1, 4, 299)])
        XCTAssertEqual(settings.choices, [1: true])
        settings.keepChoices(from: old, to: [line(0, 4, 300)])
        XCTAssertEqual(settings.choices, [:], "id 0 now names another line")
    }

    /// A line is restored as its light above its own photo's sky, read beside it: outside the footprint, on both
    /// sides, with a star under one probe left out.
    func testALinesOwnSkyIsReadBesideIt() {
        let line = NightSkyLine(frame: 0, start: SIMD2(100, 100), end: SIMD2(100, 300), width: 4, pixels: 0, peak: 1)
        let probes = line.skyProbes(SIMD2(103, 200))
        XCTAssertEqual(probes.count, 6)
        for probe in probes {
            XCTAssertEqual(probe.y, 200, accuracy: 0.001, "level with the pixel")
            XCTAssertGreaterThan(abs(probe.x - 100), line.radius, "outside the footprint")
            XCTAssertEqual(line.coverage(probe), 0)
        }
        XCTAssertEqual(Set(probes.map { $0.x < 100 }).count, 2, "both sides")
        // A gradient across the line reads as its value at the line; one probe on a star changes nothing.
        let sky: [SIMD3<Float>] = [SIMD3(repeating: 0.30), SIMD3(repeating: 0.50), SIMD3(repeating: 0.32), SIMD3(repeating: 0.48), SIMD3(repeating: 0.34), SIMD3(repeating: 3)]
        XCTAssertEqual(NightSkyLine.localSky(sky)?.x ?? 0, 0.41, accuracy: 0.08)
        XCTAssertNil(NightSkyLine.localSky(Array(sky.prefix(2))), "too little sky to go by")
    }

    func testMeteorShowerFindsTheMeteorAndPlacesItOnTheBaseSky() throws {

        try TestTier.requireSlow()
        let merger = try MeteorShowerMerger(urls: try photos())
        let analysis = try merger.analyze()
        let meteors = analysis.lines.filter { $0.kind == .meteor }, tracks = analysis.lines.filter { $0.kind == .track }
        XCTAssertEqual(meteors.map(\.frame), [night.meteorFrame], "\(analysis.lines)")
        XCTAssertEqual(meteors.first?.length ?? 0, simd_distance(night.meteor.start, night.meteor.end), accuracy: 15)
        XCTAssertEqual(Set(tracks.map(\.frame)), Set(night.aircraftFrames))
        XCTAssertEqual(analysis.framesWithLines, [night.meteorFrame] + night.aircraftFrames)
        var settings = MeteorShowerSettings()
        settings.base = 5
        let w = SyntheticNight.width
        let result = try merger.previewValues(settings), base = night.pixels(5, noise: false)
        // The meteor is moved with the stars to where the sky stood in the base photo.
        for t in [0.3, 0.5, 0.7] {
            let p = SyntheticNight.map(night.meteor.start + (night.meteor.end - night.meteor.start) * t, from: night.meteorFrame, to: 5)
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            XCTAssertGreaterThan(value(result, w, x, y).y - base[y * w + x].y, 0.08, "meteor at \(p)")
        }
        // Turning it down leaves the base sky.
        settings.choices[meteors[0].id] = false
        let without = try merger.previewValues(settings)
        let p = SyntheticNight.map((night.meteor.start + night.meteor.end) / 2, from: night.meteorFrame, to: 5)
        XCTAssertLessThan(abs(value(without, w, Int(p.x), Int(p.y)).y - base[Int(p.y) * w + Int(p.x)].y), 0.03)
        // As captured, the meteor stays where its own photo recorded it.
        settings.choices = [:]; settings.asCaptured = true
        let captured = try merger.previewValues(settings)
        let recorded = (night.meteor.start + night.meteor.end) / 2
        XCTAssertGreaterThan(value(captured, w, Int(recorded.x), Int(recorded.y)).y - base[Int(recorded.y) * w + Int(recorded.x)].y, 0.08)
        settings.asCaptured = false
        // A ground pixel is the base photo's own.
        let ground = (x: 300, y: 600)
        XCTAssertEqual(value(result, w, ground.x, ground.y).y, base[ground.y * w + ground.x].y, accuracy: 0.03)
        // The preview writes the result's DNG at its own size, so the app can develop it as the result will be.
        let preview = try merger.preview(settings)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: file) }
        try preview.write(to: file)
        let info = try RawRenderer(sourceURL: file).info
        XCTAssertTrue(info.isRAW)
        XCTAssertEqual([info.width, info.height], [preview.image.width, preview.image.height])
    }

    /// Both engines draw the same full-size result for each tool, and the full size matches the preview here, where
    /// the photos are smaller than the analysis size.
    func testGPUAndCPUAgree() throws {
        try TestTier.requireSlow()
        let urls = try photos()
        func compare(_ a: PanoramaRaster, _ b: PanoramaRaster, _ name: String, tolerance: Double = 0.001) {
            XCTAssertEqual(a.width, b.width)
            var worst: Float = 0, over = 0
            for i in stride(from: 0, to: a.rgba.count, by: 4) {
                let d = max(abs(a.rgba[i] - b.rgba[i]), abs(a.rgba[i + 1] - b.rgba[i + 1]), abs(a.rgba[i + 2] - b.rgba[i + 2]))
                worst = max(worst, d)
                if d > 2e-3 { over += 1 }
            }
            // Half-float development and float coordinates differ from the CPU only at sky-validity edges.
            XCTAssertLessThan(Double(over) / Double(a.rgba.count / 4), tolerance, "\(name): worst \(worst)")
        }
        let trails = try StarTrailsMerger(urls: urls)
        _ = try trails.analyze()
        compare(try trails.render(StarTrailsSettings(), engine: .gpu), try trails.render(StarTrailsSettings(), engine: .cpu), "star trails")
        let denoiser = try NightSkyDenoiser(urls: urls)
        _ = try denoiser.analyze()
        var denoise = NightSkyDenoiseSettings(); denoise.reference = 1
        compare(try denoiser.render(denoise, engine: .gpu), try denoiser.render(denoise, engine: .cpu), "denoise")
        denoise.rejectOutliers = true
        compare(try denoiser.render(denoise, engine: .gpu), try denoiser.render(denoise, engine: .cpu), "denoise rejecting outliers",
                tolerance: 0.004) // keeping or rejecting is a yes or no, so half-float development flips a few borderline samples
        let meteors = try MeteorShowerMerger(urls: urls)
        _ = try meteors.analyze()
        var shower = MeteorShowerSettings(); shower.base = 5; shower.skyPhotos = 20
        let gpu = try meteors.render(shower, engine: .gpu)
        compare(gpu, try meteors.render(shower, engine: .cpu), "meteor shower")
        var captured = shower; captured.asCaptured = true
        compare(try meteors.render(captured, engine: .gpu), try meteors.render(captured, engine: .cpu), "meteor shower as captured")
        let preview = try meteors.previewValues(shower)
        let p = SyntheticNight.map((night.meteor.start + night.meteor.end) / 2, from: night.meteorFrame, to: 5)
        let i = Int(p.y) * gpu.width + Int(p.x)
        XCTAssertEqual(gpu.rgba[i * 4 + 1], preview[i * 3 + 1], accuracy: 0.02)
    }

    func testMergeWritesALinearDNG() throws {

        try TestTier.requireSlow()
        let merger = try NightSkyDenoiser(urls: try photos())
        _ = try merger.analyze()
        let url = Self.directory.appendingPathComponent("denoised.dng")
        try merger.merge(NightSkyDenoiseSettings(), to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        XCTAssertEqual(Int(raw.nativeSize.width), SyntheticNight.width)
        XCTAssertEqual(Int(raw.nativeSize.height), SyntheticNight.height)
    }
}
