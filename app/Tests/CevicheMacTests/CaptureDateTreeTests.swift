import XCTest
import CevicheCore
@testable import CevicheMac

final class CaptureDateTreeTests: XCTestCase {
    func testDaysGroupIntoYearsAndMonthsWithCounts() {
        let tree = CaptureDateNode.tree(days: ["2024-01-02", "2022-06-12", "2022-06-11", "2022-05-30", ""],
                                        counts: ["2024-01-02": 1, "2022-06-12": 40, "2022-06-11": 44, "2022-05-30": 2, "": 3])
        XCTAssertEqual(tree.map(\.id), ["2024", "2022", ""])
        XCTAssertEqual(tree[1].count, 86)
        XCTAssertEqual(tree[1].children?.map(\.id), ["2022-06", "2022-05"])
        XCTAssertEqual(tree[1].children?.first?.count, 84)
        XCTAssertEqual(tree[1].children?.first?.children?.map(\.id), ["2022-06-12", "2022-06-11"])
        XCTAssertEqual(tree[2].title, "Unknown Date")
        XCTAssertEqual(CaptureDateNode.ancestors(of: "2022-06-12"), ["2022", "2022-06"])
    }
    @MainActor func testYearAndMonthFilterMatchEveryDayInside() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store), photos = model.assets
        for (index, day) in ["2022-06-12", "2022-06-11", "2022-05-30", "2021-01-01"].enumerated() {
            var metadata = photos[index].metadata; metadata.captureDay = day
            try await store.updateMetadata(metadata, assetID: photos[index].id)
        }
        var filter = CatalogFilter()
        for (value, expected) in [("2022", 3), ("2022-06", 2), ("2022-06-12", 1), ("2021", 1)] {
            filter.captureDay = value
            let count = try await store.count(filter: filter)
            XCTAssertEqual(count, expected, value)
        }
    }
}
