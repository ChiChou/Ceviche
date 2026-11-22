import Foundation
import CryptoKit

/// A LUT, camera profile or ICC profile that a stored development uses, kept once as a file instead of inside every
/// development that applies it. `path` is relative to the resource root and names the file; `digest` is the
/// SHA-256 of its bytes and finds it again after it moves or is renamed.
public struct ResourceReference: Codable, Hashable, Sendable {
    public var path: String
    public var digest: String
    public init(path: String, digest: String) { self.path = path; self.digest = digest }
    static func digest(of data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// What a resource file holds, and where Ceviche writes new ones.
public enum ResourceKind: String, CaseIterable, Sendable {
    case lut, haldLUT, cameraProfile, colorProfile
    /// LUTs are `.cube` text or original Hald PNGs; a camera profile is the look Ceviche separated from a DCP (`CameraProfileLibrary.separated`),
    /// which depends on the camera's base profile and so is kept as computed; an ICC profile is the profile itself.
    var folder: String {
        switch self {
        case .lut, .haldLUT: return LookKind.luts.rawValue + "/Imported"
        case .cameraProfile: return LookKind.profiles.rawValue + "/.Separated"
        case .colorProfile: return "Color Profiles"
        }
    }
    var fileExtension: String {
        switch self {
        case .lut: return "cube"
        case .haldLUT: return "png"
        case .cameraProfile: return "json"
        case .colorProfile: return "icc"
        }
    }
    static let extensions: Set<String> = ["cube", "png", "json", "icc", "icm"]
}

/// A development refers to a resource this Mac cannot read: it was deleted, or iCloud Drive has not downloaded it yet.
public struct ResourceUnavailable: LocalizedError {
    public let reference: ResourceReference
    public let downloading: Bool
    public var errorDescription: String? {
        let name = (reference.path as NSString).lastPathComponent
        return downloading ? L10n.tr("“\(name)” is still downloading from iCloud Drive. The photo opens once it arrives.")
            : L10n.tr("“\(name)” is missing from the library. Put the file back to open this photo with its look.")
    }
}

/// Where resources live, chosen for the build. A build signed for iCloud keeps them in the app's iCloud Drive folder so
/// every Mac has them; other builds keep them in the local library folder, or, when the build sets
/// `CevicheLocalStorage` to `database` in Info.plist (`CEVICHE_LOCAL_STORAGE=database` in build.config), in each
/// catalog's database. Development references resolve from the database first in every mode.
public enum ResourceStorage: Sendable {
    case folder(FolderResources)
    case database

    /// What catalogs opened by this process use; the app sets it at launch, and anything else (tests, tools) keeps
    /// resources in the catalog database.
    public static var shared: ResourceStorage {
        get { lock.withLock { configured } }
        set { lock.withLock { configured = newValue } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured = ResourceStorage.database

    /// The storage this build is configured for. Looking up the iCloud Drive folder can block, so call it off the main thread.
    public static func forBuild(bundle: Bundle = .main) -> ResourceStorage {
        let container = CatalogManifest.cloudContainer
        if ubiquityContainers.contains(container), let url = FileManager.default.url(forUbiquityContainerIdentifier: container) {
            return .folder(FolderResources(root: url.appendingPathComponent("Documents", isDirectory: true), ubiquitous: true))
        }
        if bundle.object(forInfoDictionaryKey: "CevicheLocalStorage") as? String == "database" { return .database }
        return .folder(FolderResources(root: LookLibrary.localRoot))
    }
    /// The library folder this storage keeps resources in, if it uses one.
    public var folder: FolderResources? { if case .folder(let folder) = self { return folder }; return nil }
    /// What a catalog of this kind uses. Only an iCloud catalog keeps its looks in iCloud Drive, where every Mac that
    /// syncs it finds them; a local catalog keeps them in the local library folder.
    public func scoped(to kind: CatalogKind) -> ResourceStorage {
        guard kind != .cloud, case .folder(let folder) = self, folder.ubiquitous else { return self }
        return .folder(FolderResources(root: LookLibrary.localRoot))
    }
    /// iCloud Drive containers this process is entitled to; empty for an ad-hoc or CloudKit-only build.
    static var ubiquityContainers: [String] { Entitlements.containers("com.apple.developer.ubiquity-container-identifiers") }
}

/// Resource files below a root folder: the look library, locally or in iCloud Drive. Files are found at their stored
/// path, or by digest when they moved; Ceviche only adds files and never changes or deletes one.
public final class FolderResources: @unchecked Sendable {
    public let root: URL
    /// The root is in iCloud Drive: files may not be downloaded yet, and access is coordinated with the sync daemon.
    public let ubiquitous: Bool
    private let lock = NSLock()
    /// Digest per relative path, valid while the file's size and modification date stay the same.
    private var known: [String: (size: Int, modified: Date, digest: String)] = [:]

    public init(root: URL, ubiquitous: Bool = false) {
        self.root = root.standardizedFileURL; self.ubiquitous = ubiquitous
    }

    /// The reference for a file inside the root, such as a LUT applied from the look library; nil for a file elsewhere.
    public func reference(for url: URL) -> ResourceReference? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path, base = root.resolvingSymlinksInPath().path + "/"
        guard path.hasPrefix(base), let data = try? read(url) else { return nil }
        let relative = String(path.dropFirst(base.count)), digest = ResourceReference.digest(of: data)
        remember(relative, url: url, digest: digest)
        return ResourceReference(path: relative, digest: digest)
    }
    /// True when the file is here (downloaded) with the referenced contents.
    func contains(_ reference: ResourceReference) -> Bool { (try? locate(reference)) != nil }
    /// The referenced file's bytes. Throws `ResourceUnavailable` when it is gone or not downloaded yet.
    func data(for reference: ResourceReference) throws -> Data {
        if let url = try locate(reference) { return try read(url) }
        throw ResourceUnavailable(reference: reference, downloading: downloading(reference))
    }
    /// Adds a file with these contents under `kind`'s folder, or returns the one already there.
    func store(_ data: Data, kind: ResourceKind, name: String) throws -> ResourceReference {
        let contents = ResourceReference.digest(of: data)
        let stem = Self.fileName(name)
        for attempt in 1...100 {
            let relative = kind.folder + "/" + (attempt == 1 ? stem : "\(stem) \(attempt)") + "." + kind.fileExtension
            let url = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                if digest(at: relative, url: url) == contents { return ResourceReference(path: relative, digest: contents) }
                continue
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, to: url)
            remember(relative, url: url, digest: contents)
            return ResourceReference(path: relative, digest: contents)
        }
        throw EditorError.invalidDocument(L10n.tr("Too many files named “\(stem)” in \(kind.folder)."))
    }

    private func locate(_ reference: ResourceReference) throws -> URL? {
        let url = root.appendingPathComponent(reference.path)
        if isDownloaded(url), digest(at: reference.path, url: url) == reference.digest { return url }
        // Moved or renamed within the library: look for the same contents.
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        for case let candidate as URL in walker {
            // iCloud catalogs keep their originals beside the library (`CatalogStore.originalsRoot`).
            if walker.level == 1, candidate.lastPathComponent == "Catalogs" { walker.skipDescendants(); continue }
            guard ResourceKind.extensions.contains(candidate.pathExtension.lowercased()), isDownloaded(candidate) else { continue }
            let relative = String(candidate.standardizedFileURL.path.dropFirst(root.path.count + 1))
            if digest(at: relative, url: candidate) == reference.digest { return candidate }
        }
        return nil
    }
    private func downloading(_ reference: ResourceReference) -> Bool {
        guard ubiquitous else { return false }
        let url = root.appendingPathComponent(reference.path)
        guard FileManager.default.fileExists(atPath: url.path), !isDownloaded(url) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }
    private func isDownloaded(_ url: URL) -> Bool {
        guard ubiquitous else { return FileManager.default.fileExists(atPath: url.path) }
        var url = url; url.removeAllCachedResourceValues()
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return status == .current
    }
    private func digest(at relative: String, url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        if let cached = lock.withLock({ known[relative] }), cached.size == size, cached.modified == modified { return cached.digest }
        guard let data = try? read(url) else { return nil }
        let digest = ResourceReference.digest(of: data)
        lock.withLock { known[relative] = (size, modified, digest) }
        return digest
    }
    private func remember(_ relative: String, url: URL, digest: String) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return }
        lock.withLock { known[relative] = (size, modified, digest) }
    }
    private func read(_ url: URL) throws -> Data {
        guard ubiquitous else { return try Data(contentsOf: url) }
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in result = Result { try Data(contentsOf: url) } }
        if let coordination { throw coordination }
        return try result.get()
    }
    private func write(_ data: Data, to url: URL) throws {
        guard ubiquitous else { return try data.write(to: url, options: .atomic) }
        var result: Result<Void, Error> = .success(())
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { url in result = Result { try data.write(to: url, options: .atomic) } }
        if let coordination { throw coordination }
        try result.get()
    }
    static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = String((cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned).prefix(120))
        return stem.isEmpty ? L10n.tr("Untitled") : stem
    }
}

