import Foundation
import CevicheCore

/// A request finishes exactly once on reply, connection failure, cancellation timeout, or deadline. On macOS batches
/// run in the utility-priority XPC service; on iOS, which has no app XPC services, the same service runs in-process.
@MainActor
final class CatalogIndexConnection {
    private enum Transport {
        case xpc(NSXPCConnection)
        case inProcess(CatalogIndexService)
    }
    private let transport: Transport
    private var pending: CheckedContinuation<String, Error>?
    private var owner: String?

    convenience init() {
        #if os(macOS)
        self.init(connection: NSXPCConnection(serviceName: catalogIndexServiceName))
        #else
        self.init(service: CatalogIndexService())
        #endif
    }
    init(connection: NSXPCConnection) {
        transport = .xpc(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: CatalogIndexServiceProtocol.self)
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.fail(L10n.tr("Index service was interrupted.")) } }
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.fail(L10n.tr("Index service connection closed.")) } }
        connection.activate()
    }
    init(service: CatalogIndexService) { transport = .inProcess(service) }

    func run(root: URL, owner: String) async throws -> String {
        guard pending == nil else { throw EditorError.invalidDocument(L10n.tr("An indexing request is already running.")) }
        self.owner = owner
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            guard let service = service(onError: { [weak self] error in Task { @MainActor in self?.finish(.failure(error)) } })
            else { fail(L10n.tr("Index service interface unavailable.")); return }
            service.processBatch(catalogURL: root, accessBookmarks: FileAccess.shared.transferBookmarks(for: root), owner: owner) { [weak self] outcome, error in
                Task { @MainActor in
                    if let error { self?.fail(error) }
                    else { self?.finish(.success(outcome ?? "idle")) }
                }
            }
        }
    }
    func cancel() {
        guard let owner, pending != nil else { return }
        service(onError: { _ in })?.cancel(owner: owner) {}
    }
    func invalidate(message: String = L10n.tr("Index service connection closed.")) {
        cancel(); fail(message)
        switch transport {
        case .xpc(let connection): connection.invalidate()
        case .inProcess(let service): service.invalidate()
        }
    }
    private func service(onError: @escaping @Sendable (Error) -> Void) -> CatalogIndexServiceProtocol? {
        switch transport {
        case .xpc(let connection): connection.remoteObjectProxyWithErrorHandler(onError) as? CatalogIndexServiceProtocol
        case .inProcess(let service): service
        }
    }
    private func fail(_ message: String) { finish(.failure(EditorError.invalidDocument(message))) }
    private func finish(_ result: Result<String, Error>) {
        guard let pending else { return }
        self.pending = nil; owner = nil; pending.resume(with: result)
    }
}
