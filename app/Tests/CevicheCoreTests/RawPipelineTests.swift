import XCTest
import CevicheTestSupport
import ImageIO
import CoreImage
import CoreGraphics
import Metal
import simd
@testable import CevicheCore

final class RawPipelineTests: XCTestCase {
    private func requireGPU() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable in this execution environment") }
    }
    func testEverySampleDecodesUsingMetal() async throws {
        try requireGPU()
        let files = try TestSamples.require(TestSamples.raws)
        for file in files {
            let (renderer, settings) = try RawRenderer.open(file)
            XCTAssertTrue(renderer.info.isRAW, file.lastPathComponent)
            let result = try await renderer.preview(settings)
            XCTAssertGreaterThan(result.image.width, 1000)
            XCTAssertLessThanOrEqual(max(result.image.width, result.image.height), 2200)
            XCTAssertEqual(result.histogram.count, 3)
            XCTAssertNotNil(CGImageSourceCreateWithData(result.thumbnail as CFData, nil))
        }
    }
    /// Detail's noise sliders drive the decoder's noise reduction and start at Apple's amounts for the photo.
    func testNoiseReductionDefaultsComeFromTheDecoder() throws {
        let files = try TestSamples.require(TestSamples.raws)
        for file in files {
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: file))
            let defaults = try RawRenderer.open(file).1
            if raw.isLuminanceNoiseReductionSupported {
                XCTAssertEqual(defaults.noiseReduction, RawRenderer.sliderAmount(raw.luminanceNoiseReductionAmount), file.lastPathComponent)
            } else { XCTAssertEqual(defaults.noiseReduction, 0, file.lastPathComponent) }
            if raw.isColorNoiseReductionSupported {
                XCTAssertEqual(defaults.colorNoiseReduction, RawRenderer.sliderAmount(raw.colorNoiseReductionAmount), file.lastPathComponent)
            }
        }
    }
    func testExposureWhiteBalanceCurvePersistenceAndExports() async throws {
        try requireGPU()
        try TestTier.requireSlow("Full-size export in every format")
        _ = try TestSamples.require(TestSamples.landscape)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TestSamples.url(TestSamples.landscape)
        let (renderer, defaults) = try RawRenderer.open(source)
        let original = try await renderer.preview(defaults)
        var exposed = defaults; exposed.exposure = 1
        let brighter = try await renderer.preview(exposed)
        XCTAssertGreaterThan(mean(brighter.image), mean(original.image) + 0.01)
        var warm = defaults; warm.temperature = 9000; warm.tint = 25
        let wb = try await renderer.preview(warm)
        XCTAssertNotEqual(wb.thumbnail, original.thumbnail)
        var curved = defaults
        for (x, y) in [(0.1, 0.02), (0.22, 0.12), (0.38, 0.3), (0.55, 0.6), (0.68, 0.82), (0.84, 0.94)] {
            curved.curve.insert(x: x, y: y)
        }
        XCTAssertEqual(curved.curve.points.count, 8)
        let curve = try await renderer.preview(curved)
        XCTAssertNotEqual(curve.thumbnail, original.thumbnail)
        var edited = curved
        edited.exposure = 0.4; edited.temperature = 7000; edited.highlights = -45; edited.shadows = 25
        edited.whites = 10; edited.blacks = -10; edited.contrast = 12; edited.vibrance = 18
        edited.clarity = 10; edited.sharpness = 15; edited.noiseReduction = 20; edited.vignette = 15
        let (reopened, restored) = try await reopenThroughCatalog(renderer, edited)
        XCTAssertEqual(reopened.sourceURL, source)
        XCTAssertEqual(restored, edited)
        let first = try await renderer.preview(edited)
        let second = try await reopened.preview(restored)
        XCTAssertEqual(first.thumbnail, second.thumbnail)
        edited.exposure = -0.3
        for format in ExportFormat.allCases where format.isAvailable {
            let url = directory.appendingPathComponent("export.\(format.fileExtension)")
            try await renderer.export(to: url, adjustments: edited, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, renderer.info.width)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, renderer.info.height)
            if format == .tiff { XCTAssertEqual(props[kCGImagePropertyDepth as String] as? Int, 16) }
        }
        edited.quarterTurns = 1
        let rotated = try await renderer.preview(edited)
        XCTAssertEqual(rotated.image.width, first.image.height)
        XCTAssertEqual(rotated.image.height, first.image.width)
    }
    func testBitmapFallbackAndOriginalProtection() async throws {
        try requireGPU()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.jpg")
        let bitmap = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let originalBytes = try Data(contentsOf: url)
        let (renderer, defaults) = try RawRenderer.open(url)
        XCTAssertFalse(renderer.info.isRAW)
        let result = try await renderer.preview(defaults)
        XCTAssertEqual(result.image.width, 64)
        var settings = defaults
        for (x, y) in [(0.11, 0.03), (0.23, 0.13), (0.39, 0.29), (0.53, 0.64), (0.68, 0.83), (0.86, 0.96)] {
            settings.curve.insert(x: x, y: y)
        }
        let curved = try await renderer.preview(settings)
        let input = pixel(result.image), output = pixel(curved.image)
        // The master curve runs hue-preserving on sRGB-encoded ProPhoto RGB.
        let source = FilmMath.encode(FilmMath.toProPhoto * FilmMath.decode(SIMD3(input[0], input[1], input[2])))
        let expected = FilmMath.encode(FilmMath.clamp(FilmMath.fromProPhoto * FilmMath.decode(FilmMath.huePreserving(source) { settings.curve.value(at: $0) })))
        for channel in 0..<3 {
            XCTAssertEqual(output[channel], expected[channel], accuracy: 0.025, "GPU curve should match graph coordinates")
        }
        do { try await renderer.export(to: url, adjustments: defaults, format: .jpeg); XCTFail("Must not overwrite original") } catch { }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }
    /// A 16-bit, 3-channel, rotated Adobe RGB TIFF decoded once matches what Core Image reads from the file.
    func testSixteenBitTIFFDecodesOnceLikeCoreImage() throws {
        try requireGPU()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.tif")
        let width = 40, height = 24, space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 3
            samples[i] = UInt16(x * 65535 / width); samples[i + 1] = UInt16(y * 65535 / height); samples[i + 2] = x < width / 2 ? 9000 : 52000
        } }
        let data = samples.map(\.bigEndian).withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let decoded = try XCTUnwrap(RawRenderer.decodedBitmap(source, type: CGImageSourceGetType(source) as String?, properties: properties))
        let reference = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        XCTAssertEqual(decoded.extent, reference.extent)
        XCTAssertEqual(decoded.extent.size, CGSize(width: height, height: width))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        func floats(_ image: CIImage) -> [Float] {
            var out = [Float](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: height * 16, bounds: image.extent, format: .RGBAf, colorSpace: space) }
            return out
        }
        for (a, b) in zip(floats(decoded), floats(reference)) { XCTAssertEqual(a, b, accuracy: 0.0005) }
        XCTAssertEqual(try RawRenderer(sourceURL: url).info.width, height)
        let pixels = try XCTUnwrap(RawRenderer.decodedPixels(source, type: CGImageSourceGetType(source) as String?, properties: properties))
        let small = try XCTUnwrap(RawRenderer.downsampled(pixels.image, side: 20))
        XCTAssertEqual([small.width, small.height], [20, 12], "previews scale the decoded pixels, keeping their shape and format")
        XCTAssertEqual(small.bitsPerComponent, 16)
        var huge = properties; huge[kCGImagePropertyPixelWidth as String] = 20_000; huge[kCGImagePropertyPixelHeight as String] = 10_000
        XCTAssertNil(RawRenderer.decodedPixels(source, type: CGImageSourceGetType(source) as String?, properties: huge),
                     "a picture past proxyPixels stays with Core Image's tiles")
    }
    private func pixel(_ image: CGImage) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { ptr in
            let context = CGContext(data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }
    private func mean(_ image: CGImage) -> Double {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes { ptr in
            let context = CGContext(data: ptr.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        var total = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) { total += Double(bytes[i]) * 0.2126 + Double(bytes[i + 1]) * 0.7152 + Double(bytes[i + 2]) * 0.0722 }
        return total / (32 * 32 * 255)
    }
}
