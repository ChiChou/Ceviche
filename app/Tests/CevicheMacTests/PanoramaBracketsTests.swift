import XCTest
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

/// Merge to Panorama on brackets: HDR turns on by itself, and turned off the photos are stitched as they are.
final class PanoramaBracketsTests: XCTestCase {
    @MainActor private func ready(_ model: PanoramaMergeModel) async throws {
        for _ in 0..<1200 where model.stage != .ready { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.stage, .ready)
    }

    @MainActor func testBracketsTurnHDROn() async throws {
        let sources = try TestSamples.requireFiles(TestSamples.hdrPanorama.dng, extensions: CatalogImporter.rawExtensions)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PanoramaBrackets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try await EditorFixtures.catalog(of: sources, in: directory)
        catalog.requestPanoramaMerge(catalog.assets)
        let model = PanoramaMergeModel(request: try XCTUnwrap(catalog.panoramaMerge))
        defer { model.stop() }
        model.start(catalog: catalog)
        try await ready(model)
        XCTAssertTrue(model.hdr)
        XCTAssertEqual(model.grouping?.groups.map(\.count), [3, 3, 3])
        XCTAssertEqual(model.alignment?.filenames.count, 3, "one merged frame per position")

        model.setDeghosting(.high, catalog: catalog)
        try await ready(model)
        XCTAssertEqual(model.alignment?.filenames.count, 3, "the brackets merge again")

        model.setHDR(false, catalog: catalog)
        try await ready(model)
        XCTAssertEqual(model.alignment?.filenames.count, 9)
    }

    /// Merge leaves a latent image with the options and the alignment; opening it skips aligning, and a source changed
    /// since makes it align again.
    @MainActor func testLatentImageKeepsTheAlignment() async throws {
        let sources = try TestSamples.requireFiles(TestSamples.hdrPanorama.dng, extensions: CatalogImporter.rawExtensions)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PanoramaLatent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try await EditorFixtures.catalog(of: sources, in: directory)
        let store = try XCTUnwrap(catalog.store)
        UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.panorama))
        defer { UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.panorama)) }
        catalog.requestPanoramaMerge(catalog.assets)
        let model = PanoramaMergeModel(request: try XCTUnwrap(catalog.panoramaMerge))
        model.start(catalog: catalog)
        try await ready(model)
        model.setHDR(false, catalog: catalog)
        try await ready(model)
        for _ in 0..<600 where model.preview == nil { try await Task.sleep(for: .milliseconds(50)) }
        let projection = try XCTUnwrap(model.alignment?.available.first { $0 != model.settings.projection })
        model.settings.projection = projection
        model.settings.boundaryWarp = 0.4
        let included = model.alignment?.included
        model.keepLatent(catalog: catalog, output: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.latentAssetID, "a merge keeps nothing until Keep Latent Image is ticked")
        UserDefaults.standard.set(true, forKey: LatentPreference.key(LatentImage.panorama))
        model.keepLatent(catalog: catalog, output: true)
        for _ in 0..<600 where model.latentAssetID == nil { try await Task.sleep(for: .milliseconds(50)) }
        let object = try await store.asset(XCTUnwrap(model.latentAssetID, catalog.error ?? "no latent image"))
        model.close(catalog: catalog)
        let saved = try LatentImage.load(CatalogImporter.sourceURL(for: object, root: store.root)).panoramaSettings()
        XCTAssertFalse(saved.hdr); XCTAssertNotNil(saved.solved); XCTAssertEqual(saved.settings.projection, projection)

        func reopen() async throws -> PanoramaMergeModel {
            catalog.openLatent(object)
            for _ in 0..<100 where catalog.panoramaMerge == nil { try await Task.sleep(for: .milliseconds(20)) }
            let reopened = PanoramaMergeModel(request: try XCTUnwrap(catalog.panoramaMerge))
            reopened.start(catalog: catalog)
            try await ready(reopened)
            for _ in 0..<600 where reopened.preview == nil && reopened.previewError == nil { try await Task.sleep(for: .milliseconds(50)) }
            return reopened
        }
        let reopened = try await reopen()
        XCTAssertTrue(reopened.restored, "the saved alignment is used")
        XCTAssertFalse(reopened.hdr)
        XCTAssertEqual(reopened.alignment?.included, included)
        XCTAssertEqual(reopened.settings.projection, projection); XCTAssertEqual(reopened.settings.boundaryWarp, 0.4)
        XCTAssertNotNil(reopened.preview, reopened.previewError ?? "no preview")
        reopened.close(catalog: catalog)
        for _ in 0..<100 where catalog.panoramaMerge != nil { try await Task.sleep(for: .milliseconds(20)) }

        // Touching a source's file changes its stamp: the alignment is found again rather than trusted.
        let first = CatalogImporter.sourceURL(for: try XCTUnwrap(catalog.assets.first { !$0.isLatent }), root: store.root)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: first.path)
        let realigned = try await reopen()
        XCTAssertFalse(realigned.restored)
        XCTAssertEqual(realigned.settings.projection, projection, "the options are kept")
        realigned.stop()
    }
}
