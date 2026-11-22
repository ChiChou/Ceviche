import CevicheCore
import AppKit
import SwiftUI

/// Something the app is doing in the background, shown with the title its caller gives it.
struct Activity: Identifiable, Equatable {
    /// What other code asks about ("is an import running?", Stop Export); the text is the title.
    enum Kind: Equatable {
        case importing, exporting, merging, downloading, catalog, editing
    }
    enum Outcome: Equatable { case done(String), stopped, failed(String) }
    /// What Show reveals once the activity is done.
    enum Result: Equatable { case files([URL]), photo(String) }

    let id = UUID()
    let kind: Kind
    var title: String
    /// The current step as the caller words it, such as "3 of 12 - DSC0001.ARW" or "Writing DNG".
    var detail = ""
    /// Items finished so far, out of `total`; `total` is nil while the size is unknown.
    var completed = 0
    var total: Int?
    /// Progress as a fraction, for work that isn't counted in items.
    var progress: Double?
    var stoppable = true
    let started = Date()
    var finished: Date?
    var outcome: Outcome?
    var result: Result?

    var fraction: Double? { progress ?? total.map { $0 > 0 ? Double(completed) / Double($0) : 0 } }
    /// Seconds left, from the pace so far; nil until there is enough to go on.
    func remaining(at now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(started)
        guard let fraction, fraction > 0.03, fraction < 1, elapsed > 3 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }
}

/// Every background activity, shared by every view, so one indicator and one list show them all. Finished activities
/// stay under Recent with their outcome until cleared.
@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()
    @Published private(set) var running: [Activity] = [] {
        didSet { DockProgress.shared.show(running.isEmpty ? nil : running.count == 1 ? running[0].fraction ?? 0 : fraction ?? 0) }
    }
    @Published private(set) var recent: [Activity] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stoppers: [UUID: () -> Void] = [:]
    /// Files an import has claimed, so two imports running together never add the same photo twice.
    private var claimed: Set<String> = []
    /// Opens a merged or imported photo for Show.
    var showPhoto: ((String) -> Void)?

    var isEmpty: Bool { running.isEmpty }
    func contains(_ kind: Activity.Kind) -> Bool { running.contains { $0.kind == kind } }
    /// Combined progress of everything that knows its progress; nil while nothing does.
    var fraction: Double? {
        let known = running.compactMap(\.fraction)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    /// Runs `work` as a new activity. It ends when the work returns: stopped if it was cancelled, otherwise done,
    /// unless the work recorded its own outcome with `finish`.
    @discardableResult
    func start(_ kind: Activity.Kind, title: String, detail: String = "", total: Int? = nil, _ work: @escaping @MainActor (UUID) async -> Void) -> UUID {
        let activity = Activity(kind: kind, title: title, detail: detail, total: total)
        running.append(activity)
        tasks[activity.id] = Task { [weak self] in
            await work(activity.id)
            self?.end(activity.id, outcome: Task.isCancelled ? .stopped : .done(""))
        }
        return activity.id
    }
    /// Shows work the app tracks itself, such as catalog maintenance; `end` finishes it.
    func begin(_ kind: Activity.Kind, title: String, detail: String = "", stop: (() -> Void)? = nil) -> UUID {
        var activity = Activity(kind: kind, title: title, detail: detail)
        activity.stoppable = stop != nil
        running.append(activity)
        stoppers[activity.id] = stop
        return activity.id
    }
    func update(_ id: UUID, completed: Int? = nil, total: Int? = nil, progress: Double? = nil, detail: String? = nil, title: String? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var activity = running[index]
        if let completed { activity.completed = completed }
        if let total { activity.total = total }
        if let progress { activity.progress = max(0, min(1, progress)) }
        if let detail { activity.detail = detail }
        if let title { activity.title = title }
        if activity != running[index] { running[index] = activity }
    }
    /// Records how the activity went, for Recent. The first outcome recorded wins.
    /// `title` replaces the running title for Recent, such as "Panorama merged".
    func finish(_ id: UUID, title: String? = nil, outcome: Activity.Outcome, result: Activity.Result? = nil) {
        guard let index = running.firstIndex(where: { $0.id == id }), running[index].outcome == nil else { return }
        running[index].outcome = outcome; running[index].result = result
        if let title { running[index].title = title }
    }
    func end(_ id: UUID, outcome: Activity.Outcome = .done(""), keep: Bool = true) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var activity = running.remove(at: index)
        tasks[id] = nil; stoppers[id] = nil
        guard keep else { return }
        if activity.outcome == nil { activity.outcome = outcome }
        activity.finished = Date()
        recent.insert(activity, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
    }
    /// Returns once a job from `start` has finished.
    func wait(_ id: UUID) async { await tasks[id]?.value }
    func cancel(_ id: UUID) { tasks[id]?.cancel(); stoppers[id]?() }
    func cancelAll(_ kind: Activity.Kind? = nil) {
        for activity in running where kind == nil || activity.kind == kind { cancel(activity.id) }
    }
    func clearRecent() { recent = [] }
    func show(_ activity: Activity) {
        switch activity.result {
        case .files(let urls): NSWorkspace.shared.showInFinder(urls)
        case .photo(let id): showPhoto?(id)
        case nil: break
        }
    }

    func claim(_ key: String) -> Bool { claimed.insert(key).inserted }
    func release(_ keys: some Sequence<String>) { claimed.subtract(keys) }
}

