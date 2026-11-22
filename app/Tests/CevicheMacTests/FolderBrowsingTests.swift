import XCTest
import AppKit
import SwiftUI
import Vision
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

final class FolderBrowsingTests: XCTestCase {
    /// A scratch home folder with Pictures/Trip (three photos) and Pictures/Trip/Day 2 (one), and a catalog beside it.
    @MainActor private func fixture() async throws -> (directory: URL, home: URL, model: CatalogModel, suite: String) {
        let (directory, photo) = try EditorFixtures.photo()
        let fm = FileManager.default
        let home = directory.appendingPathComponent("home")
        for folder in ["Pictures/Trip/Day 2", "Pictures/Empty", "Desktop", "Documents", "Downloads"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try fm.copyItem(at: photo, to: home.appendingPathComponent("Pictures/Trip/\(name)")) }
        try fm.copyItem(at: photo, to: home.appendingPathComponent("Pictures/Trip/Day 2/d.jpg"))
        let suite = UUID().uuidString
        let model = CatalogModel(preferences: UserDefaults(suiteName: suite)!, folders: FolderBrowser(home: home))
        model.folderIndexOverride = home.deletingLastPathComponent().appendingPathComponent("Caches/Folders.cevichecatalog")
        await model.openCatalog(directory.appendingPathComponent("Library.cevichecatalog"), manifest: CatalogManifest(name: "Library", kind: .file))
        XCTAssertNotNil(model.store, model.error ?? "")
        return (directory, home, model, suite)
    }
    @MainActor private func cleanUp(_ fixture: (directory: URL, home: URL, model: CatalogModel, suite: String)) {
        fixture.model.stopIndexing()
        UserDefaults().removePersistentDomain(forName: fixture.suite)
        try? FileManager.default.removeItem(at: fixture.directory)
    }
    @MainActor private func wait(_ seconds: Double = 8, until done: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 20) where !done() { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// Choosing a folder shows its photos without an import, and the grid follows files added and deleted on disk.
    @MainActor func testChoosingAFolderIndexesItAndFollowsItsFiles() async throws {
        let fixture = try await fixture(); defer { cleanUp(fixture) }
        let model = fixture.model, fm = FileManager.default
        let trip = fixture.home.appendingPathComponent("Pictures/Trip", isDirectory: true), photo = trip.appendingPathComponent("a.jpg")
        // Opening a catalog no longer looks for cameras and cards; choosing Camera… does.
        XCTAssertFalse(model.cameraImporter.isDiscovering)

        await model.showFolder(trip, root: "home")
        // Thumbnails reach the grid a moment after they are stored, in batches.
        try await wait { model.assets.count == 3 && model.folderSync == nil && model.assets.allSatisfy { $0.thumbnailKey != nil } }
        XCTAssertEqual(model.assets.map(\.filename).sorted(), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(model.collectionTitle, "Trip"); XCTAssertEqual(model.matchingCount, 3); XCTAssertNil(model.folderIssue)
        XCTAssertTrue(model.assets.allSatisfy { !$0.isCopy && $0.thumbnailKey != nil })

        try fm.copyItem(at: photo, to: trip.appendingPathComponent("e.jpg"))
        try await wait { model.assets.count == 4 }
        XCTAssertEqual(model.assets.count, 4, "a file added to the shown folder appears")
        try fm.removeItem(at: photo)
        try await wait { model.assets.count == 3 }
        XCTAssertEqual(model.assets.map(\.filename).sorted(), ["b.jpg", "c.jpg", "e.jpg"], "a file deleted from the shown folder goes")

        // The subfolder is a folder of its own; All Photos holds everything browsed so far.
        await model.showFolder(trip.appendingPathComponent("Day 2", isDirectory: true), root: "home")
        try await wait { model.assets.count == 1 && model.folderSync == nil }
        XCTAssertEqual(model.assets.map(\.filename), ["d.jpg"])
        await model.showCollection(trash: false)
        XCTAssertNil(model.filter.folder); XCTAssertEqual(model.total, 4)

        await model.showFolder(fixture.home.appendingPathComponent("Gone", isDirectory: true))
        try await wait { model.folderIssue != nil }
        XCTAssertEqual(model.folderIssue, .missing(fixture.home.appendingPathComponent("Gone").path))
    }

    /// Photos opened from the Finder show where they are, in the Folders view: nothing goes into the person's catalog,
    /// one photo opens in Detail, several are selected in the grid.
    @MainActor func testPhotosFromTheFinderOpenInPlace() async throws {
        let fixture = try await fixture(); defer { cleanUp(fixture) }
        let model = fixture.model, editor = EditorModel()
        let trip = fixture.home.appendingPathComponent("Pictures/Trip", isDirectory: true)
        let library = try XCTUnwrap(model.store)

        await model.openInPlace([trip.appendingPathComponent("b.jpg")], editor: editor)
        try await wait { model.viewMode == .detail && editor.catalogAssetID != nil }
        XCTAssertEqual(model.sidebarTab, .folders); XCTAssertTrue(model.isFolderIndex)
        XCTAssertEqual(model.filter.folder, CatalogFolders.path(trip))
        XCTAssertEqual(model.selected?.filename, "b.jpg")
        XCTAssertEqual(editor.catalogAssetID, model.selected?.id)
        let imported = try await library.assets()
        XCTAssertTrue(imported.isEmpty, "nothing is imported into the catalog")
        // The outline opens down to the folder and selects it, under the deepest root that holds it.
        let pictures = CatalogFolders.path(fixture.home.appendingPathComponent("Pictures", isDirectory: true))
        XCTAssertEqual(model.folderRoot, "place:Pictures")
        XCTAssertTrue(model.folders.isExpanded(FolderBrowser.Node(root: "place:Pictures", path: pictures)))
        XCTAssertFalse(model.folders.isExpanded(FolderBrowser.Node(root: "place:Pictures", path: CatalogFolders.path(trip))), "the folder itself stays closed")

        model.viewMode = .grid
        await model.openInPlace([trip.appendingPathComponent("c.jpg"), trip.appendingPathComponent("a.jpg")], editor: editor)
        try await wait { model.selectedIDs.count == 2 }
        XCTAssertEqual(Set(model.assets.filter { model.selectedIDs.contains($0.id) }.map(\.filename)), ["a.jpg", "c.jpg"])
        XCTAssertEqual(model.selected?.filename, "c.jpg", "the first photo handed over leads")
        XCTAssertEqual(model.viewMode, .grid, "several photos stay in the grid")

        await model.openInPlace([trip.appendingPathComponent("Day 2", isDirectory: true)], editor: editor)
        try await wait { model.assets.map(\.filename) == ["d.jpg"] }
        XCTAssertEqual(model.filter.folder, CatalogFolders.path(trip.appendingPathComponent("Day 2")))
        XCTAssertTrue(model.folders.isExpanded(FolderBrowser.Node(root: "place:Pictures", path: CatalogFolders.path(trip))), "a deeper folder opens the levels above it")
        XCTAssertNil(model.pendingFinderPhotos)
    }

    /// The outline reads a folder only when it is opened, and follows folders made and removed inside an open one.
    @MainActor func testTheOutlineOpensALevelAtATimeAndFollowsNewFolders() async throws {
        let fixture = try await fixture(); defer { cleanUp(fixture) }
        let folders = fixture.model.folders, fm = FileManager.default
        XCTAssertEqual(folders.places.map(\.url.lastPathComponent), ["Pictures", "Desktop", "Documents", "Downloads"])
        XCTAssertTrue(folders.contents.isEmpty, "nothing is read before the Folders tab shows")
        folders.activate()
        let home = CatalogFolders.path(fixture.home)
        try await wait { folders.contents[home] == .folders(["Desktop", "Documents", "Downloads", "Pictures"].map { fixture.home.appendingPathComponent($0, isDirectory: true) }) }
        XCTAssertEqual(Set(folders.contents.keys), [home], "only the home folder itself has been read")

        let pictures = FolderBrowser.Node(root: "home", path: home + "/Pictures")
        folders.setExpanded(pictures, true)
        try await wait { folders.contents[pictures.path] != nil && folders.contents[pictures.path] != .loading }
        XCTAssertEqual(folders.contents[pictures.path], .folders(["Empty", "Trip"].map { fixture.home.appendingPathComponent("Pictures/\($0)", isDirectory: true) }))
        try fm.createDirectory(at: fixture.home.appendingPathComponent("Pictures/New Shoot"), withIntermediateDirectories: false)
        try await wait { if case .folders(let found) = folders.contents[pictures.path] { return found.count == 3 } else { return false } }
        XCTAssertEqual(folders.contents[pictures.path], .folders(["Empty", "New Shoot", "Trip"].map { fixture.home.appendingPathComponent("Pictures/\($0)", isDirectory: true) }))
        folders.setExpanded(pictures, false)
        XCTAssertNil(folders.contents[pictures.path]); XCTAssertFalse(folders.isExpanded(pictures))
    }

    /// The sidebar driven as a person drives it, with mouse clicks on the real window: the Folders tab, a chevron, a
    /// folder, a subfolder, and the footer's appearance switch. CEVICHE_SNAPSHOT_OUT=<folder> also saves each step.
    @MainActor func testClickingThroughTheFoldersTab() async throws {
        let fixture = try await fixture(); defer { cleanUp(fixture) }
        let model = fixture.model, editor = EditorModel()
        model.showSidebar = true; model.sidebarTab = .catalog
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(.dark).ignoresSafeArea(.container, edges: .top))
        host.appearance = NSAppearance(named: .darkAqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(600)); host.layoutSubtreeIfNeeded()

        /// Where the sidebar shows `label`, read off the rendered window as a person reads it (SwiftUI builds no
        /// accessibility tree inside a test process). The lowest match, so a folder in the home tree wins over the
        /// place of the same name above it. The recogniser may read a row's icon as stray letters before its title, so the
        /// title is matched at the end of the line. `chevronAtDepth` aims at the row's disclosure button instead: 8 pt of
        /// list padding, 2 of row padding, 14 a level, then half the 12 pt button.
        /// The fast recogniser misses some short titles; `after` then places the row that many 29 pt rows below a title it does read.
        func target(_ label: String, chevronAtDepth depth: Int? = nil, after anchor: (title: String, rows: Int)? = nil) throws -> NSPoint {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .fast; request.usesLanguageCorrection = false; request.minimumTextHeight = 0.004
            try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
            let width = host.bounds.width, height = host.bounds.height
            let found = (request.results ?? []).compactMap { observation -> (String, NSRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return (text, NSRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height))
            }.filter { $0.1.maxX < CGFloat(model.sidebarWidth) }
            func lowest(_ title: String) -> (String, NSRect)? { found.filter { $0.0.lowercased().hasSuffix(title.lowercased()) }.min { $0.1.minY < $1.1.minY } }
            var located = lowest(label)
            if located == nil, let anchor, let above = lowest(anchor.title) {
                let share = CGFloat(anchor.title.count) / CGFloat(max(above.0.count, 1))
                located = (label, NSRect(x: above.1.maxX - above.1.width * share, y: above.1.minY - CGFloat(anchor.rows) * 29, width: above.1.width * share, height: above.1.height))
            }
            let match = try XCTUnwrap(located, "No “\(label)” in the sidebar: \(found.map(\.0))")
            if let depth { return NSPoint(x: 16 + CGFloat(depth) * 14, y: match.1.midY) }
            let share = CGFloat(label.count) / CGFloat(max(match.0.count, 1))
            let half = match.1.width * share / 2
            return NSPoint(x: match.1.maxX - half, y: match.1.midY)
        }
        func click(_ point: NSPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                NSApp.sendEvent(event)
                try await Task.sleep(for: .milliseconds(60))
            }
            try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        }
        var step = 0
        func capture(_ name: String) throws {
            guard let output = ProcessInfo.processInfo.environment["CEVICHE_SNAPSHOT_OUT"] else { return }
            step += 1
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("click-\(step)-\(name).png"))
        }

