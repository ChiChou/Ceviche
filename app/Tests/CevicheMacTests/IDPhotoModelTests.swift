import XCTest
import CevicheCore
import CevicheTestSupport
@testable import CevicheMac

/// The ID Photo tool's state as the dialog drives it, on a real portrait in a catalog.
final class IDPhotoModelTests: XCTestCase {
    @MainActor private func fixture() async throws -> (URL, CatalogModel, EditorModel, CatalogAsset) {
        let source = try TestSamples.require(TestSamples.idPortrait)
        // The tool remembers the last paper and document; each test starts from the defaults.
        IDPhotoModel.remember(nil)
        // Most tests start from a document kept with "Use next time"; testChoosingTheDocument starts without one.
        UserDefaults.standard.set("eu-schengen-visa", forKey: IDPhotoModel.specKey)
        // Replace Background starts on until the user turns it off; these tests start from the photo's own background.
        UserDefaults.standard.removeObject(forKey: IDPhotoModel.replaceBackgroundKey)
        XCTAssertTrue(IDPhotoModel.replacesBackground)
        IDPhotoModel.replacesBackground = false
        let (directory, _) = try EditorFixtures.photo()
        let suite = UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let model = CatalogModel(preferences: preferences)
        await model.openCatalog(directory.appendingPathComponent("Catalog"))
        preferences.removePersistentDomain(forName: suite)
        let store = try XCTUnwrap(model.store)
        let url = directory.appendingPathComponent("portrait.dng")
        try FileManager.default.copyItem(at: source, to: url)
        let prepared = try CatalogImporter.prepare(url)
        let asset = try await store.insert(prepared.0, thumbnail: prepared.1)
        await model.refresh()
        return (directory, model, EditorModel(), asset)
    }

    @MainActor private func opened(_ catalog: CatalogModel, _ asset: CatalogAsset) async throws -> IDPhotoModel {
        let model = IDPhotoModel(asset: asset)
        model.start(catalog: catalog)
        try await until("the photo is ready") { model.stage == .ready }
        return model
    }

