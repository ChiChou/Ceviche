import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

/// Renders the welcome screen and the card importer to PNGs when CEVICHE_UI_SNAPSHOTS=1.
final class SetupSnapshotTests: XCTestCase {
    @MainActor private func snapshot<V: View>(_ view: V, size: NSSize, to path: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .seconds(2)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    @MainActor func testWelcomeAndCardImportSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional snapshots") }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences)
        try await snapshot(WelcomeView(model: catalog), size: NSSize(width: 1200, height: 760), to: "/private/tmp/ceviche-welcome.png")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        let samples = try TestSamples.require(TestSamples.raws)
        for (index, url) in samples.prefix(6).enumerated() { try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("DCIM/100MSDCF/DSC00\(index).ARW")) }
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        let prepared = try CatalogImporter.prepare(directory.appendingPathComponent("DCIM/100MSDCF/DSC001.ARW"))
        _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        let request = CardImportRequest(roots: [directory.appendingPathComponent("DCIM")], title: "UNTITLED", defaultMode: .copy)
        try await snapshot(CardImportView(catalog: catalog, request: request), size: NSSize(width: 1420, height: 920), to: "/private/tmp/ceviche-card-import.png")
    }
}
