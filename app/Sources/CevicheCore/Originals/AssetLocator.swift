import Foundation

/// Where an original lives, independent of this Mac's mount points or the account that is signed in.
/// Stored in the catalog (and synced through iCloud) as a URL-like string:
///
/// - `file:///Users/…`                     a file on an internal volume
/// - `catalog:///Originals/2025-10/A.ARW` a copy inside the catalog folder (local to this Mac)
/// - `volume://<UUID>/DCIM/100MSDCF/A.ARW` a removable or external volume, by volume UUID
/// - `smb://host/share/folder/A.ARW`      a file on an SMB server, remounted on demand
public enum AssetLocator: Hashable, Sendable {
    public enum Scheme: String, CaseIterable, Sendable { case file, catalog, volume, smb }
    case file(path: String)
    case catalog(relativePath: String)
    case volume(uuid: String, relativePath: String)
    case smb(host: String, share: String, path: String)

    public var scheme: Scheme {
        switch self {
        case .file: return .file
        case .catalog: return .catalog
        case .volume: return .volume
        case .smb: return .smb
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
        case .smb:
            guard let host = components.host, !host.isEmpty else { return nil }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let share = parts.first, parts.count >= 2 else { return nil }
            self = .smb(host: host.lowercased(), share: share, path: parts.dropFirst().joined(separator: "/"))
        }
    }
    public var string: String {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        switch self {
        case .file(let path): components.host = ""; components.path = path
        case .catalog(let relative): components.host = ""; components.path = "/" + relative
        case .volume(let uuid, let relative): components.host = uuid; components.path = "/" + relative
        case .smb(let host, let share, let path): components.host = host; components.path = "/" + share + "/" + path
        }
        return components.string ?? scheme.rawValue + "://"
    }
    public var filename: String {
        switch self {
        case .file(let path), .catalog(let path), .volume(_, let path), .smb(_, _, let path): return (path as NSString).lastPathComponent
        }
    }
    /// A short, human description of the storage, for inspectors and offline notices.
    public var storageDescription: String {
        switch self {
        case .file: return L10n.tr("This Mac")
        case .catalog: return L10n.tr("Catalog folder")
        case .volume(let uuid, _): return FileSystemAssetProvider.volumeName(uuid: uuid) ?? L10n.tr("External volume")
        case .smb(let host, let share, _): return "\(share) on \(host)"
        }
    }
    /// The best locator for a file the user chose in Finder: SMB shares and external volumes are
    /// recorded by server or volume identity so the reference survives remounts and other Macs.
    public static func describing(_ url: URL) -> AssetLocator {
        let standardized = url.standardizedFileURL
        if let values = try? standardized.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeURLKey]),
           values.volumeIsRootFileSystem != true, let volumeURL = values.volume {
            let relative = relativePath(of: standardized, in: volumeURL)
            if let remount = values.volumeURLForRemounting, remount.scheme?.lowercased() == "smb", let host = remount.host,
               let share = remount.path.split(separator: "/").first.map(String.init), let relative {
                return .smb(host: host.lowercased(), share: share, path: relative)
            }
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

/// Resolves locators to files: on this Mac (`FileSystemAssetProvider`) or on SMB servers (`SMBAssetProvider`).
/// Availability checks are quick and synchronous (the grid calls them per page); fetching mounts a share or downloads
/// into the catalog's cache.
public enum AssetResolver {
    public static func availability(of locator: AssetLocator, catalog: URL?) -> AssetAvailability {
        switch locator {
        case .file(let path): FileSystemAssetProvider.availability(path: path)
        case .catalog(let relative): FileSystemAssetProvider.availability(copy: relative, catalog: catalog)
        case .volume(let uuid, let relative): FileSystemAssetProvider.availability(volume: uuid, relativePath: relative)
        case .smb(let host, let share, let path): SMBAssetProvider.availability(host: host, share: share, path: path)
        }
    }
    public static func fetch(_ locator: AssetLocator, catalog: URL?, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if case .smb(let host, let share, let path) = locator { return try await SMBAssetProvider.fetch(host: host, share: share, path: path, progress: progress) }
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
    public var originalOnThisMac: Bool { locator.scheme == .file || locator.scheme == .catalog }
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
            let parts = (path as NSString).pathComponents
            if parts.count > 2, parts[1] == "Volumes" { return fm.fileExists(atPath: "/Volumes/" + parts[2]) }
            return true
        case .catalog:
            // An iCloud catalog's copy may not have arrived from the Mac that imported it.
            guard let root else { return false }
            return CatalogImporter.originalsRoot(for: root) == root
        case .volume(let uuid, _): return FileSystemAssetProvider.mountedVolume(uuid: uuid) != nil
        case .smb(let host, let share, _): return SMBAssetProvider.mountPoint(host: host, share: share) != nil
        }
    }
}

extension AssetLocator {
    /// A locator the catalog stored itself (`CatalogAsset.origin`). One that doesn't parse (a damaged catalog, a newer
    /// build's scheme) becomes a file that isn't there, so the photo shows as missing its original.
    init(stored origin: String) {
        self = AssetLocator(string: origin) ?? .file(path: origin.isEmpty ? "/" : origin)
    }
}