        // The tab under Import.
        try await click(target("FOLDERS"))
        XCTAssertEqual(model.sidebarTab, .folders, "clicking the Folders tab switches the sidebar")
        let home = CatalogFolders.path(fixture.home)
        try await wait { model.folders.contents[home] != nil && model.folders.contents[home] != .loading }
        try await Task.sleep(for: .milliseconds(300)); try capture("folders-tab")

        // The home tree: open Pictures by its chevron, then choose Trip.
        try await click(target("Pictures", chevronAtDepth: 1))
        let pictures = FolderBrowser.Node(root: "home", path: home + "/Pictures")
        XCTAssertTrue(model.folders.isExpanded(pictures), "clicking the chevron opens the folder")
        try await wait { model.folders.contents[pictures.path] != nil && model.folders.contents[pictures.path] != .loading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.filter.folder, "opening a folder in the outline does not show it")
        try await click(target("Trip", after: ("Empty", 1)))
        XCTAssertEqual(model.filter.folder, home + "/Pictures/Trip", "clicking a folder shows it")
        try await wait { model.assets.count == 3 && model.folderSync == nil }
        XCTAssertEqual(model.assets.count, 3); try await Task.sleep(for: .milliseconds(600)); try capture("trip")

        // Its subfolder, then back to the catalog's own list.
        try await click(target("Trip", chevronAtDepth: 2, after: ("Empty", 1)))
        try await wait { model.folders.contents[home + "/Pictures/Trip"] != nil && model.folders.contents[home + "/Pictures/Trip"] != .loading }
        try await Task.sleep(for: .milliseconds(300))
        try await click(target("Day 2", after: ("Empty", 2)))
        try await wait { model.assets.map(\.filename) == ["d.jpg"] }
        XCTAssertEqual(model.assets.map(\.filename), ["d.jpg"]); try capture("day-2")
        try await click(target("Pictures", chevronAtDepth: 1))
        XCTAssertFalse(model.folders.isExpanded(pictures))
        XCTAssertTrue(model.isFolderIndex, "folders are browsed in their own index")
        let index = model.root
        try await click(target("LIBRARY"))
        XCTAssertEqual(model.sidebarTab, .catalog)
        // Back in the person's catalog, which browsing left as it was.
        try await wait { !model.isFolderIndex && model.store != nil && model.filter.folder == nil }
        XCTAssertNotEqual(model.root, index); XCTAssertEqual(model.root?.lastPathComponent, "Library.cevichecatalog")
        try await click(target("All Photos"))
        try await wait { model.filter.folder == nil }
        XCTAssertNil(model.filter.folder); XCTAssertEqual(model.total, 0, "browsed photos stay out of the catalog")

