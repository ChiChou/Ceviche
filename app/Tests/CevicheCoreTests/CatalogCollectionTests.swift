import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogCollectionTests: XCTestCase {
    func testAlbumsPersistMembershipAndUseFirstActivePhotosLocalCache() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        let store = try CatalogStore(root: root)
        let prepared = try CatalogImporter.prepare(url)
        let first = try await store.insert(prepared.0, thumbnail: prepared.1)
        var next = prepared.0; next.id = UUID().uuidString; next.importPath += "-second"
        let second = try await store.insert(next, thumbnail: prepared.1)
        let album = try await store.createAlbum(name: "  Trip  ", assetIDs: [first.id, second.id, first.id])
        try await store.addToAlbum(album.id, assetIDs: [second.id, first.id])
        try await store.renameAlbum(album.id, to: "Holiday")
        let reopened = try CatalogStore(root: root)
        var summary = try await reopened.albums()[0]
        XCTAssertEqual(summary.album.name, "Holiday"); XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.coverAssetID, first.id); XCTAssertEqual(summary.thumbnailKey, first.thumbnailKey)
        var filter = CatalogFilter(); filter.albumID = album.id
        let count = try await reopened.count(filter: filter); XCTAssertEqual(count, 2)
        filter.search = "missing"
        let filtered = try await reopened.assets(filter: filter); XCTAssertTrue(filtered.isEmpty)
        // Cache is durable, shared with the photo and independent of availability of its original.
        try FileManager.default.removeItem(at: url)
        try await reopened.sweepPreviews()
        let cachedPreview = try await reopened.previews.data(assetID: first.id)
        XCTAssertEqual(cachedPreview, prepared.1)
        try await reopened.installThumbnail(Data([1, 2, 3]), assetID: first.id, renderKey: first.renderKey)
        summary = try await reopened.albums()[0]
        XCTAssertNotEqual(summary.thumbnailKey, first.thumbnailKey)
        try await reopened.moveToTrash(first.id)
        summary = try await reopened.albums()[0]
        XCTAssertEqual(summary.count, 1); XCTAssertEqual(summary.coverAssetID, second.id)
        try await reopened.recoverFromTrash(first.id)
        summary = try await reopened.albums()[0]; XCTAssertEqual(summary.coverAssetID, first.id)
        try await reopened.removeFromAlbum(album.id, assetIDs: [first.id])
        summary = try await reopened.albums()[0]; XCTAssertEqual(summary.coverAssetID, second.id)
        let backup = directory.appendingPathComponent("Backup")
        try await reopened.backup(to: backup)
        let backupStore = try CatalogStore(root: backup)
        let backupAlbums = try await backupStore.albums(); XCTAssertEqual(backupAlbums, [summary])
        try await reopened.deleteAlbum(album.id)
        let remaining = try await reopened.assets(); XCTAssertEqual(remaining.count, 2)
        let albums = try await reopened.albums(); XCTAssertTrue(albums.isEmpty)
    }

    func testOverviewCountsActivePhotos() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let empty = try await store.overview()
        XCTAssertEqual(empty.photos, 0); XCTAssertNil(empty.firstDay)
        let prepared = try CatalogImporter.prepare(url)
        func add(_ suffix: String, day: String, kind: String, review: ReviewState = .unreviewed, edited: Bool = false) async throws -> CatalogAsset {
            var asset = prepared.0; asset.id = UUID().uuidString; asset.importPath += suffix
            asset.captureDay = day; asset.kind = kind; asset.review = review
            if edited { asset.lastEditedAt = Date() }
            return try await store.insert(asset, thumbnail: prepared.1)
        }
        _ = try await add("-a", day: "2019-03-02", kind: "RAW", review: .rejected)
        _ = try await add("-b", day: "2021-06-01", kind: "RAW", review: .accepted, edited: true)
        _ = try await add("-c", day: "2026-11-04", kind: "JPG")
        let trashed = try await add("-d", day: "2027-01-01", kind: "RAW", review: .accepted)
        try await store.moveToTrash(trashed.id)
        let overview = try await store.overview()
        XCTAssertEqual(overview.photos, 3); XCTAssertEqual(overview.raw, 2)
        XCTAssertEqual(overview.picked, 1); XCTAssertEqual(overview.rejected, 1); XCTAssertEqual(overview.edited, 1)
        XCTAssertEqual(overview.firstDay, "2019-03-02"); XCTAssertEqual(overview.lastDay, "2026-11-04")
    }

    func testTrashAlbumPhotosPreservesOtherMembershipsAndOriginals() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        let first = try await store.insert(prepared.0, thumbnail: prepared.1)
        var next = prepared.0; next.id = UUID().uuidString; next.importPath += "-second"
        let second = try await store.insert(next, thumbnail: prepared.1)
        let album = try await store.createAlbum(name: "Delete", assetIDs: [first.id, second.id])
        let other = try await store.createAlbum(name: "Keep", assetIDs: [first.id])
        // A stale plan must leave both the album and its photos untouched.
        do {
            try await store.trashPhotosAndDeleteAlbum(album.id, expectedPhotoIDs: [first.id])
            XCTFail("Accepted a stale album plan")
        } catch {}
        let active = try await store.assets(); XCTAssertEqual(active.count, 2)
        let before = try await store.albums(); XCTAssertEqual(before.count, 2)
        try await store.moveToTrash(second.id)
        let alreadyTrashed = try await store.asset(second.id).trashedAt
        let ids = try await store.activeAlbumPhotoIDs(album.id)
        XCTAssertEqual(ids, [first.id])
        try await store.trashPhotosAndDeleteAlbum(album.id, expectedPhotoIDs: ids)
        let remaining = try await store.albums()
        XCTAssertEqual(remaining.map(\.id), [other.id]); XCTAssertEqual(remaining.first?.count, 0)
        let firstAfter = try await store.asset(first.id)
        let secondAfter = try await store.asset(second.id)
        XCTAssertNotNil(firstAfter.trashedAt); XCTAssertEqual(secondAfter.trashedAt, alreadyTrashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try await store.recoverFromTrash(first.id)
        let recovered = try await store.albums()
        XCTAssertEqual(recovered.first?.count, 1)
        XCTAssertEqual(recovered.map(\.id), [other.id])
    }

    func testEditedSortKeepsUneditedPhotosLast() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        let plain = try await store.insert(prepared.0, thumbnail: nil)
        var next = prepared.0; next.id = UUID().uuidString; next.importPath += "-edited"
        let edited = try await store.insert(next, thumbnail: nil)
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: edited.id, baseline: Adjustments())
        var filter = CatalogFilter(); filter.sort = .edited
        for ascending in [false, true] {
            filter.ascending = ascending
            let order = try await store.assets(filter: filter).map(\.id)
            XCTAssertEqual(order, [edited.id, plain.id])
        }
    }

    func testImportDaysBatchesLegacyPhotosTrashAndPaginationAgree() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        let today = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        var inserted: [CatalogAsset] = []
        for index in 0..<5 {
            var asset = prepared.0; asset.id = "photo-\(index)"; asset.importPath += "-\(index)"
            asset.importedAt = today.addingTimeInterval(Double(index))
            asset.importBatchID = index == 4 ? nil : index < 3 ? "batch-1" : "batch-2"
            inserted.append(try await store.insert(asset, thumbnail: nil))
        }
        let groups = try await store.importGroups()
        XCTAssertEqual(groups.count, 3); XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 5)
        var filter = CatalogFilter(); filter.importDay = try XCTUnwrap(groups.first?.day); filter.importBatchID = "batch-1"
        let count = try await store.count(filter: filter), page = try await store.assets(filter: filter, limit: 2, offset: 2)
        XCTAssertEqual(count, 3); XCTAssertEqual(page.count, 1)
        try await store.moveToTrash(inserted[0].id)
        let activeGroups = try await store.importGroups(), activeCount = try await store.count(filter: filter)
        XCTAssertEqual(activeGroups.first { $0.batchID == "batch-1" }?.count, 2); XCTAssertEqual(activeCount, 2)
        filter.importBatchID = nil
        let dayCount = try await store.count(filter: filter); XCTAssertEqual(dayCount, 4)
        filter.importDay = "1900-01-01"
        let absent = try await store.count(filter: filter); XCTAssertEqual(absent, 0)
        let duplicate = try await store.insert(inserted[0].asPhoto, thumbnail: nil)
        XCTAssertEqual(duplicate.importBatchID, "batch-1")
    }

    func testLastEditClockExcludesCullingMetadataImportsAndCacheWrites() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var prepared = try CatalogImporter.prepare(url)
        prepared.0.adjustmentsData = try JSONEncoder().encode(Adjustments())
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertNil(asset.lastEditedAt)
        try await store.updateQuickMetadata(assetIDs: [asset.id], rating: 5, review: .accepted)
        var metadata = asset.metadata; metadata.title = "Changed metadata"
        try await store.updateMetadata(metadata, assetID: asset.id)
        var filter = CatalogFilter(); filter.recentEdits = true; filter.sort = .edited
        var count = try await store.count(filter: filter); XCTAssertEqual(count, 0)
        var edits = Adjustments(); edits.exposure = 1
        try await store.saveEdits(edits, assetID: asset.id)
        let edited = try await store.asset(asset.id), timestamp = try XCTUnwrap(edited.lastEditedAt)
        try await store.saveEdits(edits, assetID: asset.id) // no-op
        try await store.updateQuickMetadata(assetIDs: [asset.id], rating: 1, review: .rejected)
        try await store.installThumbnail(Data([7]), assetID: asset.id, renderKey: edited.renderKey)
        let culled = try await store.asset(asset.id); XCTAssertEqual(culled.lastEditedAt, timestamp)
        count = try await store.count(filter: filter); XCTAssertEqual(count, 1)
        // Browsing uses the column, even if history is absent.
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "DELETE FROM revision") }
        let reopened = try CatalogStore(root: store.root)
        let recent = try await reopened.assets(filter: filter); XCTAssertEqual(recent.map(\.id), [asset.id])
        try await reopened.moveToTrash(asset.id)
        count = try await reopened.count(filter: filter); XCTAssertEqual(count, 0)
        try await reopened.recoverFromTrash(asset.id)
        let recovered = try await reopened.asset(asset.id); XCTAssertEqual(recovered.lastEditedAt, timestamp)
    }

    /// Typing and dragging a range are throttled; a click on anything else queries at once.
    func testOnlyTypedAndDraggedChangesAreThrottled() {
        let base = CatalogFilter()
        var typed = base; typed.search = "sea"
        XCTAssertTrue(typed.changesContinuously(from: base))
        var dragged = base; dragged.iso = 100...800
        XCTAssertTrue(dragged.changesContinuously(from: base))
        var clicked = base; clicked.kind = "RAW"
        XCTAssertFalse(clicked.changesContinuously(from: base))
        var both = typed; both.kind = "RAW"
        XCTAssertFalse(both.changesContinuously(from: base), "A click along with typing refreshes at once")
        XCTAssertFalse(base.changesContinuously(from: base))
    }
}
