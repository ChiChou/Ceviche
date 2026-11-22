import Foundation
import GRDB

extension CatalogStore {
    /// Takes photos out of the library into the archive (`CatalogAsset.archivedAt`), leaving their files where they
    /// are. Photos already archived or in the Trash are skipped. Returns the IDs archived.
    @discardableResult
    public func archive(_ assetIDs: [String]) throws -> [String] {
        try database.write { db in
            var archived: [String] = []
            let now = Date()
            for assetID in Set(assetIDs) {
                guard let asset = try CatalogAsset.fetchOne(db, key: assetID), asset.inLibrary else { continue }
                try CatalogAsset.filter(key: assetID).updateAll(db, CatalogAsset.Columns.archivedAt.set(to: now), CatalogAsset.Columns.updatedAt.set(to: now))
                // Removing the lease also rejects a late result from a worker already in flight.
                try CatalogAnalysisJob.deleteOne(db, key: assetID)
                archived.append(assetID)
            }
            if !archived.isEmpty { try Self.analysisChanged(db) }
            return archived
        }
    }
    /// Puts archived photos back in the library.
    public func unarchive(_ assetIDs: [String]) throws {
        try database.write { db in
            let now = Date()
            var changed = false
            for assetID in Set(assetIDs) {
                guard let asset = try CatalogAsset.fetchOne(db, key: assetID), asset.archivedAt != nil else { continue }
                try CatalogAsset.filter(key: assetID).updateAll(db, CatalogAsset.Columns.archivedAt.set(to: nil), CatalogAsset.Columns.updatedAt.set(to: now))
                if asset.trashedAt == nil, asset.analysisOrigin == "local", asset.analysisVersion != CatalogImporter.analysisVersion {
                    try Self.enqueueAnalysis(db, assetID: assetID, version: CatalogImporter.analysisVersion, priority: 0)
                }
                changed = true
            }
            if changed { try Self.analysisChanged(db) }
        }
    }
}
