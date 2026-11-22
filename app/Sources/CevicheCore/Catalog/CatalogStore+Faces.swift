import CoreGraphics
import Foundation
import GRDB
import ImageIO

/// A face background analysis found in a photo (`CatalogImporter.classifyLabels`): where it is, and what Vision made
/// of it. One row per face in `assetFace`; a photo's `faceCount` is the number of its rows.
public struct CatalogFace: Codable, Equatable, Sendable {
    /// Proportions of the upright photo, top-left origin, as `PhotoQualityReport.Face.bounds`.
    public var bounds: CGRect
    /// How well Vision's landmark outline fits, 0 to 1: real faces 0.82 and up, a "face" in dark rock 0.71.
    public var landmarks: Double?
    /// Vision's face capture quality, 0 to 1; meant for comparing shots of the same person.
    public var quality: Double?
    /// Height over width of each eye's outline, as `PhotoQualityReport.Face`.
    public var leftEye: Double?
    public var rightEye: Double?
    public init(bounds: CGRect, landmarks: Double? = nil, quality: Double? = nil, leftEye: Double? = nil, rightEye: Double? = nil) {
        self.bounds = bounds; self.landmarks = landmarks; self.quality = quality; self.leftEye = leftEye; self.rightEye = rightEye
    }
    /// The landmark fit below which the culling measure drops a face.
    public static let landmarkMinimum = 0.75
    /// Faces narrower than this share of the photo are crowds and passers-by: counted, but left off the Faces wall.
    public static let wallWidth = 0.03
    /// Large and face-like enough to judge its eyes and focus on, by the rules of the culling measure.
    public var judged: Bool { bounds.width >= PhotoQualityReport.Face.judgedWidth && (landmarks ?? 0) >= Self.landmarkMinimum }
    /// The face as the culling measure describes one, without the sharpness only that measure takes.
    public var qualityFace: PhotoQualityReport.Face { PhotoQualityReport.Face(bounds: bounds, quality: quality, leftEye: leftEye, rightEye: rightEye) }
}

/// One tile of the Faces wall.
public struct CatalogFaceEntry: Identifiable, Equatable, Sendable {
    public var assetID: String
    /// The face's place in its photo, left to right.
    public var index: Int
    public var face: CatalogFace
    public var captureDay: String
    /// Who the face is, once People has grouped it.
    public var personID: String?
    /// Placed or taken out by hand.
    public var pinned = false
    public var id: String { "\(assetID)/\(index)" }
    public var key: CatalogFaceKey { CatalogFaceKey(assetID: assetID, index: index) }
}

extension CatalogStore {
    static func createFaceTable(_ db: Database) throws {
        try db.create(table: "assetFace", options: .withoutRowID) { t in
            t.column("assetID", .text).notNull().references("asset", onDelete: .cascade)
            t.column("idx", .integer).notNull()
            t.column("x", .double).notNull()
            t.column("y", .double).notNull()
            t.column("width", .double).notNull()
            t.column("height", .double).notNull()
            t.column("landmarks", .double)
            t.column("quality", .double)
            t.column("leftEye", .double)
            t.column("rightEye", .double)
            t.primaryKey(["assetID", "idx"])
        }
    }

