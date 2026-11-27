import Foundation

/// Where an original lives, independent of this Mac's mount points or the account that is signed in.
/// Stored in the catalog (and synced through iCloud) as a URL-like string:
///
/// - `file:///Users/…`                     a file on an internal volume
/// - `catalog:///Originals/2025-10/A.ARW` a copy inside the catalog folder (local to this Mac)
/// - `volume://<UUID>/DCIM/100MSDCF/A.ARW` a removable or external volume, by volume UUID
///
/// A network share is a `file` under `/Volumes`, read while Finder has it mounted.
public enum AssetLocator: Hashable, Sendable {
    public enum Scheme: String, CaseIterable, Sendable { case file, catalog, volume }
    case file(path: String)
    case catalog(relativePath: String)
    case volume(uuid: String, relativePath: String)

    public var scheme: Scheme {
        switch self {
        case .file: return .file
        case .catalog: return .catalog
        case .volume: return .volume
        }
    }
    public init?(string: String) {
        guard let components = URLComponents(string: string), let scheme = components.scheme.flatMap(Scheme.init) else { return nil }
        let path = components.path
        switch scheme {
        case .file:
            guard !path.isEmpty else { return nil }
            self = .file(path: path)
        case .catalog:
            let relative = (path as NSString).pathComponents.filter { $0 != "/" }.joined(separator: "/")
            guard !relative.isEmpty else { return nil }
            self = .catalog(relativePath: relative)
        case .volume:
            guard let host = components.host, !host.isEmpty, path.count > 1 else { return nil }
            self = .volume(uuid: host.uppercased(), relativePath: String(path.dropFirst()))
        }
    }
    public var string: String {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        switch self {
        case .file(let path): components.host = ""; components.path = path
        case .catalog(let relative): components.host = ""; components.path = "/" + relative
        case .volume(let uuid, let relative): components.host = uuid; components.path = "/" + relative
        }
        return components.string ?? scheme.rawValue + "://"
    }
    public var filename: String {
        switch self {
        case .file(let path), .catalog(let path), .volume(_, let path): return (path as NSString).lastPathComponent
        }
    }
    /// A short, human description of the storage, for inspectors and offline notices.
    public var storageDescription: String {
        switch self {
        case .file: return L10n.tr("This Mac")
        case .catalog: return L10n.tr("Catalog folder")
        case .volume(let uuid, _): return FileSystemAssetProvider.volumeName(uuid: uuid) ?? L10n.tr("External volume")
        }
    }
    /// The best locator for a file the user chose in Finder: external volumes are recorded by volume identity so the
    /// reference survives remounts and other Macs. Network shares have no volume UUID and stay paths.
    public static func describing(_ url: URL) -> AssetLocator {
        let standardized = url.standardizedFileURL
        if let values = try? standardized.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeURLKey]),
           values.volumeIsRootFileSystem != true, let volumeURL = values.volume {
            let relative = relativePath(of: standardized, in: volumeURL)
            if values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false,
               let uuid = values.volumeUUIDString, let relative {
                return .volume(uuid: uuid.uppercased(), relativePath: relative)
            }
        }
        // Symlinks resolved, so one file has one locator however it was reached.
        return .file(path: standardized.resolvingSymlinksInPath().path)
    }
    /// The path of `url` below `volume`, by path components, or nil when it is not inside.
    public static func relativePath(of url: URL, in volume: URL) -> String? {
        let base = volume.standardizedFileURL.pathComponents, path = url.standardizedFileURL.pathComponents
        guard path.count > base.count, path.starts(with: base) else { return nil }
        return path.dropFirst(base.count).joined(separator: "/")
    }
}

/// Whether an original can be read from this Mac right now.
public enum AssetAvailability: Equatable, Sendable {
    /// The file is on disk at this URL.
    case available(URL)
    /// Reachable from this Mac after mounting or downloading; the text names the storage.
    case fetchable(String)
    /// Not reachable from this Mac or this account; the text says why. The user can replace the file.
    case offline(String)
    public var localURL: URL? { if case .available(let url) = self { return url }; return nil }
    public var isOffline: Bool { if case .offline = self { return true }; return false }
}

