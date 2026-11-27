import XCTest
import GRDB
@testable import CevicheCore

final class DevelopmentMergeTests: XCTestCase {
    /// Mask rasters, by the blob ID the stored form names them with.
    private var blobs: [String: Data] = [:]
    private func stored(_ edits: Adjustments) throws -> Data {
        try RevisionPayload.encode(edits, blob: { data in
            let id = String(data.hashValue, radix: 16); self.blobs[id] = data; return id
        }, resource: { _ in throw EditorError.invalidDocument("no resources") })
    }
    private func read(_ data: Data) throws -> Adjustments {
        try RevisionPayload.decode(data, blob: { id in self.blobs[id]! }, resource: { _ in throw EditorError.invalidDocument("no resources") })
    }
    private func merge(_ base: Adjustments, _ ours: Adjustments, _ theirs: Adjustments, winner: DevelopmentMerge.Side = .theirs) throws -> (Adjustments, [String]) {
        let result = try DevelopmentMerge.merge(base: stored(base), ours: stored(ours), theirs: stored(theirs), winner: winner)
        // Either device may do the merge: with the sides swapped it must give the same bytes.
        let swapped = try DevelopmentMerge.merge(base: stored(base), ours: stored(theirs), theirs: stored(ours), winner: winner == .ours ? .theirs : .ours)
        XCTAssertEqual(result, swapped, "The merge depends on which side does it")
        return (try read(result.data), result.conflicts)
    }
    private func mask(_ name: String, _ number: Int) -> PhotoMask {
        var mask = PhotoMask(kind: .subject); mask.name = name
        mask.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
        return mask
    }

