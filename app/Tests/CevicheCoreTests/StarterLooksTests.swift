import XCTest
@testable import CevicheCore

final class StarterLooksTests: XCTestCase {
    /// Every look is a valid preset, and the set installs once: files already there are left as they are. A look
    /// keeps the photo's own exposure and white balance, and choosing another of its pack leaves nothing of the first.
    func testInstallsAsPresetsThatApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LookLibrary(root: root)
        let count = StarterLooks.packs.reduce(0) { $0 + $1.looks.count }
        XCTAssertEqual(try StarterLooks.install(in: library), count)
        XCTAssertEqual(try StarterLooks.install(in: library), 0)
        var base = Adjustments(); base.exposure = 0.7; base.highlights = -40; base.temperature = 4300; base.sharpness = 31
        for pack in StarterLooks.packs {
            XCTAssertEqual(Set(pack.looks.map(\.name)).count, pack.looks.count)
            let folder = library.folder(.presets).appendingPathComponent(pack.folder)
            var previous = base
            for look in pack.looks {
                let (applied, warnings) = try DevelopPreset.apply(folder.appendingPathComponent(look.name + ".xmp"), to: previous, defaults: Adjustments())
                let expected = pack.adjustments(look)
                XCTAssertTrue(warnings.isEmpty, "\(look.name): \(warnings)")
                XCTAssertEqual(applied.monochrome, pack.folder == "Black & White", look.name)
                // The look itself, whatever look was on before it.
                XCTAssertEqual(applied.parametricCurve, expected.parametricCurve, look.name)
                XCTAssertEqual(applied.splitToning, expected.splitToning, look.name)
                XCTAssertEqual(applied.vibrance, expected.vibrance, look.name); XCTAssertEqual(applied.saturation, expected.saturation, look.name)
                if pack.folder == "Color" {
                    XCTAssertEqual(applied.curve, expected.curve, look.name); XCTAssertEqual(applied.clarity, expected.clarity, look.name)
                    XCTAssertEqual(applied.grain, expected.grain, look.name); XCTAssertEqual(applied.postCropVignette, expected.postCropVignette, look.name)
                } else {
                    XCTAssertEqual(applied.blackWhiteMixer, expected.blackWhiteMixer, look.name)
                }
                // The photo's own correction stays.
                XCTAssertEqual(applied.exposure, 0.7, look.name); XCTAssertEqual(applied.highlights, -40, look.name)
                XCTAssertEqual(applied.temperature, 4300, look.name); XCTAssertEqual(applied.sharpness, 31, look.name)
                previous = applied
            }
        }
    }

    /// The lens filters do what the glass does: red turns a blue sky darker and skin lighter than no filter, green
    /// lifts foliage.
    func testFiltersLightenTheirOwnColour() throws {
        let pack = StarterLooks.blackWhite
        func grey(_ name: String, _ rgb: SIMD3<Double>) throws -> Double {
            pack.adjustments(try XCTUnwrap(pack.looks.first { $0.name == name })).blackWhiteMixer.transform(rgb).x
        }
        let sky = SIMD3(0.25, 0.45, 0.85), skin = SIMD3(0.85, 0.6, 0.5), leaf = SIMD3(0.25, 0.6, 0.2)
        XCTAssertLessThan(try grey("Filter Red", sky), try grey("Neutral", sky) - 0.05)
        XCTAssertLessThan(try grey("Filter Red", sky), try grey("Filter Yellow", sky))
        XCTAssertGreaterThan(try grey("Filter Red", skin), try grey("Neutral", skin))
        XCTAssertGreaterThan(try grey("Filter Green", leaf), try grey("Neutral", leaf) + 0.05)
    }

    /// The colour looks keep a mid grey a mid grey unless they are meant to move it, and none clips: every curve is
    /// a valid one with black and white where a print could hold them.
    func testColourLooksAreGentle() throws {
        for look in StarterLooks.color.looks {
            let settings = try StarterLooks.color.adjustments(look).validated()
            XCTAssertLessThanOrEqual(abs(settings.vibrance), 30, look.name); XCTAssertLessThanOrEqual(abs(settings.clarity), 20, look.name)
            XCTAssertLessThanOrEqual(settings.curve.points.first?.y ?? 0, 0.1, look.name)
            XCTAssertGreaterThanOrEqual(settings.curve.points.last?.y ?? 1, 0.9, look.name)
            for value in [settings.parametricCurve.shadows, settings.parametricCurve.darks, settings.parametricCurve.lights, settings.parametricCurve.highlights] {
                XCTAssertLessThanOrEqual(abs(value), 25, look.name)
            }
        }
    }
}
