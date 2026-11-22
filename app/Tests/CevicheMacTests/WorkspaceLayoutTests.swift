import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class WorkspaceLayoutTests: XCTestCase {
    @MainActor func testDetailFitsWindowBeforeAndAfterCardImport() async throws {
        let (directory, catalog, editor) = try await EditorFixtures.catalog()
        defer { catalog.stopIndexing(); editor.closeDocument(); try? FileManager.default.removeItem(at: directory) }
        let opened = await catalog.openPhoto(catalog.assets[0], editor: editor)
        XCTAssertTrue(opened)
        catalog.showSidebar = true; editor.showInspector = true; editor.toolTab = .masks
        catalog.syncState = .unavailable("Offline")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1420, height: 800),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: catalog, editor: editor)
            .preferredColorScheme(.dark).frame(minWidth: 1000, minHeight: 700))
        host.sizingOptions = []
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
        }
        for afterImport in [false, true] {
            if afterImport {
                catalog.cardImport = CardImportRequest(roots: [directory], title: "Camera Card", defaultMode: .reference)
                try await Task.sleep(for: .milliseconds(150))
                catalog.cardImport = nil
            }
            for width in [1420.0, 1200.0, 1000.0] {
                window.setContentSize(NSSize(width: width, height: 800))
                try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
                let scrolls = scrollViews(host)
                XCTAssertGreaterThanOrEqual(scrolls.count, 2, "The sidebar and inspector must be present")
                for scroll in scrolls {
                    let rect = host.convert(scroll.bounds, from: scroll)
                    XCTAssertGreaterThanOrEqual(rect.minX, -1, "\(width), after import: \(afterImport), \(rect)")
                    XCTAssertLessThanOrEqual(rect.maxX, host.bounds.width + 1, "\(width), after import: \(afterImport), \(rect)")
                }
                if width == 1200, !afterImport, ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/private/tmp/ceviche-workspace-layout.png"))
                }
            }
        }
    }
}