    @MainActor private func until(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock(), end = clock.now + timeout
        while !condition() {
            guard clock.now < end else { return XCTFail("Timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Off and on again, many times and quickly, always ends with the replaced preview showing when it's on.
    @MainActor func testTogglingBackgroundKeepsItReplaced() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        model.replaceBackground(true)
        try await until("the matte is made") { model.replaced != nil }
        for round in 0..<12 {
            model.replaceBackground(false)
            XCTAssertNil(model.replaced, "round \(round)")
            XCTAssertNil(model.layout?.background)
            model.replaceBackground(true)
            XCTAssertNotNil(model.replaced, "round \(round): the replaced preview comes back at once")
            XCTAssertEqual(model.checks.first { $0.id == "background" }?.detail, L10n.tr("Replaced"))
        }
        // Toggled while the matte is still being made.
        let fresh = try await opened(catalog, asset)
        fresh.replaceBackground(true); fresh.replaceBackground(false); fresh.replaceBackground(true)
        try await until("the matte is made") { !fresh.matting }
        XCTAssertNotNil(fresh.replaced)
        XCTAssertNil(fresh.matteError)
    }

    /// Find Face moves the markers back and keeps everything else.
    @MainActor func testFindFaceKeepsSettings() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        let found = try XCTUnwrap(model.layout)
        model.replaceBackground(true)
        model.layout?.headSize = 0.9; model.layout?.offsetMM = 1.5; model.layout?.sheet.paper = .a4
        model.layout?.crown.y += 0.05
        model.placeMarkers()
        let layout = try XCTUnwrap(model.layout)
        XCTAssertEqual(layout.crown, found.crown)
        XCTAssertEqual(layout.headSize, 0.9); XCTAssertEqual(layout.offsetMM, 1.5)
        XCTAssertEqual(layout.sheet.paper, .a4); XCTAssertNotNil(layout.background)
    }

    /// Head size grows the frame past the canvas's region, which follows it; a marker drag doesn't move it.
    @MainActor func testCanvasFollowsTheFrame() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        model.layout?.headSize = 0
        let region = model.region
        model.layout?.chin.y += 0.01
        XCTAssertEqual(model.region, region, "dragging a marker leaves the canvas still")
        model.layout?.offsetMM = 4
        XCTAssertTrue(model.region.contains(model.frameCorners), "the canvas shows the whole frame")
    }

    /// Auto white balance in the tool goes to the photo's development, which the tool opens with next time; the layout
    /// (here a replaced background) is not kept.
    @MainActor func testWhiteBalanceIsSavedAndRestored() async throws {
        let (directory, catalog, editor, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        XCTAssertEqual(model.checks.first { $0.id == "cast" }?.status, .warning)
        let shot = try XCTUnwrap(model.development?.temperature)
        model.autoWhiteBalance()
        try await until("white balance is solved") { model.balance != nil && !model.balancing }
        let balanced = try XCTUnwrap(model.balance)
        XCTAssertLessThan(balanced.temperature, shot)
        XCTAssertEqual(model.checks.first { $0.id == "cast" }?.status, .pass)
        model.replaceBackground(true)
        try await until("the matte is made") { model.replaced != nil }
        await catalog.saveIDPhotoWhiteBalance([IDPhotoSave(asset: asset, balance: try XCTUnwrap(model.developChanges))], editor: editor)
        model.stop()

        let saved = try await XCTUnwrapAsync(try await catalog.store?.savedAdjustments(of: try await catalog.store!.asset(asset.id)))
        XCTAssertEqual(saved.temperature, balanced.temperature); XCTAssertEqual(saved.tint, balanced.tint)

        let again = try await opened(catalog, asset)
        XCTAssertNil(again.layout?.background, "the layout is framed afresh, not restored")
        XCTAssertEqual(again.development?.temperature, balanced.temperature)
        XCTAssertEqual(again.checks.first { $0.id == "cast" }?.status, .pass)
    }
    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

    /// Copies of several photos (here three imports of one portrait) laid out over sheets, and the settings a batch
    /// shares reaching every photo while each keeps its own framing.
    @MainActor func testBatch() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(catalog.store)
        var assets = [asset]
        for index in 1...2 {
            let url = directory.appendingPathComponent("portrait-\(index).dng")
            try FileManager.default.copyItem(at: try TestSamples.require(TestSamples.idPortrait), to: url)
            let prepared = try CatalogImporter.prepare(url)
            assets.append(try await store.insert(prepared.0, thumbnail: prepared.1))
        }
        let session = IDPhotoSession(request: IDPhotoRequest(assets: assets))
        XCTAssertTrue(session.isBatch); XCTAssertEqual(session.current, 0)
        session.start(catalog: catalog)
        try await until("every photo is ready") { session.ready.count == 3 && session.settled }
        XCTAssertEqual(session.counts, [2, 2, 2], "two copies each by default")

        // A shared setting set on one photo reaches the others; framing stays each photo's.
        session.photos[1].layout?.crown.y += 0.02
        let uk = try XCTUnwrap(IDPhotoSpecs.spec("gb-passport"))
        session.select(uk)
        session.setShared { $0.sheet.paper = .photo4x6; $0.sheet.spacing = .lab }
        for photo in session.photos {
            XCTAssertEqual(photo.layout?.spec, uk); XCTAssertEqual(photo.layout?.sheet.paper, .photo4x6)
        }
        XCTAssertNotEqual(session.photos[1].layout?.crown, session.photos[0].layout?.crown)
        session.photos[2].layout?.sheet.spacing = .edgeToEdge   // changed on one photo, as its own panel would
        XCTAssertTrue(session.photos.allSatisfy { $0.layout?.sheet.spacing == .edgeToEdge })
        session.setShared { $0.sheet.spacing = .lab }

        // 2 + 2 + 2 on a 6-place sheet: one sheet; 4 + 2 + 2: the third photo's copies start a second.
        XCTAssertEqual(session.capacity, 6); XCTAssertEqual(session.sheetCount, 1)
        session.setCopies(4, of: session.photos[0])
        XCTAssertEqual(session.sheetCount, 2)
        XCTAssertEqual(session.counts, [4, 2, 2], "copies are each photo's own, not shared")

        session.replaceBackground(true)
        try await until("every matte is made") { session.photos.allSatisfy { $0.replaced != nil } }
        try await until("the sheets are laid out") { session.sheetPreviews.count == 2 }
        let sheets = try await session.renderSheets()
        XCTAssertEqual(sheets.count, 2)
        XCTAssertEqual(sheets[0].width, Int((101.6 / 25.4 * 300).rounded()))
        session.stop()
    }

    /// Two photos of a batch open with one set of shared settings, whichever finishes developing first.
    @MainActor func testBatchAgreesOnOpening() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(catalog.store)
        let url = directory.appendingPathComponent("portrait-2.dng")
        try FileManager.default.copyItem(at: try TestSamples.require(TestSamples.idPortrait), to: url)
        let prepared = try CatalogImporter.prepare(url)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        for _ in 0..<3 {
            let session = IDPhotoSession(request: IDPhotoRequest(assets: [asset, second]))
            session.start(catalog: catalog)
            try await until("every photo is ready") { session.ready.count == 2 }
            let backgrounds = session.photos.map { $0.layout?.background }
            XCTAssertEqual(backgrounds[0], backgrounds[1], "the photos share one background setting")
            XCTAssertTrue(session.photos[0].layout!.sharesSettings(with: session.photos[1].layout!))
            session.stop()
        }
    }

