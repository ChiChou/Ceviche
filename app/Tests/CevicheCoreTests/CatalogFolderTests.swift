import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogFolderTests: XCTestCase {
    /// Browsing a folder indexes what is directly in it, by reference, and follows files added and deleted there.
    func testSyncIndexesAFolderAndFollowsItsFiles() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Shoot"), nested = folder.appendingPathComponent("Selects")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try fm.copyItem(at: photo, to: folder.appendingPathComponent(name)) }
        try fm.copyItem(at: photo, to: nested.appendingPathComponent("d.jpg"))
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try fm.createDirectory(at: folder.appendingPathComponent("Library.cevichecatalog"), withIntermediateDirectories: true)

        let listing = try CatalogFolders.list(folder)
        XCTAssertEqual(listing.photos.map(\.lastPathComponent), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(listing.folders.map(\.lastPathComponent), ["Library.cevichecatalog", "Selects"].filter { $0 != "Library.cevichecatalog" || !Self.catalogIsPackage })

        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var result = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(result.added, 3); XCTAssertEqual(result.failed, 0); XCTAssertEqual(result.found, 3)
        var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder); filter.sort = .filename; filter.ascending = true
        var shown = try await store.assets(filter: filter)
        XCTAssertEqual(shown.map(\.filename), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertTrue(shown.allSatisfy { !$0.isCopy && $0.importBatchID == nil })
        // The subfolder is its own folder; a sibling whose name starts the same is not inside.
        filter.folder = CatalogFolders.path(nested)
        var count = try await store.count(filter: filter); XCTAssertEqual(count, 0)
        _ = try await CatalogFolders.sync(nested, store: store)
        count = try await store.count(filter: filter); XCTAssertEqual(count, 1)
        filter.folder = CatalogFolders.path(folder)
        count = try await store.count(filter: filter); XCTAssertEqual(count, 3)

        // Nothing changed: nothing to do. A file named in `skipping` is left for a later sync.
        result = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(result, { var same = CatalogFolders.SyncResult(); same.found = 3; return same }())
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("f.jpg"))
        result = try await CatalogFolders.sync(folder, store: store, skipping: [folder.appendingPathComponent("f.jpg").path])
        XCTAssertEqual(result.added, 0); XCTAssertEqual(result.found, 4)
        try fm.removeItem(at: folder.appendingPathComponent("f.jpg"))

        // A file added and two deleted; the rated one keeps its record, and so does the one named in `keeping`.
        try await store.updateQuickMetadata(assetIDs: [shown[1].id], rating: 4)
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("e.jpg"))
        try fm.removeItem(at: folder.appendingPathComponent("a.jpg")); try fm.removeItem(at: folder.appendingPathComponent("b.jpg"))
        result = try await CatalogFolders.sync(folder, store: store, keeping: [shown[0].id])
        XCTAssertEqual(result.added, 1); XCTAssertEqual(result.removed, 0)
        result = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(result.added, 0); XCTAssertEqual(result.removed, 1)
        shown = try await store.assets(filter: filter)
        XCTAssertEqual(shown.map(\.filename), ["b.jpg", "c.jpg", "e.jpg"])
        XCTAssertThrowsError(try CatalogFolders.list(directory.appendingPathComponent("Gone"))) { XCTAssertFalse(CatalogFolders.isDenied($0)) }
    }

    /// Photos are listed first, without thumbnails, and the thumbnails follow; a sync that was stopped before they
    /// arrived is finished by the next one.
    func testSyncListsBeforeItMakesThumbnails() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default, folder = directory.appendingPathComponent("Shoot")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try fm.copyItem(at: photo, to: folder.appendingPathComponent(name)) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder)
        let query = filter
        let seen = Seen()
        let result = try await CatalogFolders.sync(folder, store: store, listed: {
            let listed = (try? await store.assets(filter: query)) ?? []
            await seen.note(listed.count, bare: listed.filter { $0.thumbnailKey == nil }.count)
        }, progress: { done, total in await seen.progress(done, total) })
        XCTAssertEqual(result.added, 3); XCTAssertEqual(result.thumbnails, 3)
        let (listed, bare, last) = await (seen.listed, seen.bare, seen.last)
        XCTAssertEqual(listed, 3); XCTAssertEqual(bare, 3, "listed before any thumbnail was made")
        XCTAssertEqual(last.0, 3); XCTAssertEqual(last.1, 3)
        var shown = try await store.assets(filter: filter)
        XCTAssertTrue(shown.allSatisfy { $0.thumbnailKey != nil })

        // Stopped right after listing: the records are there, bare, and the next visit gives them thumbnails.
        for name in ["d.jpg", "e.jpg"] { try fm.copyItem(at: photo, to: folder.appendingPathComponent(name)) }
        let stopped = Task { try await CatalogFolders.sync(folder, store: store, listed: { withUnsafeCurrentTask { $0?.cancel() } }) }
        let partial = try await stopped.value
        XCTAssertEqual(partial.added, 2); XCTAssertEqual(partial.thumbnails, 0)
        let resumed = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(resumed.added, 0); XCTAssertEqual(resumed.thumbnails, 2)
        shown = try await store.assets(filter: filter)
        XCTAssertEqual(shown.count, 5); XCTAssertTrue(shown.allSatisfy { $0.thumbnailKey != nil })
    }
    private actor Seen {
        var listed = 0, bare = 0, last = (0, 0)
        func note(_ count: Int, bare: Int) { listed = count; self.bare = bare }
        func progress(_ done: Int, _ total: Int) { last = (done, total) }
    }

    /// With its subfolders, a folder takes in everything below it and nothing beside it.
    func testSyncIncludesSubfolders() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Shoot"), deepest = folder.appendingPathComponent("Day 1/Selects"), beside = directory.appendingPathComponent("Shoot 2")
        try fm.createDirectory(at: deepest, withIntermediateDirectories: true); try fm.createDirectory(at: beside, withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("a.jpg"))
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("Day 1/b.jpg"))
        try fm.copyItem(at: photo, to: deepest.appendingPathComponent("c.jpg"))
        try fm.copyItem(at: photo, to: folder.appendingPathComponent(".hidden/x.jpg"))
        try fm.copyItem(at: photo, to: beside.appendingPathComponent("d.jpg"))
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        _ = try await CatalogFolders.sync(beside, store: store)
        var result = try await CatalogFolders.sync(folder, store: store, deep: true)
        XCTAssertEqual(result.added, 3); XCTAssertEqual(result.found, 3)
        var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder); filter.sort = .filename; filter.ascending = true
        var count = try await store.count(filter: filter); XCTAssertEqual(count, 1)
        filter.subfolders = true
        let shown = try await store.assets(filter: filter)
        XCTAssertEqual(shown.map(\.filename), ["a.jpg", "b.jpg", "c.jpg"])
        // The folder's Info panel: what it holds, with and without the folders below; and nothing shows unchosen.
        let deepSummary = try await store.folderSummary(CatalogFolders.path(folder), deep: true)
        let ownSummary = try await store.folderSummary(CatalogFolders.path(folder))
        XCTAssertEqual(deepSummary.photos, 3); XCTAssertEqual(ownSummary.photos, 1)
        XCTAssertGreaterThan(deepSummary.bytes, ownSummary.bytes); XCTAssertEqual(deepSummary.firstDay, "2025-10-23")
        var unchosen = CatalogFilter(); unchosen.nothing = true
        let none = try await store.count(filter: unchosen); XCTAssertEqual(none, 0)
        // A file deleted two levels down is followed; the folder beside is untouched.
        try fm.removeItem(at: deepest.appendingPathComponent("c.jpg"))
        result = try await CatalogFolders.sync(folder, store: store, deep: true)
        XCTAssertEqual(result.removed, 1); XCTAssertEqual(result.found, 2)
        filter.folder = CatalogFolders.path(beside); filter.subfolders = false
        count = try await store.count(filter: filter); XCTAssertEqual(count, 1)
        let plan = try await store.database.read { db in
            var deep = CatalogFilter(); deep.folder = "/Volumes/Card/DCIM"; deep.subfolders = true
            let statement = try CatalogStore.query(deep).select(CatalogAsset.Columns.id).makePreparedRequest(db, forSingleResult: false).statement
            return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments).map { $0["detail"] as String }.joined(separator: "\n")
        }
        XCTAssertTrue(plan.contains("asset_folder"), plan)
        // The rows come from the folder index; the catalog is sought by row, never passed over.
        XCTAssertTrue(plan.contains("rowid=?"), plan)
        XCTAssertFalse(plan.contains("(archivedAt=?)") || plan.contains("SCAN asset"), plan)
    }

    /// A photo with a sidecar is listed and shown with the camera's preview, then developed with the sidecar's edits.
    func testSyncDevelopsPhotosWithSidecars() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default, folder = directory.appendingPathComponent("Shoot")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("plain.jpg"))
        try fm.copyItem(at: photo, to: folder.appendingPathComponent("edited.jpg"))
        try """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+1.50"/>
            </rdf:RDF></x:xmpmeta>
            """.write(to: folder.appendingPathComponent("edited.xmp"), atomically: true, encoding: .utf8)
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let result = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(result.added, 2); XCTAssertEqual(result.thumbnails, 2); XCTAssertEqual(result.developed, 1)
        var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder); filter.sort = .filename; filter.ascending = true
        let shown = try await store.assets(filter: filter)
        XCTAssertEqual(shown.map(\.filename), ["edited.jpg", "plain.jpg"])
        XCTAssertEqual(shown[0].thumbnailRenderKey, shown[0].renderKey, "the thumbnail shows the sidecar's edits")
        XCTAssertNil(shown[0].lastEditedAt, "a sidecar read in a folder is not an edit to write back")
        // Nothing is left to develop on the next visit.
        let again = try await CatalogFolders.sync(folder, store: store)
        XCTAssertEqual(again.developed, 0); XCTAssertEqual(again.thumbnails, 0)
    }

    /// A catalog import counts a sidecar's development as an edit, so the photo shows under Edited; plain photos and a
    /// sidecar that changes nothing don't.
    func testImportedSidecarEditsCountAsEdited() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default
        for name in ["plain", "edited", "unchanged"] { try fm.copyItem(at: photo, to: directory.appendingPathComponent("\(name).jpg")) }
        func sidecar(_ name: String, _ attributes: String) throws {
            try """
                <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attributes)/>
                </rdf:RDF></x:xmpmeta>
                """.write(to: directory.appendingPathComponent("\(name).xmp"), atomically: true, encoding: .utf8)
        }
        try sidecar("edited", "crs:Exposure2012=\"+1.50\"")
        try sidecar("unchanged", "crs:Exposure2012=\"0\"")
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var options = CatalogImporter.ImportOptions(thumbnail: false); options.marksSidecarEdits = true
        var edited: [String: Bool] = [:]
        for name in ["plain", "edited", "unchanged"] {
            let asset = try await store.insert(CatalogImporter.prepare(directory.appendingPathComponent("\(name).jpg"), options: options).0, thumbnail: nil)
            edited[name] = asset.lastEditedAt != nil
        }
        XCTAssertEqual(edited, ["plain": false, "edited": true, "unchanged": false])
        var filter = CatalogFilter(); filter.recentEdits = true
        let count = try await store.count(filter: filter)
        XCTAssertEqual(count, 1)
    }

    /// An import made while browsing a folder is a copy into that folder, catalogued where it lands.
    func testImportCopiesIntoTheFolder() throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default, folder = directory.appendingPathComponent("Shoot")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: directory.appendingPathComponent("Catalog"))
        options.copyFolder = folder
        let first = try CatalogImporter.prepare(photo, options: options).0
        XCTAssertEqual(first.asset.sourcePath, folder.appendingPathComponent("photo.jpg").path)
        XCTAssertFalse(first.asset.isCopy, "the file belongs to the folder, not to the catalog")
        XCTAssertTrue(fm.fileExists(atPath: first.asset.sourcePath)); XCTAssertTrue(fm.fileExists(atPath: photo.path))
        // The same name again takes a free one; a file already in the folder is used where it is.
        let second = try CatalogImporter.prepare(photo, options: options).0
        XCTAssertEqual(second.asset.sourcePath, folder.appendingPathComponent("photo 2.jpg").path)
        let inPlace = try CatalogImporter.prepare(folder.appendingPathComponent("photo.jpg"), options: options).0
        XCTAssertEqual(inPlace.asset.sourcePath, first.asset.sourcePath)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), ["photo 2.jpg", "photo.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent("Catalog/Originals").path))
    }

    /// The index of browsed folders is a cache: edits are written to the photo's XMP sidecar and come back when the
    /// folder is listed into an empty index. A photo that was only looked at leaves nothing behind, and another
    /// application's sidecar is left alone.
    func testFolderEditsSurviveAnEmptiedIndex() async throws {
        let (directory, photo) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fm = FileManager.default, folder = directory.appendingPathComponent("Shoot")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try fm.copyItem(at: photo, to: folder.appendingPathComponent(name)) }
        let theirs = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPacket.rdf)">
        <rdf:Description xmlns:crs="\(XMPPacket.crs)" xmlns:xmp="\(XMPPacket.xmp)" xmp:CreatorTool="Another Raw Editor" crs:Exposure2012="1.25"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
        try theirs.write(to: folder.appendingPathComponent("c.xmp"))
        var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder); filter.sort = .filename; filter.ascending = true
        func files() throws -> [String] { try fm.contentsOfDirectory(atPath: folder.path).sorted() }

        var store = try CatalogStore(root: directory.appendingPathComponent("Index 1"))
        let opened = Date().addingTimeInterval(-1)
        _ = try await CatalogFolders.sync(folder, store: store, folderData: true)
        var mark = try await FolderEdits.flush(store, since: opened)
        XCTAssertEqual(try files(), ["a.jpg", "b.jpg", "c.jpg", "c.xmp"], "browsing alone writes nothing into the folder")

        var shown = try await store.assets(filter: filter)
        var edit = Adjustments(); edit.exposure = 0.7
        try await store.saveEdits(edit, assetID: shown[1].id, baseline: Adjustments())
        var other = try await store.savedAdjustments(of: shown[2]) ?? Adjustments(); other.exposure = 0.3
        try await store.saveEdits(other, assetID: shown[2].id, baseline: Adjustments())
        mark = try await FolderEdits.flush(store, since: mark)
        XCTAssertEqual(try files(), ["a.jpg", "b.jpg", "b.xmp", "c.ceviche.xmp", "c.jpg", "c.xmp"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("c.xmp")), theirs)
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(".ceviche").path))

        // The cache is emptied: a new index lists the folder and has the edits again, ours before theirs.
        store = try CatalogStore(root: directory.appendingPathComponent("Index 2"))
        _ = try await CatalogFolders.sync(folder, store: store, folderData: true)
        shown = try await store.assets(filter: filter)
        let restored = try await store.savedAdjustments(of: shown[1])
        XCTAssertEqual(restored?.exposure, 0.7)
        let ours = try await store.savedAdjustments(of: shown[2])
        XCTAssertEqual(ours?.exposure, 0.3)
        // Listing reads the sidecars without writing them back.
        _ = try await FolderEdits.flush(store, since: opened)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("c.xmp")), theirs)

        // A file deleted from the folder drops its record here whatever was made of it.
        try fm.removeItem(at: folder.appendingPathComponent("b.jpg"))
        let result = try await CatalogFolders.sync(folder, store: store, folderData: true)
        XCTAssertEqual(result.removed, 1)
        try await store.forgetFolder(below: CatalogFolders.path(folder))
        let count = try await store.count(filter: filter); XCTAssertEqual(count, 0)
    }

    /// Only what can be developed counts as a photo: a drawing is an image to the system, but not one of ours.
    func testDrawingsAreNotPhotos() throws {
        for name in ["logo.svg", "logo.SVG", "notes.pdf", "movie.mov", "sheet.txt"] { XCTAssertFalse(CatalogImporter.supported(URL(fileURLWithPath: "/tmp/" + name)), name) }
        for name in ["a.jpg", "a.ARW", "a.dng", "a.heic", "a.png", "a.tiff", "a.jxl", "a.jp2"] { XCTAssertTrue(CatalogImporter.supported(URL(fileURLWithPath: "/tmp/" + name)), name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: directory.appendingPathComponent("logo.svg"))
        XCTAssertTrue(try CatalogFolders.list(directory).photos.isEmpty)
    }

    func testLRUCacheDropsWhatWasUsedLongestAgo() {
        var cache = LRUCache<String, Int>(countLimit: 3, costLimit: 100)
        cache.insert(1, for: "a", cost: 10); cache.insert(2, for: "b", cost: 10); cache.insert(3, for: "c", cost: 10)
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.insert(4, for: "d", cost: 10), ["b"], "a was read after b")
        XCTAssertNil(cache.peek("b")); XCTAssertEqual(cache.count, 3)
        // Over the cost limit: the oldest go until it fits, and the newcomer always stays.
        XCTAssertEqual(Set(cache.insert(5, for: "e", cost: 85)), ["c", "a"])
        XCTAssertEqual(cache.totalCost, 95)
        XCTAssertEqual(cache.insert(6, for: "f", cost: 500), ["d", "e"]); XCTAssertEqual(cache.count, 1)
        cache.insert(7, for: "f", cost: 1); XCTAssertEqual(cache.totalCost, 1)
    }

    /// The folder query seeks in the folder index, in the grid's order, rather than passing over the catalog.
    func testFolderQueryUsesTheFolderIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory)
        var filter = CatalogFilter(); filter.folder = "/Volumes/Card/DCIM/100MSDCF"
        let plan = try await store.database.read { db in
            let request = CatalogStore.query(filter).select(CatalogAsset.Columns.id).order(CatalogStore.ordering(filter)).limit(200)
            let statement = try request.makePreparedRequest(db, forSingleResult: false).statement
            return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + statement.sql, arguments: statement.arguments).map { $0["detail"] as String }.joined(separator: "\n")
        }
        XCTAssertTrue(plan.contains("USING INDEX asset_folder"), plan)
        XCTAssertFalse(plan.contains("TEMP B-TREE"), plan)
    }

    private final class Mark: @unchecked Sendable { var listed = Date() }
    /// `CEVICHE_FOLDER_BENCH=<folder of photos> make test FILTER=CatalogFolderTests/testFolderBrowsingSpeed` times a
    /// first visit, a revisit and the grid's query inside a catalog of 200,000 other photos.
    func testFolderBrowsingSpeed() async throws {
        guard let source = ProcessInfo.processInfo.environment["CEVICHE_FOLDER_BENCH"] else { throw XCTSkip("Set CEVICHE_FOLDER_BENCH to a folder of photos.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = URL(fileURLWithPath: source, isDirectory: true)
        func timed<T>(_ work: () async throws -> T) async rethrows -> (T, Double) {
            let start = Date(); let value = try await work(); return (value, Date().timeIntervalSince(start))
        }
        let (listing, listTime) = try await timed { try CatalogFolders.list(folder) }
        var lines = ["\(listing.photos.count) photos, \(listing.folders.count) folders: listed in \(Int(listTime * 1000)) ms"]
        for width in [1, CatalogFolders.defaultWidth] {
            let store = try CatalogStore(root: directory.appendingPathComponent("Catalog-\(width)"))
            let started = Date(), mark = Mark()
            let (first, firstTime) = try await timed { try await CatalogFolders.sync(folder, store: store, width: width, listed: { mark.listed = Date() }) }
            lines.append("first visit, \(width) at a time: \(first.added) listed after \(String(format: "%.2f", mark.listed.timeIntervalSince(started))) s, \(first.thumbnails) thumbnails and \(first.failed) failed by \(String(format: "%.2f", firstTime)) s (\(Int(firstTime * 1000 / Double(max(1, first.added)))) ms a photo)")
            guard width > 1 else { continue }
            let (again, againTime) = try await timed { try await CatalogFolders.sync(folder, store: store) }
            lines.append("revisit: \(again.added) added, \(again.removed) removed in \(Int(againTime * 1000)) ms")
            // The same folder among many others: rows that differ only in where their original is.
            try await store.database.write { db in
                try db.execute(sql: "CREATE TEMP TABLE filler AS SELECT * FROM asset LIMIT 1")
                // Generated columns (the extension, the pixel size) fill themselves in.
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_xinfo(asset)").filter { ($0["hidden"] as Int) == 0 }.map { $0["name"] as String }
                let values = columns.map { name -> String in
                    switch name {
                    case "id": return "'filler-' || i"
                    case "importPath", "origin": return "'file:///Volumes/Archive/' || (i / 500) || '/' || i || '.ARW'"
                    case "sourcePath": return "'/Volumes/Archive/' || (i / 500) || '/' || i || '.ARW'"
                    case "captureDay": return "date('2020-01-01', '+' || (i / 100) || ' days')"
                    default: return name
                    }
                }.joined(separator: ", ")
                try db.execute(sql: """
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
                    INSERT INTO asset (\(columns.joined(separator: ", "))) SELECT \(values) FROM filler, n
                    """)
            }
            var filter = CatalogFilter(); filter.folder = CatalogFolders.path(folder)
            _ = try await store.assets(filter: filter, limit: 200)
            let (page, pageTime) = try await timed { try await store.assets(filter: filter, limit: 200) }
            let (count, countTime) = try await timed { try await store.count(filter: filter) }
            let (records, recordsTime) = try await timed { try await store.folderRecords(filter.folder!) }
            lines.append("in a catalog of 200,000: page of \(page.count) in \(String(format: "%.1f", pageTime * 1000)) ms, count \(count) in \(String(format: "%.1f", countTime * 1000)) ms, sync's lookup of \(records.count) in \(String(format: "%.1f", recordsTime * 1000)) ms")
        }
        print("FOLDER BENCH\n" + lines.joined(separator: "\n"))
    }

    /// Whether this machine knows `.cevichecatalog` as a package; only an installed Ceviche declares the type.
    private static let catalogIsPackage: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cevichecatalog")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }()
}
