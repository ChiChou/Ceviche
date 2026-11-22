import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

/// Pick from Bursts on screen, with Pick, Group and Skip bursts. Set CEVICHE_UI_SNAPSHOTS=1, CEVICHE_BURST_PHOTOS to
/// folders of photos separated by ":", and CEVICHE_SNAPSHOT_OUT to where the PNGs go.
final class BurstSnapshotTests: XCTestCase {
    @MainActor func testBurstDialogSnapshotsWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CEVICHE_UI_SNAPSHOTS"] == "1", let folders = environment["CEVICHE_BURST_PHOTOS"] else { throw XCTSkip("Optional burst snapshots") }
        let out = URL(fileURLWithPath: environment["CEVICHE_SNAPSHOT_OUT"] ?? NSTemporaryDirectory())
        let fm = FileManager.default
        let sources = try folders.split(separator: ":").flatMap { folder in
            try fm.contentsOfDirectory(at: URL(fileURLWithPath: String(folder)), includingPropertiesForKeys: nil)
                .filter { CatalogImporter.supported($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let catalog = try await EditorFixtures.catalog(of: sources, in: directory)
        let editor = EditorModel()
        let photos = catalog.assets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) }
        let request = CullingAssistantRequest(assets: photos, title: L10n.tr("All Photos"))
        let model = CullingAssistantModel(request: request, sensitivity: catalog.cullingSensitivity)
        model.options.burst = BurstSettings(gap: 30, distance: 0.5)

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 900), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { model.stop(); window.close() }
        let host = NSHostingView(rootView: CullingAssistantView(catalog: catalog, editor: editor, model: model).preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        for _ in 0..<1200 where model.stage != .ready { try await Task.sleep(for: .milliseconds(250)) }
        try await Task.sleep(for: .seconds(1))
        print("BURSTS", model.plan.bursts.map(\.members.count), model.stage, model.options.burst)
        XCTAssertGreaterThanOrEqual(model.plan.bursts.count, 2)

        func capture(_ name: String) async throws {
            try await Task.sleep(for: .seconds(2)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
        }
        try await capture("bursts-1-pick")
        // ← and → run on from the last frame of one burst into the next, and back.
        let first = model.plan.bursts[0], second = model.plan.bursts[1]
        model.burstID = first.id; model.focusedID = first.members.last
        model.moveFocus(1)
        XCTAssertEqual(model.burstID, second.id); XCTAssertEqual(model.focusedID, second.members.first)
        model.moveFocus(-1)
        XCTAssertEqual(model.burstID, first.id); XCTAssertEqual(model.focusedID, first.members.last)
        model.moveBurst(1)
        XCTAssertEqual(model.burstID, second.id); XCTAssertEqual(model.focusedID, second.best)
        // The first burst folded, the last skipped, the rest picked from.
        let bursts = model.plan.bursts
        model.setAction(bursts[0], .group)
        if bursts.count > 2 { model.setAction(bursts[bursts.count - 1], .skip) }
        model.burstID = bursts[0].id; model.focusedID = model.cover(of: bursts[0])
        try await capture("bursts-2-mixed")
        model.moveFocus(1)
        if let id = model.focusedID { model.makeCover(id) }
        try await capture("bursts-3-new-cover")
        model.setAll(.group)
        try await capture("bursts-4-all-grouped")
        model.setAll(.skip)
        try await capture("bursts-5-all-skipped")
    }
}
