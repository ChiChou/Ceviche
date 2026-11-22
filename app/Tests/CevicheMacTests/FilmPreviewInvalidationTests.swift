import XCTest
import SwiftUI
@testable import CevicheMac
import CevicheCore

final class FilmPreviewInvalidationTests: XCTestCase {
    @MainActor func testImageSwitchAndEditClearPreviewsBeforeReplacement() async throws {
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let (directory, first) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: first, to: second)
        let model = EditorModel()
        defer { model.closeDocument() }
        let opened = await model.open(first)
        XCTAssertTrue(opened)
        model.prewarmFilmPreviews(after: .zero)
        for _ in 0..<200 where model.filmPreviews.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.filmPreviews.isEmpty)
        model.edit { $0.exposure += 1 }
        XCTAssertTrue(model.filmPreviews.isEmpty, "An edit must blank stale previews immediately")
        model.prewarmFilmPreviews(after: .zero)
        for _ in 0..<200 where model.filmPreviews.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(model.filmPreviews.isEmpty)
        // The Darkroom's strip and ring prints belong to the photo too.
        model.edit { $0.film = FilmSimulation(stock: "portra400") }
        let prints = await model.filmPrints(model.adjustments, exposures: [0, 0.5])
        XCTAssertEqual(prints.count, 2)
        model.filmProofs.startStrip(model.adjustments)
        for (index, print) in prints.enumerated() { model.filmProofs.keep(print, exposure: index * 500) }
        XCTAssertEqual(model.filmProofs.strip.count, 2)
        let switched = await model.open(second)
        XCTAssertTrue(switched)
        XCTAssertEqual(model.filmProofs.strip.count, 0, "A new photo must not show the old photo's prints")
        XCTAssertNil(model.filmProofs.stripBase)
        XCTAssertTrue(model.filmPreviews.isEmpty, "A new photo must not inherit the old photo's previews")
        model.closeDocument()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(model.filmPreviews.isEmpty, "Cancelled work must not repopulate previews")
    }

    /// A film under the pointer shows in the canvas, and the photo's own film comes back when the pointer leaves.
    @MainActor func testHoveringAFilmPreviewsItOnTheCanvas() async throws {
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel()
        defer { model.closeDocument() }
        let opened = await model.open(photo)
        XCTAssertTrue(opened)
        func settled() async throws -> [UInt8] {
            try await Task.sleep(for: .milliseconds(300))
            for _ in 0..<200 where model.isRendering { try await Task.sleep(for: .milliseconds(50)) }
            let image = try XCTUnwrap(model.preview)
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return pixel
        }
        model.edit { $0.film = FilmSimulation(stock: "portra400") }
        let own = try await settled()
        var hovered = model.adjustments; hovered.film = FilmSimulation(stock: "trix400")
        model.showLookPreview(hovered)
        let preview = try await settled()
        XCTAssertNotEqual(own, preview)
        XCTAssertEqual(preview[0], preview[1], accuracy: 2, "Tri-X is black and white")
        model.showLookPreview(nil)
        let back = try await settled()
        XCTAssertEqual(own, back)
    }

    /// Optional visual check of the Darkroom's steps: CEVICHE_UI_SNAPSHOTS=1 writes /private/tmp/ceviche-darkroom-<medium>.png
    /// for a paper, a print film, a scan and a slide, whose Print steps differ, and for a film the catalog lacks.
    @MainActor func testDarkroomPanelSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional snapshots") }
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = EditorModel()
        defer { model.closeDocument() }
        let opened = await model.open(photo)
        XCTAssertTrue(opened)
        for (name, stock, medium) in [("paper", "portra400", nil), ("print-film", "vision500t", nil), ("scan", "trix400", "screen"), ("slide", "velvia50", nil), ("unknown", "kodak_gold_200", nil)] as [(String, String, String?)] {
            model.edit { $0.film = FilmSimulation(stock: stock); $0.film?.medium = medium }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 4600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ScrollView { FilmPanel(model: model) }.frame(width: 300, height: 4600).preferredColorScheme(.dark))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-darkroom-\(name).png"))
            window.close()
        }
    }
}
