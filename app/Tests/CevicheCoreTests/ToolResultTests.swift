import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

/// A processed photo's result is written in its own format (or TIFF) and looks as the photo did; a RAW's is a DNG.
final class ToolResultTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToolResultTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A Display P3 photo, wider than tall and stored on its side (EXIF orientation 6), with a bright red corner at the
    /// stored top left so a flip or a lost rotation shows.
    private func photo(_ type: UTType, ext: String) throws -> URL {
        let width = 96, height = 64
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<width {
            context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(x) / CGFloat(width), 0.5, 1 - CGFloat(x) / CGFloat(width), 1])!)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: height - 16, width: 16, height: 16))
        let url = directory.appendingPathComponent("IMG_0001.\(ext)")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifDateTimeOriginal: "2026:11:22 10:00:00"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The photo upright in sRGB bytes, as the app first shows it.
    private func rendered(_ url: URL) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = try RawRenderer(sourceURL: url)
        let image = try await renderer.displayImage(renderer.info.defaults, maxDimension: 200, sdr: true)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height)
    }

    private func raster(_ url: URL) throws -> PanoramaRaster {
        let metadata = try HDRMergeDecoder.metadata(url)
        let context = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .workingFormat: CIFormat.RGBAf])
        let frame = try HDRMergeDecoder.decode(url, metadata: metadata, longEdge: nil, whiteBalance: (5000, 0), context: context)
        return PanoramaRaster(width: frame.width, height: frame.height, rgba: frame.pixels)
    }

    private func writer(_ source: URL) throws -> ToolResultWriter {
        ToolResultWriter(dng: PanoramaDNGWriter(metadata: try HDRMergeDecoder.metadata(source).panorama, kind: .stack), source: source, dropsExposure: true)
    }

    func testExtensionFollowsTheSource() {
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/DSC0001.ARW")), "dng")
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/DSC0001.ARW"), format: .tiff), "dng")
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/IMG_0001.HEIC")), "heic")
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/IMG_0001.jpg")), "jpg")
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/IMG_0001.webp")), "heic")
        XCTAssertEqual(ToolResult.fileExtension(for: URL(fileURLWithPath: "/a/IMG_0001.HEIC"), format: .tiff), "tif")
    }

    /// Decoded the way the merges decode a processed photo and written back, the photo looks as it did: same tone,
    /// color and orientation, its date kept and its shutter speed dropped as for a merge.
    func testProcessedResultLooksLikeThePhoto() async throws {
        for (type, ext, outputs) in [(UTType.jpeg, "jpg", ["jpg", "tif"]), (UTType.heic, "heic", ["heic", "tif"]), (UTType.tiff, "tif", ["tif"])] {
            let source = try photo(type, ext: ext)
            let original = try await rendered(source)
            XCTAssertEqual(original.height, 96, "upright")
            for output in outputs {
                let url = directory.appendingPathComponent("result-\(ext).\(output)")
                try writer(source).write(try raster(source), to: url)
                let result = try await rendered(url)
                XCTAssertEqual(result.width, original.width); XCTAssertEqual(result.height, original.height)
                // JPEG blurs the hard edge of the red corner when encoded again, so most pixels, not every one, must match.
                var differences: [Int] = []
                for i in original.bytes.indices where i % 4 != 3 { differences.append(abs(Int(original.bytes[i]) - Int(result.bytes[i]))) }
                differences.sort()
                XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(differences.count), 4, "\(ext) → \(output)")
                XCTAssertLessThanOrEqual(differences[differences.count * 95 / 100], 6, "\(ext) → \(output)")
                let properties = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
                let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
                XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:11:22 10:00:00")
                XCTAssertNil(exif[kCGImagePropertyExifExposureTime as String])
                XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1, 1)
                if output == "tif" { XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16) }
            }
        }
    }

    /// A result brighter than white keeps its highlights: a gain map in a HEIC, half floats in a TIFF.
    func testBrighterThanWhiteIsKept() throws {
        let source = try photo(.heic, ext: "heic")
        var bright = try raster(source)
        for p in stride(from: 0, to: bright.rgba.count, by: 4) { for c in 0..<3 { bright.rgba[p + c] *= 4 } }
        for output in ["heic", "tif"] {
            let url = directory.appendingPathComponent("hdr.\(output)")
            try writer(source).write(bright, to: url)
            let image = try XCTUnwrap(CIImage(contentsOf: url, options: [.expandToHDR: true]))
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]), toBitmap: &pixel,
                               rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: PanoramaDecoder.space)
            XCTAssertGreaterThan(pixel[0...2].max()!, 2, output)
        }
    }
}
