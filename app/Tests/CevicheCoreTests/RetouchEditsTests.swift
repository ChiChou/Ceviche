import XCTest
@testable import CevicheCore

/// The Retouch decisions both apps share: fill queue, refused sources, source landing and dust repair.
final class RetouchEditsTests: XCTestCase {
    private func remove(_ x: Double, generative: Bool = true) -> RetouchStroke {
        var stroke = RetouchStroke(mode: .remove, source: MaskPoint(x: 0.9, y: 0.5), target: MaskPoint(x: x, y: 0.5), radius: 0.02, softness: 0.3, opacity: 1)
        stroke.generative = generative
        return stroke
    }
    private func fill(for stroke: RetouchStroke) -> RetouchFill {
        RetouchFill(x: 0, y: 0, width: 0.1, height: 0.1, reach: 0.02, footprint: RetouchFill.footprint(of: stroke), raster: Data())
    }

    func testFillQueueTakesStrokesNeedingFillsInStrokeOrder() {
        let a = remove(0.2), b = remove(0.4), patch = remove(0.6, generative: false)
        var filled = remove(0.8); filled.fill = fill(for: filled)
        var queue = RetouchFillQueue()
        XCTAssertTrue(queue.schedule([b, a, patch, filled]))
        XCTAssertEqual(queue.pending, [b.id, a.id])
        XCTAssertFalse(queue.schedule([patch]), "Nothing asks for a fill: nothing starts")
        XCTAssertEqual(queue.next(in: [a, b])?.id, a.id, "Stroke order, not queue order")
        queue.finish(a.id)
        XCTAssertEqual(queue.next(in: [a, b])?.id, b.id)
    }

    func testFailedFillIsNotTriedAgainUntilTheStrokeChangesOrIsRefreshed() {
        var stroke = remove(0.3)
        var queue = RetouchFillQueue()
        queue.schedule([stroke])
        queue.fail(stroke, "No memory"); queue.finish(stroke.id)
        XCTAssertEqual(queue.failure(for: stroke), "No memory")
        XCTAssertFalse(queue.schedule([stroke]))
        // Moved: another footprint, tried again.
        stroke.points = [MaskPoint(x: 0.35, y: 0.5)]
        XCTAssertNil(queue.failure(for: stroke))
        XCTAssertTrue(queue.schedule([stroke]))
        queue.cancel()
        // Refresh forgets every footprint's failure and asks for another variant.
        queue.fail(stroke, "Again")
        queue.refresh([stroke.id])
        XCTAssertTrue(queue.failures.isEmpty)
        XCTAssertEqual(queue.variant(stroke.id), 1)
        XCTAssertTrue(queue.schedule([stroke]))
        XCTAssertEqual(queue.cancel(), [stroke.id]); XCTAssertTrue(queue.isEmpty)
    }

