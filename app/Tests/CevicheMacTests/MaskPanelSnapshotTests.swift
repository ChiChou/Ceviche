import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

/// Optional visual checks of the inspector panels: CEVICHE_UI_SNAPSHOTS=1 writes /private/tmp/ceviche-panel-masks.png (a
/// mask selected) and /private/tmp/ceviche-panel-crop.png.
final class MaskPanelSnapshotTests: XCTestCase {
    @MainActor func testMaskPanelSnapshotWhenRequested() async throws {
        try await snapshot("masks") { editor in
            editor.toolTab = .masks
            editor.addMask(.radial); editor.beginMask(at: MaskPoint(x: 0.5, y: 0.5)); editor.dragMask(to: MaskPoint(x: 0.7, y: 0.7)); editor.endMask()
            editor.updateMask { $0.name = "Sky" }
            return AnyView(MaskPanel(model: editor))
        }
    }
    @MainActor func testCropPanelSnapshotWhenRequested() async throws {
        try await snapshot("crop") { editor in editor.toolTab = .crop; return AnyView(CropPanel(model: editor).padding(18)) }
    }
    @MainActor private func snapshot(_ name: String, _ panel: (EditorModel) -> AnyView) async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional panel snapshot") }
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let opened = await model.openPhoto(model.assets[0], editor: editor); XCTAssertTrue(opened)
        let view = panel(editor)
        let scheme: ColorScheme = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_LIGHT"] == "1" ? .light : .dark
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ScrollView { view }.background(Theme.canvas).preferredColorScheme(scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(800)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-panel-\(name).png"))
    }
}
