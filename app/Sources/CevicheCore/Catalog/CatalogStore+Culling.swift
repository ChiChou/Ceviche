import Foundation
import GRDB

/// What the culling assistant measured on one photo's original, kept so the assistant opens again without measuring
/// the same photos twice. A per-Mac cache like the thumbnails: never synced, and dropped with the photo.
public struct CatalogCullingReport: Sendable {
    public let assetID: String
    public let report: PhotoQualityReport
    /// Archived `VNFeaturePrintObservation`, for burst grouping.
    public let featurePrint: Data?
    public init(assetID: String, report: PhotoQualityReport, featurePrint: Data?) {
        self.assetID = assetID; self.report = report; self.featurePrint = featurePrint
    }
}

extension CatalogStore {
    static func createCullingTable(_ db: Database) throws {
        try db.create(table: "cullingReport") { t in
            t.primaryKey("assetID", .text).references("asset", onDelete: .cascade)
            t.column("version", .text).notNull()
            // The original that was measured; a relinked or replaced one is measured again.
            t.column("origin", .text).notNull()
            t.column("fileSize", .integer)
            t.column("captureTime", .text)
            t.column("report", .blob).notNull()
            t.column("featurePrint", .blob)
            t.column("analyzedAt", .datetime).notNull()
        }
    }

    /// Reports of `version` for the photos whose original is still the one measured.
    public func cullingReports(_ assetIDs: [String], version: String = PhotoQualityAnalyzer.version) throws -> [String: CatalogCullingReport] {
        try database.read { db in
            var found: [String: CatalogCullingReport] = [:]
            let decoder = JSONDecoder()
            // SQLite's limit on bound values is far above a page of IDs; chunks keep a whole catalog within it.
            for chunk in stride(from: 0, to: assetIDs.count, by: 500).map({ Array(assetIDs[$0..<min($0 + 500, assetIDs.count)]) }) {
                let marks = databaseQuestionMarks(count: chunk.count)
                for row in try Row.fetchAll(db, sql: """
                    SELECT r.assetID, r.report, r.featurePrint FROM cullingReport r JOIN asset a ON a.id = r.assetID
                    WHERE r.version = ? AND r.origin = a.origin AND r.fileSize IS a.fileSize AND r.captureTime IS a.captureTime
                        AND r.assetID IN (\(marks))
                    """, arguments: StatementArguments([version] + chunk)) {
                    guard let report = try? decoder.decode(PhotoQualityReport.self, from: row["report"] as Data) else { continue }
                    found[row["assetID"]] = CatalogCullingReport(assetID: row["assetID"], report: report, featurePrint: row["featurePrint"])
                }
            }
            return found
        }
    }

    /// Records a measurement of `asset`'s original as it is in the catalog now.
    public func saveCullingReport(_ report: PhotoQualityReport, featurePrint: Data?, for asset: CatalogAsset, version: String = PhotoQualityAnalyzer.version) throws {
        let data = try JSONEncoder().encode(report)
        try database.write { db in
            guard try CatalogAsset.exists(db, key: asset.id) else { return }
            try db.execute(sql: """
                INSERT INTO cullingReport(assetID, version, origin, fileSize, captureTime, report, featurePrint, analyzedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(assetID) DO UPDATE SET version = excluded.version, origin = excluded.origin, fileSize = excluded.fileSize,
                    captureTime = excluded.captureTime, report = excluded.report, featurePrint = excluded.featurePrint, analyzedAt = excluded.analyzedAt
                """, arguments: [asset.id, version, asset.origin, asset.fileSize, asset.captureTime, data, featurePrint, Date()])
        }
    }
}