    /// Replaces a photo's faces and keeps `faceCount` to their number; nil means not analysed for faces. A new face
    /// where an old one was keeps its person (and its embedding, when the box is all but the same), so analysing a
    /// photo again or syncing its boxes never undoes People.
    static func setFaces(_ faces: [CatalogFace]?, assetID: String, _ db: Database) throws {
        let before = try Row.fetchAll(db, sql: "SELECT * FROM assetFace WHERE assetID = ?", arguments: [assetID])
        try db.execute(sql: "DELETE FROM assetFace WHERE assetID = ?", arguments: [assetID])
        let found = faces ?? []
        let carried = carry(before, to: found.map(\.bounds))
        for (index, face) in found.enumerated() {
            let b = face.bounds
            let old = carried[index]
            let keepsEmbedding = (old?.overlap ?? 0) >= 0.9
            try db.execute(sql: """
                INSERT INTO assetFace(assetID, idx, x, y, width, height, landmarks, quality, leftEye, rightEye, personID, pinned, embedding, embeddingRevision)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [assetID, index, b.minX, b.minY, b.width, b.height, face.landmarks, face.quality, face.leftEye, face.rightEye,
                                 old?.row["personID"] as String?, (old?.row["pinned"] as Bool?) ?? false,
                                 keepsEmbedding ? old?.row["embedding"] as Data? : nil, keepsEmbedding ? old?.row["embeddingRevision"] as Int? : nil])
        }
        try CatalogAsset.filter(key: assetID).updateAll(db, Column(faceCountColumn).set(to: faces?.count))
    }

    /// For each new box, the old face it replaces: pairs overlapping by half or more, closest first, each used once.
    static func carry(_ old: [Row], to boxes: [CGRect]) -> [Int: (row: Row, overlap: Double)] {
        let oldBoxes = old.map { face($0).bounds }
        var pairs: [(new: Int, old: Int, overlap: Double)] = []
        for (i, box) in boxes.enumerated() {
            for (j, previous) in oldBoxes.enumerated() {
                let o = overlap(box, previous)
                if o >= 0.5 { pairs.append((i, j, o)) }
            }
        }
        var result: [Int: (row: Row, overlap: Double)] = [:]
        var used = Set<Int>()
        for pair in pairs.sorted(by: { $0.overlap > $1.overlap }) where result[pair.new] == nil && !used.contains(pair.old) {
            result[pair.new] = (old[pair.old], pair.overlap); used.insert(pair.old)
        }
        return result
    }
    /// Intersection over union.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let shared = i.width * i.height
        return Double(shared / (a.width * a.height + b.width * b.height - shared))
    }
    static func face(_ row: Row) -> CatalogFace {
        CatalogFace(bounds: CGRect(x: row["x"] as Double, y: row["y"] as Double, width: row["width"] as Double, height: row["height"] as Double),
                    landmarks: row["landmarks"], quality: row["quality"], leftEye: row["leftEye"], rightEye: row["rightEye"])
    }

    /// Each photo's faces, left to right. A photo not analysed yet, or without faces, is absent.
    public func faces(_ assetIDs: [String]) throws -> [String: [CatalogFace]] {
        guard !assetIDs.isEmpty else { return [:] }
        return try database.read { db in
            var found: [String: [CatalogFace]] = [:]
            let list = String(decoding: try JSONEncoder().encode(assetIDs), as: UTF8.self)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM assetFace WHERE assetID IN (SELECT value FROM json_each(?)) ORDER BY assetID, idx", arguments: [list]) {
                found[row["assetID"], default: []].append(Self.face(row))
            }
            return found
        }
    }

    /// The faces of the photos matching `filter`, in its order, leaving out those narrower than `minimumWidth`.
    public func faceEntries(filter: CatalogFilter, minimumWidth: Double = CatalogFace.wallWidth) throws -> [CatalogFaceEntry] {
        try database.read { db in
            let ids = try Self.query(filter).select(Columns.id, as: String.self).order(Self.ordering(filter)).fetchAll(db)
            let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            // The photos' order is the list's; `key` keeps it through the join.
            return try Row.fetchAll(db, sql: """
                SELECT f.*, a.captureDay FROM json_each(?) j JOIN assetFace f ON f.assetID = j.value JOIN asset a ON a.id = f.assetID
                WHERE f.width >= ? ORDER BY j.key, f.idx
                """, arguments: [list, minimumWidth]).map {
                CatalogFaceEntry(assetID: $0["assetID"], index: $0["idx"], face: Self.face($0), captureDay: $0["captureDay"], personID: $0["personID"], pinned: $0["pinned"])
            }
        }
    }

    /// Photos that would match `filter` but have not been analysed for faces yet.
    public func unanalysedFaceCount(filter: CatalogFilter) throws -> Int {
        var filter = filter; filter.withFaces = false; filter.faces = nil
        return try database.read { try Self.query(filter).filter(Column(Self.faceCountColumn) == nil && CatalogAsset.Columns.kind != LatentImage.kind).fetchCount($0) }
    }
}

extension FaceCrops {
    /// A stand-in tile cut from the library thumbnail, for a face whose tile isn't made yet (analysed on another Mac).
    public static func tile(from thumbnail: CGImage, face: CGRect) -> CGImage? {
        let region = tileRegion(face: face, imageSize: CGSize(width: thumbnail.width, height: thumbnail.height)).integral
        return thumbnail.cropping(to: region)
    }
    private static let wallTileGate = DispatchSemaphore(value: 2)
    /// Long edge of a Faces wall tile: the largest tile, at 2x, does not upscale it.
    public static let wallTilePixels = 256
    /// JPEG tiles of the faces wide enough for the wall, cut from the original at `wallTilePixels`, keyed by the
    /// face's place in `faces`. Only photos with such a face read the original again.
    public static func wallTiles(at url: URL, faces: [CatalogFace]) -> [Int: Data] {
        let shown = faces.indices.filter { faces[$0].bounds.width >= CatalogFace.wallWidth }
        guard !shown.isEmpty else { return [:] }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        // A RAW cut at its reduced scale still takes 150-300 MB while it renders; two at a time keeps the index
        // service's four workers from stacking four of them.
        wallTileGate.wait(); defer { wallTileGate.signal() }
        let images = autoreleasepool { tiles(at: url, faces: shown.map { faces[$0].bounds }, pixels: wallTilePixels) }
        var found: [Int: Data] = [:]
        for (index, image) in zip(shown, images) { if let image, let data = CatalogImporter.encodeThumbnail(image) { found[index] = data } }
        return found
    }
}
