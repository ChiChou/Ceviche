import XCTest
import CoreImage
import ImageIO
import Metal
@testable import CevicheCore

final class PhotoDenoiserTests: XCTestCase {
    private let properties: [String: Any] = [
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7M4",
                                                  kCGImagePropertyTIFFArtist: "C. C.", kCGImagePropertyTIFFCopyright: "© C. C."],
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifExposureTime: 1.0 / 250, kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifISOSpeedRatings: [6400],
            kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifFocalLenIn35mmFilm: 35, kCGImagePropertyExifExposureBiasValue: -0.7,
            kCGImagePropertyExifLensMake: "Sony", kCGImagePropertyExifLensModel: "FE 35mm F1.4 GM",
            kCGImagePropertyExifLensSpecification: [35, 35, 1.4, 1.4],
            kCGImagePropertyExifDateTimeOriginal: "2025:10:23 19:42:07", kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            kCGImagePropertyExifBodySerialNumber: "1234567"],
        kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude: 46.6125, kCGImagePropertyGPSLatitudeRef: "N",
                                                 kCGImagePropertyGPSLongitude: 12.1781, kCGImagePropertyGPSLongitudeRef: "E",
                                                 kCGImagePropertyGPSAltitude: 2210.5, kCGImagePropertyGPSAltitudeRef: 0],
    ]
    private func raster(width: Int = 240, height: Int = 160) -> PanoramaRaster {
        var rgba = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let p = (y * width + x) * 4
            rgba[p] = Float(x) / Float(width) * 0.6; rgba[p + 1] = 0.2 + 0.1 * Float((x * 7 + y * 13) % 5) / 5; rgba[p + 2] = Float(y) / Float(height) * 0.4
        }}
        return PanoramaRaster(width: width, height: height, rgba: rgba)
    }
    private func readProperties(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] })
    }

    /// The DNG Denoise writes says what the photo's file says: camera, lens, exposure, time and place.
    func testDNGKeepsTheSourceEXIF() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable in this execution environment") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = PanoramaFrameMetadata(filename: "DSC0001.ARW", make: "SONY", model: "ILCE-7M4", width: 240, height: 160,
                                             focalLength35mm: 35, captureTime: "2025:10:23 19:42:07", temperature: 5600, tint: 0)
        let url = directory.appendingPathComponent("DSC0001-NR.dng")
        try PanoramaDNGWriter(metadata: metadata, source: DNGSourceMetadata(properties: properties, process: PhotoDenoiser.suffix)).write(raster(), to: url)

        let read = try readProperties(url)
        let tiff = try XCTUnwrap(read[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        let exif = try XCTUnwrap(read[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let gps = try XCTUnwrap(read[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "SONY")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "ILCE-7M4")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFArtist as String] as? String, "C. C.")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright as String] as? String, "© C. C.")
        XCTAssertEqual((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0, 1.0 / 250, accuracy: 1e-9)
        XCTAssertEqual((exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0, 2.8, accuracy: 1e-4)
        XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [6400])
        XCTAssertEqual((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0, 35, accuracy: 1e-4)
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int, 35)
        XCTAssertEqual((exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber)?.doubleValue ?? 0, -0.7, accuracy: 1e-4)
        XCTAssertEqual(exif[kCGImagePropertyExifLensMake as String] as? String, "Sony")
        XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, "FE 35mm F1.4 GM")
        for (found, expected) in zip((exif[kCGImagePropertyExifLensSpecification as String] as? [NSNumber])?.map(\.doubleValue) ?? [], [35, 35, 1.4, 1.4]) {
            XCTAssertEqual(found, expected, accuracy: 1e-4)
        }
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2025:10:23 19:42:07")
        // ImageIO doesn't report the offset tags of a DNG, but they are written.
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data("+02:00\0".utf8)))
        XCTAssertEqual(exif[kCGImagePropertyExifBodySerialNumber as String] as? String, "1234567")
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue ?? 0, 46.6125, accuracy: 1e-6)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "N")
        XCTAssertEqual((gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue ?? 0, 12.1781, accuracy: 1e-6)
        XCTAssertEqual((gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue ?? 0, 2210.5, accuracy: 1e-3)

        // The catalog reads the same camera, lens, time and place as from the photo.
        let (asset, _) = try CatalogImporter.prepare(url)
        let info = try JSONDecoder().decode(ImageInfo.self, from: asset.infoData)
        XCTAssertEqual(info.camera, "ILCE-7M4")
        XCTAssertEqual(info.lens, "FE 35mm F1.4 GM")
        XCTAssertTrue(info.isRAW)
        XCTAssertEqual(asset.captureTime, "2025-10-23T19:42:07")
        XCTAssertEqual(asset.latitude ?? 0, 46.6125, accuracy: 1e-6)
        XCTAssertEqual(asset.longitude ?? 0, 12.1781, accuracy: 1e-6)

        // Naming the real camera doesn't make the decoder treat the pixels as that camera's: they develop exactly as
        // a merge's generic camera does.
        let generic = directory.appendingPathComponent("generic.dng")
        try PanoramaDNGWriter(metadata: metadata).write(raster(), to: generic)
        func developed(_ url: URL) throws -> [Float] {
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
            let image = try XCTUnwrap(raw.outputImage)
            var pixels = [Float](repeating: 0, count: 240 * 160 * 4)
            CIContext().render(image, toBitmap: &pixels, rowBytes: 240 * 16, bounds: image.extent, format: .RGBAf, colorSpace: PanoramaDecoder.space)
            return pixels
        }
        let named = try developed(url), plain = try developed(generic)
        let difference = zip(named, plain).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(difference, 1e-4)
    }

    /// Opt-in, as a full-size denoise takes minutes and needs a noisy photo: CEVICHE_DENOISE_RAW=<RAW file> with the
    /// NAFNet model installed.
    /// The DNG has the photo's size and EXIF, and less noise.
    func testDenoiseWritesALinearDNGWithTheSourceEXIF() throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_DENOISE_RAW"] else { throw XCTSkip("Set CEVICHE_DENOISE_RAW to run") }
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        let sample = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("denoised.dng")
        try PhotoDenoiser.denoise(sample, to: url, settings: DenoiseSettings(), exposure: 2)

        let source = try readProperties(sample), result = try readProperties(url)
        for dictionary in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary] {
            let before = source[dictionary as String] as? [String: Any] ?? [:], after = result[dictionary as String] as? [String: Any] ?? [:]
            for key in [kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
                        kCGImagePropertyExifLensModel, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] as [CFString] {
                guard let expected = before[key as String] else { continue }
                XCTAssertEqual("\(after[key as String] ?? "missing")", "\(expected)", "\(key)")
            }
        }
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        let original = try XCTUnwrap(CIRAWFilter(imageURL: sample))
        XCTAssertEqual(raw.nativeSize.width, RawRenderer.orientedRAWSize(original).width, accuracy: 1)
        XCTAssertEqual(raw.nativeSize.height, RawRenderer.orientedRAWSize(original).height, accuracy: 1)

        // Flat sky near the top, brightened: much smoother than the photo developed without noise reduction.
        func roughness(_ url: URL, noiseReduction: Bool) throws -> Double {
            let metadata = try PanoramaDecoder.metadata(url)
            var image = try PanoramaDecoder.developedImage(url, longEdge: nil, whiteBalance: (metadata.temperature, metadata.tint), noiseReduction: noiseReduction)
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])
            let w = 256, h = 256, region = CGRect(x: image.extent.midX - 128, y: image.extent.maxY * 0.92 - 128, width: CGFloat(w), height: CGFloat(h))
            var pixels = [Float](repeating: 0, count: w * h * 4)
            CIContext().render(image, toBitmap: &pixels, rowBytes: w * 16, bounds: region, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            func luma(_ x: Int, _ y: Int) -> Double { let i = (y * w + x) * 4; return Double(0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2]) }
            var total = 0.0
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                var mean = 0.0; for j in -1...1 { for i in -1...1 { mean += luma(x + i, y + j) } }
                total += abs(luma(x, y) - mean / 9)
            } }
            return total / Double((w - 2) * (h - 2))
        }
        let before = try roughness(sample, noiseReduction: false), after = try roughness(url, noiseReduction: false)
        XCTAssertLessThan(after, before * 0.7)
    }
}
