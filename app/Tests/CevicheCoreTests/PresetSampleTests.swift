import XCTest
import CevicheTestSupport
@testable import CevicheCore

/// Parses a small sample of third-party presets and profiles in the git-ignored `presets/` folder: `.lrtemplate`
/// and `.xmp` develop presets, curves, and the Sony camera profiles they name.
final class PresetSampleTests: XCTestCase {
    func testSuppliedPresetsAndProfilesParse() throws {
        guard TestSamples.enabled else { throw XCTSkip("Sample files are off (CI or CEVICHE_SAMPLES=off)") }
        let presets = TestSamples.presets.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: presets.path) else { throw XCTSkip("No local presets folder") }
        let library = CameraProfileLibrary()
        guard !library.reload(folders: [presets]).isEmpty else { throw XCTSkip("No camera profiles in the local presets folder") }
        let resolver = library.resolver(make: "SONY", model: "ILCE-7R")
        var count = 0, profiled = 0, failures: [String] = []
        let walker = FileManager.default.enumerator(at: presets, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])!
        for case let url as URL in walker where LookKind(file: url) == .presets && !DevelopPreset.isBrushPreset(url) {
            count += 1
            do {
                let (adjustments, notes) = try DevelopPreset.apply(url, to: Adjustments(), defaults: Adjustments(), profiles: resolver)
                if adjustments.cameraProfile != nil { profiled += 1 }
                XCTAssertFalse(notes.contains { $0.contains("Enable") && $0.hasPrefix("Preserved") }, url.lastPathComponent)
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard count > 0 else { throw XCTSkip("No presets in the local presets folder") }
        XCTAssertGreaterThan(profiled, 0, "The presets that name a third-party profile find it for the camera")
        XCTAssertEqual(failures, [])
    }
}
