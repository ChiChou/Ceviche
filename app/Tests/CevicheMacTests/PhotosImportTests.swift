import XCTest
import CevicheCore
@testable import CevicheMac

final class PhotosImportTests: XCTestCase {
    @MainActor func testTemporaryPhotoImportSurvivesCleanupAndCatalogReopen() async throws {
        let (directory, source) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = try Data(contentsOf: source)
        let photo = try PickedPhoto.stage(source)
        defer { photo.file.remove() }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: defaults)
        defer { catalog.stopIndexing() }
        let root = directory.appendingPathComponent("Catalog")
        await catalog.openCatalog(root)
        let store = try XCTUnwrap(catalog.store)
        // The Photos picker hands its staged file to this download-based import path.
        let item = CatalogModel.ImportItem(url: nil, locator: nil, download: { _ in photo.file })
        let job = catalog.activity.start(.importing, title: "Test") { job in
            await catalog.runImport([item], mode: .copy, store: store, job: job)
        }
        await catalog.activity.wait(job)
        XCTAssertNil(catalog.error)
        let asset = try XCTUnwrap(catalog.assets.first)
        XCTAssertTrue(asset.isCopy)
        XCTAssertEqual(asset.locator.scheme, .catalog)
        photo.file.remove()
        try FileManager.default.removeItem(at: source)
        let reopened = try CatalogStore(root: root)
        let persisted = try await reopened.asset(asset.id)
        let original = CatalogImporter.sourceURL(for: persisted, root: root)
        XCTAssertTrue(original.path.hasPrefix(root.appendingPathComponent("Originals").path + "/"))
        XCTAssertEqual(try Data(contentsOf: original), expected)
    }
    func testProviderFileSurvivesProviderCleanupWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("IMG_1234.dng")
        let bytes = Data([0, 1, 2, 3, 255])
        try bytes.write(to: source)
        let photo = try PickedPhoto.stage(source)
        defer { photo.file.remove() }
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(photo.file.url.lastPathComponent, "IMG_1234.dng")
        XCTAssertEqual(try Data(contentsOf: photo.file.url), bytes)
        photo.file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.file.directory.path))
    }
}
