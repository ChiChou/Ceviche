import XCTest
@testable import CevicheCore

final class ExportPresetTests: XCTestCase {
    func testLongEdgePresetsShrinkWithoutEnlarging() throws {
        let web = try XCTUnwrap(ExportPreset.named("jpeg-2560"))
        let settings = web.settings()
        XCTAssertEqual(try settings.sizing.dimensions(for: CGSize(width: 6000, height: 4000)), ExportDimensions(width: 2560, height: 1707))
        XCTAssertEqual(try settings.sizing.dimensions(for: CGSize(width: 800, height: 600)), ExportDimensions(width: 800, height: 600), "Small photos are not upscaled")
        XCTAssertEqual(settings.sizing.cropRect(for: CGSize(width: 800, height: 600)), CGRect(x: 0, y: 0, width: 800, height: 600), "No ratio, no crop")
        XCTAssertEqual(web.detail, "JPEG - 85% - 8-bit - 2560 px - sRGB")
        // "Don't enlarge" keeps small photos at their size for the fixed presets and custom sizes; frames still apply.
        var sizing = ExportSizing(); sizing.preset = .large; sizing.allowsEnlarging = false
        XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 800, height: 600)), ExportDimensions(width: 800, height: 600))
        sizing.allowsEnlarging = true
        XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 800, height: 600)), ExportDimensions(width: 3840, height: 2880))
        sizing.preset = .custom; sizing.width = 1600; sizing.height = 1200; sizing.allowsEnlarging = false
        XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 800, height: 600)), ExportDimensions(width: 800, height: 600))
        sizing.frame = ExportDimensions(width: 1080, height: 1920)
        XCTAssertEqual(try sizing.dimensions(for: CGSize(width: 300, height: 200)), ExportDimensions(width: 1080, height: 1920))
    }
    func testSavedPresetsExportWhatTheDialogShowed() throws {
        let suite = "ExportPresetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ExportSettings(); settings.select(.webp); settings.lossless = false; settings.quality = 0.7
        settings.sizing.select(.large, source: CGSize(width: 6000, height: 4000)); settings.sizing.allowsEnlarging = true
        settings.aiDenoise = 30; settings.profile.preset = .displayP3
        ExportPreset.saveUserPreset(name: "Web", settings: settings, defaults: defaults)
        let preset = try XCTUnwrap(ExportPreset.savedByUser(defaults).first)
        let restored = preset.settings()
        XCTAssertEqual(try restored.sizing.dimensions(for: CGSize(width: 6000, height: 4000)), ExportDimensions(width: 3840, height: 2560), "Large stays Large")
        XCTAssertFalse(restored.lossless); XCTAssertEqual(restored.quality, 0.7); XCTAssertEqual(restored.aiDenoise, 30)
        XCTAssertTrue(restored.sizing.allowsEnlarging); XCTAssertEqual(restored.profile.preset, .displayP3)
        XCTAssertEqual(preset.detail, "WebP - 70% - 8-bit - 3840 px - Display P3")
        // "As Developed": each photo keeps its own profile.
        ExportPreset.saveUserPreset(name: "Own", settings: settings, developedProfile: true, defaults: defaults)
        var own = ColorProfile(); own.preset = .adobeRGB
        XCTAssertEqual(try XCTUnwrap(ExportPreset.savedByUser(defaults).last).settings(developmentProfile: own).profile.preset, .adobeRGB)
    }
    func testFixedSizePresetsCropCentrallyThenScaleToExactPixels() throws {
        let story = try XCTUnwrap(ExportPreset.named("instagram-story"))
        let settings = story.settings()
        XCTAssertEqual(settings.format, .jpeg); XCTAssertEqual(settings.depth, 8)
        XCTAssertEqual(settings.profile.preset, .sRGB)
        XCTAssertFalse(settings.includeMetadata, "Social exports leave capture metadata and location out")
        // A 3:2 landscape keeps its full height and the centered 9:16 slice of its width.
        XCTAssertEqual(settings.sizing.cropRect(for: CGSize(width: 6000, height: 4000)), CGRect(x: 1875, y: 0, width: 2250, height: 4000))
        // A tall portrait keeps its width and the centered slice of its height.
        XCTAssertEqual(settings.sizing.cropRect(for: CGSize(width: 1000, height: 3000)), CGRect(x: 0, y: 611, width: 1000, height: 1777))
        for source in [CGSize(width: 6000, height: 4000), CGSize(width: 1000, height: 3000), CGSize(width: 300, height: 200)] {
            XCTAssertEqual(try settings.sizing.dimensions(for: source), ExportDimensions(width: 1080, height: 1920), "Exactly the required pixels, even from a small photo")
        }
        try settings.validate()
        XCTAssertEqual(story.detail, "JPEG - 90% - 8-bit - 1080 × 1920 px - sRGB")
        XCTAssertTrue(ExportPreset.social.allSatisfy { $0.frame != nil }, "Social presets have explicit crop targets")
        XCTAssertEqual(ExportPreset.socialByPlatform.map(\.platform), ["Instagram", "Facebook", "Threads", "X", "TikTok", "Pinterest", "YouTube", "LinkedIn"])
    }
    func testFullSizePresetsKeepTheDevelopmentProfileAndMetadata() throws {
        var developed = ColorProfile(); developed.preset = .adobeRGB
        let tiff = try XCTUnwrap(ExportPreset.named("tiff-16")).settings(developmentProfile: developed)
        XCTAssertEqual(tiff.format, .tiff); XCTAssertEqual(tiff.depth, 16)
        XCTAssertEqual(tiff.profile.preset, .adobeRGB); XCTAssertTrue(tiff.includeMetadata)
        XCTAssertNil(tiff.sizing.longEdge)
        XCTAssertEqual(try tiff.sizing.dimensions(for: CGSize(width: 6000, height: 4000)), ExportDimensions(width: 6000, height: 4000))
        XCTAssertEqual(Set((ExportPreset.standard + ExportPreset.social).map(\.id)).count, ExportPreset.standard.count + ExportPreset.social.count, "Preset IDs are unique")
        for preset in ExportPreset.standard + ExportPreset.social where preset.format.isAvailable { XCTAssertNoThrow(try preset.settings().validate(), preset.name) }
    }
    /// JPEG goes out in sRGB whatever the photo was developed in; HEIC keeps the development profile.
    func testJPEGPresetsDeliverSRGBAndHEICKeepsTheProfile() throws {
        var developed = ColorProfile(); developed.preset = .adobeRGB
        for id in ["jpeg-full", "jpeg-2560"] { XCTAssertEqual(try XCTUnwrap(ExportPreset.named(id)).settings(developmentProfile: developed).profile.preset, .sRGB, id) }
        XCTAssertEqual(try XCTUnwrap(ExportPreset.named("heic-full")).settings(developmentProfile: developed).profile.preset, .adobeRGB)
    }
    func testAutomaticProfileIsSRGBExceptHEIF() throws {
        XCTAssertEqual(ColorProfile().preset, .automatic)
        XCTAssertEqual(Adjustments().colorProfile.preset, .automatic)
        var settings = ExportSettings()
        for format in ExportFormat.allCases {
            settings.select(format)
            let expected: RGBProfile = format == .heif ? .displayP3 : .sRGB
            XCTAssertEqual(settings.resolvedProfile.preset, expected, format.rawValue)
            XCTAssertEqual(try settings.colorSpace().name, expected.space.name, format.rawValue)
            XCTAssertEqual(settings.profileLabel, expected.rawValue)
        }
        // A profile chosen in the development is kept in every format.
        settings.profile.preset = .displayP3; settings.select(.jpeg)
        XCTAssertEqual(try settings.colorSpace().name, CGColorSpace.displayP3)
        settings.profile.preset = .sRGB; settings.select(.heif)
        XCTAssertEqual(try settings.colorSpace().name, CGColorSpace.sRGB)
        // A gain map's SDR base follows the same rule.
        settings.profile.preset = .automatic; settings.setHDR(true); settings.setHDREncoding(.gainMap)
        XCTAssertEqual(settings.profileLabel, "Display P3 + HDR gain map")
        settings.select(.jpeg)
        XCTAssertEqual(settings.profileLabel, "sRGB + HDR gain map")
    }
}
