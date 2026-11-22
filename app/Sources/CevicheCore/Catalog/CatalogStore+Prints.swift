import Foundation
import GRDB
import ImageIO
import Vision

/// Each photo's Vision feature print, from background analysis (`CatalogImporter.classifyLabels`): Apple's own measure
/// of what a picture shows, for Show Similar and Duplicates. Stored as the print's 768 values at half precision
/// (1.5 KB a photo), not as an archived Vision object: the distance Vision computes between two prints is the Euclidean
/// distance between these values, and comparing plain numbers is what lets a whole library be searched in a moment.
/// Measured on a night group: a copy saved again as JPEG 0.09, the next frame of a burst 0.21, the same photo half size
/// and brighter 0.25, the same group re-arranged 0.42, another shot 0.85. A per-Mac cache, never synced.
extension CatalogStore {
    static func createPrintTable(_ db: Database) throws {
        try db.create(table: "assetPrint", options: .withoutRowID) { t in
            t.column("assetID", .text).primaryKey().references("asset", onDelete: .cascade)
            t.column("revision", .integer).notNull()
            t.column("vector", .blob).notNull()
        }
    }

    /// Library photos without a print of the current revision, newest imports first, for the backfill that prints the
    /// photos analysed before prints were kept (`CatalogIndexWorker.runPrintBackfill`).
    public func photosNeedingPrint(limit: Int) throws -> [CatalogAsset] {
        try database.read { db in
            try CatalogAsset.fetchAll(db, sql: """
                SELECT * FROM asset a WHERE a.trashedAt IS NULL AND a.archivedAt IS NULL AND a.kind != ?
                AND NOT EXISTS (SELECT 1 FROM assetPrint p WHERE p.assetID = a.id AND p.revision = ?)
                ORDER BY a.importedAt DESC LIMIT ?
                """, arguments: [LatentImage.kind, CatalogPrint.revision, limit])
        }
    }
    /// Stores a print made outside analysis; `nil` records that the photo couldn't be printed (an empty vector, never
    /// searched), so the backfill moves on. Analysing the photo again replaces either.
    public func savePrint(_ print: CatalogPrint?, assetID: String) throws {
        try database.write { db in
            guard try CatalogAsset.filter(key: assetID).fetchCount(db) > 0 else { return }
            if let print { try Self.setPrint(print, assetID: assetID, db) }
            else { try db.execute(sql: "INSERT OR REPLACE INTO assetPrint(assetID, revision, vector) VALUES (?, ?, ?)", arguments: [assetID, CatalogPrint.revision, Data()]) }
        }
    }

    /// Replaces the photo's print; nil removes it.
    static func setPrint(_ print: CatalogPrint?, assetID: String, _ db: Database) throws {
        guard let print else { try db.execute(sql: "DELETE FROM assetPrint WHERE assetID = ?", arguments: [assetID]); return }
        try db.execute(sql: "INSERT OR REPLACE INTO assetPrint(assetID, revision, vector) VALUES (?, ?, ?)",
                       arguments: [assetID, print.revision, print.vector])
    }

