import XCTest
import AppKit
import SwiftUI
import CevicheCore
@testable import CevicheMac

final class CatalogKeyboardTests: XCTestCase {
    func testGridDirectionsRespectRowsAndBoundaries() {
        XCTAssertNil(CatalogGridMove.right.destination(from: nil, count: 0, columns: 3))
        XCTAssertEqual(CatalogGridMove.down.destination(from: nil, count: 8, columns: 3), 0)
        XCTAssertEqual(CatalogGridMove.right.destination(from: 2, count: 8, columns: 3), 3)
        XCTAssertEqual(CatalogGridMove.left.destination(from: 0, count: 8, columns: 3), 0)
        XCTAssertEqual(CatalogGridMove.up.destination(from: 2, count: 8, columns: 3), 2)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 2, count: 8, columns: 3), 5)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 5, count: 8, columns: 3), 7)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 6, count: 8, columns: 3), 6)
        XCTAssertEqual(CatalogGridMove.up.destination(from: 7, count: 8, columns: 3), 4)
        XCTAssertEqual(CatalogGridMove.first.destination(from: 7, count: 8, columns: 3), 0)
        XCTAssertEqual(CatalogGridMove.last.destination(from: 0, count: 8, columns: 3), 7)
    }
    @MainActor func testRapidNavigationFlushesMetadataAndUsesFilteredOrder() async throws {
        let (directory, url) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        let store = try XCTUnwrap(model.store)
        for i in 0..<8 {
            let copy = directory.appendingPathComponent("photo-\(i).jpg"); try FileManager.default.copyItem(at: url, to: copy)
            let prepared = try CatalogImporter.prepare(copy)
            _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        }
        await model.refresh(); model.libraryColumnCount = 3
        let ordered = model.assets
        await model.selectAsset(ordered[0]); model.metadata.title = "Saved before navigation"
        model.moveLibrarySelection(.right); model.moveLibrarySelection(.right); model.moveLibrarySelection(.right)
        try await EditorFixtures.settle(model, id: ordered[3].id)
        let saved = try await store.asset(ordered[0].id)
        XCTAssertEqual(saved.title, "Saved before navigation"); XCTAssertFalse(model.metadataPending)
        model.moveLibrarySelection(.down)
        try await EditorFixtures.settle(model, id: ordered[6].id)
        model.moveLibrarySelection(.last)
        try await EditorFixtures.settle(model, id: ordered[7].id)
        model.filter.search = ordered[2].filename; await model.refresh()
        model.moveLibrarySelection(.right)
        try await EditorFixtures.settle(model, id: ordered[2].id)
        XCTAssertEqual(model.assets.count, 1); XCTAssertNil(model.error)
        model.filter = CatalogFilter(); await model.refresh(); await model.selectAsset(ordered[0])
        let editor = EditorModel()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.firstResponder is NSTextView, "The library grid receives focus on entry")
        XCTAssertGreaterThan(model.libraryColumnCount, 1)
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        NSApp.sendEvent(try key(124, "\u{F703}"))
        try await EditorFixtures.settle(model, id: ordered[1].id)
        NSApp.sendEvent(try key(124, "\u{F703}", modifiers: .shift))
        try await EditorFixtures.settle(model, id: ordered[2].id)
        XCTAssertEqual(model.selectedIDs, Set(ordered[1...2].map(\.id)))
        NSApp.sendEvent(try key(123, "\u{F702}", modifiers: .shift))
        try await EditorFixtures.settle(model, id: ordered[1].id)
        XCTAssertEqual(model.selectedIDs, [ordered[1].id])
        let columns = model.libraryColumnCount
        NSApp.sendEvent(try key(125, "\u{F701}"))
        try await EditorFixtures.settle(model, id: ordered[1 + columns].id)
        NSApp.sendEvent(try key(119, "\u{F72B}"))
        try await EditorFixtures.settle(model, id: ordered[7].id)
        try await Task.sleep(for: .milliseconds(150))
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) } }
        let grid = try XCTUnwrap(scrolls(host).max { $0.frame.width < $1.frame.width })
        XCTAssertGreaterThan(grid.contentView.bounds.minY, 0, "Selecting the last row scrolls it into view")
        func textFields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields($0) } }
        let text = try XCTUnwrap(textFields(host).first { $0.isEditable })
        window.makeFirstResponder(text)
        XCTAssertTrue(window.firstResponder is NSTextView)
        NSApp.sendEvent(try key(123, "\u{F702}"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.selected?.id, ordered[7].id, "Arrows inside a text field must not navigate photos")
    }
    @MainActor func testShiftOAndKeyRepeatThroughTheWindowMonitor() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel(preferences: preferences)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        editor.preview = try XCTUnwrap(pixels.makeImage())
        catalog.viewMode = .detail
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Color.clear.background(PhotoBrowsingKeys(catalog: catalog, editor: editor)))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(nil)
        func key(_ characters: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeating, keyCode: code)))
        }
        editor.toolTab = .crop; editor.showInspector = true
        editor.cropOverlay = .goldenSpiral; editor.cropOverlayOrientation = 0
        try key("O", 31, modifiers: .shift)
        XCTAssertEqual(editor.cropOverlay, .goldenSpiral, "⇧O turns the overlay instead of choosing the next one")
        XCTAssertEqual(editor.cropOverlayOrientation, 1)
        try key("O", 31, modifiers: .shift, repeating: true)
        XCTAssertEqual(editor.cropOverlayOrientation, 1, "Holding ⇧O turns it once")
        try key("o", 31)
        XCTAssertNotEqual(editor.cropOverlay, .goldenSpiral)
        catalog.panelsHidden = false
        try key("\t", 48)
        XCTAssertTrue(catalog.panelsHidden)
        try key("\t", 48, repeating: true)
        XCTAssertTrue(catalog.panelsHidden, "Holding Tab must not bring the panels back")
        try key("\t", 48)
        XCTAssertFalse(catalog.panelsHidden)
        // ⇧I belongs to Capture Info, not the Info panel; the Develop letters need a photo, so with none they pass through.
        let info = editor.showCaptureOverlay, tab = editor.toolTab
        try key("I", 34, modifiers: .shift)
        XCTAssertEqual(editor.showCaptureOverlay, info); XCTAssertEqual(editor.toolTab, tab)
    }
    @MainActor func testDevelopLettersCaptureInfoFitAndMaskOverlay() async throws {
        let (directory, catalog, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try XCTUnwrap(catalog.assets.first)
        catalog.develop(asset, editor: editor)
        for _ in 0..<200 where !(editor.hasImage && !editor.busy) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(editor.hasImage)
        catalog.viewMode = .detail
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Color.clear.background(PhotoBrowsingKeys(catalog: catalog, editor: editor)))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(nil)
        func key(_ characters: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)))
        }
        editor.toolTab = .light; editor.showInspector = true
        let info = editor.showCaptureOverlay
        try key("I", 34, modifiers: .shift)
        XCTAssertEqual(editor.showCaptureOverlay, !info)
        XCTAssertEqual(editor.toolTab, .light, "⇧I must not open the Info panel")
        try key("i", 34)
        XCTAssertEqual(editor.toolTab, .info)
        editor.updateViewportGeometry(image: CGSize(width: 800, height: 600), canvas: CGSize(width: 400, height: 300))
        editor.viewport.fit()
        try key("z", 6)
        XCTAssertFalse(editor.viewport.isFitted)
        try key("z", 6)
        XCTAssertTrue(editor.viewport.isFitted)
        try key("w", 13)
        XCTAssertNil(editor.eyedropper, "W arms white balance only on a RAW")
        editor.toolTab = .masks; editor.showInspector = true
        let overlay = editor.showMaskOverlay
        try key("o", 31)
        XCTAssertEqual(editor.showMaskOverlay, !overlay)
        editor.showMaskOverlay = overlay
    }
    @MainActor func testOriginalPeekReleaseAndFocusGuards() async throws {
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let catalog = CatalogModel(preferences: preferences), editor = EditorModel(preferences: preferences)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        editor.preview = try XCTUnwrap(pixels.makeImage()); editor.originalPreview = editor.preview
        catalog.viewMode = .detail
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: EditorCanvas(model: editor).background(PhotoBrowsingKeys(catalog: catalog, editor: editor)))
        let container = NSView(frame: window.contentLayoutRect)
        host.frame = container.bounds; host.autoresizingMask = [.width, .height]; container.addSubview(host)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(nil)
        func key(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false, code: UInt16 = 42) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: code == 49 ? " " : "\\",
                charactersIgnoringModifiers: code == 49 ? " " : "\\", isARepeat: repeating, keyCode: code)))
        }
        try key(.keyDown, repeating: true)
        XCTAssertFalse(editor.peekingOriginal, "Key repeat must not start a peek")
        editor.comparing = true; editor.setComparisonSplit(0.3)
        try key(.keyDown)
        XCTAssertTrue(editor.peekingOriginal)
        try key(.keyDown, repeating: true)
        XCTAssertTrue(editor.peekingOriginal)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22)); container.addSubview(field); window.makeFirstResponder(field)
        XCTAssertTrue(window.firstResponder is NSTextView)
        try key(.keyUp, modifiers: .shift)
        XCTAssertFalse(editor.peekingOriginal, "Release restores the edit even after focus and modifiers change")
        XCTAssertTrue(editor.comparing); XCTAssertEqual(editor.comparisonSplit, 0.3)
        try key(.keyDown)
        XCTAssertFalse(editor.peekingOriginal, "Typing must not peek")
        window.makeFirstResponder(nil)
        try key(.keyDown, modifiers: .command)
        XCTAssertFalse(editor.peekingOriginal)
        try key(.keyDown)
        XCTAssertTrue(editor.peekingOriginal)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(editor.peekingOriginal)
        editor.comparing = false
        try key(.keyDown, modifiers: .shift)
        XCTAssertTrue(editor.comparing)
        XCTAssertFalse(editor.peekingOriginal)
        try key(.keyDown, modifiers: .shift, repeating: true)
        XCTAssertTrue(editor.comparing, "Repeat must not toggle comparison")
        try key(.keyUp, modifiers: .shift)
        editor.updateViewportGeometry(image: CGSize(width: 800, height: 600), canvas: CGSize(width: 400, height: 300))
        editor.viewport.fit()
        try key(.keyDown, code: 49)
        XCTAssertTrue(editor.spaceHeld)
        XCTAssertFalse(editor.peekingOriginal)
        XCTAssertTrue(editor.viewport.isFitted)
        try key(.keyUp, code: 49)
        XCTAssertEqual(editor.viewport.scale, 2)
        try key(.keyDown, code: 49)
        editor.spaceDragged = true
        try key(.keyUp, code: 49)
        XCTAssertEqual(editor.viewport.scale, 2, "Pan release must retain zoom")
        try key(.keyDown, code: 49)
        try key(.keyUp, code: 49)
        XCTAssertTrue(editor.viewport.isFitted)
        catalog.viewMode = .compare
        try key(.keyDown)
        XCTAssertFalse(editor.peekingOriginal, "Peek belongs only to Develop")
        editor.showCaptureOverlay = true
        XCTAssertTrue(EditorModel(preferences: preferences).showCaptureOverlay)
    }
    func testGridDaysKeepTheColumnAcrossShortRows() {
        // Days of 2, 4 and 1 photos in a 3-column grid: rows 0..<2, 2..<5, 5..<6, 6..<7.
        let rows = [0..<2, 2..<5, 5..<6, 6..<7]
        XCTAssertEqual(CatalogGridMove.down.destination(from: 1, count: 7, columns: 3, rows: rows, keepsColumn: true), 3)
        XCTAssertEqual(CatalogGridMove.down.destination(from: 4, count: 7, columns: 3, rows: rows, keepsColumn: true), 5)
        XCTAssertEqual(CatalogGridMove.up.destination(from: 5, count: 7, columns: 3, rows: rows, keepsColumn: true), 2)
    }
}
