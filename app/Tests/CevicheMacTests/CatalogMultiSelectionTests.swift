import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogMultiSelectionTests: XCTestCase {
    @MainActor func testMultiSelectionLayoutWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional multi-selection snapshots") }
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.selectAsset(model.assets[0]); model.select(model.assets[2], extending: true)
        try await EditorFixtures.settle(model, id: model.assets[2].id)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { model.cancelPermanentDeletion(); window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        func capture(_ view: NSView, _ name: String) throws {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
        }
        try capture(host, "ceviche-multi-selection")
        await model.requestPermanentDeletion(model.selectedAssets, editor: editor)
        for _ in 0..<30 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(50)) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(200))
        try capture(XCTUnwrap(sheet.contentView), "ceviche-multi-confirmation")
        model.cancelPermanentDeletion()
    }
    @MainActor func testRangeToggleKeyboardAndContextTargets() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = model.assets
        await model.selectAsset(photos[1]); model.metadata.title = "Keep metadata"
        model.select(photos[4], extending: true)
        try await EditorFixtures.settle(model, id: photos[4].id)
        XCTAssertEqual(model.selectedIDs, Set(photos[1...4].map(\.id)))
        model.moveLibrarySelection(.left, extending: true)
        try await EditorFixtures.settle(model, id: photos[3].id)
        XCTAssertEqual(model.selectedIDs, Set(photos[1...3].map(\.id)))
        model.select(photos[5], toggling: true)
        try await EditorFixtures.settle(model, id: photos[5].id)
        XCTAssertEqual(model.selectedIDs, Set([1, 2, 3, 5].map { photos[$0].id }))
        model.select(photos[2], toggling: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.selectedIDs, Set([1, 3, 5].map { photos[$0].id }))
        XCTAssertEqual(Set(model.contextAssets(for: photos[3]).map(\.id)), model.selectedIDs)
        XCTAssertEqual(model.contextAssets(for: photos[0]).map(\.id), [photos[0].id])
        let saved = try await XCTUnwrap(model.store).asset(photos[1].id)
        XCTAssertEqual(saved.title, "Keep metadata")
        // Rapid repeats extend from the pending focus without skipping the anchor.
        model.select(photos[0]); try await EditorFixtures.settle(model, id: photos[0].id)
        model.moveLibrarySelection(.right, extending: true)
        model.moveLibrarySelection(.right, extending: true)
        model.moveLibrarySelection(.right, extending: true)
        try await EditorFixtures.settle(model, id: photos[3].id)
        XCTAssertEqual(model.selectedIDs, Set(photos[0...3].map(\.id)))
        model.filter.search = photos[2].filename; await model.refresh()
        try await EditorFixtures.settle(model, id: photos[2].id)
        XCTAssertEqual(model.selectedIDs, [photos[2].id])
        model.select(photos[2], toggling: true)
        try await EditorFixtures.settle(model, id: nil)
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    @MainActor func testAFoldedGroupIsSelectedAsAllItsPhotosAndStaysSelectedWhenExpanded() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = model.assets
        let grouped = Set(photos[1...3].map(\.id))
        await model.group(Array(photos[1...3]))
        let cover = try XCTUnwrap(model.assets.first { $0.stackID == $0.id })
        try await EditorFixtures.settle(model, id: cover.id)
        XCTAssertEqual(model.assets.count, 4)
        // The cover alone is selected, and stands for its group wherever the selection is acted on.
        XCTAssertEqual(model.selectedIDs, [cover.id])
        XCTAssertEqual(model.selectionCount, 3)
        XCTAssertEqual(model.selectedAssets.map(\.id).first, cover.id)
        XCTAssertEqual(Set(model.selectedAssets.map(\.id)), grouped)
        XCTAssertEqual(model.selectedCell?.id, cover.id)
        // Right-clicking the folded group outside the selection takes the group too; another photo stays alone.
        model.select(photos[0]); try await EditorFixtures.settle(model, id: photos[0].id)
        XCTAssertEqual(Set(model.contextAssets(for: cover).map(\.id)), grouped)
        XCTAssertEqual(model.contextAssets(for: photos[0]).map(\.id), [photos[0].id])
        XCTAssertEqual(Set(model.photoDrag(for: cover).assetIDs), grouped)
        // Expanding shows the photos one by one, all selected, until another click.
        model.toggleGroup(cover)
        try await EditorFixtures.settle(model, id: cover.id)
        XCTAssertEqual(model.selectedIDs, grouped)
        await model.refresh()
        XCTAssertEqual(model.assets.count, 6)
        XCTAssertEqual(model.selectedIDs, grouped)
        XCTAssertEqual(model.selectionCount, 3)
        // The collapse control stays on the leading displayed member, not the cover that sorts last.
        let expandedMembers = model.assets.filter { $0.stackID == cover.id }
        let leading = try XCTUnwrap(expandedMembers.first)
        XCTAssertNotEqual(leading.id, cover.id)
        let badge = try XCTUnwrap(model.groupBadge(for: leading))
        XCTAssertEqual(badge.count, 3)
        XCTAssertTrue(badge.expanded)
        XCTAssertNotNil(badge.toggle)
        for other in expandedMembers.dropFirst() { XCTAssertNil(model.groupBadge(for: other)?.toggle) }
        // Expanded, one photo of the group is just that photo.
        let member = try XCTUnwrap(model.assets.first { $0.stackID == cover.id && $0.id != cover.id })
        model.select(member); try await EditorFixtures.settle(model, id: member.id)
        XCTAssertEqual(model.selectedAssets.map(\.id), [member.id])
        badge.toggle?()
        await model.refresh()
        try await EditorFixtures.settle(model, id: cover.id)
        XCTAssertFalse(model.groupExpanded(cover))
        XCTAssertEqual(model.assets.count, 4)
        XCTAssertNotNil(model.groupBadge(for: cover)?.toggle)
    }
    @MainActor func testBatchPasteTrashAndRecoverKeepOriginalsAndHistory() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        var copied = Adjustments(); copied.exposure = 0.85
        editor.captureEdits(copied, baseline: Adjustments(), name: "Source")
        let targets = Array(photos[1...3])
        await model.selectAsset(targets[0]); model.metadata.title = "Destination"
        await model.pasteEdits(to: targets, editor: editor)
        XCTAssertNil(model.error); XCTAssertNil(model.failure)
        for photo in targets {
            let saved = try await EditorFixtures.withCurrentThumbnail(store, id: photo.id)
            let settings = try JSONDecoder().decode(Adjustments.self, from: XCTUnwrap(saved.adjustmentsData))
            XCTAssertEqual(settings.exposure, 0.85)
            XCTAssertEqual(saved.thumbnailRenderKey, saved.renderKey)
            let history = try await store.history(assetID: photo.id)
            XCTAssertTrue(history.contains { $0.summary == "Original development" })
        }
        let untouched = try await store.photo(photos[0].id)
        XCTAssertNil(untouched.adjustmentsData)
        let saved = try await store.photo(targets[0].id)
        XCTAssertEqual(saved.title, "Destination")
        await model.moveToTrash(targets, editor: editor)
        XCTAssertNil(model.error); XCTAssertNil(model.failure); XCTAssertEqual(model.trashCount, 3); XCTAssertEqual(model.total, 3)
        for photo in photos { XCTAssertTrue(FileManager.default.fileExists(atPath: photo.sourcePath)) }
        await model.showCollection(trash: true)
        await model.recoverFromTrash(model.assets)
        XCTAssertNil(model.error); XCTAssertNil(model.failure); XCTAssertEqual(model.trashCount, 0); XCTAssertEqual(model.total, 6)
        let recovered = try await store.photo(targets[0].id)
        XCTAssertEqual(recovered.adjustmentsData, saved.adjustmentsData)
    }
    @MainActor func testBatchRemovalFreezesConfirmationAndKeepsReferencedFiles() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        var shared = try await store.photo(photos[0].id); shared.id = UUID().uuidString; shared.importPath += ".ceviche"
        _ = try await store.insert(shared, thumbnail: nil)
        let targets = [photos[0], shared.asset, photos[1], photos[0]]
        await model.requestPermanentDeletion(targets, editor: editor)
        XCTAssertEqual(model.pendingDeletion?.removal.entries.count, 3, "Each photo once")
        model.select(photos[5]) // Pending confirmation blocks selection changes.
        await model.confirmPermanentDeletion()
        XCTAssertNil(model.error); XCTAssertNil(model.failure); XCTAssertEqual(model.total, 4)
        for photo in photos { XCTAssertTrue(FileManager.default.fileExists(atPath: photo.sourcePath), "Referenced originals stay") }
    }
    /// Ticked, a file changed since import is skipped and reported at the end; the rest still go.
    @MainActor func testTickedDeletionSkipsChangedFilesAndReportsThem() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = model.assets
        await model.requestPermanentDeletion([photos[0], photos[1]], editor: editor); model.deleteReferencedFiles = true
        let changed = URL(fileURLWithPath: photos[1].sourcePath)
        try Data("changed".utf8).write(to: changed)
        await model.confirmPermanentDeletion()
        XCTAssertEqual(model.failure?.message.hasPrefix("1 photo couldn’t be deleted."), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photos[0].sourcePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path), "A changed file isn't this photo's to delete")
        XCTAssertEqual(model.total, photos.count - 1)
    }
    @MainActor func testPagingAppendsAndSelectAllReachesUnloadedPhotos() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        let template = try XCTUnwrap(model.assets.first)
        for index in 0..<CatalogModel.pageSize {
            var copy = try await store.photo(template.id)
            copy.id = UUID().uuidString; copy.importPath += "-copy-\(index)"
            _ = try await store.insert(copy, thumbnail: nil)
        }
        await model.refresh()
        XCTAssertEqual(model.assets.count, CatalogModel.pageSize)
        XCTAssertTrue(model.hasMore)
        let firstPage = model.assets.map(\.id)
        model.loadMore()
        for _ in 0..<50 where model.hasMore { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(Array(model.assets.prefix(firstPage.count)).map(\.id), firstPage, "Paging appends without reordering")
        XCTAssertEqual(Set(model.assets.map(\.id)).count, CatalogModel.pageSize + 6)
        await model.showCollection(trash: false)
        XCTAssertTrue(model.hasMore)
        model.selectAll()
        for _ in 0..<50 where model.selectedIDs.count < CatalogModel.pageSize + 6 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.selectedIDs.count, CatalogModel.pageSize + 6, "Select All covers every matching photo")
    }

    @MainActor func testSelectionPushedPastTheLoadedPageByAnImportStaysSelected() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        let template = try XCTUnwrap(model.assets.first)
        for index in 0..<CatalogModel.pageSize {
            var copy = try await store.photo(template.id)
            copy.id = UUID().uuidString; copy.importPath += "-copy-\(index)"
            _ = try await store.insert(copy, thumbnail: nil)
        }
        model.setSort(.importDate, ascending: false); await model.refresh()
        XCTAssertEqual(model.assets.count, CatalogModel.pageSize)
        let target = try XCTUnwrap(model.assets.last)
        await model.selectAsset(target)
        XCTAssertEqual(model.selectedIDs, [target.id])
        // Newer photos land ahead of it, so it falls past the loaded page while still in the collection.
        for index in 0..<10 {
            var copy = try await store.photo(template.id)
            copy.id = UUID().uuidString; copy.importPath += "-new-\(index)"; copy.importedAt = Date().addingTimeInterval(3600)
            _ = try await store.insert(copy, thumbnail: nil)
        }
        await model.refresh()
        XCTAssertFalse(model.assets.contains { $0.id == target.id })
        XCTAssertEqual(model.selectedIDs, [target.id]); XCTAssertEqual(model.selected?.id, target.id)
        // Gone from the collection, it is deselected.
        try await store.moveToTrash([target.id])
        await model.refresh()
        XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertNil(model.selected)
    }
}
