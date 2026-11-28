import Foundation

/// Files on this Mac: internal volumes, mounted shares, copies inside the catalog, and external volumes found by UUID.
public enum FileSystemAssetProvider {
    static func availability(path: String) -> AssetAvailability {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return .available(URL(fileURLWithPath: path)) }
        if let mount = AssetLocator.volumesMount(path), !fm.fileExists(atPath: mount) {
            return .offline(L10n.tr("\((mount as NSString).lastPathComponent) is not connected."))
        }
        return .offline(L10n.tr("The file is no longer at \(path)."))
    }
    static func availability(copy relative: String, catalog: URL?) -> AssetAvailability {
        guard let catalog else { return .offline(L10n.tr("The original was copied into a catalog on another Mac.")) }
        let url = CatalogImporter.catalogCopyURL(relative, root: catalog)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .offline(CatalogImporter.originalsRoot(for: catalog) == catalog ? L10n.tr("The copy is missing from this Mac's catalog folder.")
                : L10n.tr("The original is not in iCloud Drive yet. It uploads from the Mac that imported it while Ceviche is open there."))
        }
        return CatalogImporter.isDownloaded(url) ? .available(url) : .fetchable(L10n.tr("iCloud Drive"))
    }
    static func availability(volume uuid: String, relativePath relative: String) -> AssetAvailability {
        guard let volume = mountedVolume(uuid: uuid) else { return .offline(L10n.tr("The volume holding this original is not connected.")) }
        let url = volume.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? .available(url) : .offline(L10n.tr("The file is missing from \(volume.lastPathComponent)."))
    }
    /// Asks iCloud Drive for a file and waits until its contents are on this Mac, reporting iCloud's own progress.
    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        progress(0)
        let watch = await DownloadProgress(url)
        defer { Task { @MainActor in watch.stop() } }
        while !CatalogImporter.isDownloaded(url) {
            try await Task.sleep(for: .milliseconds(250))
            var current = url; current.removeAllCachedResourceValues()
            if let error = try? current.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]).ubiquitousItemDownloadingError { throw error }
            if let fraction = await watch.fraction { progress(min(fraction, 0.99)) }
        }
        progress(1)
        return url
    }
    /// The mount point of a connected volume, by UUID.
    public static func mountedVolume(uuid: String) -> URL? {
        #if !os(macOS)
        // iPadOS lists no volumes to apps; drives and cards are reached through the Files picker instead.
        return nil
        #else
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
            if (try? url.resourceValues(forKeys: keys))?.volumeUUIDString?.uppercased() == uuid.uppercased() { return url }
        }
        return nil
        #endif
    }
    static func volumeName(uuid: String) -> String? {
        mountedVolume(uuid: uuid).flatMap { (try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName }
    }
    /// Connected volumes a user might import from: cards, drives and mounted network shares.
    public struct MountedVolume: Identifiable, Hashable, Sendable {
        public let id: String
        public let url: URL
        public let name: String
        public let isRemovable: Bool
        public let isNetwork: Bool
        /// A DCIM folder marks a camera card; imports default to copying from it.
        public var isCameraCard: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path) }
    }
    public static func externalVolumes() -> [MountedVolume] {
        #if !os(macOS)
        return []
        #else
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeURLForRemountingKey, .volumeIsLocalKey]
        var result: [MountedVolume] = []
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [] {
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsRootFileSystem != true else { continue }
            let network = values.volumeIsLocal == false || values.volumeURLForRemounting != nil
            let removable = values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
            guard network || removable else { continue }
            result.append(MountedVolume(id: values.volumeUUIDString ?? url.path, url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                                        isRemovable: removable && !network, isNetwork: network))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        #endif
    }
}

/// iCloud's download progress for one file, from a metadata query; queries deliver updates on the main run loop.
@MainActor final class DownloadProgress {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    /// 0…1, once iCloud reports it.
    private(set) var fraction: Double?
    init(_ url: URL) {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemPathKey, url.standardizedFileURL.path)
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        query.start()
    }
    private func read() {
        query.disableUpdates(); defer { query.enableUpdates() }
        guard let item = query.results.first as? NSMetadataItem,
              let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double else { return }
        fraction = percent / 100
    }
    func stop() {
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
