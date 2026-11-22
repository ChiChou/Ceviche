import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

/// Optional visual check of the Library: CEVICHE_UI_SNAPSHOTS=1 writes /private/tmp/ceviche-library.png.
/// CEVICHE_SNAPSHOT_LIGHT=1 renders the light palette; CEVICHE_SNAPSHOT_PANEL=history the inspector's History tab.
final class LibrarySnapshotTests: XCTestCase {
    @MainActor func testLibrarySnapshotWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional library snapshot") }
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        for (index, day) in ["2022-06-12", "2022-06-12", "2022-06-11", "2022-05-30", "2021-01-01", ""].enumerated() {
            var metadata = photos[index].metadata; metadata.captureDay = day; metadata.rating = index % 4; metadata.review = index == 1 ? .accepted : index == 3 ? .rejected : .unreviewed
            try await store.updateMetadata(metadata, assetID: photos[index].id)
        }
        try await store.createAlbum(name: "Coastline", assetIDs: [photos[0].id, photos[1].id])
        try await store.createAlbum(name: "A longer album name for truncation", assetIDs: [photos[2].id])
        await model.refresh()
        await model.selectAsset(model.assets[1])
        if ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_MULTI"] == "1" {
            model.selectAll(); try await Task.sleep(for: .milliseconds(200))
        }
        // CEVICHE_SNAPSHOT_PANEL=history shows the inspector's History tab instead of Info.
        if let panel = CatalogModel.LibraryPanel(rawValue: ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_PANEL"] ?? "") { model.showLibraryPanel(panel) }
        let width = Double(ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_WIDTH"] ?? "") ?? 1300
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor)
            .preferredColorScheme(snapshotScheme).ignoresSafeArea(.container, edges: .top))
        host.appearance = NSAppearance(named: snapshotScheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-library.png"))
    }
}

private var snapshotScheme: ColorScheme { ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_LIGHT"] == "1" ? .light : .dark }