    /// A selfie under room light before a cream wall: two fixable issues, each with its fix; fixed, it's ready.
    /// A warning can be let stand, and a photo left out of the sheets comes back.
    @MainActor func testIssuesAndFixes() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        let fixes = Dictionary(model.issues.map { ($0.id, $0.fix) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(fixes["cast"], .autoWhiteBalance)
        XCTAssertEqual(fixes["background"], .replaceBackground)
        XCTAssertEqual(model.readiness, .needsFix)
        model.autoWhiteBalance()
        try await until("white balance is solved") { model.balance != nil && !model.balancing }
        model.replaceBackground(true)
        try await until("the matte is made") { model.replaced != nil }
        XCTAssertNil(model.issues.first { $0.id == "cast" || $0.id == "background" }, "\(model.issues.map(\.id))")
        XCTAssertNotEqual(model.readiness, .retake)
        // Japan limits the space above the head to 2–6 mm; 4 mm lower is past it.
        model.select(try XCTUnwrap(IDPhotoSpecs.spec("jp-passport")))
        model.layout?.offsetMM = 4
        XCTAssertEqual(model.issues.first { $0.id == "crown" }?.fix, .fitToSpec)
        XCTAssertNotEqual(model.readiness, .ready)
        model.fitToSpec()
        XCTAssertNil(model.issues.first { $0.id == "crown" })
        model.stop()
    }

    @MainActor func testLeaveOut() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(catalog.store)
        let url = directory.appendingPathComponent("portrait-2.dng")
        try FileManager.default.copyItem(at: try TestSamples.require(TestSamples.idPortrait), to: url)
        let prepared = try CatalogImporter.prepare(url)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        let session = IDPhotoSession(request: IDPhotoRequest(assets: [asset, second]))
        session.start(catalog: catalog)
        try await until("every photo is ready") { session.settled && session.ready.count == 2 }
        session.leaveOut(session.photos[1])
        XCTAssertTrue(session.isLeftOut(session.photos[1]))
        XCTAssertEqual(session.counts, [2, 0])
        XCTAssertTrue(session.pages.allSatisfy { !$0.contains(1) })
        session.resetCopies(of: session.photos[1])
        XCTAssertEqual(session.counts, [2, 2])
        session.remove(session.photos[0])
        XCTAssertEqual(session.photos.count, 1); XCTAssertEqual(session.current, 0)
        session.remove(session.photos[0])
        XCTAssertEqual(session.photos.count, 1, "the last photo stays")
        session.stop()
    }

