import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogTrashTests: XCTestCase {
    func fixture() async throws -> (URL, URL, CatalogStore, CatalogAsset) {
        let (directory, image) = try CatalogTests().fixture()
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(image)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        return (directory, image, store, asset)
    }
    func testTrashRecoveryPersistsOriginalEditsHistoryAndFilters() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: original)
        var settings = Adjustments(); settings.exposure = 1.3; settings.hdr.enabled = true
        try await store.saveEdits(settings, assetID: asset.id)
        var metadata = asset.metadata; metadata.title = "Recover this"; metadata.rating = 4
        try await store.updateMetadata(metadata, assetID: asset.id)
        let before = try await store.asset(asset.id), history = try await store.history(assetID: asset.id)
        let beforeDevelopment = try await store.development(asset.id), photo = try await store.photo(asset.id)
        try await store.moveToTrash(asset.id)
        let active = try await store.assets(), groups = try await store.groups()
        XCTAssertTrue(active.isEmpty); XCTAssertEqual(groups.total, 0); XCTAssertEqual(groups.trash, 1); XCTAssertTrue(groups.dates.isEmpty)
        let reopened = try CatalogStore(root: store.root)
        var filter = CatalogFilter(); filter.area = .trash; filter.minimumRating = 4; filter.search = "Recover"
        let trashed = try await reopened.assets(filter: filter)
        XCTAssertEqual(trashed.map(\.id), [asset.id])
        let duplicate = try await reopened.insert(photo, thumbnail: nil)
        XCTAssertNotNil(duplicate.trashedAt)
        let backup = directory.appendingPathComponent("Backup")
        try await reopened.backup(to: backup)
        let backupStore = try CatalogStore(root: backup), backupGroups = try await backupStore.groups()
        XCTAssertEqual(backupGroups.trash, 1)
        try await reopened.recoverFromTrash(asset.id)
        let after = try await reopened.asset(asset.id), afterHistory = try await reopened.history(assetID: asset.id)
        XCTAssertNil(after.trashedAt); XCTAssertEqual(after.metadata, metadata)
        let afterDevelopment = try await reopened.development(asset.id)
        XCTAssertEqual(afterDevelopment, beforeDevelopment); XCTAssertEqual(after.thumbnailKey, before.thumbnailKey)
        XCTAssertEqual(afterHistory.map(\.id), history.map(\.id)); XCTAssertEqual(try Data(contentsOf: original), bytes)
        let found = try await reopened.assets(); XCTAssertEqual(found.count, 1)
    }
    /// A photo already gone (sync, another window) has nothing left to trash or recover; the rest of the batch goes.
    func testBatchTrashAndRecoverySkipAPhotoAlreadyGone() async throws {
        let (directory, _, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.moveToTrash([asset.id, "missing", asset.id])
        let trashed = try await store.asset(asset.id)
        XCTAssertNotNil(trashed.trashedAt)
        try await store.recoverFromTrash([asset.id, "missing", asset.id])
        let recovered = try await store.asset(asset.id)
        XCTAssertNil(recovered.trashedAt)
        let plans = try await store.deletionPlans(for: ["missing", asset.id])
        XCTAssertEqual(plans.flatMap(\.entries).map(\.id), [asset.id])
    }
    /// Photos received without a file path don't share an original just because their paths are both empty.
    func testEmptySourcePathsAreNotOneOriginal() async throws {
        let (directory, image, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: image, to: copy)
        let prepared = try CatalogImporter.prepare(copy)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        try await store.database.write { db in
            try db.execute(sql: "UPDATE asset SET sourcePath = '' WHERE id IN (?, ?)", arguments: [asset.id, second.id])
        }
        let plan = try await store.deletionPlan(for: asset.id)
        XCTAssertEqual(plan.entries.map(\.id), [asset.id])
    }
    func testTrashCancelsClaimsAndRecoverRequeues() async throws {
        let (directory, _, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = CatalogImporter.analysisVersion
        let claim = try await store.claimAnalysis(owner: "old-worker", version: version)
        XCTAssertNotNil(claim)
        try await store.moveToTrash(asset.id)
        try await store.enqueueOutdatedAnalysis(version: version)
        try await store.enqueueAnalysis(assetID: asset.id, version: version)
        let job = try await store.analysisJob(assetID: asset.id); XCTAssertNil(job)
        let late = try await store.finishAnalysis(XCTUnwrap(claim), tags: "stale", version: version)
        XCTAssertFalse(late)
        try await store.recoverFromTrash(asset.id)
        let restored = try await store.analysisJob(assetID: asset.id); XCTAssertEqual(restored?.state, .pending)
    }
    func testPermanentPlanIncludesSharedReferencesAndRemovesOnlyOriginalAndCatalogData() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("photo.xmp"); try Data("sidecar".utf8).write(to: sibling)
        let document = directory.appendingPathComponent("edit.ceviche"); try Data("document".utf8).write(to: document)
        var shared = try await store.photo(asset.id); shared.id = UUID().uuidString; shared.importPath = document.path
        _ = try await store.insert(shared, thumbnail: nil)
        try await store.moveToTrash(asset.id)
        let plan = try await store.deletionPlan(for: asset.id)
        XCTAssertEqual(Set(plan.entries.map(\.id)), [asset.id, shared.id])
        XCTAssertEqual(plan.entries.filter(\.inTrash).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Preparing confirmation must not unlink")
        try await store.deletePermanently(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        let groups = try await store.groups(), revisions = try await store.history(assetID: asset.id), job = try await store.analysisJob(assetID: asset.id)
        XCTAssertEqual(groups.total + groups.trash, 0); XCTAssertTrue(revisions.isEmpty); XCTAssertNil(job)
    }
    /// Copies the catalog made at import are its own to delete, sidecar included; a referenced file is not catalog-owned.
    func testCatalogOwnedCopiesDeleteWithTheirSidecar() async throws {
        let (directory, image) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(image, options: CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.root))
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertEqual(asset.locator.scheme, .catalog); XCTAssertTrue(asset.isCopy)
        let copied = CatalogImporter.sourceURL(for: asset, root: store.root)
        XCTAssertTrue(copied.path.hasPrefix(store.root.appendingPathComponent("Originals").path))
        let sidecar = copied.deletingPathExtension().appendingPathExtension("xmp"); try Data("sidecar".utf8).write(to: sidecar)
        try await store.moveToTrash(asset.id)
        let plan = try await store.deletionPlan(for: asset.id)
        XCTAssertTrue(plan.catalogOwned)
        try await store.deletePermanently(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "The file the copy was made from stays")
        let groups = try await store.groups(); XCTAssertEqual(groups.total + groups.trash, 0)
        let referenced = try CatalogImporter.prepare(image)
        let reference = try await store.insert(referenced.0, thumbnail: referenced.1)
        XCTAssertEqual(reference.locator.scheme, .file); XCTAssertFalse(reference.isCopy)
        let referencePlan = try await store.deletionPlan(for: reference.id)
        XCTAssertFalse(referencePlan.catalogOwned)
    }
    func testChangedFileOrReferencesRequireNewConfirmation() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plan = try await store.deletionPlan(for: asset.id)
        var shared = asset.asPhoto; shared.id = UUID().uuidString; shared.importPath += ".ceviche"
        _ = try await store.insert(shared, thumbnail: nil)
        do { try await store.deletePermanently(plan); XCTFail("Stale reference list accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let refreshed = try await store.deletionPlan(for: asset.id)
        try Data("replacement".utf8).write(to: original)
        do { try await store.deletePermanently(refreshed); XCTFail("Changed original deleted") } catch {}
        XCTAssertEqual(try Data(contentsOf: original), Data("replacement".utf8))
        let retained = try await store.asset(asset.id); XCTAssertEqual(retained.id, asset.id)
    }
    func testDeleteFailureKeepsRecordsAndMissingFileCanBeRemoved() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.moveToTrash(asset.id)
        let plan = try await store.deletionPlan(for: asset.id)
        do {
            try await store.deletePermanently(plan, removeOriginal: { _ in throw CocoaError(.fileWriteNoPermission) })
            XCTFail("Unlink failure ignored")
        } catch {}
        let retained = try await store.asset(asset.id), revisions = try await store.history(assetID: asset.id)
        XCTAssertNotNil(retained.trashedAt); XCTAssertFalse(revisions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        let missing = try await store.deletionPlan(for: asset.id)
        // A new file appearing at that path must not be deleted by a missing-file confirmation.
        try Data("new file".utf8).write(to: original)
        do { try await store.deletePermanently(missing); XCTFail("New file accepted") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        let missingAgain = try await store.deletionPlan(for: asset.id)
        try await store.deletePermanently(missingAgain)
        let groups = try await store.groups(); XCTAssertEqual(groups.trash, 0)
    }
    func testCatalogCommitFailureAfterUnlinkReportsRecoverableCleanup() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.moveToTrash(asset.id)
        let plan = try await store.deletionPlan(for: asset.id)
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_deletion BEFORE DELETE ON asset BEGIN SELECT RAISE(ABORT, 'simulated commit failure'); END") }
        do { try await store.deletePermanently(plan); XCTFail("Database failure ignored") }
        catch { XCTAssertTrue(error.localizedDescription.contains("original was deleted")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let retained = try await store.asset(asset.id); XCTAssertNotNil(retained.trashedAt)
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_deletion") }
        let retry = try await store.deletionPlan(for: asset.id)
        try await store.deletePermanently(retry)
        let groups = try await store.groups(); XCTAssertEqual(groups.trash, 0)
    }
    func testRemoveFromCatalogKeepsReferencedOriginalAndDeletesOwnedCopy() async throws {
        let (directory, original, store, referenced) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("second.jpg"); try FileManager.default.copyItem(at: original, to: second)
        let copied = try CatalogImporter.prepare(second, options: .init(mode: .copy, catalogRoot: store.root))
        let owned = try await store.insert(copied.0, thumbnail: copied.1)
        XCTAssertEqual(owned.locator.scheme, .catalog)
        let copyURL = CatalogImporter.sourceURL(for: owned, root: store.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        try await store.saveEdits(Adjustments(), assetID: referenced.id)
        try await store.moveToTrash(owned.id)
        let plan = try await store.removalPlan(for: [referenced.id, owned.id, referenced.id])
        XCTAssertEqual(plan.entries.map(\.id), [referenced.id, owned.id])
        XCTAssertEqual(plan.references.map(\.id), [referenced.id]); XCTAssertEqual(plan.copies.map(\.id), [owned.id])
        XCTAssertTrue(plan.copies[0].inTrash); XCTAssertFalse(plan.references[0].inTrash)
        let deleted = try await store.removeFromCatalog(plan)
        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Referenced originals are never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path), "The catalog's own copy goes with its record")
        let groups = try await store.groups()
        XCTAssertEqual(groups.total, 0); XCTAssertEqual(groups.trash, 0)
        do { _ = try await store.asset(referenced.id); XCTFail("Record survived removal") } catch {}
        let tombstones = try await store.database.read { try CatalogSyncTombstone.fetchAll($0) }.map(\.id)
        XCTAssertEqual(Set(tombstones), [referenced.id, owned.id])
        let again = try await store.removalPlan(for: [owned.id])
        XCTAssertTrue(again.entries.isEmpty, "A photo already gone has nothing left to remove")
    }
    func testRemovalKeepsCatalogCopyAnotherPhotoStillUses() async throws {
        let (directory, _, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shared.jpg")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("photo.jpg"), to: image)
        let copied = try CatalogImporter.prepare(image, options: .init(mode: .copy, catalogRoot: store.root))
        let first = try await store.insert(copied.0, thumbnail: copied.1)
        var draft = copied.0; draft.id = UUID().uuidString; draft.importPath += "#twin"; let twin = draft
        let second = try await store.database.write { db in
            try twin.asset.insert(db); try twin.exif.insert(db); try twin.development.insert(db); return twin.asset
        }
        let copyURL = CatalogImporter.sourceURL(for: first, root: store.root)
        try await store.removeFromCatalog(try await store.removalPlan(for: [first.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path), "Another record still points at the copy")
        try await store.removeFromCatalog(try await store.removalPlan(for: [second.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
    }
    func testRemovedPhotosStayRecognizedForThirtyDays() async throws {
        let (directory, original, store, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fingerprint = try CatalogImporter.fingerprint(original), locator = AssetLocator.describing(original)
        var presence = try await store.presence()
        XCTAssertTrue(presence.contains(fingerprint, locator: locator)); XCTAssertFalse(presence.wasDeleted(fingerprint, locator: locator))
        try await store.removeFromCatalog(try await store.removalPlan(for: [asset.id]))
        presence = try await store.presence()
        XCTAssertFalse(presence.contains(fingerprint, locator: locator), "Quick import may bring it back")
        XCTAssertTrue(presence.wasDeleted(fingerprint, locator: locator))
        let renamed = ImportFingerprint(name: original.lastPathComponent, size: fingerprint.size, captureTime: nil)
        XCTAssertTrue(presence.wasDeleted(renamed), "Name and size are enough, as for photos still in the catalog")
        let scanned = try ImportScanner.candidate(original, folder: "", presence: presence)
        XCTAssertFalse(scanned.present); XCTAssertTrue(scanned.recentlyDeleted)
        let later = try await store.presence(now: Date().addingTimeInterval(CatalogStore.deletedImportRetention + 60))
        XCTAssertFalse(later.wasDeleted(fingerprint, locator: locator), "The record expires")
        let reimported = try await store.insert(try CatalogImporter.prepare(original).0, thumbnail: nil)
        let scannedAgain = try ImportScanner.candidate(original, folder: "", presence: try await store.presence())
        XCTAssertTrue(scannedAgain.present); XCTAssertFalse(scannedAgain.recentlyDeleted, "Back in the catalog wins")
        let plan = try await store.deletionPlan(for: reimported.id)
        try await store.deletePermanently(plan, removeOriginal: { _ in })
        let count = try await store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM deletedImport") }
        XCTAssertEqual(count, 2, "Permanent deletion is remembered too")
    }
    func testRelinkedCopyBecomesAReference() async throws {
        let (directory, _, store, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("shared.jpg")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("photo.jpg"), to: image)
        let copied = try CatalogImporter.prepare(image, options: .init(mode: .copy, catalogRoot: store.root))
        let asset = try await store.insert(copied.0, thumbnail: copied.1)
        XCTAssertTrue(asset.isCopy)
        try await store.relink(image, assetID: asset.id)
        let relinked = try await store.asset(asset.id); XCTAssertFalse(relinked.isCopy)
        let plan = try await store.deletionPlan(for: asset.id); XCTAssertFalse(plan.catalogOwned)
    }
}
