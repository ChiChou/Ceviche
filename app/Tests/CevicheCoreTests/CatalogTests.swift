import XCTest
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import CevicheCore

final class CatalogTests: XCTestCase {
    func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photo.jpg")
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:10:23 12:13:14"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 46.5, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 11.3, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, url)
    }
    /// The grid's queries run on the browse and kind indexes without a sort step, which is what keeps paging
    /// fast in a large catalog; a year or month filter is a range on the day, not a LIKE.
    func testBrowsingQueriesUseTheIndexesWithoutSorting() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        _ = try await store.insert(prepared.0, thumbnail: nil)
        // Enough rows of three kinds, with statistics, for the planner to choose as it would in a real catalog.
        for index in 0..<60 {
            var copy = prepared.0; copy.id = "photo-\(index)"; copy.importPath += "-\(index)"; copy.kind = ["RAW", "JPG", "HIF"][index % 3]
            _ = try await store.insert(copy, thumbnail: nil)
        }
        let database = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await database.write { try $0.execute(sql: "ANALYZE") }
        func plan(_ filter: CatalogFilter) throws -> String {
            try database.read { db in
                let request = CatalogStore.query(filter).order(CatalogStore.ordering(filter))
                let statement = try request.makePreparedRequest(db, forSingleResult: false).statement
                return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments).map { $0["detail"] as String }.joined(separator: "\n")
            }
        }
        let indexes = try await database.read { try $0.indexes(on: "asset").map(\.name) }
        XCTAssertTrue(indexes.contains("asset_browse") && indexes.contains("asset_kind"), "\(indexes)")
        XCTAssertFalse(indexes.contains("asset_date") || indexes.contains("asset_trash_date") || indexes.contains("asset_on_kind"), "\(indexes)")
        var filter = CatalogFilter()
        let browse = try plan(filter)
        XCTAssertTrue(browse.contains("asset_browse"), browse); XCTAssertFalse(browse.contains("TEMP B-TREE"), browse)
        filter.captureDay = "2026-10"
        let month = try plan(filter)
        XCTAssertTrue(month.contains("asset_browse") && month.contains(">"), month); XCTAssertFalse(month.contains("TEMP B-TREE"), month)
        filter.captureDay = nil; filter.kind = "RAW"
        let kind = try plan(filter)
        XCTAssertTrue(kind.contains("asset_kind"), kind); XCTAssertFalse(kind.contains("TEMP B-TREE"), kind)
        // The month and year ranges match exactly the days inside them.
        var metadata = prepared.0.metadata
        for (id, day) in [("a", "2026-10-05"), ("b", "2026-11-01"), ("c", "2025-10-05")] {
            var copy = prepared.0; copy.id = id; copy.importPath += id; metadata.captureDay = day; copy.metadata = metadata
            _ = try await store.insert(copy, thumbnail: nil)
        }
        var october = CatalogFilter(); october.captureDay = "2026-10"
        let inOctober = try await store.assets(filter: october).map(\.id)
        XCTAssertEqual(inOctober, ["a"])
        var year = CatalogFilter(); year.captureDay = "2026"
        let inYear = try await store.assets(filter: year).map(\.id)
        XCTAssertEqual(Set(inYear), ["a", "b"])
    }
    func testImportReopenMetadataFiltersAndHistory() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: url)
        let root = directory.appendingPathComponent("Library")
        let store = try CatalogStore(root: root)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertEqual(asset.captureDay, "2025-10-23")
        XCTAssertEqual(asset.latitude, 46.5)
        XCTAssertEqual(asset.longitude, 11.3)
        XCTAssertNotNil(asset.thumbnailKey)
        var metadata = asset.metadata; metadata.rating = 5; metadata.review = .accepted; metadata.keywords = "Alps, 100% snow"; metadata.latitude = nil; metadata.longitude = nil
        try await store.updateMetadata(metadata, assetID: asset.id)
        var filter = CatalogFilter(); filter.minimumRating = 4; filter.review = .accepted; filter.search = "100% snow"; filter.captureDay = "2025-10-23"; filter.kind = "JPG"
        let matches = try await store.assets(filter: filter)
        XCTAssertEqual(matches.map(\.id), [asset.id])
        // "_" would match the middle "0" if it were a LIKE wildcard; as punctuation it separates "1" from "0".
        filter.search = "1_0"
        let escaped = try await store.assets(filter: filter)
        XCTAssertTrue(escaped.isEmpty, "SQL wildcard input must be literal")
        filter.search = "旅_"
        let unspaced = try await store.assets(filter: filter)
        XCTAssertTrue(unspaced.isEmpty, "Substring search of unspaced scripts escapes wildcards too")
        let reopened = try CatalogStore(root: root)
        let persisted = try await reopened.asset(asset.id)
        XCTAssertEqual(persisted.metadata, metadata)
        XCTAssertEqual(persisted.thumbnailKey, asset.thumbnailKey, "Metadata must not invalidate thumbnail")
        XCTAssertEqual(persisted.renderKey, asset.renderKey)
        let history = try await reopened.history(assetID: asset.id)
        XCTAssertEqual(history.count, 2)
        try await reopened.restore(history.last!)
        let restored = try await reopened.asset(asset.id)
        XCTAssertEqual(restored.rating, 0)
        XCTAssertEqual(restored.latitude, 46.5)
        let restoredHistory = try await reopened.history(assetID: asset.id)
        XCTAssertEqual(restoredHistory.count, 3, "Restore adds history instead of destroying it")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Catalog writes never change original bytes")
    }
    func testEditCommitSurvivesMissingThumbnailAndStaleCompletion() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        var first = Adjustments(); first.exposure = 1
        let oldKey = try await store.saveEdits(first, assetID: asset.id, baseline: Adjustments())
        var second = first; second.exposure = 2
        let currentKey = try await store.saveEdits(second, assetID: asset.id)
        try await store.installThumbnail(Data([7]), assetID: asset.id, renderKey: currentKey)
        let current = try await store.asset(asset.id)
        try await store.installThumbnail(Data([8]), assetID: asset.id, renderKey: oldKey)
        let afterStale = try await store.photo(asset.id)
        XCTAssertEqual(current.thumbnailKey, afterStale.thumbnailKey)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: afterStale.adjustmentsData!), second)
        let history = try await store.history(assetID: asset.id)
        XCTAssertEqual(history.filter { $0.kind == .edit }.count, 3)
        _ = try await store.saveEdits(second, assetID: asset.id)
        let unchanged = try await store.history(assetID: asset.id)
        XCTAssertEqual(unchanged.count, history.count)
        try await store.sweepPreviews()
        let kept = try await store.previews.data(assetID: asset.id), rows = try await store.previews.count()
        XCTAssertEqual(kept, Data([7]), "A sweep keeps the thumbnail of every photo that has one")
        XCTAssertEqual(rows, 1, "A replaced thumbnail overwrites the old one instead of adding a row")
    }
    func testAutosavesCoalesceIntoOneDescribedHistoryEntry() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments(), coalescing: true)
        edits.highlights = -30
        try await store.saveEdits(edits, assetID: asset.id, coalescing: true)
        edits.shadows = 20
        try await store.saveEdits(edits, assetID: asset.id, coalescing: true)
        var history = try await store.history(assetID: asset.id)
        XCTAssertEqual(Set(history.map(\.summary)), ["Imported metadata", "Exposure, Highlights, Shadows", "Original development"])
        let session = try XCTUnwrap(history.first { $0.summary.hasPrefix("Exposure") })
        let stored = try await store.adjustments(of: session)
        XCTAssertEqual(stored, edits)
        // An explicit save starts a new entry, and later autosaves never rewrite it.
        edits.whites = 10
        try await store.saveEdits(edits, assetID: asset.id)
        edits.blacks = -5
        try await store.saveEdits(edits, assetID: asset.id, coalescing: true)
        history = try await store.history(assetID: asset.id)
        XCTAssertEqual(Set(history.map(\.summary)), ["Imported metadata", "Blacks", "Whites", "Exposure, Highlights, Shadows", "Original development"])
    }
    func testConcurrentQuickMetadataKeepsEveryField() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        async let rated = store.updateQuickMetadata(assetIDs: [asset.id], rating: 3)
        async let reviewed = store.updateQuickMetadata(assetIDs: [asset.id], review: .accepted)
        _ = try await (rated, reviewed)
        let stored = try await store.asset(asset.id)
        XCTAssertEqual(stored.metadata.rating, 3)
        XCTAssertEqual(stored.metadata.review, .accepted)
        do { try await store.updateQuickMetadata(assetIDs: [asset.id], rating: 6); XCTFail("Invalid rating accepted") } catch {}
    }
    func testInvalidMetadataAndEditsDoNotReplaceState() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: nil)
        var bad = asset.metadata; bad.rating = 6
        do { try await store.updateMetadata(bad, assetID: asset.id); XCTFail("Invalid rating accepted") } catch {}
        bad = asset.metadata; bad.latitude = .nan
        do { try await store.updateMetadata(bad, assetID: asset.id); XCTFail("NaN location accepted") } catch {}
        bad = asset.metadata; bad.latitude = nil
        XCTAssertThrowsError(try bad.validated())
        bad = asset.metadata; bad.captureDay = "2026-02-30"
        XCTAssertThrowsError(try bad.validated())
        var edits = Adjustments(); edits.exposure = .infinity
        do { try await store.saveEdits(edits, assetID: asset.id); XCTFail("Invalid edits accepted") } catch {}
        let current = try await store.photo(asset.id)
        XCTAssertEqual(current.metadata, asset.metadata)
        XCTAssertNil(current.adjustmentsData)
        let history = try await store.history(assetID: asset.id)
        XCTAssertEqual(history.count, 1)
    }
    func testDuplicateImportRelinkAndMissingOriginalLegacyImport() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        let duplicate = try CatalogImporter.prepare(url)
        let second = try await store.insert(duplicate.0, thumbnail: duplicate.1)
        XCTAssertEqual(asset.id, second.id)
        let moved = directory.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: url, to: moved)
        try await store.relink(moved, assetID: asset.id)
        let relinked = try await store.asset(asset.id)
        XCTAssertEqual(relinked.sourcePath, moved.path)
        let wrong = directory.appendingPathComponent("wrong.jpg"); try Data([1, 2]).write(to: wrong)
        do { try await store.relink(wrong, assetID: asset.id); XCTFail("Different original accepted") } catch {}
    }
    func testNewerCatalogSchemaIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try CatalogStore(root: directory)
        let db = try DatabaseQueue(path: directory.appendingPathComponent("catalog.sqlite").path)
        try db.write { try $0.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('future-v2')") }
        XCTAssertThrowsError(try CatalogStore(root: directory))
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier = 'future-v2'") }
        XCTAssertEqual(count, 1)
    }
    func testBackupIsAnIndependentSnapshot() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        let prepared = try CatalogImporter.prepare(url)
        let migrated = try CatalogStore(root: root)
        let id = try await migrated.insert(prepared.0, thumbnail: prepared.1).id
        var metadata = try await migrated.asset(id).metadata; metadata.caption = "Preserve me in the backup"
        try await migrated.updateMetadata(metadata, assetID: id)
        let current = try await migrated.asset(id)
        XCTAssertEqual(current.caption, "Preserve me in the backup")
        XCTAssertEqual(current.locator, .file(path: url.path))
        XCTAssertEqual(current.captureTime, "2025-10-23T12:13:14", "Capture time comes from the EXIF")
        XCTAssertEqual(current.fileSize, Int64(try Data(contentsOf: url).count))
        let backupURL = directory.appendingPathComponent("Backup")
        try await migrated.backup(to: backupURL)
        let backup = try CatalogStore(root: backupURL)
        let copied = try await backup.asset(id)
        XCTAssertEqual(copied.metadata, current.metadata)
        let copiedThumbnail = try await backup.previews.data(assetID: id)
        XCTAssertEqual(copiedThumbnail, prepared.1)
        var later = current.metadata; later.rating = 2
        try await migrated.updateMetadata(later, assetID: id)
        let frozen = try await backup.asset(id)
        XCTAssertEqual(frozen.rating, 0, "Backup must remain an independent snapshot")
        do { try await migrated.backup(to: backupURL); XCTFail("Existing backup overwritten") } catch {}
    }
}
