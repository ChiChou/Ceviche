import XCTest
@testable import CevicheCore

/// Devices that change one photo before seeing each other's change, on one shared mirror standing in for CloudKit.
final class CloudSyncMergeTests: XCTestCase {
    private let helper = CloudSyncTests()

    /// A photo every replica has, in step.
    private func shared(_ directory: URL, _ url: URL, _ stores: [CatalogStore], _ engines: [CloudSyncEngine], edits: Adjustments? = nil) async throws -> String {
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await stores[0].insert(prepared.0, thumbnail: prepared.1)
        if let edits { try await stores[0].saveEdits(edits, assetID: asset.id, baseline: Adjustments()) }
        for engine in engines { _ = await engine.sync() }
        for engine in engines { _ = await engine.sync() }
        return asset.id
    }
    private func edit(_ store: CatalogStore, _ id: String, _ change: (inout Adjustments) -> Void) async throws {
        let photo = try await store.asset(id)
        var settings = try await store.savedAdjustments(of: photo) ?? Adjustments()
        change(&settings)
        try await store.saveEdits(settings, assetID: id, baseline: Adjustments())
        // Each edit a clock tick apart, as on real devices.
        try await Task.sleep(for: .milliseconds(5))
    }
    private func settings(_ store: CatalogStore, _ id: String) async throws -> Adjustments? {
        try await store.savedAdjustments(of: try await store.asset(id))
    }
    private func third(_ directory: URL, like store: CatalogStore) throws -> (CatalogStore, CloudSyncEngine) {
        let c = try CatalogStore(root: directory.appendingPathComponent("MacC"), manifest: store.manifest)
        return (c, try CloudSyncEngine(store: c, mirrorURL: directory.appendingPathComponent("mirror.store"), cloudContainer: nil))
    }

    func testEditsToDifferentSettingsOnTwoDevicesBothSurvive() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        var start = Adjustments(); start.exposure = 0.3
        let id = try await shared(directory, url, [a, b], [syncA, syncB], edits: start)
        try await edit(a, id) { $0.exposure = 1.0 }
        try await edit(b, id) { $0.clarity = 25 }
        _ = await syncA.sync(); _ = await syncB.sync(); _ = await syncA.sync()
        for store in [a, b] {
            let merged = try await settings(store, id)
            XCTAssertEqual(merged?.exposure, 1.0); XCTAssertEqual(merged?.clarity, 25)
            let snapshots = try await store.snapshots(assetID: id)
            XCTAssertEqual(snapshots.count, 0, "No conflict, nothing to keep aside")
        }
        let renderA = try await a.asset(id).renderKey, renderB = try await b.asset(id).renderKey
        XCTAssertEqual(renderA, renderB)
        await syncA.stop(); await syncB.stop()
    }
    /// The device whose change is older syncs last: its change must not overwrite the newer one, and the newer one
    /// must not overwrite it.
    func testTheOlderChangeSyncingLastIsMergedNotLost() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        let id = try await shared(directory, url, [a, b], [syncA, syncB], edits: Adjustments())
        try await edit(a, id) { $0.contrast = 12 }
        try await edit(b, id) { $0.vibrance = 30 }
        _ = await syncB.sync(); _ = await syncA.sync(); _ = await syncB.sync()
        for store in [a, b] {
            let merged = try await settings(store, id)
            XCTAssertEqual(merged?.contrast, 12); XCTAssertEqual(merged?.vibrance, 30)
        }
        await syncA.stop(); await syncB.stop()
    }
    func testAConflictKeepsTheLaterEditAndTheOtherAsASnapshot() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        let id = try await shared(directory, url, [a, b], [syncA, syncB], edits: Adjustments())
        try await edit(a, id) { $0.exposure = -1; $0.saturation = 10 }
        try await edit(b, id) { $0.exposure = 1.5 }
        _ = await syncA.sync(); _ = await syncB.sync(); _ = await syncA.sync(); _ = await syncB.sync()
        for store in [a, b] {
            let merged = try await settings(store, id)
            XCTAssertEqual(merged?.exposure, 1.5, "The later edit wins the setting both changed")
            XCTAssertEqual(merged?.saturation, 10)
            let snapshots = try await store.snapshots(assetID: id)
            XCTAssertEqual(snapshots.map(\.name), ["Other edits"])
            let kept = try await store.adjustments(of: snapshots[0])
            XCTAssertEqual(kept.exposure, -1)
        }
        await syncA.stop(); await syncB.stop()
    }
    func testRatingAndKeywordsChangedOnTwoDevicesBothSurvive() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        let id = try await shared(directory, url, [a, b], [syncA, syncB])
        _ = try await a.updateQuickMetadata(assetIDs: [id], rating: 4)
        try await Task.sleep(for: .milliseconds(5))
        var metadata = try await b.asset(id).metadata; metadata.keywords = "dusk, harbour"
        try await b.updateMetadata(metadata, assetID: id)
        _ = await syncB.sync(); _ = await syncA.sync(); _ = await syncB.sync()
        for store in [a, b] {
            let photo = try await store.asset(id)
            XCTAssertEqual(photo.rating, 4); XCTAssertEqual(photo.metadata.keywordList, ["dusk", "harbour"])
        }
        await syncA.stop(); await syncB.stop()
    }
    /// An iPhone, a Mac and an iPad each change the photo offline, then sync in turn: all three agree, with every
    /// change in.
    func testThreeDevicesConverge() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        let (c, syncC) = try third(directory, like: a)
        let id = try await shared(directory, url, [a, b, c], [syncA, syncB, syncC], edits: Adjustments())
        try await edit(a, id) { $0.exposure = 0.7 }
        try await edit(b, id) { $0.geometry.straighten = 3 }
        try await edit(c, id) { $0.vignette = 20 }
        for _ in 0..<2 { for engine in [syncC, syncA, syncB] { _ = await engine.sync() } }
        var results: [Adjustments] = []
        for store in [a, b, c] { if let merged = try await settings(store, id) { results.append(merged) } }
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].exposure, 0.7); XCTAssertEqual(results[0].geometry.straighten, 3); XCTAssertEqual(results[0].vignette, 20)
        XCTAssertEqual(results[1], results[0]); XCTAssertEqual(results[2], results[0])
        await syncA.stop(); await syncB.stop(); await syncC.stop()
    }
    func testAPhotoChangedOnOneDeviceStillJustArrives() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b, syncA, syncB) = try helper.replicas(directory)
        let id = try await shared(directory, url, [a, b], [syncA, syncB], edits: Adjustments())
        try await edit(a, id) { $0.exposure = 0.4 }
        _ = await syncA.sync(); _ = await syncB.sync()
        let received = try await settings(b, id)
        XCTAssertEqual(received?.exposure, 0.4)
        let renderA = try await a.asset(id).renderKey, renderB = try await b.asset(id).renderKey
        XCTAssertEqual(renderA, renderB, "Not a merge: the edit arrives as made")
        await syncA.stop(); await syncB.stop()
    }
}
