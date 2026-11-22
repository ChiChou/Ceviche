import Foundation

/// Duplicate: a second original on disk beside the first, added as a photo of its own with the same development and
/// metadata, so the two can be developed apart.
extension CatalogImporter {
    /// The first free name beside `url`: `name-copy.ext`, then `name-copy-2.ext` and so on.
    public static func duplicateURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        func named(_ name: String) -> URL { folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)") }
        var candidate = named("\(stem)-copy"), number = 2
        while FileManager.default.fileExists(atPath: candidate.path) { candidate = named("\(stem)-copy-\(number)"); number += 1 }
        return candidate
    }

    /// Copies the original of `asset`, found at `url`, beside it (FileManager clones it on APFS, so the copy shares the
    /// original's blocks until either changes), and returns the copy with its `catalog:` locator when
    /// it is inside the catalog (nil for a file referenced in place). A copy of an original stored inside the catalog
    /// stays there; one whose folder can't be written, such as a locked card, goes into the catalog's originals in
    /// `originalsRoot`, as Copy imports do.
    public static func duplicateOriginal(of asset: CatalogAsset, at url: URL, originalsRoot: URL) throws -> (URL, AssetLocator?) {
        if case .catalog(let relative) = asset.locator {
            let destination = duplicateURL(for: url)
            try FileManager.default.copyItem(at: url, to: destination)
            let folder = (relative as NSString).deletingLastPathComponent
            return (destination, .catalog(relativePath: folder.isEmpty ? destination.lastPathComponent : folder + "/" + destination.lastPathComponent))
        }
        if FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) {
            let destination = duplicateURL(for: url)
            try FileManager.default.copyItem(at: url, to: destination)
            return (destination, nil)
        }
        let month = asset.captureDay.count >= 7 ? String(asset.captureDay.prefix(7)) : "Undated"
        let folder = originalsRoot.appendingPathComponent("Originals").appendingPathComponent(month)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = duplicateURL(for: folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.copyItem(at: url, to: destination)
        return (destination, .catalog(relativePath: "Originals/\(month)/\(destination.lastPathComponent)"))
    }
}

extension CatalogStore {
    /// Adds `copy`, a duplicate of `source`'s original, as a photo of its own with `source`'s development, metadata,
    /// imported XMP and thumbnail. `locator` is the copy's place in the catalog for originals stored inside it.
    public func duplicate(_ source: CatalogAsset, as copy: URL, locator: AssetLocator?) async throws -> CatalogAsset {
        let current = try asset(source.id)
        var (asset, thumbnail) = try CatalogImporter.prepare(copy, options: CatalogImporter.ImportOptions(mode: .reference, locator: locator))
        if let locator, case .catalog = locator { asset.importPath = locator.string; asset.isCopy = true }
        asset.importBatchID = UUID().uuidString
        asset.metadata = current.metadata
        asset.adjustmentsData = try savedAdjustments(of: current).map { try JSONEncoder().encode($0) }
        asset.xmpData = try development(source.id).xmpData; asset.xmpWarnings = current.xmpWarnings
        // The same file develops from the same defaults, including those an imported sidecar set.
        var info = asset.info
        info.defaults = current.info.defaults
        asset.infoData = try info.storedData()
        // The source's thumbnail already shows the development the copy starts with.
        return try await insert(asset, thumbnail: try await previews.data(assetID: current.id) ?? thumbnail)
    }
}
