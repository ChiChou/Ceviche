import XCTest
import GRDB
@testable import CevicheCore

final class HistoryStorageTests: XCTestCase {
    private func store() async throws -> (URL, CatalogStore, CatalogAsset) {
        let (directory, url) = try CatalogTests().fixture()
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"))
        let prepared = try CatalogImporter.prepare(url)
        return (directory, store, try await store.insert(prepared.0, thumbnail: prepared.1))
    }
    private func masked(_ exposure: Double) -> Adjustments {
        var edits = Adjustments(); edits.exposure = exposure
        var mask = PhotoMask(kind: .subject); mask.raster = Data((0..<50_000).map { UInt8($0 % 251) })
        mask.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        edits.masks = [mask]
        return edits
    }
    private func count(_ table: String, _ directory: URL) async throws -> Int {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        return try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
    private func secondPhoto(_ directory: URL, store: CatalogStore) async throws -> CatalogAsset {
        let copy = directory.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("photo.jpg"), to: copy)
        let prepared = try CatalogImporter.prepare(copy)
        return try await store.insert(prepared.0, thumbnail: prepared.1)
    }
    private func lut(_ name: String) -> CreativeLUT {
        let n = 3
        var rgb: [Float] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n { rgb += [Float(r) / 2, Float(g) / 2 * 0.9, Float(b) / 2] } } }
        return CreativeLUT(name: name, dimension: n, rgb: rgb)
    }
    func testPayloadRoundTripsAndStoresEachRasterOnce() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        for exposure in [0.5, 1.0, 1.5] { try await store.saveEdits(masked(exposure), assetID: asset.id, baseline: Adjustments()) }
        let history = try await store.history(assetID: asset.id).filter { $0.kind == .edit }
        XCTAssertEqual(history.count, 4)
        for entry in history where entry.summary != "Original development" {
            XCTAssertLessThan(entry.payload.count, 5_000, "The raster lives in the blob table, not in every step")
        }
        let newest = try await store.adjustments(of: history[0])
        XCTAssertEqual(newest, masked(1.5))
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        let blobs = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blob") }
        XCTAssertEqual(blobs, 1)
    }
    func testStoredDevelopmentsReferToBlobsInsteadOfHoldingData() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.saveEdits(masked(0.5), assetID: asset.id, baseline: Adjustments())
        try await store.createSnapshot(name: "Masked", adjustments: masked(0.5), thumbnail: nil, assetID: asset.id)
        let saved = try await store.asset(asset.id)
        let development = try await store.development(asset.id)
        let stored = try XCTUnwrap(development.adjustmentsData)
        XCTAssertLessThan(stored.count, 5_000, "The raster is not inline")
        let references = try RevisionPayload.references(stored)
        XCTAssertEqual(references.count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(references.first)), "Blob IDs are UUIDs")
        let snapshot = try await store.snapshots(assetID: asset.id)[0]
        XCTAssertEqual(try RevisionPayload.references(snapshot.payload), references, "The snapshot shares the photo's blob")
        let resolved = try await store.savedAdjustments(of: saved)
        XCTAssertEqual(resolved, masked(0.5))
        // A new raster is a new blob; the old one stays while History or a Snapshot needs it.
        var changed = masked(0.5); changed.masks[0].raster = Data(repeating: 7, count: 40_000)
        try await store.saveEdits(changed, assetID: asset.id)
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        var blobs = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blob") }
        XCTAssertEqual(blobs, 2)
        try await store.deleteSnapshot(snapshot.id)
        blobs = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blob") }
        XCTAssertEqual(blobs, 2, "History still holds the first raster")
        _ = try await store.compactHistory(assetID: asset.id, now: Date().addingTimeInterval(30 * 86400))
        blobs = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM blob") }
        XCTAssertEqual(blobs, 1, "Folding History frees the raster nothing refers to; the photo's own stays")
        let latest = try await store.savedAdjustments(of: store.asset(asset.id))
        XCTAssertEqual(latest, changed)
    }
    func testAStaleRasterGoesAtOnceAndEachPhotoOwnsItsBlobs() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.saveEdits(masked(0.5), assetID: asset.id, baseline: Adjustments())
        // Regenerating the mask soon after continues the same step, so nothing holds the first raster any more.
        var regenerated = masked(0.5); regenerated.masks[0].raster = Data(repeating: 9, count: 30_000)
        try await store.saveEdits(regenerated, assetID: asset.id, coalescing: true)
        var blobs = try await count("blob", directory)
        XCTAssertEqual(blobs, 1, "The replaced raster is deleted in the same save")
        // The same raster pasted onto another photo is that photo's own copy.
        let second = try await secondPhoto(directory, store: store)
        try await store.saveEdits(regenerated, assetID: second.id, baseline: Adjustments())
        blobs = try await count("blob", directory)
        XCTAssertEqual(blobs, 2)
        let firstStored = try await store.development(asset.id).adjustmentsData, secondStored = try await store.development(second.id).adjustmentsData
        XCTAssertTrue(try RevisionPayload.references(XCTUnwrap(firstStored)).isDisjoint(with: RevisionPayload.references(XCTUnwrap(secondStored))))
        // Deleting a photo deletes its blobs with it.
        let plan = try await store.deletionPlan(for: second.id)
        try await store.deletePermanently(plan, removeOriginal: { _ in })
        blobs = try await count("blob", directory)
        XCTAssertEqual(blobs, 1)
        let kept = try await store.savedAdjustments(of: store.asset(asset.id))
        XCTAssertEqual(kept, regenerated)
    }
    func testLUTsAndProfilesAreStoredOnceOutsideTheDevelopment() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        var edits = Adjustments(); edits.lut = lut("Teal"); edits.lut?.amount = 0.6
        let icc = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        edits.colorProfile.preset = .custom; edits.colorProfile.iccData = icc; edits.colorProfile.name = "P3"
        try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        let second = try await secondPhoto(directory, store: store)
        try await store.saveEdits(edits, assetID: second.id, baseline: Adjustments())
        let resources = try await count("resource", directory)
        XCTAssertEqual(resources, 2, "One LUT and one ICC profile, whatever number of photos use them")
        let saved = try await store.asset(asset.id), development = try await store.development(asset.id)
        let stored = try XCTUnwrap(development.adjustmentsData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let storedLUT = try XCTUnwrap(object["lut"] as? [String: Any])
        XCTAssertNil(storedLUT["samples"]); XCTAssertNotNil(storedLUT["resource"]); XCTAssertEqual(storedLUT["amount"] as? Double, 0.6)
        XCTAssertNil((object["colorProfile"] as? [String: Any])?["iccData"])
        let read = try await store.savedAdjustments(of: saved)
        let resolved = try XCTUnwrap(read)
        XCTAssertEqual(resolved.lut?.samples, edits.lut?.samples); XCTAssertEqual(resolved.lut?.amount, 0.6); XCTAssertEqual(resolved.lut?.name, "Teal")
        XCTAssertEqual(resolved.colorProfile.iccData, icc); XCTAssertNotNil(resolved.lut?.source)
        // Saving what was read back changes nothing.
        let before = try await store.history(assetID: asset.id).count
        try await store.saveEdits(resolved, assetID: asset.id)
        let after = try await store.history(assetID: asset.id).count
        XCTAssertEqual(after, before)
    }
    func testFolderResourcesReferToLibraryFilesAndFollowThemWhenMoved() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("Looks", isDirectory: true)
        let folder = FolderResources(root: library)
        let store = try CatalogStore(root: directory.appendingPathComponent("Library"), resources: .folder(folder))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        // A LUT applied from the library is referenced in place.
        let film = library.appendingPathComponent("LUTs/Film/Teal.cube")
        try FileManager.default.createDirectory(at: film.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lut("Teal").cubeText.write(to: film)
        var edits = Adjustments(); edits.lut = try CreativeLUT(contentsOf: film); edits.lut?.source = folder.reference(for: film)
        XCTAssertEqual(edits.lut?.source?.path, "LUTs/Film/Teal.cube")
        try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("LUTs/Imported").path), "Nothing is copied")
        // Moved and renamed in Finder: found again by its contents.
        let moved = library.appendingPathComponent("LUTs/Teal Renamed.cube")
        try FileManager.default.moveItem(at: film, to: moved)
        let reopened = try await store.savedAdjustments(of: store.asset(asset.id))
        XCTAssertEqual(reopened?.lut?.samples, edits.lut?.samples)
        // One that came from elsewhere is written into the library when saved.
        var imported = Adjustments(); imported.lut = lut("Warm"); imported.exposure = 0.3
        try await store.saveEdits(imported, assetID: asset.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("LUTs/Imported/Warm.cube").path))
        // A file that is gone is reported, not silently dropped.
        try FileManager.default.removeItem(at: library.appendingPathComponent("LUTs/Imported/Warm.cube"))
        do { _ = try await store.savedAdjustments(of: store.asset(asset.id)); XCTFail("The LUT is missing") } catch is ResourceUnavailable {}
        // Reset Unreadable takes out only the look that is gone.
        try await store.resetUnreadableEdits(to: Adjustments(), assetID: asset.id)
        let read = try await store.savedAdjustments(of: store.asset(asset.id)); let reset = try XCTUnwrap(read)
        XCTAssertNil(reset.lut); XCTAssertEqual(reset.exposure, 0.3)
    }
    private func rewriteDevelopment(_ directory: URL, _ assetID: String, _ change: (inout [String: Any]) -> Void) throws {
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        try database.write { db in
            let stored = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT adjustmentsData FROM assetDevelopment WHERE assetID = ?", arguments: [assetID]))
            var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
            change(&tree)
            try db.execute(sql: "UPDATE assetDevelopment SET adjustmentsData = ? WHERE assetID = ?", arguments: [JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]), assetID])
        }
    }
    /// A value out of range and a mask whose raster is gone read as unreadable edits naming each part, not as a bare
    /// error, and Reset Unreadable keeps the rest.
    func testValuesOutOfRangeAndMissingRastersCanBeReset() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.saveEdits(masked(1.5), assetID: asset.id, baseline: Adjustments())
        try rewriteDevelopment(directory, asset.id) { $0["temperature"] = 99_999 }
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        try await database.write { try $0.execute(sql: "DELETE FROM blob") }
        do {
            _ = try await store.savedAdjustments(of: store.asset(asset.id)); XCTFail("The edits read")
        } catch EditorError.unreadableEdits(_, let parts) {
            XCTAssertTrue(parts.contains("temperature"), "\(parts)"); XCTAssertTrue(parts.contains("masks › 1"), "\(parts)")
        }
        var defaults = Adjustments(); defaults.temperature = 5200
        try await store.resetUnreadableEdits(to: defaults, assetID: asset.id)
        let read = try await store.savedAdjustments(of: store.asset(asset.id)); let reset = try XCTUnwrap(read)
        XCTAssertEqual(reset.exposure, 1.5); XCTAssertEqual(reset.temperature, 5200); XCTAssertTrue(reset.masks.isEmpty)
    }
    /// A History step that can't be parsed keeps its blobs and doesn't stop the next save.
    func testDamagedHistoryStepDoesNotBlockSaving() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.saveEdits(masked(1.0), assetID: asset.id, baseline: Adjustments())
        let database = try DatabaseQueue(path: directory.appendingPathComponent("Library/catalog.sqlite").path)
        try await database.write { try $0.execute(sql: "UPDATE revision SET payload = ? WHERE kind = 'edit'", arguments: [Data(#"{"masks":["@blob:"#.utf8)]) }
        try await store.resetEdits(to: Adjustments(), assetID: asset.id)
        let blobs = try await count("blob", directory)
        XCTAssertEqual(blobs, 1, "A damaged step may still use the raster")
        let read = try await store.savedAdjustments(of: store.asset(asset.id)); let reset = try XCTUnwrap(read)
        XCTAssertTrue(reset.masks.isEmpty)
    }
    func testRatingsAndFlagsStayOutOfHistory() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        let before = try await store.history(assetID: asset.id).count
        _ = try await store.updateQuickMetadata(assetIDs: [asset.id], rating: 4, review: .accepted)
        var metadata = try await store.asset(asset.id).metadata
        metadata.rating = 2
        try await store.updateMetadata(metadata, assetID: asset.id)
        let afterCulling = try await store.history(assetID: asset.id).count
        XCTAssertEqual(afterCulling, before)
        metadata.title = "Dolomites"
        try await store.updateMetadata(metadata, assetID: asset.id)
        let afterTitle = try await store.history(assetID: asset.id).count
        XCTAssertEqual(afterTitle, before + 1)
    }
    func testReturningToTheSameControlContinuesTheStep() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        // A later autosave of the same control (no open session) continues the explicit step…
        edits.exposure = 0.8
        try await store.saveEdits(edits, assetID: asset.id, coalescing: true)
        var summaries = try await store.history(assetID: asset.id).map(\.summary)
        XCTAssertEqual(summaries.filter { $0 == "Exposure" }.count, 1, "\(summaries)")
        // …while a different control after an explicit save starts a new one.
        edits.contrast = 20
        try await store.saveEdits(edits, assetID: asset.id)
        edits.saturation = 10
        try await store.saveEdits(edits, assetID: asset.id, coalescing: true)
        summaries = try await store.history(assetID: asset.id).map(\.summary)
        XCTAssertEqual(summaries.prefix(2), ["Saturation", "Contrast"], "\(summaries)")
    }
    func testResetAndRevertAreMilestonesAndSnapshotsPersist() async throws {
        let (directory, store, asset) = try await store(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.saveEdits(masked(1), assetID: asset.id, baseline: Adjustments())
        let snapshot = try await store.createSnapshot(name: "  Warm  ", adjustments: masked(1), thumbnail: nil, assetID: asset.id)
        XCTAssertEqual(snapshot.name, "Warm")
        try await store.resetEdits(to: Adjustments(), assetID: asset.id)
        var history = try await store.history(assetID: asset.id)
        XCTAssertEqual(history.first?.summary, "Reset all edits"); XCTAssertEqual(history.first?.milestone, true)
        let snapshots = try await store.snapshots(assetID: asset.id)
        let restored = try await store.adjustments(of: snapshots[0])
        XCTAssertEqual(restored, masked(1))
        try await store.restore(history[1])
        history = try await store.history(assetID: asset.id)
        XCTAssertTrue(history[0].summary.hasPrefix("Reverted to")); XCTAssertTrue(history[0].milestone)
        // Folding history must not drop the raster a snapshot still needs.
        _ = try await store.compactHistory(assetID: asset.id, now: Date().addingTimeInterval(30 * 86400))
        let kept = try await store.snapshots(assetID: asset.id)
        let survived = try await store.adjustments(of: kept[0])
        XCTAssertEqual(survived, masked(1))
    }
    func testCompactionPlanKeepsRecentStepsAndMilestones() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        func entry(_ id: String, hoursAgo: Double, milestone: Bool = false) -> HistoryCompactor.Entry {
            .init(id: id, createdAt: now.addingTimeInterval(-hoursAgo * 3600), milestone: milestone)
        }
        let entries = [
            entry("old1", hoursAgo: 240), entry("old2", hoursAgo: 239.9), entry("old3", hoursAgo: 236),   // same day, >1 week
            entry("mid1", hoursAgo: 50.5), entry("mid2", hoursAgo: 50.4),                                     // same hour, 2 days old
            entry("reset", hoursAgo: 50.3, milestone: true), entry("mid3", hoursAgo: 50.2),                  // milestone splits the run
            entry("new1", hoursAgo: 2), entry("new2", hoursAgo: 1.9)                                          // under a day: kept
        ]
        let runs = HistoryCompactor.plan(entries, now: now, calendar: calendar)
        XCTAssertEqual(runs, [["old1", "old2", "old3"], ["mid1", "mid2"]])
    }
}
