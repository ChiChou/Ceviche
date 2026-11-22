import XCTest
@testable import CevicheCore

/// `Adjustments` is copied by value through imports and renders on Swift concurrency threads, whose stacks are small;
/// RawCamera recurses deeply under them when it makes a thumbnail, and a 296-byte larger edit was enough to overflow
/// importing some Sony ARWs by copy. Thumbnails of originals now decode on their own stack (`ImageDecode`); keeping
/// large optional parts out of line (`@Boxed`) still keeps every copy of an edit cheap.
final class AdjustmentsSizeTests: XCTestCase {
    func testTheEditStaysSmall() {
        XCTAssertLessThanOrEqual(MemoryLayout<Adjustments>.size, 1200, "box a large, rarely set part with @Boxed")
    }
    func testBoxedPartsKeepValueSemanticsAndEquality() throws {
        var a = Adjustments()
        a.look = ImportedLook(name: "Warm")
        var b = a
        b.look?.amount = 0.5
        XCTAssertEqual(a.look?.amount, 1, "changing a copy leaves the original")
        XCTAssertNotEqual(a, b)
        b.look?.amount = 1
        XCTAssertEqual(a, b, "equal by content, not by box")
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
        b.look = nil
        XCTAssertNil(b.look); XCTAssertNotNil(a.look)
    }
    /// The catalog stores developments without their default values; decoding has to bring each one back exactly.
    func testStoredDevelopmentsLeaveOutDefaultsAndReadBackTheSame() throws {
        let sparse = JSONEncoder(); sparse.userInfo[Adjustments.sparseKey] = true
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: sparse.encode(Adjustments())), Adjustments(),
                       "every key a stored development leaves out decodes to the default")
        XCTAssertLessThan(try sparse.encode(Adjustments()).count, 40)
        var edit = Adjustments(); edit.exposure = 0.7; edit.lensCorrection = false; edit.curveSaturation = 80; edit.quarterTurns = 1
        let stored = try sparse.encode(edit)
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: stored), edit)
        XCTAssertLessThan(stored.count, try JSONEncoder().encode(edit).count / 5)
        // A full payload from an earlier build and a compact one differ only where the edit does.
        var next = edit; next.exposure = 1
        XCTAssertEqual(EditSummary.changedKeys(from: try JSONEncoder().encode(edit), to: try sparse.encode(next)), ["exposure"])
    }
}