    /// Every library photo's print of the current revision, for searching: photos in the Trash or the archive, and
    /// prints of another macOS's revision (not comparable), are left out.
    public func printIndex() throws -> CatalogPrintIndex {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.assetID, p.vector FROM assetPrint p JOIN asset a ON a.id = p.assetID
                WHERE p.revision = ? AND a.trashedAt IS NULL AND a.archivedAt IS NULL
                """, arguments: [CatalogPrint.revision])
            var index = CatalogPrintIndex()
            index.ids.reserveCapacity(rows.count)
            index.values.reserveCapacity(rows.count * CatalogPrint.count)
            for row in rows {
                let data: Data = row["vector"]
                guard data.count == CatalogPrint.count * 2 else { continue }
                index.ids.append(row["assetID"])
                data.withUnsafeBytes { index.values.append(contentsOf: $0.bindMemory(to: Float16.self)) }
            }
            return index
        }
    }

    /// Photos that are duplicates, as Photos counts them: copies, and shots near enough the same to keep one of, taken
    /// in the same second (the camera's fraction of a second agreeing where both files record it) with nearly the same
    /// print (`within`; a copy saved again measures about 0.09, the next frame of a moving burst 0.21, two frames of a
    /// still scene less). A RAW and the JPEG the camera saved with it are a pair, not duplicates. Each group is a
    /// photo and its duplicates, by name; groups newest first.
    /// Only the prints of photos that share their second with another are read, so a library is searched without
    /// loading all its prints.
    public nonisolated func duplicates(within: Float = 0.15) throws -> [[String]] {
        let library = "trashedAt IS NULL AND archivedAt IS NULL"
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.captureTime, a.filename, p.vector FROM asset a JOIN assetPrint p ON p.assetID = a.id AND p.revision = ?
                WHERE a.\(library) AND a.captureTime IN
                  (SELECT captureTime FROM asset WHERE \(library) AND captureTime IS NOT NULL AND captureTime != ''
                   GROUP BY captureTime HAVING count(*) > 1)
                """, arguments: [CatalogPrint.revision])
        }
        var index = CatalogPrintIndex(), bySecond: [String: [Int]] = [:], names: [String] = [], times: [String] = []
        for row in rows {
            let data: Data = row["vector"]
            guard data.count == CatalogPrint.count * 2 else { continue }
            let time: String = row["captureTime"]
            bySecond[time, default: []].append(index.ids.count)
            index.ids.append(row["id"]); names.append(row["filename"]); times.append(time)
            data.withUnsafeBytes { index.values.append(contentsOf: $0.bindMemory(to: Float16.self)) }
        }
        func stem(_ name: String) -> String { (name as NSString).deletingPathExtension.lowercased() }
        var candidates: [(Int, Int)] = []
        for group in bySecond.values where group.count > 1 {
            for (a, b) in index.closePairs(in: group, within: within) {
                // The camera's RAW and JPEG of one shot: Tidy RAW + JPEG Pairs' business.
                let sameType = (names[a] as NSString).pathExtension.lowercased() == (names[b] as NSString).pathExtension.lowercased()
                if stem(names[a]) == stem(names[b]), !sameType { continue }
                candidates.append((a, b))
            }
        }
        guard !candidates.isEmpty else { return [] }
        // Frames of a fast burst share a second: the fraction the camera recorded tells them apart. Read from the
        // metadata kept at import, only for the few photos that are candidates: never from the originals, which may be
        // on a slow drive.
        let involved = Array(Set(candidates.flatMap { [$0.0, $0.1] }))
        let place = Dictionary(uniqueKeysWithValues: involved.map { (index.ids[$0], $0) })
        let stored = try database.read { db in
            try CatalogExif.fetchAll(db, sql: "SELECT * FROM assetExif WHERE assetID IN (SELECT value FROM json_each(?))",
                                     arguments: [String(decoding: try JSONEncoder().encode(Array(place.keys)), as: UTF8.self)])
        }
        var fraction: [Int: String] = [:]
        for exif in stored {
            guard let i = place[exif.assetID],
                  let properties = (try? PropertyListSerialization.propertyList(from: exif.extractedMetadata, format: nil)) as? [String: Any],
                  let values = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
                  let sub = values[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, !sub.isEmpty else { continue }
            fraction[i] = sub
        }
        var parent = Dictionary(involved.map { ($0, $0) }, uniquingKeysWith: { a, _ in a })
        func leader(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        for (a, b) in candidates {
            if let fa = fraction[a], let fb = fraction[b], fa != fb { continue }
            parent[leader(a)] = leader(b)
        }
        var groups: [Int: [Int]] = [:]
        for i in involved { groups[leader(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }
            .sorted { times[$0[0]] > times[$1[0]] }
            .map { $0.sorted { names[$0] < names[$1] }.map { index.ids[$0] } }
    }

    /// How many library photos have no print of the current revision yet: background analysis still has them to do.
    public func photosWithoutPrint() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM asset a WHERE a.trashedAt IS NULL AND a.archivedAt IS NULL AND a.kind != ?
                AND NOT EXISTS (SELECT 1 FROM assetPrint p WHERE p.assetID = a.id AND p.revision = ?)
                """, arguments: [LatentImage.kind, CatalogPrint.revision]) ?? 0
        }
    }
}

/// One photo's feature print, as stored.
public struct CatalogPrint: Sendable, Equatable {
    public static let count = 768
    /// Prints of different revisions can't be compared.
    public static var revision: Int { VNGenerateImageFeaturePrintRequest.defaultRevision }
    public let revision: Int
    /// `count` values, Float16.
    public let vector: Data

    /// The observation's values at half precision; nil for a print of another shape.
    public init?(_ observation: VNFeaturePrintObservation, revision: Int) {
        guard observation.elementType == .float, observation.elementCount == Self.count else { return nil }
        var half = [Float16](repeating: 0, count: Self.count)
        observation.data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<Self.count { half[i] = Float16(floats[i]) }
        }
        self.revision = revision
        vector = half.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension CatalogPrint {
    /// The print of the photo at `url`, as background analysis makes it: for a photo it hasn't reached yet.
    public static func measure(_ url: URL) -> CatalogPrint? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ImageDecode.analysisImage(source, url: url, pixelSize: 1600, minimum: 1024) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let observation = request.results?.first else { return nil }
        return CatalogPrint(observation, revision: request.revision)
    }
}

/// The library's prints in one block of memory, searched by plain distance.
public struct CatalogPrintIndex: Sendable {
    public var ids: [String] = []
    /// `ids.count × CatalogPrint.count` values.
    var values: [Float16] = []
    public init() {}

    public var count: Int { ids.count }

    /// Euclidean distance between the prints at two places in the index: Vision's own `distance(to:)`.
    func distance(_ a: Int, _ b: Int) -> Float {
        let n = CatalogPrint.count
        return values.withUnsafeBufferPointer { v in
            var sum = SIMD8<Float>()
            var i = 0
            while i < n {
                let x = SIMD8<Float>(SIMD8<Float16>(v[a * n + i ..< a * n + i + 8]))
                let y = SIMD8<Float>(SIMD8<Float16>(v[b * n + i ..< b * n + i + 8]))
                let d = x - y
                sum += d * d
                i += 8
            }
            return sum.sum().squareRoot()
        }
    }

    /// The photos closest to `id`, nearest first, no further than `within`; the photo itself is left out. `print`
    /// stands in for a photo the index doesn't have yet.
    public func similar(to id: String, print: CatalogPrint? = nil, within: Float = 0.6, limit: Int = 500) -> [(id: String, distance: Float)] {
        var index = self
        if !ids.contains(id), let print, print.revision == CatalogPrint.revision {
            index.ids.append(id)
            print.vector.withUnsafeBytes { index.values.append(contentsOf: $0.bindMemory(to: Float16.self)) }
        }
        return index.nearest(to: id, within: within, limit: limit)
    }
    private func nearest(to id: String, within: Float, limit: Int) -> [(id: String, distance: Float)] {
        guard let a = ids.firstIndex(of: id) else { return [] }
        var found: [(Int, Float)] = []
        for b in ids.indices where b != a {
            let d = distance(a, b)
            if d <= within { found.append((b, d)) }
        }
        return found.sorted { $0.1 < $1.1 }.prefix(limit).map { (ids[$0.0], $0.1) }
    }

    /// Pairs among `group` (places in the index, already grouped by when they were taken) whose prints are nearly the
    /// same.
    func closePairs(in group: [Int], within: Float) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        for (n, a) in group.enumerated() { for b in group[(n + 1)...] where distance(a, b) <= within { pairs.append((a, b)) } }
        return pairs
    }
}
