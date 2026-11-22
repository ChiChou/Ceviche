import AppKit
import SwiftUI

/// The window a SwiftUI view is in, for event monitors that must leave other windows' keys alone.
@MainActor
final class HostWindow {
    weak var window: NSWindow?
    /// True for events sent to this window while no sheet covers it.
    func owns(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        return event.window === window && window.attachedSheet == nil
    }
}

/// Records the hosting window in `host`; put it in a background.
struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow
    func makeNSView(context: Context) -> NSView { Reader(host: host) }
    func updateNSView(_ view: NSView, context: Context) { host.window = view.window }
    private final class Reader: NSView {
        let host: HostWindow
        init(host: HostWindow) { self.host = host; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); host.window = window }
    }
}