    /// Leaving keeps only a white balance set in the tool, once: opening the photo or moving its framing records
    /// nothing, since the layout is never kept.
    @MainActor func testOnlyWhiteBalanceIsKept() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = IDPhotoSession(request: IDPhotoRequest(asset: asset))
        session.start(catalog: catalog)
        try await until("the photo is ready") { session.settled }
        XCTAssertTrue(session.takeSaves().isEmpty, "opening changes nothing")
        session.shown.layout?.headSize = 0.8
        XCTAssertTrue(session.takeSaves().isEmpty, "the framing is not kept")
        session.shown.autoWhiteBalance()
        try await until("white balance is solved") { session.shown.balance != nil && !session.shown.balancing }
        XCTAssertEqual(session.takeSaves().count, 1)
        XCTAssertTrue(session.takeSaves().isEmpty, "kept once")
        session.stop()
    }

    /// Nothing is assumed: with no document kept for next time, the photos wait for one; choosing it frames them all,
    /// and it's remembered only when asked.
    @MainActor func testChoosingTheDocument() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory); IDPhotoModel.remember(nil) }
        IDPhotoModel.remember(nil)
        let store = try XCTUnwrap(catalog.store)
        let url = directory.appendingPathComponent("portrait-2.dng")
        try FileManager.default.copyItem(at: try TestSamples.require(TestSamples.idPortrait), to: url)
        let prepared = try CatalogImporter.prepare(url)
        let second = try await store.insert(prepared.0, thumbnail: prepared.1)
        let session = IDPhotoSession(request: IDPhotoRequest(assets: [asset, second]))
        session.start(catalog: catalog)
        try await until("both are developed") { session.ready.count == 2 }
        XCTAssertTrue(session.needsDocument)
        XCTAssertNil(session.layout); XCTAssertEqual(session.sheetCount, 0)
        XCTAssertFalse(session.rememberChoice)
        let uk = try XCTUnwrap(IDPhotoSpecs.spec("gb-passport"))
        session.select(uk)
        XCTAssertFalse(session.needsDocument)
        XCTAssertTrue(session.photos.allSatisfy { $0.layout?.spec == uk })
        XCTAssertNil(IDPhotoModel.rememberedSpec, "not remembered unless asked")
        session.rememberChoice = true
        XCTAssertEqual(IDPhotoModel.rememberedSpec, uk); XCTAssertTrue(session.rememberChoice)
        // While ticked, a later change is remembered too.
        session.setShared { $0.sheet.paper = .photoL }
        XCTAssertEqual(IDPhotoModel.rememberedSheet.paper, .photoL)
        session.rememberChoice = false
        XCTAssertNil(IDPhotoModel.rememberedSpec)
        session.stop()
    }

    /// A single photo fills its sheet, and its sheet preview follows the paper.
    @MainActor func testSingleSheet() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = IDPhotoSession(request: IDPhotoRequest(asset: asset))
        XCTAssertEqual(session.current, 0)
        session.start(catalog: catalog)
        try await until("the photo is ready") { session.settled }
        session.setShared { $0.sheet.paper = .photoL; $0.sheet.spacing = .lab }
        XCTAssertEqual(session.counts, [4])
        let ppm = IDPhotoSession.sheetPreviewPixelsPerMM
        try await until("the sheet is laid out") { session.sheetPreviews.first.map { abs(Double($0.width) - 89 * ppm) <= 1 } == true }
        // Single Photo paper: the print on its own.
        session.setShared { $0.sheet.paper = .single }
        XCTAssertEqual(session.pages, [[0]])
        try await until("the print is shown") { session.sheetPreviews.first.map { abs(Double($0.height) - session.layout!.spec.heightMM * ppm) <= 1 } == true }
        session.stop()
    }

    /// The full-resolution detail of a region renders at the size asked, and is dropped when the background
    /// changes, since it shows the old one.
    @MainActor func testDetail() async throws {
        let (directory, catalog, _, asset) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await opened(catalog, asset)
        XCTAssertEqual(model.visibleRegion, model.region)
        let preview = try XCTUnwrap(model.preview), full = try XCTUnwrap(model.renderer?.size)
        let eye = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.08)
        let size = CGSize(width: (eye.width * full.width).rounded(), height: (eye.height * full.height).rounded())
        // This phone DNG is barely larger than the preview; a camera RAW has several times its pixels here.
        XCTAssertGreaterThanOrEqual(size.width, eye.width * Double(preview.width))
        model.requestDetail(eye, size: size)
        try await until("the detail is rendered") { model.detail != nil }
        XCTAssertEqual(model.detail?.region, eye)
        XCTAssertEqual(model.detail?.image.width, Int(size.width))
        // Turning the background on drops the detail, which shows the old background.
        model.replaceBackground(true)
        try await until("the matte is made") { model.replaced != nil }
        XCTAssertNil(model.detail)
    }
}

/// The document list's columns on a wide canvas.
final class IDPhotoSpecListTests: XCTestCase {
    func testColumnsKeepTheOrderBalanceRowsAndNeverSplitAGroup() {
        let specs = Array(IDPhotoSpecs.all.prefix(6))
        let groups: [IDPhotoSpecList.Group] = [("A", Array(specs.prefix(4))), ("B", [specs[0]]), ("C", [specs[1], specs[2]]), ("D", [specs[3]]), ("E", Array(specs.prefix(3)))]
        let one = IDPhotoSpecList.split(groups, into: 1)
        XCTAssertEqual(one.map { $0.map(\.name) }, [["A", "B", "C", "D", "E"]])
        // 16 rows over two columns: A and B (7) then C, D and E (9).
        let two = IDPhotoSpecList.split(groups, into: 2)
        XCTAssertEqual(two.map { $0.map(\.name) }, [["A", "B"], ["C", "D", "E"]])
        let three = IDPhotoSpecList.split(groups, into: 3)
        XCTAssertEqual(three.flatMap { $0.map(\.name) }, ["A", "B", "C", "D", "E"], "Down one column, then on into the next")
        XCTAssertLessThanOrEqual(three.count, 3)
        XCTAssertEqual(IDPhotoSpecList.split([], into: 3).count, 1)
    }
}
