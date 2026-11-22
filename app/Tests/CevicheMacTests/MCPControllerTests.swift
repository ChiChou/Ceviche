import XCTest
import AppKit
import SwiftUI
import ImageIO
import Metal
import CevicheCore
@testable import CevicheMac

final class MCPControllerTests: XCTestCase {
    @MainActor func testPreferencesSnapshotWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_UI_SNAPSHOTS"] == "1" else { throw XCTSkip("Optional MCP settings snapshot") }
        _ = NSApplication.shared
        let suite = "mcp-ui-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let controller = MCPController(preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NSHostingView(rootView: PreferencesView(mcp: controller).preferredColorScheme(.dark))
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/ceviche-mcp-settings.png"))
        XCTAssertFalse(controller.enabled); XCTAssertNil(controller.server)
    }
    @MainActor private func rpc(_ controller: MCPController, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params]
        let response = await controller.handle(try MCPSchema.data(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response)) as? [String: Any])
    }
    @MainActor private func tool(_ controller: MCPController, _ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await rpc(controller, "tools/call", ["name": name, "arguments": args])
        return try XCTUnwrap(response["result"] as? [String: Any])
    }
    private func payload(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertEqual(result["isError"] as? Bool, false, String(describing: result))
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
    @MainActor func testDefaultsReadOnlyAndProtocolErrors() async throws {
        let suite = "mcp-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let controller = MCPController(preferences: preferences)
        XCTAssertFalse(controller.enabled); XCTAssertNil(controller.server)
        let initialization = try await rpc(controller, "initialize", ["protocolVersion": "2025-11-25"])
        XCTAssertEqual((initialization["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let listed = try await rpc(controller, "tools/list")
        let names = ((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("catalog_trash")); XCTAssertFalse(names.contains(where: { $0.contains("delete") }))
        let invalid = try await rpc(controller, "tools/call", ["name": "deletePermanently", "arguments": [:]])
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32602)
        controller.activeReadOnly = true
        let blocked = try await tool(controller, "catalog_trash", ["catalogId": "c", "assetIds": ["a"]])
        XCTAssertEqual(((blocked["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "read_only")
        // Read-only access offers the writing tools that can propose, as dry runs only, and hides the rest.
        let readOnlyListing = try await rpc(controller, "tools/list")
        let readOnlyTools = try XCTUnwrap((readOnlyListing["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let readOnlyNames = readOnlyTools.compactMap { $0["name"] as? String }
        XCTAssertFalse(readOnlyNames.contains("catalog_trash")); XCTAssertFalse(readOnlyNames.contains("job_cancel"), "Cancelling changes state")
        let proposal = try XCTUnwrap(readOnlyTools.first { $0["name"] as? String == "catalog_update" })
        XCTAssertEqual(((proposal["inputSchema"] as? [String: Any])?["required"] as? [String])?.contains("dryRun"), true)
        XCTAssertEqual((proposal["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertTrue(readOnlyNames.contains("photo_apply"))
        let update: [String: Any] = ["catalogId": "c", "items": [["assetId": "a", "set": ["rating": 3]]]]
        let written = try await tool(controller, "catalog_update", update)
        XCTAssertEqual(((written["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "read_only")
        var dryUpdate = update; dryUpdate["dryRun"] = true
        let proposed = try await tool(controller, "catalog_update", dryUpdate)
        XCTAssertEqual(((proposed["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "not_ready", "Allowed past access; no catalog is open")
        let cancel = try await tool(controller, "job_cancel", ["jobId": "j"])
        XCTAssertEqual(((cancel["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "read_only")
        let docs = try payload(await tool(controller, "photo_docs", ["section": "global", "control": "exposure"]))
        XCTAssertEqual((docs["schema"] as? [String: Any])?["maximum"] as? Double, 5)
        let masks = try payload(await tool(controller, "photo_docs", ["section": "masks"]))
        let semantics = try XCTUnwrap(masks["semantics"] as? [String: Any])
        for kind in ["Brush", "Linear gradient", "Radial gradient", "Color range", "coordinates", "stacking"] { XCTAssertNotNil(semantics[kind] as? String, kind) }
        let index = try payload(await tool(controller, "photo_docs"))
        XCTAssertFalse((index["advice"] as? [String] ?? []).isEmpty)
        controller.port = 1; controller.applyPreferences()
        XCTAssertNil(controller.server); XCTAssertFalse(preferences.bool(forKey: "mcp.enabled"))
        let notification = await controller.handle(try MCPSchema.data(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(notification)
    }
    @MainActor func testBackgroundImportReturnsAJobToFollow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "mcp-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let editor = EditorModel(preferences: preferences), catalog = CatalogModel(preferences: preferences)
        let controller = MCPController(preferences: preferences)
        controller.editor = editor; controller.catalog = catalog
        defer { editor.closeDocument(); catalog.stopIndexing(); controller.stop() }
        await catalog.openCatalog(dir.appendingPathComponent("test.cevichecatalog"))
        let folder = dir.appendingPathComponent("photos"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<3 {
            bitmap.setFillColor(CGColor(red: Double(index) / 3, green: 0.4, blue: 0.6, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent("p\(index).png") as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let listed = try await rpc(controller, "tools/list", [:])
        let names = (listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let importSchema = try XCTUnwrap(names?.first { $0["name"] as? String == "catalog_import" }?["inputSchema"] as? [String: Any])
        XCTAssertNotNil((importSchema["properties"] as? [String: Any])?["background"])
        let started = try payload(await tool(controller, "catalog_import", ["paths": [folder.path], "background": true]))
        let jobID = try XCTUnwrap(started["jobId"] as? String)
        XCTAssertEqual(started["status"] as? String, "running")
        var status: [String: Any] = [:]
        for _ in 0..<200 {
            status = try payload(await tool(controller, "job_status", ["jobId": jobID]))
            if status["status"] as? String != "running" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status["status"] as? String, "done", String(describing: status))
        let items = try XCTUnwrap((status["result"] as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items.filter { $0["status"] as? String == "imported" }.count, 3)
        let unknown = try await tool(controller, "job_status", ["jobId": "nope"])
        XCTAssertEqual(unknown["isError"] as? Bool, true)
        let cancelled = try payload(await tool(controller, "job_cancel", ["jobId": jobID]))
        XCTAssertEqual(cancelled["status"] as? String, "done", "Cancelling a finished job leaves its result")
    }
    @MainActor func testThumbnailsAndBatchUpdateWithOneUndo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "mcp-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let editor = EditorModel(preferences: preferences), catalog = CatalogModel(preferences: preferences)
        let controller = MCPController(preferences: preferences)
        controller.editor = editor; controller.catalog = catalog
        defer { editor.closeDocument(); catalog.stopIndexing(); controller.stop() }
        await catalog.openCatalog(dir.appendingPathComponent("test.cevichecatalog"))
        let store = try XCTUnwrap(catalog.store)
        let folder = dir.appendingPathComponent("photos"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for index in 0..<3 {
            bitmap.setFillColor(CGColor(red: Double(index) / 3, green: 0.4, blue: 0.6, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent("p\(index).jpg") as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let imported = try payload(await tool(controller, "catalog_import", ["paths": [folder.path]]))
        let ids = try XCTUnwrap((imported["items"] as? [[String: Any]])?.compactMap { $0["assetId"] as? String })
        XCTAssertEqual(ids.count, 3)

        let unlocated = try payload(await tool(controller, "catalog_query", ["hasLocation": false]))
        XCTAssertEqual((unlocated["items"] as? [[String: Any]])?.count, 3)
        let lookResult = try await tool(controller, "catalog_thumbnails", ["assetIds": ids + ["nope"], "maxEdge": 128])
        let look = try payload(lookResult)
        let items = try XCTUnwrap(look["items"] as? [[String: Any]])
        XCTAssertEqual(items.map { $0["status"] as? String }, ["ok", "ok", "ok", "missing"])
        XCTAssertEqual(items.first?["width"] as? Int, 128); XCTAssertEqual(items.first?["image"] as? Int, 1)
        let images = (lookResult["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image" } ?? []
        XCTAssertEqual(images.count, 3); XCTAssertEqual(images.first?["mimeType"] as? String, "image/jpeg")
        let sheetResult = try await tool(controller, "catalog_thumbnails", ["assetIds": ids, "maxEdge": 128, "sheet": true])
        let sheet = try payload(sheetResult)
        XCTAssertEqual((sheet["items"] as? [[String: Any]])?.last?["sheetIndex"] as? Int, 3)
        XCTAssertEqual((sheet["sheet"] as? [String: Any])?["width"] as? Int, 2 * 128 + 3 * 4)
        XCTAssertEqual((sheetResult["content"] as? [[String: Any]])?.filter { $0["type"] as? String == "image" }.count, 1)
        let revisions = items.prefix(3).map { $0["revision"] as! String }

        let batch: [[String: Any]] = [
            ["assetId": ids[0], "expectedRevision": revisions[0], "set": ["location": ["latitude": 48.8584, "longitude": 2.2945], "review": "accepted"], "addKeywords": ["Eiffel Tower"]],
            ["assetId": ids[1], "expectedRevision": revisions[1], "set": ["review": "rejected", "label": "red"]],
            ["assetId": ids[2], "expectedRevision": "stale", "set": ["rating": 5]],
            ["assetId": "nope", "set": ["rating": 1]]
        ]
        let rehearsal = try payload(await tool(controller, "catalog_update", ["items": batch, "dryRun": true]))
        XCTAssertEqual((rehearsal["items"] as? [[String: Any]])?.map { $0["status"] as? String }, ["wouldUpdate", "wouldUpdate", "revision_conflict", "failed"])
        let unchangedYet = try await store.asset(ids[0]).metadata
        XCTAssertNil(unchangedYet.latitude)
        let undoBefore = catalog.undoSteps.count
        let written = try payload(await tool(controller, "catalog_update", ["items": batch]))
        XCTAssertEqual(written["updated"] as? Int, 2); XCTAssertEqual(written["conflicts"] as? Int, 1); XCTAssertEqual(written["failed"] as? Int, 1)
        let first = try await store.asset(ids[0]).metadata, second = try await store.asset(ids[1]).metadata
        XCTAssertEqual(first.latitude, 48.8584); XCTAssertEqual(first.longitude, 2.2945); XCTAssertEqual(first.review, .accepted)
        XCTAssertEqual(first.keywords, "Eiffel Tower"); XCTAssertEqual(second.review, .rejected); XCTAssertEqual(second.label, .red)
        let third = try await store.asset(ids[2]).metadata
        XCTAssertEqual(third.rating, 0)
        let changes = try XCTUnwrap((written["items"] as? [[String: Any]])?.first?["changes"] as? [String: Any])
        XCTAssertEqual(Set(changes.keys), ["location", "review", "keywords"])
        let revision = try XCTUnwrap((written["items"] as? [[String: Any]])?.first?["revision"] as? String)
        let reread = try payload(await tool(controller, "catalog_inspect", ["assetId": ids[0]]))
        XCTAssertEqual(reread["revision"] as? String, revision, "The returned revision is the one the next read gives")
        let located = try payload(await tool(controller, "catalog_query", ["hasLocation": true]))
        XCTAssertEqual((located["items"] as? [[String: Any]])?.compactMap { $0["assetId"] as? String }, [ids[0]])
        XCTAssertEqual(first.locationSource, .assigned, "A location a client writes is marked as set in Ceviche")
        XCTAssertEqual(((located["items"] as? [[String: Any]])?.first?["location"] as? [String: Any])?["source"] as? String, "set")
        let setHere = try payload(await tool(controller, "catalog_query", ["search": "location:set"]))
        XCTAssertEqual((setHere["items"] as? [[String: Any]])?.compactMap { $0["assetId"] as? String }, [ids[0]])
        let fromFile = try payload(await tool(controller, "catalog_query", ["search": "location:file"]))
        XCTAssertEqual((fromFile["items"] as? [[String: Any]])?.count, 0)
        let none = try payload(await tool(controller, "catalog_query", ["search": "location:none"]))
        XCTAssertEqual((none["items"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(CatalogSearchToken("location:set")?.source, .place)
        // Metadata read from one photo writes back to another as is: keywords as an array, location.source ignored.
        let source = try payload(await tool(controller, "catalog_thumbnails", ["assetIds": [ids[0]]]))
        let copied = try XCTUnwrap((source["items"] as? [[String: Any]])?.first?["metadata"] as? [String: Any])
        let copy = try payload(await tool(controller, "catalog_update", ["items": [["assetId": ids[2], "set": copied]], "dryRun": true]))
        let copyItem = try XCTUnwrap((copy["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(copyItem["status"] as? String, "wouldUpdate", String(describing: copyItem))
        XCTAssertEqual(Set((copyItem["changes"] as? [String: Any] ?? [:]).keys), ["location", "review", "keywords"])
        // Tags and location narrow the query in the catalog, before the cap and the pages.
        let tagged = try payload(await tool(controller, "catalog_query", ["tags": ["all": ["eiffel tower"], "source": "keywords"]]))
        XCTAssertEqual((tagged["items"] as? [[String: Any]])?.compactMap { $0["assetId"] as? String }, [ids[0]])
        let untagged = try payload(await tool(controller, "catalog_query", ["tags": ["none": ["Eiffel Tower"]], "hasLocation": false]))
        XCTAssertEqual(Set((untagged["items"] as? [[String: Any]])?.compactMap { $0["assetId"] as? String } ?? []), [ids[1], ids[2]])
        let firstPage = try payload(await tool(controller, "catalog_query", ["limit": 2]))
        XCTAssertEqual(firstPage["remaining"] as? Int, 1)
        let secondPage = try payload(await tool(controller, "catalog_query", ["limit": 2, "cursor": try XCTUnwrap(firstPage["nextCursor"] as? String)]))
        XCTAssertEqual(secondPage["remaining"] as? Int, 0); XCTAssertNil(secondPage["nextCursor"])
        let paged = ((firstPage["items"] as? [[String: Any]] ?? []) + (secondPage["items"] as? [[String: Any]] ?? [])).compactMap { $0["assetId"] as? String }
        XCTAssertEqual(Set(paged), Set(ids))
        // The user's selection, paged; an empty one is a count of zero.
        await catalog.refresh()
        catalog.selectedIDs = []
        // GPS goes into an export only when asked for.
        let developed = try payload(await tool(controller, "photo_read", ["assetId": ids[0], "includePreview": false]))
        func exportedGPS(_ name: String, includeLocation: Bool) async throws -> [String: Any]? {
            let url = dir.appendingPathComponent(name)
            let result = try payload(await tool(controller, "photo_export", ["assetId": ids[0], "revision": try XCTUnwrap(developed["revision"]), "path": url.path,
                                                                            "format": "JPEG", "includeLocation": includeLocation]))
            XCTAssertEqual(result["includeLocation"] as? Bool, includeLocation)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])?[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        }
        let withoutGPS = try await exportedGPS("plain.jpg", includeLocation: false)
        XCTAssertNil(withoutGPS?[kCGImagePropertyGPSLatitude as String])
        // The location set in Ceviche is written, though the original file has no GPS.
        let withGPS = try await exportedGPS("located.jpg", includeLocation: true)
        XCTAssertEqual(withGPS?[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 48.8584, accuracy: 0.001)
        XCTAssertEqual(withGPS?[kCGImagePropertyGPSLongitudeRef as String] as? String, "E")
        let nothing = try payload(await tool(controller, "catalog_context"))
        XCTAssertEqual(nothing["selectedCount"] as? Int, 0); XCTAssertEqual((nothing["selectedIds"] as? [String])?.count, 0)
        XCTAssertEqual(nothing["view"] as? String, "library")
        catalog.selectedIDs = Set(ids)
        let selection = try payload(await tool(controller, "catalog_context", ["limit": 2]))
        XCTAssertEqual(selection["selectedCount"] as? Int, 3); XCTAssertEqual((selection["selectedIds"] as? [String])?.count, 2)
        let rest = try payload(await tool(controller, "catalog_context", ["offset": try XCTUnwrap(selection["nextOffset"] as? Int)]))
        XCTAssertEqual(Set((selection["selectedIds"] as? [String] ?? []) + (rest["selectedIds"] as? [String] ?? [])), Set(ids))
        catalog.selectedIDs = []

        XCTAssertEqual(catalog.undoSteps.count, undoBefore + 1, "The whole batch is one Undo step")
        // A later edit to another field survives undoing the batch.
        var titled = try await store.asset(ids[1]).metadata; titled.title = "Kept"
        try await store.updateMetadata(titled, assetID: ids[1])
        await catalog.perform(undo: true)
        let undone0 = try await store.asset(ids[0]).metadata, undone1 = try await store.asset(ids[1]).metadata
        XCTAssertNil(undone0.latitude); XCTAssertEqual(undone0.review, .unreviewed); XCTAssertEqual(undone0.keywords, "")
        XCTAssertEqual(undone1.review, .unreviewed); XCTAssertNil(undone1.label); XCTAssertEqual(undone1.title, "Kept")
        await catalog.perform(undo: false)
        let redone = try await store.asset(ids[1]).metadata
        XCTAssertEqual(redone.review, .rejected); XCTAssertEqual(redone.title, "Kept")

        let removal = try payload(await tool(controller, "catalog_update", ["items": [["assetId": ids[0], "removeKeywords": ["eiffel tower"], "set": ["location": NSNull()]]]]))
        XCTAssertEqual(removal["updated"] as? Int, 1)
        let cleared = try await store.asset(ids[0]).metadata
        XCTAssertEqual(cleared.keywords, ""); XCTAssertNil(cleared.latitude); XCTAssertNil(cleared.locationSource)

        // Placed by hand: the same mark, one Undo step for the selection, and the picker starts at the photos' own location.
        await catalog.setLocation((35.6586, 139.7454), assetIDs: [ids[0], ids[2]])
        let placed = try await store.asset(ids[2])
        XCTAssertEqual(placed.latitude, 35.6586); XCTAssertEqual(placed.locationSource, .assigned)
        XCTAssertEqual(catalog.undoSteps.last?.name, L10n.tr("Location"))
        let start = await catalog.startingLocation(for: [try await store.asset(ids[1]), placed])
        XCTAssertEqual(start?.latitude, 35.6586)
        let unknown = await catalog.startingLocation(for: [try await store.asset(ids[1])])
        XCTAssertNil(unknown, "No capture time, nothing to start near")
        await catalog.perform(undo: true)
        let unplaced = try await store.asset(ids[2])
        XCTAssertNil(unplaced.latitude); XCTAssertNil(unplaced.locationSource)
        await catalog.perform(undo: false)
        await catalog.setLocation(nil, assetIDs: [ids[0]])
        let removed = try await store.asset(ids[0])
        XCTAssertNil(removed.latitude); XCTAssertNil(removed.locationSource)
        // Show Nearby Photos: the Map, pointed at the photo's surroundings, with the photo selected.
        let tokyo = try await store.asset(ids[2])
        XCTAssertTrue(catalog.canShowNearby([tokyo])); XCTAssertFalse(catalog.canShowNearby([removed]))
        var latitudeOnly = tokyo; latitudeOnly.longitude = nil
        XCTAssertFalse(catalog.canShowNearby([latitudeOnly]), "Enabled only when the action can run")
        await catalog.showNearby(tokyo, editor: editor)
        XCTAssertTrue(catalog.filter.geotagged); XCTAssertEqual(catalog.shownOverview, .map)
        XCTAssertEqual(catalog.mapFocus?.latitude, 35.6586); XCTAssertEqual(catalog.selected?.id, ids[2])
        await catalog.showCollection(area: .library)
        XCTAssertNil(catalog.mapFocus, "Leaving for another collection forgets the point")
        XCTAssertEqual(LocationPicker.coordinate("48.8584, 2.2945")?.longitude, 2.2945)
        XCTAssertNil(LocationPicker.coordinate("Eiffel Tower")); XCTAssertNil(LocationPicker.coordinate("95, 10"))
        // Suggestions wait for a pause in typing, but never more than maxWait after the first unsent keystroke.
        let typed = ContinuousClock.now
        XCTAssertEqual(PlaceCompleter.delay(waitingSince: typed, now: typed), PlaceCompleter.debounce)
        XCTAssertEqual(PlaceCompleter.delay(waitingSince: typed, now: typed + .milliseconds(600)), .milliseconds(100))
        XCTAssertEqual(PlaceCompleter.delay(waitingSince: typed, now: typed + .seconds(2)), .zero)
    }
    @MainActor func testLibraryAndEditingWorkflowSharesUIStateAndRejectsStaleEdits() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "mcp-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let editor = EditorModel(preferences: preferences), catalog = CatalogModel(preferences: preferences)
        let controller = MCPController(preferences: preferences)
        controller.editor = editor; controller.catalog = catalog
        defer { editor.closeDocument(); catalog.stopIndexing(); controller.stop() }
        await catalog.openCatalog(dir.appendingPathComponent("test.cevichecatalog"))
        let store = try XCTUnwrap(catalog.store)
        let query = try payload(await tool(controller, "catalog_query"))
        let catalogID = try XCTUnwrap(query["catalogId"] as? String)
        let source = dir.appendingPathComponent("photo.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 128, height: 80, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 128, height: 80))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        let imported = try payload(await tool(controller, "catalog_import", ["catalogId": catalogID, "paths": [source.path]]))
        let id = try XCTUnwrap((imported["items"] as? [[String: Any]])?.first?["assetId"] as? String)
        let ref: [String: Any] = ["catalogId": catalogID, "assetId": id]
        let inspect = try payload(await tool(controller, "catalog_inspect", ref))
        XCTAssertEqual(inspect["physicalPath"] as? String, source.resolvingSymlinksInPath().path)
        XCTAssertNotNil(inspect["capture"] as? [String: Any], "Capture settings are always present, even when empty")
        let capture = MCPController.capture([
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [200], kCGImagePropertyExifExposureTime as String: 0.005,
                                                       kCGImagePropertyExifFNumber as String: 7.1, kCGImagePropertyExifFocalLength as String: 60.0, kCGImagePropertyExifExposureBiasValue as String: -0.7],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "ILCE-7RM3"]])
        XCTAssertEqual(capture["iso"] as? Int, 200); XCTAssertEqual(capture["shutter"] as? String, "1/200 s")
        XCTAssertEqual(capture["fNumber"] as? Double, 7.1); XCTAssertEqual(capture["model"] as? String, "ILCE-7RM3"); XCTAssertEqual(capture["exposureBias"] as? Double, -0.7)
        let update: [String: Any] = ["catalogId": catalogID, "items": [["assetId": id, "expectedRevision": inspect["revision"]!, "set": ["keywords": "mountain, blue sky", "rating": 4]]]]
        _ = try payload(await tool(controller, "catalog_update", update))
        let exact = try payload(await tool(controller, "catalog_query", ["catalogId": catalogID, "tags": ["all": ["BLUE SKY"], "source": "keywords"]]))
        XCTAssertEqual((exact["items"] as? [[String: Any]])?.count, 1)
        let partial = try payload(await tool(controller, "catalog_query", ["catalogId": catalogID, "tags": ["all": ["sky"], "source": "keywords"]]))
        XCTAssertEqual((partial["items"] as? [[String: Any]])?.count, 0)
        let asset = try await store.asset(id)
        let opened = await editor.open(source, catalog: store, asset: asset)
        XCTAssertTrue(opened)
        editor.edit { $0.exposure = 0.2 }
        var readArgs = ref; readArgs["includePreview"] = false
        let observation = try payload(await tool(controller, "photo_read", readArgs))
        let editing = observation["editing"] as! [String: Any]
        XCTAssertEqual((editing["global"] as? [String: Any])?["exposure"] as? Double, 0.2)
        let revision = try XCTUnwrap(observation["revision"] as? String)
        XCTAssertTrue(editor.dirty, "Reads must not save pending UI edits")
        let saved = await editor.save()
        XCTAssertTrue(saved)
        var apply = ref; apply["expectedRevision"] = revision; apply["schemaVersion"] = "1"
        apply["changes"] = ["global": ["exposure": 0.4, "typo": 2]]
        let historyBefore = try await store.history(assetID: id).count
        let invalid = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(invalid["isError"] as? Bool, true)
        XCTAssertEqual(editor.adjustments.exposure, 0.2)
        let historyAfterInvalid = try await store.history(assetID: id).count
        XCTAssertEqual(historyBefore, historyAfterInvalid)
        apply["changes"] = ["global": ["exposure": 0.4, "highlights": -25]]
        var rehearsal = apply; rehearsal["dryRun"] = true; rehearsal["scope"] = [0, 0, 0.5, 0.5]
        let rehearsalResult = try await tool(controller, "photo_apply", rehearsal)
        let rehearsed = try payload(rehearsalResult)
        XCTAssertEqual(rehearsed["committed"] as? Bool, false); XCTAssertEqual(rehearsed["revision"] as? String, revision)
        XCTAssertNotEqual(rehearsed["candidateRevision"] as? String, revision)
        XCTAssertEqual(((rehearsed["editing"] as? [String: Any])?["global"] as? [String: Any])?["exposure"] as? Double, 0.4)
        XCTAssertEqual((rehearsed["preview"] as? [String: Any])?["width"] as? Int, 64); XCTAssertNotNil(rehearsed["statistics"])
        XCTAssertEqual((rehearsalResult["content"] as? [[String: Any]])?.last?["type"] as? String, "image")
        XCTAssertEqual(editor.adjustments.exposure, 0.2)
        let historyAfterRehearsal = try await store.history(assetID: id).count
        XCTAssertEqual(historyAfterRehearsal, historyBefore, "A dry run commits nothing")
        var identityArgs = ref; identityArgs["from"] = "preview"; identityArgs["points"] = [[0.25, 0.75]]
        let identityResult = try payload(await tool(controller, "photo_convert", identityArgs))
        let identity = try XCTUnwrap(identityResult["points"] as? [[Double]])
        XCTAssertEqual(identity[0][0], 0.25, accuracy: 0.001); XCTAssertEqual(identity[0][1], 0.25, accuracy: 0.001, "Without geometry only the vertical axis flips")
        let edited = try payload(await tool(controller, "photo_apply", apply))
        XCTAssertEqual(editor.adjustments.exposure, 0.4); XCTAssertEqual(editor.adjustments.highlights, -25)
        XCTAssertEqual(editor.undoStack.last?.exposure, 0.2); XCTAssertFalse(editor.dirty)
        let historyAfterEdit = try await store.history(assetID: id).count
        XCTAssertEqual(historyAfterEdit, historyBefore + 1)
        let stale = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(((stale["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "revision_conflict")
        var previewArgs = ref; previewArgs["revision"] = edited["revision"]; previewArgs["scope"] = [0, 0, 0.5, 0.5]
        let previewResult = try await tool(controller, "photo_preview", previewArgs)
        let preview = try payload(previewResult)["preview"] as! [String: Any]
        XCTAssertEqual(preview["width"] as? Int, 64); XCTAssertEqual(preview["height"] as? Int, 40)
        XCTAssertEqual((previewResult["content"] as? [[String: Any]])?.last?["type"] as? String, "image")
        let maskID = UUID().uuidString
        apply["expectedRevision"] = edited["revision"]
        apply["changes"] = ["addMasks": [["id": maskID, "kind": "Radial gradient", "name": "Centre", "start": ["x": 0.25, "y": 0.25], "end": ["x": 0.75, "y": 0.75], "adjustments": ["exposure": 0.5]]]]
        let withMask = try payload(await tool(controller, "photo_apply", apply))
        var matteArgs = ref; matteArgs["mask"] = maskID; matteArgs["includeImage"] = false
        let matte = try payload(await tool(controller, "photo_preview", matteArgs))
        let maskInfo = try XCTUnwrap(matte["mask"] as? [String: Any])
        XCTAssertEqual(maskInfo["name"] as? String, "Centre")
        let coverage = try XCTUnwrap(maskInfo["coverage"] as? Double)
        XCTAssertGreaterThan(coverage, 0.05); XCTAssertLessThan(coverage, 0.5)
        var cube = ["LUT_3D_SIZE 2"]
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube.append("\(1 - r) \(1 - g) \(1 - b)") } } }
        let lutFile = dir.appendingPathComponent("Invert.cube"); try cube.joined(separator: "\n").write(to: lutFile, atomically: true, encoding: .utf8)
        let presetFile = dir.appendingPathComponent("Warm.xmp")
        try "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"\(XMPPacket.rdf)\"><rdf:Description xmlns:crs=\"\(XMPPacket.crs)\" crs:Exposure2012=\"1\" crs:Contrast2012=\"30\"/></rdf:RDF></x:xmpmeta>".write(to: presetFile, atomically: true, encoding: .utf8)
        let looks = try payload(await tool(controller, "photo_looks", ["kind": "LUTs"]))
        XCTAssertNotNil((looks["LUTs"] as? [String: Any])?["folder"] as? String); XCTAssertNil(looks["Presets"])
        apply["expectedRevision"] = withMask["revision"]
        apply["changes"] = ["applyFiles": [["path": lutFile.path], ["path": presetFile.path]], "global": ["lut": ["amount": 0.5], "contrast": 12]]
        let looked = try payload(await tool(controller, "photo_apply", apply))
        let lookedGlobal = try XCTUnwrap((looked["editing"] as? [String: Any])?["global"] as? [String: Any])
        XCTAssertEqual((lookedGlobal["lut"] as? [String: Any])?["amount"] as? Double, 0.5, "The patch merges after the files")
        XCTAssertEqual((lookedGlobal["lut"] as? [String: Any])?["samplesPresent"] as? Bool, true)
        XCTAssertEqual(lookedGlobal["exposure"] as? Double, 1); XCTAssertEqual(lookedGlobal["contrast"] as? Double, 12)
        XCTAssertEqual(editor.adjustments.lut?.amount, 0.5)
        apply["expectedRevision"] = looked["revision"]; apply["changes"] = ["applyFiles": [["path": dir.appendingPathComponent("missing.cube").path]]]
        let missingLook = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(((missingLook["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "missing_file")
        let notes = dir.appendingPathComponent("notes.txt"); try "not a look".write(to: notes, atomically: true, encoding: .utf8)
        apply["changes"] = ["applyFiles": [["path": notes.path]]]
        let wrongKind = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(((wrongKind["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "unsupported_look")
        // A PNG may be a Hald LUT, so a photo saved as PNG is a look that fails to load rather than an unsupported kind.
        apply["changes"] = ["applyFiles": [["path": source.path]]]
        let notHald = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(((notHald["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "invalid_look")
        apply["changes"] = ["global": ["lut": NSNull(), "exposure": 0.4, "contrast": 0]]
        let unlooked = try payload(await tool(controller, "photo_apply", apply))
        XCTAssertNil(((unlooked["editing"] as? [String: Any])?["global"] as? [String: Any])?["lut"] as? [String: Any])
        apply["expectedRevision"] = unlooked["revision"]
        apply["changes"] = ["addMasks": [["id": UUID().uuidString, "kind": "Object"]]]
        let noPoint = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(((noPoint["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "point_required")
        apply["changes"] = ["addMasks": [["id": UUID().uuidString, "kind": "Subject"]]]
        let flat = try await tool(controller, "photo_apply", apply)
        XCTAssertEqual(flat["isError"] as? Bool, true, "A flat colour has no foreground subject, and the failure commits nothing")
        XCTAssertEqual(editor.adjustments.masks.count, 1)
        apply["changes"] = ["masks": [maskID: ["components": [["id": UUID().uuidString, "operation": "Subtract", "selection": ["kind": "Linear gradient", "start": ["x": 0.5, "y": 0.0], "end": ["x": 0.5, "y": 0.5]]]]]]]
        let compound = try payload(await tool(controller, "photo_apply", apply))
        let compoundMask = try XCTUnwrap((compound["editing"] as? [String: Any])?["masks"] as? [[String: Any]]).first { ($0["id"] as? String)?.lowercased() == maskID.lowercased() }
        XCTAssertEqual((compoundMask?["components"] as? [[String: Any]])?.count, 1)
        matteArgs["mask"] = maskID
        let trimmed = try payload(await tool(controller, "photo_preview", matteArgs))
        let trimmedCoverage = try XCTUnwrap((trimmed["mask"] as? [String: Any])?["coverage"] as? Double)
        XCTAssertLessThan(trimmedCoverage, coverage, "Subtracting the lower half shrinks the matte")
        apply["expectedRevision"] = compound["revision"]
        matteArgs["mask"] = UUID().uuidString
        let missing = try await tool(controller, "photo_preview", matteArgs)
        XCTAssertEqual(((missing["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "missing_mask")
        apply["changes"] = ["removeMasks": [maskID]]
        let unmasked = try payload(await tool(controller, "photo_apply", apply))
        var historyArgs = ref; historyArgs["fields"] = ["history"]
        let inspected = try payload(await tool(controller, "catalog_inspect", historyArgs))
        let history = try XCTUnwrap(inspected["history"] as? [[String: Any]])
        let entries = try await store.history(assetID: id)
        let oldest = try XCTUnwrap(entries.last { $0.kind == .edit })
        XCTAssertTrue(history.contains { $0["id"] as? String == oldest.id })
        let earlier = try await store.adjustments(of: oldest)
        XCTAssertNotEqual(earlier, editor.adjustments)
        var restoreArgs = ref; restoreArgs["expectedRevision"] = unmasked["revision"]; restoreArgs["historyId"] = oldest.id
        let rewound = try payload(await tool(controller, "photo_restore", restoreArgs))
        XCTAssertEqual((rewound["restored"] as? [String: Any])?["kind"] as? String, "edit")
        XCTAssertEqual(editor.adjustments, earlier, "Restoring updates the open editor")
        let historyAfterRestore = try await store.history(assetID: id).count
        XCTAssertEqual(historyAfterRestore, entries.count + 1, "Restore adds a revision instead of rewinding")
        restoreArgs["expectedRevision"] = rewound["revision"]; restoreArgs["historyId"] = "nope"
        let noHistory = try await tool(controller, "photo_restore", restoreArgs)
        XCTAssertEqual(((noHistory["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "missing_history")
        apply["expectedRevision"] = rewound["revision"]; apply["changes"] = ["global": ["exposure": 0.4, "highlights": -25]]
        let reapplied = try payload(await tool(controller, "photo_apply", apply))
        var exportArgs = ref; exportArgs["revision"] = reapplied["revision"]; exportArgs["path"] = dir.appendingPathComponent("output.png").path
        exportArgs["format"] = "PNG"; exportArgs["bitsPerChannel"] = 16; exportArgs["size"] = ["width": 64, "height": 64]
        let exported = try payload(await tool(controller, "photo_export", exportArgs))
        XCTAssertEqual(exported["width"] as? Int, 64); XCTAssertEqual(exported["height"] as? Int, 40)
        let overwrite = try await tool(controller, "photo_export", exportArgs)
        XCTAssertEqual(overwrite["isError"] as? Bool, true)
        exportArgs["path"] = dir.appendingPathComponent("asshot.png").path; exportArgs["rendition"] = "asShot"
        let asShot = try payload(await tool(controller, "photo_export", exportArgs))
        XCTAssertEqual(asShot["rendition"] as? String, "asShot"); XCTAssertEqual(asShot["width"] as? Int, 64)
        XCTAssertNotEqual(try Data(contentsOf: dir.appendingPathComponent("asshot.png")), try Data(contentsOf: dir.appendingPathComponent("output.png")), "As-shot export ignores the +0.4 EV edit")
        exportArgs.removeValue(forKey: "rendition")
        apply["expectedRevision"] = reapplied["revision"]; apply["changes"] = ["global": ["quarterTurns": 1]]
        let rotated = try payload(await tool(controller, "photo_apply", apply))
        exportArgs["revision"] = rotated["revision"]; exportArgs["path"] = dir.appendingPathComponent("tiny.png").path
        exportArgs["size"] = ["width": 1, "height": 1]
        var convertArgs = ref; convertArgs["from"] = "preview"; convertArgs["points"] = [[0.25, 0.75], [0, 0]]
        let converted = try payload(await tool(controller, "photo_convert", convertArgs))
        XCTAssertEqual(converted["to"] as? String, "mask")
        let maskPoints = try XCTUnwrap(converted["points"] as? [[Double]])
        // One clockwise quarter turn: the preview's lower-left quadrant point maps back into the unrotated source.
        XCTAssertEqual(maskPoints[0].count, 2); XCTAssertTrue(maskPoints[0].allSatisfy { (0...1).contains($0) })
        convertArgs["from"] = "mask"; convertArgs["points"] = maskPoints
        let roundTripResult = try payload(await tool(controller, "photo_convert", convertArgs))
        let roundTrip = try XCTUnwrap(roundTripResult["points"] as? [[Double]])
        XCTAssertEqual(roundTrip[0][0], 0.25, accuracy: 0.01); XCTAssertEqual(roundTrip[0][1], 0.75, accuracy: 0.01)
        XCTAssertEqual(roundTrip[1][0], 0, accuracy: 0.01); XCTAssertEqual(roundTrip[1][1], 0, accuracy: 0.01)
        let tooSmall = try await tool(controller, "photo_export", exportArgs)
        XCTAssertEqual(((tooSmall["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "invalid_size")
        _ = try payload(await tool(controller, "catalog_trash", ["catalogId": catalogID, "assetIds": [id]]))
        let trashed = try await store.asset(id); XCTAssertNotNil(trashed.trashedAt)
        XCTAssertNil(editor.catalogAssetID)
        _ = try payload(await tool(controller, "catalog_restore", ["catalogId": catalogID, "assetIds": [id]]))
        let restored = try await store.asset(id); XCTAssertNil(restored.trashedAt)
        XCTAssertEqual(try Data(contentsOf: source), original)
        // An original that changed can't be read, so its revision can't be checked: a stale revision leaves
        // history alone, and only recover: true restores.
        try Data("changed".utf8).write(to: source)
        let beforeRecovery = try await store.history(assetID: id).count
        var recoverArgs = ref; recoverArgs["expectedRevision"] = "stale"; recoverArgs["historyId"] = oldest.id
        let unchecked = try await tool(controller, "photo_restore", recoverArgs)
        XCTAssertEqual(((unchecked["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "revision_unavailable")
        let afterRefusal = try await store.history(assetID: id).count
        XCTAssertEqual(afterRefusal, beforeRecovery, "A refused restore writes nothing")
        recoverArgs["recover"] = true
        let recovered = try payload(await tool(controller, "photo_restore", recoverArgs))
        XCTAssertNotNil(recovered["note"], "Restored, but the photo still can't be read")
        let afterRecovery = try await store.history(assetID: id).count
        XCTAssertEqual(afterRecovery, beforeRecovery + 1)
    }
}
