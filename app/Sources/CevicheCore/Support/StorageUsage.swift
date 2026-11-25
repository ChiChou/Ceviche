import Foundation

/// What the app keeps on this device, by kind, for the Storage screen: the catalog's photos and previews, the cache
/// that can be cleared, and the downloaded models.
public struct StorageUsage: Equatable, Sendable {
    /// Imported originals the catalog keeps in its own folder; nil for a catalog that only refers to files elsewhere.
    public var photos: Int64?
    /// Thumbnails and previews, made again as they are needed.
    public var previews: Int64?
    /// Decoded RAWs, kept so recent photos open without decoding again: cleared without losing anything.
    public var cache: Int64
    /// Models downloaded or added from a file; the built-in ones are part of the app.
    public var models: Int64

    /// Measures it off the main thread. `catalog` is the catalog folder whose photos and previews count.
    public static func measure(catalog: URL?) async -> StorageUsage {
        await Task.detached(priority: .utility) {
            let originals = catalog?.appendingPathComponent("Originals", isDirectory: true)
            let previews = catalog.map { root in
                ["", "-wal", "-shm"].reduce(Int64(0)) { $0 + size(of: root.appendingPathComponent(PreviewStore.filename + $1)) }
            }
            return StorageUsage(photos: originals.map(size(of:)), previews: previews, cache: cacheSize(),
                                models: size(of: ModelLibrary.defaultDirectory))
        }.value
    }

    /// Removes every decode and gives what is left. Working files a tool is using stay; those left behind go at launch.
    public static func clearCache() async -> Int64 {
        await Task.detached(priority: .userInitiated) {
            DecodeCache.trim(limit: 0)
            return cacheSize()
        }.value
    }

    /// The decoded RAWs.
    static func cacheSize() -> Int64 { DecodeCache.folder.map(size(of:)) ?? 0 }

    /// A file's or folder's size on disk; 0 when it isn't there.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            if let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
