import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogCollectionWorkflowTests: XCTestCase {
    @MainActor func testSidebarGroupActionsIgnoreTheGridAndConfirmTrash() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let prepared = try CatalogImporter.prepare(original)
        for index in 0..<3 {
            var photo = prepared.0
            photo.id = "photo-\(index)"; photo.importPath += "-\(index)"
            photo.importedAt = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
            photo.importBatchID = index == 2 ? "second" : "first"
            photo.captureDay = ["2025-01-02", "2025-02-03", ""][index]
            _ = try await store.insert(photo, thumbnail: nil)
        }
        // A group spanning imports must not pull an unrelated session into the action.
        try await store.stack(["photo-0", "photo-1", "photo-2"], cover: "photo-2")
        model.filter.search = "no matching photos"
        await model.refresh()
        let day = try XCTUnwrap(model.importDays.first?.id)
        XCTAssertTrue(model.assets.isEmpty)
        await model.actOnSidebarGroup(.imports(day: day, batchID: "first"), action: .trash, editor: editor)
        XCTAssertEqual(Set(model.pendingTrash?.map(\.id) ?? []), ["photo-0", "photo-1"])
        let trashCount = try await store.count(filter: { var f = CatalogFilter(); f.area = .trash; return f }())
        XCTAssertEqual(trashCount, 0)
        model.pendingTrash = nil
        await model.actOnSidebarGroup(.imports(day: day, batchID: nil), action: .newAlbum, editor: editor)
        XCTAssertEqual(Set(model.albumDraft?.assetIDs ?? []), ["photo-0", "photo-1", "photo-2"])
        model.albumDraft = nil
        let album = try await store.createAlbum(name: "Group")
        await model.actOnSidebarGroup(.imports(day: day, batchID: "second"), action: .addToAlbum(album.id), editor: editor)
        let members = try await store.activeAlbumPhotoIDs(album.id)
        XCTAssertEqual(members, ["photo-2"])
        await model.actOnSidebarGroup(.imports(day: day, batchID: "first"), action: .export, editor: editor)
        XCTAssertEqual(Set(model.exportSession?.assets.map(\.id) ?? []), ["photo-0", "photo-1"])
        model.exportSession = nil
        await model.actOnSidebarGroup(.imports(day: day, batchID: "first"), action: .select, editor: editor)
        XCTAssertEqual(model.selectedIDs, ["photo-0", "photo-1"])
        XCTAssertEqual(model.filter.importBatchID, "first")
        XCTAssertTrue(model.filter.search.isEmpty)
        for (period, ids) in [("2025", ["photo-0", "photo-1"]), ("2025-01", ["photo-0"]),
                              ("2025-02-03", ["photo-1"]), ("", ["photo-2"])] {
            await model.actOnSidebarGroup(.captureDate(period, area: .library), action: .select, editor: editor)
            XCTAssertEqual(model.selectedIDs, Set(ids), "Period: \(period), assets: \(model.assets.map { ($0.id, $0.captureDay) })")
            XCTAssertEqual(model.filter.captureDay, period)
        }
        try await store.moveToTrash("photo-0")
        await model.actOnSidebarGroup(.captureDate("2025", area: .trash), action: .select, editor: editor)
        XCTAssertEqual(model.selectedIDs, ["photo-0"])
        XCTAssertEqual(model.filter.area, .trash)
        XCTAssertNil(model.error); XCTAssertNil(model.failure)
    }

    @MainActor func testMissingAlbumCoverRegeneratesOutsideTheFilteredGrid() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let prepared = try CatalogImporter.prepare(original)
        let asset = try await store.insert(prepared.0, thumbnail: nil)
        try await store.createAlbum(name: "Offline cover", assetIDs: [asset.id])
        model.filter.search = "no matching photos"
        await model.refresh()
        XCTAssertTrue(model.assets.isEmpty)
        var cover: CatalogAlbumSummary?
        for _ in 0..<100 {
            cover = try await store.albums().first
            if cover?.thumbnailKey != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let key = try XCTUnwrap(cover?.thumbnailKey)
        let cachedPreview = try await store.previews.data(assetID: asset.id)
        XCTAssertNotNil(cachedPreview)
        try FileManager.default.removeItem(at: original)
        let reopened = try CatalogStore(root: store.root)
        let cachedCover = try await reopened.albums().first
        XCTAssertEqual(cachedCover?.thumbnailKey, key)
    }

    @MainActor func testClosingTheCatalogClearsItsAlbumsAndImports() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        await model.runImport([.init(url: original, locator: nil)], mode: .reference, store: store, job: UUID())
        try await store.createAlbum(name: "Trip", assetIDs: model.assets.map(\.id))
        await model.refresh()
        XCTAssertEqual(model.albums.count, 1); XCTAssertFalse(model.importDays.isEmpty)
        await model.closeCatalog(editor: editor)
        XCTAssertNil(model.store)
        XCTAssertTrue(model.albums.isEmpty); XCTAssertTrue(model.importDays.isEmpty); XCTAssertEqual(model.recentEditsCount, 0)
    }

    @MainActor func testImportsCreateBatchesAndCollectionsKeepTheirFilters() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let second = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: original, to: second)
        await model.runImport([.init(url: original, locator: nil), .init(url: second, locator: nil)], mode: .reference, store: store, job: UUID())
        let firstBatch = model.assets
        XCTAssertEqual(Set(firstBatch.compactMap(\.importBatchID)).count, 1)
        let third = directory.appendingPathComponent("third.jpg")
        try FileManager.default.copyItem(at: original, to: third)
        await model.runImport([.init(url: original, locator: nil), .init(url: third, locator: nil)], mode: .reference, store: store, job: UUID())
        // Each import switches the grid to its own batch.
        XCTAssertEqual(model.assets.count, 1); XCTAssertEqual(model.assets.first?.filename, "third.jpg")
        XCTAssertEqual(model.filter.importBatchID, model.assets.first?.importBatchID); XCTAssertNotEqual(model.filter.importBatchID, firstBatch[0].importBatchID)
        XCTAssertEqual(model.total, 3); XCTAssertEqual(model.importDays.first?.batches.count, 2)
        let album = try await store.createAlbum(name: "Trip", assetIDs: firstBatch.map(\.id))
        await model.refresh()
        await model.selectAsset(firstBatch[0]); model.metadata.title = "Pending title"
        await model.showAlbum(album.id); await model.refresh()
        XCTAssertEqual(model.collectionTitle, "Trip"); XCTAssertEqual(model.assets.count, 2)
        let saved = try await store.asset(firstBatch[0].id); XCTAssertEqual(saved.title, "Pending title")
        model.filter.search = "missing"; await model.refresh(); XCTAssertTrue(model.assets.isEmpty)
        model.clearFilters(); await model.refresh()
        XCTAssertEqual(model.filter.albumID, album.id); XCTAssertEqual(model.assets.count, 2)
        let day = try XCTUnwrap(model.importDays.first?.id)
        await model.showCatalogGroup(recentlyAdded: true, importDay: day, importBatchID: firstBatch[0].importBatchID)
        await model.refresh(); XCTAssertEqual(model.assets.count, 2)
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: firstBatch[0].id)
        await model.showCatalogGroup(recentEdits: true); await model.refresh()
        XCTAssertEqual(model.assets.map(\.id), [firstBatch[0].id]); XCTAssertEqual(model.filter.sort, .edited)
        XCTAssertEqual(model.collectionTitle, "Recent Edits")
        await model.showAlbum(album.id); await model.refresh()
        await model.deleteAlbum(album.id)
        XCTAssertNil(model.filter.albumID); XCTAssertEqual(model.assets.count, 3); XCTAssertNil(model.error); XCTAssertNil(model.failure)
    }

    @MainActor func testImportLeavesASearchOrFilteredViewAlone() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        await model.runImport([.init(url: original, locator: nil)], mode: .reference, store: store, job: UUID())
        await model.showCollection(trash: false)
        await model.selectAsset(try XCTUnwrap(model.assets.first))
        model.filter.search = "jpg"; await model.refresh()
        let searched = model.filter
        let second = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: original, to: second)
        await model.runImport([.init(url: second, locator: nil)], mode: .reference, store: store, job: UUID())
        // The search being typed, and the photo picked in it, stay; the new batch waits under Imports.
        XCTAssertEqual(model.filter, searched); XCTAssertNil(model.filter.importBatchID)
        XCTAssertNotNil(model.selected)
        XCTAssertEqual(model.importDays.first?.batches.count, 2)
    }

    @MainActor func testCollectionSidebarSnapshotWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional collection snapshot") }
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { model.stopIndexing(); try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        let photos = model.assets
        try await store.createAlbum(name: "Autumn in the mountains", assetIDs: photos.prefix(4).map(\.id))
        try await store.createAlbum(name: "Favourites", assetIDs: photos.suffix(2).map(\.id))
        try await store.createAlbum(name: "New album")
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: photos[0].id)
        let newURL = directory.appendingPathComponent("new-import.jpg")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: photos[0].sourcePath), to: newURL)
        await model.runImport([.init(url: newURL, locator: nil)], mode: .reference, store: store, job: UUID())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.sidebarWidth = 260
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        await model.showCatalogGroup(recentlyAdded: true, importDay: model.importDays.first?.id)
        try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-collections.png"))
    }
}
