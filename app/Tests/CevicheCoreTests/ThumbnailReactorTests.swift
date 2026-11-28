import XCTest
import Synchronization
@testable import CevicheCore

final class ThumbnailReactorTests: XCTestCase {
    /// Steps the stub ran, and a gate that holds renders until opened.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ThumbnailReactor.Step, String)] = []
        private var gate: [CheckedContinuation<Void, Never>] = []
        private var gateOpen = true
        var onDevelop: (@Sendable (CatalogAsset) async -> Void)?
        func add(_ step: ThumbnailReactor.Step, _ id: String) { lock.withLock { entries.append((step, id)) } }
        var steps: [(ThumbnailReactor.Step, String)] { lock.withLock { entries } }
        func count(_ step: ThumbnailReactor.Step, _ id: String) -> Int { steps.filter { $0.0 == step && $0.1 == id }.count }
        func close() { lock.withLock { gateOpen = false } }
        func open() { let waiting = lock.withLock { gateOpen = true; let g = gate; gate = []; return g }; waiting.forEach { $0.resume() } }
        func pass() async {
            let wait = lock.withLock { !gateOpen }
            guard wait else { return }
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { if gateOpen { return true }; gate.append(continuation); return false }
                if resumeNow { continuation.resume() }
            }
        }
    }

    /// Stands in for the decoder: previews and renders store a few bytes, as the real steps store a JPEG.
    static func stub(_ log: Log) -> ThumbnailReactor.Work {
        { step, asset, store in
            log.add(step, asset.id);
            switch step {
            case .embedded, .decode:
                try await store.installPreviewThumbnail(Data("preview \(asset.id)".utf8), assetID: asset.id)
            case .develop:
                await log.pass()
                await log.onDevelop?(asset)
                try Task.checkCancellation()
                try await store.installThumbnail(Data("render \(asset.renderKey)".utf8), assetID: asset.id, renderKey: asset.renderKey)
            }
            return .installed
        }
    }

    /// Waits for `condition`, failing rather than spinning forever.
    func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private var directory: URL!
    override func tearDown() { if let directory { try? FileManager.default.removeItem(at: directory) } }

    /// A catalog with `count` photos listed without thumbnails, and edits on the ones in `edited`.
    func catalog(_ count: Int, edited: Set<Int> = []) async throws -> (CatalogStore, [String]) {
        let (directory, photo) = try CatalogTests().fixture()
        self.directory = directory
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var ids: [String] = []
        for index in 0..<count {
            let url = directory.appendingPathComponent("p\(index).jpg")
            try FileManager.default.copyItem(at: photo, to: url)
            let prepared = try CatalogImporter.prepare(url, options: CatalogImporter.ImportOptions(thumbnail: false))
            let id = try await store.insert(prepared.0, thumbnail: nil).id
            if edited.contains(index) { var edit = Adjustments(); edit.exposure = 0.5; _ = try await store.saveEdits(edit, assetID: id) }
            ids.append(id)
        }
        return (store, ids)
    }

    func testAPhotoAskedForTwiceIsDoneOnce() async throws {
        let (store, ids) = try await catalog(3, edited: [0, 1, 2])
        let log = Log()
        let reactor = ThumbnailReactor(store: store, work: Self.stub(log))
        let first = await reactor.want(ids, kind: .developed, priority: .batch)
        let second = await reactor.want(ids, kind: .developed, priority: .visible)
        let outcomes = await reactor.wait([first, second])
        XCTAssertEqual(Set(outcomes.values), [.installed])
        for id in ids { XCTAssertEqual(log.count(.develop, id), 1); XCTAssertEqual(log.count(.embedded, id), 1) }
        // Up to date now: asked again, nothing runs.
        let again = await reactor.wait(await reactor.want(ids, kind: .developed, priority: .batch))
        XCTAssertEqual(Set(again.values), [.current])
        XCTAssertEqual(log.steps.count, 6)
        let fresh = try await store.asset(ids[0])
        XCTAssertEqual(fresh.thumbnailRenderKey, fresh.renderKey)
    }

    /// A photo with no camera preview is decoded instead; one that is up to date costs nothing.
    func testPreviewsFallBackToADecode() async throws {
        let (store, ids) = try await catalog(2)
        let log = Log()
        let reactor = ThumbnailReactor(store: store, work: { step, asset, store in
            if step == .embedded, asset.id == ids[0] { log.add(step, asset.id); return .noPreview }
            return try await Self.stub(log)(step, asset, store)
        })
        let outcomes = await reactor.wait(await reactor.want(ids, kind: .preview, priority: .visible))
        XCTAssertEqual(outcomes[ids[0]], .installed); XCTAssertEqual(outcomes[ids[1]], .installed)
        XCTAssertEqual(log.count(.decode, ids[0]), 1); XCTAssertEqual(log.count(.decode, ids[1]), 0)
    }

    /// The camera's preview of an edited photo is stored still marked for a render, in the one write: a quit before a
    /// second write would leave the undeveloped preview passing for the edits. An unedited photo's preview is current.
    func testAPreviewOfAnEditedPhotoStaysMarkedForARender() async throws {
        let (store, ids) = try await catalog(2, edited: [0])
        for id in ids { try await store.installPreviewThumbnail(Data("preview \(id)".utf8), assetID: id) }
        let edited = try await store.asset(ids[0]), plain = try await store.asset(ids[1])
        XCTAssertNotNil(edited.thumbnailKey); XCTAssertNil(edited.thumbnailRenderKey)
        XCTAssertNotNil(plain.thumbnailKey); XCTAssertEqual(plain.thumbnailRenderKey, plain.renderKey)
        let undeveloped = try await store.undevelopedAssetIDs()
        XCTAssertEqual(undeveloped, [ids[0]])
    }

    /// Edits saved while a render runs: the render's thumbnail is not kept, and the photo is rendered again.
    func testEditsChangedMidRenderAreRenderedAgain() async throws {
        let (store, ids) = try await catalog(1, edited: [0])
        let log = Log()
        let changed = Mutex(false)
        log.onDevelop = { asset in
            guard changed.withLock({ let first = !$0; $0 = true; return first }) else { return }
            var edit = Adjustments(); edit.exposure = 1
            _ = try? await store.saveEdits(edit, assetID: asset.id)
        }
        let reactor = ThumbnailReactor(store: store, work: Self.stub(log))
        let outcomes = await reactor.wait(await reactor.want(ids, kind: .developed, priority: .batch))
        XCTAssertEqual(outcomes[ids[0]], .installed)
        XCTAssertEqual(log.count(.develop, ids[0]), 2)
        let fresh = try await store.asset(ids[0])
        XCTAssertEqual(fresh.thumbnailRenderKey, fresh.renderKey)
        let stored = try await store.previews.data(assetID: ids[0])
        XCTAssertEqual(stored, Data("render \(fresh.renderKey)".utf8))
    }

    /// Stop: the photos only that ticket wanted leave the queue; one another ticket wants carries on.
    func testCancellingATicketDropsOnlyItsOwnPhotos() async throws {
        let (store, ids) = try await catalog(4, edited: [0, 1, 2, 3])
        let log = Log(); log.close()
        let reactor = ThumbnailReactor(store: store, renderWidth: 1, work: Self.stub(log))
        let batch = await reactor.want(ids, kind: .developed, priority: .batch)
        let other = await reactor.want([ids[3]], kind: .developed, priority: .batch)
        try await until { log.count(.develop, ids[0]) > 0 }
        await reactor.cancel(batch)
        log.open()
        let outcomes = await reactor.wait(other)
        XCTAssertEqual(outcomes, [ids[3]: .installed])
        XCTAssertEqual(log.count(.develop, ids[1]), 0); XCTAssertEqual(log.count(.develop, ids[2]), 0)
        // The render under way when Stop came was abandoned before storing its thumbnail.
        let first = try await store.asset(ids[0])
        XCTAssertNotEqual(first.thumbnailRenderKey, first.renderKey)
        // The cancelled ticket's wait returns too.
        _ = await reactor.wait(batch)
    }

    /// Photos on screen go ahead of a job's photos still waiting.
    func testHigherPriorityGoesFirst() async throws {
        let (store, ids) = try await catalog(4, edited: [0, 1, 2, 3])
        let log = Log(); log.close()
        let reactor = ThumbnailReactor(store: store, renderWidth: 1, work: Self.stub(log))
        let background = await reactor.want(ids[0..<3], kind: .developed, priority: .background)
        try await until { log.count(.develop, ids[0]) > 0 }
        let visible = await reactor.want([ids[3]], kind: .developed, priority: .visible)
        log.open()
        _ = await reactor.wait([background, visible])
        let order = log.steps.filter { $0.0 == .develop }.map(\.1)
        XCTAssertEqual(order, [ids[0], ids[3], ids[1], ids[2]])
    }

    /// Background renders take one place in the render lane at a time; a batch render still starts beside them.
    func testBackgroundRendersRunOneAtATime() async throws {
        let (store, ids) = try await catalog(4, edited: [0, 1, 2, 3])
        let log = Log(); log.close()
        let reactor = ThumbnailReactor(store: store, renderWidth: 3, work: Self.stub(log))
        let background = await reactor.want(ids[0..<3], kind: .developed, priority: .background)
        try await until { log.steps.contains { $0.0 == .develop } }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.steps.filter { $0.0 == .develop }.count, 1)
        let batch = await reactor.want([ids[3]], kind: .developed, priority: .batch)
        try await until { log.count(.develop, ids[3]) > 0 }
        XCTAssertEqual(log.steps.filter { $0.0 == .develop && $0.1 != ids[3] }.count, 1)
        log.open()
        let outcomes = await reactor.wait([background, batch])
        XCTAssertEqual(Set(outcomes.values), [.installed])
        XCTAssertEqual(outcomes.count, 4)
    }

    /// While the editor holds renders, camera previews still arrive; renders start once released.
    func testHeldRendersWaitPreviewsDoNot() async throws {
        let (store, ids) = try await catalog(2, edited: [1])
        let log = Log()
        let reactor = ThumbnailReactor(store: store, work: Self.stub(log))
        let owner = ObjectIdentifier(self)
        await reactor.holdRenders(true, by: owner, sequence: 1)
        let preview = await reactor.want([ids[0]], kind: .preview, priority: .visible)
        let render = await reactor.want([ids[1]], kind: .developed, priority: .batch)
        let previewed = await reactor.wait(preview)
        XCTAssertEqual(previewed, [ids[0]: .installed])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.count(.develop, ids[1]), 0)
        // A stale release arriving late changes nothing.
        await reactor.holdRenders(true, by: owner, sequence: 0)
        await reactor.holdRenders(false, by: owner, sequence: 2)
        let rendered = await reactor.wait(render)
        XCTAssertEqual(rendered, [ids[1]: .installed])
    }

    /// The catch-up finds edited photos whose thumbnail does not show their edits.
    func testCatchUpFindsUndevelopedPhotos() async throws {
        let (store, ids) = try await catalog(3, edited: [1, 2])
        let log = Log()
        let reactor = ThumbnailReactor(store: store, work: Self.stub(log))
        let found = try await store.undevelopedAssetIDs()
        XCTAssertEqual(Set(found), [ids[1], ids[2]])
        let ticket = await reactor.catchUp()
        XCTAssertEqual(ticket?.total, 2)
        _ = await reactor.wait(ticket!)
        let left = try await store.undevelopedAssetIDs()
        XCTAssertEqual(left, [])
    }

    /// Originals on a network share or another volume are left to the grid: the catch-up renders only this Mac's own.
    func testCatchUpLeavesNetworkAndVolumeOriginals() async throws {
        let (store, ids) = try await catalog(3, edited: [0, 1, 2])
        try await store.database.write { db in
            try db.execute(sql: "UPDATE asset SET origin = 'file:///Volumes/photo/a.ARW' WHERE id = ?", arguments: [ids[0]])
            try db.execute(sql: "UPDATE asset SET origin = 'volume://0000/a.ARW' WHERE id = ?", arguments: [ids[1]])
        }
        let all = try await store.undevelopedAssetIDs()
        XCTAssertEqual(Set(all), Set(ids))
        let local = try await store.undevelopedAssetIDs(onThisMac: true)
        XCTAssertEqual(local, [ids[2]])
    }
}
