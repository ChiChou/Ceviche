import XCTest
import CevicheTestSupport
import GRDB
import Vision
@testable import CevicheCore

final class CatalogPrintTests: XCTestCase {
    /// A picture of a few shapes, shifted by `offset`, for real Vision prints without a photo.
    private func picture(offset: CGFloat, hue: CGFloat = 0.6) -> CGImage {
        let c = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 0.1, green: 0.2, blue: hue, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        c.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1)); c.fillEllipse(in: CGRect(x: 120 + offset, y: 140, width: 160, height: 160))
        c.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1)); c.fill(CGRect(x: 360 + offset, y: 80, width: 180, height: 260))
        return c.makeImage()!
    }
    private func observation(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try XCTUnwrap(request.results?.first)
    }

    func testStoredPrintsMeasureVisionsOwnDistance() throws {
        let a = try observation(picture(offset: 0)), b = try observation(picture(offset: 40)), c = try observation(picture(offset: 0, hue: 0.1))
        let prints = [a, b, c].compactMap { CatalogPrint($0, revision: CatalogPrint.revision) }
        XCTAssertEqual(prints.count, 3)
        var index = CatalogPrintIndex()
        for (i, print) in prints.enumerated() {
            index.ids.append("p\(i)")
            print.vector.withUnsafeBytes { index.values.append(contentsOf: $0.bindMemory(to: Float16.self)) }
        }
        for (i, j, x, y) in [(0, 1, a, b), (0, 2, a, c), (1, 2, b, c)] {
            var vision: Float = 0
            try x.computeDistance(&vision, to: y)
            // Half precision keeps Vision's distance to about a thousandth.
            XCTAssertEqual(index.distance(i, j), vision, accuracy: 0.003)
        }
        XCTAssertEqual(index.similar(to: "p0", within: 10).map(\.id).first, index.distance(0, 1) < index.distance(0, 2) ? "p1" : "p2")
    }

    /// Show Similar reads every print in the library: a hundred thousand photos must stay well under a second.
    func testSearchingAHundredThousandPrintsIsQuick() {
        var index = CatalogPrintIndex()
        let n = 100_000
        index.ids = (0..<n).map { "a\($0)" }
        // Scattered values from a multiplicative hash: random enough, and quick to make.
        index.values = (0..<(n * CatalogPrint.count)).map { Float16(Float(UInt32(truncatingIfNeeded: $0 &* 2_654_435_761) % 1000) / 10_000 - 0.05) }
        // One photo a near copy of the first.
        for k in 0..<CatalogPrint.count { index.values[5 * CatalogPrint.count + k] = index.values[k] + 0.001 }
        let start = Date()
        let found = index.similar(to: "a0", within: 0.6)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(found.first?.id, "a5")
        Swift.print("Searched \(n) prints in \(seconds) s")
        XCTAssertLessThan(seconds, 0.5, "searching took \(seconds) s")
    }

    func testAnalysisStoresThePrintAndCopiesAreFound() async throws {
        let (directory, url, store, first) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        // A second import of the same file: a copy taken at the same moment.
        let copy = url.deletingLastPathComponent().appendingPathComponent("copy-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        let prepared = try CatalogImporter.prepare(copy)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        let print = try XCTUnwrap(CatalogPrint(try observation(picture(offset: 0)), revision: CatalogPrint.revision))
        for _ in 0..<2 {
            let claim = try await store.claimAnalysis(owner: "worker", version: CatalogImporter.analysisVersion)!
            _ = try await store.finishAnalysis(claim, tags: "", version: CatalogImporter.analysisVersion, print: print)
        }
        let index = try await store.printIndex()
        XCTAssertEqual(Set(index.ids), [first.id, second.id])
        XCTAssertEqual(index.similar(to: first.id).map(\.id), [second.id])
        let missing = try await store.photosWithoutPrint()
        XCTAssertEqual(missing, 0)
        let found = try store.duplicates()
        if first.captureTime?.isEmpty == false {
            XCTAssertEqual(found.map(Set.init), [[first.id, second.id]])
        } else {
            XCTAssertEqual(found, [], "photos with no capture time are never called copies")
        }

        // The grid shows a found set in its order.
        var filter = CatalogFilter()
        filter.photoSet = CatalogPhotoSet(kind: .similar(to: first.id), ids: [second.id, first.id])
        let shown = try await store.assets(filter: filter).map(\.id)
        XCTAssertEqual(shown, [second.id, first.id])
        filter.photoSet = CatalogPhotoSet(kind: .similar(to: second.id), ids: [first.id, second.id])
        let reversed = try await store.assets(filter: filter).map(\.id)
        XCTAssertEqual(reversed, [first.id, second.id])
    }

    /// Duplicates reads only the prints of photos sharing their second with another: a photo without a print, or alone
    /// in its second, is never compared.
    func testDuplicatesNeedTheSameSecondAndAPrint() async throws {
        let (directory, url, store, first) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var ids = [first.id]
        for name in ["copy-a", "copy-b", "copy-c"] {
            let copy = url.deletingLastPathComponent().appendingPathComponent(name + "-" + url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            let prepared = try CatalogImporter.prepare(copy)
            ids.append(try await store.insert(prepared.0, thumbnail: prepared.1).id)
        }
        let later = ids[3]
        try await store.database.write { db in
            try db.execute(sql: "UPDATE asset SET captureTime = '2026-11-01T10:00:00'")
            try db.execute(sql: "UPDATE asset SET captureTime = '2026-11-01T10:00:01' WHERE id = ?", arguments: [later])
        }
        let print = try XCTUnwrap(CatalogPrint(try observation(picture(offset: 0)), revision: CatalogPrint.revision))
        for id in [ids[0], ids[1], ids[3]] { try await store.savePrint(print, assetID: id) }
        let waiting = try await store.photosWithoutPrint()
        XCTAssertEqual(waiting, 1)
        XCTAssertEqual(try store.duplicates().map(Set.init), [[ids[0], ids[1]]])
        try await store.savePrint(print, assetID: ids[2])
        XCTAssertEqual(try store.duplicates().map(Set.init), [Set(ids.prefix(3))])
    }

    func testBackfillPrintsPhotosAnalysedWithoutOne() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let before = try await store.photosNeedingPrint(limit: 10).map(\.id)
        XCTAssertEqual(before, [asset.id])
        let outcome = try await CatalogIndexWorker.runPrintBackfill(store: store, cancellation: CatalogAnalysisCancellation())
        XCTAssertEqual(outcome, .completed)
        let index = try await store.printIndex()
        XCTAssertEqual(index.ids, [asset.id], "the fixture photo is printed")
        let after = try await store.photosNeedingPrint(limit: 10)
        XCTAssertTrue(after.isEmpty)
        let again = try await CatalogIndexWorker.runPrintBackfill(store: store, cancellation: CatalogAnalysisCancellation())
        XCTAssertEqual(again, .idle)
    }

    func testAPhotoThatCantBePrintedIsMarkedNotRetried() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.savePrint(nil, assetID: asset.id)
        let left = try await store.photosNeedingPrint(limit: 10)
        XCTAssertTrue(left.isEmpty)
        let index = try await store.printIndex()
        XCTAssertTrue(index.ids.isEmpty, "a marker is never searched")
    }
}
