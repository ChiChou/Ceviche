import XCTest
import SwiftUI
import AppKit
@testable import CevicheMac
import CevicheCore

final class LicensesTests: XCTestCase {
    func testPackagedNoticesAreReadableAndCreditsMatchShippingScope() throws {
        let catalog = try LicenseCatalog.load()
        XCTAssertTrue(catalog.components.contains { $0.id == "grdb" && $0.texts.contains { $0.contains("Gwendal Roué") } })
        XCTAssertFalse(catalog.components.contains { $0.id == "spektrafilm" })
        XCTAssertTrue(catalog.components.contains { $0.id == "fotufilm" && $0.texts.count == 6 })
        XCTAssertFalse(catalog.components.contains { $0.id == "halide" })
        for component in catalog.components {
            XCTAssertEqual(component.texts.count, component.notices.count)
            XCTAssertTrue(component.texts.allSatisfy { !$0.isEmpty })
            XCTAssertNotNil(component.projectURL.host)
        }
        XCTAssertFalse(try XCTUnwrap(catalog.components.first { $0.id == "hald-clut" }).isVisible)
        XCTAssertFalse(try XCTUnwrap(catalog.components.first { $0.id == "torch" }).isVisible)
        XCTAssertTrue(try XCTUnwrap(catalog.components.first { $0.id == "nafnet" }).isModel)
        let grdb = try XCTUnwrap(catalog.components.first { $0.id == "grdb" })
        XCTAssertTrue(grdb.matches(" grdb "))
        XCTAssertTrue(grdb.matches("MIT"))
        XCTAssertFalse(grdb.matches("unknown project"))
    }

    /// Every notice file shipped is one the manifest names, so a licence cannot be added without its credit.
    func testEveryShippedNoticeIsNamed() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "OpenSourceLicenses", withExtension: nil)).standardizedFileURL
        let named = Set(try LicenseCatalog.load(root: root).components.flatMap { $0.notices.map { root.appendingPathComponent($0.path).standardizedFileURL.path } })
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("credits"), includingPropertiesForKeys: [.isRegularFileKey]))
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && $0.lastPathComponent != ".DS_Store" }
        XCTAssertFalse(files.isEmpty)
        for file in files { XCTAssertTrue(named.contains(file.standardizedFileURL.path), file.lastPathComponent) }
    }

    @MainActor func testEveryModelLinksToItsCredit() throws {
        // Shown under Optional Models, or with the bundled code and data for the models built into the app.
        let models = Dictionary(uniqueKeysWithValues: try LicenseCatalog.bundled.get().components.filter(\.isVisible).map { ($0.id, $0) })
        for model in BundledModel.allCases {
            XCTAssertNotNil(models[LicenseFocus.creditID(model)], "\(model) links to a license entry that is not shown")
        }
    }
    func testMissingResourcesProduceAnError() {
        XCTAssertThrowsError(try LicenseCatalog.load(root: nil))
        XCTAssertThrowsError(try LicenseCatalog.load(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @MainActor func testLicensesWindowSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional snapshots") }
        let catalog = try LicenseCatalog.load()
        for dark in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: LicensesView(catalog: .success(catalog), expanded: dark ? ["aces"] : []).preferredColorScheme(dark ? .dark : .light))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = dark ? "dark-expanded" : "light"
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-licenses-\(name).png"))
            window.close()
        }
    }
}
