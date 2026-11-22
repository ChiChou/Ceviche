import XCTest
import CevicheTestSupport
import CoreImage
import ImageIO
import simd
import CameraRaw
@testable import CevicheCore

/// Pixel Shift beyond Sony, on real sets (`TestSamples.pixelShift`): Pentax files that each hold four exposures, and a
/// Fujifilm set of sixteen. The tests skip without them.
final class PixelShiftCameraTests: XCTestCase {
    /// The merge's colour against Apple's development of the first exposure, block by block, as the Sony test does.
    private func colourRatio(_ raster: PanoramaRaster, url: URL, window: (x: Int, y: Int, width: Int, height: Int),
                             crop: (x: Int, y: Int, width: Int, height: Int)) throws -> SIMD3<Double> {
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        raw.orientation = .up; raw.exposure = 0; raw.boostAmount = 0; raw.boostShadowAmount = 0
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = false }
        var image = try XCTUnwrap(raw.outputImage)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = window.width, h = window.height
        let top = window.y - crop.y, left = window.x - crop.x
        let bounds = CGRect(x: CGFloat(left), y: image.extent.height - CGFloat(top + h), width: CGFloat(w), height: CGFloat(h))
        var apple = [Float](repeating: 0, count: w * h * 4)
        apple.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        var ours = SIMD3<Double>.zero, theirs = SIMD3<Double>.zero, compared = 0
        let side = 20
        for by in 0..<(h / side) { for bx in 0..<(w / side) {
            var sum = SIMD3<Double>.zero, a = SIMD3<Double>.zero
            for y in (by * side)..<((by + 1) * side) { for x in (bx * side)..<((bx + 1) * side) {
                let p = (y * w + x) * 4
                sum += SIMD3(Double(raster.rgba[p]), Double(raster.rgba[p + 1]), Double(raster.rgba[p + 2]))
                a += SIMD3(Double(apple[p]), Double(apple[p + 1]), Double(apple[p + 2]))
            } }
            sum /= Double(side * side); a /= Double(side * side)
            guard a.max() < 0.5, a.min() > 0.02 else { continue }
            ours += sum; theirs += a; compared += 1
        } }
        XCTAssertGreaterThan(compared, 100)
        return ours / theirs
    }

    /// The menus offer one photo only when its file type and camera can hold a whole set.
    func testOnePhotoMayHoldASetByFileTypeAndCamera() {
        XCTAssertTrue(PixelShiftMerger.mayHoldSet(filename: "k1ii.pef", camera: "PENTAX K-1 Mark II"))
        XCTAssertTrue(PixelShiftMerger.mayHoldSet(filename: "IMGP0001.DNG", camera: "PENTAX K-3 Mark III "))
        XCTAssertTrue(PixelShiftMerger.mayHoldSet(filename: "h6d.fff", camera: ""))
        XCTAssertFalse(PixelShiftMerger.mayHoldSet(filename: "IMGP0001.PEF", camera: "PENTAX K-70"))
        XCTAssertFalse(PixelShiftMerger.mayHoldSet(filename: "phone.dng", camera: "iPhone 17 Pro"))
        XCTAssertFalse(PixelShiftMerger.mayHoldSet(filename: "DSC01472.ARW", camera: "ILCE-7RM4"))
    }

    func testReadsPentaxExposures() throws {
        for url in try TestSamples.requireFiles(TestSamples.pixelShift.pentax, extensions: ["pef", "dng"]) {
            let frames = try PentaxRAW.frames(url)
            XCTAssertEqual(frames.count, 4, url.lastPathComponent)
            XCTAssertTrue(PentaxRAW.pixelShiftModels.contains(frames[0].model), frames[0].model)
            let frame = frames[0]
            XCTAssertEqual(frame.cfa, [0, 1, 1, 2])
            XCTAssertGreaterThan(frame.black[0], 0); XCTAssertGreaterThan(frame.white, 16000)
            XCTAssertGreaterThan(frame.whiteBalance[0], 1); XCTAssertGreaterThan(frame.whiteBalance[2], 1)
            // The crop is the picture Apple develops.
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
            XCTAssertEqual([frame.crop.width, frame.crop.height], [Int(raw.nativeSize.width), Int(raw.nativeSize.height)], url.lastPathComponent)
            let samples = try frame.samples(url)
            XCTAssertEqual(samples.count, frame.width * frame.height)
            let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
            XCTAssertGreaterThan(mean, Double(frame.black[0]) + 20, url.lastPathComponent)
        }
    }

    /// The four exposures are four whole-pixel positions, and the merge has Apple's colour.
    func testPentaxMerge() throws {
        for url in try TestSamples.requireFiles(TestSamples.pixelShift.pentax, extensions: ["pef", "dng"]) {
            let frame = try PentaxRAW.frames(url)[0]
            let window = (x: (frame.width / 2 - 400) & ~1, y: (frame.height / 2 - 300) & ~1, width: 800, height: 600)
            let merger = try PixelShiftMerger(urls: [url])
            merger.window = window
            let analysis = try merger.analyze()
            XCTAssertEqual(analysis.shots, 4)
            let places = Set(analysis.frames.map { [Int($0.shift.x.rounded()) & 1, Int($0.shift.y.rounded()) & 1] })
            XCTAssertEqual(places.count, 4, url.lastPathComponent)
            let raster = try merger.mergedRaster()
            XCTAssertEqual([raster.width, raster.height], [800, 600])
            // One colour fit for the whole frame: a window of saturated red roof tiles is a few percent off in its small
            // green and blue.
            let ratio = try colourRatio(raster, url: url, window: window, crop: frame.crop)
            for c in 0..<3 { XCTAssertEqual(ratio[c], 1, accuracy: 0.05, "\(url.lastPathComponent) channel \(c)") }
            // Outdoor scenes: a little moves between the exposures.
            XCTAssertLessThan(try merger.preview().motionCoverage, 0.1, url.lastPathComponent)
        }
    }

    func testFujifilmSetIsReadInOrder() throws {
        let urls = try TestSamples.requireFiles(TestSamples.pixelShift.fujifilm, extensions: ["raf"])
        try XCTSkipUnless(urls.count == 16, "Expected one 16-shot set")
        let merger = try PixelShiftMerger(urls: urls.reversed())
        let analysis = try merger.analyze()
        XCTAssertEqual(analysis.frames.map(\.filename), urls.map(\.lastPathComponent))
        // The area all sixteen cover, on the doubled grid.
        XCTAssertEqual([analysis.width, analysis.height], [23288, 17464])
        // Wider than Apple's decoder develops a DNG: kept as TIFF or JPEG.
        XCTAssertFalse(analysis.developable)
        XCTAssertThrowsError(try PixelShiftMerger(urls: Array(urls.dropLast())).analyze())
    }

    /// The whole set merged: neighbouring pixels come from different shots, and they agree.
    func testFujifilmMerge() throws {
        try TestTier.requireSlow()
        let urls = try TestSamples.requireFiles(TestSamples.pixelShift.fujifilm, extensions: ["raf"])
        let merger = try PixelShiftMerger(urls: urls)
        _ = try merger.analyze()
        let raster = try merger.mergedRaster()
        XCTAssertEqual([raster.width, raster.height], [23288, 17464])
        var even = 0.0, odd = 0.0
        let cx = raster.width / 2, cy = raster.height / 2
        for y in (cy - 500)..<(cy + 500) { for x in (cx - 500)..<(cx + 500) {
            let v = Double(raster.rgba[(y * raster.width + x) * 4 + 1])
            if (x + y) & 1 == 0 { even += v } else { odd += v }
        } }
        XCTAssertGreaterThan(even, 0)
        XCTAssertEqual(even / odd, 1, accuracy: 0.005)
    }

    /// The six exposures decode, sit at the recorded half-pixel places, and merge to the portrait the camera shot.
    func testHasselbladSixShot() throws {
        let url = try TestSamples.require(TestSamples.pixelShift.hasselblad)
        let shot = try HasselbladMultiShot.read(url)
        XCTAssertEqual(shot.places.count, 6)
        XCTAssertEqual([shot.crop.width, shot.crop.height], [23200, 17400])
        XCTAssertEqual(shot.colourMatrix.count, 9)
        let merger = try PixelShiftMerger(urls: [url])
        let analysis = try merger.analyze()
        XCTAssertEqual([analysis.width, analysis.height, analysis.orientation], [23200, 17400, 8])
        XCTAssertFalse(analysis.developable)
        let preview = try merger.preview()
        XCTAssertEqual([preview.image.width, preview.image.height], [2900, 2175])
        // A picture, not black or white.
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(preview.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let mean = Int(context.data!.load(fromByteOffset: 1, as: UInt8.self))
        XCTAssertTrue((20...235).contains(mean), "\(mean)")
    }

    /// The whole six-shot merge as a TIFF: upright, 16-bit, without alpha.
    func testHasselbladExport() throws {
        try TestTier.requireSlow()
        let url = try TestSamples.require(TestSamples.pixelShift.hasselblad)
        let merger = try PixelShiftMerger(urls: [url])
        _ = try merger.analyze()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multishot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("merged.tiff")
        try merger.export(to: out, format: .tiff)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 17400); XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 23200)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertNotEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
    }

    func testSelectionRules() throws {
        let pentax = try TestSamples.requireFiles(TestSamples.pixelShift.pentax, extensions: ["pef"])
        try XCTSkipUnless(pentax.count >= 2)
        // A set is one Pentax file; a camera JPEG beside it is left out.
        XCTAssertThrowsError(try PixelShiftMerger(urls: Array(pentax.prefix(2))).analyze())
        if case .pentax = try PixelShiftSelection([pentax[0], URL(fileURLWithPath: "/tmp/camera.JPG")]) {} else { XCTFail("Expected a Pentax set") }
        XCTAssertThrowsError(try PixelShiftSelection([URL(fileURLWithPath: "/tmp/camera.JPG")]))
    }
}
