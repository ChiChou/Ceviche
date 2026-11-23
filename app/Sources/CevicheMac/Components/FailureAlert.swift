import CevicheCore
import SwiftUI
import AppKit

/// Something the person asked for that failed, or only partly worked, and that they must not miss: shown in a blocking
/// alert, unlike `error`, which is a toast for background or self-evident failures.
struct Failure: Identifiable, Equatable {
    let id = UUID()
    /// What didn't happen, as an alert title: "Couldn’t Export", "Some Photos Weren’t Deleted".
    let title: String
    let message: String
    /// Ways out the alert offers beside OK, such as Reset Unreadable and Reset Edits for edits that can't be read.
    var actions: [Action]
    struct Action { let title: String; let destructive: Bool; let run: @MainActor () -> Void }
    /// One file of a batch that failed, listed in full under the message so it can be selected, copied and found.
    struct Detail: Equatable {
        /// The full path, or where the file is when it isn't on this Mac (a camera, an unmounted volume).
        let path: String
        let reason: String
        /// The file on this Mac, for Show in Finder.
        var url: URL? = nil
    }
    /// Every failed file, shown as a list in the alert in place of a few names in the message.
    var details: [Detail] = []

    init(_ title: String, _ message: String, actions: [Action] = []) { self.title = title; self.message = message; self.actions = actions }
    init(_ title: String, _ error: Error) { self.init(title, error.localizedDescription) }
    /// A batch that partly failed: `summary` ("3 photos couldn’t be exported."), if any, then the first eight of `items`.
    init(_ title: String, summary: String, items: [String]) {
        let shown = items.prefix(8).joined(separator: "\n") + (items.count > 8 ? "\n…" : "")
        self.init(title, [summary, shown].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
    /// A batch that partly failed, with every file listed in full.
    init(_ title: String, summary: String, details: [Detail]) {
        self.init(title, summary)
        self.details = details
    }
    static func == (a: Failure, b: Failure) -> Bool { a.id == b.id }
}

extension View {
    /// Shows each failure the models report as an alert on the frontmost window, or on its sheet when one is open, so
    /// a failure inside a sheet or the secondary window is seen where the person is looking. Clears it when dismissed.
    func failureAlerts(_ failures: Binding<Failure?>...) -> some View {
        var view = AnyView(self)
        for failure in failures {
            view = AnyView(view.onChange(of: failure.wrappedValue) { _, new in
                guard let new else { return }
                FailurePresenter.shared.show(new) { if failure.wrappedValue == new { failure.wrappedValue = nil } }
            })
        }
        return view
    }
}

/// One alert at a time: a failure reported while another shows waits for it, and the same message twice in a row
/// shows once.
@MainActor
final class FailurePresenter {
    static let shared = FailurePresenter()
    private var queue: [(failure: Failure, done: () -> Void)] = []
    private var current: Failure?

    func show(_ failure: Failure, done: @escaping () -> Void) {
        let last = queue.last?.failure ?? current
        if let last, last.title == failure.title, last.message == failure.message, last.details == failure.details { done(); return }
        queue.append((failure, done))
        next()
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let (failure, done) = queue.removeFirst()
        current = failure
        if !failure.details.isEmpty { showDetails(failure, done: done); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.addButton(withTitle: L10n.tr("OK"))
        for action in failure.actions { alert.addButton(withTitle: action.title).hasDestructiveAction = action.destructive }
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            done()
            self?.current = nil
            let index = response.rawValue - NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
            if failure.actions.indices.contains(index) { failure.actions[index].run() }
            self?.next()
        }
        if let window = Self.target() {
            alert.beginSheetModal(for: window) { finish($0) }
        } else {
            finish(alert.runModal())
        }
    }

    /// A failure with a file list is a sheet of its own: an alert is too narrow for full paths.
    private func showDetails(_ failure: Failure, done: @escaping () -> Void) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let parent = Self.target()
        let close = { [weak self, weak window] in
            guard let window else { return }
            if let parent = window.sheetParent { parent.endSheet(window) } else { NSApp.stopModal(); window.orderOut(nil) }
            done()
            self?.current = nil
            self?.next()
        }
        window.contentViewController = NSHostingController(rootView: FailureDetailsSheet(failure: failure, close: close))
        window.setContentSize(window.contentViewController!.view.fittingSize)
        if let parent { parent.beginSheet(window) } else { window.center(); NSApp.runModal(for: window) }
    }

    /// The window the person is working in, down to its open sheet: a sheet would hold back an alert on its parent.
    private static func target() -> NSWindow? {
        var window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        while let sheet = window?.attachedSheet { window = sheet }
        return window
    }
}

/// Every failed file of a batch: full path and reason in a table whose rows select, copy (⌘C, as path, tab, reason)
/// and show in Finder, so the person can find out what went wrong.
private struct FailureDetailsSheet: View {
    let failure: Failure
    let close: () -> Void
    private struct Row: Identifiable { let id: Int; let detail: Failure.Detail }
    @State private var selection: Set<Int> = []
    private var rows: [Row] { failure.details.enumerated().map { Row(id: $0.offset, detail: $0.element) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title).font(.headline)
                    if !failure.message.isEmpty { Text(failure.message).foregroundStyle(.secondary) }
                }
            }
            Table(rows, selection: $selection) {
                TableColumn(L10n.tr("File")) { row in
                    Text(verbatim: row.detail.path).lineLimit(1).truncationMode(.head).help(row.detail.path)
                }.width(min: 200, ideal: 440)
                TableColumn(L10n.tr("Reason")) { row in
                    Text(verbatim: row.detail.reason).lineLimit(1).help(row.detail.reason)
                }.width(min: 120, ideal: 240)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button(L10n.tr("Copy")) { copy(ids) }
                Button(L10n.tr("Show in Finder")) { NSWorkspace.shared.showInFinder(targets(ids).compactMap(\.url)) }
                    .disabled(targets(ids).allSatisfy { $0.url == nil })
            }
            .onCopyCommand { [NSItemProvider(object: text(selection) as NSString)] }
            .frame(minHeight: 120, idealHeight: min(320, CGFloat(rows.count) * 24 + 32))
            HStack {
                Button(L10n.tr("Copy All")) { copy([]) }
                Spacer()
                Button(L10n.tr("OK"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 240)
    }
    /// The rows `ids` names, or every row when it names none.
    private func targets(_ ids: Set<Int>) -> [Failure.Detail] {
        ids.isEmpty ? failure.details : ids.sorted().map { failure.details[$0] }
    }
    private func text(_ ids: Set<Int>) -> String { targets(ids).map { $0.path + "\t" + $0.reason }.joined(separator: "\n") }
    private func copy(_ ids: Set<Int>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(ids), forType: .string)
    }
}
