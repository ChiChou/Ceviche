import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogQuickMetadataTests: XCTestCase {
    @MainActor func testTileRatingClickAndDragDoNotTriggerSelectionOrOpen() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try XCTUnwrap(model.assets.first)
        var ratings: [Int] = [], selections = 0, opens = 0
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogTile(asset: photo, previews: model.previews, selected: false, rating: 3, review: .unreviewed,
            setRating: { ratings.append($0) }, setReview: { _ in })
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 200, height: 220, alignment: .bottom)
            .onTapGesture(count: 2) { opens += 1 }.onTapGesture { selections += 1 })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        let point = host.convert(NSPoint(x: 151, y: host.isFlipped ? host.bounds.height - 12 : 12), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(ratings, [0]); XCTAssertEqual(selections, 0); XCTAssertEqual(opens, 0)
        for (type, x) in [(NSEvent.EventType.leftMouseDown, 111.0), (.leftMouseDragged, 191.0), (.leftMouseUp, 191.0)] {
            let location = host.convert(NSPoint(x: x, y: host.isFlipped ? host.bounds.height - 12 : 12), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ratings, [0, 5]); XCTAssertEqual(selections, 0); XCTAssertEqual(opens, 0)
    }
    @MainActor func testPartialCaptureDateNeitherAlertsNorBlocksSelection() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = model.assets
        await model.selectAsset(photos[0])
        let stored = model.metadata.captureDay
        model.metadata.captureDay = "2024-"
        XCTAssertFalse(model.captureDayValid)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(model.error, "A partial date is not saved while typing")
        await model.selectAsset(photos[1])
        XCTAssertNil(model.error)
        XCTAssertEqual(model.selected?.id, photos[1].id, "Leaving an incomplete date does not block selection")
        let first = try await XCTUnwrap(model.store).asset(photos[0].id)
        XCTAssertEqual(first.captureDay, stored)
    }
    @MainActor func testQuickControlsPreserveDraftsLocationsAndSelection() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        await model.selectAsset(photos[0])
        model.metadata.title = "Pending title"
        model.metadata.keywords = "mountains"
        model.metadata.latitude = 46.5; model.metadata.longitude = 11.3
        await model.updateQuickMetadata(photos[1], rating: 4)
        XCTAssertEqual(model.selected?.id, photos[0].id, "Quick controls do not move selection")
        let draft = try await store.asset(photos[0].id)
        XCTAssertEqual(draft.title, "Pending title")
        XCTAssertEqual(draft.latitude, 46.5)
        await model.updateQuickMetadata(photos[0], review: .accepted)
        await model.updateQuickMetadata(photos[0], rating: 5)
        let saved = try await store.asset(photos[0].id)
        XCTAssertEqual(saved.rating, 5); XCTAssertEqual(saved.review, .accepted)
        XCTAssertEqual(saved.keywords, "mountains"); XCTAssertEqual(saved.longitude, 11.3)
        XCTAssertEqual(model.metadata, saved.metadata)
        // Actions use persisted values even when invoked with an older tile value.
        await model.updateQuickMetadata(photos[0], rating: 5)
        await model.updateQuickMetadata(photos[0], review: .accepted)
        let cleared = try await store.asset(photos[0].id)
        XCTAssertEqual(cleared.rating, 0); XCTAssertEqual(cleared.review, .unreviewed)
        XCTAssertNil(model.error)
    }
    @MainActor func testQuickReviewReappliesFilterAndDoesNotEditTrash() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = model.assets[0], store = try XCTUnwrap(model.store)
        model.filter.review = .unreviewed
        await model.refresh(); await model.selectAsset(photo)
        await model.updateQuickMetadata(photo, review: .rejected)
        XCTAssertFalse(model.assets.contains { $0.id == photo.id })
        XCTAssertNil(model.selected)
        await model.moveToTrash([photo], editor: editor)
        await model.updateQuickMetadata(photo, rating: 5)
        let trashed = try await store.asset(photo.id)
        XCTAssertNotNil(trashed.trashedAt); XCTAssertEqual(trashed.rating, 0)
    }
}
