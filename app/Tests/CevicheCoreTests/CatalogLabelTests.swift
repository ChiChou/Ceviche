import XCTest
@testable import CevicheCore

final class CatalogLabelTests: XCTestCase {
    func testLabelsAreSetClearedFilteredAndKeptOutOfHistory() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        for id in ["a", "b", "c"] {
            var photo = try CatalogImporter.prepare(url).0
            photo.id = id; photo.importPath += "#" + id
            _ = try await store.insert(photo, thumbnail: nil)
        }
        let before = try await store.history(assetID: "a").count
        let previous = try await store.updateQuickMetadata(assetIDs: ["a", "b"], label: .some(.red))
        XCTAssertEqual(Set(previous.keys), ["a", "b"]); XCTAssertNil(previous["a"]?.label)
        _ = try await store.updateQuickMetadata(assetIDs: ["c"], label: .some(.purple))
        _ = try await store.updateQuickMetadata(assetIDs: ["c"], rating: 3)
        let c = try await store.asset("c"); XCTAssertEqual(c.metadata.label, .purple, "Leaving the label out keeps it")
        var filter = CatalogFilter(); filter.label = .red
        let red = try await store.assets(filter: filter).map(\.id); XCTAssertEqual(Set(red), ["a", "b"])
        XCTAssertTrue(filter.isRefined)
        _ = try await store.updateQuickMetadata(assetIDs: ["b"], label: .some(nil))
        let stillRed = try await store.assets(filter: filter).map(\.id); XCTAssertEqual(stillRed, ["a"])
        let after = try await store.history(assetID: "a").count
        XCTAssertEqual(after, before, "A label alone is culling, not History")
    }
    func testLabelsReadAndWriteLightroomsXMPNames() throws {
        let xmp = XMPTests()
        let blue = try XMPCodec.apply(xmp.packet("xmp:Label=\"Blue\""), to: Adjustments())
        XCTAssertEqual(blue.metadata.label, .blue)
        let custom = try XMPCodec.apply(xmp.packet("xmp:Label=\"To Print\""), to: Adjustments())
        XCTAssertNil(custom.metadata.label, "A label Lightroom gives no color is left out")
        var metadata = CatalogMetadata(); metadata.label = .yellow
        let written = try XMPPacket(data: XMPCodec.encode(adjustments: Adjustments(), metadata: metadata))
        XCTAssertEqual(written.value("Label", namespace: XMPPacket.xmp), "Yellow")
        let none = try XMPPacket(data: XMPCodec.encode(adjustments: Adjustments(), metadata: CatalogMetadata()))
        XCTAssertNil(none.value("Label", namespace: XMPPacket.xmp))
    }
}
