import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Metal
import CevicheCore
@testable import CevicheMac

final class CatalogWorkflowTests: XCTestCase {
    @MainActor func testSelectionFlushesMetadataAndCatalogSwitchPreservesEdits() async throws {
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        let root = directory.appendingPathComponent("Catalog")
        await model.openCatalog(root)
        let store = try XCTUnwrap(model.store)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.selectAsset(asset)
        model.metadata.title = "First title"; model.metadata.rating = 4
        await model.openCatalog(directory.appendingPathComponent("Other catalog"))
        XCTAssertNil(model.error)
        let saved = try await store.asset(asset.id)
        XCTAssertEqual(saved.title, "First title"); XCTAssertEqual(saved.rating, 4)
        XCTAssertNil(model.selected)
        await model.openCatalog(root)
        XCTAssertEqual(model.assets.count, 1)
        await model.selectAsset(model.assets[0])
        XCTAssertEqual(model.metadata.rating, 4)
        XCTAssertFalse(model.metadataPending)
    }
    @MainActor func testCatalogEditorSavesWithoutDocumentAndRestoresHistory() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        let editor = EditorModel()
        await editor.open(url, catalog: store, asset: asset)
        XCTAssertNil(editor.error); XCTAssertFalse(editor.dirty)
        editor.edit { $0.exposure = 0.7 }
        let saved = await editor.save()
        XCTAssertTrue(saved); XCTAssertFalse(editor.dirty)
        editor.closeDocument()
        let current = try await store.asset(asset.id)
        await editor.open(url, catalog: store, asset: current)
        XCTAssertEqual(editor.adjustments.exposure, 0.7)
        editor.edit { $0.exposure = 0.9 }
        let flushed = await editor.flushEdits()
        XCTAssertTrue(flushed)
        let persisted = try await store.photo(asset.id)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: persisted.adjustmentsData!).exposure, 0.9)
        editor.closeDocument()
        var cropped = Adjustments(); cropped.geometry.crop = CropRect(width: 0.5)
        try await store.saveEdits(cropped, assetID: asset.id)
        let croppedAsset = try await store.asset(asset.id)
        editor.toolTab = .crop
        await editor.open(url, catalog: store, asset: croppedAsset)
        let refreshed = try await store.asset(asset.id)
        XCTAssertNotNil(refreshed.thumbnailKey)
        let storedThumbnail = try await store.previews.data(assetID: asset.id)
        let thumbnailData = try XCTUnwrap(storedThumbnail)
        let thumbnailSource = try XCTUnwrap(CGImageSourceCreateWithData(thumbnailData as CFData, nil))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateImageAtIndex(thumbnailSource, 0, nil))
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 0.8, accuracy: 0.02, "Library thumbnail must include the saved crop even in Crop mode")
        XCTAssertEqual(editor.preview?.width, 160, "Crop mode keeps its uncropped editing canvas")
        editor.closeDocument()
    }
    @MainActor func testXMPEditorOpenImportUndoExportAndFailure() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: url)
        var first = Adjustments(); first.exposure = 0.6
        var metadata = CatalogMetadata(); metadata.rating = 3; metadata.title = "Sample"
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        try XMPCodec.encode(adjustments: first, metadata: metadata, filename: url.lastPathComponent).write(to: sidecar)
        let editor = EditorModel()
        await editor.open(url)
        XCTAssertNil(editor.error); XCTAssertEqual(editor.adjustments, first)
        var second = first; second.exposure = 1.2
        let other = directory.appendingPathComponent("custom.xmp")
        try XMPCodec.encode(adjustments: second, metadata: metadata, filename: url.lastPathComponent).write(to: other)
        await editor.importXMP(from: other)
        XCTAssertNil(editor.failure); XCTAssertEqual(editor.adjustments, second)
        editor.undo(); XCTAssertEqual(editor.adjustments, first); editor.redo()
        let output = directory.appendingPathComponent("export.xmp")
        await editor.exportXMP(to: output)
        XCTAssertNil(editor.failure)
        let imported = try XMPCodec.apply(XMPPacket(url: output), to: Adjustments())
        XCTAssertEqual(imported.adjustments, second); XCTAssertEqual(imported.metadata, metadata)
        let invalid = directory.appendingPathComponent("invalid.xmp"); try Data("bad".utf8).write(to: invalid)
        await editor.importXMP(from: invalid)
        XCTAssertNotNil(editor.failure); XCTAssertEqual(editor.adjustments, second)
        editor.error = nil; editor.closeDocument()
        await editor.open(other)
        XCTAssertNil(editor.error); XCTAssertEqual(editor.adjustments, second)
        XCTAssertEqual(try Data(contentsOf: url), original)
        editor.closeDocument()
    }
    @MainActor func testCatalogXMPWorkflowFlushesMetadataAndPersistsRecipes() async throws {
        let (directory, url) = try EditorFixtures.photo(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store), prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.selectAsset(asset)
        model.metadata.title = "Pending title"
        var recipe = Adjustments(); recipe.exposure = 0.8
        let sidecar = directory.appendingPathComponent("edits.xmp")
        try XMPCodec.encode(adjustments: recipe).write(to: sidecar)
        await model.importXMP(from: sidecar)
        XCTAssertNil(model.error); XCTAssertEqual(model.metadata.title, "Pending title")
        let imported = try await store.photo(asset.id)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: imported.adjustmentsData!), recipe)
        XCTAssertNotNil(imported.xmpData); XCTAssertFalse(model.metadataPending)
        model.metadata.rating = 5
        let output = directory.appendingPathComponent("export.xmp")
        await model.exportXMP(to: output)
        XCTAssertNil(model.error)
        let exported = try XMPCodec.apply(XMPPacket(url: output), to: Adjustments())
        XCTAssertEqual(exported.metadata.rating, 5); XCTAssertEqual(exported.metadata.title, "Pending title")
        XCTAssertEqual(exported.adjustments, recipe)
    }
    @MainActor func testSidecarSampleDevelopsAndRoundTripsThroughXMP() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let original = try TestSamples.require(TestSamples.developedSidecar)
        let editor = EditorModel(); await editor.open(original)
        XCTAssertNil(editor.error); XCTAssertNotNil(editor.preview)
        XCTAssertEqual(editor.adjustments.exposure, 1.1); XCTAssertEqual(editor.adjustments.curve.points.count, 5)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xmp")
        defer { try? FileManager.default.removeItem(at: output) }
        await editor.exportXMP(to: output)
        XCTAssertNil(editor.error)
        XCTAssertEqual(try XMPCodec.apply(XMPPacket(url: output), to: Adjustments()).adjustments, editor.adjustments)
        editor.closeDocument()
    }
    @MainActor func testMovedCatalogIsReportedNotRecreated() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.cevichecatalog")
        preferences.set(moved.path, forKey: "catalogRoot")
        let model = CatalogModel(preferences: preferences)
        await model.start()
        XCTAssertEqual(model.missingCatalog, moved)
        XCTAssertNil(model.store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path), "A missing catalog is never replaced by an empty one")
    }
    @MainActor func testReplacedThumbnailsOverwriteTheirRowAndChangeTheirKey() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        let asset = try await store.asset(model.assets[0].id)
        let old = try XCTUnwrap(asset.thumbnailKey)
        let rows = try await store.previews.count()
        try await store.installThumbnail(Data([1, 2, 3]), assetID: asset.id, renderKey: asset.renderKey)
        let current = try await store.asset(asset.id)
        XCTAssertNotEqual(current.thumbnailKey, old, "Views keyed on the thumbnail key reload")
        let stored = try await store.previews.data(assetID: asset.id), rowsAfter = try await store.previews.count()
        XCTAssertEqual(stored, Data([1, 2, 3]))
        XCTAssertEqual(rowsAfter, rows, "One row per photo, replaced in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Thumbnails").path), "No per-photo files")
    }
}
