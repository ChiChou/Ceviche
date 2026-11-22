import AppKit
import SwiftUI

/// Watches which display shows the photo, following the window across screens, so the HDR toggle can
/// warn when the current display cannot show highlights above SDR white.
struct DisplayHDRObserver: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> DisplayHDRView { DisplayHDRView(model: model) }
    func updateNSView(_ view: DisplayHDRView, context: Context) {}
    static func dismantleNSView(_ view: DisplayHDRView, coordinator: ()) { view.stopObserving() }
}

@MainActor
final class DisplayHDRView: NSView {
    private let model: EditorModel
    private var observers: [NSObjectProtocol] = []
    init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        let center = NotificationCenter.default
        // The window moving to another display, and a display being plugged in, unplugged or reconfigured.
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        update()
    }
    func stopObserving() { observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = [] }
    private func update() {
        // Attaching the view can happen during a SwiftUI update. Publish on the next main-queue turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.observers.isEmpty, let window = self.window else { return }
            let supported = Self.supportsHDR(window.screen)
            if self.model.displaySupportsHDR != supported { self.model.displaySupportsHDR = supported }
        }
    }
    /// A display that can ever show values above SDR white: the built-in XDR panels and HDR monitors, not
    /// most external office displays. Unknown screens count as capable so the warning never shows by mistake.
    nonisolated static func supportsHDR(_ screen: NSScreen?) -> Bool {
        guard let screen else { return true }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    }
}
