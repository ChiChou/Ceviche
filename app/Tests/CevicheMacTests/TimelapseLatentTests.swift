import XCTest
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

/// Timelapse's latent image: a video leaves one with the settings, framing and photos left out; it reopens as left.
final class TimelapseLatentTests: XCTestCase {
    @MainActor func testVideoLeavesALatentImageThatReopensAsLeft() async throws {
        let (directory, first) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: defaults)
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        var assets: [CatalogAsset] = []
        for index in 0..<3 {
            let url = index == 0 ? first : directory.appendingPathComponent("Frame\(index).\(first.pathExtension)")
            if index > 0 { try FileManager.default.copyItem(at: first, to: url) }
            let prepared = try CatalogImporter.prepare(url)
            assets.append(try await store.insert(prepared.0, thumbnail: prepared.1))
        }
        func ready(_ model: TimelapseModel) async throws {
            for _ in 0..<1500 where model.stage != .ready { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(model.stage, .ready)
        }

        UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.timelapse))
        defer { UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.timelapse)) }
        let model = TimelapseModel(request: TimelapseRequest(assets: assets))
        model.start(catalog: catalog)
        try await ready(model)
        model.keepLatent(catalog: catalog, output: false)
        XCTAssertNil(model.latentAssetID, "closing without a video keeps nothing")
        model.remove([assets[2].id])
        model.settings.framesPerSecond = 30
        model.settings.crop = TimelapseCrop(centerX: 0.4, centerY: 0.6, scale: 0.7)
        let settings = model.settings
        model.keepLatent(catalog: catalog, output: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.latentAssetID, "a video keeps nothing until Keep Latent Image is ticked")
        UserDefaults.standard.set(true, forKey: LatentPreference.key(LatentImage.timelapse))
        model.keepLatent(catalog: catalog, output: true)
        for _ in 0..<1500 where model.latentAssetID == nil { try await Task.sleep(for: .milliseconds(20)) }
        let object = try await store.asset(XCTUnwrap(model.latentAssetID, catalog.error ?? "no latent image"))
        model.stop()
        let bundle = CatalogImporter.sourceURL(for: object, root: store.root)
        let saved = try LatentImage.load(bundle).timelapseSettings()
        XCTAssertEqual(saved.settings, settings)
        XCTAssertEqual(saved.removed, [assets[2].id])

        catalog.openLatent(object)
        for _ in 0..<100 where catalog.timelapse == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reopened = TimelapseModel(request: try XCTUnwrap(catalog.timelapse))
        XCTAssertEqual(reopened.settings, settings, "the framing comes back with the photos it was made for")
        reopened.start(catalog: catalog)
        try await ready(reopened)
        XCTAssertEqual(reopened.frames.count, 2)
        XCTAssertEqual(reopened.removed, [assets[2].id])
        reopened.restoreRemoved()
        reopened.close(catalog: catalog)
        for _ in 0..<1500 where (try? LatentImage.load(bundle).timelapseSettings().removed) != [] { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try LatentImage.load(bundle).timelapseSettings().removed, [], "closing updates it")
        let latents = try await store.assets().filter(\.isLatent)
        XCTAssertEqual(latents.count, 1)
    }
}
