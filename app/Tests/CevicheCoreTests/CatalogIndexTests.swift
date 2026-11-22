import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogIndexTests: XCTestCase {
    let version = CatalogImporter.analysisVersion
    func fixture() async throws -> (URL, URL, CatalogStore, CatalogAsset) {
        let (directory, url) = try CatalogTests().fixture()
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        return (directory, url, store, asset)
    }
    func testQueueSurvivesReopenAndClaimsAreExclusive() async throws {
        let (directory, _, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let other = try CatalogStore(root: store.root, existingOnly: true)
        let initial = try await other.analysisStatus(); XCTAssertEqual(initial.pending, 1)
        async let a = store.claimAnalysis(owner: "first", version: version)
        async let b = other.claimAnalysis(owner: "second", version: version)
        let claims = try await [a, b].compactMap { $0 }
        XCTAssertEqual(claims.count, 1)
        let claim = try XCTUnwrap(claims.first)
        var metadata = asset.metadata; metadata.rating = 5; metadata.title = "Saved while Vision runs"
        try await other.updateMetadata(metadata, assetID: asset.id)
        let applied = try await store.finishAnalysis(claim, tags: "mountain, sky", version: version)
        XCTAssertTrue(applied)
        let current = try await other.asset(asset.id)
        XCTAssertEqual(current.metadata, metadata); XCTAssertEqual(current.suggestedTags, "mountain, sky")
        XCTAssertEqual(current.thumbnailKey, asset.thumbnailKey); XCTAssertEqual(current.renderKey, asset.renderKey)
        let history = try await other.history(assetID: asset.id); XCTAssertEqual(history.count, 2)
        let status = try await other.analysisStatus(); XCTAssertEqual(status.complete, 1)
        try await other.enqueueOutdatedAnalysis(version: version)
        let noDuplicate = try await other.claimAnalysis(owner: "third", version: version); XCTAssertNil(noDuplicate)
    }
    func testExpiredClaimCannotOverwriteNewOwner() async throws {
        let (directory, _, store, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 100)
        let oldValue = try await store.claimAnalysis(owner: "old", version: version, now: start, leaseSeconds: 5)
        let old = try XCTUnwrap(oldValue)
        let other = try CatalogStore(root: store.root, existingOnly: true)
        let nextValue = try await other.claimAnalysis(owner: "next", version: version, now: start.addingTimeInterval(6))
        let next = try XCTUnwrap(nextValue)
        let stale = try await store.finishAnalysis(old, tags: "wrong", version: version, now: start.addingTimeInterval(7))
        XCTAssertFalse(stale)
        let applied = try await other.finishAnalysis(next, tags: "right", version: version, now: start.addingTimeInterval(7))
        XCTAssertTrue(applied)
        let saved = try await other.asset(next.asset.id); XCTAssertEqual(saved.suggestedTags, "right")
    }
    func testRetryBackoffPauseAndFailureLimit() async throws {
        let (directory, _, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.setAnalysisEnabled(false)
        let paused = try await store.claimAnalysis(owner: "paused", version: version); XCTAssertNil(paused)
        try await store.setAnalysisEnabled(true)
        var now = Date(timeIntervalSince1970: 100)
        for attempt in 1...5 {
            let claim = try await store.claimAnalysis(owner: "failure", version: version, now: now)
            XCTAssertNotNil(claim)
            try await store.failAnalysis(owner: "failure", message: "Disconnected original", now: now)
            let immediate = try await store.claimAnalysis(owner: "early", version: version, now: now); XCTAssertNil(immediate)
            let job = try await store.analysisJob(assetID: asset.id)
            XCTAssertEqual(job?.attempts, attempt); XCTAssertEqual(job?.state, attempt == 5 ? .failed : .pending)
            now = Date(timeIntervalSince1970: job!.nextAttempt + 1)
        }
        let reopened = try CatalogStore(root: store.root, existingOnly: true)
        try await reopened.enqueueOutdatedAnalysis(version: version)
        let failed = try await reopened.analysisJob(assetID: asset.id); XCTAssertEqual(failed?.state, .failed)
        try await reopened.retryFailedAnalysis()
        let retry = try await reopened.claimAnalysis(owner: "retry", version: version, now: now); XCTAssertNotNil(retry)
        try await reopened.failAnalysis(owner: "retry", message: "User resumed editing", interrupted: true, now: now)
        let interrupted = try await reopened.analysisJob(assetID: asset.id)
        XCTAssertEqual(interrupted?.attempts, 0); XCTAssertEqual(interrupted?.state, .pending)
    }
    func testRelinkAndRequeueRejectStaleResults() async throws {
        let (directory, url, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = try await store.claimAnalysis(owner: "old", version: version)
        let claim = try XCTUnwrap(value)
        let copy = directory.appendingPathComponent("new-location.jpg"); try FileManager.default.copyItem(at: url, to: copy)
        try await store.relink(copy, assetID: asset.id)
        let stale = try await store.finishAnalysis(claim, tags: "old", version: version); XCTAssertFalse(stale)
        let newValue = try await store.claimAnalysis(owner: "new", version: version)
        let fresh = try XCTUnwrap(newValue); XCTAssertEqual(fresh.asset.sourcePath, copy.path)
        try await store.enqueueAnalysis(assetID: asset.id, version: version)
        let requeued = try await store.finishAnalysis(fresh, tags: "stale", version: version); XCTAssertFalse(requeued)
    }
    func testWorkerCommitsEmptyResultAndRejectsChangedOriginal() async throws {
        let (directory, url, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let version = self.version
        let empty = try await CatalogIndexWorker.runOne(store: store, owner: "empty", classify: { _ in ("", version) })
        XCTAssertEqual(empty, .completed)
        let saved = try await store.asset(asset.id); XCTAssertEqual(saved.analysisVersion, version)
        try await store.enqueueAnalysis(assetID: asset.id, version: version)
        try Data("Changed original".utf8).write(to: url)
        let result = try await CatalogIndexWorker.runOne(store: store, owner: "changed", classify: { _ in XCTFail("Must not classify a mismatched original"); return ("bad", version) })
        XCTAssertEqual(result, .failed)
        let job = try await store.analysisJob(assetID: asset.id); XCTAssertTrue(job?.lastError?.contains("changed") == true)
        let unchanged = try await store.asset(asset.id); XCTAssertEqual(unchanged.suggestedTags, "")
    }
    func testCancellationReturnsJobWithoutConsumingRetry() async throws {
        let (directory, _, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let token = CatalogAnalysisCancellation(), version = self.version
        do {
            _ = try await CatalogIndexWorker.runOne(store: store, owner: "cancelled", cancellation: token, classify: { _ in token.cancel(); return ("discarded", version) })
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {} catch { throw error }
        try await store.failAnalysis(owner: "cancelled", message: "Paused by user", interrupted: true)
        let job = try await store.analysisJob(assetID: asset.id)
        XCTAssertEqual(job?.state, .pending); XCTAssertEqual(job?.attempts, 0)
        let saved = try await store.asset(asset.id); XCTAssertNil(saved.analysisVersion)
    }
    func testTimeoutAfterCancellationConsumesRetry() async throws {
        let (directory, _, store, asset) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let token = CatalogAnalysisCancellation(), version = self.version
        do {
            _ = try await CatalogIndexWorker.runOne(store: store, owner: "timeout", cancellation: token, classify: { _ in token.cancel(); return ("discarded", version) })
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {} catch { throw error }
        try await store.failAnalysis(owner: "timeout", message: "Service timed out")
        let job = try await store.analysisJob(assetID: asset.id)
        XCTAssertEqual(job?.attempts, 1); XCTAssertEqual(job?.state, .pending)
        XCTAssertGreaterThan(job?.nextAttempt ?? 0, Date().timeIntervalSince1970)
    }
    func testBundledXPCIndexesRealPhotoWhenRequested() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CEVICHE_XPC_PROBE"] else { throw XCTSkip("Run scripts/test-index-service.sh for bundled XPC integration") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory)
        let prepared = try CatalogImporter.prepare(try TestSamples.require(TestSamples.landscape))
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        var assets = [asset]
        for index in 1..<4 {
            var copy = try await store.photo(asset.id); copy.id = UUID().uuidString; copy.importPath += "-batch-\(index)"
            assets.append(try await store.insert(copy, thumbnail: nil))
        }
        let status = try await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = [directory.path, asset.sourcePath]
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }.value
        XCTAssertEqual(status, 0)
        let saved = try await store.asset(asset.id)
        XCTAssertEqual(saved.analysisVersion, CatalogImporter.analysisVersion)
        XCTAssertTrue(saved.suggestedTags.contains("plant"), "Expected the actual Vision result for the supplied foliage photo")
        for photo in assets {
            let job = try await store.analysisJob(assetID: photo.id); XCTAssertEqual(job?.state, .complete)
            let indexed = try await store.asset(photo.id)
            XCTAssertEqual(indexed.suggestedTags, saved.suggestedTags)
        }
        XCTAssertEqual(saved.metadata, asset.metadata); XCTAssertEqual(saved.renderKey, asset.renderKey)
    }
    func testWorkerRefusesAMissingCatalog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try CatalogStore(root: directory.appendingPathComponent("NoCatalog"), existingOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("NoCatalog").path))
    }
}
