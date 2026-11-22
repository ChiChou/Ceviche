import Foundation
import GRDB

/// The one queue for a catalog's Library thumbnails. Callers say which photos they want up to date (`want`); the
/// reactor reads the catalog before each step to see what a photo still needs, so a photo asked for twice is done
/// once, one whose thumbnail someone else made meanwhile costs nothing, and one edited again while it rendered is
/// rendered again with its new edits rather than finishing with the old ones.
///
/// Two lanes run side by side: camera previews, which are mostly disk reads, and renders (a full decode of the
/// original), a few at a time at low priority. Within a lane the highest priority goes first, then first asked.
///
/// A ticket stands for one request. Cancelling it drops the photos no other ticket wants, abandoning their work
/// in progress at its next step: a render already started runs to its end, since the decoder can't be interrupted.
public actor ThumbnailReactor {
    /// `.preview` wants any thumbnail, the camera's own if it has one. `.developed` wants one showing the photo's
    /// current edits.
    public enum Kind: Sendable { case preview, developed }
    public enum Priority: Int, Sendable, Comparable, CaseIterable {
        /// Catching up thumbnails nobody is waiting for.
        case background
        /// Photos a job changed, such as Paste Edits.
        case batch
        /// Photos on screen.
        case visible
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Outcome: Sendable, Equatable {
        /// A new thumbnail was stored.
        case installed
        /// The thumbnail was already up to date.
        case current
        /// The original is out of reach (offline, not downloaded, changed) or the photo is in Trash.
        case skipped
        case failed
    }
    public struct Progress: Sendable, Equatable {
        public var done: Int, total: Int
        public var outcomes: [String: Outcome]
        public var finished: Bool { done >= total }
    }
    public struct Ticket: Sendable, Hashable {
        public let id: UUID
        public let total: Int
        let updates: AsyncStream<Progress>
        public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// One thing done to one photo.
    public enum Step: Sendable, Equatable {
        /// The preview the camera stored in the file.
        case embedded
        /// A decode of the original, for a file with no usable preview.
        case decode
        /// A render with the photo's edits.
        case develop
    }
    public enum StepResult: Sendable, Equatable { case installed, noPreview, unavailable, failed }
    public typealias Work = @Sendable (_ step: Step, _ asset: CatalogAsset, _ store: CatalogStore) async throws -> StepResult

    enum Lane: CaseIterable { case preview, render }

    private final class Entry {
        let id: String
        var kinds: Set<Kind> = []
        var demand: [UUID: Priority] = [:]
        let order: Int
        var triedEmbedded = false, triedDecode = false, installed = false
        /// The render key last developed, so a render that did not take is not repeated forever.
        var developedKey: String?
        /// The lane it waits in, nil while it runs.
        var waiting: Lane?
        var task: Task<Void, Never>?
        init(id: String, order: Int) { self.id = id; self.order = order }
        var priority: Priority { demand.values.max() ?? .background }
    }
    private final class TicketState {
        var ids: Set<String>
        var outcomes: [String: Outcome] = [:]
        let continuation: AsyncStream<Progress>.Continuation
        init(ids: Set<String>, continuation: AsyncStream<Progress>.Continuation) { self.ids = ids; self.continuation = continuation }
        var progress: Progress { Progress(done: outcomes.count, total: ids.count, outcomes: outcomes) }
    }

    private weak var store: CatalogStore?
    private let work: Work
    private let widths: [Lane: Int]
    private var entries: [String: Entry] = [:]
    private var tickets: [UUID: TicketState] = [:]
    /// Waiting photos per lane and priority, first asked first. An entry raised to a higher priority is queued again
    /// there; its old place is skipped when reached.
    private var queues: [Lane: [Priority: [Entry]]] = [:]
    private var heads: [Lane: [Priority: Int]] = [:]
    private var running: [Lane: Int] = [:]
    private var nextOrder = 0
    private var holds: [ObjectIdentifier: (held: Bool, sequence: Int)] = [:]
    private var closed = false

    public init(store: CatalogStore, previewWidth: Int = CatalogFolders.defaultWidth, renderWidth: Int = ThumbnailReactor.renderWidth,
                work: @escaping Work = ThumbnailReactor.perform) {
        self.store = store
        self.work = work
        widths = [.preview: max(1, previewWidth), .render: max(1, renderWidth)]
    }
    /// Renders at once: the RAW decoder is mostly single-threaded per photo, so a few in parallel use the Mac's cores
    /// without crowding the editor and the grid.
    public static let renderWidth = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// Renders nobody waits for (catching up after an import or sync) run one at a time. Each decodes a whole RAW,
    /// up to a gigabyte of memory, and reads its original in full: six at once kept a 5,000-photo library on a network
    /// share at 150 MB/s and 4 GB for half an hour. Photos on screen and batch jobs still use the whole lane.
    public static let backgroundRenderWidth = 1
    private var backgroundRenders = 0

    // MARK: Requests

    /// Asks for `ids` to have an up-to-date thumbnail of `kind`. Follow the ticket with `wait`, or let it run.
    @discardableResult
    public func want(_ ids: some Sequence<String>, kind: Kind, priority: Priority) -> Ticket {
        // In the order asked, so a grid fills from the top.
        var seen = Set<String>()
        let ordered = ids.filter { seen.insert($0).inserted }
        let unique = seen
        let (stream, continuation) = AsyncStream.makeStream(of: Progress.self, bufferingPolicy: .bufferingNewest(1))
        let ticket = Ticket(id: UUID(), total: unique.count, updates: stream)
        let state = TicketState(ids: unique, continuation: continuation)
        tickets[ticket.id] = state
        if closed { for id in unique { state.outcomes[id] = .skipped } }
        else {
            for id in ordered {
                let entry: Entry
                if let existing = entries[id] { entry = existing } else {
                    entry = Entry(id: id, order: nextOrder); nextOrder += 1; entries[id] = entry
                }
                let previous = entry.demand.isEmpty ? nil : entry.priority
                entry.kinds.insert(kind); entry.demand[ticket.id] = priority
                if entry.task == nil {
                    // A waiting entry moves up when raised; a new one starts in the lane of what it most likely needs.
                    if let lane = entry.waiting {
                        if let previous, entry.priority <= previous {} else { enqueue(entry, lane) }
                    } else { enqueue(entry, entry.kinds.contains(.developed) ? .render : .preview) }
                }
            }
        }
        report(ticket.id, state)
        pump()
        return ticket
    }
    /// Drops the ticket: its photos that no other ticket wants leave the queue, and their work stops at its next step.
    public func cancel(_ ticket: Ticket) { cancel(ticket.id) }
    public func cancel(_ tickets: some Sequence<Ticket>) { for ticket in tickets { cancel(ticket.id) } }
    private func cancel(_ ticketID: UUID) {
        guard let state = tickets.removeValue(forKey: ticketID) else { return }
        for id in state.ids where state.outcomes[id] == nil {
            guard let entry = entries[id] else { continue }
            entry.demand[ticketID] = nil
            if entry.demand.isEmpty { entries[id] = nil; entry.task?.cancel(); entry.waiting = nil }
        }
        state.continuation.finish()
    }
    /// Stops everything, for a catalog being closed. Later requests finish at once as skipped.
    public func shutdown() {
        closed = true
        for id in Array(tickets.keys) { cancel(id) }
    }
    /// While any owner holds them, no new render starts (camera previews go on), so the editor has the Mac to itself
    /// during a drag. `sequence` grows with each call from an owner, so a release that arrives before its hold wins.
    public func holdRenders(_ hold: Bool, by owner: ObjectIdentifier, sequence: Int) {
        guard sequence > (holds[owner]?.sequence ?? .min) else { return }
        holds[owner] = (hold, sequence)
        if !rendersHeld { pump() }
    }
    private var rendersHeld: Bool { holds.values.contains { $0.held } }
    /// Follows `tickets` to the end, giving their combined progress. Cancelling the caller cancels the tickets.
    public nonisolated func wait(_ tickets: [Ticket], progress: (@Sendable (_ done: Int, _ total: Int) async -> Void)? = nil) async -> [String: Outcome] {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                let combined = Combined(count: tickets.count)
                for (index, ticket) in tickets.enumerated() {
                    group.addTask {
                        for await update in ticket.updates {
                            let (done, total) = combined.set(index, update)
                            await progress?(done, total)
                        }
                    }
                }
                await group.waitForAll()
                return combined.outcomes
            }
        } onCancel: {
            Task { await self.cancel(tickets) }
        }
    }
    public nonisolated func wait(_ ticket: Ticket, progress: (@Sendable (_ done: Int, _ total: Int) async -> Void)? = nil) async -> [String: Outcome] {
        await wait([ticket], progress: progress)
    }
    /// Edited photos whose thumbnail does not show their edits, such as edits that arrived from another Mac or
    /// whose original was offline when they were made, at background priority. Only originals on this Mac's own disk:
    /// a library on a network share or an external drive (thousands of Lightroom edits read in full over the network)
    /// gets its renders as the grid shows them, at `.visible`.
    @discardableResult
    public func catchUp() async -> Ticket? {
        guard let store, !closed, let ids = try? await store.undevelopedAssetIDs(onThisMac: true), !ids.isEmpty else { return nil }
        return want(ids, kind: .developed, priority: .background)
    }

    // MARK: Running

    private func enqueue(_ entry: Entry, _ lane: Lane) {
        entry.waiting = lane
        queues[lane, default: [:]][entry.priority, default: []].append(entry)
    }
    /// The next entry of `lane`, leaving background ones waiting unless `background`.
    private func dequeue(_ lane: Lane, background: Bool = true) -> Entry? {
        for priority in Priority.allCases.reversed() where background || priority != .background {
            guard var queue = queues[lane]?[priority], !queue.isEmpty else { continue }
            var head = heads[lane]?[priority] ?? 0
            defer {
                // Compact once the consumed front outgrows the rest.
                if head > 256, head * 2 > queue.count { queue.removeFirst(head); head = 0 }
                queues[lane]![priority] = queue; heads[lane, default: [:]][priority] = head
            }
            while head < queue.count {
                let entry = queue[head]; head += 1
                // Skipped: cancelled, already running, moved lanes, or queued again at a higher priority.
                guard entries[entry.id] === entry, entry.waiting == lane, entry.task == nil, entry.priority == priority else { continue }
                return entry
            }
        }
        return nil
    }
    private func pump() {
        guard !closed else { return }
        for lane in Lane.allCases where lane != .render || !rendersHeld {
            while running[lane, default: 0] < widths[lane]!,
                  let entry = dequeue(lane, background: lane != .render || backgroundRenders < Self.backgroundRenderWidth) {
                running[lane, default: 0] += 1
                entry.waiting = nil
                let background = lane == .render && entry.priority == .background
                if background { backgroundRenders += 1 }
                entry.task = Task(priority: lane == .render ? .utility : .userInitiated) { await self.run(entry, in: lane, background: background) }
            }
        }
    }
    private func run(_ entry: Entry, in lane: Lane, background: Bool) async {
        defer { running[lane, default: 1] -= 1; if background { backgroundRenders -= 1 }; entry.task = nil; pump() }
        while entries[entry.id] === entry, !Task.isCancelled, let store {
            guard let asset = try? await store.asset(entry.id) else { finish(entry, .skipped); return }
            guard entries[entry.id] === entry, !Task.isCancelled else { return }
            let step: Step
            switch next(entry, asset) {
            case .finish(let outcome): finish(entry, outcome); return
            case .step(let chosen): step = chosen
            }
            // A decode or render found in the preview lane waits its turn in the render lane.
            if lane == .preview, step != .embedded { entry.task = nil; enqueue(entry, .render); return }
            switch step {
            case .embedded: entry.triedEmbedded = true
            case .decode: entry.triedDecode = true
            case .develop: entry.developedKey = asset.renderKey
            }
            let result: StepResult
            do { result = try await work(step, asset, store) } catch is CancellationError { return } catch { result = .failed }
            guard entries[entry.id] === entry else { return }
            switch result {
            case .installed: entry.installed = true
            case .noPreview: break
            case .unavailable: finish(entry, .skipped); return
            case .failed: finish(entry, .failed); return
            }
        }
    }
    private enum Plan { case step(Step), finish(Outcome) }
    /// What a photo needs next, from what the catalog says now.
    private func next(_ entry: Entry, _ asset: CatalogAsset) -> Plan {
        if asset.area == .trash { return .finish(.skipped) }
        let developed = entry.kinds.contains(.developed)
        if asset.thumbnailKey == nil {
            // The camera's preview shows in moments, ahead of a render that takes longer.
            if !entry.triedEmbedded { return .step(.embedded) }
            // A render makes a thumbnail anyway.
            if !developed && !entry.triedDecode { return .step(.decode) }
        }
        if developed, asset.thumbnailKey == nil || asset.thumbnailRenderKey != asset.renderKey {
            return entry.developedKey == asset.renderKey ? .finish(.failed) : .step(.develop)
        }
        if asset.thumbnailKey == nil { return .finish(.failed) }
        return .finish(entry.installed ? .installed : .current)
    }
    private func finish(_ entry: Entry, _ outcome: Outcome) {
        guard entries[entry.id] === entry else { return }
        entries[entry.id] = nil
        for ticketID in entry.demand.keys {
            guard let state = tickets[ticketID] else { continue }
            state.outcomes[entry.id] = outcome
            report(ticketID, state)
        }
    }
    private func report(_ ticketID: UUID, _ state: TicketState) {
        state.continuation.yield(state.progress)
        if state.progress.finished { state.continuation.finish(); tickets[ticketID] = nil }
    }

    // MARK: Work

    /// The real steps: the original's camera preview or decode stored as a preview thumbnail, or a render with the
    /// saved edits stored for the render key it was made from.
    public static let perform: Work = { step, asset, store in
        try Task.checkCancellation()
        guard let url = asset.availability(catalog: store.root).localURL else { return .unavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if asset.isLatent {
            let data = try Data(contentsOf: url.appendingPathComponent("thumbnail.jpg"))
            try Task.checkCancellation()
            try await store.installThumbnail(data, assetID: asset.id, renderKey: asset.renderKey)
            return .installed
        }
        switch step {
        case .embedded, .decode:
            guard let data = CatalogImporter.thumbnail(of: url, embeddedOnly: step == .embedded) else { return step == .embedded ? .noPreview : .failed }
            try Task.checkCancellation()
            try await store.installPreviewThumbnail(data, assetID: asset.id)
            return .installed
        case .develop:
            guard try CatalogImporter.matches(url, asset) else { return .unavailable }
            let (renderer, defaults) = try RawRenderer.open(url, hdr: asset.hdr)
            let settings = try await store.savedAdjustments(of: asset) ?? defaults
            try Task.checkCancellation()
            let data = try await renderer.thumbnail(settings)
            try Task.checkCancellation()
            try await store.installThumbnail(data, assetID: asset.id, renderKey: asset.renderKey)
            return .installed
        }
    }
}

/// Progress of several tickets added up, for `wait`.
private final class Combined: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [ThumbnailReactor.Progress?]
    init(count: Int) { parts = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ progress: ThumbnailReactor.Progress) -> (Int, Int) {
        lock.withLock {
            parts[index] = progress
            return parts.reduce((0, 0)) { ($0.0 + ($1?.done ?? 0), $0.1 + ($1?.total ?? 0)) }
        }
    }
    var outcomes: [String: ThumbnailReactor.Outcome] {
        lock.withLock { parts.reduce(into: [:]) { $0.merge($1?.outcomes ?? [:]) { _, new in new } } }
    }
}

