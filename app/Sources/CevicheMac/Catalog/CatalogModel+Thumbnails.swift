import CevicheCore
import Foundation

/// The tickets behind the "Updating thumbnails" row: however many jobs hand photos to the thumbnail queue, one row
/// shows them all, and Stop drops them all.
struct ThumbnailJob {
    let row: UUID
    let store: CatalogStore
    var progress: [ThumbnailReactor.Ticket: (done: Int, total: Int)] = [:]
    var stopped = false
}

extension CatalogModel {
    /// Thumbnails showing the new edits of photos a job changed, after the job.
    func updateThumbnails(_ ids: [String], store: CatalogStore) {
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            let ticket = await store.thumbnails.want(ids, kind: .developed, priority: .batch)
            await self?.trackThumbnails(ticket, store: store)
        }
    }
    /// Shows `ticket` in the "Updating thumbnails" row until it is done, so its work can be seen and stopped there.
    private func trackThumbnails(_ ticket: ThumbnailReactor.Ticket, store: CatalogStore) async {
        guard ticket.total > 0, self.store === store else { return }
        if thumbnailJob?.store !== store {
            let row = activity.begin(.editing, title: L10n.tr("Updating thumbnails")) { [weak self] in self?.stopThumbnailJob() }
            thumbnailJob = ThumbnailJob(row: row, store: store)
        }
        thumbnailJob?.progress[ticket] = (0, ticket.total)
        showThumbnailJob()
        _ = await store.thumbnails.wait(ticket) { [weak self] done, total in
            await MainActor.run {
                guard let self, self.thumbnailJob?.progress[ticket] != nil else { return }
                self.thumbnailJob?.progress[ticket] = (done, total); self.showThumbnailJob()
            }
        }
        guard var job = thumbnailJob, job.store === store else { return }
        job.progress[ticket] = nil
        // The row stays until every ticket behind it is done.
        if job.progress.values.allSatisfy({ $0.done >= $0.total }) {
            activity.end(job.row, outcome: job.stopped ? .stopped : .done(""))
            thumbnailJob = nil
        } else { thumbnailJob = job; showThumbnailJob() }
    }
    private func showThumbnailJob() {
        guard let job = thumbnailJob else { return }
        let done = job.progress.values.reduce(0) { $0 + $1.done }, total = job.progress.values.reduce(0) { $0 + $1.total }
        activity.update(job.row, completed: done, total: total)
    }
    private func stopThumbnailJob() {
        guard let job = thumbnailJob else { return }
        thumbnailJob?.stopped = true
        let tickets = Array(job.progress.keys)
        Task { await job.store.thumbnails.cancel(tickets) }
    }
    /// Edited photos whose thumbnail is out of date get theirs in the background, a little after the catalog opens
    /// or changes from another Mac. A library imported with thousands of XMP edits renders for a long time, so the work
    /// shows in the activity center, where Stop ends it until the catalog next opens.
    func scheduleThumbnailCatchUp(for store: CatalogStore, after delay: Duration = .seconds(10)) {
        thumbnailCatchUpTask?.cancel()
        thumbnailCatchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.store === store, !self.isFolderIndex else { return }
            guard let ticket = await store.thumbnails.catchUp() else { return }
            await self.trackThumbnails(ticket, store: store)
        }
    }
    /// Photos on screen, and a screen either side, whose thumbnail doesn't show their edits yet get one ahead of other
    /// work: the way a library on a network share gets its edited thumbnails, since the catch-up leaves it alone.
    /// Photos scrolled away from are dropped, though a render already started finishes.
    func developOnScreen(_ ids: [String]) {
        guard let store, !isFolderIndex else { return }
        onScreenGeneration += 1
        let generation = onScreenGeneration, previous = onScreenTicket
        onScreenTicket = nil
        Task {
            if let previous { await store.thumbnails.cancel(previous) }
            guard !ids.isEmpty, generation == self.onScreenGeneration, self.store === store else { return }
            self.onScreenTicket = await store.thumbnails.want(ids, kind: .developed, priority: .visible)
        }
    }
    /// Stops all thumbnail work for a catalog being closed or replaced.
    func stopThumbnails(of store: CatalogStore) {
        thumbnailCatchUpTask?.cancel(); thumbnailCatchUpTask = nil
        onScreenGeneration += 1; onScreenTicket = nil
        if let job = thumbnailJob, job.store === store { activity.end(job.row, outcome: .stopped); thumbnailJob = nil }
        Task { await store.thumbnails.shutdown() }
    }
}
