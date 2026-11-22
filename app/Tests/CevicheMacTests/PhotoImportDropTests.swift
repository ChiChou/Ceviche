import XCTest
import AppKit
import CevicheCore
@testable import CevicheMac

final class PhotoImportDropTests: XCTestCase {
    @MainActor func testFileAndFolderDropsUseOptionCommandInsteadOfThePanelPreference() async throws {
        let (directory, source) = try CatalogSetupTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        let root = directory.appendingPathComponent("Catalog")
        await model.openCatalog(root)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        model.importMode = .copy
        XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
        let reference = PhotoImportDrop(modifiers: [.option, .command])
        XCTAssertEqual(reference.operation(for: pasteboard, catalog: model), .link)
        XCTAssertTrue(reference.performDrop(from: pasteboard, catalog: model))
        while model.importing { try await Task.sleep(for: .milliseconds(10)) }
        let referenced = try XCTUnwrap(model.assets.first)
        XCTAssertEqual(referenced.sourcePath, source.path)
        XCTAssertFalse(referenced.isCopy)
        XCTAssertEqual(model.importMode, .copy, "A drop does not change the panel's saved mode")

        let folder = directory.appendingPathComponent("Card/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let second = folder.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: source, to: second)
        model.importMode = .reference
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([folder.deletingLastPathComponent() as NSURL]))
        let copy = PhotoImportDrop(modifiers: [])
        XCTAssertEqual(copy.operation(for: pasteboard, catalog: model), .copy)
        XCTAssertTrue(copy.performDrop(from: pasteboard, catalog: model))
        while model.importing { try await Task.sleep(for: .milliseconds(10)) }
        let copied = try XCTUnwrap(model.assets.first { $0.filename == "second.jpg" })
        XCTAssertTrue(copied.isCopy)
        XCTAssertEqual(copied.locator, .catalog(relativePath: "Originals/2025-10/second.jpg"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Originals/2025-10/second.jpg")), try Data(contentsOf: second))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(model.importMode, .reference)
    }

    @MainActor func testDropsRejectMissingCatalogBusyCatalogAndNonFileURLs() async throws {
        let (directory, source) = try CatalogSetupTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([source as NSURL])
        let drop = PhotoImportDrop(modifiers: [])
        XCTAssertEqual(drop.operation(for: pasteboard, catalog: model), [])
        XCTAssertFalse(drop.performDrop(from: pasteboard, catalog: model))
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        model.automationBusy = true
        XCTAssertEqual(drop.operation(for: pasteboard, catalog: model), [])
        XCTAssertFalse(drop.performDrop(from: pasteboard, catalog: model))
        model.automationBusy = false
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.com/photo.jpg")!])
        XCTAssertEqual(drop.operation(for: pasteboard, catalog: model), [])
        XCTAssertFalse(drop.performDrop(from: pasteboard, catalog: model))
    }
}
