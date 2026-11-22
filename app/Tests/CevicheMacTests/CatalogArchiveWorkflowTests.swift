import XCTest
import CevicheCore
@testable import CevicheMac

final class CatalogArchiveWorkflowTests: XCTestCase {
    /// Tidy Pairs' Apply archives in place with one Undo; Move to Folder moves the file with an XMP and drops the record.
    @MainActor func testArchiveUndoThenMoveToFolderWritesXMP() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        defer { model.stopIndexing() }
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let source = directory.appendingPathComponent("Referenced").appendingPathComponent("shot.jpg")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: source)
        let prepared = try CatalogImporter.prepare(source)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        var settings = Adjustments(); settings.exposure = 0.7
        try await store.saveEdits(settings, assetID: asset.id)
        await model.refresh()

        var decisions = FileDecisions(); decisions.archive = [asset]
        let result = await model.applyFileDecisions(decisions, undoTitle: "Tidy")
        XCTAssertEqual(result?.archived, 1)
        XCTAssertEqual(model.total, 0); XCTAssertEqual(model.archiveCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await model.perform(undo: true)
        XCTAssertEqual(model.total, 1); XCTAssertEqual(model.archiveCount, 0)
        await model.archive([try await store.asset(asset.id)])
        XCTAssertEqual(model.archiveCount, 1)

        let folder = directory.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.moveToFolder([try await store.asset(asset.id)], folder: folder)
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("shot.jpg").path))
        let xmp = try String(contentsOf: folder.appendingPathComponent("shot.xmp"), encoding: .utf8)
        XCTAssertTrue(xmp.contains("Exposure2012"), xmp)
        XCTAssertEqual(model.archiveCount, 0)
        let gone = try? await store.asset(asset.id)
        XCTAssertNil(gone)
    }
}
