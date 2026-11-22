import AppKit
import SwiftUI
import XCTest
import CevicheCore
@testable import CevicheMac

/// Optional visual checks, isolated from the user's catalog and preferences. Launch each language
/// in a fresh test process with -AppleLanguages '(it)' (or es, zh-Hans, zh-Hant, en).
final class LocalizationLayoutTests: XCTestCase {
    @MainActor func testLocalizedWelcomeAndSettings() async throws {
        guard let output = ProcessInfo.processInfo.environment["CEVICHE_LOCALIZATION_SNAPSHOTS"] else {
            throw XCTSkip("Set CEVICHE_LOCALIZATION_SNAPSHOTS to an output folder for visual checks")
        }
        let suite = "LocalizationLayout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences)
        let editor = EditorModel(preferences: preferences)
        let mcp = MCPController(preferences: preferences)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = L10n.bundle.preferredLocalizations.first ?? "en"
        try await snapshot(WelcomeView(model: catalog), size: NSSize(width: 1200, height: 760),
                           to: directory.appendingPathComponent("welcome-\(language).png"))
        try await snapshot(PreferencesView(mcp: mcp), size: NSSize(width: 620, height: 480),
                           to: directory.appendingPathComponent("settings-\(language).png"))
        try await snapshot(EditorInspector(model: editor, catalog: catalog), size: NSSize(width: 350, height: 900),
                           to: directory.appendingPathComponent("editor-\(language).png"))
    }

    @MainActor private func snapshot<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
}
