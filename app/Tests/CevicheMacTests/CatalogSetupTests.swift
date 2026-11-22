import XCTest
import ImageIO
import UniformTypeIdentifiers
import CevicheCore
@testable import CevicheMac

final class CatalogSetupTests: XCTestCase {
    @MainActor func testCloseSavesMetadataAndReturnsToWelcomeWithoutDeletingCatalog() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences), editor = EditorModel()
        let root = directory.appendingPathComponent("Catalog")
        await model.openCatalog(root)
        let store = try XCTUnwrap(model.store)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.refresh(); await model.selectAsset(asset)
        model.metadata.title = "Saved before closing"
        await model.closeCatalog(editor: editor)
        XCTAssertNil(model.store); XCTAssertNil(model.root); XCTAssertTrue(model.needsSetup)
        XCTAssertTrue(model.assets.isEmpty); XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertEqual(model.total, 0); XCTAssertNil(model.syncState)
        XCTAssertEqual(model.knownCatalogs.count, 1)
        let saved = try await store.asset(asset.id)
        XCTAssertEqual(saved.title, "Saved before closing")
        let restarted = CatalogModel(preferences: preferences)
        await restarted.start()
        XCTAssertTrue(restarted.needsSetup); XCTAssertNil(restarted.store)
        await restarted.openCatalog(root)
        XCTAssertEqual(restarted.assets.first?.title, "Saved before closing")
        XCTAssertFalse(preferences.bool(forKey: "catalogClosed"))
    }
    func testRemovingADeletedCloudReplicaKeepsCopiesOnlyThisMacHas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default
        let empty = directory.appendingPathComponent("A.cevichecatalog")
        try fm.createDirectory(at: empty.appendingPathComponent("Originals/2024-05"), withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent("catalog.sqlite"))
        XCTAssertNil(try CatalogModel.removeReplica(at: empty, keepingOriginalsAs: "Empty"))
        XCTAssertFalse(fm.fileExists(atPath: empty.path))
        let replica = directory.appendingPathComponent("B.cevichecatalog")
        try fm.createDirectory(at: replica.appendingPathComponent("Originals/2024-05"), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: replica.appendingPathComponent("Originals/2024-05/IMG_0001.DNG"))
        try Data().write(to: replica.appendingPathComponent("catalog.sqlite"))
        let kept = try XCTUnwrap(CatalogModel.removeReplica(at: replica, keepingOriginalsAs: "Trips/2024"))
        XCTAssertEqual(kept.lastPathComponent, "Trips-2024 Originals")
        XCTAssertFalse(fm.fileExists(atPath: replica.path))
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("2024-05/IMG_0001.DNG")), Data("raw".utf8))
    }
    func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("card.jpg")
        let context = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:10:23 12:13:14"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, url)
    }
    @MainActor func testFreshInstallationShowsWelcomeInsteadOfCreatingACatalog() async throws {
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        guard !CatalogModel.catalogExists(at: CatalogModel.defaultCatalogRoot) else { throw XCTSkip("A default catalog exists on this Mac") }
        let model = CatalogModel(preferences: preferences)
        await model.start()
        XCTAssertTrue(model.needsSetup); XCTAssertNil(model.store); XCTAssertNil(model.missingCatalog)
        XCTAssertFalse(CatalogModel.catalogExists(at: CatalogModel.defaultCatalogRoot), "Nothing is created until the person chooses")
    }
    @MainActor func testCreatedCatalogsCarryTheirKindAndAreRemembered() async throws {
        let (directory, _) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        let chosen = directory.appendingPathComponent("Chosen.cevichecatalog")
        await model.openCatalog(chosen, manifest: CatalogManifest(name: "Chosen", kind: .file))
        XCTAssertEqual(model.manifest?.kind, .file); XCTAssertFalse(model.needsSetup); XCTAssertNil(model.syncState)
        let cloud = CatalogManifest(name: "Everywhere", kind: .cloud)
        await model.openCatalog(directory.appendingPathComponent("Cloud.cevichecatalog"), manifest: cloud)
        XCTAssertEqual(model.manifest?.kind, .cloud); XCTAssertEqual(model.manifest?.id, cloud.id)
        try await Task.sleep(for: .milliseconds(800))
        let state = try XCTUnwrap(model.syncState, "iCloud catalogs report a sync state")
        if case .unavailable = state {} else if CloudSyncEngine.entitledContainers.isEmpty { XCTFail("An unsigned test process cannot reach iCloud: \(state)") }
        XCTAssertEqual(model.knownCatalogs.map(\.name), ["Everywhere", "Chosen"])
        XCTAssertEqual(model.recentCatalogs(iCloudEnabled: false).map(\.name), ["Chosen"])
        XCTAssertEqual(model.recentCatalogs(iCloudEnabled: true).map(\.name), ["Everywhere", "Chosen"])
        let again = CatalogModel(preferences: preferences)
        XCTAssertEqual(again.knownCatalogs.map(\.kind), [.cloud, .file], "The list survives relaunch")
        await model.openCatalog(chosen)
        XCTAssertEqual(model.manifest?.name, "Chosen", "An existing catalog keeps its manifest")
        XCTAssertNil(model.syncState)
    }
    @MainActor func testImportsRunningTogetherAddEachPhotoOnce() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        model.importMode = .reference
        XCTAssertTrue(model.importFiles([url])); XCTAssertTrue(model.importFiles([url]), "A second import starts beside the first")
        XCTAssertEqual(model.activity.running.filter { $0.kind == .importing }.count, 2)
        while model.importing { try await Task.sleep(for: .milliseconds(10)) }
        await model.refresh()
        XCTAssertEqual(model.assets.count, 1)
    }
    @MainActor func testQuickImportCanCopyOriginalsAndSkipsPhotosTheCatalogHas() async throws {
        let (directory, url) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        let root = directory.appendingPathComponent("Catalog")
        await model.openCatalog(root)
        model.importMode = .copy
        XCTAssertTrue(model.importFiles([url]))
        // The title bar's progress names the photo and the count while the import runs, and clears after.
        var progress: Activity?
        while model.importing { if let current = model.activity.running.first(where: { $0.total != nil }) { progress = current }; try await Task.sleep(for: .milliseconds(1)) }
        if let progress { XCTAssertEqual(progress.total, 1); XCTAssertEqual(progress.detail, "1 of 1 - card.jpg"); XCTAssertEqual(progress.fraction, 0) }
        XCTAssertTrue(model.activity.isEmpty)
        // Recent keeps what the import did, with Show for the photo.
        let finished = try XCTUnwrap(model.activity.recent.first)
        XCTAssertEqual(finished.outcome, .done("1 photo imported"))
        XCTAssertNotNil(finished.result)
        XCTAssertNil(model.notice, "A successful import needs no notice")
        XCTAssertEqual(model.assets.count, 1)
        XCTAssertEqual(model.assets[0].locator, .catalog(relativePath: "Originals/2025-10/card.jpg"))
        XCTAssertTrue(model.availability.isEmpty, "A copy inside the catalog is available")
        // The same photo elsewhere (a card re-inserted, a laptop copy) is recognized by name and capture time.
        let elsewhere = directory.appendingPathComponent("Elsewhere"); try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: elsewhere.appendingPathComponent("card.jpg"))
        XCTAssertTrue(model.importFiles([elsewhere.appendingPathComponent("card.jpg")]))
        while model.importing { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.assets.count, 1); XCTAssertEqual(model.notice, "1 already in the catalog")
        // Referencing a file that later disappears marks the photo offline on the next refresh.
        model.importMode = .reference
        let other = directory.appendingPathComponent("other.jpg"); try FileManager.default.copyItem(at: url, to: other)
        XCTAssertTrue(model.importFiles([other]))
        while model.importing { try await Task.sleep(for: .milliseconds(50)) }
        // The grid switches to the new batch: just this photo, of the catalog's two.
        XCTAssertEqual(model.assets.map(\.filename), ["other.jpg"]); XCTAssertEqual(model.total, 2)
        try FileManager.default.removeItem(at: other)
        await model.refresh(); try await Task.sleep(for: .milliseconds(300))
        let offline = try XCTUnwrap(model.assets.first { $0.filename == "other.jpg" })
        XCTAssertTrue(model.availability[offline.id]?.isOffline == true)
        let opened = await model.openPhoto(offline, editor: EditorModel())
        XCTAssertFalse(opened); XCTAssertTrue(model.failure?.message.contains("offline") == true, model.failure?.message ?? "")
    }
}
