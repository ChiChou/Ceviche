import XCTest
import CevicheCore
@testable import CevicheMac

final class CatalogIndexerTests: XCTestCase {
    @MainActor func testNewWorkWakesIdleIndexerWithoutWaitingForPoll() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        var requests = 0
        let indexer = CatalogIndexer(pollInterval: .seconds(60)) {
            requests += 1
            // Observe dispatch without launching Vision; connection failure also exercises retry cleanup.
            let client = CatalogIndexConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
            client.invalidate()
            return client
        }
        indexer.start(catalog: model)
        defer { indexer.stop() }
        for _ in 0..<100 {
            if model.indexingMessage == "All photos are analyzed." { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.indexingMessage, "All photos are analyzed.")
        XCTAssertEqual(requests, 0)
        let prepared = try CatalogImporter.prepare(url)
        _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        indexer.workAvailable()
        for _ in 0..<100 {
            if requests > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requests, 1, "New work must start without the 60-second idle poll")
    }
    @MainActor func testXPCReplyAndReconnect() async throws {
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        try await store.setAnalysisEnabled(false)
        let listener = NSXPCListener.anonymous(), delegate = CatalogIndexServiceDelegate()
        listener.delegate = delegate; listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        for _ in 0..<2 {
            let client = CatalogIndexConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
            let result = try await client.run(root: store.root, owner: UUID().uuidString)
            XCTAssertEqual(result, "idle"); client.invalidate()
        }
    }
    @MainActor func testInvalidatedXPCConnectionReturnsError() async throws {
        let listener = NSXPCListener.anonymous(), delegate = CatalogIndexServiceDelegate()
        listener.delegate = delegate; listener.resume()
        let client = CatalogIndexConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        client.invalidate(); listener.invalidate()
        do { _ = try await client.run(root: URL(fileURLWithPath: "/missing"), owner: UUID().uuidString); XCTFail("Disconnected service succeeded") }
        catch {}
        withExtendedLifetime(delegate) {}
    }
    /// iOS has no app XPC services, so the same service runs in the app process there.
    @MainActor func testInProcessReplyAndInvalidation() async throws {
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        try await store.setAnalysisEnabled(false)
        for _ in 0..<2 {
            let client = CatalogIndexConnection(service: CatalogIndexService())
            let result = try await client.run(root: store.root, owner: UUID().uuidString)
            XCTAssertEqual(result, "idle"); client.invalidate()
        }
        let closed = CatalogIndexConnection(service: CatalogIndexService())
        closed.invalidate()
        do { _ = try await closed.run(root: store.root, owner: UUID().uuidString); XCTFail("Invalidated service succeeded") }
        catch {}
    }
}
