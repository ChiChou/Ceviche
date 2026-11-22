import XCTest
import CevicheTestSupport
import CoreImage
import ImageIO
import Metal
@testable import CevicheCore

final class RawOrientationTests: XCTestCase {
    private var portraitSample: URL {
        TestSamples.url(TestSamples.portrait)
    }

    private func requirePortraitSample() throws {
        _ = try TestSamples.require(TestSamples.portrait)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    }

    func testDimensionsMatchDecoderForEveryEXIFOrientation() throws {
        let sample = try TestSamples.require(TestSamples.landscape)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: sample))
        let sensorSize = raw.nativeSize
        for value in UInt32(1)...8 {
            raw.orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: value))
            let expected = value >= 5 ? CGSize(width: sensorSize.height, height: sensorSize.width) : sensorSize
            XCTAssertEqual(RawRenderer.orientedRAWSize(raw), expected, "EXIF orientation \(value)")
            XCTAssertEqual(RawRenderer.orientedRAWSize(raw), try XCTUnwrap(raw.outputImage).extent.size)
            XCTAssertEqual(raw.nativeSize, sensorSize)
        }
    }

    func testPortraitRAWDimensionsMatchDecodedImage() async throws {
        try requirePortraitSample()
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: portraitSample))
        XCTAssertEqual(raw.nativeSize, CGSize(width: 7952, height: 5304))
        XCTAssertEqual(raw.orientation, .left)
        let decoded = try XCTUnwrap(raw.outputImage).extent.size
        XCTAssertEqual(decoded, CGSize(width: 5304, height: 7952))
        let renderer = try RawRenderer(sourceURL: portraitSample)
        XCTAssertEqual(renderer.info.width, 5304)
        XCTAssertEqual(renderer.info.height, 7952)
        let preview = try await renderer.preview(renderer.info.defaults)
        XCTAssertLessThan(preview.image.width, preview.image.height)
        XCTAssertEqual(Double(renderer.info.width) / Double(renderer.info.height),
                       Double(preview.image.width) / Double(preview.image.height), accuracy: 0.001)
    }

    func testPortraitPresetsCustomSizeAndRotationMatchExportedPixels() async throws {
        try TestTier.requireSlow("Five exports of a full-size RAW")
        try requirePortraitSample()
        let renderer = try RawRenderer(sourceURL: portraitSample)
        let sourceSize = CGSize(width: renderer.info.width, height: renderer.info.height)
        var sizing = ExportSizing()
        XCTAssertEqual(try sizing.dimensions(for: sourceSize), ExportDimensions(width: 5304, height: 7952))
        for (preset, width, height) in [(ExportSizePreset.small, 1067, 1600), (.medium, 1708, 2560), (.large, 2561, 3840)] {
            sizing.select(preset, source: sourceSize)
            XCTAssertEqual(try sizing.dimensions(for: sourceSize), ExportDimensions(width: width, height: height))
        }
        sizing.setWidth(1200, source: sourceSize)
        XCTAssertEqual(try sizing.dimensions(for: sourceSize), ExportDimensions(width: 1200, height: 1799))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ExportSettings(); options.select(.jpeg)
        try await checkExport(renderer, adjustments: renderer.info.defaults, settings: options,
                              expected: ExportDimensions(width: 5304, height: 7952), directory: directory)
        options.sizing = sizing
        try await checkExport(renderer, adjustments: renderer.info.defaults, settings: options,
                              expected: ExportDimensions(width: 1200, height: 1799), directory: directory)
        if ExportFormat.avif.isAvailable { options.select(.avif) }
        options.sizing.select(.small, source: sourceSize)
        try await checkExport(renderer, adjustments: renderer.info.defaults, settings: options,
                              expected: ExportDimensions(width: 1067, height: 1600), directory: directory)
        var rotated = renderer.info.defaults; rotated.quarterTurns = 1
        let rotatedSize = try GeometryPlan(size: sourceSize, settings: rotated.geometry, quarterTurns: 1).outputSize
        XCTAssertEqual(rotatedSize, CGSize(width: 7952, height: 5304))
        try await checkExport(renderer, adjustments: rotated, settings: options,
                              expected: ExportDimensions(width: 1600, height: 1067), directory: directory)
        rotated.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.75)
        let croppedSize = try GeometryPlan(size: sourceSize, settings: rotated.geometry, quarterTurns: 1).outputSize
        XCTAssertEqual(croppedSize, CGSize(width: 3976, height: 3978))
        let expected = try options.sizing.dimensions(for: croppedSize)
        try await checkExport(renderer, adjustments: rotated, settings: options, expected: expected, directory: directory)
    }

    private func checkExport(_ renderer: RawRenderer, adjustments: Adjustments, settings: ExportSettings,
                             expected: ExportDimensions, directory: URL) async throws {
        let url = directory.appendingPathComponent("export.\(settings.format.fileExtension)")
        try await renderer.export(to: url, adjustments: adjustments, settings: settings)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, expected.width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, expected.height)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, settings.depth)
    }
}
