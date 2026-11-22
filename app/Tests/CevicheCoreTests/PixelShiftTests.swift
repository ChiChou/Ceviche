import XCTest
import CevicheTestSupport
import CoreImage
import simd
import ImageIO
@testable import CevicheCore
import CameraRaw

/// Pixel Shift on real Sony sets (`TestSamples.pixelShift`): the tests skip without them.
final class PixelShiftTests: XCTestCase {
    private func set(_ role: String) throws -> [URL] {
        try TestSamples.requireFiles(role, extensions: ["arw"])
    }

    func testReadsSonyRawTags() throws {
        let four = try set(TestSamples.pixelShift.four), sixteen = try set(TestSamples.pixelShift.sixteen)
        let info = try SonyARW.frame(four[0])
        XCTAssertEqual(info.model, "ILCE-7RM4")
        XCTAssertEqual([info.width, info.height], [9600, 6376])
        XCTAssertEqual(info.cfa, [0, 1, 1, 2])
        XCTAssertEqual(info.black, [512, 512, 512, 512])
        XCTAssertEqual(info.white, 16383)
        XCTAssertEqual([info.crop.x, info.crop.y, info.crop.width, info.crop.height], [32, 20, 9504, 6336])
        XCTAssertGreaterThan(info.whiteBalance[0], 1.5)
        XCTAssertEqual(info.sonyShift?.shots, 4)
        XCTAssertEqual(Set(try four.map { try SonyARW.frame($0).sonyShift!.index }), [1, 2, 3, 4])
        let places = try sixteen.map { try SonyARW.frame($0).sonyShift! }
        XCTAssertEqual(Set(places.map(\.index)), Set(1...16))
        XCTAssertEqual(Set(places.map(\.group)).count, 1)
        // A photo that isn't a Sony RAW says so.
        XCTAssertThrowsError(try SonyARW.frame(URL(fileURLWithPath: #filePath)))
    }

    /// Four shots, on a piece of the sensor: Sony's sensor path, colour and exposure that match Apple's development of
    /// one shot, the GPU and the CPU alike, and no motion in a still scene.
    func testFourShotMergeMatchesAppleColour() throws {
        for folder in TestTier.slow ? [TestSamples.pixelShift.stillLife, TestSamples.pixelShift.four] : [TestSamples.pixelShift.four] {
            let urls = try set(folder)
            let info = try SonyARW.frame(urls[0])
            let window = (x: (info.width / 2 - 400) & ~1, y: (info.height / 2 - 300) & ~1, width: 800, height: 600)
            // Given out of order, as a selection may be.
            let merger = try PixelShiftMerger(urls: urls.reversed())
            merger.window = window
            let analysis = try merger.analyze()
            XCTAssertEqual(analysis.frames.map(\.filename), urls.map(\.lastPathComponent))
            XCTAssertEqual(analysis.frames.map { [Int($0.shift.x.rounded()), Int($0.shift.y.rounded())] }, [[0, 0], [0, 1], [-1, 1], [-1, 0]], folder)
            let raster = try merger.mergedRaster()
            XCTAssertEqual([raster.width, raster.height], [800, 600])

            let cpu = try PixelShiftMerger(urls: urls, engine: PixelShiftCPU())
            cpu.window = window
            _ = try cpu.analyze()
            let reference = try cpu.mergedRaster()
            var difference: Float = 0
            for i in raster.rgba.indices { difference = max(difference, abs(raster.rgba[i] - reference.rgba[i])) }
            XCTAssertLessThan(difference, 2e-3, folder)

            // Apple's development of the same piece, with nothing done to its geometry.
            let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: urls[0]))
            raw.orientation = .up; raw.exposure = 0; raw.boostAmount = 0; raw.boostShadowAmount = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
            var image = try XCTUnwrap(raw.outputImage)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            // Core Image counts rows from the bottom; the window is in sensor rows from the top, inside the camera's crop.
            let top = window.y - info.crop.y, left = window.x - info.crop.x
            let bounds = CGRect(x: CGFloat(left), y: image.extent.height - CGFloat(top + window.height), width: 800, height: 600)
            var apple = [Float](repeating: 0, count: 800 * 600 * 4)
            apple.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: 800 * 16, bounds: bounds, format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
            var ours = SIMD3<Double>.zero, theirs = SIMD3<Double>.zero, compared = 0, off = 0
            let side = 20
            for by in 0..<(600 / side) { for bx in 0..<(800 / side) {
                var sum = SIMD3<Double>.zero, a = SIMD3<Double>.zero
                for y in (by * side)..<((by + 1) * side) { for x in (bx * side)..<((bx + 1) * side) {
                    let p = (y * 800 + x) * 4
                    sum += SIMD3(Double(raster.rgba[p]), Double(raster.rgba[p + 1]), Double(raster.rgba[p + 2]))
                    a += SIMD3(Double(apple[p]), Double(apple[p + 1]), Double(apple[p + 2]))
                } }
                sum /= Double(side * side); a /= Double(side * side)
                guard a.max() < 0.5, a.min() > 0.02 else { continue }
                ours += sum; theirs += a; compared += 1
                // Against the block's brightness: a saturated colour's smallest channel is all rounding.
                if simd_reduce_max(simd_abs(sum - a)) / simd_dot(a, SIMD3(0.2126, 0.7152, 0.0722)) > 0.1 { off += 1 }
            } }
            XCTAssertGreaterThan(compared, 100, folder)
            let ratio = ours / theirs
            for c in 0..<3 { XCTAssertEqual(ratio[c], 1, accuracy: 0.03, "\(folder) channel \(c)") }
            XCTAssertLessThan(Double(off) / Double(compared), 0.1, folder)

            let preview = try merger.preview()
            XCTAssertEqual([preview.image.width, preview.image.height], [800, 600])
            XCTAssertLessThan(preview.motionCoverage, 0.02, folder)
        }
    }

    func testIncompleteSetIsRefused() throws {
        let four = try set(TestSamples.pixelShift.four), sixteen = try set(TestSamples.pixelShift.sixteen)
        XCTAssertThrowsError(try PixelShiftMerger(urls: Array(four.prefix(3))).analyze())
        XCTAssertThrowsError(try PixelShiftMerger(urls: Array(four.prefix(3)) + [sixteen[0]]).analyze())
    }

    /// Sixteen shots double the width and height, and write a DNG the app's decoder opens at that size.
    func testSixteenShotMerge() async throws {
        try TestTier.requireSlow()
        let urls = try set(TestSamples.pixelShift.sixteen)
        let info = try SonyARW.frame(urls[0])
        let merger = try PixelShiftMerger(urls: urls)
        merger.window = (x: (info.width / 2 - 300) & ~1, y: (info.height / 2 - 200) & ~1, width: 600, height: 400)
        let analysis = try merger.analyze()
        XCTAssertEqual([analysis.width, analysis.height], [1200, 800])
        // Four sets of four, each half a pixel from the others.
        let lattices = Set(analysis.frames.map { [Int((2 * $0.shift.x).rounded()) & 1, Int((2 * $0.shift.y).rounded()) & 1] })
        XCTAssertEqual(lattices.count, 4)
        let raster = try merger.mergedRaster()
        XCTAssertEqual([raster.width, raster.height], [1200, 800])
        // Neighbouring pixels come from different sets: a set off in brightness or place would show as a checkerboard.
        var even = 0.0, odd = 0.0
        for y in stride(from: 100, to: 700, by: 1) { for x in stride(from: 100, to: 1100, by: 1) {
            let v = Double(raster.rgba[(y * 1200 + x) * 4 + 1])
            if (x + y) & 1 == 0 { even += v } else { odd += v }
        } }
        XCTAssertEqual(even / odd, 1, accuracy: 0.005)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pixelshift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("merged.dng")
        try merger.merge(to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        XCTAssertEqual([Int(raw.nativeSize.width), Int(raw.nativeSize.height)], [1200, 800])

        // Export JPEG: the merge developed with the photo defaults, at the merged size and full quality.
        let renderer = try RawRenderer(sourceURL: url)
        var settings = ExportSettings(); settings.select(.jpeg); settings.quality = 1; settings.profile.preset = .sRGB
        let jpeg = directory.appendingPathComponent("merged.jpg")
        try await renderer.export(to: jpeg, adjustments: renderer.info.defaults, settings: settings)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1200); XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 800)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(Int(pixel[1]), 8, "the picture isn't black")
    }
}
