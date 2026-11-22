import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import CevicheCore

/// Runs HDR merge, panorama stitching and stacking on real photos when `CEVICHE_MERGE_SAMPLES` names a folder, writing
/// pictures to `CEVICHE_MERGE_OUTPUT` (or a temporary folder) for inspection. Skipped otherwise.
final class MergeSampleTests: XCTestCase {
    private func samples() throws -> (urls: [URL], output: URL) {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_MERGE_SAMPLES"] else { throw XCTSkip("Set CEVICHE_MERGE_SAMPLES to a folder of photos") }
        let only = ProcessInfo.processInfo.environment["CEVICHE_MERGE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["arw", "cr2", "cr3", "nef", "raf", "jpg", "jpeg", "tif", "tiff", "heic"].contains($0.pathExtension.lowercased()) }
            .filter { only == nil || only!.contains($0.lastPathComponent) }
            .filter { !$0.lastPathComponent.lowercased().contains("hdr") && !$0.lastPathComponent.lowercased().contains("pano") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEVICHE_MERGE_OUTPUT"] ?? NSTemporaryDirectory() + "MergeSamples")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (urls, output)
    }

    static func save(_ image: CGImage?, _ url: URL) {
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The raster scaled by 2^stops, then drawn as the merge preview draws it.
    static func exposed(_ raster: PanoramaRaster, stops: Float, maxDimension: Int = 2000) -> CGImage? {
        let gain = exp2(stops)
        return HDRMergeFinishing.picture(PanoramaRaster(width: raster.width, height: raster.height, rgba: raster.rgba.enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element * gain }),
                                         maxDimension: maxDimension)
    }

    /// Develops each photo linear at `CEVICHE_MERGE_LONG_EDGE` (2400 by default), as the merges do, into raw float32 RGBA
    /// files (`name.f32`, preceded by width and height as int32) for experiments outside the app.
    func testDumpLinearFrames() throws {
        let (urls, output) = try samples()
        let longEdge = ProcessInfo.processInfo.environment["CEVICHE_MERGE_LONG_EDGE"].flatMap(Int.init) ?? 2400
        let frames = try urls.map { try HDRMergeDecoder.metadata($0) }
        let middle = frames[frames.count / 2]
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
        for (url, metadata) in zip(urls, frames) {
            let frame = try HDRMergeDecoder.decode(url, metadata: metadata, longEdge: longEdge, whiteBalance: (middle.temperature, middle.tint), context: context)
            var data = Data()
            withUnsafeBytes(of: Int32(frame.width)) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(frame.height)) { data.append(contentsOf: $0) }
            frame.pixels.withUnsafeBytes { data.append(contentsOf: $0) }
            try data.write(to: output.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".f32"))
            print("\(metadata.filename) \(frame.width)×\(frame.height) recorded \(metadata.recordedStops ?? .nan) focal35 \(metadata.panorama.focalLength35mm ?? .nan)")
        }
    }

    func testHDRMergeOnSamples() throws {
        let (urls, output) = try samples()
        let merger = try HDRMerger(urls: urls)
        let start = Date()
        let analysis = try merger.analyze { fraction, message in print(String(format: "%6.1f s %3.0f%% %@", Date().timeIntervalSince(start), fraction * 100, message)) }
        for frame in analysis.frames {
            print("\(frame.filename) stops \(String(format: "%.2f", frame.stops)) recorded \(frame.recordedStops.map { String(format: "%.2f", $0) } ?? "-") shift \(frame.shift.map { "\($0)" } ?? "nil")")
        }
        let deghosting = ProcessInfo.processInfo.environment["CEVICHE_MERGE_DEGHOST"].flatMap(HDRDeghosting.init(rawValue:)) ?? .medium
        var settings = HDRMergeSettings()
        settings.deghosting = deghosting
        if let reference = ProcessInfo.processInfo.environment["CEVICHE_MERGE_REFERENCE"].flatMap(Int.init) { settings.reference = reference }
        let preview = try merger.preview(settings)
        Self.save(preview.image, output.appendingPathComponent("hdr-preview.png"))
        Self.save(preview.motion, output.appendingPathComponent("hdr-motion.png"))
        print("motion coverage \(preview.motionCoverage)")
        let raster = try merger.previewRaster(settings)
        for stops: Float in [-4, -2, 0, 2, 4] {
            Self.save(Self.exposed(raster, stops: stops), output.appendingPathComponent("hdr-preview-\(Int(stops)).png"))
        }
        if ProcessInfo.processInfo.environment["CEVICHE_MERGE_FULL"] != nil {
            let (full, _, _) = try merger.mergedRaster(settings, engine: .gpu)
            for stops: Float in [-4, 0, 4] {
                Self.save(Self.exposed(full, stops: stops, maxDimension: 3000), output.appendingPathComponent("hdr-full-\(Int(stops)).png"))
            }
            try merger.merge(settings, to: output.appendingPathComponent("hdr.dng"))
        }
    }

