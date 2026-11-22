import XCTest
import CoreImage
import ImageIO
import Metal
@testable import CevicheCore

final class HDRExportTests: XCTestCase {
    func testHDRSelectionKeepsChosenFormatAndUsesSupportedDepth() throws {
        var settings = ExportSettings()
        for format in ExportFormat.allCases where format.supportsHDR {
            // Fresh settings take the container's default encoding; a chosen encoding carries over where the next container holds it.
            settings = ExportSettings(); settings.select(format); settings.setHDR(true)
            XCTAssertEqual(settings.format, format)
            XCTAssertTrue(settings.hdr); XCTAssertEqual(settings.hdrEncoding, format.hdrEncodings[0])
            XCTAssertEqual(settings.depth, format == .jpeg ? 8 : format == .tiff ? 32 : format == .png ? 16 : 10)
            if format.isAvailable { XCTAssertNoThrow(try settings.validate()) }
            for encoding in HDREncoding.allCases {
                settings.setHDREncoding(encoding)
                XCTAssertEqual(settings.hdrEncoding == encoding, format.hdrEncodings.contains(encoding), "\(format) \(encoding)")
                XCTAssertTrue(settings.depths.contains(settings.depth))
            }
            settings.setHDR(false)
            XCTAssertEqual(settings.format, format); XCTAssertTrue(format.depths.contains(settings.depth))
        }
        settings.select(.avif); settings.setHDR(true); settings.setHDREncoding(.gainMap); XCTAssertEqual(settings.depth, 8)
        settings.select(.heif); XCTAssertTrue(settings.hdr); XCTAssertEqual(settings.hdrEncoding, .gainMap); XCTAssertEqual(settings.depth, 8)
        settings.select(.png); XCTAssertTrue(settings.hdr); XCTAssertEqual(settings.hdrEncoding, .pq); XCTAssertEqual(settings.depth, 16)
        settings.setHDREncoding(.hlg); XCTAssertEqual(settings.depth, 16)
        settings.select(.tiff); XCTAssertEqual(settings.hdrEncoding, .hlg); XCTAssertEqual(settings.depth, 16)
        settings.setHDREncoding(.linear); XCTAssertEqual(settings.depth, 32)
        settings.select(.jpeg); XCTAssertTrue(settings.hdr); XCTAssertEqual(settings.hdrEncoding, .gainMap); XCTAssertEqual(settings.depth, 8)
        settings.hdrEncoding = .pq; XCTAssertThrowsError(try settings.validate())
        // Remembered settings decode with their encoding; without one they get the container's default.
        settings.hdrEncoding = .gainMap
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings)), settings)
        let older = try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"format":"HEIF","hdr":true,"depth":10}"#.utf8))
        XCTAssertEqual(older.hdrEncoding, .pq); XCTAssertEqual(older.depth, 10)
    }

    func testEveryAvailableHDRFormatRetainsHighlightsAndEstimatesEncodedSize() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: linear])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.tiff")
        let image = CIImage(color: CIColor(red: 4, green: 2, blue: 1, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 128))
        try XCTUnwrap(context.tiffRepresentation(of: image, format: .RGBAf, colorSpace: linear)).write(to: source)
        let sourceBytes = try Data(contentsOf: source)
        let renderer = try RawRenderer(sourceURL: source)
        var edits = renderer.info.defaults; edits.hdr.enabled = true
        for format in ExportFormat.allCases where format.supportsHDR && format.isAvailable {
            var settings = ExportSettings(); settings.select(format); settings.setHDR(true)
            settings.sizing.setWidth(128, source: image.extent.size)
            for encoding in format.hdrEncodings {
                settings.setHDREncoding(encoding)
                let label = "\(format.rawValue) \(encoding.rawValue)"
                let output = directory.appendingPathComponent("hdr-\(encoding.rawValue)." + format.fileExtension)
                try await renderer.export(to: output, adjustments: edits, settings: settings)
                let file = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [String: Any])
                XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, settings.depth, label)
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 128)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 64)
                // Decoded for an HDR display: PQ and HLG carry the highlights directly, the gain map restores them over its SDR base.
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, [kCGImageSourceShouldAllowFloat: true, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary))
                let space = try XCTUnwrap(decoded.colorSpace)
                switch encoding {
                case .linear: XCTAssertTrue(CGColorSpaceUsesExtendedRange(space), label)
                case .pq: XCTAssertTrue(CGColorSpaceIsPQBased(space), label)
                case .hlg: XCTAssertTrue(CGColorSpaceIsHLGBased(space), label)
                case .gainMap, .appleGainMap:
                    XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeISOGainMap), label)
                    if encoding == .appleGainMap {
                        // As an iPhone writes it: Apple's map beside the ISO one, sized like it, with the same headroom.
                        let apple = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [CFString: Any], label)
                        let metadata = try XCTUnwrap(apple[kCGImageAuxiliaryDataInfoMetadata] as! CGImageMetadata?)
                        let headroom = try XCTUnwrap((CGImageMetadataCopyStringValueWithPath(metadata, nil, "HDRGainMap:HDRGainMapHeadroom" as CFString) as String?).flatMap(Double.init))
                        // ImageIO no longer reports a top-level Headroom, so compare with the ISO map's alternate headroom, in stops.
                        let iso = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any], label)
                        let isoMetadata = try XCTUnwrap(iso[kCGImageAuxiliaryDataInfoMetadata] as! CGImageMetadata?)
                        let alternate = (CGImageMetadataCopyTags(isoMetadata) as? [CGImageMetadataTag])?.first { CGImageMetadataTagCopyName($0) as String? == "AlternateHeadroom" }
                        let stops = try XCTUnwrap(alternate.flatMap { CGImageMetadataTagCopyValue($0) as? String }.flatMap(Double.init), label)
                        XCTAssertEqual(headroom, pow(2, stops), accuracy: 0.01, label)
                        XCTAssertGreaterThan(headroom, 1.5, label)
                        let description = try XCTUnwrap(apple[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
                        XCTAssertGreaterThan(description["Width"] as? Int ?? 0, 2, label)
                        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any], label)
                        XCTAssertNotNil(maker["48"], label)
                    }
                    let sdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(file, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary))
                    var base = [Float](repeating: 0, count: 4)
                    context.render(CIImage(cgImage: sdr), toBitmap: &base, rowBytes: 16, bounds: CGRect(x: 30, y: 30, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
                    XCTAssertLessThanOrEqual(base[0], 1.05, label)
                }
                var pixel = [Float](repeating: 0, count: 4)
                context.render(CIImage(cgImage: decoded), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 30, y: 30, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
                // A gain map scales the tone-mapped SDR base by one factor, so its colors are only approximately restored.
                XCTAssertEqual(pixel[0], 4, accuracy: encoding.isGainMap ? 0.8 : 0.25, label)
                XCTAssertEqual(pixel[1], 2, accuracy: encoding.isGainMap ? 0.8 : 0.15, label)
            }
            settings.setHDR(false)
            let sdr = directory.appendingPathComponent("sdr." + format.fileExtension)
            try await renderer.export(to: sdr, adjustments: edits, settings: settings)
            let sdrImage = try XCTUnwrap(CIImage(contentsOf: sdr))
            var sdrPixel = [Float](repeating: 0, count: 4)
            context.render(sdrImage, toBitmap: &sdrPixel, rowBytes: 16, bounds: CGRect(x: 30, y: 30, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            XCTAssertLessThanOrEqual(sdrPixel[0], 1.05, format.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
}
