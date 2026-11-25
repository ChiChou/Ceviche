import XCTest
import CevicheTestSupport
import CevicheCore
@testable import CevicheMac

final class CatalogPendingOutputTests: XCTestCase {
    @MainActor func testAbortAndCommitHaveOneWinner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try PendingOutput(root: directory, source: nil, title: "HDR", albumID: nil, journalDirectory: directory)
        var cancelled = false
        first.cancel = { cancelled = true }
        first.abort()
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try first.beginCommit())
        let second = try PendingOutput(root: directory, source: nil, title: "HDR", albumID: nil, journalDirectory: directory)
        try second.beginCommit()
        second.abort()
        XCTAssertFalse(second.aborted)
        XCTAssertTrue(second.committing)
    }

    @MainActor func testMergeReservesReplacesAndAbortsWithoutPublishing() async throws {
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = CatalogModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        let imported = try CatalogImporter.prepare(photo)
        let source = try await store.insert(imported.0, thumbnail: imported.1)
        func start() {
            catalog.runMergeJob(beside: photo, suffix: "Test", title: "Test", access: [], merge: { destination, progress in
                try FileManager.default.copyItem(at: photo, to: destination)
                progress(1, "")
            }, done: "Done", detail: "", stopped: "Stopped", failed: { $0 })
        }
        start()
        let aborted = try XCTUnwrap(catalog.pendingOutputs.first)
        XCTAssertFalse(catalog.selectedAssets.contains { $0.id == aborted.id })
        aborted.abort()
        let firstJob = try XCTUnwrap(catalog.activity.running.last?.id)
        await catalog.activity.wait(firstJob)
        XCTAssertTrue(catalog.pendingOutputs.isEmpty)
        let afterAbort = try await store.assets()
        XCTAssertEqual(afterAbort.map(\.id), [source.id])
        start()
        let pending = try XCTUnwrap(catalog.pendingOutputs.first)
        let secondJob = try XCTUnwrap(catalog.activity.running.last?.id)
        await catalog.activity.wait(secondJob)
        XCTAssertTrue(catalog.pendingOutputs.isEmpty)
        let output = try await store.asset(pending.id)
        XCTAssertNotNil(output.thumbnailKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CatalogImporter.sourceURL(for: output, root: store.root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.journal.path))
    }
}

extension CatalogPendingOutputTests {
    @MainActor func testBatchAbortIsPerOutputAndSkipsQueuedWork() async throws {
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = CatalogModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        let prepared = try CatalogImporter.prepare(photo)
        let source = try await store.insert(prepared.0, thumbnail: prepared.1)
        // Convert Negative is the batch left: AI Noise Reduction and Wide-Angle Faces work on one photo.
        do {
            catalog.startNegative([source, source], choices: [:])
            let outputs = catalog.pendingOutputs
            XCTAssertEqual(outputs.count, 2)
            outputs[1].abort()
            XCTAssertFalse(outputs[0].aborted)
            XCTAssertEqual(catalog.pendingOutputs.count, 1)
            outputs[0].abort()
            let activity = try XCTUnwrap(catalog.activity.running.last?.id)
            await catalog.activity.wait(activity)
            XCTAssertTrue(catalog.pendingOutputs.isEmpty)
            XCTAssertEqual(catalog.activity.recent.first?.outcome, .stopped)
            let remaining = try await store.assets()
            XCTAssertEqual(remaining.count, 1)
        }
    }

    @MainActor func testRecoveryRemovesUnpublishedOutputButKeepsCommittedPhoto() async throws {
        let (directory, photo) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = CatalogModel()
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        let pending = try catalog.reserveOutput(source: nil, title: "Test", store: store)
        let partial = directory.appendingPathComponent("Partial.dng")
        try Data([0]).write(to: partial)
        try pending.recordGenerated(partial)
        catalog.pendingOutputs = []
        await catalog.recoverPendingOutputs(in: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.journal.path))
        XCTAssertNotNil(catalog.failure)
        let complete = try catalog.reserveOutput(source: nil, title: "Test", store: store)
        var prepared = try CatalogImporter.prepare(photo)
        prepared.0.id = complete.id
        _ = try await store.insertCompletedOutput(prepared.0, thumbnail: prepared.1)
        try complete.recordGenerated(photo)
        catalog.pendingOutputs = []
        await catalog.recoverPendingOutputs(in: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: complete.journal.path))
        // A record cut short mid-write can't be recovered from, so it goes instead of staying forever.
        let damaged = CatalogModel.jobJournalDirectory(store).appendingPathComponent("damaged.json")
        try Data("{\"id\":".utf8).write(to: damaged)
        await catalog.recoverPendingOutputs(in: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: damaged.path))
    }
}
