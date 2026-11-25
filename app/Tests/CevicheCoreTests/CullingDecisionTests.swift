import XCTest
@testable import CevicheCore

/// The culling tools' decisions both apps share: Pick from Bursts' choices, Find Flawed Photos' ticks, Tidy RAW + JPEG
/// Pairs' plan, what culling writes to the catalog, and Set Location's changes.
final class CullingDecisionTests: XCTestCase {
    private func photos(_ count: Int, review: [ReviewState] = []) throws -> (URL, [CatalogAsset]) {
        let (directory, url) = try CatalogTests().fixture()
        let base = try CatalogImporter.prepare(url).0.asset
        let assets = (0..<count).map { index -> CatalogAsset in
            var asset = base; asset.id = "photo-\(index)"; asset.importPath += "-\(index)"
            asset.review = index < review.count ? review[index] : .unreviewed
            asset.rating = 0; asset.label = nil; asset.latitude = nil; asset.longitude = nil; asset.locationSource = nil
            asset.captureTime = "2026-10-31T21:00:0\(index)"
            return asset
        }
        return (directory, assets)
    }
    private func plan(_ bursts: [CullingPlan.Burst], proposals: [String: ReviewState]) -> CullingPlan {
        var plan = CullingPlan([], options: CullingPlan.Options())
        plan.bursts = bursts; plan.proposals = proposals
        return plan
    }

    func testBurstChoicesFollowTheProposalUntilThePersonChooses() throws {
        let (directory, assets) = try photos(6, review: [.unreviewed, .unreviewed, .unreviewed, .accepted, .unreviewed, .unreviewed])
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = assets.map(\.id)
        let first = CullingPlan.Burst(members: [ids[0], ids[1], ids[2]], best: ids[1], scores: [:])
        let second = CullingPlan.Burst(members: [ids[3], ids[4]], best: ids[3], scores: [:])
        var choices = BurstChoices(photos: assets)
        choices.update(plan([first, second], proposals: [ids[0]: .rejected, ids[1]: .accepted, ids[2]: .rejected, ids[3]: .accepted, ids[4]: .rejected]))

        // Pick by default: the proposal, a photo's own flag where it proposes nothing new.
        XCTAssertEqual(choices.changes, [ids[0]: .rejected, ids[1]: .accepted, ids[2]: .rejected, ids[4]: .rejected])
        // Skipped, a burst keeps its flags; flagging a frame makes it one to pick from again.
        choices.setAction(second, .skip)
        XCTAssertEqual(choices.flag(ids[4]), .unreviewed)
        choices.set(ids[4], .accepted)
        XCTAssertEqual(choices.action(second), .pick); XCTAssertEqual(choices.flag(ids[4]), .accepted)
        // Keeping one frame rejects the others.
        choices.keepOnly(ids[2])
        XCTAssertEqual([ids[0], ids[1], ids[2]].map(choices.flag), [.rejected, .rejected, .accepted])
        // A cover made groups the burst and leaves its flags; Group All covers bursts found later.
        choices.makeCover(ids[0])
        XCTAssertEqual(choices.action(first), .group); XCTAssertEqual(choices.cover(of: first), ids[0])
        XCTAssertNil(choices.changes[ids[0]])
        XCTAssertEqual(choices.groupChanges, [CullingChanges.Group(members: [ids[0], ids[1], ids[2]], cover: ids[0])])
        choices.setAll(.skip)
        XCTAssertEqual(choices.action(first), .skip); XCTAssertTrue(choices.changes.isEmpty)
        // A photo outside the bursts stays as it is.
        XCTAssertEqual(choices.flag(ids[5]), .unreviewed)
    }

