import XCTest
import CevicheCore
@testable import CevicheMac

final class CameraImportTests: XCTestCase {
    /// Looking for cameras and cards is what makes macOS ask for access to a connected card, so it waits for the
    /// person to choose Import from Camera: opening a catalog does not start it, the camera importer does, and
    /// closing the catalog stops it.
    @MainActor func testDiscoveryWaitsForTheCameraImporter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let catalog = CatalogModel(preferences: defaults), editor = EditorModel()
        defer {
            catalog.stopIndexing(); catalog.cameraImporter.stopDiscovery()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await catalog.openCatalog(root)
        let store = try XCTUnwrap(catalog.store)
        await catalog.refresh()
        XCTAssertFalse(catalog.cameraImporter.isDiscovering, "opening a catalog does not look for cards")
        catalog.requestCameraImport()
        XCTAssertTrue(catalog.showingCameraImport)
        XCTAssertFalse(catalog.cameraImporter.isDiscovering, "nor does asking for the importer, until it opens")
        await catalog.cameraImporter.start(store: store)
        XCTAssertTrue(catalog.cameraImporter.isDiscovering, "the camera importer looks for cameras and cards")
        await catalog.closeCatalog(editor: editor)
        XCTAssertFalse(catalog.cameraImporter.isDiscovering, "closing the catalog stops looking")
    }
    @MainActor func testSyntheticCardDownloadsIntoScratchCatalog() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_TEST_CAMERA_NAME"] == "CEVICHETEST" else {
            throw XCTSkip("Requires the synthetic CEVICHETEST disk image")
        }
        let model = CameraImportModel()
        model.startDiscovery()
        defer { model.stopDiscovery() }
        for _ in 0..<100 where !model.cameras.contains(where: { $0.name == "CEVICHETEST" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        model.requestedCamera = try XCTUnwrap(model.cameras.first { $0.name == "CEVICHETEST" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let catalog = CatalogModel(preferences: defaults)
        defer {
            catalog.stopIndexing(); catalog.cameraImporter.stopDiscovery()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await catalog.openCatalog(root)
        await model.start(store: try XCTUnwrap(catalog.store))
        for _ in 0..<150 where model.scanning || model.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let entry = try XCTUnwrap(model.entries.first { $0.filename == "IMG_0001.JPG" }, "scanning=\(model.scanning), error=\(model.error ?? "none"), files=\(model.camera?.mediaFiles?.count ?? -1)")
        model.selected = [entry.id]
        model.importSelection(into: catalog)
        for _ in 0..<300 where model.importing { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.importing)
        XCTAssertNil(catalog.error)
        XCTAssertEqual(catalog.assets.count, 1)
        XCTAssertEqual(catalog.assets.first?.filename, "IMG_0001.JPG")
        XCTAssertTrue(catalog.assets.first?.isCopy == true)
    }
    @MainActor func testConnectedCameraDiscoveryWithoutOpeningSession() async throws {
        guard let name = ProcessInfo.processInfo.environment["CEVICHE_TEST_CAMERA_NAME"] else {
            throw XCTSkip("Set CEVICHE_TEST_CAMERA_NAME for a connected-device discovery check")
        }
        let model = CameraImportModel()
        model.startDiscovery()
        defer { model.stopDiscovery() }
        for _ in 0..<100 {
            if model.cameras.contains(where: { $0.name == name }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.cameras.contains(where: { $0.name == name }))
        XCTAssertNil(model.camera, "Menu discovery must not open a session")
        XCTAssertTrue(model.entries.isEmpty)
    }
    @MainActor func testDownloadedOriginalIsOwnedAndDuplicateStagingIsRemoved() async throws {
        let (directory, jpeg) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        var staging: [URL] = []
        let item = CatalogModel.ImportItem(url: nil, locator: nil, transferPath: "DCIM/100/shot.jpg", download: { report in
            let folder = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("shot.jpg")
            try FileManager.default.copyItem(at: jpeg, to: url)
            staging.append(folder); report(1)
            return ImportedPhotoFile(url: url, directory: folder)
        })
        for _ in 0..<2 {
            let job = model.activity.start(.importing, title: "Test") { job in
                await model.runImport([item], mode: .copy, store: store, job: job)
            }
            await model.activity.wait(job)
        }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.assets.count, 1, "A reconnect/download must not create a second copy")
        let asset = try XCTUnwrap(model.assets.first)
        XCTAssertTrue(asset.isCopy)
        XCTAssertEqual(asset.locator.scheme, .catalog)
        XCTAssertFalse(staging.contains { asset.sourcePath.hasPrefix($0.path) })
        let original = CatalogImporter.sourceURL(for: asset, root: store.root)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: jpeg))
        XCTAssertEqual(staging.count, 2)
        XCTAssertTrue(staging.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        model.stopIndexing()
    }

    @MainActor func testFailedTransferDoesNotDiscardEarlierImport() async throws {
        let (directory, jpeg) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let folder = directory.appendingPathComponent("Staging")
        let good = CatalogModel.ImportItem(url: nil, locator: nil, transferPath: "DCIM/one.jpg", download: { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("one.jpg")
            try FileManager.default.copyItem(at: jpeg, to: url)
            return ImportedPhotoFile(url: url, directory: folder)
        })
        let bad = CatalogModel.ImportItem(url: nil, locator: nil, transferPath: "DCIM/two.jpg", download: { _ in
            throw NSError(domain: "CameraTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"])
        })
        let job = model.activity.start(.importing, title: "Test") { job in
            await model.runImport([good, bad], mode: .copy, store: store, job: job)
        }
        await model.activity.wait(job)
        XCTAssertEqual(model.assets.count, 1)
        XCTAssertTrue(model.failure?.message.contains("Disconnected") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        model.stopIndexing()
    }

    @MainActor func testCancellationBeforeIngestCleansDownloadedFile() async throws {
        let (directory, jpeg) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: defaults)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        let folder = directory.appendingPathComponent("Staging")
        var entered = false
        let item = CatalogModel.ImportItem(url: nil, locator: nil, transferPath: "DCIM/one.jpg", download: { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("one.jpg")
            try FileManager.default.copyItem(at: jpeg, to: url)
            entered = true
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return ImportedPhotoFile(url: url, directory: folder)
        })
        let job = model.activity.start(.importing, title: "Test") { job in
            await model.runImport([item], mode: .copy, store: store, job: job)
        }
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(entered)
        model.activity.cancel(job)
        await model.activity.wait(job)
        XCTAssertTrue(model.assets.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        model.stopIndexing()
    }

    @MainActor func testTransferCancellationSettlesAndCleansLateCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var completion: CameraDownload.Completion?
        var cancelled = false
        let transfer = try CameraDownload(directory: directory, begin: { _, callback in
            completion = callback; return Progress(totalUnitCount: 100)
        }, cancel: { cancelled = true })
        let task = Task { try await transfer.run { _ in } }
        for _ in 0..<100 where completion == nil { await Task.yield() }
        XCTAssertNotNil(completion)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer must not return a file") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // Some device drivers finish writing after cancellation. The late callback must
        // neither resume the continuation twice nor leave that partial download behind.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("late.jpg"))
        completion?("late.jpg", nil)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testTransferFailureAndDuplicateCompletionRespectOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var completion: CameraDownload.Completion?
        let transfer = try CameraDownload(directory: directory, begin: { folder, callback in
            completion = callback
            try! Data([1, 2, 3]).write(to: folder.appendingPathComponent("shot.jpg"))
            callback("shot.jpg", nil)
            return nil
        }, cancel: {})
        let lease = try await transfer.run { _ in }
        completion?("shot.jpg", nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path), "A duplicate completion cannot remove a file being ingested")
        lease.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let failed = try CameraDownload(directory: directory, begin: { _, callback in
            callback("../outside.jpg", nil); return nil
        }, cancel: {})
        do { _ = try await failed.run { _ in }; XCTFail("Must reject a path outside staging") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor func testCameraNamesAndPairFilteringDoNotNeedFilesystemPaths() {
        XCTAssertTrue(CameraImportModel.accepts("DSC0001.ARW"))
        XCTAssertFalse(CameraImportModel.accepts("../DSC0001.ARW"))
        XCTAssertFalse(CameraImportModel.accepts("movie.mp4"))
        XCTAssertFalse(CameraImportModel.accepts("edits.ceviche"))
        let items = ["DCIM/100/shot.ARW", "DCIM/100/shot.JPG", "DCIM/101/shot.JPG"].map {
            CatalogModel.ImportItem(url: nil, locator: nil, transferPath: $0)
        }
        XCTAssertEqual(RawJPEGImport.rawOnly.keep(items).map(\.transferPath), ["DCIM/100/shot.ARW", "DCIM/101/shot.JPG"])
        XCTAssertEqual(RawJPEGImport.processedOnly.keep(items).map(\.transferPath), ["DCIM/100/shot.JPG", "DCIM/101/shot.JPG"])
    }
}