    func testRefreshSplitsFillsFromSources() {
        let ai = remove(0.2), patch = remove(0.4, generative: false)
        let heal = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.1, y: 0.1), target: MaskPoint(x: 0.5, y: 0.5), radius: 0.02, softness: 0.5, opacity: 1)
        let split = RetouchFillQueue.refreshing([ai, patch, heal], fillAvailable: true)
        XCTAssertEqual(split.fills, [ai.id]); XCTAssertEqual(split.sources, [patch.id, heal.id])
        // Without the model an AI fill is not dropped for one that can't be made: the stroke takes another source.
        XCTAssertEqual(RetouchFillQueue.refreshing([ai], fillAvailable: false).sources, [ai.id])
    }

    func testFillLandsOnlyOnTheFootprintItWasMadeFor() {
        let stroke = remove(0.3)
        var a = Adjustments(); a.retouch = [stroke]
        let made = fill(for: stroke)
        a.retouch[0].points.append(MaskPoint(x: 0.4, y: 0.5))
        a.placeFill(made, on: stroke.id)
        XCTAssertNil(a.retouch[0].fill, "The stroke was extended meanwhile")
        a.retouch[0].points = stroke.points
        a.placeFill(made, on: stroke.id)
        XCTAssertEqual(a.retouch[0].fill, made)
        a.setGenerative(false, [stroke.id])
        XCTAssertFalse(a.retouch[0].generative); XCTAssertNil(a.retouch[0].fill)
    }

    func testRefreshRefusesEverySourceTried() {
        var stroke = remove(0.3)
        var history = RetouchSourceHistory()
        XCTAssertEqual(history.choosing([stroke], refresh: true)[stroke.id], [stroke.source])
        let first = stroke.source
        stroke.source = MaskPoint(x: 0.1, y: 0.1)
        XCTAssertEqual(history.choosing([stroke], refresh: true)[stroke.id], [first, stroke.source])
        XCTAssertNil(history.choosing([stroke], refresh: false)[stroke.id], "Moved or painted: it starts afresh")
    }

    func testSourceChoiceLeavesStrokesChangedMeanwhile() {
        let a = remove(0.2, generative: false), b = remove(0.4, generative: false)
        var adjustments = Adjustments(); adjustments.retouch = [a, b]
        let choice = RetouchSourceChoice(strokes: [a, b], sources: [a.id: MaskPoint(x: 0.7, y: 0.7), b.id: MaskPoint(x: 0.6, y: 0.6)], exposures: [:])
        adjustments.retouch[1].points = [MaskPoint(x: 0.45, y: 0.5)]
        adjustments.apply(choice)
        XCTAssertEqual(adjustments.retouch[0].source, MaskPoint(x: 0.7, y: 0.7))
        XCTAssertEqual(adjustments.retouch[1].source, b.source)
    }

    func testDustRepairBatchesWithinRoom() {
        let spots = (0..<5).map { DustSpot(center: MaskPoint(x: Double($0) / 10, y: 0.5), radius: 0.01) }
        let all = DustRepair.batch(spots, room: 3)
        XCTAssertEqual(all.spots.map(\.id), spots.prefix(3).map(\.id)); XCTAssertEqual(all.skipped, 2)
        let some = DustRepair.batch(spots, selected: [spots[1].id, spots[4].id], room: 10)
        XCTAssertEqual(some.spots.map(\.id), [spots[1].id, spots[4].id]); XCTAssertEqual(some.skipped, 0)
        XCTAssertTrue(DustRepair.batch(spots, room: -2).spots.isEmpty)
        // A spot removed meanwhile stays removed; strokes added meanwhile take room first.
        let strokes = spots.map { RetouchStroke(mode: .heal, source: $0.center, target: $0.center, radius: $0.radius, softness: 0.4, opacity: 1) }
        let kept = DustRepair.accepted(spots, strokes: strokes, current: spots.filter { $0.id != spots[0].id }, room: 2)
        XCTAssertEqual(kept.map(\.spot.id), [spots[1].id, spots[2].id])
        XCTAssertEqual(kept.map(\.stroke.id), [strokes[1].id, strokes[2].id])
    }

    func testRetouchRoomNeverGoesBelowZero() {
        var a = Adjustments()
        a.retouch = Array(repeating: remove(0.5), count: DustFinder.strokeLimit + 1)
        XCTAssertEqual(a.retouchRoom, 0)
        XCTAssertTrue(a.fittingRetouch([remove(0.1)]).isEmpty)
    }

    func testMovedDodgeBurnSpotKeepsItsSourceOnItsCentre() {
        let centre = MaskPoint(x: 0.5, y: 0.5)
        var tone = RetouchStroke(mode: .tone, source: centre, target: centre, radius: 0.01, softness: 0.9, opacity: 1)
        tone.moveDustSpot(to: MaskPoint(x: 1.2, y: 0.3), radius: 0.5)
        XCTAssertEqual(tone.points, [MaskPoint(x: 1, y: 0.3)])
        XCTAssertEqual(tone.source, MaskPoint(x: 1, y: 0.3))
        XCTAssertEqual(tone.radius, 0.15)
        // A healed spot keeps the clean patch it samples.
        var heal = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.1, y: 0.1), target: centre, radius: 0.01, softness: 0.4, opacity: 1)
        heal.moveDustSpot(to: MaskPoint(x: 0.6, y: 0.6))
        XCTAssertEqual(heal.source, MaskPoint(x: 0.1, y: 0.1))
        var spot = DustSpot(center: centre, radius: 0.01)
        spot.move(to: MaskPoint(x: -0.1, y: 0.2), radius: 0.0001)
        XCTAssertEqual(spot.center, MaskPoint(x: 0, y: 0.2)); XCTAssertEqual(spot.radius, 0.001)
    }
}
