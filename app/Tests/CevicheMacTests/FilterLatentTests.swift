import XCTest
import CevicheCore
import CevicheTestSupport
import Metal
import AppKit
@testable import CevicheMac

/// Creative Filters' latent images: an output leaves one per photo, and opening one edits it in place.
final class FilterLatentTests: XCTestCase {
    @MainActor func testOutputLeavesALatentImageThatReopensAndFollowsTheStack() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: defaults)
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        let prepared = try CatalogImporter.prepare(url)
        let photo = try await store.insert(prepared.0, thumbnail: prepared.1)

        let stack = CreativeFilterStack([CreativeFilter(.glow), CreativeFilter(.border)])
        @MainActor final class Kept { var ids: [String: String] = [:] }
        let kept = Kept()
        catalog.keepFilterLatents([photo], stack: stack, kept: { kept.ids[$0] }, saved: { kept.ids[$0] = $1 })
        for _ in 0..<1500 where kept.ids.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let latentID = try XCTUnwrap(kept.ids[photo.id], catalog.error ?? "no latent image saved")
        let object = try await store.asset(latentID)
        XCTAssertTrue(object.isLatent)
        let bundle = CatalogImporter.sourceURL(for: object, root: store.root)
        XCTAssertEqual(try LatentImage.load(bundle).filterStack(), stack)
        // Develop shows it in the filmstrip with the preview it saved, and opening it there edits nothing.
        XCTAssertNotNil(NSImage(contentsOf: LatentImage.previewURL(in: bundle)))
        let editor = EditorModel()
        let openedLatent = await catalog.openPhoto(object, editor: editor)
        XCTAssertTrue(openedLatent)
        XCTAssertEqual(catalog.latentShown?.id, latentID)
        XCTAssertEqual(Set(catalog.browsingAssets.map(\.id)), [photo.id, latentID])
        XCTAssertFalse(editor.hasImage)
        XCTAssertFalse(catalog.toolOpen, "browsing must never open a tool")
        XCTAssertFalse(catalog.canShow(.compare, editor: editor))
        let openedPhoto = await catalog.openPhoto(photo, editor: editor)
        XCTAssertTrue(openedPhoto)
        XCTAssertNil(catalog.latentShown)
        await catalog.closePhoto(editor: editor)
        // Another output from the same window (a second Print) updates it.
        let printed = CreativeFilterStack([CreativeFilter(.glow)])
        catalog.keepFilterLatents([photo], stack: printed, kept: { kept.ids[$0] }, saved: { kept.ids[$0] = $1 })
        for _ in 0..<1500 where (try? LatentImage.load(bundle).filterStack()) != printed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try LatentImage.load(bundle).filterStack(), printed)
        let afterPrint = try await store.assets()
        XCTAssertEqual(afterPrint.count, 2)
        catalog.keepFilterLatents([photo], stack: stack, kept: { kept.ids[$0] }, saved: { kept.ids[$0] = $1 })
        for _ in 0..<1500 where (try? LatentImage.load(bundle).filterStack()) != stack { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try LatentImage.load(bundle).sources.map(\.assetID), [photo.id])

        catalog.openLatent(object)
        for _ in 0..<100 where catalog.filters == nil { try await Task.sleep(for: .milliseconds(20)) }
        let request = try XCTUnwrap(catalog.filters)
        XCTAssertEqual(request.assets.map(\.id), [photo.id])
        XCTAssertEqual(request.latent?.assetID, object.id)
        let model = FiltersModel(request: request)
        XCTAssertEqual(model.stack, stack, "the latent's stack, not the last one used")
        model.start(catalog: catalog)
        for _ in 0..<1500 where model.stage == .reading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.stage, .ready)
        model.setOn(.border, false)
        let edited = model.stack
        model.close(catalog: catalog)
        for _ in 0..<1500 where (try? LatentImage.load(bundle).filterStack()) != edited { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try LatentImage.load(bundle).filterStack(), edited, catalog.error ?? "closing saves the edited stack")
        let assets = try await store.assets()
        XCTAssertEqual(assets.count, 2, "editing an opened latent image never adds another")
    }
}