    func testStackOnSamples() throws {
        let (urls, output) = try samples()
        let stacker = try PhotoStacker(urls: urls)
        let start = Date()
        let analysis = try stacker.analyze { fraction, message in print(String(format: "%6.1f s %3.0f%% %@", Date().timeIntervalSince(start), fraction * 100, message)) }
        for frame in analysis.frames {
            print("\(frame.filename) stops \(String(format: "%.2f", frame.stops)) shift \(frame.shift.map { "\($0)" } ?? "nil") rotation \(frame.rotationDegrees ?? .nan)")
        }
        for mode in PhotoStackMode.allCases {
            var settings = PhotoStackSettings()
            settings.mode = mode
            let t = Date()
            Self.save(try stacker.preview(settings).image, output.appendingPathComponent("stack-preview-\(mode.rawValue).png"))
            print("preview \(mode.rawValue) \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        }
        if ProcessInfo.processInfo.environment["CEVICHE_MERGE_FULL"] != nil {
            var settings = PhotoStackSettings()
            for engine in [HDRMerger.Engine.gpu, .cpu] {
                let t = Date()
                let full = try stacker.stackedRaster(settings, engine: engine)
                print("full \(engine) \(full.width)×\(full.height) \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
                Self.save(HDRMergeFinishing.picture(full, maxDimension: 3000), output.appendingPathComponent("stack-full-\(engine).png"))
            }
            settings.mode = .median
            try stacker.stack(settings, to: output.appendingPathComponent("stack.dng"))
        }
    }

    func testPanoramaOnSamples() throws {
        let (urls, output) = try samples()
        let merger = try PanoramaMerger(urls: urls, useGPU: ProcessInfo.processInfo.environment["CEVICHE_MERGE_CPU"] == nil)
        let start = Date()
        let alignment = try merger.align { fraction, message in print(String(format: "%6.1f s %3.0f%% %@", Date().timeIntervalSince(start), fraction * 100, message)) }
        print("included \(alignment.included.map { alignment.filenames[$0] }) excluded \(alignment.excluded)")
        print(String(format: "error median %.2f px p95 %.2f px; projections %@", alignment.medianErrorPixels, alignment.p95ErrorPixels, alignment.available.map(\.rawValue).sorted().joined(separator: ",")))
        for projection in alignment.available.sorted(by: { $0.rawValue < $1.rawValue }) {
            var settings = PanoramaSettings()
            settings.projection = projection
            let t = Date()
            Self.save(try merger.preview(settings).image, output.appendingPathComponent("pano-\(projection.rawValue).png"))
            print("preview \(projection.rawValue) \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        }
        // Boundary Warp, Auto Crop and Fill Edges on the suggested projection.
        for (name, warp, crop, fill) in [("warp100", 1.0, false, false), ("warp50-crop", 0.5, true, false),
                                         ("fill", 0.0, false, true), ("warp50-fill", 0.5, false, true)] {
            guard !fill || PanoramaSettings.canFillEdges else { continue }
            var settings = PanoramaSettings()
            settings.projection = alignment.suggested; settings.boundaryWarp = warp; settings.autoCrop = crop; settings.fillEdges = fill
            let t = Date()
            Self.save(try merger.preview(settings).image, output.appendingPathComponent("pano-\(alignment.suggested.rawValue)-\(name).png"))
            print("preview \(name) \(String(format: "%.2f", Date().timeIntervalSince(t))) s")
        }
        if ProcessInfo.processInfo.environment["CEVICHE_MERGE_FULL"] != nil {
            var settings = PanoramaSettings()
            settings.projection = alignment.suggested
            settings.boundaryWarp = 0.5; settings.fillEdges = PanoramaSettings.canFillEdges
            let url = output.appendingPathComponent("pano.dng")
            try? FileManager.default.removeItem(at: url)
            let t = Date()
            try merger.merge(settings, to: url)
            print("full \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
        }
    }

    /// Features, matches and RANSAC inliers for each pair, to see why photos don't join.
    func testPanoramaPairs() throws {
        let (urls, _) = try samples()
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
        let frames = try urls.map(PanoramaDecoder.metadata)
        let planes = try urls.map { LuminancePlane(try PanoramaDecoder.decode($0, longEdge: 1400, whiteBalance: (frames[0].temperature, frames[0].tint), context: context), longEdge: 1400) }
        let features = planes.map { PanoramaFeatures.detect(HDRMergeAlignment.equalized($0, floor: 1e-4), limit: 1800) }
        let cameras = zip(frames, planes).map { f, p in PanoramaCamera(width: Double(p.width), height: Double(p.height), focal: (f.focalLength35mm ?? 50) * hypot(Double(p.width), Double(p.height)) / hypot(36, 24)) }
        for a in urls.indices { for b in a + 1..<urls.count {
            let matches = PanoramaFeatures.match(features[a], features[b], ratio: 0.78)
            let fit = PanoramaGeometry.estimate(matches, a: cameras[a], b: cameras[b], threshold: 3)
            let starMatches = PanoramaStars.matches(PanoramaStars.detect(planes[a]), PanoramaStars.detect(planes[b]), cameraA: cameras[a], cameraB: cameras[b], threshold: 3, minimum: 18)
            guard starMatches != nil || (fit?.1.count ?? 0) >= 18 else { continue }
            print("stars \(starMatches?.count ?? 0) \(frames[a].filename)-\(frames[b].filename) features \(features[a].count)/\(features[b].count) matches \(matches.count) inliers \(fit?.1.count ?? 0) median \(fit.map { String(format: "%.2f", $0.2) } ?? "-")")
        }}
    }

    /// The CPU fallbacks against Metal on real photos: prints mean and 99.9th-percentile absolute difference of the
    /// full-size HDR merge (CEVICHE_MERGE_KIND=hdr) or the panorama preview blend (=pano) and the stack (=stack).
    func testCPUMatchesGPUOnSamples() throws {
        let (urls, _) = try samples()
        func compare(_ a: PanoramaRaster, _ b: PanoramaRaster, _ label: String) {
            XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
            var differences: [Float] = [], scale: Float = 0
            for i in stride(from: 0, to: a.rgba.count, by: 4) where a.rgba[i + 3] > 0 && b.rgba[i + 3] > 0 {
                for c in 0..<3 { differences.append(abs(a.rgba[i + c] - b.rgba[i + c])); scale = max(scale, a.rgba[i + c]) }
            }
            differences.sort()
            let mean = differences.reduce(0, +) / Float(max(1, differences.count))
            let p999 = differences.isEmpty ? 0 : differences[min(differences.count - 1, differences.count * 999 / 1000)]
            print(String(format: "%@ CPU vs GPU: mean %.5f, p99.9 %.5f (relative to brightest %.3f: mean %.4f%%)", label, mean, p999, scale, 100 * mean / max(scale, 1e-6)))
            XCTAssertLessThan(mean / max(scale, 1e-6), 0.002, label)
        }
        switch ProcessInfo.processInfo.environment["CEVICHE_MERGE_KIND"] ?? "hdr" {
        case "hdr":
            let merger = try HDRMerger(urls: urls)
            _ = try merger.analyze()
            let settings = HDRMergeSettings()
            compare(try merger.mergedRaster(settings, engine: .gpu).0, try merger.mergedRaster(settings, engine: .cpu).0, "HDR full size")
        case "stack":
            let stacker = try PhotoStacker(urls: urls)
            _ = try stacker.analyze()
            let settings = PhotoStackSettings()
            compare(try stacker.stackedRaster(settings, engine: .gpu), try stacker.stackedRaster(settings, engine: .cpu), "Stack full size")
        default:
            let gpu = try PanoramaMerger(urls: urls), cpu = try PanoramaMerger(urls: urls, useGPU: false)
            let alignment = try gpu.align(); _ = try cpu.align()
            for projection in alignment.available.sorted(by: { $0.rawValue < $1.rawValue }) {
                var settings = PanoramaSettings(); settings.projection = projection
                compare(try gpu.previewRaster(settings), try cpu.previewRaster(settings), "Panorama \(projection.rawValue)")
            }
        }
    }
}
