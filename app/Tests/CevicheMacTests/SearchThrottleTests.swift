import XCTest
@testable import CevicheCore
@testable import CevicheMac

/// Typing queries at once and then at most every `typingInterval`, the last text always included.
@MainActor
final class SearchThrottleTests: XCTestCase {
    func testTypingQueriesAtOnceThenThrottlesAndKeepsTheLastText() async throws {
        let (directory, _) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        try await Task.sleep(for: .milliseconds(300))
        let before = model.refreshGeneration
        model.filter.search = "s"
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.refreshGeneration, before + 1, "the first key after a pause queries without waiting")
        for text in ["su", "sun", "suns", "sunse", "sunset"] { model.filter.search = text; try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(model.refreshGeneration - before, 3, "a burst of keys makes a query or two, not one each")
        XCTAssertEqual(model.filter.search, "sunset")
        XCTAssertGreaterThan(model.lastRefreshStart, ContinuousClock.now - .milliseconds(400), "the last text was queried after the burst")
    }
}
