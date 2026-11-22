import XCTest
import AppKit
import SwiftUI
@testable import CevicheMac

final class WindowTitlebarTests: XCTestCase {
    func testSystemPreferenceMapping() {
        XCTAssertEqual(TitlebarDoubleClickAction(preference: nil), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "Zoom"), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "Fill"), .fill)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "Maximize"), .fill)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "Minimize"), .minimize)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "None"), .none)
        XCTAssertEqual(TitlebarDoubleClickAction(preference: "No Action"), .none)
    }
    @MainActor func testHeaderDoubleClickAndDragUseNativeWindowActions() {
        _ = NSApplication.shared
        let window = TitlebarTestWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = WindowTitlebarView(frame: NSRect(x: 0, y: 0, width: 500, height: 60))
        window.contentView?.addSubview(view)
        func click(_ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 200, y: 20), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        view.doubleClickPreference = { nil }
        view.mouseDown(with: click(2)); XCTAssertEqual(window.zoomCalls, 1)
        view.doubleClickPreference = { "Minimize" }
        view.mouseDown(with: click(2)); XCTAssertEqual(window.minimizeCalls, 1)
        view.doubleClickPreference = { "None" }
        view.mouseDown(with: click(2)); XCTAssertEqual(window.zoomCalls, 1); XCTAssertEqual(window.minimizeCalls, 1)
        view.mouseDown(with: click(1)); XCTAssertEqual(window.dragCalls, 1)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
    }
    @MainActor func testFillRestoresFrameAcrossBothHeaderRegions() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let original = NSRect(x: screen.visibleFrame.midX - 250, y: screen.visibleFrame.midY - 200, width: 500, height: 400)
        let window = TitlebarTestWindow(contentRect: original, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(original, display: false)
        defer { window.close() }
        let brand = WindowTitlebarView(), filename = WindowTitlebarView()
        window.contentView?.addSubview(brand); window.contentView?.addSubview(filename)
        brand.doubleClickPreference = { "Fill" }; filename.doubleClickPreference = { "Fill" }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        brand.mouseDown(with: event)
        XCTAssertEqual(window.frame, screen.visibleFrame)
        filename.mouseDown(with: event)
        XCTAssertEqual(window.frame, original)
    }
    @MainActor func testTrafficLightsAlignWithEveryHeaderAndRemainClickableAfterResize() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        defer { window.close() }
        let editor = EditorModel(), catalog = CatalogModel()
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { try XCTUnwrap(window.standardWindowButton($0)) }
        let nativeSizes = buttons.map(\.frame.size)
        let nativeSpacing = buttons[1].frame.minX - buttons[0].frame.minX
        func anchors(_ view: NSView) -> [TrafficLightAlignmentView] {
            (view as? TrafficLightAlignmentView).map { [$0] } ?? view.subviews.flatMap { anchors($0) }
        }
        catalog.viewMode = .detail
        let views: [AnyView] = [AnyView(CatalogWorkspace(catalog: catalog, editor: editor))]
        for (index, view) in views.enumerated() {
            let host = NSHostingView(rootView: view.preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            for size in [NSSize(width: 1200, height: 760), NSSize(width: 1000, height: 700)] {
                window.setContentSize(size); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let anchor = try XCTUnwrap(anchors(host).first)
                let center = anchor.convert(NSPoint(x: anchor.bounds.minX + 19, y: anchor.bounds.midY), to: nil)
                XCTAssertEqual(anchor.bounds.height, 48, accuracy: 0.1)
                for (buttonIndex, button) in buttons.enumerated() {
                    let frame = button.convert(button.bounds, to: nil)
                    XCTAssertEqual(frame.midY, center.y, accuracy: 0.5, "View \(index), button \(buttonIndex)")
                    XCTAssertEqual(frame.minX, center.x + Double(buttonIndex) * nativeSpacing, accuracy: 0.5)
                    XCTAssertEqual(button.frame.size, nativeSizes[buttonIndex], "Keep AppKit's native buttons")
                    let parent = try XCTUnwrap(button.superview)
                    XCTAssertTrue(parent.bounds.contains(button.frame), "The button must stay inside its native hit-testing container")
                    let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
                    XCTAssertTrue(parent.hitTest(parent.convert(point, to: parent.superview)) === button)
                }
            }
            if index == 2, ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" {
                let frame = try XCTUnwrap(window.contentView?.superview)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-traffic-lights.png"))
            }
        }
    }
    @MainActor func testHeaderAreasDoNotCoverToolbarControlsOrPhotograph() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 920), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let catalog = CatalogModel(); catalog.viewMode = .detail
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: EditorModel()))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1420, height: 920)
        host.layoutSubtreeIfNeeded()
        func areas(_ view: NSView) -> [WindowTitlebarView] {
            (view as? WindowTitlebarView).map { [$0] } ?? view.subviews.flatMap { areas($0) }
        }
        // The empty space on each side of the search field, which sits in the middle of the header.
        let regions = areas(host).sorted { host.convert($0.bounds, from: $0).minX < host.convert($1.bounds, from: $1).minX }
        XCTAssertEqual(regions.count, 2)
        let rects = regions.map { host.convert($0.bounds, from: $0) }
        XCTAssertTrue(rects.allSatisfy { $0.width >= 44 }, "Each side keeps room to drag the window")
        XCTAssertGreaterThan(rects.reduce(0) { $0 + $1.width }, 300, "The empty header beside the search field must be draggable")
        XCTAssertFalse(rects.contains { $0.contains(CGPoint(x: 350, y: 460)) }, "The photograph must retain its own gestures")
        // All of each side's empty space drags the window; the search field between them keeps its clicks.
        for region in regions {
            for x in [region.bounds.minX + 8, region.bounds.midX, region.bounds.maxX - 8] {
                let point = region.convert(CGPoint(x: x, y: region.bounds.midY), to: host)
                XCTAssertTrue(host.hitTest(host.convert(point, to: host.superview)) === region)
            }
        }
        if rects.count == 2 {
            let field = CGPoint(x: (rects[0].maxX + rects[1].minX) / 2, y: rects[0].midY)
            let hit = host.hitTest(host.convert(field, to: host.superview))
            XCTAssertFalse(regions.contains { $0 === hit }, "The search field between the two sides keeps its clicks")
        }
    }
}

@MainActor
private final class TitlebarTestWindow: NSWindow {
    var zoomCalls = 0, minimizeCalls = 0, dragCalls = 0
    override func performZoom(_ sender: Any?) { zoomCalls += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizeCalls += 1 }
    override func performDrag(with event: NSEvent) { dragCalls += 1 }
    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: flag, animate: false)
    }
}
