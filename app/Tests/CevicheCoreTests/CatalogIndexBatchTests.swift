import XCTest
import Vision
@testable import CevicheCore

final class CatalogIndexBatchTests: XCTestCase {
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CatalogIndexWorker.Outcome?, Never>?
        init(_ continuation: CheckedContinuation<CatalogIndexWorker.Outcome?, Never>) { self.continuation = continuation }
        func resume(_ value: CatalogIndexWorker.Outcome?) {
            let pending = lock.withLock { let c = continuation; continuation = nil; return c }
            pending?.resume(returning: value)
        }
    }
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var active = 0, peak = 0, calls = 0
        func enter() -> Int { lock.withLock { active += 1; calls += 1; peak = max(peak, active); return calls } }
        func leave() { lock.withLock { active -= 1 } }
    }
    private func copies(_ count: Int, asset: CatalogAsset, store: CatalogStore) async throws {
        for index in 1..<count {
            var copy = try await store.photo(asset.id); copy.id = UUID().uuidString; copy.importPath += "-\(index)"
            _ = try await store.insert(copy, thumbnail: nil)
        }
    }
    func testBatchUsesBoundedParallelWorkersAndStopsAtBatchSize() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await copies(20, asset: asset, store: store)
        let probe = Probe(), version = CatalogImporter.analysisVersion
        let classify: @Sendable (URL) throws -> (String, String) = { _ in
            _ = probe.enter(); defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.08)
            return ("mountain", version)
        }
        let first = try await CatalogIndexWorker.runBatch(store: store, owner: "batch-one", classify: classify)
        XCTAssertEqual(first, .completed)
        let status = try await store.analysisStatus()
        XCTAssertEqual(status.complete, 16); XCTAssertEqual(status.pending, 4); XCTAssertEqual(status.running, 0)
        XCTAssertGreaterThan(probe.peak, 1); XCTAssertLessThanOrEqual(probe.peak, 4)
        _ = try await CatalogIndexWorker.runBatch(store: store, owner: "batch-two", classify: classify)
        let finished = try await store.analysisStatus()
        XCTAssertEqual(finished.complete, 20); XCTAssertEqual(finished.remaining, 0)
        XCTAssertEqual(probe.calls, 20, "Each photo is classified once")
    }
    /// Vision itself, not a stub, on a full set of parallel workers: at background priority its classify
    /// requests deadlocked, so no batch ever replied and the app timed every one out.
    func testRealClassificationOfParallelWorkersCompletes() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await copies(8, asset: asset, store: store)
        // A deadlocked batch never returns, not even when cancelled, so the race leaves it behind rather than awaiting it.
        let outcome: CatalogIndexWorker.Outcome? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(try? await CatalogIndexWorker.runBatch(store: store, owner: "vision")) }
            Task { try? await Task.sleep(for: .seconds(90)); once.resume(nil) }
        }
        XCTAssertEqual(outcome, .completed, "Classification did not finish in time")
        let status = try await store.analysisStatus()
        XCTAssertEqual(status.complete, 8); XCTAssertEqual(status.remaining, 0)
    }
    func testFailureDoesNotReleaseOtherPhotosInSameBatch() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await copies(4, asset: asset, store: store)
        let probe = Probe(), version = CatalogImporter.analysisVersion
        _ = try await CatalogIndexWorker.runBatch(store: store, owner: "shared-owner", classify: { _ in
            let call = probe.enter(); defer { probe.leave() }
            Thread.sleep(forTimeInterval: 0.08)
            if call == 1 { throw EditorError.decode }
            return ("sky", version)
        })
        let status = try await store.analysisStatus()
        XCTAssertEqual(status.complete, 3); XCTAssertEqual(status.pending, 1); XCTAssertEqual(status.running, 0)
        let assets = try await store.assets()
        for photo in assets {
            let job = try await store.analysisJob(assetID: photo.id)
            XCTAssertEqual(job?.attempts, 1)
        }
    }
    func testBatchCancellationRequeuesEveryUnfinishedClaim() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await copies(8, asset: asset, store: store)
        let token = CatalogAnalysisCancellation(), version = CatalogImporter.analysisVersion
        do {
            _ = try await CatalogIndexWorker.runBatch(store: store, owner: "cancelled-batch", cancellation: token, classify: { _ in
                token.cancel(); return ("discarded", version)
            })
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {}
        try await store.failAnalysis(owner: "cancelled-batch", message: "Rendering", interrupted: true)
        let status = try await store.analysisStatus()
        XCTAssertEqual(status.pending, 8); XCTAssertEqual(status.running, 0); XCTAssertEqual(status.complete, 0)
        for photo in try await store.assets() {
            let job = try await store.analysisJob(assetID: photo.id)
            XCTAssertEqual(job?.attempts, 0)
        }
    }
    private final class Request: VNRequest, @unchecked Sendable {
        var cancellations = 0
        override func cancel() { cancellations += 1 }
    }
    func testCancellationReachesAllActiveVisionRequests() throws {
        let token = CatalogAnalysisCancellation()
        let first = Request(), second = Request(), finished = Request()
        try token.addRequest(first); try token.addRequest(second); try token.addRequest(finished)
        token.removeRequest(finished)
        token.cancel()
        XCTAssertEqual(first.cancellations, 1); XCTAssertEqual(second.cancellations, 1); XCTAssertEqual(finished.cancellations, 0)
        XCTAssertThrowsError(try token.addRequest(Request()))
    }
}
