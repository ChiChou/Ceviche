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

    init(_ title: String, _ message: String, actions: [Action] = []) { self.title = title; self.message = message; self.actions = actions }
    init(_ title: String, _ error: Error) { self.init(title, error.localizedDescription) }
    /// A batch that partly failed: `summary` ("3 photos couldn’t be exported."), if any, then the first eight of `items`.
    init(_ title: String, summary: String, items: [String]) {
        let shown = items.prefix(8).joined(separator: "\n") + (items.count > 8 ? "\n…" : "")
        self.init(title, [summary, shown].filter { !$0.isEmpty }.joined(separator: "\n\n"))
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
        if let last, last.title == failure.title, last.message == failure.message { done(); return }
        queue.append((failure, done))
        next()
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let (failure, done) = queue.removeFirst()
        current = failure
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

    /// The window the person is working in, down to its open sheet: a sheet would hold back an alert on its parent.
    private static func target() -> NSWindow? {
        var window = NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        while let sheet = window?.attachedSheet { window = sheet }
        return window
    }
}
