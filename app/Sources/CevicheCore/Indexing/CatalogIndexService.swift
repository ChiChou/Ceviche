import Foundation
import Vision

public let catalogIndexServiceName = Bundle.main.object(forInfoDictionaryKey: "CevicheIndexServiceIdentifier") as? String ?? "me.chichou.ceviche.indexer"

/// Explicit XPC messages; no shell arguments, image buffers, or executable discovery.
@objc(CevicheIndexServiceProtocol)
public protocol CatalogIndexServiceProtocol {
    func processBatch(catalogURL: URL, accessBookmarks: [Data], owner: String, withReply reply: @escaping (String?, String?) -> Void)
    func cancel(owner: String, withReply reply: @escaping () -> Void)
}

/// Propagates cancellation through hashing boundaries and into a synchronous Vision request.
public final class CatalogAnalysisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var requests: [ObjectIdentifier: VNRequest] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func check() throws { if isCancelled { throw CancellationError() } }
    public func cancel() {
        let active = lock.withLock { cancelled = true; return Array(requests.values) }
        active.forEach { $0.cancel() }
    }
    func addRequest(_ value: VNRequest) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            requests[ObjectIdentifier(value)] = value
        }
    }
    func removeRequest(_ value: VNRequest) { _ = lock.withLock { requests.removeValue(forKey: ObjectIdentifier(value)) } }
}

/// One instance per connection. Connection invalidation cancels only that client's work.
public final class CatalogIndexService: NSObject, CatalogIndexServiceProtocol, @unchecked Sendable {
    private static let gate = CatalogIndexWorkGate()
    private let lock = NSLock()
    private var active: (String, CatalogAnalysisCancellation)?
    private var invalidated = false
    public func processBatch(catalogURL: URL, accessBookmarks: [Data], owner: String, withReply reply: @escaping (String?, String?) -> Void) {
        let cancellation = CatalogAnalysisCancellation()
        let accepted = lock.withLock {
            guard !invalidated, active == nil, Self.gate.acquire() else { return false }
            active = (owner, cancellation); return true
        }
        guard accepted else { reply(nil, L10n.tr("Index service is already busy or disconnected.")); return }
        Task.detached(priority: CatalogIndexWorker.priority) { [self] in
            let access = accessBookmarks.compactMap { data -> URL? in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
                      url.startAccessingSecurityScopedResource() else { return nil }
                return url
            }
            defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
            var outcome: String?, failure: String?
            do {
                try cancellation.check()
                let store = try CatalogStore(root: catalogURL, existingOnly: true)
                outcome = try await CatalogIndexWorker.runBatch(store: store, owner: owner, cancellation: cancellation).rawValue
            } catch is CancellationError { outcome = "cancelled" }
            catch { failure = error.localizedDescription }
            lock.withLock { active = nil }
            Self.gate.release()
            reply(outcome, failure)
        }
    }
    public func cancel(owner: String, withReply reply: @escaping () -> Void) {
        let cancellation = lock.withLock { active?.0 == owner ? active?.1 : nil }
        cancellation?.cancel(); reply()
    }
    public func invalidate() {
        let cancellation = lock.withLock { invalidated = true; return active?.1 }
        cancellation?.cancel()
    }
}

public final class CatalogIndexServiceDelegate: NSObject, NSXPCListenerDelegate {
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = CatalogIndexService()
        connection.exportedInterface = NSXPCInterface(with: CatalogIndexServiceProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.invalidate() }
        connection.interruptionHandler = { service.invalidate() }
        connection.activate()
        return true
    }
}

/// A disconnected request may still be unwinding; prevent overlapping batches from exceeding the concurrency limit.
private final class CatalogIndexWorkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    func acquire() -> Bool { lock.withLock { if occupied { return false }; occupied = true; return true } }
    func release() { lock.withLock { occupied = false } }
}
