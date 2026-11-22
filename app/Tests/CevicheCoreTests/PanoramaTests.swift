import XCTest
import CoreImage
import Metal
import simd
@testable import CevicheCore

final class PanoramaTests: XCTestCase {
    func testRotationFitRecoversKnownRotation() throws {
        let truth = simd_double3x3(simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3(0.2, 1, 0.1))))
        let source = (0..<20).map { i in simd_normalize(SIMD3(sin(Double(i)), cos(Double(i) * 0.7), 2)) }
        let fitted = try XCTUnwrap(PanoramaGeometry.fitRotation(source: source, target: source.map { truth * $0 }))
        for c in 0..<3 { XCTAssertLessThan(simd_length(fitted[c] - truth[c]), 1e-9) }
    }

    func testSymmetricEigenDecomposition() {
        let (values, vectors) = PanoramaGeometry.symmetricEigen([2, 1, 0, 1, 2, 0, 0, 0, 5], size: 3)
        for (value, expected) in zip(values.sorted(), [1.0, 3, 5]) { XCTAssertEqual(value, expected, accuracy: 1e-9) }
        let smallest = vectors[values.firstIndex { abs($0 - 1) < 1e-9 }!]
        XCTAssertEqual(abs(smallest[0] + smallest[1]), 0, accuracy: 1e-9)
    }

    func testSolveRecoversRotations() throws {
        // Three cameras panning about 29° apart, observing points on a sphere.
        let truthCamera = PanoramaCamera(width: 1200, height: 800, focal: 1000)
        let yaws = [-0.5, 0.0, 0.5]
        let rotations = yaws.map { simd_double3x3(simd_quatd(angle: $0, axis: SIMD3(0, 1, 0))) }
        var seed: UInt64 = 7
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 11) / Double(1 << 53) }
        let world = (0..<3000).map { _ in simd_normalize(SIMD3(random() * 2 - 1, (random() * 2 - 1) * 0.4, random() + 0.2)) }
        var features: [[PanoramaFeature]] = []
        for rotation in rotations {
            var list: [PanoramaFeature] = []
            for (index, ray) in world.enumerated() {
                guard let p = truthCamera.point(rotation.transpose * ray), p.x > 0, p.y > 0, p.x < 1200, p.y < 800 else { continue }
                var descriptor = [Float](repeating: 0, count: 128)
                descriptor[index % 128] = 1; descriptor[(index / 128) % 128] += 1; descriptor[(index * 7 / 5) % 128] += 0.5
                let norm = sqrt(descriptor.reduce(0) { $0 + $1 * $1 })
                list.append(PanoramaFeature(point: p, descriptor: descriptor.map { $0 / norm }, strength: 1))
            }
            features.append(list)
        }
        let base = [PanoramaCamera](repeating: PanoramaCamera(width: 1200, height: 800, focal: 1000), count: 3)
        let solution = try PanoramaGeometry.solve(cameras: base, features: features, pairs: [(0, 1), (1, 2), (0, 2)], threshold: 3,
                                                  minimumInliers: 10, cancelled: { false })
        XCTAssertEqual(solution.included, [0, 1, 2])
        XCTAssertLessThan(solution.medianError, 0.1)
        for i in 0..<3 {
            let relative = rotations[1].transpose * rotations[i]
            for c in 0..<3 { XCTAssertLessThan(simd_length(solution.rotations[i][c] - relative[c]), 1e-3) }
        }
    }

    func testDistortedCameraRoundTrips() {
        let camera = PanoramaCamera(width: 1200, height: 800, focal: 600, k1: -0.12, k2: 0.03)
        for point in [SIMD2(0.0, 0.0), SIMD2(1200, 800), SIMD2(611, 37), SIMD2(600, 400)] {
            let back = try! XCTUnwrap(camera.point(camera.ray(point)))
            XCTAssertLessThan(simd_distance(back, point), 1e-6)
        }
        // Barrel pulls the corner in: the corner's ray is wider than a pinhole's.
        XCTAssertGreaterThan(camera.ray(.zero).x * -1, PanoramaCamera(width: 1200, height: 800, focal: 600).ray(.zero).x * -1)
    }

    /// An ultra-wide lens with uncorrected barrel, panned 50° a frame: the lens fit, anchored on the recorded focal
    /// length, finds the barrel, and the seams close.
    func testLensFitRecoversBarrelDistortion() throws {
        let truth = PanoramaCamera(width: 1200, height: 800, focal: 600, k1: -0.1, k2: 0.02)
        let rotations = [-0.85, 0.0, 0.85].map { simd_double3x3(simd_quatd(angle: $0, axis: SIMD3(0, 1, 0))) }
        var seed: UInt64 = 11
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 11) / Double(1 << 53) }
        let world = (0..<6000).map { _ in simd_normalize(SIMD3(random() * 4 - 2, (random() * 2 - 1) * 0.7, random() * 1.2 + 0.1)) }
        var features: [[PanoramaFeature]] = []
        for rotation in rotations {
            var list: [PanoramaFeature] = []
            for (index, ray) in world.enumerated() {
                guard let p = truth.point(rotation.transpose * ray), p.x > 0, p.y > 0, p.x < 1200, p.y < 800 else { continue }
                var descriptor = [Float](repeating: 0, count: 128)
                descriptor[index % 128] = 1; descriptor[(index / 128) % 128] += 1; descriptor[(index * 7 / 5) % 128] += 0.5
                let norm = sqrt(descriptor.reduce(0) { $0 + $1 * $1 })
                list.append(PanoramaFeature(point: p, descriptor: descriptor.map { $0 / norm }, strength: 1))
            }
            features.append(list)
        }
        let pinhole = [PanoramaCamera](repeating: PanoramaCamera(width: 1200, height: 800, focal: 600), count: 3)
        let solution = try PanoramaGeometry.solve(cameras: pinhole, features: features, pairs: [(0, 1), (1, 2), (0, 2)], threshold: 3,
                                                  minimumInliers: 10, cancelled: { false })
        let fitted = PanoramaGeometry.refineLens(cameras: pinhole, edges: solution.edges, members: solution.included, anchor: solution.anchor,
                                                 rotations: solution.rotations, focalRange: 0.9...1.1, distortion: true)
        let before = PanoramaGeometry.errors(cameras: pinhole, rotations: solution.rotations, edges: solution.edges, members: Set(solution.included)).sorted()
        let after = PanoramaGeometry.errors(cameras: fitted.cameras, rotations: fitted.rotations, edges: solution.edges, members: Set(solution.included)).sorted()
        XCTAssertGreaterThan(before[before.count / 2], 0.5)
        XCTAssertLessThan(after[after.count / 2], 0.1)
        XCTAssertEqual(fitted.lens.scale, 1, accuracy: 0.02)
        XCTAssertEqual(fitted.lens.k1, -0.1, accuracy: 0.03)
    }

    /// A strip whose top and bottom edges wave, as frames do: a full warp covers the whole frame, half a warp less.
    func testBoundaryWarpFillsTheFrame() throws {
        let w = 400, h = 120
        var rgba = [Float](repeating: 0, count: w * h * 4)
        for x in 0..<w {
            let top = Int(12 + 10 * sin(Double(x) / 40)), bottom = h - Int(14 + 8 * cos(Double(x) / 33))
            for y in top..<bottom { let p = (y * w + x) * 4; rgba[p] = Float(x) / Float(w); rgba[p + 1] = 0.5; rgba[p + 2] = 0.2; rgba[p + 3] = 1 }
        }
        let image = PanoramaRaster(width: w, height: h, rgba: rgba)
        func covered(_ r: PanoramaRaster) -> Double { Double(stride(from: 3, to: r.rgba.count, by: 4).filter { r.rgba[$0] > 0.99 }.count) / Double(r.width * r.height) }
        let full = PanoramaWarp.warp(image, amount: 1), half = PanoramaWarp.warp(image, amount: 0.5)
        XCTAssertGreaterThan(covered(full), 0.995)
        XCTAssertGreaterThan(covered(half), covered(image)); XCTAssertLessThan(covered(half), covered(full))
        XCTAssertEqual(PanoramaWarp.warp(image, amount: 0).rgba, image.rgba)
        // Colour runs left to right as before: columns are only stretched up and down.
        XCTAssertEqual(full.rgba[(60 * w + 200) * 4], 0.5, accuracy: 0.02)
        // Auto Crop after a half warp keeps more than without it.
        var settings = PanoramaSettings(); settings.autoCrop = true
        let plain = try PanoramaFinishing.finish(image, settings: settings)
        settings.boundaryWarp = 0.5
        let warped = try PanoramaFinishing.finish(image, settings: settings)
        XCTAssertGreaterThan(warped.width * warped.height, plain.width * plain.height)
    }

    func testFillEdgesCoversEverything() throws {
        guard PanoramaSettings.canFillEdges else { throw XCTSkip("Big-LaMa is not installed") }
        let w = 900, h = 300
        var rgba = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where y > 30 + Int(20 * sin(Double(x) / 60)) && y < h - 25 {
            let p = (y * w + x) * 4; rgba[p] = 0.3; rgba[p + 1] = 0.4 + 0.2 * Float(y) / Float(h); rgba[p + 2] = 0.6; rgba[p + 3] = 1
        } }
        var settings = PanoramaSettings(); settings.fillEdges = true
        let filled = try PanoramaFinishing.finish(PanoramaRaster(width: w, height: h, rgba: rgba), settings: settings)
        XCTAssertTrue(stride(from: 3, to: filled.rgba.count, by: 4).allSatisfy { filled.rgba[$0] == 1 })
        XCTAssertTrue(filled.rgba.allSatisfy(\.isFinite))
        // A smooth blue gradient is continued with something like it.
        XCTAssertEqual(filled.rgba[(5 * w + 450) * 4 + 2], 0.6, accuracy: 0.15)
    }

    func testCropFindsCoveredRectangle() {
        var rgba = [Float](repeating: 0, count: 20 * 10 * 4)
        for y in 2..<8 { for x in 3..<17 { let p = (y * 20 + x) * 4; rgba[p] = 0.5; rgba[p + 1] = 0.25; rgba[p + 2] = 0.1; rgba[p + 3] = 1 } }
        let image = PanoramaRaster(width: 20, height: 10, rgba: rgba)
        let cropped = PanoramaFinishing.crop(image)
        XCTAssertEqual(cropped.width, 14); XCTAssertEqual(cropped.height, 6)
    }

    func testDNGReopensWithValuesAndHeadroom() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable in this execution environment") }
        let width = 300, height = 200
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            rgba[p] = Float(x) / Float(width) * 0.5; rgba[p + 1] = 0.25; rgba[p + 2] = Float(y) / Float(height) * 0.5; rgba[p + 3] = x < 20 ? 0 : 1
            if x >= 280 { rgba[p] = 3; rgba[p + 1] = 3; rgba[p + 2] = 3 }
        }}
        let metadata = PanoramaFrameMetadata(filename: "test.ARW", make: "Test", model: "Camera", width: width, height: height,
                                             focalLength35mm: nil, captureTime: "2023:11:14 17:13:20", temperature: 5600, tint: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let url = directory.appendingPathComponent("panorama.dng")
            let writer = PanoramaDNGWriter(metadata: metadata, baselineExposure: 0.5, preview: nil)
            try writer.write(PanoramaRaster(width: width, height: height, rgba: rgba), to: url)
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url), "CIRAWFilter can't open the DNG")
            XCTAssertEqual(Int(raw.nativeSize.width), width); XCTAssertEqual(Int(raw.nativeSize.height), height)
            let image = try XCTUnwrap(raw.outputImage)
            XCTAssertEqual(Int(image.extent.width), width)
            // Developed linearly, the file gives back what was stored, highlights above 1 included.
            raw.boostAmount = 0; raw.boostShadowAmount = 0; raw.exposure = 0
            raw.isGamutMappingEnabled = false
            if #available(macOS 26, *), raw.isHighlightRecoverySupported { raw.isHighlightRecoveryEnabled = false }
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            raw.extendedDynamicRangeAmount = 1
            let linear = try XCTUnwrap(raw.outputImage)
            func sample(_ x: Int, _ y: Int) -> [Float] {
                var pixel = [Float](repeating: 0, count: 4)
                CIContext(options: [.workingColorSpace: PanoramaDecoder.space]).render(linear, toBitmap: &pixel, rowBytes: 16,
                    bounds: CGRect(x: x, y: height - 1 - y, width: 1, height: 1), format: .RGBAf, colorSpace: PanoramaDecoder.space)
                return pixel
            }
            XCTAssertEqual(sample(150, 100)[1], 0.25 * sqrt(2), accuracy: 0.01) // the 0.5 EV baseline exposure
            XCTAssertEqual(sample(150, 100)[0], 0.25 * sqrt(2), accuracy: 0.01)
            XCTAssertGreaterThan(sample(290, 100)[1], 2)
            // White balance is baked in: as shot is the linear-sRGB profile's own white, D50.
            XCTAssertEqual(raw.neutralTemperature, 5000, accuracy: 150)
            let properties = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, metadata.captureTime)
        }
    }

    func testMergesAreDatedJustAfterTheirLastPhoto() {
        XCTAssertEqual(PanoramaFrameMetadata.captureTime(after: ["2026:10:31 23:59:58", nil, "2026:10:31 23:59:59.40", "2026:10:31 21:00:00"]), "2026:11:01 00:00:00")
        XCTAssertNil(PanoramaFrameMetadata.captureTime(after: [nil, "not a date"]))
    }
}
