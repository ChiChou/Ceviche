import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

final class WatermarkTests: XCTestCase {
    private var directory: URL!
    private var library: WatermarkLibrary!
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-watermark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = WatermarkLibrary(root: directory.appendingPathComponent("Watermarks"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    /// A solid red image of `width` × `height`, written as `type`.
    private func image(_ name: String, width: Int = 40, height: Int = 20, type: UTType = .png) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    /// Red, green, blue and alpha at a pixel, top-left origin.
    private func pixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
        var value = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return value
    }
    private let photo = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))

    func testLibraryCopiesImagesInAndKeepsOnlyThoseItUses() throws {
        XCTAssertThrowsError(try library.importImage(try image("logo.jpg", type: .jpeg)), "Formats without transparency are refused")
        let first = try library.importImage(try image("logo.png"))
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL.path, library.root.path)
        var watermark = Watermark(name: "Studio", image: first)
        try library.save(watermark)
        XCTAssertEqual(library.watermarks(), [watermark])
        XCTAssertEqual(library.watermark(id: watermark.id)?.name, "Studio")

        // A new image replaces the old one, which is removed; an image no watermark uses is pruned.
        let second = try library.importImage(try image("other.png"))
        watermark.image = second; watermark.setLayout(.tiled)
        try library.save(watermark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(library.watermarks().map(\.layout), [.tiled])
        let orphan = try library.importImage(try image("orphan.png"))
        library.discardImage(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "A saved watermark's image is never discarded")
        library.pruneImages()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        // Images outside the library are not saved by reference.
        XCTAssertThrowsError(try library.save(Watermark(name: "Outside", image: try image("outside.png"))))

        // The library moving (a renamed container) does not lose the images.
        let moved = directory.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: library.root, to: moved)
        XCTAssertEqual(WatermarkLibrary(root: moved).watermarks().first?.image?.standardizedFileURL, moved.appendingPathComponent(second.lastPathComponent).standardizedFileURL)

        try WatermarkLibrary(root: moved).delete(watermark.id)
        XCTAssertTrue(WatermarkLibrary(root: moved).watermarks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(second.lastPathComponent).path))
    }

    /// An entry this build can't read keeps its place and its image: nothing is pruned, and saving another
    /// watermark writes it back as it was.
    func testUnreadableEntryKeepsItsImageAndItsPlace() throws {
        let used = try library.importImage(try image("logo.png"))
        let index = library.root.appendingPathComponent("Watermarks.json")
        try Data(#"[{"name":"From a newer build","image":"\#(used.path)","kind":"hologram"}]"#.utf8).write(to: index)
        XCTAssertTrue(library.watermarks().isEmpty)
        library.pruneImages()
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path), "An unreadable entry may use it")
        try library.save(Watermark(name: "Studio", text: WatermarkText(string: "©")))
        XCTAssertEqual(library.watermarks().map(\.name), ["Studio"])
        XCTAssertTrue(try String(contentsOf: index, encoding: .utf8).contains("hologram"), "The unreadable entry is written back")
        // A file that isn't a list is kept aside before it is written over.
        try Data("[{\"name\"".utf8).write(to: index)
        try library.save(Watermark(name: "Again", text: WatermarkText(string: "©")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Watermarks.damaged.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
    }

    func testCornerWatermarkSitsInsideTheMarginAtItsSize() throws {
        var watermark = Watermark(name: "Mark", image: try image("logo.png", width: 40, height: 20))
        watermark.corner = .bottomRight; watermark.scale = 0.2; watermark.spacing = 0.05
        // Long edge 0.2 × 300 = 60 px, so 60 × 30, 15 px from the right and bottom edges.
        let stamped = try watermark.composited(over: photo)
        XCTAssertEqual(stamped.extent, photo.extent)
        XCTAssertEqual(pixel(stamped, x: 400 - 15 - 30, y: 300 - 15 - 15)[0], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(stamped, x: 400 - 10, y: 300 - 10)[0], 0, accuracy: 0.01, "The margin stays clear")
        XCTAssertEqual(pixel(stamped, x: 400 - 15 - 64, y: 300 - 30)[0], 0, accuracy: 0.01)
        XCTAssertEqual(pixel(stamped, x: 20, y: 20)[0], 0, accuracy: 0.01)

        watermark.corner = .topLeft; watermark.opacity = 0.5
        let faded = try watermark.composited(over: photo)
        XCTAssertEqual(pixel(faded, x: 15 + 30, y: 15 + 15)[0], 0.5, accuracy: 0.02)
        XCTAssertEqual(pixel(faded, x: 400 - 30, y: 300 - 20)[0], 0, accuracy: 0.01)
    }

    func testEdgeAndCenterPlacesOfTheNinePointGrid() throws {
        var watermark = Watermark(name: "Mark", image: try image("logo.png", width: 40, height: 20))
        watermark.scale = 0.2; watermark.spacing = 0.05
        XCTAssertEqual(Set(Watermark.Corner.grid), Set(Watermark.Corner.allCases))
        // 60 × 30 px, 15 px from the edges it sits against, centred on the others.
        watermark.corner = .center
        XCTAssertEqual(pixel(try watermark.composited(over: photo), x: 200, y: 150)[0], 1, accuracy: 0.01)
        watermark.corner = .top
        let top = try watermark.composited(over: photo)
        XCTAssertEqual(pixel(top, x: 200, y: 15 + 15)[0], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(top, x: 200, y: 150)[0], 0, accuracy: 0.01)
        watermark.corner = .right
        let right = try watermark.composited(over: photo)
        XCTAssertEqual(pixel(right, x: 400 - 15 - 30, y: 150)[0], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(right, x: 400 - 10, y: 150)[0], 0, accuracy: 0.01, "The margin stays clear")
        let preview = try watermark.preview(over: nil, longEdge: 300)
        XCTAssertEqual(max(preview.width, preview.height), 300)
    }

    func testTiledWatermarkCoversThePhotoFadedAndCentered() throws {
        var watermark = Watermark(name: "Pattern", image: try image("logo.png", width: 40, height: 20))
        watermark.setLayout(.tiled)
        XCTAssertEqual(watermark.opacity, 0.25, "Tiled watermarks start faded")
        let stamped = try watermark.composited(over: photo)
        XCTAssertEqual(stamped.extent, photo.extent)
        XCTAssertEqual(pixel(stamped, x: 200, y: 150)[0], 0.25, accuracy: 0.02, "One mark sits on the center")
        // Marks repeat over the whole photo, with gaps between them.
        var covered = 0, clear = 0
        for y in stride(from: 5, to: 300, by: 10) {
            for x in stride(from: 5, to: 400, by: 10) {
                let red = pixel(stamped, x: x, y: y)[0]
                if red > 0.2 { covered += 1 } else if red < 0.01 { clear += 1 }
            }
        }
        XCTAssertGreaterThan(covered, 150); XCTAssertGreaterThan(clear, 150)
        for (x0, y0) in [(0, 0), (200, 0), (0, 150), (200, 150)] {
            let reached = stride(from: y0, to: y0 + 150, by: 5).contains { y in stride(from: x0, to: x0 + 200, by: 5).contains { x in pixel(stamped, x: x, y: y)[0] > 0.2 } }
            XCTAssertTrue(reached, "The pattern reaches the quarter at \(x0), \(y0)")
        }
    }

    func testLayoutDefaultsFollowTheLayoutUnlessChanged() {
        var watermark = Watermark(name: "Mark", image: URL(fileURLWithPath: "/tmp/mark.png"))
        watermark.setLayout(.tiled)
        XCTAssertEqual(watermark.opacity, 0.25); XCTAssertEqual(watermark.spacing, 0.2)
        watermark.opacity = 0.4
        watermark.setLayout(.corner)
        XCTAssertEqual(watermark.opacity, 0.4, "A value the user set is kept")
        XCTAssertEqual(watermark.spacing, 0.03)
        watermark.opacity = 3
        XCTAssertThrowsError(try watermark.validate())
    }

    func testSettingsAndSavedPresetsCarryTheWatermark() throws {
        let watermark = Watermark(name: "Studio", image: try library.importImage(try image("logo.png")))
        try library.save(watermark)
        var settings = ExportSettings(); settings.select(.jpeg); settings.watermark = watermark
        let decoded = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.watermark, watermark)
        XCTAssertNil(try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"format":"JPEG"}"#.utf8)).watermark)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ceviche-watermark-tests-" + UUID().uuidString))
        ExportPreset.saveUserPreset(name: "Web", settings: settings, defaults: defaults)
        let preset = try XCTUnwrap(ExportPreset.savedByUser(defaults).first)
        XCTAssertEqual(preset.watermark, watermark.id)
        XCTAssertEqual(preset.settings(watermarks: library).watermark, watermark)
        try library.delete(watermark.id)
        XCTAssertNil(preset.settings(watermarks: library).watermark, "A deleted watermark is left out")
    }

    func testExportsAndTheirPreviewCarryTheWatermark() async throws {
        let source = directory.appendingPathComponent("photo.png")
        try context.writePNGRepresentation(of: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)),
                                           to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let (renderer, adjustments) = try RawRenderer.open(source)
        var watermark = Watermark(name: "Mark", image: try image("logo.png", width: 40, height: 20))
        watermark.scale = 0.2; watermark.spacing = 0.05
        var settings = ExportSettings(); settings.select(.jpeg); settings.quality = 1; settings.watermark = watermark
        settings.profile.preset = .sRGB
        let url = directory.appendingPathComponent("stamped.jpg")
        try await renderer.export(to: url, adjustments: adjustments, settings: settings)
        let exported = try XCTUnwrap(CIImage(contentsOf: url))
        let mark = pixel(exported, x: 400 - 15 - 30, y: 300 - 15 - 15), plain = pixel(exported, x: 40, y: 40)
        XCTAssertGreaterThan(mark[0], 0.9); XCTAssertLessThan(mark[1], 0.05)
        XCTAssertEqual(plain[0], plain[1], accuracy: 0.02, "Away from the corner the photo is untouched")

        // The dialog's smaller preview places it the same way, in proportion.
        let preview = CIImage(cgImage: try await renderer.exportPreview(adjustments, settings: settings, maxDimension: 200))
        XCTAssertEqual(preview.extent.size, CGSize(width: 200, height: 150))
        XCTAssertGreaterThan(pixel(preview, x: 200 - 8 - 15, y: 150 - 8 - 8)[0], 0.9)

        try FileManager.default.removeItem(at: XCTUnwrap(watermark.image))
        do {
            try await renderer.export(to: url, adjustments: adjustments, settings: settings)
            XCTFail("A missing watermark image stops the export")
        } catch {}
    }

    func testTextIsDrawnAtTheSizeAskedWithTransparencyAround() throws {
        var text = WatermarkText(string: "© 2026 Studio"); text.shadow = false
        for edge in [80.0, 600, 3000] {
            let image = try text.rendered(longEdge: edge)
            XCTAssertEqual(Double(max(image.width, image.height)), edge, accuracy: edge * 0.02 + 2, "Drawn for its size, not scaled from a bitmap")
            XCTAssertGreaterThan(image.width, image.height * 3, "One line of text")
        }
        let drawn = CIImage(cgImage: try text.rendered(longEdge: 600))
        XCTAssertEqual(pixel(drawn, x: 0, y: 0)[3], 0, accuracy: 0.01, "Transparent around the letters")
        var white = 0
        for x in stride(from: 0, to: Int(drawn.extent.width), by: 3) { let p = pixel(drawn, x: x, y: Int(drawn.extent.height) / 2); if p[3] > 0.9 && p.prefix(3).allSatisfy({ $0 > 0.95 }) { white += 1 } }
        XCTAssertGreaterThan(white, 10, "The letters are white")
        text.string = "  "
        XCTAssertThrowsError(try text.rendered(longEdge: 100))
    }

    func testTextWatermarksNeedNoImageAndStampLikeImages() throws {
        var text = WatermarkText(string: "WATERMARK"); text.shadow = false
        var watermark = Watermark(name: "Text", text: text)
        watermark.corner = .bottomRight; watermark.scale = 0.5; watermark.spacing = 0.05
        // Long edge 0.5 × 300 = 150 px, 15 px from the right and bottom.
        let stamped = try watermark.composited(over: photo)
        var hits = 0
        for y in stride(from: 300 - 15 - 20, to: 300 - 15, by: 2) { for x in stride(from: 400 - 15 - 150, to: 400 - 15, by: 2) where pixel(stamped, x: x, y: y)[0] > 0.9 { hits += 1 } }
        XCTAssertGreaterThan(hits, 20)
        XCTAssertEqual(pixel(stamped, x: 20, y: 20)[0], 0, accuracy: 0.01)

        try library.save(watermark)
        XCTAssertEqual(library.watermarks(), [watermark], "Saved without an image file")
        XCTAssertEqual(try JSONDecoder().decode(Watermark.self, from: JSONEncoder().encode(watermark)), watermark)
        var both = watermark; both.image = try library.importImage(try image("logo.png"))
        XCTAssertThrowsError(try both.validate(), "Either an image or text, not both")
        var empty = watermark; empty.text?.string = ""
        XCTAssertThrowsError(try library.save(empty))
        // Turning it into an image watermark keeps the library consistent.
        var picture = watermark; picture.text = nil; picture.image = both.image
        try library.save(picture)
        XCTAssertNil(library.watermark(id: watermark.id)?.text)
        picture.image = nil; picture.text = text
        try library.save(picture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: both.image!.path), "The image it no longer uses is removed")
    }

    func testTileAngleTurnsThePattern() throws {
        var watermark = Watermark(name: "Pattern", image: try image("logo.png", width: 40, height: 20))
        watermark.setLayout(.tiled); watermark.opacity = 1
        XCTAssertEqual(watermark.angle, 45)
        // A 75 × 37.5 px mark on the center: level rows reach 30 px to the side but not 30 px up; a quarter turn, the reverse.
        watermark.angle = 0
        var stamped = try watermark.composited(over: photo)
        XCTAssertGreaterThan(pixel(stamped, x: 230, y: 150)[0], 0.9)
        XCTAssertLessThan(pixel(stamped, x: 200, y: 120)[0], 0.1)
        watermark.angle = 90
        stamped = try watermark.composited(over: photo)
        XCTAssertLessThan(pixel(stamped, x: 230, y: 150)[0], 0.1)
        XCTAssertGreaterThan(pixel(stamped, x: 200, y: 120)[0], 0.9)
        watermark.angle = 200
        XCTAssertThrowsError(try watermark.validate())
        // Without an angle, a watermark is at 45°.
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(watermark)) as? [String: Any])
        stored["angle"] = nil
        XCTAssertEqual(try JSONDecoder().decode(Watermark.self, from: JSONSerialization.data(withJSONObject: stored)).angle, 45)
    }
}

