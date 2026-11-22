import XCTest
import CevicheCore
@testable import CevicheMac

final class LaunchOptionsTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/work")
    /// A fake file system: `/work` and `/work/Shoot` are folders, `/work/a.ARW` a file, `/work/Old.cevichecatalog` a catalog.
    private func status(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        switch url.path {
        case "/work", "/work/Shoot", "/work/Old.cevichecatalog": (true, true)
        case "/work/a.ARW", "/work/Old.cevichecatalog/catalog.sqlite": (true, false)
        default: (false, false)
        }
    }
    private func parse(_ arguments: [String]) throws -> LaunchOptions.Outcome {
        try LaunchOptions.parse(arguments, currentDirectory: cwd, fileExists: status)
    }
    private func message(_ arguments: [String]) -> String? {
        do { _ = try parse(arguments); return nil } catch { return (error as? LaunchOptions.UsageError)?.description }
    }

    func testNewCatalogWithImportsDefaultsToReference() throws {
        XCTAssertEqual(try parse(["--new-catalog", "Trails", "Shoot", "/work/a.ARW"]),
                       .run(LaunchOptions(catalog: URL(fileURLWithPath: "/work/Trails.cevichecatalog"), create: true,
                                          imports: [URL(fileURLWithPath: "/work/Shoot"), URL(fileURLWithPath: "/work/a.ARW")], mode: .reference)))
    }
    func testExistingCatalogWithCopyAndAppKitDefaults() throws {
        let outcome = try parse(["-NSDocumentRevisionsDebugMode", "YES", "--catalog", "/work/Old.cevichecatalog", "--copy", "-psn_0_123", "--", "a.ARW"])
        XCTAssertEqual(outcome, .run(LaunchOptions(catalog: URL(fileURLWithPath: "/work/Old.cevichecatalog"), create: false,
                                                   imports: [URL(fileURLWithPath: "/work/a.ARW")], mode: .copy)))
    }
    func testQuitWhenDone() throws {
        XCTAssertEqual(try parse(["--catalog", "Old.cevichecatalog", "--quit-when-done"]),
                       .run(LaunchOptions(catalog: URL(fileURLWithPath: "/work/Old.cevichecatalog"), create: false, quitWhenDone: true)))
        XCTAssertEqual(message(["--quit-when-done", "a.ARW"]), "--quit-when-done needs --new-catalog or --catalog.")
    }
    func testWithoutCatalogOptionsAPhotoKeepsOpeningInDetail() throws {
        XCTAssertEqual(try parse([]), LaunchOptions.Outcome.none)
        XCTAssertEqual(try parse(["/work/a.ARW", "-ApplePersistenceIgnoreState", "YES"]), LaunchOptions.Outcome.none)
        XCTAssertEqual(try parse(["--help"]), .help)
        XCTAssertEqual(try parse(["-h"]), .help)
    }
    func testInvalidInputIsRejected() {
        XCTAssertEqual(message(["--new-catalog"]), "--new-catalog needs a path.")
        XCTAssertEqual(message(["--catalog", "--copy"]), "--catalog needs a path.")
        XCTAssertEqual(message(["--new-catalog", "Old"]), "/work/Old.cevichecatalog already exists.")
        XCTAssertEqual(message(["--new-catalog", "/nowhere/X.cevichecatalog"]), "Folder /nowhere does not exist.")
        XCTAssertEqual(message(["--catalog", "Shoot"]), "/work/Shoot is not a Ceviche catalog.")
        XCTAssertEqual(message(["--new-catalog", "A", "--catalog", "Old.cevichecatalog"]), "Give one of --new-catalog or --catalog, once.")
        XCTAssertEqual(message(["--new-catalog", "A", "--copy", "--reference"]), "Give one of --copy or --reference.")
        XCTAssertEqual(message(["--copy", "a.ARW"]), "--copy and --reference need --new-catalog or --catalog.")
        XCTAssertEqual(message(["--new-catalog", "A", "missing.ARW"]), "/work/missing.ARW does not exist.")
        XCTAssertEqual(message(["--import", "a.ARW"]), "Unknown option --import.")
    }

    @MainActor func testStartCreatesTheCatalogInPlaceOfTheLastOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); LaunchOptions.current = nil }
        let suite = UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "catalogClosed")
        guard case .run(let options) = try LaunchOptions.parse(["--new-catalog", "Trails"], currentDirectory: directory) else { return XCTFail() }
        LaunchOptions.current = options
        let model = CatalogModel(preferences: preferences)
        await model.start()
        XCTAssertEqual(model.root?.standardizedFileURL.path, directory.appendingPathComponent("Trails.cevichecatalog").standardizedFileURL.path)
        XCTAssertEqual(model.manifest?.name, "Trails")
        XCTAssertTrue(CatalogModel.catalogExists(at: directory.appendingPathComponent("Trails.cevichecatalog")))
        XCTAssertNil(LaunchOptions.current)
    }
}
