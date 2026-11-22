import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogTrashWorkflowTests: XCTestCase {
    @MainActor func testDeletingInDevelopKeepsViewAndAdvancesThenStaysEmpty() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        defer { model.stopIndexing(); editor.closeDocument() }
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        var photos: [CatalogAsset] = []
        for name in ["first.jpg", "second.jpg"] {
            let url = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: original, to: url)
            let prepared = try CatalogImporter.prepare(url)
            photos.append(try await store.insert(prepared.0, thumbnail: prepared.1))
        }
        await model.refresh()
        let opened = await model.openPhoto(photos[0], editor: editor)
        XCTAssertTrue(opened)
        await model.moveToTrash([photos[0]], editor: editor)
        XCTAssertEqual(model.viewMode, .detail)
        XCTAssertEqual(editor.catalogAssetID, photos[1].id)
        XCTAssertEqual(model.browsingAssets.map(\.id), [photos[1].id])
        await model.moveToTrash([photos[1]], editor: editor)
        XCTAssertEqual(model.viewMode, .detail)
        XCTAssertFalse(editor.hasImage)
        XCTAssertTrue(model.browsingAssets.isEmpty)
        XCTAssertNil(model.error)
    }
    @MainActor func testTrashFlushesMetadataAndEditorThenRecovers() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store), prepared = try CatalogImporter.prepare(original)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.refresh(); await model.selectAsset(asset)
        model.metadata.title = "Keep this title"
        await editor.open(original, catalog: store, asset: asset)
        editor.edit { $0.exposure = 0.75 }
        await model.moveToTrash([asset], editor: editor)
        XCTAssertNil(model.error); XCTAssertFalse(editor.hasImage)
        XCTAssertNil(model.selected); XCTAssertEqual(model.total, 0); XCTAssertEqual(model.trashCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        await model.showCollection(trash: true)
        let trashed = try XCTUnwrap(model.assets.first)
        XCTAssertEqual(trashed.title, "Keep this title")
        await model.selectAsset(trashed)
        let stored = try await store.photo(asset.id)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: XCTUnwrap(stored.adjustmentsData)).exposure, 0.75)
        model.filter.search = "something else"; model.clearFilters()
        XCTAssertEqual(model.filter.area, .trash); XCTAssertTrue(model.filter.search.isEmpty)
        await model.recoverFromTrash([trashed])
        XCTAssertEqual(model.trashCount, 0); XCTAssertNil(model.selected)
        await model.showCollection(trash: false)
        XCTAssertEqual(model.assets.map(\.id), [asset.id])
    }
    @MainActor func testPermanentDeletionNeedsConfirmationAndKeepsFrozenTarget() async throws {
        let (directory, first) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("second.jpg"); try FileManager.default.copyItem(at: first, to: second)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let a = try CatalogImporter.prepare(first), b = try CatalogImporter.prepare(second)
        let firstAsset = try await store.insert(a.0, thumbnail: a.1), secondAsset = try await store.insert(b.0, thumbnail: b.1)
        await model.selectAsset(firstAsset)
        await model.confirmPermanentDeletion() // No confirmation target: no operation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        await model.requestPermanentDeletion([secondAsset], editor: editor)
        XCTAssertEqual(model.pendingDeletion?.removal.entries.map(\.id), [secondAsset.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        await model.openCatalog(directory.appendingPathComponent("Other"))
        XCTAssertTrue(model.store === store, "Cannot switch catalog underneath a pending confirmation")
        model.cancelPermanentDeletion()
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        await model.requestPermanentDeletion([secondAsset], editor: editor)
        await model.confirmPermanentDeletion()
        XCTAssertNil(model.error); XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "A referenced original stays on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(model.selected?.id, firstAsset.id); XCTAssertEqual(model.total, 1)
    }
    @MainActor func testTrashAndConfirmationSnapshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional catalog trash snapshots") }
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store), prepared = try CatalogImporter.prepare(original)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.moveToTrash([asset], editor: editor); await model.showCollection(trash: true)
        await model.selectAsset(try XCTUnwrap(model.assets.first))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { model.cancelPermanentDeletion(); window.close() }
        try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        try capture(host, "ceviche-catalog-trash")
        await model.requestPermanentDeletion([asset], editor: editor)
        for _ in 0..<30 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(300))
        try capture(XCTUnwrap(sheet.contentView), "ceviche-catalog-delete")
        model.cancelPermanentDeletion()
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    @MainActor private func capture(_ view: NSView, _ name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
    }
    @MainActor func testUncheckedDeletionLeavesReferencedOriginal() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store), prepared = try CatalogImporter.prepare(original)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.refresh(); await model.selectAsset(asset)
        await editor.open(original, catalog: store, asset: asset)
        await model.requestPermanentDeletion([asset], editor: editor)
        let plan = try XCTUnwrap(model.pendingDeletion)
        XCTAssertEqual(plan.removal.entries.map(\.id), [asset.id]); XCTAssertTrue(plan.removal.copies.isEmpty)
        XCTAssertTrue(model.interactionBusy, "A pending confirmation blocks other catalog changes")
        XCTAssertFalse(editor.hasImage, "The open photo closes before its record can go")
        XCTAssertEqual(model.total, 1, "Nothing changes until the plan is confirmed")
        model.cancelPermanentDeletion()
        XCTAssertNil(model.pendingDeletion); XCTAssertFalse(model.interactionBusy)
        await model.requestPermanentDeletion([asset], editor: editor)
        await model.confirmPermanentDeletion()
        XCTAssertNil(model.error); XCTAssertNil(model.pendingDeletion); XCTAssertNil(model.selected)
        XCTAssertEqual(model.total, 0); XCTAssertEqual(model.trashCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(model.notice, "Removed from the library")
    }
    /// Copies the catalog made go with their photos; referenced originals stay, decided from the catalog alone.
    @MainActor func testCopiesGoWithTheirPhotosAndReferencesStay() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let copied = try CatalogImporter.prepare(original, options: .init(mode: .copy, catalogRoot: store.root))
        let copy = try await store.insert(copied.0, thumbnail: copied.1)
        let referenced = try CatalogImporter.prepare(original)
        let reference = try await store.insert(referenced.0, thumbnail: referenced.1)
        await model.refresh()
        await model.requestPermanentDeletion([copy], editor: editor)
        XCTAssertEqual(model.pendingDeletion?.removal.references.isEmpty, true, "Only copies: no files stay")
        model.cancelPermanentDeletion()
        await model.requestPermanentDeletion([copy, reference], editor: editor)
        XCTAssertEqual(model.pendingDeletion?.removal.references.map(\.id), [reference.id])
        let copyURL = CatalogImporter.sourceURL(for: copy, root: store.root)
        await model.confirmPermanentDeletion()
        XCTAssertNil(model.error); XCTAssertEqual(model.total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path), "The catalog's copy goes with its photo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Unticked, the referenced original stays")
    }
    /// Ticked, a mixed list deletes the referenced originals too, each checked only as it goes.
    @MainActor func testTickedMixedListDeletesReferencedOriginals() async throws {
        let (directory, original) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults), editor = EditorModel()
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let copied = try CatalogImporter.prepare(original, options: .init(mode: .copy, catalogRoot: store.root))
        let copy = try await store.insert(copied.0, thumbnail: copied.1)
        let referenced = try CatalogImporter.prepare(original)
        let reference = try await store.insert(referenced.0, thumbnail: referenced.1)
        await model.refresh()
        await model.requestPermanentDeletion([copy, reference], editor: editor)
        XCTAssertFalse(model.deleteReferencedFiles, "Unticked at first")
        model.deleteReferencedFiles = true
        let copyURL = CatalogImporter.sourceURL(for: copy, root: store.root)
        await model.confirmPermanentDeletion()
        XCTAssertNil(model.error); XCTAssertEqual(model.total, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "Ticked, the referenced original goes too")
    }
}