    func testBurstChoicesGroupBothFilesOfAPairUnderTheRAW() throws {
        let (directory, assets) = try photos(4)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = assets.map(\.id)
        // 0 and 1 are JPEGs standing for the RAWs 2 and 3.
        let burst = CullingPlan.Burst(members: [ids[0], ids[1]], best: ids[1], scores: [:])
        var choices = BurstChoices(photos: Array(assets.prefix(2)), partners: [ids[0]: ids[2], ids[1]: ids[3]])
        choices.update(plan([burst], proposals: [:]))
        choices.setAll(.group)
        XCTAssertEqual(choices.groupChanges, [CullingChanges.Group(members: [ids[0], ids[2], ids[1], ids[3]], cover: ids[3])])
        // Already one group under that cover: nothing to do.
        let grouped = BurstChoices(photos: Array(assets.prefix(2)), partners: [ids[0]: ids[2], ids[1]: ids[3]],
                                   stacks: [ids[0]: ids[3], ids[1]: ids[3], ids[2]: ids[3], ids[3]: ids[3]])
        var same = grouped; same.update(plan([burst], proposals: [:])); same.setAll(.group)
        XCTAssertTrue(same.isGrouped(burst)); XCTAssertTrue(same.groupChanges.isEmpty)
        // A timelapse is grouped unless chosen otherwise; a group the person made is always picked from.
        var series = burst; series.series = BurstDetector.Series(interval: 10)
        var timelapse = BurstChoices(photos: assets); timelapse.update(plan([series], proposals: [:]))
        XCTAssertEqual(timelapse.action(series), .group)
        var one = BurstChoices(photos: assets, oneBurst: true); one.update(plan([series], proposals: [:])); one.setAll(.skip)
        XCTAssertEqual(one.action(series), .pick)
    }

    func testCullingChangesFlagBothFilesOfAShot() {
        let changes = CullingChanges(flags: ["jpeg": .rejected, "other": .accepted, "clear": .unreviewed], partners: ["jpeg": "raw"])
        XCTAssertEqual(changes.flags, ["jpeg": .rejected, "raw": .rejected, "other": .accepted, "clear": .unreviewed])
        XCTAssertEqual(changes.batches.map(\.review), [.rejected, .accepted, .unreviewed])
        XCTAssertEqual(changes.batches[0].ids, ["jpeg", "raw"])
        XCTAssertTrue(CullingChanges(flags: [:]).isEmpty)
    }

    func testFlawTicksLeaveThePersonsPicksUnticked() throws {
        let (directory, assets) = try photos(3, review: [.unreviewed, .accepted, .rejected])
        defer { try? FileManager.default.removeItem(at: directory) }
        var ticks = FlawTicks()
        XCTAssertEqual(ticks.toReject(assets), [assets[0].id])
        XCTAssertFalse(ticks.isIncluded(assets[1].id, current: .accepted))
        ticks.toggle(assets[1].id, current: .accepted); ticks.toggle(assets[0].id, current: .unreviewed)
        XCTAssertEqual(ticks.toReject(assets), [assets[1].id])
        ticks.setAll(true, assets)
        XCTAssertEqual(ticks.toReject(assets), [assets[0].id, assets[1].id])
        ticks.setAll(false, assets)
        XCTAssertTrue(ticks.toReject(assets).isEmpty)
        XCTAssertEqual(CullingIssue.flaws, [.blurry, .outOfFocus, .overexposed, .underexposed, .eyesClosed])
    }

    func testTidyPairsPlanCarriesStarsToTheFileKept() throws {
        let (directory, assets) = try photos(8)
        defer { try? FileManager.default.removeItem(at: directory) }
        var raws = Array(assets.prefix(4)), jpegs = Array(assets.suffix(4))
        raws[1].rating = 3; jpegs[1].label = .red
        jpegs[3].review = .rejected
        let plan = TidyPairsPlan([(raws[0], jpegs[0], .archiveJPEG), (raws[1], jpegs[1], .keepJPEG), (raws[2], jpegs[2], .undecided), (raws[3], jpegs[3], .rejectBoth)])
        XCTAssertEqual(plan.decisions.archive.map(\.id), [jpegs[0].id])
        XCTAssertEqual(plan.decisions.changes[jpegs[1].id], FileDecisions.Change(review: .accepted, rating: 3))
        XCTAssertEqual(plan.decisions.changes[raws[1].id]?.review, .rejected)
        XCTAssertNil(plan.decisions.changes[raws[2].id]); XCTAssertNil(plan.decisions.changes[jpegs[2].id])
        XCTAssertEqual(plan.archived, 1); XCTAssertEqual(plan.picked, 1)
        // The JPEG already rejected isn't counted again.
        XCTAssertEqual(plan.rejectedFiles, 3)
        XCTAssertTrue(TidyPairsPlan([(raws[2], jpegs[2], .undecided)]).isEmpty)
    }

