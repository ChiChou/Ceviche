import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

/// Two replicas of one iCloud catalog share a local mirror store, standing in for CloudKit.
final class CloudSyncTests: XCTestCase {
    func testOfflineEditsSurviveAndReachAnotherReplicaAfterReconnect() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        await syncA.networkChanged(connected: false)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.8
        try await a.saveEdits(edits, assetID: asset.id)
        _ = await syncA.sync()
        let offlineState = await syncA.state
        guard case .unavailable = offlineState else { return XCTFail("Local writes must not claim cloud success while offline") }
        let reopened = try CatalogStore(root: a.root)
        let persisted = try await reopened.asset(asset.id)
        let persistedEdits = try await reopened.savedAdjustments(of: persisted); XCTAssertEqual(persistedEdits?.exposure, 0.8)
        await syncA.networkChanged(connected: true)
        _ = await syncA.sync(); _ = await syncB.sync()
        let received = try await b.asset(asset.id)
        let receivedEdits = try await b.savedAdjustments(of: received); XCTAssertEqual(receivedEdits?.exposure, 0.8)
        await syncA.stop(); await syncB.stop()
    }
    func testCloudFailureIsNotClearedBySuccessfulLocalMirrorWrite() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (_, _, engine, _) = try replicas(directory)
        await engine.recordCloudEvent(id: UUID(), finished: true, succeeded: false, exported: true, issue: "Connection lost")
        _ = await engine.sync()
        let failed = await engine.state
        guard case .unavailable(let reason) = failed else { return XCTFail("The cloud failure must remain visible") }
        XCTAssertTrue(reason.contains("Connection lost"))
        await engine.recordCloudEvent(id: UUID(), finished: true, succeeded: true, exported: true, issue: nil)
        let recovered = await engine.state
        XCTAssertTrue(recovered.isHealthy)
        await engine.stop()
    }
    func testRenameReachesTheOtherMacAndTheDirectory() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        _ = await syncA.sync(); _ = await syncB.sync()
        let catalogs = try CloudCatalogDirectory(mirrorURL: directory.appendingPathComponent("mirror.store"), cloudContainer: nil)
        let renamedAt = Date()
        try a.rename(to: "Travel", at: renamedAt)
        try catalogs.rename(a.manifest.id, to: "Travel", at: renamedAt)
        _ = await syncA.sync()
        let arrived = await syncB.sync(); XCTAssertTrue(arrived)
        XCTAssertEqual(b.manifest.name, "Travel")
        XCTAssertEqual(try CatalogManifest.load(root: b.root)?.name, "Travel", "The name is saved in the replica's manifest")
        XCTAssertEqual(try catalogs.catalogs().map(\.name), ["Travel"])
        // A later rename on the other Mac wins over the earlier one.
        try b.rename(to: "Trips", at: renamedAt.addingTimeInterval(5))
        _ = await syncB.sync(); _ = await syncA.sync()
        XCTAssertEqual(a.manifest.name, "Trips")
        XCTAssertEqual(try catalogs.catalogs().map(\.name), ["Trips"])
        await syncA.stop(); await syncB.stop()
    }
    func testDeletedCatalogLeavesTheMirrorAndStopsTheOtherMac() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        _ = try await a.createAlbum(name: "Favourites", assetIDs: [asset.id])
        _ = await syncA.sync(); _ = await syncB.sync()
        let catalogs = try CloudCatalogDirectory(mirrorURL: directory.appendingPathComponent("mirror.store"), cloudContainer: nil)
        XCTAssertEqual(try catalogs.catalogs().map(\.id), [a.manifest.id])
        try catalogs.delete(a.manifest.id)
        XCTAssertTrue(try catalogs.catalogs().isEmpty)
        XCTAssertEqual(try catalogs.deletedCatalogIDs(), [a.manifest.id])
        let mirrored = try await syncB.mirroredAssetIDs(); XCTAssertTrue(mirrored.isEmpty)
        // The Mac that still has it open stops instead of uploading it again, even after more edits.
        var edits = Adjustments(); edits.exposure = 1
        try await b.saveEdits(edits, assetID: asset.id)
        _ = await syncB.sync()
        let state = await syncB.state; XCTAssertEqual(state, .removed)
        let afterEdit = try await syncB.mirroredAssetIDs(); XCTAssertTrue(afterEdit.isEmpty)
        XCTAssertTrue(try catalogs.catalogs().isEmpty, "The catalog does not come back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Originals are never touched")
        await syncA.stop(); await syncB.stop()
    }
    func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("photo.jpg")
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:10:23 12:13:14"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, url)
    }
    func replicas(_ directory: URL) throws -> (CatalogStore, CatalogStore, CloudSyncEngine, CloudSyncEngine) {
        let manifest = CatalogManifest(name: "Shared", kind: .cloud)
        let a = try CatalogStore(root: directory.appendingPathComponent("MacA"), manifest: manifest)
        let b = try CatalogStore(root: directory.appendingPathComponent("MacB"), manifest: manifest)
        XCTAssertEqual(a.manifest.id, b.manifest.id)
        let mirror = directory.appendingPathComponent("mirror.store")
        return (a, b, try CloudSyncEngine(store: a, mirrorURL: mirror, cloudContainer: nil), try CloudSyncEngine(store: b, mirrorURL: mirror, cloudContainer: nil))
    }
    func testEditsMetadataAndSnapshotsReachTheOtherMacAndOriginalsStayPutAsOffline() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.5
        try await a.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        try await a.createSnapshot(name: "Warm", adjustments: edits, thumbnail: nil, assetID: asset.id)
        let firstPass = await syncA.sync(); XCTAssertFalse(firstPass, "Pushing changes nothing on this Mac")
        let mirrored = try await syncA.mirroredAssetIDs(); XCTAssertEqual(mirrored, [asset.id])
        let state = await syncA.state
        if case .unavailable = state { XCTFail("A local mirror is always available") }
        let pulled = await syncB.sync(); XCTAssertTrue(pulled)
        let copy = try await b.asset(asset.id)
        let originalEdit = try await a.asset(asset.id).lastEditedAt
        XCTAssertNotNil(originalEdit); XCTAssertEqual(copy.lastEditedAt, originalEdit)
        XCTAssertEqual(copy.filename, "photo.jpg"); XCTAssertEqual(copy.captureDay, "2025-10-23")
        let copyEdits = try await b.savedAdjustments(of: copy); XCTAssertEqual(copyEdits?.exposure, 0.5)
        XCTAssertEqual(copy.locator, asset.locator, "The origin travels; the file does not")
        XCTAssertNotNil(copy.thumbnailKey, "The preview syncs with the photo")
        XCTAssertNil(copy.thumbnailRenderKey, "The camera preview of an edited photo stays marked to update when it is opened")
        let bSnapshots = try await b.snapshots(assetID: asset.id); XCTAssertEqual(bSnapshots.map(\.name), ["Warm"])
        let bHistory = try await b.history(assetID: asset.id); XCTAssertEqual(bHistory.filter { $0.kind == .edit }.count, 1, "History is per Mac")
        // Mac B rates the photo; Mac A sees it without losing its own state.
        try await b.updateQuickMetadata(assetIDs: [asset.id], rating: 4)
        _ = await syncB.sync(); let ratingArrived = await syncA.sync(); XCTAssertTrue(ratingArrived)
        let aRated = try await a.asset(asset.id)
        XCTAssertEqual(aRated.rating, 4)
        XCTAssertEqual(aRated.lastEditedAt, originalEdit)
        let aRatedEdits = try await a.savedAdjustments(of: aRated); XCTAssertEqual(aRatedEdits?.exposure, 0.5)
        // A later edit on A wins over an older state on B.
        var newer = edits; newer.exposure = 1.2
        try await a.saveEdits(newer, assetID: asset.id)
        _ = await syncA.sync(); let editArrived = await syncB.sync(); XCTAssertTrue(editArrived)
        let bEdited = try await b.asset(asset.id); let bEdits = try await b.savedAdjustments(of: bEdited); XCTAssertEqual(bEdits?.exposure, 1.2)
        let bEditHistory = try await b.history(assetID: asset.id)
        XCTAssertTrue(bEditHistory.contains { $0.summary == "Received from iCloud" && $0.milestone })
        // Snapshot deleted on B disappears on A.
        let snapshot = try await b.snapshots(assetID: asset.id)[0]
        try await b.deleteSnapshot(snapshot.id)
        _ = await syncB.sync(); _ = await syncA.sync()
        let aSnapshots = try await a.snapshots(assetID: asset.id); XCTAssertTrue(aSnapshots.isEmpty)
    }
    func testMaskDataTravelsAsBlobsAndRowsWaitForTheirBlobs() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.4
        var mask = PhotoMask(kind: .subject); mask.raster = Data((0..<60_000).map { UInt8($0 % 241) }); edits.masks = [mask]
        try await a.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        try await a.createSnapshot(name: "Masked", adjustments: edits, thumbnail: nil, assetID: asset.id)
        _ = await syncA.sync()
        let pulled = await syncB.sync(); XCTAssertTrue(pulled)
        let copy = try await b.asset(asset.id)
        let received = try await b.savedAdjustments(of: copy)
        XCTAssertEqual(received, edits)
        let copyDevelopment = try await b.development(asset.id)
        XCTAssertLessThan(try XCTUnwrap(copyDevelopment.adjustmentsData).count, 5_000, "The synced row carries a reference, not the raster")
        let snapshot = try await b.snapshots(assetID: asset.id)[0]
        let restored = try await b.adjustments(of: snapshot)
        XCTAssertEqual(restored, edits)
        // A row that names a blob this Mac has not received is held back, then applied once the blob is there.
        let pushed = try await a.syncDevelopments([asset.id])
        var newer = try XCTUnwrap(pushed.first)
        var later = edits; later.masks[0].raster = Data(repeating: 3, count: 50_000)
        let blobID = UUID().uuidString
        let encoder = JSONEncoder(); encoder.dataEncodingStrategy = .custom { _, encoder in var c = encoder.singleValueContainer(); try c.encode("@blob:" + blobID) }
        newer.adjustmentsData = try encoder.encode(later); newer.updatedAt = Date().addingTimeInterval(60)
        let early = try await b.applyRemote(CatalogSyncPhoto(assetID: asset.id, development: newer)); XCTAssertFalse(early)
        let unchanged = try await b.savedAdjustments(of: b.asset(asset.id)); XCTAssertEqual(unchanged, edits)
        let applied = try await b.applyRemote(CatalogSyncPhoto(assetID: asset.id, development: newer), blobs: [blobID: later.masks[0].raster!]); XCTAssertTrue(applied)
        let arrived = try await b.savedAdjustments(of: b.asset(asset.id)); XCTAssertEqual(arrived, later)
        await syncA.stop(); await syncB.stop()
    }
    func testMirrorBlobsFollowTheirPhotoAndDevelopmentsWaitForTheLibrary() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        // Each Mac's iCloud Drive folder; B's copy has not downloaded A's files yet.
        let driveA = directory.appendingPathComponent("DriveA", isDirectory: true), driveB = directory.appendingPathComponent("DriveB", isDirectory: true)
        let manifest = CatalogManifest(name: "Shared", kind: .cloud)
        let a = try CatalogStore(root: directory.appendingPathComponent("MacA"), manifest: manifest, resources: .folder(FolderResources(root: driveA)))
        let b = try CatalogStore(root: directory.appendingPathComponent("MacB"), manifest: manifest, resources: .folder(FolderResources(root: driveB)))
        let mirror = directory.appendingPathComponent("mirror.store")
        let syncA = try CloudSyncEngine(store: a, mirrorURL: mirror, cloudContainer: nil), syncB = try CloudSyncEngine(store: b, mirrorURL: mirror, cloudContainer: nil)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.4
        var mask = PhotoMask(kind: .sky); mask.raster = Data((0..<40_000).map { UInt8($0 % 239) }); edits.masks = [mask]
        edits.lut = CreativeLUT(name: "Teal", dimension: 2, rgb: [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1])
        try await a.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        _ = await syncA.sync()
        let firstBlobs = try await syncA.mirroredBlobIDs()
        XCTAssertEqual(firstBlobs.count, 1)
        _ = await syncB.sync()
        // The LUT has not reached Mac B: the photo is there, its development waits.
        let waiting = try await b.asset(asset.id)
        let undeveloped = try await b.savedAdjustments(of: waiting); XCTAssertNil(undeveloped)
        // iCloud Drive delivers the file; the next pass applies the photo.
        try FileManager.default.copyItem(at: driveA, to: driveB)
        let arrived = await syncB.sync(); XCTAssertTrue(arrived)
        let received = try await b.savedAdjustments(of: b.asset(asset.id))
        XCTAssertEqual(received?.lut?.samples, edits.lut?.samples); XCTAssertEqual(received?.masks, edits.masks)
        // A new raster replaces the old one in the mirror as soon as A pushes it.
        var regenerated = edits; regenerated.masks[0].raster = Data(repeating: 5, count: 20_000)
        try await a.saveEdits(regenerated, assetID: asset.id)
        _ = await syncA.sync()
        let latest = try await a.development(asset.id)
        let current = try RevisionPayload.references(XCTUnwrap(latest.adjustmentsData))
        let mirrored = try await syncA.mirroredBlobIDs()
        XCTAssertEqual(mirrored, current)
        XCTAssertTrue(mirrored.isDisjoint(with: firstBlobs))
        // Deleting the photo takes its blobs out of the mirror.
        let plan = try await a.deletionPlan(for: asset.id)
        try await a.deletePermanently(plan, removeOriginal: { _ in })
        _ = await syncA.sync()
        let afterDeletion = try await syncA.mirroredBlobIDs()
        XCTAssertTrue(afterDeletion.isEmpty)
        await syncA.stop(); await syncB.stop()
    }
    func testCopiedOriginalsAndPreviewsReachTheOtherMac() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        // The catalog's originals folder in iCloud Drive, which both Macs see.
        let drive = directory.appendingPathComponent("Drive/Catalogs/Shared", isDirectory: true)
        let manifest = CatalogManifest(name: "Shared", kind: .cloud)
        let a = try CatalogStore(root: directory.appendingPathComponent("MacA"), manifest: manifest, originals: drive)
        let b = try CatalogStore(root: directory.appendingPathComponent("MacB"), manifest: manifest, originals: drive)
        XCTAssertEqual(a.originalsRoot, drive.standardizedFileURL)
        let mirror = directory.appendingPathComponent("mirror.store")
        let syncA = try CloudSyncEngine(store: a, mirrorURL: mirror, cloudContainer: nil), syncB = try CloudSyncEngine(store: b, mirrorURL: mirror, cloudContainer: nil)
        let prepared = try CatalogImporter.prepare(url, options: CatalogImporter.ImportOptions(mode: .copy, catalogRoot: a.originalsRoot))
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertEqual(asset.locator.scheme, .catalog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("Originals").path), "The copy is in the shared folder")
        _ = await syncA.sync(); _ = await syncB.sync()
        let copy = try await b.asset(asset.id)
        guard case .available(let opened) = copy.availability(catalog: b.root) else { return XCTFail("Mac B opens the copy from the shared folder") }
        XCTAssertEqual(try Data(contentsOf: opened), try Data(contentsOf: url))
        // The preview arrives with the photo, before any original is read on Mac B.
        let preview = try await b.previews.data(assetID: asset.id)
        XCTAssertEqual(preview, prepared.1)
        let withPreview = try await b.asset(asset.id); XCTAssertNotNil(withPreview.thumbnailKey)
        // A copy made before the catalog kept originals in iCloud Drive moves there, at the same path.
        let early = a.root.appendingPathComponent("Originals/2025-01/early.jpg")
        try FileManager.default.createDirectory(at: early.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: early)
        XCTAssertEqual(CatalogImporter.catalogCopyURL("Originals/2025-01/early.jpg", root: a.root), early, "Found where it is until it moves")
        XCTAssertEqual(try a.shareLocalOriginals(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("Originals/2025-01/early.jpg").path))
        XCTAssertEqual(CatalogImporter.catalogCopyURL("Originals/2025-01/early.jpg", root: b.root).standardizedFileURL,
                       drive.appendingPathComponent("Originals/2025-01/early.jpg").standardizedFileURL)
        await syncA.stop(); await syncB.stop()
    }
    func testCatalogCopiesAreFoundWhereTheyWereUntilTheyMove() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog"), current = directory.appendingPathComponent("Drive/Catalogs/X")
        CatalogImporter.setOriginalsRoot(current, for: root)
        let relative = "Originals/2025-01/A.ARW"
        XCTAssertEqual(CatalogImporter.catalogCopyURL(relative, root: root).path, current.appendingPathComponent(relative).standardizedFileURL.path, "A missing copy is expected in the current folder")
        let old = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: old)
        XCTAssertEqual(CatalogImporter.catalogCopyURL(relative, root: root).path, old.standardizedFileURL.path)
        let moved = current.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: moved)
        XCTAssertEqual(CatalogImporter.catalogCopyURL(relative, root: root).path, moved.standardizedFileURL.path)
        XCTAssertTrue(CatalogImporter.isDownloaded(moved), "A local file needs no download")
    }
    func testSuggestedTagsAreGeneratedOnceAndSync() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let asset = try await a.insert(CatalogImporter.prepare(url).0, thumbnail: nil)
        let version = CatalogImporter.analysisVersion
        let claimed = try await a.claimAnalysis(owner: "test", version: version)
        let claim = try XCTUnwrap(claimed)
        let finished = try await a.finishAnalysis(claim, tags: "mountain, sky", version: version); XCTAssertTrue(finished)
        _ = await syncA.sync(); _ = await syncB.sync()
        let copy = try await b.asset(asset.id)
        XCTAssertEqual(copy.suggestedTags, "mountain, sky"); XCTAssertEqual(copy.analysisVersion, version)
        let left = try await b.claimAnalysis(owner: "test", version: version)
        XCTAssertNil(left, "Mac B does not analyze the photo again")
        try await b.enqueueOutdatedAnalysis(version: "a-newer-model")
        let upgraded = try await b.claimAnalysis(owner: "test", version: "a-newer-model")
        XCTAssertNil(upgraded, "Another Mac's result stays the source of truth, whatever this Mac's analysis version")
        await syncA.stop(); await syncB.stop()
    }
    func testAlbumsAndTheirPhotosSync() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let first = try await a.insert(CatalogImporter.prepare(url).0, thumbnail: nil)
        let copy = directory.appendingPathComponent("second.jpg"); try FileManager.default.copyItem(at: url, to: copy)
        let second = try await a.insert(CatalogImporter.prepare(copy).0, thumbnail: nil)
        func photos(_ store: CatalogStore, _ album: String) async throws -> Set<String> {
            var filter = CatalogFilter(); filter.albumID = album
            return Set(try await store.assets(filter: filter).map(\.id))
        }
        let trip = try await a.createAlbum(name: "Trip", assetIDs: [first.id])
        _ = await syncA.sync(); _ = await syncB.sync()
        var bAlbums = try await b.albums()
        XCTAssertEqual(bAlbums.map(\.album.name), ["Trip"])
        var inTrip = try await photos(b, trip.id); XCTAssertEqual(inTrip, [first.id])
        // Mac A adds a photo while Mac B renames the album: both changes survive.
        try await a.addToAlbum(trip.id, assetIDs: [second.id])
        try await b.renameAlbum(trip.id, to: "Dolomites")
        _ = await syncA.sync(); _ = await syncB.sync(); _ = await syncA.sync()
        let aAlbums = try await a.albums(); XCTAssertEqual(aAlbums.map(\.album.name), ["Dolomites"])
        inTrip = try await photos(b, trip.id); XCTAssertEqual(inTrip, [first.id, second.id])
        // A photo removed on Mac B leaves the album on Mac A.
        try await b.removeFromAlbum(trip.id, assetIDs: [first.id])
        _ = await syncB.sync(); _ = await syncA.sync()
        inTrip = try await photos(a, trip.id); XCTAssertEqual(inTrip, [second.id])
        // Added back on Mac A after that, it is in the album again on both.
        try await a.addToAlbum(trip.id, assetIDs: [first.id])
        _ = await syncA.sync(); _ = await syncB.sync()
        inTrip = try await photos(b, trip.id); XCTAssertEqual(inTrip, [first.id, second.id])
        // Deleting the album on Mac A deletes it on Mac B; the photos stay.
        try await a.deleteAlbum(trip.id)
        _ = await syncA.sync(); _ = await syncB.sync()
        bAlbums = try await b.albums(); XCTAssertTrue(bAlbums.isEmpty)
        let bPhotos = try await b.assets(); XCTAssertEqual(bPhotos.count, 2)
        let remaining = try await a.tombstones(kind: "album"); XCTAssertTrue(remaining.isEmpty, "Sent deletions are cleared")
        await syncA.stop(); await syncB.stop()
    }
    /// Each mirror row and its sync part describe the same fields; a field added to one without the other fails here.
    func testMirrorRowsCarryEveryFieldOfTheirSyncPart() throws {
        let original = CatalogSyncOriginal(assetID: "asset", filename: "x.ARW", kind: "RAW", fileSize: 12, captureTime: "2026-10-24T10:00:00",
            infoData: Data("info".utf8), extractedMetadata: Data("meta".utf8), importedAt: Date(timeIntervalSince1970: 1), importBatchID: "batch",
            updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(SyncedOriginal(catalogID: "catalog", original: original).original, original)
        XCTAssertEqual(try fields(original), 10)
        var metadata = CatalogMetadata()
        metadata.title = "Title"; metadata.caption = "Caption"; metadata.keywords = "one, two"; metadata.rating = 3; metadata.review = .accepted; metadata.label = .green
        metadata.captureDay = "2026-10-24"; metadata.latitude = 1.5; metadata.longitude = -2.5
        let state = CatalogSyncState(assetID: "asset", origin: "file:///Photos/x.ARW", isCopy: true, metadata: metadata,
            trashedAt: Date(timeIntervalSince1970: 3), stackID: "stack", updatedAt: Date(timeIntervalSince1970: 4))
        let photo = SyncedPhoto(catalogID: "catalog", assetID: "asset"); photo.apply(state)
        XCTAssertEqual(photo.keywords, ["one", "two"], "Keywords sync as a list")
        XCTAssertEqual(photo.state, state)
        XCTAssertEqual(try fields(state), 7)
        let development = CatalogSyncDevelopment(assetID: "asset", adjustmentsData: Data("adjustments".utf8), xmpData: Data("xmp".utf8), xmpWarnings: "warning",
            renderKey: "render", lastEditedAt: Date(timeIntervalSince1970: 5), updatedAt: Date(timeIntervalSince1970: 6))
        XCTAssertEqual(SyncedDevelopment(catalogID: "catalog", development: development).development, development)
        XCTAssertEqual(try fields(development), 7)
    }
    private func fields(_ value: some Encodable) throws -> Int {
        (try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]).count
    }
    /// A rating made on one Mac and an edit made on another meanwhile both stay: each part of a photo has its own clock.
    func testRatingOnOneMacAndEditOnAnotherBothSurvive() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        _ = await syncA.sync(); _ = await syncB.sync()
        let before = try await a.syncClocks()[asset.id]
        _ = try await a.updateQuickMetadata(assetIDs: [asset.id], rating: 5)
        var edits = Adjustments(); edits.exposure = 0.6
        try await b.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        let afterEdit = try await b.syncClocks()[asset.id]
        XCTAssertEqual(afterEdit?.state, before?.state, "An edit leaves the photo's state clock alone")
        XCTAssertEqual(afterEdit?.original, before?.original)
        _ = await syncA.sync(); _ = await syncB.sync(); _ = await syncA.sync()
        for store in [a, b] {
            let photo = try await store.asset(asset.id), settings = try await store.savedAdjustments(of: photo)
            XCTAssertEqual(photo.rating, 5); XCTAssertEqual(settings?.exposure, 0.6)
        }
        await syncA.stop(); await syncB.stop()
    }
    func testAlbumsAndImportBatchesReachAnotherReplica() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        var draft = prepared.0; draft.importBatchID = "batch"
        let first = try await a.insert(draft, thumbnail: prepared.1)
        var next = prepared.0; next.id = UUID().uuidString; next.importPath += "-second"
        let second = try await a.insert(next, thumbnail: prepared.1)
        let album = try await a.createAlbum(name: "Trip", assetIDs: [second.id, first.id])
        _ = await syncA.sync(); _ = await syncB.sync()
        let received = try await b.asset(first.id); XCTAssertEqual(received.importBatchID, "batch")
        var albums = try await b.albums()
        XCTAssertEqual(albums.map(\.album.name), ["Trip"]); XCTAssertEqual(albums.first?.count, 2); XCTAssertEqual(albums.first?.coverAssetID, second.id)
        try await b.renameAlbum(album.id, to: "Holiday")
        try await b.removeFromAlbum(album.id, assetIDs: [second.id])
        _ = await syncB.sync(); let renamed = await syncA.sync(); XCTAssertTrue(renamed)
        albums = try await a.albums()
        XCTAssertEqual(albums.map(\.album.name), ["Holiday"]); XCTAssertEqual(albums.first?.coverAssetID, first.id)
        let settled = await syncA.sync(); XCTAssertFalse(settled, "An album already matching iCloud is not rewritten")
        try await a.deleteAlbum(album.id)
        _ = await syncA.sync(); let deleted = await syncB.sync(); XCTAssertTrue(deleted)
        albums = try await b.albums(); XCTAssertTrue(albums.isEmpty)
        let assets = try await b.assets(); XCTAssertEqual(assets.count, 2, "Deleting an album keeps its photos")
        let tombstones = try await a.tombstones(); XCTAssertTrue(tombstones.isEmpty)
    }
    /// Edits this Mac can't read stay in the mirror for a later build; the other photos still arrive, and the
    /// pass doesn't fail.
    func testOneUnreadableDevelopmentDoesNotStopSync() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let copy = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: url, to: copy)
        let first = try CatalogImporter.prepare(url), second = try CatalogImporter.prepare(copy)
        let bad = try await a.insert(first.0, thumbnail: first.1), good = try await a.insert(second.0, thumbnail: second.1)
        _ = await syncA.sync(); _ = await syncB.sync()
        var edits = Adjustments(); edits.exposure = 0.7
        try await a.saveEdits(edits, assetID: bad.id, baseline: Adjustments())
        try await a.saveEdits(edits, assetID: good.id, baseline: Adjustments())
        try await a.database.write { db in
            let stored = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT adjustmentsData FROM assetDevelopment WHERE assetID = ?", arguments: [bad.id]))
            var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any]); tree["temperature"] = 99_999
            try db.execute(sql: "UPDATE assetDevelopment SET adjustmentsData = ? WHERE assetID = ?", arguments: [JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]), bad.id])
        }
        _ = await syncA.sync(); _ = await syncB.sync()
        if case .failed(let message) = await syncB.state { XCTFail(message) }
        let arrived = try await b.savedAdjustments(of: b.asset(good.id))
        XCTAssertEqual(arrived?.exposure, 0.7)
    }
    func testTrashAndPermanentDeletionPropagate() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try replicas(directory)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await a.insert(prepared.0, thumbnail: prepared.1)
        _ = await syncA.sync(); _ = await syncB.sync()
        try await b.moveToTrash(asset.id)
        _ = await syncB.sync(); let trashArrived = await syncA.sync(); XCTAssertTrue(trashArrived)
        let aTrashed = try await a.asset(asset.id); XCTAssertNotNil(aTrashed.trashedAt)
        let plan = try await a.deletionPlan(for: asset.id)
        try await a.deletePermanently(plan, removeOriginal: { _ in })
        let tombstones = try await a.tombstones(); XCTAssertEqual(tombstones.map(\.id), [asset.id])
        _ = await syncA.sync()
        let remaining = try await a.tombstones(); XCTAssertTrue(remaining.isEmpty)
        let deletionArrived = await syncB.sync(); XCTAssertTrue(deletionArrived)
        do { _ = try await b.asset(asset.id); XCTFail("Deleted on A, still on B") } catch {}
        let mirrored = try await syncB.mirroredAssetIDs(); XCTAssertTrue(mirrored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The other Mac never touches originals")
        XCTAssertEqual(try CloudCatalogDirectory(mirrorURL: directory.appendingPathComponent("mirror.store"), cloudContainer: nil).catalogs().map(\.name), ["Shared"])
    }
}
