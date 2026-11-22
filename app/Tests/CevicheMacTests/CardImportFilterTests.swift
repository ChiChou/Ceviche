import XCTest
import CevicheCore
@testable import CevicheMac

final class CardImportFilterTests: XCTestCase {
    @MainActor func testKindFilterAndSelectAllFollowTheShownPhotos() async throws {
        let (directory, jpeg) = try EditorFixtures.photo()
        defer { try? FileManager.default.removeItem(at: directory) }
        let card = directory.appendingPathComponent("DCIM")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        for name in ["DSC001.JPG", "DSC002.JPG", "DSC003.JPEG"] { try FileManager.default.copyItem(at: jpeg, to: card.appendingPathComponent(name)) }
        let model = CardImportModel(request: CardImportRequest(roots: [card], title: "Card", defaultMode: .copy))
        model.start(store: try CatalogStore(root: directory.appendingPathComponent("Catalog")))
        for _ in 0..<50 where model.scanning { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.candidates.count, 3)
        XCTAssertEqual(model.availableKinds.map(\.kind), ["JPEG", "JPG"]); XCTAssertEqual(model.availableKinds.map(\.count), [1, 2])
        XCTAssertTrue(model.allShownSelected, "New photos start selected")
        model.toggleKind("JPEG")
        XCTAssertEqual(model.shown.count, 2, "A chip hides its type")
        XCTAssertEqual(model.chosen.count, 2, "Hidden photos stay selected but do not import")
        model.allShownSelected = false
        XCTAssertEqual(model.selected.count, 1, "Unchecking Select All only drops the shown photos")
        XCTAssertFalse(model.allShownSelected)
        model.allShownSelected = true
        XCTAssertEqual(model.selected.count, 3)
        model.toggleKind("JPG")
        XCTAssertTrue(model.shown.isEmpty, "Every type can be hidden; the grid then says so")
        model.toggleKind("JPEG"); model.toggleKind("JPG")
        XCTAssertTrue(model.hiddenKinds.isEmpty); XCTAssertEqual(model.shown.count, 3)
    }
}
