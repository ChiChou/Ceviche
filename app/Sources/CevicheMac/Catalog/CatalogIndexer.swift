import AppKit
import CevicheCore

/// Consumes bounded batches in the utility-priority XPC service, independently of preview rendering.
@MainActor
final class CatalogIndexer {
    private weak var catalog: CatalogModel?
    private var idleWait: Task<Void, Error>?
    private var wakeRequested = false
    private let pollInterval: Duration
    private let makeConnection: @MainActor () -> CatalogIndexConnection
    private var task: Task<Void, Never>?
    private var connection: CatalogIndexConnection?
    private var interrupted = false
    private var launchRetryAt = Date.distantPast
    private var shuttingDown = false

    init(pollInterval: Duration = .seconds(1), makeConnection: @escaping @MainActor () -> CatalogIndexConnection = { CatalogIndexConnection() }) {
        self.pollInterval = pollInterval; self.makeConnection = makeConnection
    }
    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        self.catalog = catalog; shuttingDown = false
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.wakeRequested = false
                let more = await self?.tick() == true
                guard let self, !Task.isCancelled else { break }
                if more || self.wakeRequested { continue }
                let wait = Task { try await Task.sleep(for: self.pollInterval) }
                self.idleWait = wait
                _ = await wait.result
                self.idleWait = nil
            }
        }
    }
    func cancelCurrent() {
        guard let connection, !interrupted else { return }
        interrupted = true; connection.cancel()
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let connection, self.connection === connection else { return }
            connection.invalidate(message: L10n.tr("Indexing interrupted for a catalog change."))
        }
    }
    /// A newly opened catalog starts indexing immediately rather than after the previous one's retry delay.
    func catalogChanged() { cancelCurrent(); workAvailable() }
    /// Wake an idle worker without cancelling an in-flight batch or waiting for the next poll.
    func workAvailable() {
        launchRetryAt = .distantPast; wakeRequested = true; idleWait?.cancel()
    }
    func stop() {
        shuttingDown = true; task?.cancel(); idleWait?.cancel(); task = nil
        interrupted = true; connection?.invalidate(message: L10n.tr("App is stopping."))
    }
    /// True means there is more ready work: start the next batch immediately.
    private func tick() async -> Bool {
        guard !shuttingDown, let catalog, let store = catalog.store, !store.isReadOnly else { return false }
        do {
            let status = try await store.analysisStatus()
            guard catalog.store === store, !shuttingDown else { return false }
            let changed = catalog.indexing.generation != status.generation
            catalog.updateIndexing(status)
            // New tags and faces change which photos match only a filter that looks at them.
            if changed, catalog.filter.followsAnalysis { await catalog.refresh() }
            guard catalog.store === store, !shuttingDown else { return false }
            // Catalog maintenance can explicitly suspend claims; preview rendering never does.
            guard status.enabled else { return false }
            if status.remaining == 0 {
                catalog.updateIndexing(status, message: status.failed > 0 ? (status.failed == 1 ? L10n.tr("\(status.failed) photo couldn’t be analyzed.") : L10n.tr("\(status.failed) photos couldn’t be analyzed.")) : L10n.tr("All photos are analyzed."))
                return false
            }
            if status.ready == 0 { catalog.updateIndexing(status, message: L10n.tr("Waiting to try again.")); return false }
            guard Date() >= launchRetryAt else { return false }
            catalog.indexingMessage = L10n.tr("Analyzing photos to suggest tags.")
            let owner = UUID().uuidString
            interrupted = false
            do {
                let outcome = try await run(store: store, owner: owner)
                try await store.failAnalysis(owner: owner, message: L10n.tr("Index service returned \(outcome)."), interrupted: interrupted)
            } catch {
                try await store.failAnalysis(owner: owner, message: error.localizedDescription, interrupted: interrupted)
                if !interrupted {
                    launchRetryAt = Date().addingTimeInterval(30)
                    catalog.indexingMessage = L10n.tr("Will try again: ") + error.localizedDescription
                }
            }
            if catalog.store === store, !shuttingDown {
                catalog.updateIndexing(try await store.analysisStatus())
                await catalog.indexingCompletedPhotos()
                return catalog.indexing.ready > 0 && !interrupted && Date() >= launchRetryAt
            }
        } catch {
            catalog.indexingMessage = L10n.tr("Will try again: ") + error.localizedDescription
            launchRetryAt = Date().addingTimeInterval(30)
        }
        return false
    }
    private func run(store: CatalogStore, owner: String) async throws -> String {
        let client = makeConnection(); connection = client
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            client.invalidate(message: L10n.tr("Index service timed out; retrying later."))
        }
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let catalog = self.catalog else { return }
                guard catalog.store === store, !self.shuttingDown else { self.cancelCurrent(); return }
                if let status = try? await store.analysisStatus(), catalog.store === store, !Task.isCancelled {
                    let completed = status.complete != catalog.indexing.complete
                    catalog.updateIndexing(status, message: L10n.tr("Analyzing photos to suggest tags."))
                    if completed { await catalog.indexingCompletedPhotos() }
                }
            }
        }
        defer { timeout.cancel(); progress.cancel(); connection = nil; client.invalidate() }
        return try await client.run(root: store.root, owner: owner)
    }
}
