import XCTest
import ImageIO
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class PrintOutputTests: XCTestCase {
    @MainActor func testProofAndExportLayouts() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_PRINT_SNAPSHOTS"] == "1" else { return }
        _ = NSApplication.shared
        let proof = PrintProofState()
        let remembered = UserDefaults.standard.object(forKey: "printProofProfile")
        defer { UserDefaults.standard.set(remembered, forKey: "printProofProfile") }
        proof.selected = "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"
        for _ in 0..<100 where proof.profile == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(proof.profile)
        proof.coverage = (0.423, 0.043)
        proof.settings.gamutWarning = true
        func capture<Content: View>(_ content: Content, size: CGSize, name: String) async throws {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content.preferredColorScheme(.dark))
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/private/tmp/ceviche-\(name).png"))
        }
        for width in [1100.0, 650, 430] {
            try await capture(PrintProofBar(proof: proof).frame(width: width), size: CGSize(width: width, height: 140), name: "proof-\(Int(width))")
        }
        let (directory, source) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorModel()
        await editor.open(source)
        defer { editor.closeDocument() }
        try await capture(ExportDialog(model: editor), size: ExportDialog<EditorModel>.size, name: "export-print")
    }

    @MainActor func testHoverAndPinnedWarningsRemainIndependent() {
        let proof = PrintProofState()
        proof.previewWarning = .gamut
        XCTAssertTrue(proof.displaySettings.gamutWarning)
        XCTAssertFalse(proof.settings.gamutWarning)
        proof.toggle(.gamut)
        XCTAssertNil(proof.previewWarning)
        XCTAssertTrue(proof.settings.gamutWarning)
        proof.previewWarning = .shadow
        XCTAssertTrue(proof.displaySettings.gamutWarning)
        XCTAssertTrue(proof.displaySettings.shadowWarning)
        proof.previewWarning = nil
        XCTAssertFalse(proof.displaySettings.shadowWarning)
        proof.previewWarning = .gamut
        proof.toggle(.gamut)
        XCTAssertFalse(proof.displaySettings.gamutWarning, "Clicking off under the pointer must hide the overlay")
    }

    @MainActor func testPrintPagesUseFullSizeAndCleanUpTemporaryFiles() async throws {
        let (directory, source) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (renderer, adjustments) = try RawRenderer.open(source)
        var document: PhotoPrintDocument? = try PhotoPrintDocument()
        let temporary = try XCTUnwrap(document?.directory)
        try await document?.append(renderer: renderer, adjustments: adjustments)
        try await document?.append(renderer: renderer, adjustments: adjustments)
        let pages = try XCTUnwrap(document?.pages)
        XCTAssertEqual(pages.map(\.size), [CGSize(width: 160, height: 100), CGSize(width: 160, height: 100)])
        for page in pages {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(page.photo as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.bitsPerComponent, 16)
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.rommrgb)
        }
        document = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor func testBatchPrintIncludesEveryPhotoAndAppliesFilters() async throws {
        let (directory, catalog, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assets = Array(catalog.assets.prefix(3))
        XCTAssertEqual(assets.count, 3)
        let plain = try await PhotoPrintDocument.make(assets: assets, catalog: catalog)
        let filtered = try await PhotoPrintDocument.make(assets: assets, catalog: catalog,
                                                         filters: CreativeFilterStack([CreativeFilter(.fog, amount: 100)]))
        XCTAssertEqual(plain.pages.count, assets.count)
        XCTAssertEqual(filtered.pages.count, assets.count)
        func pixel(_ page: PhotoPrintDocument.Page) throws -> [UInt8] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(page.photo as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return rgba
        }
        for (original, result) in zip(plain.pages, filtered.pages) {
            XCTAssertNotEqual(try pixel(original), try pixel(result), "Print must include the filter stack on every page")
        }
    }
}