extension CreativeLUT {
    /// The table as `.cube` text. Six decimals keep every 16-bit sample exact when the file is read back.
    var cubeText: Data {
        var text = "TITLE \"\(name.replacingOccurrences(of: "\"", with: "'"))\"\nLUT_3D_SIZE \(dimension)\n"
        text.reserveCapacity(text.count + dimension * dimension * dimension * 28)
        samples.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt16.self)
            for index in stride(from: 0, to: values.count, by: 3) {
                func value(_ offset: Int) -> String { String(format: "%.6f", Double(UInt16(littleEndian: values[index + offset])) / 65535) }
                text += value(0) + " " + value(1) + " " + value(2) + "\n"
            }
        }
        return Data(text.utf8)
    }
}

/// Parsed resources by digest, so opening History or another photo with the same LUT does not parse it again.
final class ResourceCache: @unchecked Sendable {
    static let shared = ResourceCache()
    private let lock = NSLock()
    private var luts = LRUCache<String, CreativeLUT>(countLimit: 32), profiles = LRUCache<String, CameraProfile>(countLimit: 32)
    /// References already stored for a LUT's samples, so autosaving does not rewrite the `.cube` text each time.
    private var stored: [String: ResourceReference] = [:]

    func lut(_ reference: ResourceReference, parse: () throws -> CreativeLUT) rethrows -> CreativeLUT {
        if let cached = lock.withLock({ luts.value(for: reference.digest) }) { return cached }
        let parsed = try parse()
        lock.withLock { _ = luts.insert(parsed, for: reference.digest) }
        return parsed
    }
    func profile(_ reference: ResourceReference, parse: () throws -> CameraProfile) rethrows -> CameraProfile {
        if let cached = lock.withLock({ profiles.value(for: reference.digest) }) { return cached }
        let parsed = try parse()
        lock.withLock { _ = profiles.insert(parsed, for: reference.digest) }
        return parsed
    }
    func storedReference(_ key: String) -> ResourceReference? { lock.withLock { stored[key] } }
    func rememberStored(_ key: String, _ reference: ResourceReference) { lock.withLock { stored[key] = reference } }
}

extension CameraProfile {
    /// The separated look as a resource file: everything except the settings that belong to the photo.
    var separatedContents: Data {
        get throws {
            var look = self; look.amount = 1; look.enabled = true; look.source = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(look)
        }
    }
}
