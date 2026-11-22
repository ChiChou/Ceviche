import XCTest
import CevicheTestSupport
import CoreImage
import Metal
import simd
import FilmPrint
@testable import CevicheCore

/// The catalog and settings are checked everywhere; what the film print renders only where there is a GPU for it
/// (`FilmCatalog.isAvailable`).
final class FilmSimulationTests: XCTestCase {
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    private let catalog = FilmCatalog.shared

    /// A linear color: CIColor's default components are sRGB-encoded.
    private func flat(_ color: SIMD3<Double>, size: Int = 96) -> CIImage {
        CIImage(color: CIColor(red: color.x, green: color.y, blue: color.z, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }
    private func render(_ image: CIImage, _ settings: FilmSimulation) -> [Float] {
        let out = FilmSimulationRenderer().apply(settings, to: image)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var result = [Float](repeating: 0, count: w * h * 4)
        result.withUnsafeMutableBytes { context.render(out, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
        return result
    }
    /// The mean color of a flat field through the film, without its grain and halation.
    private func mean(_ color: SIMD3<Double>, _ settings: FilmSimulation) -> SIMD3<Double> {
        var smooth = settings; smooth.grain = 0; smooth.halation = 0
        let pixels = render(flat(color), smooth), count = Double(pixels.count / 4)
        return SIMD3((0..<3).map { c in stride(from: c, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) } / count })
    }
    private func deviation(_ pixels: [Float], channel: Int) -> Double {
        let values = stride(from: channel, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }
    private func film(_ stock: String, on medium: String? = nil) -> FilmSimulation {
        var settings = FilmSimulation(stock: stock); settings.medium = medium
        return settings
    }
    private let gray = SIMD3<Double>(repeating: 0.18)

    // MARK: Catalog and settings

    func testCatalogListsFotufilmsStocksByKindWithTheirMedia() throws {
        XCTAssertGreaterThanOrEqual(catalog.films.count, 40)
        XCTAssertFalse(catalog.films.contains { $0.id.hasPrefix("example-") })
        XCTAssertEqual(catalog.film("portra400")?.kind, .negative)
        XCTAssertEqual(catalog.film("velvia50")?.kind, .slide)
        XCTAssertEqual(catalog.film("trix400")?.kind, .monochrome)
        XCTAssertEqual(catalog.film("vision500t")?.kind, .cine)
        XCTAssertEqual(catalog.film("lomochromepurple")?.kind, .creative)
        XCTAssertEqual(catalog.film("instaxmini")?.kind, .instant)
        XCTAssertEqual(catalog.film("vision500t")?.gauge, .super35)
        let portra = try XCTUnwrap(catalog.film("portra400"))
        // A still negative is made for paper under an enlarger, which takes an exposure, a filtration and a head.
        let paper = try XCTUnwrap(portra.medium(nil))
        XCTAssertEqual(paper.kind, .paper); XCTAssertTrue(paper.hasExposure && paper.hasBalance && paper.hasHead); XCTAssertFalse(paper.hasStyle)
        XCTAssertTrue(portra.media.contains { $0.kind == .printFilm }); XCTAssertTrue(portra.media.contains { $0.kind == .scan })
        let scan = try XCTUnwrap(portra.medium("screen"))
        XCTAssertTrue(scan.hasStyle && scan.hasGrade && scan.hasBalance); XCTAssertFalse(scan.hasHead)
        XCTAssertEqual(portra.medium("no-such-paper")?.id, paper.id)
        // A cine negative is made for its release print; a slide is looked at, or printed on Ilfochrome.
        XCTAssertEqual(catalog.film("vision500t")?.medium(nil)?.kind, .printFilm)
        let velvia = try XCTUnwrap(catalog.film("velvia50"))
        XCTAssertEqual(velvia.medium(nil)?.kind, .view); XCTAssertTrue(velvia.media.contains { $0.kind == .paper })
        XCTAssertFalse(velvia.media.contains { $0.id == "negative" })
        // Black-and-white takes no color balance.
        XCTAssertFalse(try XCTUnwrap(catalog.film("trix400")?.medium(nil)).hasBalance)
        XCTAssertTrue(portra.pushes.contains(0)); XCTAssertEqual(portra.pushes, portra.pushes.sorted())
    }

    func testAStockTheCatalogLacksStaysOnTheEditAndRendersWithoutFilm() throws {
        let old = try JSONDecoder().decode(FilmSimulation.self, from: Data(#"{"stock":"kodak_gold_200","paper":"kodak_ultra_endura","flare":2,"scatter":50,"off":["adjust"]}"#.utf8))
        XCTAssertEqual(old.stock, "kodak_gold_200"); XCTAssertNil(old.film); XCTAssertNil(old.output); XCTAssertNil(old.medium); XCTAssertEqual(old.off, [])
        XCTAssertEqual(old.amount, 100); XCTAssertEqual(old.grain, 100); XCTAssertEqual(old.format, .mm35); XCTAssertEqual(old.light, .balanced)
        XCTAssertNil(catalog.development(old))
        var adjustments = Adjustments(); adjustments.film = old
        XCTAssertEqual(adjustments.rendering, .camera)
        XCTAssertEqual(try JSONDecoder().decode(FilmSimulation.self, from: JSONEncoder().encode(old)).stock, "kodak_gold_200")
        for film in catalog.films { XCTAssertNotNil(catalog.development(FilmSimulation(stock: film.id)), film.id) }
    }

    func testSettingsRoundTripAndRejectNonsense() throws {
        var adjustments = Adjustments()
        adjustments.film = film("gold200", on: "screen"); adjustments.film?.magenta = -7; adjustments.film?.style = .graded; adjustments.film?.off = [.texture]
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(adjustments))
        XCTAssertEqual(restored.film, adjustments.film)
        XCTAssertNil(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(Adjustments())).film)
        XCTAssertThrowsError(try JSONDecoder().decode(Adjustments.self, from: Data(#"{"film":{"stock":"gold200","yellow":900}}"#.utf8)))
    }

    func testSwitchedOffPartsRenderAtTheirDefaultsAndKeepTheirValues() throws {
        var film = FilmSimulation(stock: "gold200")
        film.amount = 40; film.printExposure = 1; film.yellow = 12; film.grain = 150; film.format = .lf45; film.medium = "screen"; film.expired = 10
        film.off = [.develop, .print, .texture]
        let rendered = film.rendered
        XCTAssertEqual(rendered.amount, 40); XCTAssertEqual(rendered.printExposure, 0); XCTAssertEqual(rendered.yellow, 0)
        XCTAssertEqual(rendered.grain, 100); XCTAssertEqual(rendered.format, .mm35); XCTAssertEqual(rendered.expired, 0); XCTAssertEqual(rendered.medium, "screen")
        XCTAssertEqual(try JSONDecoder().decode(FilmSimulation.self, from: JSONEncoder().encode(film)), film)
        film.off = []
        XCTAssertEqual(film.rendered, film)
    }

    func testChoosingAStockTakesItsOwnMediumGaugeAndDevelopment() throws {
        var settings = film("portra400", on: "screen"); settings.push = 9; settings.yellow = 5
        settings.choose(stock: "vision500t")
        XCTAssertEqual(settings.stock, "vision500t"); XCTAssertNil(settings.medium); XCTAssertEqual(settings.format, .super35)
        XCTAssertEqual(settings.push, 0); XCTAssertEqual(settings.yellow, 5)
        // A push the stock doesn't list renders as normal development.
        var pushed = FilmSimulation(stock: "portra400"); pushed.push = 2.5
        XCTAssertEqual(pushed.rendered.push, 0)
    }

    func testWithoutTheEngineAFilmLeavesTheCamerasRendering() throws {
        try XCTSkipIf(catalog.isAvailable)
        var adjustments = Adjustments(); adjustments.film = FilmSimulation()
        XCTAssertEqual(adjustments.rendering, .camera)
        let image = flat(gray, size: 8)
        XCTAssertEqual(render(image, FilmSimulation()), render(image, FilmSimulation()))
    }

    // MARK: The engine

    func testPrintsGetBrighterWithSceneLightAndWithPrintExposure() throws {
        try XCTSkipUnless(catalog.isAvailable)
        for medium in [nil, "vision-2383", "screen", "lab-scan"] {
            var settings = film("portra400", on: medium); settings.style = .fixed
            let dark = mean(SIMD3(repeating: 0.05), settings), middle = mean(gray, settings), bright = mean(SIMD3(repeating: 0.6), settings)
            XCTAssertLessThan(dark.y, middle.y, medium ?? "paper"); XCTAssertLessThan(middle.y, bright.y, medium ?? "paper")
            XCTAssertGreaterThan(middle.y, 0.03); XCTAssertLessThan(middle.y, 0.6)
            settings.printExposure = 1
            XCTAssertGreaterThan(mean(gray, settings).y, middle.y, medium ?? "paper")
            settings.printExposure = -1
            XCTAssertLessThan(mean(gray, settings).y, middle.y, medium ?? "paper")
        }
    }

    func testYellowAndMagentaAddTheirColorToThePrint() throws {
        try XCTSkipUnless(catalog.isAvailable)
        for medium in [nil, "vision-2383", "screen"] {
            var settings = film("portra400", on: medium); settings.style = .fixed
            let neutral = mean(gray, settings)
            settings.yellow = 20
            let yellow = mean(gray, settings)
            XCTAssertLessThan(yellow.z / yellow.y, neutral.z / neutral.y, medium ?? "paper")
            settings.yellow = 0; settings.magenta = 20
            let magenta = mean(gray, settings)
            XCTAssertLessThan(magenta.y / magenta.x, neutral.y / neutral.x, medium ?? "paper")
        }
    }

    /// The first touch of a print control doesn't move the picture: a hair of exposure or color is a hair of change.
    func testPrintControlsStartFromTheMediumsOwnTiming() throws {
        try XCTSkipUnless(catalog.isAvailable)
        for (stock, medium) in [("portra400", nil), ("portra400", "vision-2383"), ("portra400", "screen"), ("velvia50", "ilfochrome-cps-1k"), ("trix400", nil)] as [(String, String?)] {
            var settings = film(stock, on: medium); settings.style = .fixed
            let rest = mean(gray, settings)
            settings.printExposure = 0.01
            let exposed = mean(gray, settings)
            settings.printExposure = 0; settings.yellow = 0.5; settings.magenta = 0.5
            let balanced = mean(gray, settings)
            for c in 0..<3 {
                XCTAssertEqual(exposed[c], rest[c], accuracy: rest[c] * 0.04 + 0.002, "\(stock) \(medium ?? "own") exposure")
                XCTAssertEqual(balanced[c], rest[c], accuracy: rest[c] * 0.04 + 0.002, "\(stock) \(medium ?? "own") balance")
            }
        }
    }

    func testEveryStockPrintsMidGrayNearNeutralOnItsOwnMedium() throws {
        try XCTSkipUnless(catalog.isAvailable)
        for stock in catalog.films where stock.kind != .creative {
            var settings = FilmSimulation(stock: stock.id); settings.style = .fixed
            let print = mean(gray, settings)
            XCTAssertGreaterThan(print.y, 0.02, stock.id); XCTAssertLessThan(print.y, 0.7, stock.id)
            XCTAssertLessThan(abs(print.x / print.y - 1), 0.35, stock.id); XCTAssertLessThan(abs(print.z / print.y - 1), 0.35, stock.id)
        }
    }

    func testGrainIsFixedBySeedAndFinerOnLargerFilm() throws {
        try XCTSkipUnless(catalog.isAvailable)
        var settings = film("trix400", on: "screen"); settings.style = .fixed; settings.halation = 0
        let image = flat(gray, size: 256)
        let first = render(image, settings)
        XCTAssertEqual(first, render(image, settings))
        XCTAssertGreaterThan(deviation(first, channel: 1), 0)
        settings.seed = 7
        XCTAssertNotEqual(first, render(image, settings))
        settings.seed = 1; settings.format = .lf45
        XCTAssertLessThan(deviation(render(image, settings), channel: 1), deviation(first, channel: 1))
        settings.format = .mm35; settings.grain = 0
        XCTAssertLessThan(deviation(render(image, settings), channel: 1), deviation(first, channel: 1) / 4)
    }

    func testTungstenLightWarmsDaylightFilm() throws {
        try XCTSkipUnless(catalog.isAvailable)
        var settings = film("portra400", on: "screen"); settings.style = .fixed
        let balanced = mean(gray, settings)
        settings.light = .tungsten
        let tungsten = mean(gray, settings)
        XCTAssertGreaterThan(tungsten.x / tungsten.z, balanced.x / balanced.z * 1.1)
    }

    func testAPartOfTheFrameIsTheWholeFramesPicture() throws {
        try XCTSkipUnless(catalog.isAvailable)
        // A ramp, so levels and position both show; Core Image is asked for a corner of the developed frame.
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 200, y: 120),
                                                                   "inputColor0": CIColor(red: 0.02, green: 0.02, blue: 0.02), "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.5)])!
            .outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 120))
        var settings = film("portra400"); settings.grain = 0
        let out = FilmSimulationRenderer().apply(settings, to: ramp)
        var whole = [Float](repeating: 0, count: 200 * 120 * 4), corner = [Float](repeating: 0, count: 50 * 30 * 4)
        whole.withUnsafeMutableBytes { context.render(out, toBitmap: $0.baseAddress!, rowBytes: 200 * 16, bounds: ramp.extent, format: .RGBAf, colorSpace: nil) }
        let part = CGRect(x: 120, y: 70, width: 50, height: 30)
        corner.withUnsafeMutableBytes { context.render(out, toBitmap: $0.baseAddress!, rowBytes: 50 * 16, bounds: part, format: .RGBAf, colorSpace: nil) }
        // Bitmaps hold their top row first: the part's first row is the frame's row 120 - 100.
        for (row, column) in [(0, 0), (12, 31), (29, 49)] {
            for c in 0..<3 {
                XCTAssertEqual(corner[(row * 50 + column) * 4 + c], whole[((20 + row) * 200 + 120 + column) * 4 + c], accuracy: 1e-4)
            }
        }
    }

    func testALargeFrameDevelopsAsASmallOneDoesTheRightWayUp() throws {
        try XCTSkipUnless(catalog.isAvailable)
        // Four quadrants of different tones and colors: a large frame renders its own scene, a small one is handed
        // it, and both must lay the picture the same way round.
        func quadrants(_ width: Double, _ height: Double) -> CIImage {
            let colors: [(CGRect, SIMD3<Double>)] = [
                (CGRect(x: 0, y: 0, width: width / 2, height: height / 2), SIMD3(0.04, 0.04, 0.04)), (CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2), SIMD3(0.5, 0.1, 0.1)),
                (CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2), SIMD3(0.1, 0.5, 0.1)), (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2), SIMD3(0.2, 0.2, 0.7))]
            return colors.reduce(CIImage.empty()) { image, part in
                CIImage(color: CIColor(red: part.1.x, green: part.1.y, blue: part.1.z, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: part.0).composited(over: image)
            }
        }
        var settings = film("portra400"); settings.grain = 0; settings.halation = 0
        func corners(_ width: Int, _ height: Int) -> [SIMD3<Float>] {
            let image = quadrants(Double(width), Double(height))
            let out = FilmSimulationRenderer().apply(settings, to: image)
            // A patch well inside each quadrant, read on its own.
            return [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].map { x, y in
                var patch = [Float](repeating: 0, count: 8 * 8 * 4)
                patch.withUnsafeMutableBytes {
                    context.render(out, toBitmap: $0.baseAddress!, rowBytes: 8 * 16, bounds: CGRect(x: Double(width) * x, y: Double(height) * y, width: 8, height: 8), format: .RGBAf, colorSpace: nil)
                }
                return SIMD3(patch[0], patch[1], patch[2])
            }
        }
        let small = corners(600, 400), large = corners(4800, 3200)
        for (a, b) in zip(small, large) { for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 0.01) } }
        XCTAssertGreaterThan(simd_distance(small[1], small[2]), 0.1)
    }

