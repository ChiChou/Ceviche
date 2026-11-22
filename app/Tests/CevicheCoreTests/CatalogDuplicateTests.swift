import XCTest
import Darwin
@testable import CevicheCore

final class CatalogDuplicateTests: XCTestCase {
    /// The APFS clone ID of a file's data: pure clones share it.
    private func cloneID(_ url: URL) throws -> UInt64 {
        var request = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS),
                               volattr: 0, dirattr: 0, fileattr: 0, forkattr: attrgroup_t(ATTR_CMNEXT_CLONEID))
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = url.withUnsafeFileSystemRepresentation { path in
            getattrlist(path!, &request, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Length, the returned attribute set, then the clone ID.
        let returned = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self) }
        guard returned & UInt32(ATTR_CMNEXT_CLONEID) != 0 else { throw XCTSkip("The file system reports no clone IDs") }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: UInt64.self) }
    }

    private func edited(_ store: CatalogStore, _ url: URL, options: CatalogImporter.ImportOptions = .init()) async throws -> CatalogAsset {
        let (prepared, thumbnail) = try CatalogImporter.prepare(url, options: options)
        let asset = try await store.insert(prepared, thumbnail: thumbnail)
        var metadata = asset.metadata; metadata.rating = 4; metadata.title = "Lake"; metadata.keywords = "water, dusk"
        try await store.updateMetadata(metadata, assetID: asset.id)
        var settings = Adjustments(); settings.exposure = 1.2; settings.contrast = 15
        _ = try await store.saveEdits(settings, assetID: asset.id, baseline: Adjustments())
        return try await store.asset(asset.id)
    }

    func testDuplicateClonesTheOriginalBesideItWithItsEditsAndMetadata() async throws {
        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let source = try await edited(store, url)

        let (copy, locator) = try CatalogImporter.duplicateOriginal(of: source, at: url, originalsRoot: store.originalsRoot)
        XCTAssertEqual(copy, directory.appendingPathComponent("photo-copy.jpg"))
        XCTAssertNil(locator)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: url))
        let original = try cloneID(url), cloned = try cloneID(copy)
        XCTAssertNotEqual(original, 0)
        XCTAssertEqual(original, cloned, "the copy is an APFS clone sharing the original's data")
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int,
                          try FileManager.default.attributesOfItem(atPath: copy.path)[.systemFileNumber] as? Int)

        let duplicate = try await store.duplicate(source, as: copy, locator: locator)
        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(duplicate.filename, "photo-copy.jpg")
        XCTAssertEqual(URL(fileURLWithPath: duplicate.sourcePath).standardizedFileURL, copy.standardizedFileURL)
        XCTAssertEqual(duplicate.metadata, source.metadata)
        XCTAssertEqual(duplicate.rating, 4)
        let edits = try await store.savedAdjustments(of: duplicate)
        XCTAssertEqual(edits?.exposure, 1.2)
        XCTAssertEqual(edits?.contrast, 15)
        let thumbnail = try await store.previews.data(assetID: duplicate.id)
        XCTAssertNotNil(thumbnail)
        let all = try await store.assets().map(\.id)
        XCTAssertEqual(Set(all), [source.id, duplicate.id])
        // Editing the copy leaves the original's development alone.
        var changed = try XCTUnwrap(edits); changed.exposure = -1
        _ = try await store.saveEdits(changed, assetID: duplicate.id)
        let sourceEdits = try await store.savedAdjustments(of: store.asset(source.id))
        XCTAssertEqual(sourceEdits?.exposure, 1.2)

        // Another duplicate never overwrites the first copy.
        let (second, _) = try CatalogImporter.duplicateOriginal(of: source, at: url, originalsRoot: store.originalsRoot)
        XCTAssertEqual(second.lastPathComponent, "photo-copy-2.jpg")
    }

    func testDuplicateOfACatalogOriginalStaysInTheCatalog() async throws {
        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let source = try await edited(store, url, options: .init(mode: .copy, catalogRoot: store.originalsRoot))
        guard case .catalog(let relative) = source.locator else { return XCTFail("expected a catalog original, got \(source.locator)") }
        XCTAssertEqual(relative, "Originals/2025-10/photo.jpg")
        let inside = CatalogImporter.sourceURL(for: source, root: store.root)

        let (copy, locator) = try CatalogImporter.duplicateOriginal(of: source, at: inside, originalsRoot: store.originalsRoot)
        XCTAssertEqual(locator, .catalog(relativePath: "Originals/2025-10/photo-copy.jpg"))
        XCTAssertEqual(try cloneID(copy), try cloneID(inside))
        let duplicate = try await store.duplicate(source, as: copy, locator: locator)
        XCTAssertEqual(duplicate.locator, locator)
        XCTAssertTrue(duplicate.isCopy)
        XCTAssertEqual(CatalogImporter.sourceURL(for: duplicate, root: store.root).standardizedFileURL, copy.standardizedFileURL)
        XCTAssertEqual(duplicate.metadata, source.metadata)
        let edits = try await store.savedAdjustments(of: duplicate)
        XCTAssertEqual(edits?.exposure, 1.2)
    }
}