    func testStoreAppliesCullingAndFileDecisions() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        var ids: [String] = []
        for second in 0..<5 {
            var asset = prepared.0; asset.id = "photo-\(second)"; asset.importPath += "-\(second)"
            asset.captureDay = "2026-10-31"; asset.captureTime = "2026-10-31T21:00:0\(second)"
            ids.append(try await store.insert(asset, thumbnail: nil).id)
        }
        let before = try await store.asset(ids[0]).review
        let outcome = await store.applyCulling(CullingChanges(flags: [ids[0]: .rejected, ids[1]: before], partners: [ids[0]: ids[4]],
                                                              groups: [.init(members: [ids[2], ids[3]], cover: ids[3])]))
        XCTAssertTrue(outcome.flagErrors.isEmpty); XCTAssertTrue(outcome.groupErrors.isEmpty)
        // A photo already so isn't counted.
        XCTAssertEqual(outcome.applied, [ids[0]: .rejected, ids[4]: .rejected])
        XCTAssertEqual(outcome.previous[ids[0]]?.review, before)
        XCTAssertEqual(outcome.grouped, 1)
        XCTAssertEqual(outcome.stacksBefore[ids[2]], .some(nil)); XCTAssertEqual(outcome.stacksAfter[ids[2]], .some(ids[3]))

        var decisions = FileDecisions()
        decisions.archive = [try await store.asset(ids[1])]
        decisions.changes[ids[2]] = FileDecisions.Change(review: .accepted, rating: 4)
        let applied = await store.apply(decisions)
        XCTAssertEqual(applied.archived, [ids[1]]); XCTAssertEqual(applied.picked, 1); XCTAssertTrue(applied.errors.isEmpty)
        let picked = try await store.asset(ids[2]); XCTAssertEqual(picked.rating, 4)
    }

    func testLocationChangesLeavePhotosAlreadyThere() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        var assets: [CatalogAsset] = []
        for second in 0..<3 {
            var asset = prepared.0; asset.id = "photo-\(second)"; asset.importPath += "-\(second)"
            asset.captureDay = "2026-10-31"; asset.captureTime = "2026-10-31T21:00:0\(second)"
            asset.latitude = nil; asset.longitude = nil; asset.locationSource = nil
            assets.append(try await store.insert(asset, thumbnail: nil))
        }
        let ids = assets.map(\.id)
        var placed = try await store.locationChanges((45.5, 9.2), for: ids)
        XCTAssertEqual(placed.map(\.id), ids)
        XCTAssertEqual(placed[0].new.latitude, 45.5); XCTAssertEqual(placed[0].new.locationSource, .assigned)
        try await store.updateMetadata(Dictionary(uniqueKeysWithValues: [placed[0]].map { ($0.id, $0.new) }))
        placed = try await store.locationChanges((45.5, 9.2), for: ids)
        XCTAssertEqual(placed.map(\.id), [ids[1], ids[2]])
        // Removed, a location goes with its source.
        let removed = try await store.locationChanges(nil, for: ids)
        XCTAssertEqual(removed.map(\.id), [ids[0]]); XCTAssertNil(removed[0].new.locationSource)

        // The picker starts at the photos' own location, else the one taken closest in time.
        let others = try await [store.asset(ids[1]), store.asset(ids[2])]
        let start = await store.startingLocation(for: others)
        XCTAssertEqual(start?.latitude, 45.5); XCTAssertEqual(start?.longitude, 9.2)
        let own = await store.startingLocation(for: [others[0].placed(1, 2)])
        XCTAssertEqual(own?.latitude, 1)
    }
}

private extension CatalogAsset {
    func placed(_ latitude: Double, _ longitude: Double) -> CatalogAsset { var asset = self; asset.latitude = latitude; asset.longitude = longitude; return asset }
}
