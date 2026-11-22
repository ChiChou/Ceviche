import XCTest
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

/// Focus Stack's latent image: a merge leaves one with the settings and the layer brush's strokes; it reopens with them.
final class FocusStackLatentTests: XCTestCase {
    @MainActor func testMergeLeavesALatentImageWithTheStrokes() async throws {
        let (directory, first) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("Second.\(first.pathExtension)")
        try FileManager.default.copyItem(at: first, to: second)
        let catalog = try await EditorFixtures.catalog(of: [first, second], in: directory.appendingPathComponent("Copies"))
        let store = try XCTUnwrap(catalog.store)
        func ready(_ model: FocusStackModel) async throws {
            for _ in 0..<1200 where model.stage != .ready || model.preview == nil {
                if case .failed(let message) = model.stage { return XCTFail(message) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.focusStack))
        defer { UserDefaults.standard.removeObject(forKey: LatentPreference.key(LatentImage.focusStack)) }
        catalog.requestFocusStack(catalog.assets)
        let model = FocusStackModel(request: try XCTUnwrap(catalog.focusStack))
        model.start(catalog: catalog)
        try await ready(model)
        model.settings.strokes = [FocusStackStroke(x: 0.3, y: 0.4, radius: 0.05, photo: 1, add: true)]
        model.settings.cropToCoverage = false
        let settings = model.settings
        model.keepLatent(catalog: catalog, output: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.latentAssetID, "a merge keeps nothing until Keep Latent Image is ticked")
        UserDefaults.standard.set(true, forKey: LatentPreference.key(LatentImage.focusStack))
        model.keepLatent(catalog: catalog, output: true)
        for _ in 0..<600 where model.latentAssetID == nil { try await Task.sleep(for: .milliseconds(50)) }
        let object = try await store.asset(XCTUnwrap(model.latentAssetID, catalog.error ?? "no latent image"))
        model.stop(); catalog.focusStack = nil
        let bundle = CatalogImporter.sourceURL(for: object, root: store.root)
        XCTAssertEqual(try LatentImage.load(bundle).focusStackSettings(), settings)

        catalog.openLatent(object)
        for _ in 0..<100 where catalog.focusStack == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reopened = FocusStackModel(request: try XCTUnwrap(catalog.focusStack))
        XCTAssertEqual(reopened.settings, settings)
        XCTAssertTrue(reopened.history.undoStack.isEmpty, "the strokes it opens with are not an edit to undo")
        reopened.start(catalog: catalog)
        try await ready(reopened)
        reopened.resetPainting(nil)
        reopened.close(catalog: catalog)
        for _ in 0..<600 where (try? LatentImage.load(bundle).focusStackSettings().strokes) != [] { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(try LatentImage.load(bundle).focusStackSettings().strokes, [], "closing updates it")
        let latents = try await store.assets().filter(\.isLatent)
        XCTAssertEqual(latents.count, 1)
    }
}
