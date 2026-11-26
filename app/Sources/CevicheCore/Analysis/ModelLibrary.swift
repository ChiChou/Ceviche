import Foundation
import CoreML
import CryptoKit
import AppleArchive
import System

/// The Core ML models installed for this user, in `~/Library/Application Support/Ceviche/Models`, and the downloads
/// that fill it. Apart from the few built into the app (`BundledModel.isBuiltIn`), each is fetched on demand, FP16 or
/// INT8 as the user chooses, from the model set pinned in this build (`ModelSet.pinned`), verified against its pinned SHA-256 and unpacked into its own folder as the release archive
/// has it, `<Name>/`, with the model compiled by Core ML (`<Name>/<Name>.mlmodelc`, the source is not kept), the
/// `LICENSE` packed with it and a `<Name>.json` record of where it came from. Models can also be added from files (a
/// release `.aar`, an `.mlpackage`, an `.mlmodel` or a compiled `.mlmodelc`), which are installed the same way. A build
/// without downloads (`allowsDownloads` false: the Mac App Store build) relies on those, or on a release archive unpacked
/// into the folder by hand: `<Name>/<Name>.mlpackage` (or `.mlmodel`), or the bare file beside the folders, is
/// compiled in on the next `rescan`. Libraries from before the folders kept `<Name>.mlmodelc` and `<Name>.json` at the
/// top; those still count until the model is installed again. The iPad and iPhone App Store build downloads the same
/// archives as Apple-hosted asset packs instead (`delivery`, `ModelAssetPacks`). A missing model disables only its feature;
/// `BundledModel` finds installed ones through `searchDirectories`.
@MainActor
public final class ModelLibrary: ObservableObject {
    public static let shared = ModelLibrary()
    /// Posted after a model is installed or removed, for code that caches availability.
    public static let didChange = Notification.Name("CevicheModelLibraryDidChange")
    nonisolated public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ceviche/Models", isDirectory: true)

