import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogFaceTests: XCTestCase {
    let version = CatalogImporter.analysisVersion
    let left = CatalogFace(bounds: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.15), landmarks: 0.9, quality: 0.6, leftEye: 0.3, rightEye: 0.28)
    let crowd = CatalogFace(bounds: CGRect(x: 0.7, y: 0.5, width: 0.015, height: 0.02), landmarks: 0.8)

    func testAnalysisStoresFacesAndKeepsTheCount() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let claim = try await store.claimAnalysis(owner: "worker", version: version)!
        let applied = try await store.finishAnalysis(claim, tags: "person", version: version, faces: [left, crowd])
        XCTAssertTrue(applied)
        let stored = try await store.faces([asset.id])
        XCTAssertEqual(stored[asset.id], [left, crowd])
        let value1 = try await count(store, asset.id)
        XCTAssertEqual(value1, 2)
        XCTAssertTrue(stored[asset.id]![0].judged); XCTAssertFalse(stored[asset.id]![1].judged)

        // Analysed again: the rows are replaced, never added to.
        try await store.enqueueAnalysis(assetID: asset.id, version: version)
        let again = try await store.claimAnalysis(owner: "worker", version: version)!
        _ = try await store.finishAnalysis(again, tags: "", version: version, faces: [])
        let none = try await store.faces([asset.id])
        let value2 = try await count(store, asset.id)
        XCTAssertNil(none[asset.id]); XCTAssertEqual(value2, 0)
    }

    func testWallListsFacesOfTheFilteredPhotos() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        var filter = CatalogFilter(); filter.withFaces = true
        let before = try await store.unanalysedFaceCount(filter: filter)
        XCTAssertEqual(before, 1)
        let claim = try await store.claimAnalysis(owner: "worker", version: version)!
        _ = try await store.finishAnalysis(claim, tags: "", version: version, faces: [left, crowd])
        let entries = try await store.faceEntries(filter: filter)
        // The crowd face is counted but too small for the wall.
        XCTAssertEqual(entries.map(\.id), ["\(asset.id)/0"])
        let value3 = try await store.assets(filter: filter).map(\.id)
        XCTAssertEqual(value3, [asset.id])
        let value4 = try await store.unanalysedFaceCount(filter: filter)
        XCTAssertEqual(value4, 0)
        filter.minimumRating = 3
        let value5 = try await store.faceEntries(filter: filter).isEmpty
        XCTAssertTrue(value5)
        // Trashing the photo takes its faces off the wall; deleting it removes their rows.
        try await store.moveToTrash([asset.id])
        let value6 = try await store.faceEntries(filter: CatalogFilter()).isEmpty
        XCTAssertTrue(value6)
    }

    func testFaceBoxesTravelWithTheAnalysis() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let claim = try await store.claimAnalysis(owner: "worker", version: version)!
        _ = try await store.finishAnalysis(claim, tags: "person", version: version, faces: [left])
        let results = try await store.localAnalysisResults()
        let result = try XCTUnwrap(results[asset.id])
        XCTAssertEqual(result.faces, 1); XCTAssertEqual(result.faceBoxes, [left])

        // Another Mac's newer result replaces the faces here.
        var remote = result; remote.analyzedAt = result.analyzedAt.addingTimeInterval(60); remote.faceBoxes = [left, left]; remote.faces = 2
        let value7 = try await store.applyRemoteAnalysis([asset.id: remote])
        XCTAssertTrue(value7)
        let value8 = try await store.faces([asset.id])[asset.id]?.count
        XCTAssertEqual(value8, 2)
        let value9 = try await count(store, asset.id)
        XCTAssertEqual(value9, 2)

        // One from a build that only counted them keeps the count and has no boxes.
        var counted = remote; counted.analyzedAt = remote.analyzedAt.addingTimeInterval(60); counted.faceBoxes = nil; counted.faces = 3
        let value10 = try await store.applyRemoteAnalysis([asset.id: counted])
        XCTAssertTrue(value10)
        let value11 = try await store.faces([asset.id])[asset.id]
        XCTAssertNil(value11)
        let value12 = try await count(store, asset.id)
        XCTAssertEqual(value12, 3)
    }

    func testFaceTilesAreStoredPerFaceAndRemovedWithThePhoto() async throws {
        let (directory, _, store, asset) = try await CatalogIndexTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await store.previews.installFaceTiles([0: Data([1]), 2: Data([2])], assetID: asset.id)
        let first = try await store.previews.faceTile(assetID: asset.id, index: 0)
        XCTAssertEqual(first, Data([1]))
        try await store.previews.installFaceTiles([1: Data([3])], assetID: asset.id)
        let replaced = try await store.previews.faceTile(assetID: asset.id, index: 0)
        XCTAssertNil(replaced)
        try await store.previews.remove(assetIDs: [asset.id])
        let removed = try await store.previews.faceTile(assetID: asset.id, index: 1)
        XCTAssertNil(removed)
    }

    func testAnalysisFindsTheFaceItsEyesAndCutsATile() throws {
        let url = TestSamples.url(TestSamples.faceSeries.reference)
        guard !url.hasDirectoryPath, FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Face series sample missing") }
        let found = try CatalogImporter.classifyLabels(url, cancellation: nil)
        XCTAssertEqual(found.version, version)
        let face = try XCTUnwrap(found.faces.first)
        XCTAssertEqual(found.faces.count, 1)
        XCTAssertTrue(face.judged); XCTAssertNotNil(face.quality)
        XCTAssertGreaterThan(try XCTUnwrap(face.leftEye), 0.15, "Open eyes")
        let tiles = FaceCrops.wallTiles(at: url, faces: found.faces)
        XCTAssertEqual(Array(tiles.keys), [0])
    }

    private func count(_ store: CatalogStore, _ id: String) async throws -> Int? {
        try await store.database.read { try Int.fetchOne($0, sql: "SELECT faceCount FROM asset WHERE id = ?", arguments: [id]) }
    }
}
