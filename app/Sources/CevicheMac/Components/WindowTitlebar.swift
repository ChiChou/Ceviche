import AppKit
import SwiftUI

/// The custom header must explicitly provide the interactions of a native title bar.
struct WindowTitlebarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitlebarView { WindowTitlebarView() }
    func updateNSView(_ view: WindowTitlebarView, context: Context) {}
}

enum TitlebarDoubleClickAction {
    case zoom, fill, minimize, none
    init(preference: String?) {
        switch preference?.lowercased() {
        case "minimize": self = .minimize
        case "fill", "maximize": self = .fill
        case "none", "nothing", "no action": self = .none
        default: self = .zoom
        }
    }
}

@MainActor
final class WindowTitlebarView: NSView {
    // Read on each click so changing System Settings takes effect without relaunching.
    var doubleClickPreference: () -> String? = { UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            guard !window.styleMask.contains(.fullScreen) else { return }
            switch TitlebarDoubleClickAction(preference: doubleClickPreference()) {
            case .zoom: window.performZoom(nil)
            case .fill: WindowFillState.toggle(window)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        } else if event.clickCount == 1 {
            window.performDrag(with: event)
        }
    }
}

/// Share the restore frame across the brand and filename regions of the same window.
@MainActor
private final class WindowFillState: NSObject {
    static let frames = NSMapTable<NSWindow, WindowFillState>.weakToStrongObjects()
    let frame: NSRect
    init(frame: NSRect) { self.frame = frame }
    static func toggle(_ window: NSWindow) {
        guard let screen = window.screen, window.styleMask.contains(.resizable) else { return }
        let visible = screen.visibleFrame
        let current = window.frame
        let isFilled = abs(current.minX - visible.minX) < 1 && abs(current.minY - visible.minY) < 1
            && abs(current.width - visible.width) < 1 && abs(current.height - visible.height) < 1
        if isFilled, let previous = frames.object(forKey: window) {
            frames.removeObject(forKey: window)
            window.setFrame(window.constrainFrameRect(previous.frame, to: screen), display: true, animate: true)
        } else {
            frames.setObject(WindowFillState(frame: current), forKey: window)
            window.setFrame(visible, display: true, animate: true)
        }
    }
}

/// Align AppKit's own window buttons with the custom toolbar, keeping their native actions and hit targets.
struct WindowTrafficLights: NSViewRepresentable {
    static let headerHeight: CGFloat = 48
    static let leadingReservation: CGFloat = 80
    func makeNSView(context: Context) -> TrafficLightAlignmentView { TrafficLightAlignmentView() }
    func updateNSView(_ view: TrafficLightAlignmentView, context: Context) { view.scheduleAlignment() }
    static func dismantleNSView(_ view: TrafficLightAlignmentView, coordinator: ()) { view.stopObserving() }
}

@MainActor
final class TrafficLightAlignmentView: NSView {
    private var observers: [NSObjectProtocol] = []
    private var alignmentPending = false
    private var transitioningFullScreen = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didChangeBackingPropertiesNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAlignment() }
            })
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transitioningFullScreen = true }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.transitioningFullScreen = false; self?.scheduleAlignment() }
            })
        }
        // AppKit puts the buttons back whenever it lays out the title bar again (a new title, a catalog opening), which
        // none of the window's notifications report; the button's own move does.
        if let close = window.standardWindowButton(.closeButton) {
            close.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAlignment() }
            })
        }
        scheduleAlignment()
    }
    override func layout() { super.layout(); scheduleAlignment() }
    func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []; transitioningFullScreen = false
    }
    func scheduleAlignment() {
        guard !alignmentPending else { return }
        alignmentPending = true
        // AppKit lays out the native title bar first, including during window resizing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.alignmentPending = false; self.alignButtons()
        }
    }
    private func alignButtons() {
        guard let window, !transitioningFullScreen, !window.styleMask.contains(.fullScreen),
              bounds.width > 0, bounds.height > 0,
              let close = window.standardWindowButton(.closeButton), let parent = close.superview else { return }
        let target = convert(NSPoint(x: bounds.minX + 19, y: bounds.midY), to: nil)
        let current = close.convert(close.bounds, to: nil)
        let dx = target.x - current.minX
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), button.superview === parent else { continue }
            let frame = button.convert(button.bounds, to: nil)
            let origin = parent.convert(NSPoint(x: frame.minX + dx, y: target.y - frame.height / 2), from: nil)
            if abs(button.frame.minX - origin.x) > 0.01 || abs(button.frame.minY - origin.y) > 0.01 {
                button.setFrameOrigin(origin)
            }
        }
    }
}
