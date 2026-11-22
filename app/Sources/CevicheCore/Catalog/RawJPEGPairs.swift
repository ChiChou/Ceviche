import Foundation

/// A camera set to RAW + JPEG (or RAW + HEIF, which Sony and Canon name `.HIF`) writes both files of one shot side by
/// side under one name. They are one photograph: culling decides about them together, and the photographer chooses
/// which of the two to keep.
public enum RawJPEGPairs {
    /// The camera-rendered half of a pair.
    public static let processedExtensions: Set<String> = ["jpg", "jpeg", "hif", "heif", "heic"]

    /// Pairs among files known by path or locator string: a RAW and a processed file in the same folder with the same
    /// name, compared without case. A name with more than one of either kind is left alone. Indices into `items`.
    public static func pairs<Item>(_ items: [Item], path: (Item) -> String) -> [(raw: Int, processed: Int)] {
        var raws: [String: [Int]] = [:], processed: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            let file = path(item) as NSString
            let ext = file.pathExtension.lowercased(), key = file.deletingPathExtension.lowercased()
            if CatalogImporter.rawExtensions.contains(ext) { raws[key, default: []].append(index) }
            else if processedExtensions.contains(ext) { processed[key, default: []].append(index) }
        }
        return raws.compactMap { key, raw in
            guard raw.count == 1, let match = processed[key], match.count == 1 else { return nil }
            return (raw[0], match[0])
        }.sorted { $0.raw < $1.raw }
    }

    /// Pairs among catalog photos, by where each original was read from; both halves must also share a capture time
    /// when both have one, so a renamed or later file with the same name is not taken for the other half.
    public static func pairs(_ assets: [CatalogAsset]) -> [(raw: CatalogAsset, processed: CatalogAsset)] {
        pairs(assets) { $0.sourcePath }.compactMap { raw, processed in
            let a = assets[raw], b = assets[processed]
            if let first = a.captureTime, let second = b.captureTime, first != second { return nil }
            return (a, b)
        }
    }
}
