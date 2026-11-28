import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

final class AssetSystemTests: XCTestCase {
    func fixture(count: Int = 1) throws -> (URL, [URL]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        var urls: [URL] = []
        for index in 0..<count {
            let url = directory.appendingPathComponent("DCIM/100MSDCF/DSC0\(index).jpg")
            let context = CGContext(data: nil, width: 64 + index, height: 48, bitsPerComponent: 8, bytesPerRow: (64 + index) * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64 + index, height: 48))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:10:2\(index) 12:13:1\(index)"]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            urls.append(url)
        }
        return (directory, urls)
    }
    func testLocatorStringsRoundTrip() {
        let cases: [AssetLocator] = [
            .file(path: "/Users/me/Pictures/Été 2025/DSC001.ARW"),
            .catalog(relativePath: "Originals/2025-10/DSC001.ARW"),
            .volume(uuid: "1A2B3C4D-0000-1111-2222-333344445555", relativePath: "DCIM/100MSDCF/DSC001.ARW")
        ]
        for locator in cases {
            XCTAssertEqual(AssetLocator(string: locator.string), locator, locator.string)
            XCTAssertEqual(locator.filename, "DSC001.ARW")
        }
        XCTAssertNil(AssetLocator(string: "ftp://x/y"))
        XCTAssertNil(AssetLocator(string: "smb://nas.local/Photos/A.ARW"))
        // Shares recorded by older builds read as the path Finder mounts them at.
        XCTAssertEqual(AssetLocator(stored: "smb://nas.local/Photos/2025/A.ARW"), .file(path: "/Volumes/Photos/2025/A.ARW"))
        XCTAssertNil(AssetLocator(string: "gdrive:///me@example.com/abc"))
    }
    func testLocalFilesAreDescribedAsFilesAndMissingOnesAreOffline() throws {
        let (directory, urls) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let locator = AssetLocator.describing(urls[0])
        if case .volume = locator {} else { XCTAssertEqual(locator.scheme, .file) }
        XCTAssertEqual(AssetResolver.availability(of: locator, catalog: nil).localURL?.standardizedFileURL, urls[0].standardizedFileURL)
        XCTAssertTrue(AssetResolver.availability(of: .file(path: directory.appendingPathComponent("gone.jpg").path), catalog: nil).isOffline)
        XCTAssertTrue(AssetResolver.availability(of: .catalog(relativePath: "Originals/x.jpg"), catalog: nil).isOffline)
    }
    /// A row another build or a damaged catalog left unreadable is a photo without its original, not a crash.
    func testUnreadableStoredRowsStandInInsteadOfCrashing() async throws {
        let (directory, urls) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(urls[0])
        var asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        asset.infoData = Data("not json".utf8); asset.origin = "no scheme here"
        XCTAssertEqual(asset.info.filename, asset.filename)
        XCTAssertGreaterThan(asset.info.width, 0)
        _ = asset.locator; _ = asset.availability(catalog: store.root)
        _ = AssetLocator(stored: "")
    }
    /// Import decides once whether a photo opens in HDR; the renderer takes the catalog's answer over the file.
    func testImportRecordsWhetherAPhotoIsHDR() async throws {
        let (directory, urls) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let bright = directory.appendingPathComponent("bright.tif")
        let width = 16, height = 8
        let values = [Float](repeating: 0, count: width * height * 4).enumerated().map { $0.offset % 4 == 3 ? Float(1) : 4 } // four times white, opaque
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                            space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(bright as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let sdr = try await store.insert(try CatalogImporter.prepare(urls[0]).0, thumbnail: nil)
        let hdr = try await store.insert(try CatalogImporter.prepare(bright).0, thumbnail: nil)
        let stored = try await (store.asset(sdr.id).hdr, store.asset(hdr.id).hdr)
        XCTAssertEqual(stored.0, false)
        XCTAssertEqual(stored.1, true)
        let info = try await store.asset(hdr.id).info
        XCTAssertEqual(info.defaultsFromImport, true)
        XCTAssertTrue(info.defaults.hdr.enabled, "The recorded defaults open it in HDR")
        XCTAssertEqual(CatalogImporter.developmentDefaults(for: directory.appendingPathComponent("gone.tif"), info: info), info.defaults,
                       "Recorded defaults are used without the file")
        XCTAssertTrue(try RawRenderer(sourceURL: bright).info.defaults.hdr.enabled, "Without the catalog's answer the file is looked at")
        XCTAssertFalse(try RawRenderer(sourceURL: bright, hdr: false).info.defaults.hdr.enabled)
    }
    func testReferenceImportRecordsOriginAndFingerprint() async throws {
        let (directory, urls) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        XCTAssertEqual(store.manifest.kind, .file)
        let prepared = try CatalogImporter.prepare(urls[0])
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertEqual(asset.locator.filename, "DSC00.jpg")
        XCTAssertEqual(asset.captureTime, "2025-10-20T12:13:10")
        XCTAssertEqual(asset.fileSize, Int64(try Data(contentsOf: urls[0]).count))
        XCTAssertEqual(asset.availability(catalog: store.root).localURL?.standardizedFileURL, urls[0].standardizedFileURL)
        let presence = try await store.presence()
        XCTAssertTrue(presence.contains(try CatalogImporter.fingerprint(urls[0]), locator: nil, path: nil))
        var renamed = try CatalogImporter.fingerprint(urls[0])
        renamed = ImportFingerprint(name: "other.jpg", size: renamed.size, captureTime: renamed.captureTime)
        XCTAssertFalse(presence.contains(renamed))
        XCTAssertTrue(presence.contains(ImportFingerprint(name: "dsc00.JPG", size: nil, captureTime: "2025-10-20T12:13:10")), "Name and capture time are enough")
        XCTAssertTrue(presence.contains(ImportFingerprint(name: "DSC00.jpg", size: asset.fileSize, captureTime: nil)), "Name and size are enough when the time is unknown")
    }
    func testCopyImportPlacesOriginalInsideCatalogAndResolvesAfterMove() async throws {
        let (directory, urls) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Catalog")
        let store = try CatalogStore(root: root, manifest: CatalogManifest(name: "Trip", kind: .local))
        XCTAssertEqual(try CatalogManifest.load(root: root)?.name, "Trip")
        let sidecar = urls[0].deletingPathExtension().appendingPathExtension("xmp")
        try "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description rdf:about=''/></rdf:RDF></x:xmpmeta>".write(to: sidecar, atomically: true, encoding: .utf8)
        let options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: root)
        let prepared = try CatalogImporter.prepare(urls[0], options: options)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        XCTAssertEqual(asset.locator, .catalog(relativePath: "Originals/2025-10/DSC00.jpg"))
        XCTAssertEqual(asset.importPath, "catalog:///Originals/2025-10/DSC00.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Originals/2025-10/DSC00.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Originals/2025-10/DSC00.xmp").path), "The sidecar travels with the copy")
        XCTAssertEqual(try Data(contentsOf: urls[0]), try Data(contentsOf: root.appendingPathComponent("Originals/2025-10/DSC00.jpg")))
        // A second copy of the same file never overwrites the first.
        let again = try CatalogImporter.prepare(urls[0], options: options)
        XCTAssertEqual(again.0.locator, .catalog(relativePath: "Originals/2025-10/DSC00 2.jpg"))
        // The catalog folder can move; the copy is found relative to it.
        let moved = directory.appendingPathComponent("Moved.cevichecatalog")
        try FileManager.default.moveItem(at: root, to: moved)
        let reopened = try CatalogStore(root: moved)
        let current = try await reopened.asset(asset.id)
        XCTAssertEqual(CatalogImporter.sourceURL(for: current, root: moved).path, moved.appendingPathComponent("Originals/2025-10/DSC00.jpg").path)
        XCTAssertNotNil(current.availability(catalog: moved).localURL)
        XCTAssertTrue(current.availability(catalog: nil).isOffline || current.availability(catalog: nil).localURL != nil)
    }
    func testLibrarySortsByEachKeyInBothDirections() async throws {
        let (directory, urls) = try fixture(count: 3); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        for url in urls.reversed() { let prepared = try CatalogImporter.prepare(url); _ = try await store.insert(prepared.0, thumbnail: nil) }
        var filter = CatalogFilter()
        var names = try await store.assets(filter: filter).map(\.filename)
        XCTAssertEqual(names, ["DSC02.jpg", "DSC01.jpg", "DSC00.jpg"], "Newest capture first by default")
        filter.ascending = true
        names = try await store.assets(filter: filter).map(\.filename); XCTAssertEqual(names, ["DSC00.jpg", "DSC01.jpg", "DSC02.jpg"])
        filter.sort = .filename; filter.ascending = true
        names = try await store.assets(filter: filter).map(\.filename); XCTAssertEqual(names, ["DSC00.jpg", "DSC01.jpg", "DSC02.jpg"])
        filter.sort = .importDate; filter.ascending = false
        names = try await store.assets(filter: filter).map(\.filename); XCTAssertEqual(names, ["DSC00.jpg", "DSC01.jpg", "DSC02.jpg"], "Imported last comes first")
        let rated = try await store.assets(filter: CatalogFilter())[1]
        try await store.updateQuickMetadata(assetIDs: [rated.id], rating: 5)
        filter.sort = .rating; filter.ascending = false
        names = try await store.assets(filter: filter).map(\.filename); XCTAssertEqual(names.first, "DSC01.jpg")
        var edits = Adjustments(); edits.exposure = 0.5
        try await store.saveEdits(edits, assetID: rated.id)
        filter.sort = .edited
        names = try await store.assets(filter: filter).map(\.filename); XCTAssertEqual(names.first, "DSC01.jpg", "The last edited photo leads")
        XCTAssertEqual(CatalogSort.filename.defaultAscending, true); XCTAssertEqual(CatalogSort.rating.descendingTitle, "Highest First")
    }
    func testScannerMarksPhotosAlreadyInCatalog() async throws {
        let (directory, urls) = try fixture(count: 3); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(urls[1])
        _ = try await store.insert(prepared.0, thumbnail: prepared.1)
        // The same photo copied from the card to a laptop earlier: different path, same name and capture time.
        let elsewhere = directory.appendingPathComponent("Laptop"); try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: urls[2], to: elsewhere.appendingPathComponent("DSC02.jpg"))
        let imported = try CatalogImporter.prepare(elsewhere.appendingPathComponent("DSC02.jpg"))
        _ = try await store.insert(imported.0, thumbnail: imported.1)
        var found: [ImportCandidate] = []
        for try await candidate in ImportScanner.scan([directory.appendingPathComponent("DCIM")], presence: try await store.presence()) { found.append(candidate) }
        XCTAssertEqual(Set(found.map(\.filename)), ["DSC00.jpg", "DSC01.jpg", "DSC02.jpg"])
        XCTAssertEqual(Set(found.filter(\.present).map(\.filename)), ["DSC01.jpg", "DSC02.jpg"])
        XCTAssertEqual(found.first?.folder, "100MSDCF")
        let groups = ImportScanner.groups(found)
        XCTAssertEqual(groups.map(\.title), ["2025-10-22", "2025-10-21", "2025-10-20"], "One folder groups by capture day, newest first")
    }
    func testReplaceOriginalKeepsEditsAndRejectsPhotosAlreadyInCatalog() async throws {
        let (directory, urls) = try fixture(count: 2); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(urls[0])
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        var edits = Adjustments(); edits.exposure = 0.8
        try await store.saveEdits(edits, assetID: asset.id, baseline: Adjustments())
        try FileManager.default.removeItem(at: urls[0])
        let reloaded = try await store.asset(asset.id)
        XCTAssertTrue(reloaded.availability(catalog: store.root).isOffline)
        do { try await store.relink(urls[1], assetID: asset.id); XCTFail("Locate must verify the contents") } catch {}
        try await store.replaceOriginal(urls[1], assetID: asset.id)
        let replaced = try await store.asset(asset.id)
        XCTAssertEqual(replaced.filename, "DSC01.jpg")
        let replacedEdits = try await store.savedAdjustments(of: replaced); XCTAssertEqual(replacedEdits?.exposure, 0.8)
        XCTAssertNotEqual(replaced.renderKey, reloaded.renderKey, "Thumbnails re-render for the new file")
        XCTAssertFalse(replaced.availability(catalog: store.root).isOffline)
        let history = try await store.history(assetID: asset.id); XCTAssertTrue(history.contains { $0.summary.hasPrefix("Replaced original") })
        let other = try CatalogImporter.prepare(urls[1])
        let same = try await store.insert(other.0, thumbnail: nil)
        XCTAssertEqual(same.id, asset.id, "The replacement path is now this photo's import key")
    }
    func testOnlyOriginalsGoneFromReachableStorageAreMissing() async throws {
        let (directory, urls) = try fixture(count: 2); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let kept = try CatalogImporter.prepare(urls[0]), gone = try CatalogImporter.prepare(urls[1])
        let present = try await store.insert(kept.0, thumbnail: kept.1)
        let removed = try await store.insert(gone.0, thumbnail: gone.1)
        try FileManager.default.removeItem(at: urls[1])
        XCTAssertFalse(present.originalIsMissing(catalog: store.root))
        let reloaded = try await store.asset(removed.id)
        XCTAssertTrue(reloaded.originalIsMissing(catalog: store.root))
        var unmounted = reloaded; unmounted.origin = AssetLocator.file(path: "/Volumes/NoSuchDrive-\(UUID().uuidString)/A.ARW").string
        XCTAssertFalse(unmounted.originalIsMissing(catalog: store.root), "A drive that is not mounted is offline, not missing")
        var volume = reloaded; volume.origin = AssetLocator.volume(uuid: UUID().uuidString, relativePath: "A.ARW").string
        XCTAssertFalse(volume.originalIsMissing(catalog: store.root))
        var share = reloaded; share.origin = "smb://nas.invalid/photos-\(UUID().uuidString)/A.ARW"
        XCTAssertFalse(share.originalIsMissing(catalog: store.root), "A share recorded by an older build that is not mounted is offline")
        XCTAssertFalse(share.originalOnThisMac)
    }
}
