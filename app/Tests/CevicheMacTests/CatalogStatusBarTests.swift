import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogStatusBarTests: XCTestCase {
    @MainActor func testDevelopInspectorVisibilityPersists() {
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let editor = EditorModel(preferences: preferences)
        XCTAssertTrue(editor.showInspector)
        editor.showInspector = false
        XCTAssertFalse(EditorModel(preferences: preferences).showInspector)
    }
    func testZoomSliderGivesMostTravelToFitThroughEightTimes() {
        XCTAssertEqual(ZoomControls.scale(atSliderPosition: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(ZoomControls.scale(atSliderPosition: 0.8), 8, accuracy: 1e-9)
        XCTAssertEqual(ZoomControls.scale(atSliderPosition: 1), ImageViewport.maximum, accuracy: 1e-9)
        for scale in [1.0, 1.5, 2, 4, 8, 12, 16] {
            XCTAssertEqual(ZoomControls.scale(atSliderPosition: ZoomControls.sliderPosition(for: scale)), scale, accuracy: 1e-9)
        }
    }
    @MainActor func testZoomSliderScaleIsClampedToViewportRange() {
        let editor = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        editor.updateViewportGeometry(image: CGSize(width: 3000, height: 2000), canvas: CGSize(width: 1200, height: 800))
        editor.zoomImage(to: 4)
        XCTAssertEqual(editor.viewport.scale, 4, accuracy: 0.0001)
        editor.zoomImage(to: 100)
        XCTAssertEqual(editor.viewport.scale, ImageViewport.maximum, accuracy: 0.0001)
        editor.zoomImage(to: 0.2)
        XCTAssertTrue(editor.viewport.isFitted)
    }
    @MainActor func testCompareLayoutPersists() {
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences)
        XCTAssertEqual(catalog.compareSource, .beforeAfter); XCTAssertEqual(catalog.compareOrientation, .columns)
        catalog.compareSource = .twoPhotos; catalog.compareOrientation = .rows
        let reopened = CatalogModel(preferences: preferences)
        XCTAssertEqual(reopened.compareSource, .twoPhotos); XCTAssertEqual(reopened.compareOrientation, .rows)
    }
    @MainActor func testOpeningPreviouslyPausedCatalogEnablesAutomaticIndexing() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        try await store.setAnalysisEnabled(false)
        await model.openCatalog(store.root)
        XCTAssertTrue(model.indexing.enabled)
        XCTAssertNil(model.error)
    }
    @MainActor func testStatusBarSnapshotsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional status bar snapshots") }
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.indexing.running = 4; model.indexing.pending = 36; model.indexing.complete = 60
        model.indexingMessage = "Analyzing photos to suggest tags."
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor)
            .preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-status-bar.png"))
    }
    @MainActor func testDevelopStatusBarRatesOpenPhoto() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let asset = try XCTUnwrap(model.assets.first)
        let opened = await model.openPhoto(asset, editor: editor)
        XCTAssertTrue(opened)
        XCTAssertEqual(model.cullingTargets(editor: editor).map(\.id), [asset.id])
        await model.updateQuickMetadata(asset, rating: 4, review: .accepted)
        XCTAssertEqual(model.metadata.rating, 4); XCTAssertEqual(model.metadata.review, .accepted)
        // Clicking the current values again clears them.
        await model.updateQuickMetadata(asset, rating: 4, review: .accepted)
        XCTAssertEqual(model.metadata.rating, 0); XCTAssertEqual(model.metadata.review, .unreviewed)
        await model.updateQuickMetadata(asset, rating: 3, review: .rejected)
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { return }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1420, height: 860), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/ceviche-develop-status-bar.png"))
    }
}
