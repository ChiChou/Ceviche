import XCTest
import CryptoKit
import GRDB
@testable import CevicheCore

/// `scripts/recover_catalog.py`: edits and metadata out of a catalog the app won't open, as XMP this build imports.
final class CatalogRecoveryTests: XCTestCase {
    private let helper = CloudSyncTests()
    private static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/recover_catalog.py")

    private struct Entry { let status: String, xmp: String, beside: String, notes: String }
    /// Runs the script and reads recovery.csv back, by photo ID.
    private func recover(_ catalog: URL, to output: URL, _ options: [String] = []) throws -> [String: Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", Self.script.path, catalog.path, output.path] + options
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        var entries: [String: Entry] = [:]
        // The fields written here hold no commas or quotes, except notes, last on the line.
        for line in try String(contentsOf: output.appendingPathComponent("recovery.csv"), encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            entries[fields[0]] = Entry(status: fields[2], xmp: fields[4], beside: fields[5], notes: fields[6])
        }
        return entries
    }
    private func imported(_ path: String) throws -> XMPImport {
        try XMPCodec.apply(XMPPacket(url: URL(fileURLWithPath: path)), to: Adjustments())
    }

    /// A local catalog with an edited, rated photo (a mask among its edits), a photo only rated, and an untouched one.
    private func catalog(_ directory: URL, _ url: URL) async throws -> (CatalogStore, edited: String, rated: String, untouched: String) {
        let store = try CatalogStore(root: directory.appendingPathComponent("Cat.cevichecatalog"), manifest: CatalogManifest(name: "Cat", kind: .file))
        func add(_ name: String) async throws -> String {
            let file = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: url, to: file) }
            let prepared = try CatalogImporter.prepare(file)
            return try await store.insert(prepared.0, thumbnail: prepared.1).id
        }
        let edited = try await add("photo.jpg"), rated = try await add("rated.jpg"), untouched = try await add("untouched.jpg")
        var edits = Adjustments(); edits.exposure = 1.2; edits.clarity = 18
        var mask = PhotoMask(kind: .subject); mask.raster = Data((0..<6_000).map { UInt8($0 % 241) }); edits.masks = [mask]
        try await store.saveEdits(edits, assetID: edited, baseline: Adjustments())
        _ = try await store.updateQuickMetadata(assetIDs: [edited], rating: 4, label: .green)
        var metadata = try await store.asset(edited).metadata; metadata.keywords = "dusk, harbour"
        try await store.updateMetadata(metadata, assetID: edited)
        _ = try await store.updateQuickMetadata(assetIDs: [rated], rating: 2, review: .accepted, label: .blue)
        var tagged = try await store.asset(rated).metadata; tagged.keywords = "pier"; tagged.title = "Low tide & fog"
        try await store.updateMetadata(tagged, assetID: rated)
        return (store, edited, rated, untouched)
    }
    private func digest(_ folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("catalog.") {
            digests[name] = SHA256.hash(data: try Data(contentsOf: folder.appendingPathComponent(name))).description
        }
        return digests
    }

    func testEditsAndMetadataComeBackAsXMPAndTheCatalogIsNotWritten() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, edited, rated, untouched) = try await catalog(directory, url)
        let saved = try await store.savedAdjustments(of: store.asset(edited))
        let before = try digest(store.root)
        let output = directory.appendingPathComponent("Recovered")
        let entries = try recover(store.root, to: output)
        XCTAssertEqual(try digest(store.root), before, "The catalog is only read")
        XCTAssertEqual(entries[edited]?.status, "edits"); XCTAssertEqual(entries[untouched]?.status, "nothing")
        let recovered = try imported(XCTUnwrap(entries[edited]?.xmp))
        XCTAssertEqual(recovered.adjustments, saved, "The whole development, the mask raster inline")
        XCTAssertEqual(recovered.metadata.rating, 4); XCTAssertEqual(recovered.metadata.label, .green)
        XCTAssertEqual(recovered.metadata.keywordList, ["dusk", "harbour"])
        // Laid out as the originals are, so the files can go back beside them.
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(entries[edited]?.xmp)).standardizedFileURL.path,
                       URL(fileURLWithPath: output.path + "/Files" + directory.path + "/photo.xmp").standardizedFileURL.path)
        // Metadata alone goes in the standard fields, leaving the photo's own development defaults alone.
        XCTAssertEqual(entries[rated]?.status, "metadata")
        let metadata = try imported(XCTUnwrap(entries[rated]?.xmp))
        XCTAssertEqual(metadata.adjustments, Adjustments())
        XCTAssertEqual(metadata.metadata.rating, 2); XCTAssertEqual(metadata.metadata.review, .accepted)
        XCTAssertEqual(metadata.metadata.label, .blue); XCTAssertEqual(metadata.metadata.keywords, "pier")
        XCTAssertEqual(metadata.metadata.title, "Low tide & fog")
    }

    func testBesideOriginalsWritesTheStandardSidecarOnlyWhereThereIsNone() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, edited, _, _) = try await catalog(directory, url)
        let entries = try recover(store.root, to: directory.appendingPathComponent("First"), ["--beside-originals"])
        let sidecar = directory.appendingPathComponent("photo.xmp")
        XCTAssertEqual(entries[edited]?.beside, sidecar.path)
        XCTAssertEqual(try imported(sidecar.path).adjustments.exposure, 1.2)
        // A sidecar already there, Ceviche's or another editor's, is never replaced.
        try Data("keep".utf8).write(to: sidecar)
        let again = try recover(store.root, to: directory.appendingPathComponent("Second"), ["--beside-originals"])
        XCTAssertEqual(again[edited]?.beside, "")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "keep")
    }

    /// `sqlite3 .recover` drops a column of a table with generated columns; declared plainly first, the photo table
    /// comes back whole and the edits with it.
    func testSalvagingKeepsEveryPhotoAndItsEdits() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, edited, rated, untouched) = try await catalog(directory, url)
        let saved = try await store.savedAdjustments(of: store.asset(edited))
        let entries = try recover(store.root, to: directory.appendingPathComponent("Recovered"), ["--salvage"])
        XCTAssertEqual(Set(entries.keys), [edited, rated, untouched])
        XCTAssertEqual(try imported(XCTUnwrap(entries[edited]?.xmp)).adjustments, saved)
        XCTAssertEqual(entries[rated]?.status, "metadata")
    }

    /// A catalog a newer build upgraded: a column and a table this build doesn't know, and a setting it can't read.
    func testACatalogFromANewerBuildStillGivesUpItsEdits() async throws {
        let (directory, url) = try helper.fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (store, edited, _, _) = try await catalog(directory, url)
        try await DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path).write { db in
            try db.execute(sql: "ALTER TABLE asset ADD COLUMN futureColumn TEXT")
            try db.execute(sql: "CREATE TABLE futureTable (id TEXT)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('catalog-2099-01-01-future')")
            let stored = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT adjustmentsData FROM assetDevelopment WHERE assetID = ?", arguments: [edited]))
            var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any]); tree["futureSetting"] = ["strength": 3]
            try db.execute(sql: "UPDATE assetDevelopment SET adjustmentsData = ? WHERE assetID = ?",
                           arguments: [JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys]), edited])
        }
        let entries = try recover(store.root, to: directory.appendingPathComponent("Recovered"))
        XCTAssertEqual(entries[edited]?.status, "edits")
        XCTAssertEqual(try imported(XCTUnwrap(entries[edited]?.xmp)).adjustments.exposure, 1.2)
    }

    /// Recovers a real catalog into a scratch folder and checks every recovered XMP holds the catalog's development:
    /// `CEVICHE_RECOVER_CATALOG=/path/to/Library.cevichecatalog`. The catalog is only read.
    func testRealCatalogRecoversEveryEdit() async throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_RECOVER_CATALOG"] else { throw XCTSkip("Set CEVICHE_RECOVER_CATALOG") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("recover-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let entries = try recover(URL(fileURLWithPath: path), to: output)
        let store = try CatalogStore(root: URL(fileURLWithPath: path), existingOnly: true, readOnly: true)
        var compared = 0
        for (id, entry) in entries where entry.status == "edits" {
            let saved = try await store.savedAdjustments(of: store.asset(id))
            XCTAssertEqual(try imported(entry.xmp).adjustments, saved, entry.xmp)
            compared += 1
        }
        XCTAssertFalse(entries.values.contains { $0.status == "failed" })
        print("compared \(compared) recovered developments")
    }
}
