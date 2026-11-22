import Foundation
import CevicheCore

/// Embeds the open catalog's wall faces and groups them into people in the background (`PeopleIndex`), a batch at a
/// time, once the People model is installed. Woken by new analysis results and by the model arriving.
@MainActor
final class CatalogPeopleGrouper {
    private weak var catalog: CatalogModel?
    private var task: Task<Void, Never>?
    private var idleWait: Task<Void, Error>?
    private var wakeRequested = false
    private var observer: NSObjectProtocol?

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        self.catalog = catalog
        observer = NotificationCenter.default.addObserver(forName: ModelLibrary.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.workAvailable() }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.wakeRequested = false
                let more = await self?.pass() ?? false
                guard let self, !Task.isCancelled else { break }
                if more || self.wakeRequested { continue }
                let wait = Task { try await Task.sleep(for: .seconds(120)) }
                self.idleWait = wait
                _ = await wait.result
                self.idleWait = nil
            }
        }
    }
    func workAvailable() { wakeRequested = true; idleWait?.cancel() }
    func stop() {
        task?.cancel(); idleWait?.cancel(); task = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// One batch; true when there is more to do straight away.
    private func pass() async -> Bool {
        guard let catalog, let store = catalog.store, !store.isReadOnly else { return false }
        do {
            let outcome = try await PeopleIndex.run(store: store)
            guard catalog.store === store else { return false }
            let progress = try? await store.embeddingProgress()
            catalog.peopleStatus = CatalogModel.PeopleStatus(available: outcome != .unavailable, waiting: progress?.waiting ?? 0,
                                                             generation: catalog.peopleStatus.generation + (outcome == .idle || outcome == .unavailable ? 0 : 1))
            if case .progressed = outcome { return true }
            return false
        } catch {
            return false
        }
    }
}
