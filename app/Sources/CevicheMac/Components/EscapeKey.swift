import SwiftUI
import AppKit

/// Runs `action` when Escape is pressed in this view's window, whatever control has keyboard focus.
struct EscapeKey: NSViewRepresentable {
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let view, let window = view.window, event.window === window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            action(); return nil
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.monitor.map(NSEvent.removeMonitor) }
    final class Coordinator { var monitor: Any? }
}
