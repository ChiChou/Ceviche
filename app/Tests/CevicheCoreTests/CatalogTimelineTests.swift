import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class CatalogTimelineTests: XCTestCase {
    /// Photos on 2024-01-10, 2024-01-20, 2024-06-05 and 2025-03-01, and one without a date.
    private func fixture() async throws -> (URL, CatalogStore) {
        let (directory, url) = try CatalogTests().fixture()
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        for (id, day) in [("a", "2024-01-10"), ("b", "2024-01-20"), ("c", "2024-06-05"), ("d", "2025-03-01"), ("x", "")] {
            var photo = try CatalogImporter.prepare(url).0
            photo.id = id; photo.importPath += "#" + id
            var metadata = photo.metadata; metadata.captureDay = day; photo.metadata = metadata
            _ = try await store.insert(photo, thumbnail: nil)
        }
        return (directory, store)
    }

    func testMonthsAreThoseWithMatchingPhotos() async throws {
        let (directory, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let all = try await store.captureMonths(filter: CatalogFilter())
        XCTAssertEqual(all, ["2024-01", "2024-06", "2025-03"])
        try await store.moveToTrash(["c"])
        let left = try await store.captureMonths(filter: CatalogFilter())
        XCTAssertEqual(left, ["2024-01", "2025-03"], "A trashed photo's month is empty in the library")
    }

    func testJumpLandsOnTheMonthOrTheNearestDay() async throws {
        let (directory, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        // Newest first: d, c, b, a, then the undated photo.
        var filter = CatalogFilter()
        func offset(_ month: String) async throws -> Int { try await store.offset(nearestMonth: month, filter: filter) }
        let january = try await offset("2024-01"); XCTAssertEqual(january, 2, "The month's newest photo, b")
        let june = try await offset("2024-06"); XCTAssertEqual(june, 1)
        // August 2024 is empty: June 5 is nearer than March 1 next year.
        let august = try await offset("2024-08"); XCTAssertEqual(august, 1)
        // January 2025 is empty: March 1 is nearer than June 5.
        let january2025 = try await offset("2025-01"); XCTAssertEqual(january2025, 0)
        let before = try await offset("2020-01"); XCTAssertEqual(before, 3, "Past the oldest: the oldest dated photo")
        // Oldest first: the undated photo, a, b, c, d.
        filter.ascending = true
        let ascendingJanuary = try await offset("2024-01"); XCTAssertEqual(ascendingJanuary, 1, "The month's oldest photo, a")
        let ascendingAugust = try await offset("2024-08"); XCTAssertEqual(ascendingAugust, 3)
    }
}
