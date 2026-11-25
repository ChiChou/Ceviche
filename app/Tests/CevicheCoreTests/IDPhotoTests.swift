import XCTest
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
@testable import CevicheCore
import CevicheTestSupport

final class IDPhotoTests: XCTestCase {
    private let icao = IDPhotoSpec(id: "t", country: "ICAO", document: "Passport", widthMM: 35, heightMM: 45, headHeightMM: [32, 36], crownToTopMM: [3, 5])

    func testBundledSpecsDecodeAndAreValid() {
        XCTAssertFalse(IDPhotoSpecs.all.isEmpty)
        XCTAssertEqual(Set(IDPhotoSpecs.all.map(\.id)).count, IDPhotoSpecs.all.count, "ids are unique")
        for spec in IDPhotoSpecs.all {
            XCTAssertTrue(spec.isValid, spec.id)
            XCTAssertNotNil(IDPhotoSpecs.spec(spec.id))
        }
        XCTAssertNotNil(IDPhotoSpecs.spec("icao"))
    }

    func testGroupsPutTemplatesFirstAndKeepCountriesWhole() {
        let mine = IDPhotoSpecs.fallback.template(named: "Club Card")
        let all = IDPhotoSpecs.groups(templates: [mine])
        XCTAssertEqual(all.first?.specs, [mine])
        XCTAssertEqual(all.dropFirst().reduce(0) { $0 + $1.specs.count }, IDPhotoSpecs.all.count)
        let japan = IDPhotoSpecs.groups(templates: [mine], matching: "jap")
        XCTAssertEqual(japan.count, 1)
        XCTAssertTrue(japan[0].specs.allSatisfy { $0.country == "JP" })
    }

    func testIssuesAndReadiness() {
        func check(_ id: String, _ status: IDPhotoCheck.Status, advisory: Bool = false) -> IDPhotoCheck {
            var check = IDPhotoCheck(id: id, title: id, status: status, detail: ""); check.advisory = advisory; return check
        }
        XCTAssertEqual([check("head", .pass)].readiness, .ready)
        let fixable = [check("ai-smile", .warning, advisory: true), check("head", .warning), check("cast", .failure)]
        XCTAssertEqual(fixable.issues.map(\.id), ["cast", "head", "ai-smile"])
        XCTAssertEqual(fixable[1].fix, .fitToSpec)
        XCTAssertEqual(fixable.readiness, .needsFix, "An advisory retake that only warns can still be fixed")
        XCTAssertEqual((fixable + [check("yaw", .failure)]).readiness, .retake)
    }

    /// An upright head 1000 px tall in a 4000 × 6000 photo, centred at x = 2000.
    func testSearchMatchesCountriesAndDocuments() {
        func found(_ query: String) -> [IDPhotoSpec] { IDPhotoSpecs.all.filter { $0.matches(query) } }
        func countries(_ query: String) -> Set<String> { Set(found(query).map(\.country)) }
        XCTAssertEqual(countries("jap"), ["JP"])
        XCTAssertEqual(countries("king"), ["GB"])
        XCTAssertEqual(countries("STATES"), ["US"])
        XCTAssertEqual(countries("icao"), ["ICAO"])
        // A country keeps all its documents; a document only itself.
        XCTAssertEqual(found("united states").count, IDPhotoSpecs.all.filter { $0.country == "US" }.count)
        XCTAssertTrue(found("id").allSatisfy { $0.document.contains("ID") })
        XCTAssertTrue(found("id").contains { $0.country == "FR" })
        XCTAssertFalse(found("id").contains { $0.country == "JP" })
        XCTAssertTrue(found("green").map(\.document) == ["Green Card"])
        // Word starts only, and no sizes or codes: "isa" isn't Visa, "35" isn't a size.
        XCTAssertEqual(found("isa"), [])
        XCTAssertEqual(found("35"), [])
        XCTAssertEqual(found(" ").count, IDPhotoSpecs.all.count)
        XCTAssertEqual(IDPhotoSpecs.spec("icao")?.flag, "🌐")
        XCTAssertEqual(IDPhotoSpecs.all.first { $0.country == "JP" }?.flag, "🇯🇵")
    }

