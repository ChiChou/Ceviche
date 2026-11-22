import XCTest
import CoreImage
import ImageIO
import Metal
@testable import CevicheCore

final class ExportSizingTests: XCTestCase {
    func testPresetsFollowFinalImageOrientationAndAspectRatio() throws {
        let landscape = CGSize(width: 7952, height: 5304)
        var sizing = ExportSizing(); sizing.allowsEnlarging = true
        XCTAssertEqual(try sizing.dimensions(for: landscape), ExportDimensions(width: 7952, height: 5304))
        for (preset, width, height) in [(ExportSizePreset.small, 1600, 1067), (.medium, 2560, 1708), (.large, 3840, 2561)] {
            sizing.select(preset, source: landscape)
            XCTAssertEqual(try sizing.dimensions(for: landscape), ExportDimensions(width: width, height: height))
            XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 5304, height: 7952)), ExportDimensions(width: height, height: width))
            XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 1000, height: 1000)), ExportDimensions(width: width, height: width))
        }
    }

    func testDimensionsAlwaysStayLinkedAndFollowNewSource() throws {
        let source = CGSize(width: 6000, height: 4000)
        var sizing = ExportSizing()
        sizing.select(.medium, source: source)
        sizing.select(.custom, source: source)
        XCTAssertEqual(sizing.width, 2560); XCTAssertEqual(sizing.height, 1707)
        sizing.setWidth(1200, source: source)
        XCTAssertEqual(try sizing.dimensions(for: source), ExportDimensions(width: 1200, height: 800))
        sizing.setHeight(600, source: source)
        XCTAssertEqual(try sizing.dimensions(for: source), ExportDimensions(width: 900, height: 600))
        sizing.setWidth(600, source: source)
        XCTAssertEqual(try sizing.dimensions(for: source), ExportDimensions(width: 600, height: 400))
        XCTAssertEqual(sizing.height, 400)
        sizing.updateSource(CGSize(width: 4000, height: 6000))
        XCTAssertEqual(sizing.height, 900, "Reopening export on a portrait photo must use its current proportions")
        sizing.select(.original, source: source)
        XCTAssertEqual(try sizing.dimensions(for: source), ExportDimensions(width: 6000, height: 4000))
    }

    func testInvalidAndExcessiveSizesAreRejectedWithoutOverflow() throws {
        let source = CGSize(width: 6000, height: 4000)
        for value in [0, -1, Int.max, ExportSizing.maximumDimension + 1] {
            var sizing = ExportSizing(); sizing.setWidth(value, source: source)
            XCTAssertThrowsError(try sizing.dimensions(for: source))
        }
        var sizing = ExportSizing()
        sizing.setWidth(20000, source: source); sizing.setHeight(20000, source: source)
        XCTAssertThrowsError(try sizing.validate())
        sizing.setWidth(1, source: source); sizing.setHeight(1, source: source)
        XCTAssertEqual(try sizing.dimensions(for: source), ExportDimensions(width: 2, height: 1))
        XCTAssertThrowsError(try sizing.dimensions(for: .zero))
        XCTAssertThrowsError(try sizing.dimensions(for: CGSize(width: Double.infinity, height: 10)))
        var options = ExportSettings(); options.sizing = sizing
        options.select(.jpeg)
        XCTAssertEqual(options.sizing, sizing, "Changing format must retain the chosen dimensions")
    }

    func testResizeAfterCropAndRotationPreservesEncodingMetadataAndAlpha() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200,
                                            space: RGBProfile.displayP3.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.1, alpha: 0.5))
        bitmap.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        let metadata: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:30 12:00:00",
                                                                       kCGImagePropertyExifPixelXDimension: 300, kCGImagePropertyExifPixelYDimension: 200]]
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let sourceBytes = try Data(contentsOf: source)
        let renderer = try RawRenderer(sourceURL: source)
        var edits = renderer.info.defaults; edits.quarterTurns = 1
        edits.geometry.crop = CropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.5)
        let originalSize = try GeometryPlan(size: CGSize(width: 300, height: 200), settings: edits.geometry, quarterTurns: 1).outputSize
        XCTAssertEqual(originalSize, CGSize(width: 140, height: 150))
        for format in [ExportFormat.png, .tiff, .jpeg] {
            for target in [ExportDimensions(width: 84, height: 90), ExportDimensions(width: 420, height: 450)] {
                var settings = ExportSettings(); settings.select(format); settings.sizing.allowsEnlarging = true
                settings.sizing.setWidth(target.width, source: originalSize); settings.sizing.setHeight(target.height, source: originalSize)
                let output = directory.appendingPathComponent("\(target.width).\(format.fileExtension)")
                try await renderer.export(to: output, adjustments: edits, settings: settings)
                let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any])
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, target.width)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, target.height)
                XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, settings.depth)
                XCTAssertEqual(properties[kCGImagePropertyProfileName as String] as? String, "sRGB IEC61966-2.1")
                let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
                XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:09:30 12:00:00")
                XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, target.width)
                XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension as String] as? Int, target.height)
                if format.supportsAlpha {
                    let image = CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil)))
                    var pixel = [Float](repeating: 0, count: 4)
                    pixel.withUnsafeMutableBytes { bytes in
                        CIContext().render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    }
                    XCTAssertEqual(pixel[3], 0.5, accuracy: 0.02, "Resampling must not flatten transparency, including at the image edges")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        // A preset must resolve against the crop, rather than the source sensor dimensions.
        var preset = ExportSettings(); preset.sizing.allowsEnlarging = true; preset.sizing.select(.small, source: originalSize)
        let output = directory.appendingPathComponent("preset.tiff")
        try await renderer.export(to: output, adjustments: edits, settings: preset)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 1493)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 1600)
    }
    func testTypedPortraitHeightIsKept() throws {
        var sizing = ExportSizing()
        let portrait = CGSize(width: 2000, height: 3001)
        sizing.setHeight(1000, source: portrait)
        XCTAssertEqual(try sizing.dimensions(for: portrait), ExportDimensions(width: 666, height: 1000))
    }
}
