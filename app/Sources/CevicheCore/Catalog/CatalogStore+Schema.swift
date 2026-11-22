import Foundation
import CoreImage
import GRDB
import Synchronization

/// Creating and upgrading the catalog database.
extension CatalogStore {
    /// `asset` holds what browsing, search and filters read. The large values only a view of one photo needs are
    /// apart, by how often they change: the EXIF in `assetExif`, never, and the development and XMP in
    /// `assetDevelopment`, on every edit. A scan of `asset` stays small and an autosave rewrites only its own row.
    static func createAssetTables(_ db: Database) throws {
        try db.create(table: "asset") { t in
            t.primaryKey("id", .text)
            t.column("importPath", .text).notNull().unique()
            // Where the original lives (`AssetLocator`), the path and bookmark it resolves through, whether it is a
            // copy the importer made, and the size and capture time that identify it.
            t.column("origin", .text).notNull()
            t.column("sourcePath", .text).notNull()
            // The directory of the original, so showing a folder seeks to its photos however large the catalog is
            // (`asset_folder`). Virtual: the index holds the values.
            t.column("folder", .text).generatedAs(sql: Self.folderSQL, .virtual)
            t.column("isCopy", .boolean).notNull().defaults(to: false)
            t.column("fileSize", .integer)
            t.column("filename", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("captureDay", .text).notNull()
            t.column("captureTime", .text)
            for name in ["title", "caption", "keywords", "suggestedTags"] { t.column(name, .text).notNull() }
            t.column("review", .text).notNull().check(sql: "review IN (\(ReviewState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")))")
            t.column("rating", .integer).notNull().check { (0...5).contains($0) }
            t.column("latitude", .double)
            t.column("longitude", .double)
            for name in ["placeCountry", "placeRegion", "placeCity", "placeSource"] { t.column(name, .text) }
            // Where the location came from (`CatalogLocationSource`).
            t.column("locationSource", .text)
            for name in ["cameraMake", "cameraModel", "lensMake", "lensModel", "artist"] { t.column(name, .text) }
            for name in ["focalLength", "focalLength35mm", "fNumber", "exposureTime"] { t.column(name, .double) }
            t.column("iso", .integer)
            t.column("exposureBias", .double)
            t.column("flashFired", .boolean)
            // Worked out by SQLite, so no writer keeps them: the file name's extension (ARW, RAF…; `kind` is only
            // RAW) and the pixel size the photo is shown at. `aspect`, the width over height of the development
            // as shown, after its crop and quarter turns, is kept by triggers from `assetDevelopment`.
            t.column("fileExtension", .text).generatedAs(sql: Self.extensionSQL, .stored)
            t.column("width", .integer).generatedAs(sql: Self.infoSQL("width"), .stored)
            t.column("height", .integer).generatedAs(sql: Self.infoSQL("height"), .stored)
            t.column("aspect", .double)
            // The group the photo was put in (`CatalogAsset.stackID`).
            t.column("stackID", .text)
            t.column("trashedAt", .datetime)
            // Set when the photo is archived (`CatalogArea.archive`): out of the library like the Trash, its file untouched.
            t.column("archivedAt", .datetime)
            // A `CatalogLabel`; nil for none.
            t.column("label", .text).check(sql: "label IN (\(CatalogLabel.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")))")
            t.column("importedAt", .datetime).notNull()
            t.column("importBatchID", .text)
            // When each part of the photo last changed, here or on another Mac: the clocks iCloud sync compares
            // (`CatalogAsset.updatedAt` and the others), so a rating made on one Mac and an edit on another both stay.
            t.column("updatedAt", .datetime).notNull()
            t.column("developmentUpdatedAt", .datetime).notNull()
            t.column("originalUpdatedAt", .datetime).notNull()
            // Last development change made by the person, for Recent Edits; culling, metadata and cache writes never advance it.
            t.column("lastEditedAt", .datetime)
            // Background tagging: which build analysed the photo, on which Mac (`CatalogAsset.analysisOrigin`) and when.
            t.column("analysisVersion", .text)
            t.column("analysisOrigin", .text).notNull().defaults(to: "local")
            t.column("analyzedAt", .datetime)
            // The faces background tagging found; nil until it has looked, so a photo not analysed yet is neither one
            // with faces nor one without. Always the number of the photo's `assetFace` rows.
            t.column(faceCountColumn, .integer)
            // Whether the photo opens in HDR, found once at import (`CatalogAsset.hdr`).
            t.column("hdr", .boolean)
            t.column("thumbnailKey", .text)
            t.column("thumbnailRenderKey", .text)
            t.column("renderKey", .text).notNull()
            t.column("xmpWarnings", .text).notNull().defaults(to: "")
            t.column("bookmark", .blob)
            t.column("infoData", .blob).notNull()
        }
        // Written once: a photo's EXIF doesn't change.
        try db.create(table: "assetExif") { t in
            t.primaryKey("assetID", .text).references("asset", onDelete: .cascade)
            t.column("extractedMetadata", .blob).notNull()
        }
        // Rewritten on every edit, so an autosave doesn't rewrite the EXIF too.
        try db.create(table: "assetDevelopment") { t in
            t.primaryKey("assetID", .text).references("asset", onDelete: .cascade)
            t.column("adjustmentsData", .blob)
            t.column("xmpData", .blob)
        }
        try db.create(index: "asset_review_rating", on: "asset", columns: ["review", "rating"])
        try db.create(index: "asset_last_edit", on: "asset", columns: ["lastEditedAt", "id"])
        try db.create(index: "asset_import_batch", on: "asset", columns: ["importBatchID", "importedAt"])
        // The grid's queries: browsing in capture order and the day, month and year groups, and the file-type
        // filter in the same order.
        try db.create(index: "asset_browse", on: "asset", columns: ["trashedAt", "captureDay", "captureTime", "id"])
        try db.create(index: "asset_kind", on: "asset", columns: ["trashedAt", "kind", "captureDay", "captureTime", "id"])
        try db.create(index: "asset_stack", on: "asset", columns: ["stackID"])
        try db.create(index: "asset_label", on: "asset", columns: ["label"])
        try db.create(index: "asset_archived", on: "asset", columns: ["archivedAt"])
        // The range filters: focal length, aperture, shutter speed, ISO, extension and orientation.
        for column in ["focalLength", "fNumber", "exposureTime", "iso", "fileExtension", "aspect"] {
            try db.create(index: "asset_\(column)", on: "asset", columns: [column])
        }
        let aspect = "UPDATE asset SET aspect = \(aspectSQL) WHERE id = "
        try db.execute(sql: """
            CREATE TRIGGER asset_aspect_insert AFTER INSERT ON asset BEGIN \(aspect)NEW.id; END;
            CREATE TRIGGER asset_aspect_info AFTER UPDATE OF infoData ON asset BEGIN \(aspect)NEW.id; END;
            CREATE TRIGGER assetDevelopment_aspect_insert AFTER INSERT ON assetDevelopment BEGIN \(aspect)NEW.assetID; END;
            CREATE TRIGGER assetDevelopment_aspect_update AFTER UPDATE OF adjustmentsData ON assetDevelopment BEGIN \(aspect)NEW.assetID; END;
            """)
    }
    static let extensionSQL = "CASE WHEN instr(filename, '.') > 0 THEN upper(substr(filename, length(rtrim(filename, replace(filename, '.', ''))) + 1)) END"
    /// A value of the photo's `ImageInfo`; nil where it isn't JSON.
    static func infoSQL(_ key: String) -> String {
        "CAST(json_extract(CAST(infoData AS TEXT), '$.\(key)') AS INTEGER)"
    }
    /// The shown width over height for the `asset` row being updated: its size, and the crop and quarter turns of
    /// its development in `assetDevelopment`.
    static var aspectSQL: String {
        let stored = "(SELECT CAST(adjustmentsData AS TEXT) FROM assetDevelopment WHERE assetDevelopment.assetID = asset.id)"
        let development = "CASE WHEN json_valid(\(stored)) THEN \(stored) END"
        let ratio = "(width * coalesce(json_extract(\(development), '$.geometry.crop.width'), 1.0)) / (height * coalesce(json_extract(\(development), '$.geometry.crop.height'), 1.0))"
        return "CASE WHEN width > 0 AND height > 0 THEN CASE WHEN abs(coalesce(json_extract(\(development), '$.quarterTurns'), 0)) % 2 = 1 THEN 1.0 / (\(ratio)) ELSE \(ratio) END END"
    }
    /// Returns pages that deletions freed to the file system.
    public func reclaimSpace() throws {
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
    }
}
