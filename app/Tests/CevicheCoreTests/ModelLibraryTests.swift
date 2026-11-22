import XCTest
@testable import CevicheCore

/// The model library on a temporary directory: the pinned manifest, file identification, checksum verification,
/// archive extraction, installing from a compiled model and removal. A download that cannot reach GitHub points to From
/// File…; with CEVICHE_NETWORK_TESTS set, a real model is fetched from the pinned release.
final class ModelLibraryTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-models-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testPinnedManifestCoversEveryModelOrNothing() throws {
        let set = ModelSet.pinned
        XCTAssertFalse(set.repository.isEmpty)
        XCTAssertTrue(set.repository.contains("/"))
        if set.isPinned {
            for model in BundledModel.allCases {
                let asset = try XCTUnwrap(set.asset(model), "\(model) is missing from the pinned set")
                XCTAssertEqual(asset.sha256.count, 64); XCTAssertGreaterThan(asset.bytes, 0)
                XCTAssertTrue(asset.file.hasPrefix(model.rawValue + "."))
            }
            XCTAssertNotNil(set.apiURL); XCTAssertNotNil(set.releaseURL)
        } else {
            XCTAssertTrue(set.models.isEmpty)
            XCTAssertNil(set.apiURL)
        }
    }
    func testManifestRoundTrips() throws {
        let asset = ModelSet.Asset(file: "NAFNetSIDD32.aar", sha256: String(repeating: "a", count: 64), bytes: 10)
        let set = ModelSet(repository: "ChiChou/Ceviche", tag: "models-v3", models: ["NAFNetSIDD32": asset])
        let decoded = try JSONDecoder().decode(ModelSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded.asset(.denoise), asset)
        XCTAssertEqual(decoded.directURL(asset)?.absoluteString, "https://github.com/ChiChou/Ceviche/releases/download/models-v3/NAFNetSIDD32.aar")
        XCTAssertEqual(decoded.apiURL?.absoluteString, "https://api.github.com/repos/ChiChou/Ceviche/releases/tags/models-v3")
        XCTAssertEqual(decoded.variants(.denoise), [.fp16])
    }
    func testINT8CopiesAreListedBesideTheModels() throws {
        let fp16 = ModelSet.Asset(file: "NAFNetSIDD32.aar", sha256: String(repeating: "a", count: 64), bytes: 10)
        let int8 = ModelSet.Asset(file: "NAFNetSIDD32-INT8.aar", sha256: String(repeating: "b", count: 64), bytes: 5)
        let set = ModelSet(repository: "ChiChou/Ceviche", tag: "models-v3", models: ["NAFNetSIDD32": fp16, "BigLaMa": fp16], int8: ["NAFNetSIDD32": int8])
        let decoded = try JSONDecoder().decode(ModelSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded.variants(.denoise), [.fp16, .int8])
        XCTAssertEqual(decoded.variants(.inpaint), [.fp16], "a model without an INT8 copy offers no choice")
        XCTAssertEqual(decoded.asset(.denoise, .int8), int8)
        XCTAssertEqual(decoded.variant(.denoise, sha256: int8.sha256), .int8)
        XCTAssertEqual(decoded.variant(.denoise, sha256: fp16.sha256), .fp16)
        XCTAssertNil(decoded.variant(.denoise, sha256: nil))
        // A manifest from before the INT8 copies has no "int8" key.
        let old = Data(#"{"repository":"ChiChou/Ceviche","tag":"models-v1","models":{"NAFNetSIDD32":{"file":"NAFNetSIDD32.aar","sha256":"\#(fp16.sha256)","bytes":10}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ModelSet.self, from: old).variants(.denoise), [.fp16])
    }
    func testRecordsFromBeforeTheINT8CopiesAreFP16() throws {
        let old = Data(#"{"bytes":1,"installedAt":"2026-11-01T00:00:00Z","sha256":null,"source":"download","tag":"models-v1"}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(ModelLibrary.Installed.self, from: old).variant)
    }
    func testChecksumVerificationRejectsOtherBytes() throws {
        let file = directory.appendingPathComponent("blob")
        try Data("ceviche".utf8).write(to: file)
        let expected = "7ce3d0a0d2e6e1d1a6a5c2c4b3a13fbd2fc6c9ae97ad2fc7b12f7f08a2cc5b7a"
        let actual = try ModelInstaller.sha256(of: file)
        XCTAssertEqual(actual.count, 64)
        XCTAssertNoThrow(try ModelInstaller.verify(file, sha256: actual.uppercased()))
        XCTAssertThrowsError(try ModelInstaller.verify(file, sha256: expected)) { error in
            XCTAssertEqual(error as? ModelLibraryError, .checksum("blob"))
        }
    }
    /// An Apple Archive of `folder` under its own name, as `models/package-models.sh` makes them.
    private func archive(_ folder: URL, to file: URL, compression: String = "raw") throws {
        let aa = Process(); aa.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        aa.arguments = ["archive", "-a", compression, "-d", folder.deletingLastPathComponent().path, "-subdir", folder.lastPathComponent, "-o", file.path]
        try aa.run(); aa.waitUntilExit(); XCTAssertEqual(aa.terminationStatus, 0)
    }
    func testArchiveExtractionKeepsPackageDirectories() throws {
        // The release layout: <Name>/<Name>.mlpackage beside <Name>/LICENSE.
        let folder = directory.appendingPathComponent("NAFNetSIDD32", isDirectory: true)
        let package = folder.appendingPathComponent("NAFNetSIDD32.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data("m".utf8).write(to: package.appendingPathComponent("Data/weights.bin"))
        try Data("license".utf8).write(to: folder.appendingPathComponent("LICENSE"))
        for compression in ["raw", "lzfse"] {
            let file = directory.appendingPathComponent("NAFNetSIDD32-\(compression).aar")
            try archive(folder, to: file, compression: compression)
            let unpacked = try ModelInstaller.extract(file)
            defer { try? FileManager.default.removeItem(at: unpacked) }
            let found = try XCTUnwrap(ModelInstaller.modelFile(in: unpacked))
            XCTAssertEqual(found.lastPathComponent, "NAFNetSIDD32.mlpackage")
            XCTAssertEqual(try Data(contentsOf: found.appendingPathComponent("Data/weights.bin")), Data("m".utf8))
            XCTAssertEqual(try Data(contentsOf: found.deletingLastPathComponent().appendingPathComponent("LICENSE")), Data("license".utf8))
        }
        // Links are not unpacked: the archive is refused and nothing is left behind.
        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("escape").path, withDestinationPath: "/etc")
        let linkedFile = directory.appendingPathComponent("linked.aar")
        try archive(linked, to: linkedFile)
        XCTAssertThrowsError(try ModelInstaller.extract(linkedFile)) { error in
            guard case .extraction(let detail)? = error as? ModelLibraryError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("linked/escape"), detail)
        }
        // Not an archive at all.
        let text = directory.appendingPathComponent("text.aar")
        try Data("not an archive".utf8).write(to: text)
        XCTAssertThrowsError(try ModelInstaller.extract(text))
        // An archive that wrapped a folder, and one without any model.
        let wrapped = directory.appendingPathComponent("wrapped", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapped.appendingPathComponent("anything/renamed.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertEqual(ModelInstaller.modelFile(in: wrapped)?.lastPathComponent, "renamed.mlmodelc")
        XCTAssertNil(ModelInstaller.modelFile(in: directory.appendingPathComponent("wrapped/anything/renamed.mlmodelc")))
        XCTAssertThrowsError(try ModelInstaller.extract(directory.appendingPathComponent("missing.aar")))
    }
    @MainActor func testInstallFromCompiledModelAndRemove() async throws {
        // A real compiled model is needed because installing loads it; the sky model from CEVICHE_MODELS or the user's library.
        guard let original = BundledModel.sky.url else { throw XCTSkip("Supply compiled models with CEVICHE_MODELS") }
        // Under a name that says nothing: the row the user chose decides which model it is.
        let source = directory.appendingPathComponent("whatever.mlmodelc", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: source)
        let library = ModelLibrary(directory: directory.appendingPathComponent("Library"), set: ModelSet(repository: "ChiChou/Ceviche", tag: nil, models: [:]))
        XCTAssertEqual(library.status(.sky), .notInstalled)
        try await library.install(.sky, from: source)
        guard case .installed(let record) = library.status(.sky) else { return XCTFail("not installed") }
        XCTAssertEqual(record.source, .file); XCTAssertNil(record.sha256); XCTAssertGreaterThan(record.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.compiledURL(.sky).path))
        XCTAssertNil(library.matchesPin(.sky), "no pinned set, so nothing to compare with")
        // A fresh instance reads the record back.
        let again = ModelLibrary(directory: library.directory, set: library.set)
        guard case .installed(let reread) = again.status(.sky) else { return XCTFail("record not read back") }
        XCTAssertEqual(reread.source, record.source); XCTAssertEqual(reread.sha256, record.sha256); XCTAssertEqual(reread.bytes, record.bytes)
        XCTAssertEqual(reread.installedAt.timeIntervalSince1970, record.installedAt.timeIntervalSince1970, accuracy: 1, "the record is stored to the second")
        try library.remove(.sky)
        XCTAssertEqual(library.status(.sky), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.compiledURL(.sky).path))
    }
    @MainActor func testFilesThatAreNotModelsAreRefused() async throws {
        let library = ModelLibrary(directory: directory.appendingPathComponent("Library"), set: ModelSet(repository: "ChiChou/Ceviche", tag: nil, models: [:]))
        let photo = directory.appendingPathComponent("photo.jpg")
        try Data([0xff, 0xd8, 0xff]).write(to: photo)
        do { try await library.install(.denoise, from: photo); XCTFail("accepted") } catch {}
        XCTAssertEqual(library.status(.denoise) == .notInstalled, false, "the failure is shown on the row")
        if case .failed = library.status(.denoise) {} else { XCTFail("expected a failure status") }
        // An archive with no model inside, and a zip, which is not a release format.
        let folder = directory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let file = directory.appendingPathComponent("notes.aar")
        try archive(folder, to: file)
        do { try await library.install(.depth, from: file); XCTFail("accepted") }
        catch { XCTAssertEqual(error as? ModelLibraryError, .unexpectedContents("notes.aar")) }
        let zip = directory.appendingPathComponent("notes.zip")
        try Data("PK".utf8).write(to: zip)
        do { try await library.install(.depth, from: zip); XCTFail("accepted") }
        catch { XCTAssertEqual(error as? ModelLibraryError, .unexpectedContents("notes.zip")) }
        XCTAssertTrue(library.missing.isEmpty, "nothing is missing from a build that pins no set")
    }
    @MainActor func testHandPlacedModelCountsAsInstalledFromFile() throws {
        let library = ModelLibrary(directory: directory, set: ModelSet(repository: "ChiChou/Ceviche", tag: nil, models: [:]))
        try FileManager.default.createDirectory(at: library.compiledURL(.denoise), withIntermediateDirectories: true)
        library.rescan()
        guard case .installed(let record) = library.status(.denoise) else { return XCTFail("not seen") }
        XCTAssertEqual(record.source, .file)
        try library.remove(.denoise)
        XCTAssertEqual(library.status(.denoise), .notInstalled)
    }
    @MainActor func testBuildsWithoutDownloadsNeverFetch() {
        let library = ModelLibrary(directory: directory, set: .pinned)
        library.allowsDownloads = false
        library.download(.denoise)
        XCTAssertEqual(library.status(.denoise), .notInstalled, "A build without downloads only installs what the user puts there")
    }
    @MainActor func testModelUnpackedIntoTheFolderIsCompiledIn() async throws {
        // Something unpacked under a model's name that is not a model: the row says so and the files stay.
        let junk = directory.appendingPathComponent("NAFNetSIDD32.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: junk.appendingPathComponent("Manifest.json"))
        let library = ModelLibrary(directory: directory, set: ModelSet(repository: "ChiChou/Ceviche", tag: nil, models: [:]))
        for _ in 0..<50 where !({ if case .failed = library.status(.denoise) { return true }; return false }()) { try await Task.sleep(for: .milliseconds(100)) }
        if case .failed = library.status(.denoise) {} else { XCTFail("expected a failure, got \(library.status(.denoise))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: junk.path), "A failed copy is left for the user to see")
        library.rescan()
        if case .failed = library.status(.denoise) {} else { XCTFail("not retried in a loop") }
        // A real model, when one is at hand: the unpacked copy is compiled in and removed.
        guard let source = ProcessInfo.processInfo.environment["CEVICHE_MODEL_SOURCES"].map({ URL(fileURLWithPath: $0).appendingPathComponent("SkySegmentation.mlmodel") }),
              FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Set CEVICHE_MODEL_SOURCES to models/build to compile a real model") }
        let dropped = directory.appendingPathComponent("SkySegmentation.mlmodel")
        try FileManager.default.copyItem(at: source, to: dropped)
        library.rescan()
        for _ in 0..<600 where !library.isInstalled(.sky) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(library.isInstalled(.sky))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.compiledURL(.sky).path), "compiled into its own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.licenseURL(.sky).path), "a bare file brings no license")
        // A release archive unpacked by hand: its <Name> folder is compiled in place and keeps its license.
        try library.remove(.sky)
        let unpacked = library.folderURL(.sky)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: unpacked.appendingPathComponent("SkySegmentation.mlmodel"))
        try Data("MIT".utf8).write(to: unpacked.appendingPathComponent("LICENSE"))
        library.rescan()
        for _ in 0..<600 where !library.isInstalled(.sky) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(library.isInstalled(.sky))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: unpacked.path)), ["SkySegmentation.mlmodelc", "SkySegmentation.json", "LICENSE"], "the source is replaced by the compiled model")
        XCTAssertEqual(try Data(contentsOf: library.licenseURL(.sky)), Data("MIT".utf8))
        try library.remove(.sky)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.path), "the folder goes, license and all")
    }
    @MainActor func testLibraryFromBeforeTheFoldersStillCounts() throws {
        // The preview kept <Name>.mlmodelc and <Name>.json at the top of the library.
        let flat = directory.appendingPathComponent("NAFNetSIDD32.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try Data(#"{"bytes":5,"installedAt":"2026-11-17T00:00:00Z","sha256":null,"source":"file","tag":"models-v1"}"#.utf8).write(to: directory.appendingPathComponent("NAFNetSIDD32.json"))
        let library = ModelLibrary(directory: directory, set: ModelSet(repository: "ChiChou/Ceviche", tag: nil, models: [:]))
        guard case .installed(let record) = library.status(.denoise) else { return XCTFail("not seen") }
        XCTAssertEqual(record.tag, "models-v1")
        try library.remove(.denoise)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flat.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("NAFNetSIDD32.json").path))
        XCTAssertEqual(library.status(.denoise), .notInstalled)
    }
    @MainActor func testReleaseArchiveInstallsWithItsLicense() async throws {
        guard let source = ProcessInfo.processInfo.environment["CEVICHE_MODEL_SOURCES"].map({ URL(fileURLWithPath: $0).appendingPathComponent("SkySegmentation.mlmodel") }),
              FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Set CEVICHE_MODEL_SOURCES to models/build to compile a real model") }
        let folder = directory.appendingPathComponent("SkySegmentation", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("SkySegmentation.mlmodel"))
        try Data("MIT".utf8).write(to: folder.appendingPathComponent("LICENSE"))
        let file = directory.appendingPathComponent("anything.aar")
        try archive(folder, to: file)
        let sha = try ModelInstaller.sha256(of: file)
        let set = ModelSet(repository: "ChiChou/Ceviche", tag: "models-v9", models: ["SkySegmentation": .init(file: "SkySegmentation.aar", sha256: sha, bytes: 1)])
        let library = ModelLibrary(directory: directory.appendingPathComponent("Library"), set: set)
        try await library.install(.sky, from: file)
        guard case .installed(let record) = library.status(.sky) else { return XCTFail("not installed") }
        XCTAssertEqual(record.tag, "models-v9", "the pinned bytes, though chosen from a file")
        XCTAssertEqual(library.matchesPin(.sky), true)
        XCTAssertEqual(try Data(contentsOf: library.licenseURL(.sky)), Data("MIT".utf8), "unpacked as the archive has it")
        XCTAssertEqual(library.compiledURL(.sky).deletingLastPathComponent(), library.folderURL(.sky))
        XCTAssertEqual(library.compiledURL(.sky).lastPathComponent, "SkySegmentation.mlmodelc")
    }

    @MainActor func testINT8ArchiveChosenFromAFileIsRecognized() async throws {
        guard let source = ProcessInfo.processInfo.environment["CEVICHE_MODEL_SOURCES"].map({ URL(fileURLWithPath: $0).appendingPathComponent("SkySegmentation.mlmodel") }),
              FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Set CEVICHE_MODEL_SOURCES to models/build to compile a real model") }
        let folder = directory.appendingPathComponent("SkySegmentation", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("SkySegmentation.mlmodel"))
        let file = directory.appendingPathComponent("anything.aar")
        try archive(folder, to: file)
        let sha = try ModelInstaller.sha256(of: file)
        let set = ModelSet(repository: "ChiChou/Ceviche", tag: "models-v9",
                           models: ["SkySegmentation": .init(file: "SkySegmentation.aar", sha256: String(repeating: "a", count: 64), bytes: 1)],
                           int8: ["SkySegmentation": .init(file: "SkySegmentation-INT8.aar", sha256: sha, bytes: 1)])
        let library = ModelLibrary(directory: directory.appendingPathComponent("Library"), set: set)
        try await library.install(.sky, from: file)
        guard case .installed(let record) = library.status(.sky) else { return XCTFail("not installed") }
        XCTAssertEqual(record.variant, .int8)
        XCTAssertEqual(record.tag, "models-v9")
        XCTAssertEqual(library.variant(.sky), .int8)
        XCTAssertEqual(library.matchesPin(.sky), true, "either variant is a copy this build was made with")
    }

    @MainActor func testOfflineDownloadPointsToTheFileDialog() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let library = ModelLibrary(directory: directory, set: .pinned, session: URLSession(configuration: configuration))
        guard let asset = library.set.asset(.faceMesh) else { throw XCTSkip("This build pins no model set") }
        library.download(.faceMesh)
        XCTAssertFalse(library.missing.contains(.faceMesh), "on its way, so Download All skips it")
        XCTAssertTrue(library.missing.contains(.denoise))
        try await finished(library)
        XCTAssertTrue(library.missing.contains(.faceMesh), "failed, so Download All tries it again")
        XCTAssertEqual(library.status(.faceMesh), .failed(ModelLibraryError.offline(asset.file).localizedDescription))
        XCTAssertFalse(library.isInstalled(.faceMesh))
    }
    @MainActor func testPinnedModelDownloadsFromTheRelease() async throws {
        guard ProcessInfo.processInfo.environment["CEVICHE_NETWORK_TESTS"] != nil else { throw XCTSkip("Set CEVICHE_NETWORK_TESTS to download from GitHub") }
        let library = ModelLibrary(directory: directory, set: .pinned)
        let asset = try XCTUnwrap(library.set.asset(.faceMesh))
        library.download(.faceMesh)
        try await finished(library, seconds: 180)
        guard case .installed(let record) = library.status(.faceMesh) else { return XCTFail("\(library.status(.faceMesh))") }
        XCTAssertEqual(record.source, .download)
        XCTAssertEqual(record.tag, library.set.tag)
        XCTAssertEqual(record.sha256, asset.sha256)
        XCTAssertEqual(library.matchesPin(.faceMesh), true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.licenseURL(.faceMesh).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.compiledURL(.faceMesh).path))
    }
    @MainActor private func finished(_ library: ModelLibrary, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while library.isTransferring {
            guard Date() < deadline else { return XCTFail("still transferring") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Every request fails as it does with no network.
private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