    /// How an installed model got here, kept beside it.
    public struct Installed: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable { case download, file }
        public var source: Source
        /// The model set tag, for downloads.
        public var tag: String?
        /// SHA-256 of the release archive it came from, when it came from one; nil for a bare model file.
        public var sha256: String?
        public var bytes: Int64
        public var installedAt: Date
        /// Which of the set's archives it came from, FP16 or INT8; nil for a bare model file and in records from
        /// before the INT8 copies (those were FP16).
        public var variant: ModelSet.Variant? = nil
    }
    public enum Transfer: Equatable, Sendable {
        case connecting
        case downloading(received: Int64, expected: Int64?)
        case installing
        public var fraction: Double? {
            switch self {
            case .downloading(let received, let expected?) where expected > 0: return min(1, Double(received) / Double(expected))
            case .installing: return 1
            default: return nil
            }
        }
    }
    public enum Status: Equatable, Sendable { case notInstalled, installed(Installed), transferring(Transfer), failed(String) }

    public let directory: URL
    public let set: ModelSet
    @Published public private(set) var installed: [BundledModel: Installed] = [:]
    @Published public private(set) var transfers: [BundledModel: Transfer] = [:]
    @Published public private(set) var failures: [BundledModel: String] = [:]
    /// The model a tool asked for when it opened the manager, which highlights it.
    @Published public var requested: BundledModel?
    /// False in the Mac App Store build: no GitHub downloads, models come from files.
    public var allowsDownloads = true
    /// Where downloads come from: the model set's GitHub release, or, in the iPad and iPhone App Store build, the same
    /// archives as Apple-hosted asset packs.
    public enum Delivery: Sendable { case release, assetPacks }
    public var delivery = Delivery.release
    private var tasks: [BundledModel: Task<Void, Never>] = [:]
    private let session: URLSession
    private var release: GitHubRelease?

    public init(directory: URL = ModelLibrary.defaultDirectory, set: ModelSet = .pinned, session: URLSession = .shared) {
        self.directory = directory; self.set = set; self.session = session
        rescan()
    }

    // MARK: State

    public func status(_ model: BundledModel) -> Status {
        if let transfer = transfers[model] { return .transferring(transfer) }
        if let failure = failures[model] { return .failed(failure) }
        if let record = installed[model] { return .installed(record) }
        return .notInstalled
    }
    public func isInstalled(_ model: BundledModel) -> Bool { installed[model] != nil }
    /// Whether the installed copy is one this build was made with, FP16 or INT8; nil when the build pins no set or
    /// the model is not installed.
    public func matchesPin(_ model: BundledModel) -> Bool? {
        guard let record = installed[model], set.asset(model) != nil else { return nil }
        return set.variant(model, sha256: record.sha256) != nil
    }
    /// The weights of the installed copy, when it is one of the set's archives.
    public func variant(_ model: BundledModel) -> ModelSet.Variant? {
        installed[model].flatMap { $0.variant ?? set.variant(model, sha256: $0.sha256) }
    }
    public var isTransferring: Bool { !transfers.isEmpty }
    /// Pinned models neither installed, built in nor on their way, and their FP16 download size: what Download All
    /// would start.
    public var missing: [BundledModel] { BundledModel.allCases.filter { installed[$0] == nil && transfers[$0] == nil && !$0.isBuiltIn && set.asset($0) != nil } }
    public var missingBytes: Int64 { missing.compactMap { set.asset($0)?.bytes }.reduce(0, +) }
    /// The model's folder: its compiled model, the license it came with and the install record.
    public func folderURL(_ model: BundledModel) -> URL { directory.appendingPathComponent(model.rawValue, isDirectory: true) }
    public func compiledURL(_ model: BundledModel) -> URL { folderURL(model).appendingPathComponent(model.rawValue + ".mlmodelc", isDirectory: true) }
    /// The license packed with the model in its release archive; absent for a model added as a bare file.
    public func licenseURL(_ model: BundledModel) -> URL { folderURL(model).appendingPathComponent("LICENSE") }
    private func recordURL(_ model: BundledModel) -> URL { folderURL(model).appendingPathComponent(model.rawValue + ".json") }
    /// Where libraries from before the per-model folders kept the model and its record.
    private func flatURLs(_ model: BundledModel) -> (compiled: URL, record: URL) {
        (directory.appendingPathComponent(model.rawValue + ".mlmodelc", isDirectory: true), directory.appendingPathComponent(model.rawValue + ".json"))
    }

    /// Reads the directory; a model placed there by hand counts as installed from a file.
    public func rescan() {
        // Folders an install was cut short in the middle of.
        if tasks.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(".") && (name.hasSuffix(Self.stagingSuffix) || name.hasSuffix(".mlmodelc")) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        var found: [BundledModel: Installed] = [:]
        for model in BundledModel.allCases {
            let flat = flatURLs(model)
            guard let (compiled, recordFile) = [(compiledURL(model), recordURL(model)), flat].first(where: { FileManager.default.fileExists(atPath: $0.0.path) }) else { continue }
            if let data = try? Data(contentsOf: recordFile), let record = try? Self.decoder.decode(Installed.self, from: data) {
                found[model] = record
            } else {
                found[model] = Installed(source: .file, tag: nil, sha256: nil, bytes: Self.size(of: compiled), installedAt: Self.date(of: compiled))
            }
        }
        if found != installed { installed = found }
        adoptUnpackedModels()
    }
    /// A model unpacked into the library by hand from the release, `<Name>/<Name>.mlpackage` (or `.mlmodel`) beside
    /// its `LICENSE`, or the bare file at the top, is compiled into its folder like a file chosen in Settings › Models.
    /// The source is removed once the compiled model is in; a model that fails stays for the user to see.
    private func adoptUnpackedModels() {
        for model in BundledModel.allCases where installed[model] == nil && tasks[model] == nil && transfers[model] == nil && failures[model] == nil {
            guard let source = [folderURL(model), directory].lazy.flatMap({ base in ["mlpackage", "mlmodel"].map { base.appendingPathComponent(model.rawValue + "." + $0) } })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            let inFolder = source.deletingLastPathComponent().standardizedFileURL == folderURL(model).standardizedFileURL
            Task { [weak self] in
                guard let self else { return }
                let record = Installed(source: .file, tag: nil, sha256: nil, bytes: Self.size(of: source), installedAt: Date())
                self.transfers[model] = .installing
                defer { self.transfers[model] = nil }
                do {
                    // In its folder, the source goes when the folder is replaced; a bare file at the top is removed after.
                    try await self.install(model, source: source, record: record, license: inFolder ? self.licenseURL(model) : nil)
                    if !inFolder { try? FileManager.default.removeItem(at: source) }
                } catch { self.failures[model] = error.localizedDescription }
            }
        }
    }

    // MARK: Downloads

    /// Fetches the pinned asset for `model` with `variant`'s weights, verifies it and installs it, replacing the copy
    /// installed before (the other variant, say) only once the new one is in. Progress shows in `transfers`.
    public func download(_ model: BundledModel, variant: ModelSet.Variant = .fp16) {
        guard allowsDownloads, tasks[model] == nil, let asset = set.asset(model, variant) else { return }
        failures[model] = nil
        transfers[model] = .connecting
        tasks[model] = Task { [weak self] in
            guard let self else { return }
            do {
                let archive = try await self.fetch(asset) { [weak self] received, expected in
                    Task { @MainActor in self?.transfers[model] = .downloading(received: received, expected: expected) }
                }
                defer { try? FileManager.default.removeItem(at: archive) }
                try Task.checkCancellation()
                self.transfers[model] = .installing
                let record = Installed(source: .download, tag: self.set.tag, sha256: asset.sha256, bytes: asset.bytes, installedAt: Date(), variant: variant)
                try await self.install(model, archive: archive, record: record)
                // The installed copy is what the app uses; the pack's archive need not stay as well.
                #if canImport(BackgroundAssets)
                if self.delivery == .assetPacks, let tag = self.set.tag, #available(iOS 26, macOS 26, *) { await ModelAssetPacks.discard(asset, tag: tag) }
                #endif
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch let error as URLError where ModelLibraryError.isOffline(error) {
                // The row keeps From File… beside Download, for a copy fetched on another computer.
                self.failures[model] = ModelLibraryError.offline(asset.file).localizedDescription
            } catch {
                self.failures[model] = error.localizedDescription
            }
            self.transfers[model] = nil
            self.tasks[model] = nil
        }
    }
    public func downloadAll() { missing.forEach { download($0) } }
    public func cancel(_ model: BundledModel) { tasks[model]?.cancel() }
    public func cancelAll() { tasks.values.forEach { $0.cancel() } }
    public func clearFailure(_ model: BundledModel) { failures[model] = nil }

    /// Downloads `asset` into a temporary file, from the release or its asset pack, and verifies its SHA-256 against
    /// the pin: a pack holds the very archive the release has.
    private func fetch(_ asset: ModelSet.Asset, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let file: URL
        switch delivery {
        case .release:
            let url = try await assetURL(asset)
            file = try await ModelInstaller.download(url, session: session, expected: asset.bytes, progress: progress)
        case .assetPacks:
            guard let tag = set.tag, #available(iOS 26, macOS 26, *) else { throw ModelLibraryError.notPinned }
            #if canImport(BackgroundAssets)
            file = try await ModelAssetPacks.fetch(asset, tag: tag, progress: progress)
            #else
            throw ModelLibraryError.notPinned
            #endif
        }
        do { try ModelInstaller.verify(file, sha256: asset.sha256) } catch { try? FileManager.default.removeItem(at: file); throw error }
        return file
    }
    /// The asset's download URL from the release on the GitHub API, which also confirms the asset exists; when the
    /// API cannot be reached (offline, or rate limited) the conventional download URL serves the same bytes, and the
    /// checksum decides either way.
    private func assetURL(_ asset: ModelSet.Asset) async throws -> URL {
        guard let direct = set.directURL(asset), let api = set.apiURL else { throw ModelLibraryError.notPinned }
        if release == nil {
            do { release = try await ModelInstaller.release(api, session: session) }
            catch let error as ModelLibraryError { throw error }
            catch { return direct }
        }
        guard let found = release?.assets.first(where: { $0.name == asset.file }) else { throw ModelLibraryError.assetMissing(asset.file, set.tag ?? "") }
        return found.browser_download_url
    }
    // MARK: Files

    /// Installs `model` from a file the user chose for it in Settings › Models: a release `.aar`, an `.mlpackage`, an
    /// `.mlmodel` or a compiled `.mlmodelc`, under any name. The file is only checked to be a model Core ML loads;
    /// an archive whose checksum is one of the pinned ones (FP16 or INT8) is recorded as that copy.
    public func install(_ model: BundledModel, from url: URL) async throws {
        guard tasks[model] == nil else { throw ModelLibraryError.busy(model) }
        failures[model] = nil
        transfers[model] = .installing
        defer { transfers[model] = nil }
        do {
            if url.pathExtension.lowercased() == "aar" {
                let sha = try ModelInstaller.sha256(of: url)
                let variant = set.variant(model, sha256: sha)
                let record = Installed(source: .file, tag: variant != nil ? set.tag : nil, sha256: sha, bytes: Self.size(of: url), installedAt: Date(), variant: variant)
                try await install(model, archive: url, record: record)
            } else {
                guard ModelInstaller.modelExtensions.contains(url.pathExtension.lowercased()) else { throw ModelLibraryError.unexpectedContents(url.lastPathComponent) }
                let record = Installed(source: .file, tag: nil, sha256: nil, bytes: Self.size(of: url), installedAt: Date())
                try await install(model, source: url, record: record)
            }
        } catch {
            failures[model] = error.localizedDescription
            throw error
        }
    }
    /// Deletes the installed model; the feature that needs it turns off until it is installed again.
    public func remove(_ model: BundledModel) throws {
        cancel(model)
        failures[model] = nil
        if FileManager.default.fileExists(atPath: folderURL(model).path) { try FileManager.default.removeItem(at: folderURL(model)) }
        let flat = flatURLs(model)
        if FileManager.default.fileExists(atPath: flat.compiled.path) { try FileManager.default.removeItem(at: flat.compiled) }
        try? FileManager.default.removeItem(at: flat.record)
        BundledModelCache.shared.evict(model)
        installed[model] = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func install(_ model: BundledModel, archive: URL, record: Installed) async throws {
        let unpacked = try await Task.detached { try ModelInstaller.extract(archive) }.value
        defer { try? FileManager.default.removeItem(at: unpacked) }
        guard let source = ModelInstaller.modelFile(in: unpacked) else { throw ModelLibraryError.unexpectedContents(archive.lastPathComponent) }
        try await install(model, source: source, record: record, license: source.deletingLastPathComponent().appendingPathComponent("LICENSE"))
    }
    private static let stagingSuffix = ".installing"
    /// Compiles (or copies, when already compiled) the model, checks that Core ML loads it, and puts it in the model's
    /// folder with `license` (the license packed beside it in a release archive, when there is one) and its record,
    /// replacing the previous folder in one step. A copy from before the per-model folders is removed.
    private func install(_ model: BundledModel, source: URL, record: Installed, license: URL? = nil) async throws {
        try Task.checkCancellation()
        let compiled = try await ModelInstaller.compile(source)
        defer { if compiled != source { try? FileManager.default.removeItem(at: compiled) } }
        try ModelInstaller.check(compiled)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Assembled beside it under another name first, so a copy cut short never looks like an installed model.
        let staged = directory.appendingPathComponent(".\(model.rawValue)-\(UUID().uuidString)\(Self.stagingSuffix)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: compiled, to: staged.appendingPathComponent(model.rawValue + ".mlmodelc", isDirectory: true))
            if let license, FileManager.default.fileExists(atPath: license.path) {
                try FileManager.default.copyItem(at: license, to: staged.appendingPathComponent("LICENSE"))
            }
            // A record that can't be written only shows the model as installed from a file.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(record).write(to: staged.appendingPathComponent(model.rawValue + ".json"), options: .atomic)
            let destination = folderURL(model)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged, options: [])
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch { try? FileManager.default.removeItem(at: staged); throw error }
        let flat = flatURLs(model)
        try? FileManager.default.removeItem(at: flat.compiled); try? FileManager.default.removeItem(at: flat.record)
        BundledModelCache.shared.evict(model)
        installed[model] = record
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static let decoder: JSONDecoder = { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }()
    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    private static func date(of url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date() }
}

public enum ModelLibraryError: LocalizedError, Equatable {
    case notPinned
    case assetMissing(String, String)
    case checksum(String)
    case unexpectedContents(String)
    case busy(BundledModel)
    case extraction(String)
    case server(Int)
    case offline(String)
    /// Errors that mean GitHub could not be reached at all, rather than a bad answer from it.
    static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
         .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed].contains(error.code)
    }
    public var errorDescription: String? {
        switch self {
        case .notPinned: return L10n.tr("This build names no model set to download from. Add the models from files instead.")
        case .assetMissing(let file, let tag): return L10n.tr("\(file) is not part of the \(tag) model set on GitHub.")
        case .checksum(let file): return L10n.tr("\(file) does not match the checksum this build expects. The download was discarded.")
        case .unexpectedContents(let file): return L10n.tr("\(file) does not contain a Core ML model.")
        case .busy(let model): return L10n.tr("The \(model.feature) model is being installed already.")
        case .extraction(let detail): return L10n.tr("The archive could not be unpacked: \(detail)")
        case .server(let code): return L10n.tr("GitHub answered with status \(code).")
        case .offline(let file): return L10n.tr("GitHub could not be reached. Get \(file) from the release page and add it with From File….")
        }
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable { let name: String; let browser_download_url: URL; let size: Int64 }
    let tag_name: String
    let assets: [Asset]
}

/// The file work behind `ModelLibrary`, off the main actor.
enum ModelInstaller {
    static let modelExtensions: Set<String> = ["mlpackage", "mlmodel", "mlmodelc"]
    /// The one model file in an unpacked archive, whatever it is called: a `.mlpackage`, `.mlmodel` or `.mlmodelc` at
    /// the top level, or one level down when the archive wrapped a folder (as the release archives do). Which model it
    /// is was decided by the row the user chose the file for, never by its name.
    static func modelFile(in directory: URL) -> URL? {
        let extensions = modelExtensions
        func candidates(_ folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        }
        let top = candidates(directory)
        if let model = top.first(where: { extensions.contains($0.pathExtension.lowercased()) }) { return model }
        for folder in top where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let model = candidates(folder).first(where: { extensions.contains($0.pathExtension.lowercased()) }) { return model }
        }
        return nil
    }
    static func release(_ api: URL, session: URLSession) async throws -> GitHubRelease {
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ceviche", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // 404: the set was never published. Other codes (rate limit, outage) let the caller fall back to the direct URL.
            if code == 404 { throw ModelLibraryError.server(code) }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
    /// Downloads to a temporary file, reporting bytes as they arrive. The task is cancelled with the Swift task.
    static func download(_ url: URL, session: URLSession, expected: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("Ceviche", forHTTPHeaderField: "User-Agent")
        let delegate = DownloadDelegate(expected: expected, progress: progress)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64?
        let progress: @Sendable (Int64, Int64?) -> Void
        var continuation: CheckedContinuation<URL, Error>?
        private var result: Result<URL, Error>?
        init(expected: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.expected = expected; self.progress = progress }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns; keep it.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-model-" + UUID().uuidString + ".aar")
            do {
                if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 { throw ModelLibraryError.server(code) }
                try FileManager.default.moveItem(at: location, to: kept)
                result = .success(kept)
            } catch { result = .failure(error) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { continuation.resume(throwing: error) }
            else if let result { continuation.resume(with: result) }
            else { continuation.resume(throwing: URLError(.unknown)) }
        }
    }
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk); return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ url: URL, sha256 expected: String) throws {
        guard try sha256(of: url) == expected.lowercased() else { throw ModelLibraryError.checksum(url.lastPathComponent) }
    }
    /// Unpacks an Apple Archive (`.aar`, compressed or not) into a new temporary directory with the AppleArchive
    /// framework, on macOS and iPadOS alike, with no helper process. Only directories and regular files at paths inside
    /// the destination are written; links, devices and paths that climb out of it are refused.
    static func extract(_ archive: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644))
            else { throw ModelLibraryError.extraction(L10n.tr("\(archive.lastPathComponent) could not be opened.")) }
            defer { try? file.close() }
            // Reads uncompressed archives as they are, and LZFSE, LZMA, zlib, LZ4 or LZBITMAP ones.
            guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file),
                  let decoded = ArchiveStream.decodeStream(readingFrom: decompressed)
            else { throw ModelLibraryError.extraction(L10n.tr("\(archive.lastPathComponent) is not an Apple Archive.")) }
            defer { try? decoded.close(); try? decompressed.close() }
            var refused: String?
            guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(destination.path), selectUsing: { message, path, data in
                guard message == .extractBegin else { return .ok }
                var type: ArchiveHeader.EntryType?
                if case .header(let header)? = data { type = header.entryType }
                if path.isAbsolute || path.components.contains(where: { $0.kind != .regular }) || (type != nil && type != .directory && type != .regularFile) {
                    refused = path.string
                    return .cancel
                }
                return .ok
            }, flags: [.ignoreOperationNotPermitted]) else { throw ModelLibraryError.extraction(destination.path) }
            defer { try? extractor.close() }
            do { _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extractor) }
            catch {
                if let refused { throw ModelLibraryError.extraction(L10n.tr("\(archive.lastPathComponent) contains an entry that cannot be unpacked: \(refused)")) }
                throw ModelLibraryError.extraction("\(archive.lastPathComponent): \(error.localizedDescription)")
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    /// A compiled model for `source`: the source itself when it is already an `.mlmodelc`.
    static func compile(_ source: URL) async throws -> URL {
        if source.pathExtension.lowercased() == "mlmodelc" { return source }
        return try await MLModel.compileModel(at: source)
    }
    /// Core ML must load it, or the file is not a usable model.
    static func check(_ compiled: URL) throws {
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        _ = try MLModel(contentsOf: compiled, configuration: configuration)
    }
}