final class SavedListTests: XCTestCase {
    /// One preset this build can't read hides nothing else, and saving or deleting another keeps it.
    func testExportPresetsKeepEntriesThisBuildCantRead() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ceviche-saved-list-" + UUID().uuidString))
        ExportPreset.saveUserPreset(name: "Web", settings: ExportSettings(), defaults: defaults)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: "userExportPresets"))) as? [Any])
        stored.append(["id": "user-newer", "name": "Newer", "settings": ["format": "hologram"]])
        defaults.set(try JSONSerialization.data(withJSONObject: stored), forKey: "userExportPresets")
        XCTAssertEqual(ExportPreset.savedByUser(defaults).map(\.name), ["Web"])
        let web = try XCTUnwrap(ExportPreset.savedByUser(defaults).first)
        ExportPreset.deleteUserPreset(web.id, defaults: defaults)
        ExportPreset.saveUserPreset(name: "Print", settings: ExportSettings(), defaults: defaults)
        XCTAssertEqual(ExportPreset.savedByUser(defaults).map(\.name), ["Print"])
        let raw = try XCTUnwrap(String(data: XCTUnwrap(defaults.data(forKey: "userExportPresets")), encoding: .utf8))
        XCTAssertTrue(raw.contains("user-newer"), raw)
    }
    /// A section a newer build added is skipped; the sections turned off stay off.
    func testUnknownDisabledSectionIsSkipped() throws {
        var settings = Adjustments(); settings.disabledSections = [.grain]
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        tree["disabledSections"] = ["grain", "hologram"]
        let read = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(read.disabledSections, [.grain])
    }
}