    func testFramePlacesHeadPerSpec() {
        let size = CGSize(width: 4000, height: 6000)
        var layout = IDPhotoLayout(spec: icao, crown: CGPoint(x: 0.5, y: 2000 / 6000.0), chin: CGPoint(x: 0.5, y: 3000 / 6000.0))
        let frame = layout.frame(in: size)
        XCTAssertEqual(frame.headMM, 34, accuracy: 1e-9)
        XCTAssertEqual(frame.crownMM, 4, accuracy: 1e-9)
        XCTAssertEqual(frame.tiltDegrees, 0, accuracy: 1e-9)
        // The crown sits at the middle of the top edge's allowance, horizontally centred.
        let crown = frame.printPoint(photo: CGPoint(x: 2000, y: 2000))
        XCTAssertEqual(crown.x, 17.5, accuracy: 1e-9); XCTAssertEqual(crown.y, 4, accuracy: 1e-9)
        let chin = frame.photoPoint(mm: CGPoint(x: 17.5, y: 38))
        XCTAssertEqual(chin.y, 3000, accuracy: 1e-6)
        XCTAssertTrue(frame.headInRange); XCTAssertEqual(frame.crownInRange, true)
        XCTAssertFalse(frame.outsidePhoto)
        layout.headSize = 2   // clamped to the largest allowed
        XCTAssertEqual(layout.frame(in: size).headMM, 36, accuracy: 1e-9)
    }

