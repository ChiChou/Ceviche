import XCTest
import AppKit
import ImageIO
import CevicheCore
@testable import CevicheMac

final class PhotoShareTests: XCTestCase {
    @MainActor func testTemporaryHEICCanBeDecodedAtOriginalSize() async throws {
        let (directory, source) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let share = try PhotoShare { XCTFail($0) }
        defer { share.finish() }
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let tagged = directory.appendingPathComponent("tagged.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(tagged as CFURL, "public.jpeg" as CFString, 1, nil))
        let tags: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 41.9, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 12.5, kCGImagePropertyGPSLongitudeRef: "E"
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:04 12:00:00"]
        ]
        CGImageDestinationAddImageFromSource(destination, original, 0, tags as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let (renderer, edits) = try RawRenderer.open(tagged)
        let output = share.folder.appendingPathComponent("example.heic")
        try await renderer.export(to: output, adjustments: edits, settings: PhotoShare.settings)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 100)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude as String] as? Double), 41.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLongitude as String] as? Double), 12.5, accuracy: 0.0001)
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef as String] as? String, "N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef as String] as? String, "E")
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:11:04 12:00:00")
        for metadata in [true, false] {
            var settings = PhotoShare.settings
            settings.includeMetadata = metadata
            settings.includeLocation = !metadata
            let stripped = share.folder.appendingPathComponent("stripped-\(metadata).heic")
            try await renderer.export(to: stripped, adjustments: edits, settings: settings)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(stripped as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
            XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
            let capture = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertEqual(capture?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                           metadata ? "2026:11:04 12:00:00" : nil)
        }
    }

    @MainActor func testGPSPreferencePersistsInSettingsAndPresets() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ExportSettings()
        settings.includeLocation = true
        settings.rememberAsLastUsed(defaults)
        XCTAssertEqual(ExportSettings.lastUsed(defaults)?.includeLocation, true)
        ExportPreset.saveUserPreset(name: "GPS", settings: settings, defaults: defaults)
        XCTAssertEqual(ExportPreset.savedByUser(defaults).first?.settings().includeLocation, true)
    }

    @MainActor func testCancellingPickerRemovesOnlyItsTemporaryFiles() throws {
        let first = try PhotoShare { XCTFail($0) }
        let second = try PhotoShare { XCTFail($0) }
        defer { first.finish(); second.finish() }
        let file = first.folder.appendingPathComponent("photo.heic")
        try Data([1, 2, 3]).write(to: file)
        first.sharingServicePicker(NSSharingServicePicker(items: [file]), didChoose: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.folder.path))
    }
}
