import CoreGraphics
import Foundation

/// Embeds the faces of the Faces wall and groups them into people, in the app's own process: Vision's five points and
/// SFace take about 15 ms a face from its wall tile, so no original is read unless the tile is missing.
public enum PeopleIndex {
    public enum Outcome: Equatable, Sendable {
        /// Nothing left to embed; grouping is up to date.
        case idle
        /// Faces were embedded or grouped; there may be more.
        case progressed(embedded: Int, grouped: Bool)
        /// The People model is not installed.
        case unavailable
    }

    /// Embeds up to `batch` faces and groups everything embedded so far.
    public static func run(store: CatalogStore, batch: Int = 64) async throws -> Outcome {
        guard FaceEmbedding.isAvailable else { return .unavailable }
        let faces = try await store.facesNeedingEmbedding(limit: batch)
        guard !faces.isEmpty else {
            let grouped = try await store.groupPeople()
            return grouped ? .progressed(embedded: 0, grouped: true) : .idle
        }
        var results: [(face: CatalogFaceToEmbed, vector: [Float]?)] = []
        for (assetID, group) in Dictionary(grouping: faces, by: \.key.assetID) {
            try Task.checkCancellation()
            var tiles: [Int: Data] = [:]
            for face in group { if let data = try await store.previews.faceTile(assetID: assetID, index: face.key.index) { tiles[face.key.index] = data } }
            if tiles.count < group.count, let cut = try await cutTiles(store: store, asset: group[0].asset) {
                tiles.merge(cut) { kept, _ in kept }
            }
            let embedded: [(CatalogFaceToEmbed, [Float]?)] = try await Task.detached(priority: .utility) {
                try group.map { face in
                    try autoreleasepool { (face, try tiles[face.key.index].flatMap { try FaceEmbedding.embed(tileData: $0) }) }
                }
            }.value
            results.append(contentsOf: embedded)
        }
        try await store.saveEmbeddings(results)
        let grouped = try await store.groupPeople()
        return .progressed(embedded: results.count, grouped: grouped)
    }

    /// The photo's wall tiles cut again from its original and kept for the wall too; nil when the original is not on
    /// this Mac.
    static func cutTiles(store: CatalogStore, asset: CatalogAsset) async throws -> [Int: Data]? {
        let url = CatalogImporter.sourceURL(for: asset, root: store.root)
        guard CatalogImporter.isDownloaded(url), FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let faces = try await store.faces([asset.id])[asset.id], !faces.isEmpty else { return nil }
        let tiles = await Task.detached(priority: .utility) { FaceCrops.wallTiles(at: url, faces: faces) }.value
        guard !tiles.isEmpty else { return nil }
        try? await store.previews.installFaceTiles(tiles, assetID: asset.id)
        return tiles
    }
}