/// Resolves locators to files (`FileSystemAssetProvider`).
/// Availability checks are quick and synchronous (the grid calls them per page); fetching mounts a share or downloads
/// into the catalog's cache.
public enum AssetResolver {
    public static func availability(of locator: AssetLocator, catalog: URL?) -> AssetAvailability {
        switch locator {
        case .file(let path): FileSystemAssetProvider.availability(path: path)
        case .catalog(let relative): FileSystemAssetProvider.availability(copy: relative, catalog: catalog)
        case .volume(let uuid, let relative): FileSystemAssetProvider.availability(volume: uuid, relativePath: relative)
        }
    }
    public static func fetch(_ locator: AssetLocator, catalog: URL?, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch availability(of: locator, catalog: catalog) {
        case .available(let url): progress(1); return url
        case .fetchable(let text):
            // Only a catalog copy iCloud Drive has not downloaded yet is fetched on this Mac.
            guard case .catalog(let relative) = locator, let catalog else { throw EditorError.invalidDocument(text) }
            return try await FileSystemAssetProvider.download(CatalogImporter.catalogCopyURL(relative, root: catalog), progress: progress)
        case .offline(let text): throw EditorError.invalidDocument(text)
        }
    }
}

extension CatalogAsset {
    /// Where the original lives.
    public var locator: AssetLocator { AssetLocator(stored: origin) }
    /// The original is on this Mac's own disk, not a network share or another volume.
    public var originalOnThisMac: Bool {
        switch locator {
        case .file(let path): return AssetLocator.volumesMount(path) == nil
        case .catalog: return true
        case .volume: return false
        }
    }
    /// A quick availability check for grids and inspectors.
    public func availability(catalog root: URL?) -> AssetAvailability {
        let url = CatalogImporter.sourceURL(for: self, root: root)
        // A file iCloud Drive has not downloaded is fetched first, rather than read (and downloaded) where it is.
        if FileManager.default.fileExists(atPath: url.path), CatalogImporter.isDownloaded(url) { return .available(url) }
        return AssetResolver.availability(of: locator, catalog: root)
    }
    /// Whether the original is gone from storage this Mac can reach. A disconnected volume or share, a volume
    /// that is not mounted, or a copy still on another Mac or in iCloud Drive is not missing.
    public func originalIsMissing(catalog root: URL?) -> Bool {
        guard availability(catalog: root).isOffline else { return false }
        let fm = FileManager.default
        switch locator {
        case .file(let path):
            // A path on another volume counts only while that volume is mounted.
            if let mount = AssetLocator.volumesMount(path) { return fm.fileExists(atPath: mount) }
            return true
        case .catalog:
            // An iCloud catalog's copy may not have arrived from the Mac that imported it.
            guard let root else { return false }
            return CatalogImporter.originalsRoot(for: root) == root
        case .volume(let uuid, _): return FileSystemAssetProvider.mountedVolume(uuid: uuid) != nil
        }
    }
}

extension AssetLocator {
    /// A locator the catalog stored itself (`CatalogAsset.origin`). One that doesn't parse (a damaged catalog, a newer
    /// build's scheme) becomes a file that isn't there, so the photo shows as missing its original.
    init(stored origin: String) {
        if let locator = AssetLocator(string: origin) { self = locator; return }
        // Builds before 2026-11-27 recorded shares as `smb://host/share/path`; Finder mounts them at /Volumes/share.
        if let components = URLComponents(string: origin), components.scheme == "smb", components.path.count > 1 {
            self = .file(path: "/Volumes" + components.path); return
        }
        self = .file(path: origin.isEmpty ? "/" : origin)
    }
    /// `/Volumes/<name>` for a path on another volume or a network share, else nil.
    static func volumesMount(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : nil
    }
}
