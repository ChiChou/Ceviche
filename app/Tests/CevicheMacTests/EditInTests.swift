import XCTest
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

final class EditInTests: XCTestCase {
    @MainActor func testRenderedCopyJoinsTheCatalogAndPicksUpOutsideSaves() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photo = model.assets[0]
        await model.setQuickMetadata([photo], rating: 4)

        // Beside the original, referenced there, on its own, with its rating.
        let url = try await model.renderForEditing(try await store.asset(photo.id), store: store)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, CatalogImporter.sourceURL(for: photo, root: store.root).deletingLastPathComponent().standardizedFileURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-edit.tiff"), url.lastPathComponent)
        let copies = try await store.photosEditedElsewhere(suffix: ExternalEditors.suffix)
        let copy = try XCTUnwrap(copies.first); XCTAssertEqual(copies.count, 1)
        let original = try await store.asset(photo.id)
        XCTAssertEqual(copy.rating, 4)
        XCTAssertNil(original.stackID); XCTAssertNil(copy.stackID, "The copy shows on its own, not folded into a group")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16)
        // Burnt in: the copy starts with no development to revert to.
        let copyDevelopment = try await store.development(copy.id)
        XCTAssertNil(copyDevelopment.adjustmentsData)
        let history = try await store.history(assetID: copy.id)
        XCTAssertTrue(history.filter { $0.kind == .edit }.isEmpty)
        var edits = Adjustments(); edits.exposure = 1
        try await store.saveEdits(edits, assetID: copy.id, baseline: Adjustments())
        let edited = try await store.asset(copy.id)

        // Another app saves over it at a new size; returning to Ceviche picks that up.
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 30))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        model.pickUpOutsideEdits(editor: editor)
        var refreshed = copy
        for _ in 0..<200 {
            refreshed = try await store.asset(copy.id)
            if refreshed.renderKey != edited.renderKey, !ExternalEditors.shared.checkingSaves { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(refreshed.renderKey, edited.renderKey)
        XCTAssertEqual(refreshed.fileSize, Int64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
        XCTAssertEqual(refreshed.info.width, 40); XCTAssertEqual(refreshed.rating, 4)
        XCTAssertTrue(try CatalogImporter.matches(url, refreshed), "Develop opens the saved file instead of calling it changed")
        let refreshedDevelopment = try await store.development(copy.id)
        XCTAssertNil(refreshedDevelopment.adjustmentsData, "Edits made on the old pixels go with them")
        let after = try await store.history(assetID: copy.id)
        XCTAssertTrue(after.filter { $0.kind == .edit }.isEmpty)

        // Nothing changed since: a second return leaves the photo alone.
        model.pickUpOutsideEdits(editor: editor)
        for _ in 0..<50 where ExternalEditors.shared.checkingSaves { try await Task.sleep(for: .milliseconds(10)) }
        let again = try await store.asset(copy.id)
        XCTAssertEqual(again.renderKey, refreshed.renderKey)
    }

    @MainActor func testJPEGCopyIsEightBit() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editors = ExternalEditors.shared, previous = editors.format
        editors.format = .jpeg; defer { editors.format = previous }
        let store = try XCTUnwrap(model.store)
        let url = try await model.renderForEditing(try await store.asset(model.assets[0].id), store: store)
        XCTAssertEqual(url.pathExtension, ExportFormat.jpeg.fileExtension)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 8)
        let copies = try await store.photosEditedElsewhere(suffix: ExternalEditors.suffix)
        XCTAssertEqual(copies.count, 1)
    }
}
