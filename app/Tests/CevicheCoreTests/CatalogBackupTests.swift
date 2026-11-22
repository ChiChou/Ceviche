import XCTest
@testable import CevicheCore

final class CatalogBackupTests: XCTestCase {
    func testBackupWithOriginalsCopiesCatalogAndReferencedFiles() async throws {
        let (directory, original) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let referencedFile = directory.appendingPathComponent("Elsewhere/referenced.jpg")
        try FileManager.default.createDirectory(at: referencedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: referencedFile)
        let prepared = try CatalogImporter.prepare(referencedFile)
        let referenced = try await store.insert(prepared.0, thumbnail: prepared.1)
        try Data("sidecar".utf8).write(to: referencedFile.deletingPathExtension().appendingPathExtension("xmp"))
        let copied = try CatalogImporter.prepare(original, options: .init(mode: .copy, catalogRoot: store.root))
        let owned = try await store.insert(copied.0, thumbnail: copied.1)
        let gone = directory.appendingPathComponent("gone.jpg"); try FileManager.default.copyItem(at: original, to: gone)
        let offlinePrepared = try CatalogImporter.prepare(gone)
        _ = try await store.insert(offlinePrepared.0, thumbnail: offlinePrepared.1)
        try FileManager.default.removeItem(at: gone)

        let destination = directory.appendingPathComponent("Backup.cevichecatalog")
        let result = try await store.backupWithOriginals(to: destination)
        XCTAssertEqual(result.originals, 2); XCTAssertEqual(result.missing, ["gone.jpg"])

        let backup = try CatalogStore(root: destination)
        let ownedCopy = try await backup.asset(owned.id)
        XCTAssertEqual(ownedCopy.importPath, owned.importPath, "A catalog copy keeps its place")
        let referencedCopy = try await backup.asset(referenced.id)
        guard case .catalog(let relative) = referencedCopy.locator else { return XCTFail("Not repointed: \(referencedCopy.origin)") }
        XCTAssertTrue(referencedCopy.isCopy); XCTAssertNil(referencedCopy.bookmark)
        XCTAssertNotEqual(relative, String(owned.locator.string.dropFirst("catalog:///".count)), "Copies keep distinct names")
        for asset in [ownedCopy, referencedCopy] {
            let url = CatalogImporter.sourceURL(for: asset, root: destination)
            XCTAssertTrue(url.path.hasPrefix(destination.path), url.path)
            XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: original))
        }
        let sidecar = CatalogImporter.sourceURL(for: referencedCopy, root: destination).deletingPathExtension().appendingPathExtension("xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "The sidecar travels with its original")
        let source = try await store.asset(referenced.id)
        XCTAssertEqual(source.origin, referenced.origin, "The open catalog is untouched")
    }
}
