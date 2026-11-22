import XCTest
import CoreGraphics
import ImageIO
import Metal
@testable import CevicheCore

final class ModernExportTests: XCTestCase {
    func testFormatTransitionsAndSavedSettings() throws {
        var settings = ExportSettings()
        settings.setHDR(true)
        settings.select(.webp)
        XCTAssertFalse(settings.hdr); XCTAssertEqual(settings.depth, 8)
        XCTAssertTrue(settings.lossless); XCTAssertFalse(settings.usesLossyCompression)
        settings.sizing.allowsEnlarging = true
        XCTAssertThrowsError(try settings.dimensions(for: CGSize(width: 20000, height: 1000)))
        settings.lossless = false
        XCTAssertTrue(settings.usesLossyCompression)
        settings.select(.jxl)
        XCTAssertEqual(settings.depth, 16); XCTAssertFalse(settings.hdr)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.select(.png)
        XCTAssertEqual(settings.depth, 16)
        let partial = try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"format":"PNG","depth":16}"#.utf8))
        XCTAssertTrue(partial.lossless)
        for format in [ExportFormat.webp, .jxl] {
            let restored = try JSONDecoder().decode(ExportSettings.self, from: Data("{\"format\":\"\(format.rawValue)\",\"hdr\":true}".utf8))
            XCTAssertFalse(restored.hdr)
        }
    }

    func testWebPAndJXLRetainDepthProfileAlphaAndLosslessPixels() throws {
        for format in [ExportFormat.webp, .jxl] {
            for depth in format.depths {
                for lossless in [true, false] {
                    var settings = ExportSettings(); settings.select(format)
                    settings.depth = depth; settings.lossless = lossless; settings.quality = 0.75
                    let original = try fixture(depth: depth)
                    let data = try ModernImageEncoder.encode(original, settings: settings, properties: [:])
                    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                    XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 64)
                    XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 32)
                    XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, depth, "\(format) \(lossless)")
                    XCTAssertEqual(properties[kCGImagePropertyProfileName as String] as? String, "Display P3")
                    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                    let before = try rgba(original, depth: depth), after = try rgba(decoded, depth: depth)
                    if lossless { XCTAssertEqual(after, before, "\(format) \(depth)-bit lossless samples changed") }
                    // The left half is transparent, the right half opaque, even in lossy mode.
                    let alphaOffset = depth == 8 ? 3 : 6
                    XCTAssertEqual(after[alphaOffset], 0)
                    XCTAssertEqual(after[(63 * 4 * depth / 8) + alphaOffset], 255)
                }
            }
        }
    }

    func testCaptureMetadataIsOptionalAndKeepsExportDimensions() throws {
        let image = try fixture(depth: 8)
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifISOSpeedRatings: [200],
                                           kCGImagePropertyExifPixelXDimension: 64, kCGImagePropertyExifPixelYDimension: 32],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test camera"]
        ]
        for format in [ExportFormat.webp, .jxl] {
            for include in [true, false] {
                var settings = ExportSettings(); settings.select(format); settings.depth = 8; settings.includeMetadata = include
                let data = try ModernImageEncoder.encode(image, settings: settings, properties: properties)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let result = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                let exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any]
                if include {
                    XCTAssertEqual(exif?[kCGImagePropertyExifExposureTime as String] as? Double, 0.01)
                    XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int, 64)
                    XCTAssertEqual(exif?[kCGImagePropertyExifPixelYDimension as String] as? Int, 32)
                } else { XCTAssertNil(exif?[kCGImagePropertyExifExposureTime as String]) }
                XCTAssertNil(result[kCGImagePropertyGPSDictionary as String])
            }
        }
    }

    func testRendererUsesNativeEncoders() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let folder = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try fixture(depth: 16), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let renderer = try RawRenderer(sourceURL: source)
        var edits = renderer.info.defaults; edits.quarterTurns = 1
        for format in [ExportFormat.webp, .jxl] {
            var settings = ExportSettings(); settings.select(format); settings.preserveAlpha = false
            let output = folder.appendingPathComponent("output." + format.fileExtension)
            try await renderer.export(to: output, adjustments: edits, settings: settings)
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 64)
            let bytes = try Data(contentsOf: output)
            do { try await renderer.export(to: output, adjustments: edits, settings: settings, overwriteExisting: false); XCTFail("Existing export was replaced") } catch { }
            XCTAssertEqual(try Data(contentsOf: output), bytes)
        }
    }

    func testCancellingStopsAJXLEncodeInProgress() async throws {
        let size = 4096
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                              space: RGBProfile.displayP3.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt32.self, capacity: size * size)
        var seed: UInt32 = 1
        for i in 0..<(size * size) { seed = seed &* 1664525 &+ 1013904223; pixels[i] = seed | 0xff00_0000 }
        let image = try XCTUnwrap(context.makeImage())
        var settings = ExportSettings(); settings.select(.jxl); settings.depth = 8; settings.lossless = false
        let encode = Task.detached { try ModernImageEncoder.encode(image, settings: settings, properties: [:]) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelled = Date()
        encode.cancel()
        do { _ = try await encode.value; XCTFail("The encode finished despite being cancelled") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(depth: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: depth,
                                            bytesPerRow: 64 * 4 * depth / 8, space: RGBProfile.displayP3.space,
                                            bitmapInfo: (depth == 16 ? CGBitmapInfo.byteOrder16Little : .byteOrder32Big).rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 32..<64 {
            context.setFillColor(CGColor(colorSpace: RGBProfile.displayP3.space, components: [CGFloat(x) / 64, 0.231, 0.517, 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 32))
        }
        return try XCTUnwrap(context.makeImage())
    }
    private func rgba(_ image: CGImage, depth: Int) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4 * depth / 8)
        try bytes.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: depth,
                                                bytesPerRow: image.width * 4 * depth / 8, space: RGBProfile.displayP3.space,
                                                bitmapInfo: (depth == 16 ? CGBitmapInfo.byteOrder16Little : .byteOrder32Big).rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