    func testAFrameInTilesAndBetweenTexturesIsTheSamePicture() throws {
        try XCTSkipUnless(catalog.isAvailable)
        let renderer = try XCTUnwrap(FilmPrintRenderer.shared)
        let (width, height) = (700, 460)
        // Tones over nine stops with color, texture and small lights, so every spatial stage has something to spread.
        var scene = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width), v = Float(y) / Float(height), i = (y * width + x) * 4
            let level = 0.01 * powf(2, 9 * u) * (0.9 + 0.2 * Float((x &* 7919 &+ y &* 104729) % 97) / 97)
            let light = (x % 150 == 75 && y % 150 == 75) ? Float(40) : 0
            scene[i] = level * (0.8 + 0.2 * sinf(v * 30)) + light; scene[i + 1] = level + light; scene[i + 2] = level * (0.8 + 0.2 * cosf(u * 40)) + light
        } }
        func develop(_ settings: FilmSimulation, tilePixels: Int?, textures: Bool) throws -> [Float] {
            let development = try XCTUnwrap(catalog.development(settings))
            var out = [Float](repeating: 0, count: scene.count)
            if textures {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                let from = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor)), to = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
                scene.withUnsafeBytes { from.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
                XCTAssertTrue(renderer.develop(scene: .texture(from), picture: .texture(to), width: width, height: height, stock: development.stock, options: development.options, tilePixels: tilePixels))
                out.withUnsafeMutableBytes { to.getBytes($0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            } else {
                let done = scene.withUnsafeBytes { source in
                    out.withUnsafeMutableBytes { target in
                        renderer.develop(scene: .memory(UnsafeMutableRawPointer(mutating: source.baseAddress!), bytesPerRow: width * 16), picture: .memory(target.baseAddress!, bytesPerRow: width * 16),
                                         width: width, height: height, stock: development.stock, options: development.options, tilePixels: tilePixels)
                    }
                }
                XCTAssertTrue(done)
            }
            return out
        }
        // A paper print with everything on, a scan that meters the frame, a slide, black-and-white, and a stock with
        // a fourth layer.
        for (stock, medium) in [("portra400", nil), ("portra400", "screen"), ("velvia50", nil), ("trix400", nil), ("pro400h", "lab-scan")] as [(String, String?)] {
            let settings = film(stock, on: medium)
            let whole = try develop(settings, tilePixels: nil, textures: false)
            XCTAssertGreaterThan(whole[1], 0); XCTAssertTrue(whole.allSatisfy(\.isFinite))
            for (tiles, textures) in [(1 << 16, false), (1 << 16, true), (nil, true)] as [(Int?, Bool)] {
                let other = try develop(settings, tilePixels: tiles, textures: textures)
                var apart: Float = 0
                for i in whole.indices { apart = max(apart, abs(whole[i] - other[i])) }
                XCTAssertLessThan(apart, 1e-5, "\(stock) on \(medium ?? "its own") in \(tiles == nil ? "one piece" : "tiles")\(textures ? " between textures" : "")")
            }
        }
    }

    // MARK: On a photo

    private var sample: URL { get throws { try TestSamples.require(TestSamples.landscape) } }
    private func pixels(_ image: CGImage) -> [UInt16] {
        var data = [UInt16](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: image.width * 8,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    func testAmountBlendsTheCameraAndFilmRenderings() async throws {
        try XCTSkipUnless(catalog.isAvailable)
        let (renderer, defaults) = try RawRenderer.open(sample)
        var settings = defaults; settings.film = FilmSimulation(stock: "portra400"); settings.film?.grain = 0
        let full = pixels(try await renderer.preview(settings).image)
        settings.film?.amount = 0
        let none = pixels(try await renderer.preview(settings).image), camera = pixels(try await renderer.preview(defaults).image)
        settings.film?.amount = 50
        let half = pixels(try await renderer.preview(settings).image)
        var offCamera = 0.0, offMiddle = 0.0, apart = 0.0, count = 0.0
        for i in stride(from: 0, to: full.count, by: 4 * 997) {
            count += 1
            offCamera = max(offCamera, abs(Double(none[i]) - Double(camera[i])) / 65535)
            apart = max(apart, abs(Double(full[i]) - Double(camera[i])) / 65535)
            // Blending is linear, the preview gamma encoded: compare in linear light.
            func linear(_ v: UInt16) -> Double { FilmMath.decode(Double(v) / 65535) }
            offMiddle += abs(linear(half[i]) - (linear(full[i]) + linear(camera[i])) / 2)
        }
        // On average: colors either rendering takes out of the output gamut are clipped after the blend.
        XCTAssertLessThan(offCamera, 0.01); XCTAssertGreaterThan(apart, 0.1); XCTAssertLessThan(offMiddle / count, 0.01)
    }

    func testTestStripRingAroundAndNeutralBalanceWorkOnAPhoto() async throws {
        try XCTSkipUnless(catalog.isAvailable)
        let (renderer, defaults) = try RawRenderer.open(sample)
        var settings = defaults; settings.film = FilmSimulation(stock: "portra400"); settings.film?.grain = 0
        let strip = try await renderer.filmTestStrip(settings, steps: [-1, 0, 1])
        XCTAssertGreaterThan(try XCTUnwrap(strip).width, 1000)
        // More print exposure is a lighter picture on every medium.
        let lighter = try await renderer.filmTestStrip(settings, steps: [1, 1, 1]).map(pixels)!
        let darker = try await renderer.filmTestStrip(settings, steps: [-1, -1, -1]).map(pixels)!
        let sum = { (p: [UInt16]) in stride(from: 1, to: p.count, by: 4 * 101).reduce(0.0) { $0 + Double(p[$1]) } }
        XCTAssertLessThan(sum(darker), sum(lighter))
        // Each band of one strip is its own print: lighter from left to right.
        let bands = try await renderer.filmTestStrip(settings, steps: [-2, 0, 2]).map(pixels)!
        let stripWidth = try XCTUnwrap(strip).width, stripHeight = bands.count / 4 / stripWidth
        let band = { (index: Int) -> Double in
            var total = 0.0
            for y in stride(from: 0, to: stripHeight, by: 16) { for x in stride(from: index * stripWidth / 3 + 8, to: (index + 1) * stripWidth / 3 - 8, by: 16) { total += Double(bands[(y * stripWidth + x) * 4 + 1]) } }
            return total
        }
        XCTAssertLessThan(band(0) * 1.3, band(1)); XCTAssertLessThan(band(1) * 1.3, band(2))
        let ring = try await renderer.filmRingAround(settings, filtrations: [(0, 0), (20, 0)], size: 200)
        XCTAssertEqual(ring.count, 2)
        let neutral = pixels(ring[0]), yellow = pixels(ring[1])
        let blue = { (p: [UInt16]) in stride(from: 0, to: p.count, by: 4 * 31).reduce(0.0) { $0 + Double(p[$1 + 2]) - Double(p[$1]) } }
        XCTAssertLessThan(blue(yellow), blue(neutral))
        // A cast put on the print is taken back off by the dropper.
        settings.film?.yellow = 15; settings.film?.magenta = -10
        let cast = try await renderer.filmNeutralFiltration(at: MaskPoint(x: 0.5, y: 0.5), adjustments: settings)
        let clean = try await renderer.filmNeutralFiltration(at: MaskPoint(x: 0.5, y: 0.5), adjustments: { var s = settings; s.film?.yellow = 0; s.film?.magenta = 0; return s }())
        XCTAssertEqual(try XCTUnwrap(cast).yellow, try XCTUnwrap(clean).yellow, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(cast).magenta, try XCTUnwrap(clean).magenta, accuracy: 3)
        // A viewed negative has nothing to time or balance.
        settings.film?.medium = "negative"
        let untimed = try await renderer.filmTestStrip(settings, steps: [0])
        XCTAssertNil(untimed)
    }

    func testScannedNegativesPrintAsPositives() throws {
        try XCTSkipUnless(catalog.isAvailable)
        // A scan of a negative: the film base, and a denser (brighter in the scene) patch beside a thinner one.
        let base = SIMD3<Float>(0.8, 0.45, 0.25), width = 64, height = 32
        var scan = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let density: Float = x < width / 2 ? 0.4 : 1.0
            for c in 0..<3 { scan[(y * width + x) * 4 + c] = base[c] * pow(10, -density) }
        } }
        var settings = FilmSimulation(stock: "portra400"); settings.grain = 0; settings.halation = 0
        let print = try XCTUnwrap(FilmSimulationRenderer.print(scan: scan, width: width, height: height, base: base, settings: settings))
        let thin = print[(16 * width + 8) * 4 + 1], dense = print[(16 * width + 56) * 4 + 1]
        XCTAssertGreaterThan(dense, thin)
        XCTAssertNil(NegativePrint(stock: "portra400", paper: "no-such-paper").printed(scan, width: width, height: height, inversion: NegativeInversion(base: base, density: .one, gamma: .one, stops: 8, monochrome: false), context: context))
    }
}
