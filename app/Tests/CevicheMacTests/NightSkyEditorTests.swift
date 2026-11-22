import XCTest
import CevicheCore
import CevicheTestSupport
import Metal
@testable import CevicheMac

/// The night-sky window's own arithmetic: box selection, brush steps and undo. Its snapshots are in `ToolSnapshotTests`.
final class NightSkyEditorTests: XCTestCase {
    /// A dragged box takes the lines it reaches into, even those that only cross it.
    func testABoxSelectsTheLinesItReaches() {
        let box = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertTrue(NightSkyOutlines.segment(CGPoint(x: 15, y: 15), CGPoint(x: 18, y: 18), crosses: box), "inside")
        XCTAssertTrue(NightSkyOutlines.segment(CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20), crosses: box), "across")
        XCTAssertTrue(NightSkyOutlines.segment(CGPoint(x: 0, y: 0), CGPoint(x: 15, y: 15), crosses: box), "into")
        XCTAssertFalse(NightSkyOutlines.segment(CGPoint(x: 0, y: 25), CGPoint(x: 5, y: 40), crosses: box), "beside")
        XCTAssertFalse(NightSkyOutlines.segment(CGPoint(x: 0, y: 15), CGPoint(x: 15, y: 0), crosses: box), "past the corner")
        XCTAssertFalse(NightSkyOutlines.segment(CGPoint(x: 0, y: 5), CGPoint(x: 40, y: 5), crosses: box), "above")
    }

    /// [ and ] step the brush by about a fifth, at least a point, within its range.
    func testBracketsStepTheBrushSize() {
        XCTAssertEqual(NightSkyBrushSize.stepped(60, larger: true), 72)
        XCTAssertEqual(NightSkyBrushSize.stepped(60, larger: false), 50)
        XCTAssertEqual(NightSkyBrushSize.stepped(4, larger: true), 5)
        XCTAssertEqual(NightSkyBrushSize.stepped(4, larger: false), 4)
        XCTAssertEqual(NightSkyBrushSize.stepped(390, larger: true), 400)
    }

    /// Undo and redo step through strokes and toolbar changes; a Sky Edge drag is one step, and a new change after an
    /// undo drops what could be redone.
    @MainActor func testRetouchingUndoesAStepAtATime() {
        let history = NightSkyHistory()
        var retouch = NightSkyRetouch(skyEdge: 0, allSky: false, skyStrokes: [], photoRegions: [])
        history.current = { retouch }
        history.apply = { retouch = $0 }
        func change(_ edit: (inout NightSkyRetouch) -> Void) { let old = retouch; edit(&retouch); history.record(old, now: retouch) }
        let dab = NightSkyStroke(x: 0.5, y: 0.5, radius: 0.02, sky: false)
        change { $0.skyStrokes.append(dab) }
        change { $0.allSky = true }
        for edge in [4, 8, 12] { change { $0.skyEdge = edge } }
        XCTAssertEqual(history.undoStack.count, 3, "the edge drag is one step")

        history.undo()
        XCTAssertEqual(retouch.skyEdge, 0); XCTAssertTrue(retouch.allSky)
        history.undo()
        XCTAssertFalse(retouch.allSky); XCTAssertEqual(retouch.skyStrokes, [dab])
        history.redo()
        XCTAssertTrue(retouch.allSky)
        change { $0.photoRegions.append(dab) }
        XCTAssertTrue(history.redoStack.isEmpty)
        history.undo(); history.undo(); history.undo()
        XCTAssertEqual(retouch, NightSkyRetouch(skyEdge: 0, allSky: false, skyStrokes: [], photoRegions: []))
        history.undo()
        XCTAssertEqual(retouch.skyStrokes, [], "nothing left to undo")
    }
}

extension NightSkyEditorTests {
    @MainActor func testLatentImageAutosavesAndReopensFromCatalog() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal required") }
        let (directory, first) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("Second").appendingPathExtension(first.pathExtension)
        try FileManager.default.copyItem(at: first, to: second)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: defaults)
        await catalog.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(catalog.store)
        var sources: [CatalogAsset] = []
        for url in [first, second] {
            let photo = try CatalogImporter.prepare(url)
            sources.append(try await store.insert(photo.0, thumbnail: photo.1))
        }
        UserDefaults.standard.removeObject(forKey: LatentPreference.key(NightSkyTool.starTrails.rawValue))
        defer { UserDefaults.standard.removeObject(forKey: LatentPreference.key(NightSkyTool.starTrails.rawValue)) }
        let request = NightSkyRequest(tool: .starTrails, assets: sources)
        catalog.nightSky = request
        let model = NightSkyModel<StarTrailsMerger>(request: request, settings: StarTrailsSettings())
        model.start(catalog: catalog) { _, _ in }
        for _ in 0..<1500 {
            if model.canMerge { break }
            if case .failed(let message) = model.stage { XCTFail(message); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.canMerge, model.previewError ?? "the preview did not finish")
        try await Task.sleep(for: .milliseconds(300))
        let unticked = try await store.assets()
        XCTAssertFalse(unticked.contains(where: \.isLatent), "nothing is kept until Keep Latent Image is ticked")
        // Ticked partway through, it saves the analysis already made.
        UserDefaults.standard.set(true, forKey: LatentPreference.key(NightSkyTool.starTrails.rawValue))
        model.latentTicked()
        model.settings.keepStarColors = true
        let presentation = try StarTrailLatentOptions(output: .video, video: .remembered).encoded()
        model.presentation = presentation
        model.close(catalog: catalog)
        for _ in 0..<1500 where catalog.nightSky != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(catalog.nightSky)
        let assets = try await store.assets()
        let object = try XCTUnwrap(assets.first(where: \.isLatent))
        XCTAssertEqual(assets.count, 3)
        let bundle = CatalogImporter.sourceURL(for: object, root: store.root)
        let saved = try LatentImage.load(bundle)
        XCTAssertTrue(try JSONDecoder().decode(StarTrailsSettings.self, from: saved.settings).keepStarColors)
        catalog.openLatent(object)
        for _ in 0..<100 where catalog.nightSky == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reopening = try XCTUnwrap(catalog.nightSky)
        let restored = NightSkyModel<StarTrailsMerger>(request: reopening, settings: StarTrailsSettings())
        restored.start(catalog: catalog) { _, _ in XCTFail("reopening must not configure newly analyzed settings") }
        for _ in 0..<1500 {
            if restored.canMerge { break }
            if case .failed(let message) = restored.stage { XCTFail(message); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(restored.canMerge, restored.previewError ?? "reopening did not finish")
        XCTAssertTrue(restored.settings.keepStarColors)
        XCTAssertEqual(restored.presentation, presentation)
        XCTAssertEqual(try LatentImage.load(bundle).analysisID, saved.analysisID, "reopening reuses the prepared analysis")
        restored.close(catalog: catalog)
        for _ in 0..<100 where catalog.nightSky != nil { try await Task.sleep(for: .milliseconds(20)) }
    }
}