/// The title bar's view of the activity center: a ring while work runs, filling with its progress (spinning while the
/// size is unknown), and when idle a mark for what finished recently. Clicking opens the full list. Its size never
/// changes, so progress redraws only the ring and never lays out the bar around it, where a menu may be open.
struct ActivityIndicator: View {
    @ObservedObject var center: ActivityCenter
    /// Kept for the narrow title bar; the ring is the same size either way.
    var compact = false
    @State private var showingList = false
    var body: some View {
        Group {
            if let lead = center.running.first {
                Button { showingList.toggle() } label: {
                    ActivityRing(fraction: ActivityRing.step(center.running.count == 1 ? lead.fraction : center.fraction)).equatable()
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(center.running.count == 1 ? lead.title : L10n.tr("\(center.running.count) activities"))
                    .accessibilityLabel(L10n.tr("Activity: \(lead.title)"))
            } else if let last = center.recent.first {
                Button { showingList.toggle() } label: {
                    Image(systemName: last.failed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 14)).foregroundStyle(last.failed ? Theme.error : .secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.tr("Recent activity")).accessibilityLabel(L10n.tr("Recent activity"))
            }
        }
        .popover(isPresented: $showingList, arrowEdge: .bottom) { ActivityList(center: center) }
    }
}

/// Progress as a ring, 16 points across.
struct ActivityRing: View, Equatable {
    let fraction: Double?
    @State private var spin = false
    private let line: CGFloat = 2.5
    /// Whole percents: a file-by-file import redraws the ring a hundred times at most.
    static func step(_ fraction: Double?) -> Double? { fraction.map { (max(0, min(1, $0)) * 100).rounded() / 100 } }
    static func == (a: Self, b: Self) -> Bool { a.fraction == b.fraction }
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: fraction.map { max(0.02, $0) } ?? 0.25)
                .stroke(Theme.controlAccent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90 + (fraction == nil && spin ? 360 : 0)))
                .animation(fraction == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: spin)
                .animation(.easeOut(duration: 0.2), value: fraction)
        }
        .frame(width: 16, height: 16)
        .onAppear { spin = true }
    }
}