    /// A head leaning 10° is levelled: the chin-crown line becomes the print's vertical.
    func testTiltedHeadIsLevelled() {
        let size = CGSize(width: 4000, height: 4000)
        let angle = 10.0 * .pi / 180
        let chin = CGPoint(x: 2000, y: 3000), length = 1000.0
        let crown = CGPoint(x: chin.x + sin(angle) * length, y: chin.y - cos(angle) * length)
        let layout = IDPhotoLayout(spec: icao, crown: CGPoint(x: crown.x / 4000, y: crown.y / 4000), chin: CGPoint(x: 0.5, y: 0.75))
        let frame = layout.frame(in: size)
        XCTAssertEqual(frame.tiltDegrees, 10, accuracy: 1e-6)
        let printedChin = frame.printPoint(photo: chin), printedCrown = frame.printPoint(photo: crown)
        XCTAssertEqual(printedChin.x, printedCrown.x, accuracy: 1e-6)
        XCTAssertEqual(printedChin.y - printedCrown.y, 34, accuracy: 1e-6)
        // Round trip.
        let p = CGPoint(x: 1234, y: 2345), back = frame.photoPoint(mm: frame.printPoint(photo: p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6); XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    /// With only an eye-line range (as the US sets), the eyes land inside it.
    func testEyeLineRangePlacesEyes() {
        let us = IDPhotoSpec(id: "us", country: "US", document: "Passport", widthMM: 50.8, heightMM: 50.8, headHeightMM: [25.4, 34.9], eyeLineFromBottomMM: [28, 35])
        let layout = IDPhotoLayout(spec: us, crown: CGPoint(x: 0.5, y: 0.3), chin: CGPoint(x: 0.5, y: 0.5), eyes: CGPoint(x: 0.5, y: 0.4))
        let frame = layout.frame(in: CGSize(width: 3000, height: 3000))
        XCTAssertEqual(frame.eyeInRange, true)
        XCTAssertEqual(frame.eyeFromBottomMM, 31.5, accuracy: 1e-6)
    }

    func testSheetFillsPaper() throws {
        var sheet = IDPhotoSheet()
        sheet.paper = .photo4x6; sheet.spacing = .lab
        let arrangement = try XCTUnwrap(sheet.arrangement(for: icao))
        // 35 × 45 on 4 × 6 in with 4 mm margins and 3 mm gaps: 2 × 3 either way, so it stays portrait.
        XCTAssertEqual(arrangement.origins.count, 6)
        XCTAssertLessThan(arrangement.paper.width, arrangement.paper.height)
        sheet.paper = .a4
        XCTAssertEqual(sheet.arrangement(for: icao)?.origins.count, 30)
        for origin in arrangement.origins {
            XCTAssertGreaterThanOrEqual(origin.x, 0); XCTAssertLessThanOrEqual(origin.x + 35, arrangement.paper.width)
            XCTAssertGreaterThanOrEqual(origin.y, 0); XCTAssertLessThanOrEqual(origin.y + 45, arrangement.paper.height)
        }
        // 2 × 2 in photos fill a 4 × 6 in sheet edge to edge, 6 of them; with lab margins only 2 fit.
        let us = IDPhotoSpec(id: "us", country: "US", document: "Passport", widthMM: 50.8, heightMM: 50.8, headHeightMM: [25.4, 34.9])
        sheet.paper = .photo4x6
        XCTAssertEqual(sheet.arrangement(for: us)?.origins.count, 2)
        sheet.spacing = .edgeToEdge
        XCTAssertEqual(sheet.arrangement(for: us)?.origins.count, 6)
        sheet.paper = .photoL; sheet.spacing = .lab
        XCTAssertEqual(sheet.arrangement(for: icao)?.origins.count, 4, "35 × 45 on L: 2 × 2")
        XCTAssertEqual(IDPhotoSheet.Paper.standard(for: "JP"), .photoL)
        XCTAssertEqual(IDPhotoSheet.Paper.standard(for: "US"), .photo4x6)
        XCTAssertEqual(IDPhotoSheet.Paper.standard(for: "DE"), .photo10x15)
        sheet.paper = .photo4x6; sheet.spacing = .lab
        sheet.copies = 2
        XCTAssertEqual(sheet.arrangement(for: icao)?.origins.count, 2)
        sheet.paper = .single
        XCTAssertNil(sheet.arrangement(for: icao))
    }

    /// A family's photos over sheets: each photo's copies kept together where they fit, the sheets filled in order.
    func testPagesKeepEachPhotosCopiesTogether() throws {
        var sheet = IDPhotoSheet(); sheet.paper = .photo4x6; sheet.spacing = .lab   // 6 places for 35 × 45
        XCTAssertEqual(sheet.pages(copies: [2, 2, 2], spec: icao), [[0, 0, 1, 1, 2, 2]])
        XCTAssertEqual(sheet.pages(copies: [4, 4], spec: icao), [[0, 0, 0, 0], [1, 1, 1, 1]], "4 + 4 doesn't split the second photo")
        XCTAssertEqual(sheet.pages(copies: [8], spec: icao), [[0, 0, 0, 0, 0, 0], [0, 0]], "more than a sheet runs on")
        XCTAssertEqual(sheet.pages(copies: [0, 3], spec: icao), [[1, 1, 1]])
        XCTAssertEqual(sheet.pages(copies: [], spec: icao), [])
        // Mixed prints render one image per page, each the paper's size.
        let ppm = 4.0
        let red = try XCTUnwrap(Self.solid(width: Int(35 * ppm), height: Int(45 * ppm), red: 1)), blue = try XCTUnwrap(Self.solid(width: Int(35 * ppm), height: Int(45 * ppm), red: 0))
        var layout = IDPhotoLayout(spec: icao, crown: .zero, chin: CGPoint(x: 0, y: 1)); layout.sheet = sheet
        let pages = try IDPhotoRenderer.sheets([red, blue], copies: [4, 4], layout: layout, pixelsPerMM: ppm)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].width, Int((101.6 * ppm).rounded())); XCTAssertEqual(pages[0].height, Int((152.4 * ppm).rounded()))
    }
    static func solid(width: Int, height: Int, red: CGFloat) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(srgbRed: red, green: 0, blue: 1 - red, alpha: 1)); context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    /// The exported photo is the print at 300 ppi, moved only as far as the document's upload limits ask.
    func testExportedPhotoWidth() throws {
        // No upload limits: the print as it is (35 mm at 300 ppi).
        XCTAssertEqual(IDPhotoRenderer.digitalWidth(icao), 413)
        // US visa: 2 in at 300 ppi is 600 px, inside 600–1200.
        XCTAssertEqual(IDPhotoRenderer.digitalWidth(try XCTUnwrap(IDPhotoSpecs.spec("us-visa"))), 600)
        // Japan's passport form asks for exactly 600 × 730: raised from 413.
        XCTAssertEqual(IDPhotoRenderer.digitalWidth(try XCTUnwrap(IDPhotoSpecs.spec("jp-passport"))), 600)
        // Singapore caps uploads at 400 × 514: lowered from 413.
        XCTAssertEqual(IDPhotoRenderer.digitalWidth(try XCTUnwrap(IDPhotoSpecs.spec("sg-passport"))), 400)
    }


    /// Measured on the sample selfies: indoor tungsten-lit cheeks run 2.15–2.24 red to blue before a cream wall,
    /// daylight faces 1.3–1.9.
    func testColourCast() {
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: SIMD3(0.543, 0.345, 0.249), wall: SIMD3(0.86, 0.82, 0.70)), 1)
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: SIMD3(0.632, 0.429, 0.339), wall: SIMD3(0.97, 0.97, 0.97)), 0)
        // Deeper skin under neutral light before a white wall is not called warm.
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: SIMD3(0.42, 0.26, 0.19), wall: SIMD3(0.95, 0.95, 0.96)), 0)
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: SIMD3(0.40, 0.36, 0.42), wall: SIMD3(0.80, 0.85, 0.95)), -1)
    }

    /// Red over blue of `region` (fractions from the top left) in a small render, as Auto measures it.
    private func redOverBlue(_ r: IDPhotoRenderer, _ region: CGRect) async throws -> Double {
        let image = CIImage(cgImage: try await r.preview(maxDimension: 600)), e = image.extent
        let rect = CGRect(x: region.minX * e.width, y: (1 - region.maxY) * e.height, width: region.width * e.width, height: region.height * e.height)
        var pixel = [Float](repeating: 0, count: 4)
        let mean = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        pixel.withUnsafeMutableBytes { CIContext().render(mean, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: IDPhotoRenderer.space) }
        return Double(pixel[0]) / Double(pixel[2])
    }

    /// Auto on the cream wall behind a tungsten-lit selfie: the wall can be trusted, so it comes out neutral and the
    /// skin is no longer called warm.
    func testAutoWhiteBalance() async throws {
        let url = try TestSamples.require(TestSamples.idPortrait)
        let renderer = try await IDPhotoRenderer(url: url, adjustments: nil)
        let before = try IDPhotoAnalysis.analyze(try await renderer.preview(maxDimension: 1200))
        let face = try XCTUnwrap(before.face)
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: try XCTUnwrap(face.skin), wall: before.background?.color), 1)
        let balanced = try await XCTUnwrapAsync(try await renderer.autoBalance(wall: before.wallRegion, skin: face.skinRegion))
        XCTAssertLessThan(balanced.temperature, renderer.adjustments.temperature, "a warm cast is cooled")
        let after = try IDPhotoAnalysis.analyze(try await renderer.with(balanced).preview(maxDimension: 1200))
        let color = try XCTUnwrap(after.background?.color)
        XCTAssertLessThan(abs(color.x - color.z), 0.03, "the wall is neutral: \(color)")
        XCTAssertEqual(IDPhotoChecks.colourCast(skin: try XCTUnwrap(after.face?.skin), wall: color), 0)
    }

    /// Auto in front of orange brick under warm light: making the brick neutral turned the face blue, so the skin
    /// decides instead and lands within the range of daylit skin.
    func testAutoWhiteBalanceOnColouredWall() async throws {
        let url = try TestSamples.require(TestSamples.idWarmWall)
        let renderer = try await IDPhotoRenderer(url: url, adjustments: nil)
        let analysis = try IDPhotoAnalysis.analyze(try await renderer.preview(maxDimension: 1200))
        let face = try XCTUnwrap(analysis.face)
        let byWall = try await XCTUnwrapAsync(try await renderer.neutralize(try XCTUnwrap(analysis.wallRegion)))
        let skinByWall = try await redOverBlue(renderer.with(byWall), face.skinRegion)
        // The case under test, which only the photo this was written for shows: the wall alone turns the skin blue.
        guard skinByWall < IDPhotoRenderer.skinRedOverBlue.lowerBound else { throw XCTSkip("No warm-wall sample whose wall turns the skin blue") }
        let balanced = try await XCTUnwrapAsync(try await renderer.autoBalance(wall: analysis.wallRegion, skin: face.skinRegion))
        let skin = try await redOverBlue(renderer.with(balanced), face.skinRegion)
        XCTAssertEqual(skin, IDPhotoRenderer.skinRedOverBlueCentre, accuracy: 0.05)
        XCTAssertGreaterThan(balanced.temperature, byWall.temperature + 1000)
    }

    /// Auto with sky above the head and skin that already looks right: nothing changes.
    func testAutoWhiteBalanceKeepsGoodSkin() async throws {
        let url = try TestSamples.require(TestSamples.idSkyWall)
        let renderer = try await IDPhotoRenderer(url: url, adjustments: nil)
        let analysis = try IDPhotoAnalysis.analyze(try await renderer.preview(maxDimension: 1200))
        let face = try XCTUnwrap(analysis.face)
        let balanced = try await XCTUnwrapAsync(try await renderer.autoBalance(wall: analysis.wallRegion, skin: face.skinRegion))
        XCTAssertEqual(balanced.temperature, renderer.adjustments.temperature)
        XCTAssertEqual(balanced.tint, renderer.adjustments.tint)
    }

    /// A JPEG balances with Temperature too: Warmth is only rendered inside masks, so solving with it changed nothing.
    /// The sample's "wall" is sky, so the test checks the region it was asked to neutralize rather than the face.
    func testWhiteBalanceOnJPEG() async throws {
        let url = try TestSamples.require(TestSamples.idSkyWall)
        let renderer = try await IDPhotoRenderer(url: url, adjustments: nil)
        let region = CGRect(x: 0.75, y: 0.36, width: 0.1, height: 0.1)   // the grey building right of the head
        func cast(_ r: IDPhotoRenderer) async throws -> Double { log(try await redOverBlue(r, region)) }
        var warmer = renderer.adjustments; warmer.temperature = 9000
        let before = try await cast(renderer)
        let warmed = try await cast(renderer.with(warmer))
        XCTAssertGreaterThan(warmed, before + 0.05, "Temperature changes a JPEG")
        let balanced = try await XCTUnwrapAsync(try await renderer.neutralize(region))
        let after = try await cast(renderer.with(balanced))
        XCTAssertLessThan(abs(after), 0.02)
    }
    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

    /// A portrait turned on its side or upside down: the analysis says how to stand the head up, and once turned the
    /// crown is above the chin, level with it, as on the upright photo.
    func testTurnedPortraitStandsUp() async throws {
        let url = try TestSamples.require(TestSamples.idPortrait)
        let upright = try await IDPhotoRenderer(url: url, adjustments: nil)
        for turns in 0..<4 {
            let turned = try await upright.turned(turns)
            let turnedPreview = try await turned.preview(maxDimension: 1200)
            let face = try XCTUnwrap(try IDPhotoAnalysis.analyze(turnedPreview).face, "\(turns)")
            XCTAssertEqual(face.uprightTurns, (4 - turns) % 4, "turned \(turns)")
            let stood = try await turned.turned(face.uprightTurns)
            XCTAssertEqual(stood.size, upright.size)
            let stoodPreview = try await stood.preview(maxDimension: 1200)
            let again = try XCTUnwrap(try IDPhotoAnalysis.analyze(stoodPreview).face, "\(turns)")
            XCTAssertEqual(again.uprightTurns, 0)
            XCTAssertLessThan(again.crown.y, again.chin.y)
            XCTAssertLessThan(abs(again.crown.x - again.chin.x), 0.1, "turned \(turns): the head's vertical is upright")
        }
    }

    func testBackgroundCheck() {
        XCTAssertEqual(IDPhotoChecks.background(color: SIMD3(0.95, 0.95, 0.95), spread: 0.02, spec: icao).status, .pass)
        XCTAssertEqual(IDPhotoChecks.background(color: SIMD3(0.5, 0.6, 0.8), spread: 0.2, spec: icao).status, .failure)
        XCTAssertEqual(IDPhotoChecks.background(color: SIMD3(0.75, 0.75, 0.75), spread: 0.02, spec: icao).status, .warning)
    }

    /// Develops a real portrait, finds the face, and writes the print and a 4 × 6 sheet for review into
    /// `CEVICHE_IDPHOTO_OUT` when set. The photos in `TestSamples.idPortraits` are run too.
    func testSamplePortraits() async throws {
        var urls = [try TestSamples.require(TestSamples.rawJPEGPair.jpeg)]
        let folder = TestSamples.folder(TestSamples.idPortraits)
        urls += ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        let output = ProcessInfo.processInfo.environment["CEVICHE_IDPHOTO_OUT"].map(URL.init(fileURLWithPath:))
        for url in urls {
            let renderer = try await IDPhotoRenderer(url: url, adjustments: nil)
            let preview = try await renderer.preview()
            let analysis = try IDPhotoAnalysis.analyze(preview)
            let face = try XCTUnwrap(analysis.face, url.lastPathComponent)
            XCTAssertLessThan(face.crown.y, face.chin.y)
            let layout = IDPhotoLayout(spec: IDPhotoSpecs.fallback, crown: face.crown, chin: face.chin, eyes: face.eyes)
            var checks = IDPhotoChecks.evaluate(analysis, layout: layout, photoSize: renderer.size)
            checks += IDPhotoReview.applicable(await IDPhotoReview.review(preview, face: face), spec: layout.spec, measured: checks)
            for check in checks { print("  \(check.status) \(check.title): \(check.detail)\(check.advisory ? " (AI)" : "")") }
            let print = try await renderer.renderPrint(layout)
            XCTAssertEqual(print.width, IDPhotoSpecs.fallback.pixelSize.width)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let stem = url.deletingPathExtension().lastPathComponent
                try IDPhotoRenderer.write(print, to: output.appendingPathComponent("\(stem)-print.jpg"), type: .jpeg, dpi: layout.spec.printDPI)
                try IDPhotoRenderer.write(try IDPhotoRenderer.sheet(print, layout: layout), to: output.appendingPathComponent("\(stem)-sheet.jpg"), type: .jpeg, dpi: layout.spec.printDPI)
                var replaced = layout
                replaced.background = IDPhotoBackground(for: layout.spec)
                let matte = try IDPhotoMatte.make(preview)
                try IDPhotoRenderer.write(try await renderer.renderPrint(replaced, matte: matte), to: output.appendingPathComponent("\(stem)-replaced.jpg"), type: .jpeg, dpi: layout.spec.printDPI)
            }
        }
    }

    func testTemplateLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = IDPhotoTemplateLibrary(file: folder.appendingPathComponent("Templates.json"))
        XCTAssertTrue(library.templates().isEmpty)
        var template = try XCTUnwrap(IDPhotoSpecs.spec("jp-passport")).template(named: "Club card")
        XCTAssertTrue(template.isCustom); XCTAssertEqual(template.title, "Club card"); XCTAssertNil(template.source); XCTAssertNil(template.notes)
        try library.save(template)
        template.widthMM = 30
        try library.save(template)
        XCTAssertEqual(library.templates(), [template], "saving again replaces it")
        let other = IDPhotoSpecs.fallback.template(named: "Other")
        try library.save(other)
        XCTAssertEqual(library.templates().map(\.document), ["Club card", "Other"])
        try library.delete(template.id)
        XCTAssertEqual(library.templates(), [other])
    }
}
