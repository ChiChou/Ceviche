import XCTest
import GRDB
@testable import CevicheCore

final class PreviewStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testNewDatabaseUsesLargePagesAndIncrementalVacuum() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PreviewStore(root: directory)
        try await store.install(Data(repeating: 1, count: 50_000), assetID: "a")
        let queue = try DatabaseQueue(path: store.url.path)
        let (pageSize, autoVacuum) = try await queue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0, try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0)
        }
        XCTAssertEqual(pageSize, 16384)
        XCTAssertEqual(autoVacuum, 2, "Incremental, so sweeps can hand freed pages back")
    }
    func testInstallReplacesInPlaceAndRemoveDeletes() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PreviewStore(root: directory)
        try await store.install(Data([1, 2, 3]), assetID: "a")
        try await store.install(Data([9]), assetID: "a")
        try await store.install(Data([4, 5]), assetID: "b")
        let replaced = try await store.data(assetID: "a"), rows = try await store.count(), bytes = try await store.bytes()
        XCTAssertEqual(replaced, Data([9]))
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(bytes, 3)
        try await store.remove(assetIDs: ["a"])
        let removed = try await store.data(assetID: "a"), remaining = try await store.count()
        XCTAssertNil(removed)
        XCTAssertEqual(remaining, 1)
    }
    func testSweepDropsUnreferencedThenLeastRecentlySeenOverBudget() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PreviewStore(root: directory)
        for id in ["a", "b", "c", "gone"] { try await store.install(Data(repeating: 0, count: 100), assetID: id) }
        // Everything was installed today; age two rows so the order is observable, then show "b" again.
        let queue = try DatabaseQueue(path: store.url.path)
        try await queue.write { try $0.execute(sql: "UPDATE preview SET lastSeenDay = lastSeenDay - 10 WHERE assetID IN ('a', 'b')") }
        _ = try await store.data(assetID: "b")
        let evicted = try await store.sweep(budget: 250) { ["a", "b", "c"] }
        let gone = try await store.data(assetID: "gone"), rows = try await store.count()
        XCTAssertNil(gone, "Photos no longer in the catalog lose their previews")
        XCTAssertEqual(evicted, ["a"], "The least recently shown thumbnail goes first; showing b today kept it")
        XCTAssertEqual(rows, 2)
        let unbudgeted = try await store.sweep(budget: nil) { ["a", "b", "c"] }
        XCTAssertEqual(unbudgeted, [], "Without a budget nothing is evicted")
    }
    func testBackupIsAnIndependentCopy() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PreviewStore(root: directory)
        try await store.install(Data([1]), assetID: "a")
        let copyRoot = directory.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        try store.backup(to: copyRoot.appendingPathComponent(PreviewStore.filename))
        try await store.install(Data([2]), assetID: "a")
        let copied = try await PreviewStore(root: copyRoot).data(assetID: "a")
        XCTAssertEqual(copied, Data([1]))
    }
}