extension CatalogStore {
    /// The thumbnail queue of this catalog.
    public nonisolated var thumbnails: ThumbnailReactor {
        thumbnailReactor.withLock { reactor in
            if let reactor { return reactor }
            let made = ThumbnailReactor(store: self); reactor = made; return made
        }
    }
    /// Edited photos, outside Trash, whose thumbnail does not show their edits.
    /// `onThisMac` leaves out originals on a network share or another volume.
    public func undevelopedAssetIDs(onThisMac: Bool = false) throws -> [String] {
        try database.read { db in
            let edited = SQL("asset.id IN (SELECT assetID FROM assetDevelopment WHERE adjustmentsData IS NOT NULL)").sqlExpression
            let stale = Columns.thumbnailRenderKey == nil || Columns.thumbnailRenderKey != Columns.renderKey
            var request = CatalogAsset.filter(Columns.trashedAt == nil && stale && edited)
            if onThisMac {
                request = request.filter(sql: "origin NOT LIKE ? AND origin NOT LIKE ?",
                                         arguments: [AssetLocator.Scheme.smb.rawValue + ":%", AssetLocator.Scheme.volume.rawValue + ":%"])
            }
            return try String.fetchAll(db, request.select(Columns.id).order(Columns.importedAt.desc))
        }
    }
}