        // The footer: one click swaps the palette setting.
        let before = UserDefaults.standard.string(forKey: AppearanceChoice.key)
        defer { UserDefaults.standard.set(before, forKey: AppearanceChoice.key) }
        UserDefaults.standard.set(AppearanceChoice.dark.rawValue, forKey: AppearanceChoice.key)
        // The switch has no title: the second 28 pt button of the footer, 8 pt in, in a 36 pt bar.
        try await click(NSPoint(x: 8 + 28 + 14, y: 18))
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppearanceChoice.key), AppearanceChoice.light.rawValue, "the footer's switch changes the appearance")
        try capture("after-appearance")
    }

    /// Optional visual check: CEVICHE_UI_SNAPSHOTS=1 with CEVICHE_SNAPSHOT_OUT=<folder> writes folders-dark.png and
    /// folders-light.png there, the window on the Folders tab with a folder shown.
    @MainActor func testFoldersSnapshotWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CEVICHE_UI_SNAPSHOTS"] == "1", let output = environment["CEVICHE_SNAPSHOT_OUT"] else { throw XCTSkip("Optional folders snapshot") }
        let fixture = try await fixture(); defer { cleanUp(fixture) }
        let model = fixture.model, editor = EditorModel()
        // CEVICHE_SNAPSHOT_PHOTOS=<folder> shows real photos in place of the fixture's.
        let trip = fixture.home.appendingPathComponent("Pictures/Trip", isDirectory: true)
        if let photos = environment["CEVICHE_SNAPSHOT_PHOTOS"] {
            for file in try CatalogFolders.list(URL(fileURLWithPath: photos, isDirectory: true)).photos.prefix(12) {
                try FileManager.default.copyItem(at: file, to: trip.appendingPathComponent(file.lastPathComponent))
            }
        }
        model.sidebarTab = .folders
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for scheme in [ColorScheme.dark, .light] {
            let host = NSHostingView(rootView: CatalogWorkspace(catalog: model, editor: editor).preferredColorScheme(scheme).ignoresSafeArea(.container, edges: .top))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua); window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            let home = CatalogFolders.path(fixture.home)
            model.folders.setExpanded(FolderBrowser.Node(root: "home", path: home + "/Pictures"), true)
            model.folders.setExpanded(FolderBrowser.Node(root: "home", path: home + "/Pictures/Trip"), true)
            await model.showFolder(trip, root: "home")
            try await wait(20) { !model.assets.isEmpty && model.folderSync == nil }
            try await Task.sleep(for: .milliseconds(1500)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("folders-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
