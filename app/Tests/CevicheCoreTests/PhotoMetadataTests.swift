import XCTest
import ImageIO
@testable import CevicheCore

final class PhotoMetadataTests: XCTestCase {
    func testSummaryFormatsCaptureSettings() {
        let summary = PhotoMetadataSummary(properties: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "SONY", kCGImagePropertyTIFFModel as String: "ILCE-7RM4"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 8.0, kCGImagePropertyExifExposureTime as String: 0.004,
                kCGImagePropertyExifISOSpeedRatings as String: [100], kCGImagePropertyExifFocalLength as String: 24.0,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 24, kCGImagePropertyExifExposureBiasValue as String: -0.7,
                kCGImagePropertyExifExposureProgram as String: 3, kCGImagePropertyExifLensModel as String: "FE 24-70mm F2.8 GM"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 46.6, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                      kCGImagePropertyGPSLongitude as String: 11.7, kCGImagePropertyGPSLongitudeRef as String: "W"]])
        XCTAssertEqual(summary.aperture, "ƒ/8")
        XCTAssertEqual(summary.shutter, "1/250 s")
        XCTAssertEqual(summary.iso, "ISO 100")
        XCTAssertEqual(summary.focalLength, "24 mm")
        XCTAssertNil(summary.focalLength35mm, "An identical 35 mm equivalent adds nothing")
        XCTAssertEqual(summary.exposureBias, "-0.7 EV")
        XCTAssertEqual(summary.exposureProgram, "Aperture priority")
        XCTAssertEqual(summary.camera, "Sony ILCE-7RM4")
        XCTAssertEqual(summary.lens, "FE 24-70mm F2.8 GM")
        XCTAssertEqual(summary.longitude, -11.7)
        XCTAssertTrue(summary.extended.contains { $0.group == "Exif" && $0.title == "Focal Len In 35mm Film" && $0.value == "24" })
    }
    func testShutterAndTitleFormatting() {
        XCTAssertEqual(PhotoMetadataSummary.shutter(2), "2 s")
        XCTAssertEqual(PhotoMetadataSummary.shutter(0.3), "0.3 s")
        XCTAssertEqual(PhotoMetadataSummary.shutter(1.0 / 8000), "1/8000 s")
        XCTAssertEqual(PhotoMetadataSummary.title("ISOSpeedRatings"), "ISOSpeed Ratings")
        XCTAssertEqual(PhotoMetadataSummary(properties: [kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Canon", kCGImagePropertyTIFFModel as String: "Canon EOS R5"]]).camera, "Canon EOS R5")
    }
}
