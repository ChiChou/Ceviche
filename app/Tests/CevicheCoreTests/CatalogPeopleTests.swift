import XCTest
import CevicheTestSupport
import GRDB
@testable import CevicheCore

final class CatalogPeopleTests: XCTestCase {
    let version = CatalogImporter.analysisVersion
    let left = CatalogFace(bounds: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.15), landmarks: 0.9)
    let right = CatalogFace(bounds: CGRect(x: 0.6, y: 0.2, width: 0.1, height: 0.15), landmarks: 0.9)

    /// Two photos, each with a face on the left and on the right.
    func fixture() async throws -> (URL, CatalogStore, [String]) {
        let (directory, url, store, first) = try await CatalogIndexTests().fixture()
        let copy = directory.appendingPathComponent("second." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        let prepared = try CatalogImporter.prepare(copy)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        for id in [first.id, second.id] {
            try await store.database.write { db in try CatalogStore.setFaces([self.left, self.right], assetID: id, db) }
        }
        return (directory, store, [first.id, second.id])
    }
    func embed(_ store: CatalogStore, _ vectors: [CatalogFaceKey: [Float]]) async throws {
        let faces = try await store.facesNeedingEmbedding(limit: 100)
        try await store.saveEmbeddings(faces.map { ($0, vectors[$0.key]) })
    }

    func testGroupingMakesPeopleAndHandEditsHold() async throws {
        let (directory, store, ids) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let (a, b) = (ids[0], ids[1])
        let waiting = try await store.facesNeedingEmbedding(limit: 100)
        XCTAssertEqual(waiting.count, 4)
        try await embed(store, [CatalogFaceKey(assetID: a, index: 0): PeopleGroupingTests.vector(0), CatalogFaceKey(assetID: b, index: 0): PeopleGroupingTests.vector(0, noise: 0.2),
                                CatalogFaceKey(assetID: a, index: 1): PeopleGroupingTests.vector(1), CatalogFaceKey(assetID: b, index: 1): PeopleGroupingTests.vector(1, noise: 0.2)])
        let left = try await store.facesNeedingEmbedding(limit: 100)
        XCTAssertTrue(left.isEmpty)
        let changed = try await store.groupPeople()
        XCTAssertTrue(changed)
        var people = try await store.people()
        XCTAssertEqual(people.count, 2)
        var entries = try await store.faceEntries(filter: CatalogFilter())
        let byPerson = Dictionary(grouping: entries, by: \.personID)
        XCTAssertEqual(byPerson.count, 2)
        XCTAssertTrue(byPerson.values.allSatisfy { Set($0.map(\.index)).count == 1 && $0.count == 2 })
        let again = try await store.groupPeople()
        XCTAssertFalse(again)

        // Analysed again with the faces barely moved: everyone keeps their person.
        let personOfA0 = try XCTUnwrap(entries.first { $0.assetID == a && $0.index == 0 }?.personID)
        var moved = self.left; moved.bounds.origin.x += 0.005
        try await store.database.write { db in try CatalogStore.setFaces([moved, self.right], assetID: a, db) }
        entries = try await store.faceEntries(filter: CatalogFilter())
        XCTAssertEqual(entries.first { $0.assetID == a && $0.index == 0 }?.personID, personOfA0)

        // Named, merged and taken apart by hand.
        let other = try XCTUnwrap(people.first { $0.id != personOfA0 }).id
        try await store.renamePerson(other, name: "  Ana ")
        try await store.mergePeople([other], into: personOfA0)
        people = try await store.people()
        XCTAssertEqual(people.map(\.name), ["Ana"])
        try await store.assignFaces([CatalogFaceKey(assetID: b, index: 1)], to: nil)
        try await store.regroupPeople()
        _ = try await store.groupPeople()
        entries = try await store.faceEntries(filter: CatalogFilter())
        XCTAssertNil(entries.first { $0.assetID == b && $0.index == 1 }?.personID)
        XCTAssertEqual(entries.filter { $0.personID == personOfA0 }.count, 3)

        try await store.removePerson(personOfA0)
        _ = try await store.groupPeople()
        let none = try await store.people()
        XCTAssertTrue(none.isEmpty)
        entries = try await store.faceEntries(filter: CatalogFilter())
        XCTAssertTrue(entries.allSatisfy { $0.personID == nil && $0.pinned })
    }

    func testNewPersonFromFacesAndUnnamedEmptyPeopleGo() async throws {
        let (directory, store, ids) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.newPerson(with: [CatalogFaceKey(assetID: ids[0], index: 0), CatalogFaceKey(assetID: ids[1], index: 0)])
        var entries = try await store.faceEntries(filter: CatalogFilter())
        XCTAssertEqual(entries.filter { $0.personID == id }.count, 2)
        // The photo analysed again without faces: an unnamed person with no faces left is gone.
        try await store.database.write { db in
            try CatalogStore.setFaces([], assetID: ids[0], db); try CatalogStore.setFaces([], assetID: ids[1], db)
        }
        _ = try await store.groupPeople()
        let people = try await store.people()
        XCTAssertTrue(people.isEmpty)
        entries = try await store.faceEntries(filter: CatalogFilter())
        XCTAssertTrue(entries.isEmpty)
    }
}
