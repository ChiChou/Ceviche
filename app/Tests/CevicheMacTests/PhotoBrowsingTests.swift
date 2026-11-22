import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class PhotoBrowsingTests: XCTestCase {
    @MainActor func testNavigationSavesEditsKeepsFilteredSequenceAndStopsAtEnd() async throws {
        let (directory, firstURL) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        for index in 0..<3 {
            let url = directory.appendingPathComponent("photo-\(index).jpg"); try FileManager.default.copyItem(at: firstURL, to: url)
            let prepared = try CatalogImporter.prepare(url); var asset = prepared.0
            asset.captureDay = "2026-10-0\(index + 1)"; asset.rating = index == 0 ? 0 : 4
            _ = try await store.insert(asset, thumbnail: prepared.1)
        }
        catalog.filter.minimumRating = 4; await catalog.refresh()
        let first = try XCTUnwrap(catalog.assets.first), second = catalog.assets[1]
        let opened = await catalog.openPhoto(first, editor: editor)
        XCTAssertTrue(opened); XCTAssertEqual(catalog.browsingAssets.count, 2)
        editor.edit { $0.exposure = 0.7 }
        let advanced = await catalog.navigate(1, editor: editor)
        XCTAssertTrue(advanced); XCTAssertEqual(editor.catalogAssetID, second.id)
        let persisted = try await store.photo(first.id)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: XCTUnwrap(persisted.adjustmentsData)).exposure, 0.7)
        let ended = await catalog.navigate(1, editor: editor)
        XCTAssertFalse(ended)
        let returned = await catalog.navigate(-1, editor: editor)
        XCTAssertTrue(returned); XCTAssertEqual(editor.catalogAssetID, first.id)
        XCTAssertEqual(editor.adjustments.exposure, 0.7)
        await catalog.closePhoto(editor: editor)
        XCTAssertTrue(catalog.showingLibrary)
        XCTAssertEqual(catalog.selected?.id, first.id); XCTAssertTrue(catalog.browsingAssets.isEmpty)
        XCTAssertFalse(editor.hasImage)
    }
    /// ⌘A in Develop selects the whole filmstrip and keeps the photo open; ⇧⌘A goes back to it alone; a hidden
    /// filmstrip selects nothing.
    @MainActor func testSelectAllInDevelopFilmstrip() async throws {
        let (directory, firstURL) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        for index in 0..<3 {
            let url = directory.appendingPathComponent("photo-\(index).jpg"); try FileManager.default.copyItem(at: firstURL, to: url)
            let prepared = try CatalogImporter.prepare(url)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        await catalog.refresh()
        let open = try XCTUnwrap(catalog.assets.first)
        let opened = await catalog.openPhoto(open, editor: editor)
        XCTAssertTrue(opened); XCTAssertEqual(catalog.browsingAssets.count, 3)
        editor.showFilmstrip = true
        catalog.selectAllInFilmstrip(editor: editor)
        XCTAssertEqual(catalog.selectedIDs, Set(catalog.browsingAssets.map(\.id)))
        XCTAssertEqual(editor.catalogAssetID, open.id)
        XCTAssertEqual(catalog.cullingTargets(editor: editor).count, 3, "Culling keys and Paste Edits act on the whole selection")
        catalog.deselectFilmstrip(editor: editor)
        XCTAssertEqual(catalog.selectedIDs, [open.id])
        editor.showFilmstrip = false
        catalog.selectAllInFilmstrip(editor: editor)
        XCTAssertEqual(catalog.selectedIDs, [open.id], "Nothing is selected out of sight")
    }

    @MainActor func testClipboardAcrossPhotosIsUndoableAndCatalogPastePreservesHistory() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store), prepared = try CatalogImporter.prepare(url)
        let first = try await store.insert(prepared.0, thumbnail: prepared.1)
        let otherURL = directory.appendingPathComponent("other.jpg"); try FileManager.default.copyItem(at: url, to: otherURL)
        let other = try CatalogImporter.prepare(otherURL), second = try await store.insert(other.0, thumbnail: other.1)
        let originalBytes = try Data(contentsOf: otherURL)
        await catalog.refresh()
        _ = await catalog.openPhoto(first, editor: editor)
        editor.edit { $0.exposure = 1.2; $0.selectiveColors[2].saturation = -25 }
        editor.copyEdits(.edited); let editedCopy = try XCTUnwrap(editor.copiedEdits)
        XCTAssertEqual(editedCopy.items, [.light, .selectiveColor], "Only what differs from the photo's camera defaults")
        editor.copyEdits(); XCTAssertEqual(editor.copiedEdits?.sourceName, first.filename)
        XCTAssertEqual(editor.copiedEdits?.items, Set(EditTransferItem.allCases), "Copy Edits takes every setting")
        await catalog.closePhoto(editor: editor)
        await catalog.selectAsset(second); catalog.metadata.title = "Destination title"
        await catalog.pasteEdits(to: [second], editor: editor)
        XCTAssertNil(catalog.error)
        let saved = try await EditorFixtures.withCurrentThumbnail(store, id: second.id), settings = try JSONDecoder().decode(Adjustments.self, from: XCTUnwrap(saved.adjustmentsData))
        XCTAssertEqual(saved.title, "Destination title"); XCTAssertEqual(settings.exposure, 1.2)
        XCTAssertEqual(saved.thumbnailRenderKey, saved.renderKey)
        let history = try await store.history(assetID: second.id)
        XCTAssertTrue(history.contains { $0.summary == "Original development" })
        XCTAssertTrue(history.contains { $0.summary.contains("Exposure") && $0.summary.contains("Selective colors") })
        _ = await catalog.openPhoto(saved.asset, editor: editor)
        editor.edit { $0.exposure = -0.5; $0.geometry.crop = CropRect(width: 0.8) }
        let beforePaste = editor.adjustments
        editor.pasteEdits(editedCopy); XCTAssertEqual(editor.adjustments.exposure, 1.2)
        XCTAssertEqual(editor.adjustments.geometry, beforePaste.geometry, "Edited settings leave the destination's crop")
        editor.undo(); XCTAssertEqual(editor.adjustments, beforePaste)
        editor.pasteEdits(); XCTAssertEqual(editor.adjustments.geometry, editedCopy.adjustments.geometry, "Copy Edits takes the crop too")
        editor.undo(); XCTAssertEqual(editor.adjustments, beforePaste)
        editor.redo(); XCTAssertEqual(editor.adjustments.exposure, 1.2)
        editor.closeDocument()
        XCTAssertEqual(try Data(contentsOf: otherURL), originalBytes)
    }
    @MainActor func testMissingOriginalKeepsCurrentPhotoAndTrashIsNotBrowsable() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store), prepared = try CatalogImporter.prepare(url)
        let first = try await store.insert(prepared.0, thumbnail: prepared.1)
        let secondURL = directory.appendingPathComponent("missing.jpg"); try FileManager.default.copyItem(at: url, to: secondURL)
        let other = try CatalogImporter.prepare(secondURL), second = try await store.insert(other.0, thumbnail: other.1)
        _ = await catalog.openPhoto(first, editor: editor)
        try FileManager.default.removeItem(at: secondURL)
        let failed = await catalog.openPhoto(second, editor: editor, keepSequence: true)
        XCTAssertFalse(failed); XCTAssertEqual(editor.catalogAssetID, first.id)
        editor.error = nil
        try await store.moveToTrash(second.id)
        let trashed = try await store.asset(second.id)
        let refused = await catalog.openPhoto(trashed, editor: editor)
        XCTAssertFalse(refused); XCTAssertEqual(editor.catalogAssetID, first.id)
        editor.closeDocument()
    }
    @MainActor func testBrowserAndColoredControlsSnapshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional browser snapshots") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        for file in [TestSamples.landscape, TestSamples.burst.first, TestSamples.burst.second] {
            let prepared = try CatalogImporter.prepare(try TestSamples.require(file))
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        try await store.setAnalysisEnabled(false)
        await catalog.refresh()
        let first = try XCTUnwrap(catalog.assets.first)
        _ = await catalog.openPhoto(first, editor: editor)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1420, height: 920), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: editor).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { catalog.stopIndexing(); editor.closeDocument(); window.close() }
        for mode in ["develop", "compact", "filmstrip-hidden", "copy", "library"] {
            if mode == "develop" { editor.toolTab = .light }
            if mode == "compact" { window.setContentSize(CGSize(width: 1000, height: 700)) }
            if mode == "filmstrip-hidden" { window.setContentSize(CGSize(width: 1420, height: 920)); editor.showFilmstrip = false }
            if mode == "copy" { editor.copyEdits(.choosing) }
            if mode == "library" { await catalog.closePhoto(editor: editor) }
            try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded()
            let captureView: NSView = mode == "copy" ? try XCTUnwrap(window.attachedSheet?.contentView) : host
            let bitmap = try XCTUnwrap(captureView.bitmapImageRepForCachingDisplay(in: captureView.bounds))
            captureView.cacheDisplay(in: captureView.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-\(mode)-refresh.png"))
            if mode == "copy" { editor.editCopyDraft = nil }
        }
    }
    @MainActor func testDevelopWithoutSelectionOpensFirstPhoto() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        XCTAssertNil(model.selected)
        let first = try XCTUnwrap(model.assets.first)
        XCTAssertTrue(model.canShow(.detail, editor: editor))
        model.show(.detail, editor: editor)
        for _ in 0..<300 where model.showingLibrary { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .detail)
        XCTAssertEqual(editor.catalogAssetID, first.id)
        XCTAssertEqual(model.selectedIDs, [first.id])
    }
    @MainActor func testCompareFromAMultipleSelectionPairsTheFirstTwoPhotosAndSwapsOnOpen() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let first = model.assets[0], second = model.assets[1], third = model.assets[2]
        model.select(first); model.select(second, toggling: true)
        for _ in 0..<300 where model.selected?.id != second.id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedIDs, [first.id, second.id])
        model.show(.compare, editor: editor)
        for _ in 0..<300 where model.viewMode != .compare { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.viewMode, .compare); XCTAssertEqual(model.compareSource, .twoPhotos)
        // The focused photo opens for editing; the other selected photo becomes its partner.
        XCTAssertEqual(editor.catalogAssetID, second.id); XCTAssertEqual(model.compareAsset?.id, first.id)
        model.prepareCompare(editor: editor)
        for _ in 0..<1000 where model.comparePreview == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.comparePreview, "partner render: \(model.error ?? "no error")")
        // Opening the partner exchanges the two roles.
        let reopened = await model.openPhoto(first, editor: editor, keepSequence: true)
        XCTAssertTrue(reopened)
        XCTAssertEqual(editor.catalogAssetID, first.id); XCTAssertEqual(model.compareAsset?.id, second.id)
        XCTAssertEqual(model.viewMode, .compare)
        // A third photo cannot be paired with itself, and leaving for the grid clears the pair.
        model.setCompareAsset(third, editor: editor); XCTAssertEqual(model.compareAsset?.id, third.id)
        model.setCompareAsset(first, editor: editor); XCTAssertEqual(model.compareAsset?.id, third.id)
        model.show(.detail, editor: editor); XCTAssertEqual(model.viewMode, .detail)
        await model.closePhoto(editor: editor)
        XCTAssertEqual(model.viewMode, .grid); XCTAssertNil(model.compareAsset); XCTAssertNil(model.comparePreview)
    }
    /// Waits up to `seconds` for `condition`, for state that settles on a throttle.
    @MainActor private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() { guard Date() < deadline else { return false }; try await Task.sleep(for: .milliseconds(25)) }
        return true
    }
    @MainActor func testFilmstripFollowsThumbnailsLiveEditsAndRemovals() async throws {
        let (directory, firstURL) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        for index in 0..<4 {
            let url = directory.appendingPathComponent("photo-\(index).jpg"); try FileManager.default.copyItem(at: firstURL, to: url)
            let prepared = try CatalogImporter.prepare(url); var asset = prepared.0
            asset.captureDay = "2026-10-0\(index + 1)"
            _ = try await store.insert(asset, thumbnail: prepared.1)
        }
        await catalog.refresh()
        let photos = catalog.assets
        let opened = await catalog.openPhoto(photos[0], editor: editor); XCTAssertTrue(opened); XCTAssertEqual(catalog.browsingAssets.count, 4)
        // A thumbnail stored elsewhere (a paste, a sync) reaches the filmstrip without any refresh.
        let before = try XCTUnwrap(catalog.browsingAssets.first { $0.id == photos[1].id }?.thumbnailKey)
        let other = try await store.asset(photos[1].id)
        let rendered = try XCTUnwrap(CatalogImporter.prepare(firstURL).1)
        try await store.installThumbnail(rendered + Data([0]), assetID: other.id, renderKey: other.renderKey)
        let adopted = try await eventually { catalog.browsingAssets.first { $0.id == photos[1].id }?.thumbnailKey != before }
        XCTAssertTrue(adopted, "The filmstrip kept a stale thumbnail")
        // The open photo's cell shows the edit as it is made, then the saved thumbnail replaces it.
        let openKey = catalog.browsingAssets.first { $0.id == photos[0].id }?.thumbnailKey
        editor.edit { $0.exposure = 1 }
        let live = try await eventually { editor.liveThumbnail?.assetID == photos[0].id }; XCTAssertTrue(live)
        catalog.showLiveThumbnail(try XCTUnwrap(editor.liveThumbnail?.image), of: photos[0].id)
        let saved = await editor.save(); XCTAssertTrue(saved)
        let arrived = try await eventually { catalog.browsingAssets.first { $0.id == photos[0].id }?.thumbnailKey != openKey }
        XCTAssertTrue(arrived, "The saved edit's thumbnail never arrived")
        XCTAssertNil(catalog.liveThumbnails[photos[0].id], "A live image outlived the saved thumbnail")
        // Removing the open photo from the catalog closes it, and the filmstrip drops it.
        await catalog.requestPermanentDeletion([catalog.browsingAssets[0]], editor: editor)
        await catalog.confirmPermanentDeletion()
        XCTAssertNil(catalog.error)
        XCTAssertFalse(catalog.browsingAssets.contains { $0.id == photos[0].id }, "The removed photo stayed in the filmstrip")
        XCTAssertEqual(catalog.browsingAssets.count, 3)
        // Trashing a photo that is not open drops it too.
        let reopened = await catalog.openPhoto(photos[1], editor: editor, keepSequence: true); XCTAssertTrue(reopened)
        await catalog.moveToTrash([photos[2]], editor: editor)
        XCTAssertEqual(catalog.browsingAssets.map(\.id), [photos[1].id, photos[3].id])
        editor.closeDocument()
    }
}
