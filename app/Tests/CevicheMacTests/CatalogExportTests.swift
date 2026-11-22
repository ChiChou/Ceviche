import XCTest
import SwiftUI
import AppKit
import ImageIO
import CevicheCore
@testable import CevicheMac

final class CatalogExportTests: XCTestCase {
    @MainActor func testLibraryExportRendersSavedDevelopmentWithoutOverwriting() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), asset = model.assets[0]
        let folder = directory.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = CatalogExportRequest(assets: [asset]).settings
        let firstResult = try await CatalogModel.exportFile(asset, store: store, settings: settings, to: folder); let first = try XCTUnwrap(firstResult)
        let secondResult = try await CatalogModel.exportFile(asset, store: store, settings: settings, to: folder); let second = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(first, second, "An existing export is never overwritten")
        XCTAssertEqual(first.pathExtension, "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(second as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // As Developed keeps the photo's own profile; a chosen preset applies to every photo.
        func profileName(_ url: URL) throws -> String {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            return properties[kCGImagePropertyProfileName as String] as? String ?? ""
        }
        XCTAssertEqual(try profileName(first), "sRGB IEC61966-2.1")
        let wideResult = try await CatalogModel.exportFile(asset, store: store, settings: settings, profile: .adobeRGB, to: folder); let wide = try XCTUnwrap(wideResult)
        XCTAssertEqual(try profileName(wide), "Adobe RGB (1998)")
        // A preset's long-edge cap resamples even though the size preset stays Original.
        var capped = ExportPreset.named("jpeg-2560")!.settings(); capped.sizing.longEdge = 80
        let smallResult = try await CatalogModel.exportFile(asset, store: store, settings: capped, to: folder); let small = try XCTUnwrap(smallResult)
        let smallSource = try XCTUnwrap(CGImageSourceCreateWithURL(small as CFURL, nil))
        let smallProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(smallSource, 0, nil) as? [String: Any])
        XCTAssertEqual(smallProperties[kCGImagePropertyPixelWidth as String] as? Int, 80)
        XCTAssertEqual(smallProperties[kCGImagePropertyPixelHeight as String] as? Int, 50)
        // A fixed-size preset crops the 160 × 100 fixture to 9:16 and scales it to the required pixels.
        var story = ExportPreset.named("instagram-story")!.settings(); story.sizing.frame = ExportDimensions(width: 45, height: 80)
        let framedResult = try await CatalogModel.exportFile(asset, store: store, settings: story, to: folder); let framed = try XCTUnwrap(framedResult)
        let framedSource = try XCTUnwrap(CGImageSourceCreateWithURL(framed as CFURL, nil))
        let framedProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(framedSource, 0, nil) as? [String: Any])
        XCTAssertEqual(framedProperties[kCGImagePropertyPixelWidth as String] as? Int, 45)
        XCTAssertEqual(framedProperties[kCGImagePropertyPixelHeight as String] as? Int, 80)
    }
    @MainActor func testExistingFilePoliciesSkipOverwriteOrRename() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), asset = model.assets[0]
        let folder = directory.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = CatalogExportRequest(assets: [asset]).settings
        let firstResult = try await CatalogModel.exportFile(asset, store: store, settings: settings, to: folder); let first = try XCTUnwrap(firstResult)
        let originalBytes = try Data(contentsOf: first)
        let skipped = try await CatalogModel.exportFile(asset, store: store, settings: settings, to: folder, existing: .skip)
        XCTAssertNil(skipped)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        var smaller = settings; smaller.quality = 0.3
        let overwrittenResult = try await CatalogModel.exportFile(asset, store: store, settings: smaller, to: folder, existing: .overwrite); let overwritten = try XCTUnwrap(overwrittenResult)
        XCTAssertEqual(overwritten, first)
        XCTAssertNotEqual(try Data(contentsOf: first), originalBytes, "Overwrite replaces the file in place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        let renamedResult = try await CatalogModel.exportFile(asset, store: store, settings: settings, to: folder, existing: .rename); let renamed = try XCTUnwrap(renamedResult)
        XCTAssertNotEqual(renamed, first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        // A batch session starts without enlarging and remembers the policy in its request.
        model.requestExport(Array(model.assets.prefix(2)))
        let session = try XCTUnwrap(model.exportSession)
        XCTAssertFalse(session.exportSettings.sizing.allowsEnlarging); XCTAssertTrue(session.exportsManyPhotos); XCTAssertNotNil(session.locationPanel)
        // CEVICHE_UI_SNAPSHOTS=1 writes the batch dialog to CEVICHE_TOOL_OUTPUT (or the temporary folder) as export-batch.png.
        if ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" {
            let host = NSHostingView(rootView: ExportDialog(model: session).preferredColorScheme(.dark).frame(width: 500, height: 620))
            host.appearance = NSAppearance(named: .darkAqua); host.frame = NSRect(x: 0, y: 0, width: 500, height: 620)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .seconds(2))
            try host.writePNG(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEVICHE_TOOL_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("export-batch.png"))
        }
        session.dismissExport()
    }
}
