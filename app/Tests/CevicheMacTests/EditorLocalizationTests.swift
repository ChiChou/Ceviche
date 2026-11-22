import XCTest
import CevicheCore
@testable import CevicheMac

final class EditorLocalizationTests: XCTestCase {
    @MainActor func testMCPPreferencesKeepStableKeysInEveryLanguage() throws {
        let suite = "LocalizationMCP-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MCPController(preferences: defaults)
        controller.readOnly = true
        controller.commitReadOnly()
        controller.previewMaxEdge = 512
        controller.commitPreviewMaxEdge()
        XCTAssertTrue(defaults.bool(forKey: "mcp.readOnly"))
        XCTAssertEqual(defaults.integer(forKey: "mcp.previewMaxEdge"), 512)
    }

    func testSliderColorRampsUseStableKeys() {
        XCTAssertEqual(SliderAppearance.parameter("Temperature"), .temperature)
        XCTAssertEqual(SliderAppearance.parameter("Exposure"), .luminance)
        XCTAssertEqual(SliderAppearance.parameter("Red hue"), .hueShift(0))
    }
}
