import XCTest
import GRDB
import ImageIO
@testable import CevicheCore

final class CatalogSearchSchemaTests: XCTestCase {
    func testFocalFilterUses35mmEquivalentWithActualFallback() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        for (id, actual, equivalent) in [("wide", 2.22, Optional(14.0)), ("legacy", 50.0, nil), ("unknown", 85.0, nil)] {
            var asset = try photo(url, id: id, captureTime: "2026:11:06 00:00:00")
            asset.focalLength = actual; asset.focalLength35mm = equivalent
            _ = try await store.insert(asset, thumbnail: nil)
        }
        let bounds = try await store.focalRange()
        XCTAssertEqual(bounds, 14...85)
        var filter = CatalogFilter(); filter.focalLength = 14...14
        let wide = try await store.assets(filter: filter)
        XCTAssertEqual(wide.map(\.id), ["wide"])
        filter.focalLength = 2...3
        let actual = try await store.assets(filter: filter)
        XCTAssertTrue(actual.isEmpty)
        filter.focalLength = 50...85
        let fallback = try await store.assets(filter: filter)
        XCTAssertEqual(Set(fallback.map(\.id)), ["legacy", "unknown"])
        try await store.moveToTrash("wide")
        let activeBounds = try await store.focalRange()
        let trashBounds = try await store.focalRange(area: .trash)
        XCTAssertEqual(activeBounds, 50...85)
        XCTAssertEqual(trashBounds, 14...14)
    }
    private func photo(_ url: URL, id: String, captureTime: String, latitude: Double? = nil, longitude: Double? = nil, keywords: String = "") throws -> CatalogPhoto {
        var asset = try CatalogImporter.prepare(url).0
        asset.id = id; asset.importPath += "#" + id; asset.captureTime = captureTime
        var metadata = asset.metadata; metadata.latitude = latitude; metadata.longitude = longitude; metadata.keywords = keywords
        asset.metadata = metadata
        return asset
    }

    func testNewCatalogUsesIncrementalVacuumAndImportFillsCamera() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        let mode = try await db.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }
        XCTAssertEqual(mode, 2)
        let imported = try await store.insert(CatalogImporter.prepare(url).0, thumbnail: nil)
        let exif = try await store.exif(imported.id)
        XCTAssertEqual(imported.camera, CatalogCamera(extracted: exif.extractedMetadata))
        try await store.reclaimSpace()
    }

    func testPlacesComeFromLookupsAndNearbyPhotosAndCanBeSearched() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let located = try photo(url, id: "located", captureTime: "2025-07-01T10:00:00", latitude: 46.5405, longitude: 12.1357)
        let sameSquare = try photo(url, id: "same-square", captureTime: "2025-07-03T10:00:00", latitude: 46.5411, longitude: 12.1361)
        let camera = try photo(url, id: "camera", captureTime: "2025-07-01T10:40:00")
        let later = try photo(url, id: "later", captureTime: "2025-07-01T22:00:00")
        for asset in [located, sameSquare, camera, later] { _ = try await store.insert(asset, thumbnail: nil) }
        // Where Set Location starts for a photo without one: the located photo taken closest in time.
        let nearest = try await store.nearestLocation(to: "2025-07-01T11:00:00"); XCTAssertEqual(nearest?.latitude, 46.5405)
        let laterNearest = try await store.nearestLocation(to: "2025-07-03T09:00:00"); XCTAssertEqual(laterNearest?.latitude, 46.5411)

        let pending = try await store.pendingPlaceCells(locale: "en")
        XCTAssertEqual(pending.map(\.key), [CatalogPlaceCell.key(latitude: 46.5405, longitude: 12.1357)], "One lookup per square")
        let cortina = CatalogPlace(country: "Italy", region: "Veneto", city: "Cortina d'Ampezzo")
        try await store.recordPlace(cortina, cell: pending[0].key, locale: "en")
        let inferred = try await store.inferPlaces()
        XCTAssertEqual(inferred, 1)
        for (id, source) in [("located", "gps"), ("same-square", "gps"), ("camera", "nearby")] {
            let asset = try await store.asset(id)
            XCTAssertEqual(asset.placeCity, "Cortina d'Ampezzo", id); XCTAssertEqual(asset.placeSource, source, id)
        }
        let far = try await store.asset("later"); XCTAssertNil(far.placeSource, "Twelve hours from the nearest located photo")
        let none = try await store.pendingPlaceCells(locale: "en"); XCTAssertTrue(none.isEmpty)

        var filter = CatalogFilter(); filter.search = "cortina"
        let found = try await store.assets(filter: filter); XCTAssertEqual(Set(found.map(\.id)), ["located", "same-square", "camera"])
        filter.search = "veneto"
        let byRegion = try await store.count(filter: filter); XCTAssertEqual(byRegion, 3)
        let suggested = try await store.searchSuggestions(for: "ven")
        XCTAssertEqual(suggested.map(\.tag), ["Veneto"]); XCTAssertEqual(suggested.first?.source, .place); XCTAssertEqual(suggested.first?.photoCount, 3)

        // Moving a photo names it again; a square with nothing in it is remembered as such.
        var moved = located.metadata; moved.latitude = 10.0; moved.longitude = -30.0
        try await store.updateMetadata(moved, assetID: "located")
        let cleared = try await store.asset("located"); XCTAssertNil(cleared.placeCity); XCTAssertNil(cleared.placeSource)
        let sea = try await store.pendingPlaceCells(locale: "en")
        XCTAssertEqual(sea.map(\.key), [CatalogPlaceCell.key(latitude: 10, longitude: -30)])
        try await store.recordPlace(nil, cell: sea[0].key, locale: "en")
        let afterSea = try await store.pendingPlaceCells(locale: "en"); XCTAssertTrue(afterSea.isEmpty)
        // The nearby photo now borrows from the photo at sea, which has no name: its inferred place goes.
        try await store.inferPlaces()
        let orphan = try await store.asset("camera"); XCTAssertNil(orphan.placeSource)
        // Names are looked up again in another language.
        let italian = try await store.pendingPlaceCells(locale: "it"); XCTAssertEqual(italian.count, 2)
    }

    func testAnalysisRecordsConfidenceOfAutomaticTags() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let asset = try await store.insert(CatalogImporter.prepare(url).0, thumbnail: nil)
        let pending = try await store.claimAnalysis(owner: "confidence", version: CatalogImporter.analysisVersion)
        let claim = try XCTUnwrap(pending)
        let applied = try await store.finishAnalysis(claim, tags: "mountain, Sky", version: CatalogImporter.analysisVersion, confidences: ["mountain": 0.9, "sky": 0.4])
        XCTAssertTrue(applied)
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        let rows = try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT tag, confidence FROM assetTag WHERE assetID = ? AND source = 'automatic' ORDER BY tag", arguments: [asset.id])
                .map { ($0["tag"] as String, $0["confidence"] as Double) }
        }
        XCTAssertEqual(rows.map(\.0), ["mountain", "sky"])
        XCTAssertEqual(rows.map(\.1), [0.9, 0.4])
    }

    func testSearchMatchesWordStartsFileNumbersAndUnspacedScripts() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var tokyo = try photo(url, id: "tokyo", captureTime: "2026-09-19T12:00:00", keywords: "Südtirol")
        tokyo.filename = "DSC01234.ARW"; tokyo.suggestedTags = "police car, street"; tokyo.placeRegion = "Tokyo"
        var veneto = try photo(url, id: "veneto", captureTime: "2025-07-01T10:00:00")
        veneto.filename = "IMG_2001.JPG"; veneto.suggestedTags = "carousel, scarf"; veneto.placeRegion = "Veneto"
        var party = try photo(url, id: "party", captureTime: "2025-07-02T10:00:00", keywords: "东京旅行")
        party.filename = "party.heic"; party.title = "家庭聚会"
        for asset in [tokyo, veneto, party] { _ = try await store.insert(asset, thumbnail: nil) }
        func search(_ text: String) async throws -> Set<String> {
            var filter = CatalogFilter(); filter.search = text
            return Set(try await store.assets(filter: filter).map(\.id))
        }
        let expectations: [(String, Set<String>)] = [
            ("car", ["tokyo", "veneto"]), ("scar", ["veneto"]), ("arf", []),
            ("to", ["tokyo"]), ("police car", ["tokyo"]), ("police c", ["tokyo"]),
            ("1234", ["tokyo"]), ("dsc012", ["tokyo"]), ("2001", ["veneto"]),
            ("sudtirol", ["tokyo"]), ("SÜD", ["tokyo"]),
            ("聚会", ["party"]), ("东京", ["party"]), ("旅行", ["party"]),
            ("-", ["tokyo", "veneto", "party"]), ("car\"", ["tokyo", "veneto"]), ("\"", ["tokyo", "veneto", "party"]), ("OR", []), ("NEAR(", []),
        ]
        for (text, expected) in expectations {
            let found = try await search(text); XCTAssertEqual(found, expected, text)
        }
        // Every writer keeps the index in step: edits, places, trash and removal.
        var metadata = party.metadata; metadata.keywords = "birthday"
        try await store.updateMetadata(metadata, assetID: "party")
        let edited = try await search("birth"); XCTAssertEqual(edited, ["party"])
        let old = try await search("旅行"); XCTAssertTrue(old.isEmpty)
        try await store.recordPlace(CatalogPlace(country: "Italy", city: "Cortina d'Ampezzo"), cell: "x", locale: "en")
        try await store.moveToTrash("veneto")
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = 'tokyo'")
            try db.execute(sql: "INSERT INTO assetSearch(assetSearch, rank) VALUES ('integrity-check', 1)")
        }
        let removed = try await search("police"); XCTAssertTrue(removed.isEmpty)
    }

    func testBroadSearchPagesKeepTheirOrder() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        for index in 0..<30 {
            var asset = try photo(url, id: String(format: "p%02d", index), captureTime: "2025-07-01T10:00:00")
            var metadata = asset.metadata; metadata.captureDay = String(format: "2025-07-%02d", index + 1); asset.metadata = metadata
            asset.suggestedTags = "sky"
            _ = try await store.insert(asset, thumbnail: nil)
        }
        var filter = CatalogFilter(); filter.search = "sk"
        let first = try await store.assets(filter: filter, limit: 10)
        let second = try await store.assets(filter: filter, limit: 10, offset: 10)
        XCTAssertEqual(first.map(\.id), (20..<30).reversed().map { String(format: "p%02d", $0) }, "Newest first")
        XCTAssertEqual(second.map(\.id), (10..<20).reversed().map { String(format: "p%02d", $0) })
        let all = try await store.assets(filter: filter, limit: 100_000); XCTAssertEqual(all.count, 30)
    }

    func testSuggestionsMatchWordStartsAndPickExactCamerasLensesAndSettings() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        func shot(_ id: String, make: String, model: String, lens: String, f: Double, mm: Double, time: Double, iso: Int,
                  lensMake: String? = nil, bias: Double? = nil, flash: Bool? = nil, artist: String? = nil, keywords: String = "") throws -> CatalogPhoto {
            var asset = try photo(url, id: id, captureTime: "2026-09-19T12:00:00", keywords: keywords)
            var camera = CatalogCamera(); camera.make = make; camera.model = model; camera.lens = lens; camera.lensMake = lensMake; camera.fNumber = f; camera.focalLength = mm
            camera.exposureTime = time; camera.iso = iso; camera.exposureBias = bias; camera.flashFired = flash; camera.artist = artist
            asset.camera = camera
            return asset
        }
        for asset in [try shot("a", make: "SONY", model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM II", f: 2.8, mm: 35, time: 0.004, iso: 200, lensMake: "Sony", flash: true, keywords: "fence"),
                      try shot("b", make: "SONY", model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM", f: 8, mm: 70, time: 2, iso: 3200, bias: 2.0 / 3, flash: false),
                      try shot("c", make: "NIKON", model: "Z 8", lens: "NIKKOR Z 50mm f/1.8 S", f: 1.8, mm: 50, time: 0.001, iso: 6400, lensMake: "SIGMA", artist: "Ana Ruiz")] {
            _ = try await store.insert(asset, thumbnail: nil)
        }
        func suggest(_ text: String) async throws -> [CatalogSearchSuggestion] { try await store.searchSuggestions(for: text) }
        let gm = try await suggest("gm")
        XCTAssertEqual(gm.map(\.tag), ["FE 24-70mm F2.8 GM", "FE 24-70mm F2.8 GM II"])
        XCTAssertEqual(gm.first?.completion, "lens:\"FE 24-70mm F2.8 GM\"")
        let body = try await suggest("7r")
        XCTAssertEqual(body.first?.tag, "ILCE-7RM5"); XCTAssertEqual(body.first?.photoCount, 2); XCTAssertEqual(body.first?.completion, "camera:ILCE-7RM5")
        let lenses = try await suggest("lens:")
        XCTAssertEqual(lenses.count, 4); XCTAssertTrue(lenses.allSatisfy { $0.source == .lens })
        let scoped = try await suggest("sony lens:nik")
        XCTAssertEqual(scoped.map(\.completion), ["sony lens:\"NIKKOR Z 50mm f/1.8 S\""])
        let shutter = try await suggest("1/2")
        XCTAssertEqual(shutter.first?.tag, "1/250s", "A whole-tag prefix comes before a word inside one"); XCTAssertEqual(shutter.first?.source, .exposure)
        let iso = try await suggest("iso 32")
        XCTAssertEqual(iso.map(\.completion), ["ISO3200"])
        let sony = try await suggest("son")
        XCTAssertEqual(sony.map(\.tag), ["SONY"], "The body maker's own lens adds no lens make"); XCTAssertEqual(sony.first?.photoCount, 2)
        let sigma = try await suggest("sig")
        XCTAssertEqual(sigma.map(\.completion), ["lens:SIGMA"])
        for (text, expected) in [("f/", ["f/1.8", "f/2.8", "f/8"]), ("f2", ["f/2.8"]), ("iso6", ["ISO 6400"]), ("iso:3", ["ISO 3200"]), ("1/", ["1/1000s", "1/250s"]), ("+0", ["+0.7 EV"])] {
            let found = try await suggest(text)
            XCTAssertEqual(Set(found.map(\.tag)), Set(expected), text); XCTAssertTrue(found.allSatisfy { $0.source == .exposure }, text)
        }
        let bound = try await suggest("<1/5"); XCTAssertTrue(bound.isEmpty)
        let focal = try await store.focalRange(); XCTAssertEqual(focal, 35...70)
        for (range, expected) in [(24...50, Set(["a", "c"])), (35...35, ["a"]), (70...200, ["b"])] {
            var filter = CatalogFilter(); filter.focalLength = range
            let found = Set(try await store.assets(filter: filter).map(\.id)); XCTAssertEqual(found, expected, "\(range)")
        }
        func filtered(_ change: (inout CatalogFilter) -> Void) async throws -> Set<String> {
            var filter = CatalogFilter(); change(&filter)
            return Set(try await store.assets(filter: filter).map(\.id))
        }
        let apertures = try await store.exposureRange(.aperture); XCTAssertEqual(apertures, 1.8...8)
        let times = try await store.exposureRange(.shutter); XCTAssertEqual(times, 0.001...2)
        let s = CatalogExposureScale.self
        for (scale, stops, expected) in [(s.aperture, s.aperture.stop(of: 1.8)...s.aperture.stop(of: 2.8), Set(["a", "c"])),
                                         (s.aperture, s.aperture.stop(of: 8)...s.aperture.stop(of: 8), ["b"]),
                                         (s.shutter, s.shutter.stop(of: 1.0 / 1000)...s.shutter.stop(of: 1.0 / 250), ["a", "c"]),
                                         (s.shutter, s.shutter.stop(of: 1)...s.shutter.stop(of: 30), ["b"]),
                                         (s.iso, s.iso.stop(of: 3200)...s.iso.stop(of: 6400), ["b", "c"])] {
            let found = try await filtered { $0[scale] = stops }; XCTAssertEqual(found, expected, "\(scale) \(stops)")
        }
        let fired = try await filtered { $0.flash = true }; XCTAssertEqual(fired, ["a"])
        let unfired = try await filtered { $0.flash = false }; XCTAssertEqual(unfired, ["b"])
        let landscape = try await filtered { $0.orientation = .landscape }
        let portrait = try await filtered { $0.orientation = .portrait }
        XCTAssertEqual(landscape.union(portrait), ["a", "b", "c"]); XCTAssertTrue(landscape.isDisjoint(with: portrait))
        // Faces: "c" is not analysed yet, so it is neither with nor without faces.
        try await store.database.write { db in
            try db.execute(sql: "UPDATE asset SET faceCount = CASE id WHEN 'a' THEN 0 WHEN 'b' THEN 4 END")
        }
        let faceless = try await filtered { $0.faces = CatalogFaces.none }; XCTAssertEqual(faceless, ["a"])
        let withFaces = try await filtered { $0.faces = .some }; XCTAssertEqual(withFaces, ["b"])
        let group = try await filtered { $0.faces = .group; $0.flash = false }; XCTAssertEqual(group, ["b"])
        let none = try await filtered { $0.faces = .group; $0.flash = true }; XCTAssertTrue(none.isEmpty)
        let kept = try await suggest("sony f/8"); XCTAssertEqual(kept.map(\.completion), ["sony f/8"])

        func search(_ text: String) async throws -> Set<String> {
            var filter = CatalogFilter(); filter.search = text
            return Set(try await store.assets(filter: filter).map(\.id))
        }
        let expectations: [(String, Set<String>)] = [
            ("lens:\"FE 24-70mm F2.8 GM\"", ["b"]), ("lens:\"FE 24-70mm F2.8 GM II\"", ["a"]), ("camera:ilce-7rm5", ["a", "b"]), ("camera:SONY", ["a", "b"]),
            ("artist:\"ana ruiz\"", ["c"]), ("ruiz", ["c"]), ("sony", ["a", "b"]), ("\"24-70mm F2.8\"", ["a", "b"]),
            ("f/2.8", ["a"]), ("F2.8", ["a"]), ("f<4", ["a", "c"]), ("f/2-8", ["a", "b"]), ("f>=8", ["b"]),
            ("35mm", ["a"]), ("30-60mm", ["a", "c"]), (">50mm", ["b"]),
            ("1/250s", ["a"]), ("1/250", ["a"]), ("<1/500", ["c"]), (">1s", ["b"]), ("2s", ["b"]), ("1/1000-1/250", ["a", "c"]),
            ("iso200", ["a"]), ("ISO:3200", ["b"]), ("iso>=3200", ["b", "c"]), ("+0.7ev", ["b"]), ("flash", ["a"]),
            ("sony f/8 2s", ["b"]), ("camera:", ["a", "b", "c"]),
        ]
        for (text, expected) in expectations {
            let found = try await search(text); XCTAssertEqual(found, expected, text)
        }
        try await store.moveToTrash("b")
        let afterTrash = try await suggest("7r"); XCTAssertEqual(afterTrash.first?.photoCount, 1)
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        try await db.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = 'c'")
            try db.execute(sql: "INSERT INTO tagSearch(tagSearch, rank) VALUES ('integrity-check', 1)")
        }
        let gone = try await suggest("nik"); XCTAssertTrue(gone.isEmpty)
    }

    func testMakersLoseTheirCompanySuffix() {
        for (make, brand) in [("NIKON CORPORATION", "NIKON"), ("OLYMPUS IMAGING CORP.", "OLYMPUS"), ("RICOH IMAGING COMPANY, LTD.", "RICOH"),
                              ("LEICA CAMERA AG", "LEICA"), ("Canon", "Canon"), ("FUJIFILM", "FUJIFILM"), ("Camera", "Camera")] {
            XCTAssertEqual(CatalogCamera.brand(make), brand, make)
        }
    }

    func testFocalStopsAreTheEndsAndStandardLengthsBetween() {
        XCTAssertEqual(CatalogFocalFilter.stops(from: 24...80), [24, 35, 50, 80], "70 is too close to 80")
        XCTAssertEqual(CatalogFocalFilter.stops(from: 16...600), [16, 24, 35, 50, 85, 135, 200, 400, 600])
        XCTAssertEqual(CatalogFocalFilter.stops(from: 16...600, count: 5), [16, 24, 35, 50, 600], "The classic primes come first")
        XCTAssertEqual(CatalogFocalFilter.stops(from: 50...50), [50])
        XCTAssertEqual(CatalogFocalFilter.stops(from: 14...1200), [14, 24, 35, 50, 85, 135, 200, 400, 1200], "Lengths crowded on the log scale drop out")
        XCTAssertEqual(CatalogFocalFilter.position(of: 35, in: 24...35 * 35 / 24), 0.5, accuracy: 0.01)
        XCTAssertEqual(CatalogFocalFilter.position(of: 600, in: 24...600), 1)
        XCTAssertEqual(CatalogFocalFilter.ticks(from: 24...80).filter(\.labelled).map(\.millimetres), [24, 35, 50, 70, 85], "Ends widen to popular lengths")
        XCTAssertEqual(CatalogFocalFilter.ticks(from: 23...1100).filter(\.labelled).map(\.millimetres).first, 20)
        XCTAssertEqual(CatalogFocalFilter.ticks(from: 23...1100).filter(\.labelled).map(\.millimetres).last, 1100)
        let ticks = CatalogFocalFilter.ticks(from: 24...135)
        XCTAssertEqual(ticks.filter(\.labelled).map(\.millimetres), [24, 35, 50, 85, 135])
        let graduation = ticks.filter { !$0.labelled }
        XCTAssertTrue(graduation.count > 15, "\(ticks.map(\.millimetres))")
        XCTAssertTrue(graduation.allSatisfy { abs($0.position * 24 - ($0.position * 24).rounded()) < 1e-9 }, "Evenly spaced")
        XCTAssertEqual(ticks.map(\.position), ticks.map(\.position).sorted())
        XCTAssertEqual(Set(ticks.map(\.millimetres)).count, ticks.count, "No length twice")
    }

    func testExposureScalesCountInThirdStopsAndReadAsCamerasMarkThem() {
        let aperture = CatalogExposureScale.aperture, shutter = CatalogExposureScale.shutter, iso = CatalogExposureScale.iso
        XCTAssertEqual([1.7, 1.8, 2.8, 5.6, 0.95].map { aperture.label(aperture.stop(of: $0)) }, ["1.8", "1.8", "2.8", "5.6", "1"])
        XCTAssertEqual([1.0 / 8000, 1.0 / 250, 1.0 / 60, 1.0 / 1.3, 0.5, 1, 2, 30].map { shutter.label(shutter.stop(of: $0)) },
                       ["1/8000", "1/250", "1/60", "0.8\"", "1/2", "1\"", "2\"", "30\""])
        XCTAssertEqual([64, 100, 125, 3200, 12800, 102400].map { iso.label(iso.stop(of: Double($0))) }, ["64", "100", "125", "3200", "12800", "102400"])
        XCTAssertEqual(aperture.label(aperture.stop(of: 2.8)...aperture.stop(of: 5.6)), "f/2.8–5.6")
        XCTAssertEqual(iso.label(iso.stop(of: 100)...iso.stop(of: 100)), "ISO 100")
        // Bounds reach half a third stop each way, so a nominal value and its true one both fall inside.
        let wide = aperture.bounds(aperture.stop(of: 5.6)...aperture.stop(of: 5.6))
        XCTAssertTrue(wide.contains(5.6) && wide.contains(5.66) && !wide.contains(5.0) && !wide.contains(6.3))

        let ticks = aperture.ticks(from: 1.4...22)
        XCTAssertEqual(ticks.compactMap(\.label), ["1.4", "2.8", "5.6", "11", "22"])
        XCTAssertEqual(ticks.count, 25, "A tick every third stop")
        XCTAssertEqual(ticks.first?.position, 0); XCTAssertEqual(ticks.last?.position, 1)
        XCTAssertEqual(aperture.ticks(from: 1.8...2.5).compactMap(\.label), ["1.4", "2", "2.8"], "Ends widen to whole stops")
        let speeds = shutter.ticks(from: (1.0 / 8000)...30)
        XCTAssertEqual(speeds.count, 19, "A tick a stop past 12 stops")
        XCTAssertEqual(speeds.compactMap(\.label).count, 5); XCTAssertEqual(speeds.first?.label, "1/8000"); XCTAssertEqual(speeds.last?.label, "30\"")
        XCTAssertEqual(iso.ticks(from: 400...400).compactMap(\.label), ["400", "800"], "One value still makes a scale")
    }

    func testExtensionSizeAndShownAspectFollowTheRow() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var asset = try photo(url, id: "p", captureTime: "2026-09-19T12:00:00")
        asset.filename = "DSC01234.arw"
        _ = try await store.insert(asset, thumbnail: nil)
        let info = asset.info
        let db = try DatabaseQueue(path: store.root.appendingPathComponent("catalog.sqlite").path)
        func row() async throws -> Row {
            try await db.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT fileExtension, width, height, aspect FROM asset WHERE id = 'p'")) }
        }
        var found = try await row()
        XCTAssertEqual(found["fileExtension"], "ARW")
        XCTAssertEqual(found["width"], info.width); XCTAssertEqual(found["height"], info.height)
        XCTAssertEqual(found["aspect"] as Double, Double(info.width) / Double(info.height), accuracy: 1e-9)
        // A square crop, then a quarter turn of a half-height crop.
        var settings = Adjustments(); settings.geometry.crop = CropRect(x: 0, y: 0, width: Double(info.height) / Double(info.width), height: 1)
        _ = try await store.saveEdits(settings, assetID: "p")
        found = try await row(); XCTAssertEqual(found["aspect"] as Double, 1, accuracy: 1e-6)
        settings.geometry.crop = CropRect(x: 0, y: 0, width: 1, height: 0.5); settings.quarterTurns = 1
        _ = try await store.saveEdits(settings, assetID: "p")
        found = try await row(); XCTAssertEqual(found["aspect"] as Double, Double(info.height) * 0.5 / Double(info.width), accuracy: 1e-6)
        try await db.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT id FROM asset WHERE fNumber BETWEEN 1.35 AND 2.85").map { $0["detail"] as String }.joined()
            XCTAssertTrue(plan.contains("asset_fNumber"), plan)
        }
    }
}
