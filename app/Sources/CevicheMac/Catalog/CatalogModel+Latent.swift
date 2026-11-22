import Foundation
import CevicheCore

/// Saving tool work as latent images, for the tools that keep no analysis: the package is a manifest, a thumbnail and a preview.
extension CatalogModel {
    /// A reference to `asset`'s original as it is now, for a latent image's sources.
    func latentSource(_ asset: CatalogAsset) async throws -> LatentImage.Source {
        let url = try await resolveOriginal(asset)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try LatentImage.Source(assetID: asset.id, url: url)
    }

    /// Writes `latent` into the latent image `latentAssetID`, which keeps its identity, or files it in the catalog as a
    /// new one named `name`, dated by its newest source. Returns the latent image's asset ID.
    @discardableResult
    func storeLatent(_ latent: LatentImage, pictures: LatentImage.Pictures, name: String, sources: [CatalogAsset], into latentAssetID: String?,
                     store: CatalogStore) async throws -> String {
        guard self.store === store else { throw CancellationError() }
        var latent = latent
        let id: String
        if let latentAssetID {
            let bundle = CatalogImporter.sourceURL(for: try await store.asset(latentAssetID), root: store.root)
            let current = try await Task.detached(priority: .utility) { try LatentImage.load(bundle) }.value
            guard current.type == latent.type else { throw LatentImage.invalid() }
            latent.id = current.id; latent.catalogID = current.catalogID
            let saved = latent
            try await Task.detached(priority: .utility) { try saved.save(to: bundle, pictures: pictures) }.value
            try await store.updateLatent(assetID: latentAssetID, thumbnail: pictures.thumbnail)
            id = latentAssetID
        } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Latent \(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let bundle = folder.appendingPathComponent("\(name).\(LatentImage.fileExtension)")
            var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
            options.objectCaptureDay = sources.map(\.captureDay).max()
            let saved = latent
            var prepared = try await Task.detached(priority: .utility) { [options] in
                try saved.save(to: bundle, pictures: pictures)
                return try CatalogImporter.prepareLatent(bundle, options: options)
            }.value
            prepared.0.captureTime = sources.compactMap(\.captureTime).max()
            id = try await store.insertCompletedOutput(prepared.0, thumbnail: pictures.thumbnail).id
        }
        if self.store === store { await refresh(); syncSoon() }
        return id
    }
}

/// Whether a tool's outputs also keep its work as a latent image: each tool remembers its own, off until ticked. A
/// window opened from a latent image always keeps it up to date.
enum LatentPreference {
    static func key(_ type: String) -> String { "keepLatent.\(type)" }
    static func keeps(_ type: String, _ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key(type)) }
}
