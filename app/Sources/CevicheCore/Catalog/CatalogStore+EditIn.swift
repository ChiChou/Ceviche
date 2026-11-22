import Foundation
import GRDB

/// Photos rendered for another app (Edit In), whose files that app saves over.
extension CatalogStore {
    /// The photos whose filename carries `suffix`, outside the Trash: the candidates for a save from the other app.
    public func photosEditedElsewhere(suffix: String) throws -> [CatalogAsset] {
        try database.read { db in
            try CatalogAsset.filter(Columns.area(.library) && Columns.filename.like("%\(suffix)%")).fetchAll(db)
        }
    }
    /// Takes the file's new size, dimensions, camera and properties from `fresh` (the file prepared again), so the
    /// photo opens as the other app left it, and drops the old thumbnail. The file is burnt: development and its
    /// history go, since they were made on pixels that are no longer there. Metadata stays. This is the one case where
    /// a photo's EXIF is written again: the other app saved a new file in its place. Returns the photo.
    @discardableResult
    public func refreshOriginal(_ assetID: String, from fresh: CatalogPhoto) throws -> CatalogAsset {
        try database.write { db in
            guard var asset = try CatalogAsset.fetchOne(db, key: assetID) else { throw EditorError.invalidDocument(L10n.tr("The photo is no longer in the catalog.")) }
            asset.infoData = fresh.infoData; asset.camera = fresh.asset.camera; asset.hdr = fresh.asset.hdr
            asset.fileSize = fresh.fileSize; asset.captureTime = fresh.captureTime
            asset.xmpWarnings = ""
            asset.renderKey = UUID().uuidString; asset.thumbnailKey = nil; asset.thumbnailRenderKey = nil
            asset.originalUpdatedAt = Date(); asset.developmentUpdatedAt = asset.originalUpdatedAt
            try asset.update(db)
            try CatalogExif(assetID: assetID, extractedMetadata: fresh.extractedMetadata).update(db)
            try CatalogDevelopment(assetID: assetID).update(db)
            try CatalogRevision.filter(CatalogRevision.Columns.assetID == assetID && CatalogRevision.Columns.kind == CatalogRevision.Kind.edit).deleteAll(db)
            try Self.removeStaleBlobs(of: assetID, db)
            return asset
        }
    }
}