    func testChangesToDifferentSettingsBothSurvive() throws {
        var base = Adjustments(); base.exposure = 0.5
        var ours = base; ours.exposure = 1.2; ours.clarity = 20
        var theirs = base; theirs.contrast = 15; theirs.geometry.straighten = 2
        let (merged, conflicts) = try merge(base, ours, theirs)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(merged.exposure, 1.2); XCTAssertEqual(merged.clarity, 20)
        XCTAssertEqual(merged.contrast, 15); XCTAssertEqual(merged.geometry.straighten, 2)
    }
    func testTheSameChangeOnBothSidesIsNoConflict() throws {
        var ours = Adjustments(); ours.exposure = 1
        let (merged, conflicts) = try merge(Adjustments(), ours, ours)
        XCTAssertEqual(conflicts, []); XCTAssertEqual(merged, ours)
    }
    func testASettingBothChangedTakesTheWinnersAndIsListed() throws {
        var ours = Adjustments(); ours.exposure = 1
        var theirs = Adjustments(); theirs.exposure = -1; theirs.contrast = 10
        let (merged, conflicts) = try merge(Adjustments(), ours, theirs, winner: .ours)
        XCTAssertEqual(conflicts, ["exposure"])
        XCTAssertEqual(merged.exposure, 1); XCTAssertEqual(merged.contrast, 10)
    }
    func testAResetToTheDefaultIsAChange() throws {
        var base = Adjustments(); base.exposure = 1; base.vibrance = 10
        var ours = base; ours.exposure = 0
        var theirs = base; theirs.vibrance = 30
        let (merged, conflicts) = try merge(base, ours, theirs)
        XCTAssertEqual(conflicts, []); XCTAssertEqual(merged.exposure, 0); XCTAssertEqual(merged.vibrance, 30)
    }
    func testWhiteBalanceAndCropMergeAsOne() throws {
        var ours = Adjustments(); ours.temperature = 5200
        var theirs = Adjustments(); theirs.tint = 12
        var (merged, conflicts) = try merge(Adjustments(), ours, theirs, winner: .theirs)
        XCTAssertEqual(conflicts, ["temperature + tint"])
        XCTAssertEqual(merged.temperature, 6500); XCTAssertEqual(merged.tint, 12)

        var rotated = Adjustments(); rotated.quarterTurns = 1
        var cropped = Adjustments(); cropped.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        (merged, conflicts) = try merge(Adjustments(), rotated, cropped, winner: .ours)
        XCTAssertEqual(conflicts, ["geometry + quarterTurns"])
        XCTAssertEqual(merged.quarterTurns, 1); XCTAssertEqual(merged.geometry.crop, CropRect.full)
    }
    func testMasksMergeOneByOne() throws {
        var sky = mask("Sky", 1); sky.raster = Data(repeating: 7, count: 4096)
        var base = Adjustments(); base.masks = [sky, mask("Face", 2)]
        // Ours darkens the sky and adds a mask; theirs changes the face mask's opacity, removes nothing, adds one.
        var ours = base; ours.masks[0].adjustments.exposure = -1; ours.masks.append(mask("Water", 3))
        var theirs = base; theirs.masks[1].opacity = 0.5; theirs.masks.append(mask("Trees", 4))
        let (merged, conflicts) = try merge(base, ours, theirs)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(merged.masks.map(\.name), ["Sky", "Face", "Water", "Trees"], "The loser's new masks first, the winner's last")
        XCTAssertEqual(merged.masks[0].adjustments.exposure, -1); XCTAssertEqual(merged.masks[0].raster, sky.raster)
        XCTAssertEqual(merged.masks[1].opacity, 0.5)
    }
    func testAMaskBothChangedMergesItsSliders() throws {
        var base = Adjustments(); base.masks = [mask("Sky", 1)]
        var ours = base; ours.masks[0].adjustments.exposure = -1
        var theirs = base; theirs.masks[0].adjustments.saturation = 20; theirs.masks[0].opacity = 0.8
        let (merged, conflicts) = try merge(base, ours, theirs)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(merged.masks[0].adjustments.exposure, -1); XCTAssertEqual(merged.masks[0].adjustments.saturation, 20)
        XCTAssertEqual(merged.masks[0].opacity, 0.8)
    }
    func testADeletedMaskStaysDeletedUnlessTheOtherSideChangedIt() throws {
        var base = Adjustments(); base.masks = [mask("Sky", 1), mask("Face", 2)]
        var ours = base; ours.masks.removeAll { $0.name == "Sky" }
        var (merged, conflicts) = try merge(base, ours, base)
        XCTAssertEqual(merged.masks.map(\.name), ["Face"]); XCTAssertEqual(conflicts, [])

        var theirs = base; theirs.masks[0].opacity = 0.3
        (merged, conflicts) = try merge(base, ours, theirs, winner: .theirs)
        XCTAssertEqual(merged.masks.map(\.name), ["Sky", "Face"], "The winner changed it, so it comes back in its place")
        XCTAssertEqual(conflicts, ["masks › Sky"])
        (merged, _) = try merge(base, ours, theirs, winner: .ours)
        XCTAssertEqual(merged.masks.map(\.name), ["Face"])
    }
    func testAReorderOnOneSideIsKept() throws {
        var base = Adjustments(); base.masks = [mask("A", 1), mask("B", 2), mask("C", 3)]
        var ours = base; ours.masks.reverse()
        var theirs = base; theirs.masks[1].opacity = 0.5
        let (merged, _) = try merge(base, ours, theirs)
        XCTAssertEqual(merged.masks.map(\.name), ["C", "B", "A"]); XCTAssertEqual(merged.masks[1].opacity, 0.5)
    }
    func testRetouchStrokesFromBothSidesAreKeptInOrder() throws {
        func stroke(_ number: Int) -> RetouchStroke {
            var stroke = RetouchStroke(mode: .heal, source: MaskPoint(x: 0, y: 0), target: MaskPoint(x: Double(number) / 10, y: 0.5), radius: 0.02, softness: 0.5, opacity: 1)
            stroke.id = UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number))!
            return stroke
        }
        var base = Adjustments(); base.retouch = [stroke(1)]
        var ours = base; ours.retouch += [stroke(2), stroke(3)]
        var theirs = base; theirs.retouch += [stroke(4)]
        let (merged, conflicts) = try merge(base, ours, theirs, winner: .ours)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(merged.retouch.map(\.id), [1, 4, 2, 3].map { stroke($0).id })
    }
    func testDisabledSectionsMergeAsASet() throws {
        var base = Adjustments(); base.disabledSections = [.grain]
        var ours = base; ours.disabledSections = [.grain, .vignette]
        var theirs = base; theirs.disabledSections = []
        let (merged, _) = try merge(base, ours, theirs)
        XCTAssertEqual(merged.disabledSections, [.vignette])
    }
    func testSettingsFromANewerBuildPassThrough() throws {
        let base = Data(#"{"exposure":1}"#.utf8)
        let ours = Data(#"{"exposure":1,"futureTool":{"amount":3}}"#.utf8)
        let theirs = Data(#"{"contrast":10,"exposure":1}"#.utf8)
        let result = try DevelopmentMerge.merge(base: base, ours: ours, theirs: theirs, winner: .theirs)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), #"{"contrast":10,"exposure":1,"futureTool":{"amount":3}}"#)
    }
    func testWithoutABaseTheWinnerIsKeptWhole() throws {
        let ours = Data(#"{"exposure":1}"#.utf8), theirs = Data(#"{"contrast":10}"#.utf8)
        let result = try DevelopmentMerge.merge(base: nil, ours: ours, theirs: theirs, winner: .ours)
        XCTAssertEqual(result.data, ours); XCTAssertEqual(result.conflicts, ["*"])
    }
    func testAnInvalidMergeFallsBackToTheWinner() throws {
        let base = Data(#"{}"#.utf8), ours = Data(#"{"exposure":1}"#.utf8), theirs = Data(#"{"contrast":10}"#.utf8)
        let result = try DevelopmentMerge.merge(base: base, ours: ours, theirs: theirs, winner: .theirs, isValid: { _ in false })
        XCTAssertEqual(result.data, theirs); XCTAssertEqual(result.conflicts, ["*"])
    }

    // MARK: - State

    private func state(_ change: (inout CatalogSyncState) -> Void = { _ in }) -> CatalogSyncState {
        var metadata = CatalogMetadata(); metadata.keywords = "sky, sea"
        var state = CatalogSyncState(assetID: "A", origin: "file:///a.ARW", isCopy: false, metadata: metadata, trashedAt: nil, stackID: nil, updatedAt: Date(timeIntervalSince1970: 0))
        change(&state)
        return state
    }
    func testRatingOnOneDeviceAndKeywordsOnAnotherBothSurvive() {
        let base = state()
        let phone = state { $0.metadata.rating = 4; $0.updatedAt = Date(timeIntervalSince1970: 20) }
        let mac = state { $0.metadata.keywords = "sky, sea, dusk"; $0.updatedAt = Date(timeIntervalSince1970: 10) }
        let (merged, conflicts) = CatalogSyncState.merged(base: base, ours: mac, theirs: phone, winner: .theirs)
        XCTAssertEqual(conflicts, [])
        XCTAssertEqual(merged.metadata.rating, 4); XCTAssertEqual(merged.metadata.keywordList, ["sky", "sea", "dusk"])
        XCTAssertEqual(merged.updatedAt, Date(timeIntervalSince1970: 20))
    }
    func testKeywordsAddedAndRemovedOnBothSides() {
        let base = state()
        let ours = state { $0.metadata.keywords = "sea, boat" }
        let theirs = state { $0.metadata.keywords = "sky, sea, sunset" }
        let (merged, _) = CatalogSyncState.merged(base: base, ours: ours, theirs: theirs, winner: .ours)
        XCTAssertEqual(merged.metadata.keywordList, ["sea", "boat", "sunset"])
    }
    func testTheLocationMergesAsOne() {
        let base = state()
        let ours = state { $0.metadata.latitude = 1; $0.metadata.longitude = 2 }
        let theirs = state { $0.metadata.latitude = 3; $0.metadata.longitude = 4; $0.metadata.rating = 2 }
        let (merged, conflicts) = CatalogSyncState.merged(base: base, ours: ours, theirs: theirs, winner: .ours)
        XCTAssertEqual(conflicts, ["location"])
        XCTAssertEqual(merged.metadata.latitude, 1); XCTAssertEqual(merged.metadata.longitude, 2); XCTAssertEqual(merged.metadata.rating, 2)
    }

    // MARK: - A real catalog

    /// Every development in a catalog (read only): merging it with an unchanged base gives it back, its merge with
    /// another photo's development decodes, and either side merging gives the same bytes. Set
    /// `CEVICHE_MERGE_CATALOG` to a catalog folder.
    func testRealDevelopmentsMergeCleanly() throws {
        guard let path = ProcessInfo.processInfo.environment["CEVICHE_MERGE_CATALOG"] else { throw XCTSkip("CEVICHE_MERGE_CATALOG not set") }
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: URL(fileURLWithPath: path).appendingPathComponent("catalog.sqlite").path, configuration: configuration)
        let developments = try database.read { try Data.fetchAll($0, sql: "SELECT adjustmentsData FROM assetDevelopment WHERE adjustmentsData IS NOT NULL") }
        let blobs = try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, data FROM blob").map { (String($0["id"] as String), $0["data"] as Data) })
        }
        func decodes(_ data: Data) -> Bool {
            (try? RevisionPayload.decode(data, blob: { blobs[$0] ?? Data() }, resource: { _ in Data() })) != nil
        }
        var merged = 0, conflicted = 0, failed = 0
        for (index, ours) in developments.enumerated() {
            let theirs = developments[(index + 1) % developments.count]
            XCTAssertEqual(try DevelopmentMerge.merge(base: ours, ours: ours, theirs: theirs, winner: .ours).data,
                           try DevelopmentMerge.merge(base: ours, ours: theirs, theirs: theirs, winner: .ours).data)
            // Unrelated photos stand in for two devices' edits of one: the worst case for conflicts.
            let base = Data("{}".utf8)
            let a = try DevelopmentMerge.merge(base: base, ours: ours, theirs: theirs, winner: .ours)
            let b = try DevelopmentMerge.merge(base: base, ours: theirs, theirs: ours, winner: .theirs)
            XCTAssertEqual(a, b)
            merged += 1; if !a.conflicts.isEmpty { conflicted += 1 }
            if decodes(ours), decodes(theirs), !decodes(a.data) { failed += 1 }
        }
        print("Merged \(merged) developments: \(conflicted) with conflicts, \(failed) that no longer decode")
        XCTAssertEqual(failed, 0)
    }
}
