import Combine
import Foundation
import CevicheCore

/// Measures photos (`PhotoQualityAnalyzer`) in the background, one catalog at a time, and saves each report to the
/// catalog as it lands. Imported photos queue here after each import, so the culling tools usually open on photos
/// already measured; Pick from Bursts, Find Flawed Photos and Tidy Pairs put their own photos first and take more
/// workers, and closing them withdraws the photos they added that are still waiting. The activity center shows the work
/// with a stop button.
@MainActor
final class CullingScanner {
    /// One photo done: its report, or why it couldn't be measured.
    struct Measured {
        let assetID: String
        let report: CatalogCullingReport?
        let failure: String?
    }
    /// Every photo as it lands, for an open assistant to merge in.
    let measured = PassthroughSubject<Measured, Never>()
    /// Two workers in the background beside tagging and rendering; four while someone waits in the assistant.
    var urgent = false { didSet { pump() } }
    /// Photos waiting or being measured.
    var remaining: Int { queue.count + running }
    private var store: CatalogStore?
    private var root: URL?
    private var queue: [CatalogAsset] = []
    private var queued: Set<String> = []
    private var running = 0
    private var job: UUID?
    private var done = 0, total = 0
    private let activity: ActivityCenter
    init(activity: ActivityCenter) { self.activity = activity }

    /// Queues the photos not already waiting; `first` moves them all to the front of the queue. Returns the photos it
    /// added, which the caller can `withdraw` again; photos that were already waiting stay the earlier caller's.
    @discardableResult
    func enqueue(_ assets: [CatalogAsset], store: CatalogStore, root: URL?, first: Bool) -> Set<String> {
        if self.store !== store { reset(); self.store = store }
        self.root = root
        let ids = Set(assets.map(\.id))
        let fresh = assets.filter { !queued.contains($0.id) }
        if first {
            let waiting = queue.filter { ids.contains($0.id) }
            queue.removeAll { ids.contains($0.id) }
            queue.insert(contentsOf: waiting + fresh, at: 0)
        } else {
            queue += fresh
        }
        queued.formUnion(fresh.map(\.id))
        total += fresh.count
        pump()
        return Set(fresh.map(\.id))
    }
    /// Drops what is waiting; photos already being measured still finish and are saved.
    func stop() { withdraw(Set(queue.map(\.id))) }
    /// Drops the waiting photos among `ids`: a culling window closed before they were measured. Photos already being
    /// measured still finish and are saved.
    func withdraw(_ ids: Set<String>) {
        let dropped = queue.filter { ids.contains($0.id) }
        guard !dropped.isEmpty else { return }
        queue.removeAll { ids.contains($0.id) }
        dropped.forEach { queued.remove($0.id) }
        total -= dropped.count
        guard let job else { return }
        if queue.isEmpty && running == 0 { finish(job) } else { activity.update(job, completed: done, total: total) }
    }
    private func finish(_ job: UUID) {
        activity.end(job, outcome: .done(done == 1 ? L10n.tr("1 photo measured") : L10n.tr("\(done.formatted()) photos measured")), keep: false)
        self.job = nil; done = 0; total = 0
    }
    /// A different catalog opened, or this one closed.
    func reset() {
        queue = []; queued = []; store = nil; running = 0
        if let job { activity.end(job, outcome: .stopped, keep: false) }
        job = nil; done = 0; total = 0
    }

    private func pump() {
        guard let store else { return }
        while running < (urgent ? 4 : 2), !queue.isEmpty {
            let asset = queue.removeFirst()
            running += 1
            if job == nil {
                job = activity.begin(.catalog, title: L10n.tr("Measuring photos for culling")) { [weak self] in self?.stop() }
            }
            let root = self.root, priority: TaskPriority = urgent ? .userInitiated : .utility
            Task {
                let result = await Self.measure(asset, store: store, root: root, priority: priority)
                guard store === self.store else { return }
                running -= 1; done += 1; queued.remove(asset.id)
                if let job { activity.update(job, completed: done, total: total, detail: asset.filename) }
                measured.send(result)
                if queue.isEmpty && running == 0, let job { finish(job) }
                pump()
            }
        }
    }
    /// Offline originals and ones still in the cloud are skipped: culling never downloads a library.
    nonisolated private static func measure(_ asset: CatalogAsset, store: CatalogStore, root: URL?, priority: TaskPriority) async -> Measured {
        guard case .available(let url) = asset.availability(catalog: root) else {
            return Measured(assetID: asset.id, report: nil, failure: L10n.tr("The original isn’t on this Mac."))
        }
        let result = await Task.detached(priority: priority) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            return Result { try autoreleasepool { try PhotoQualityAnalyzer.analyze(url) } }
        }.value
        switch result {
        case .success(let measured):
            try? await store.saveCullingReport(measured.report, featurePrint: measured.featurePrint, for: asset)
            return Measured(assetID: asset.id, report: CatalogCullingReport(assetID: asset.id, report: measured.report, featurePrint: measured.featurePrint), failure: nil)
        case .failure(let error):
            return Measured(assetID: asset.id, report: nil, failure: error.localizedDescription)
        }
    }
}