/// Everything running, with its step, bar, time left and a stop button, then what finished recently.
struct ActivityList: View {
    @ObservedObject var center: ActivityCenter
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if !center.running.isEmpty {
                    header(L10n.tr("In Progress")) {
                        if center.running.count > 1 { Button(L10n.tr("Stop All")) { center.cancelAll() }.buttonStyle(.secondaryAction).controlSize(.small) }
                    }
                    ForEach(center.running) { RunningRow(activity: $0, now: context.date) { center.cancel($0) } }
                }
                if !center.recent.isEmpty {
                    if !center.running.isEmpty { Rule().padding(.vertical, 6) }
                    header(L10n.tr("Recent")) {
                        Button { center.clearRecent() } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L10n.tr("Clear")).accessibilityLabel(L10n.tr("Clear"))
                    }
                    ForEach(center.recent) { activity in
                        RecentRow(activity: activity, now: context.date) { center.show(activity) }
                    }
                }
                if center.running.isEmpty && center.recent.isEmpty {
                    Text(L10n.tr("Nothing is running.")).font(.callout).foregroundStyle(.secondary).padding(16)
                }
            }.padding(.vertical, 10).frame(width: 360)
        }
    }
    private func header(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }.padding(.horizontal, 14).padding(.bottom, 4)
    }
}

private struct RunningRow: View {
    let activity: Activity
    let now: Date
    let stop: (UUID) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activity.title).font(.callout).lineLimit(1).truncationMode(.middle)
                if !activity.detail.isEmpty {
                    Text(activity.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                ActivityBar(fraction: activity.fraction)
                HStack {
                    if let fraction = activity.fraction { Text(fraction.formatted(.percent.precision(.fractionLength(0)))) }
                    Spacer()
                    Text(timing)
                }.font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            if activity.stoppable {
                Button { stop(activity.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L10n.tr("Stop")).accessibilityLabel(L10n.tr("Stop \(activity.title)"))
            }
        }.padding(.horizontal, 14).padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    private var timing: String {
        let elapsed = Duration.seconds(now.timeIntervalSince(activity.started)).formatted(.time(pattern: .minuteSecond))
        guard let left = activity.remaining(at: now) else { return elapsed }
        return L10n.tr("\(elapsed) - about \(Duration.seconds(left).localized(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
    }
}

private struct RecentRow: View {
    let activity: Activity
    let now: Date
    let show: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint).frame(width: 20).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(summary).font(.caption).foregroundStyle(activity.failed ? Theme.error : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if activity.result != nil { Button(L10n.tr("Show"), action: show).buttonStyle(.textLink).font(.caption) }
        }.padding(.horizontal, 14).padding(.vertical, 5).accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch activity.outcome {
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        default: "checkmark.circle.fill"
        }
    }
    private var tint: Color { activity.failed ? Theme.error : activity.outcome == .stopped ? .secondary : Theme.accent }
    private var summary: String {
        let when = (activity.finished ?? now).localizedRelative()
        switch activity.outcome {
        case .failed(let message): return message
        case .stopped: return L10n.tr("Stopped - \(when)")
        case .done(let text): return text.isEmpty ? L10n.tr("Done - \(when)") : "\(text) - \(when)"
        case nil: return when
        }
    }
}

extension Activity {
    var failed: Bool { if case .failed = outcome { return true } else { return false } }
}

/// The same progress on the app's Dock tile: a bar under the icon while anything runs, gone when idle. Redraws only
/// when the bar would change by a pixel or so.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var shown: Double?
    private lazy var view = TileView()

    func show(_ fraction: Double?) {
        let step = fraction.map { (max(0, min(1, $0)) * 200).rounded() / 200 }
        guard step != shown else { return }
        shown = step
        guard let tile = NSApp?.dockTile else { return }
        if let step {
            view.fraction = step
            if tile.contentView !== view { tile.contentView = view }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    private final class TileView: NSView {
        var fraction = 0.0
        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let inset = bounds.width * 0.1, height = max(6, bounds.height * 0.09)
            let track = NSRect(x: inset, y: bounds.height * 0.08, width: bounds.width - inset * 2, height: height)
            let radius = height / 2
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            let inner = track.insetBy(dx: 1.5, dy: 1.5)
            guard fraction > 0 else { return }
            let fill = NSRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * fraction), height: inner.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fill, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
        }
    }
}

/// A determinate bar when the progress is known, otherwise an indeterminate one.
struct ActivityBar: View {
    let fraction: Double?
    var body: some View {
        Group {
            if let fraction { ProgressView(value: fraction).tint(Theme.accent) } else { ProgressView() }
        }.progressViewStyle(.linear).controlSize(.small)
    }
}
