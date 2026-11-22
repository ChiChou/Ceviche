import XCTest
import CoreImage
import simd
import CevicheTestSupport
@testable import CevicheCore

final class CreativeFilterTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .cacheIntermediates: false])

    /// A linear picture from a function of the pixel, rows top down.
    private func picture(_ width: Int, _ height: Int, _ value: (Int, Int) -> Float) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let v = value(x, y); for c in 0..<3 { pixels[(y * width + x) * 4 + c] = v } } }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }
    private func greens(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space) }
        return stride(from: 1, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// A latent image keeps one photo's stack and nothing else: no analysis, one source, a stack that validates.
    func testFilterLatentImageKeepsOnePhotosStack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilterLatent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("photo.tif"), other = folder.appendingPathComponent("other.tif")
        try Data([1, 2, 3]).write(to: photo); try Data([4]).write(to: other)
        var glow = CreativeFilter(.glow); glow["size"] = 70
        let stack = CreativeFilterStack([glow, CreativeFilter(.border)])
        let bundle = folder.appendingPathComponent("photo-Filters.cevichelatent")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pictures = try LatentImage.pictures(context.makeImage()!)
        var latent = try LatentImage(catalogID: "catalog", source: LatentImage.Source(assetID: "a", url: photo), stack: stack, width: 6000, height: 4000)
        try latent.save(to: bundle, pictures: pictures)
        let loaded = try LatentImage.load(bundle)
        XCTAssertEqual(loaded.type, LatentImage.creativeFilters)
        XCTAssertEqual(try loaded.filterStack(), stack)
        XCTAssertEqual(loaded.sources.map(\.assetID), ["a"])

        let saved = latent
        latent.sources.append(try LatentImage.Source(assetID: "b", url: other)); try latent.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle), "one photo only")
        latent = saved; latent.analysisID = UUID().uuidString; try latent.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle), "no analysis")
        var wild = glow; wild.amount = 1000
        latent = saved; latent.settings = try JSONEncoder().encode(CreativeFilterStack([wild])); try latent.save(to: bundle, pictures: pictures)
        XCTAssertThrowsError(try LatentImage.load(bundle), "the stack validates")
    }

    func testStackKnowsWhatItReplacesAndValidates() throws {
        var stack = CreativeFilterStack([CreativeFilter(.glow), CreativeFilter(.denoise), CreativeFilter(.outputSharpen)])
        XCTAssertEqual(stack.setAside, [.noiseReduction, .sharpening])
        var edits = Adjustments()
        edits.noiseReduction = 40; edits.sharpness = 60; edits.clarity = 20
        let developed = stack.developing(edits)
        XCTAssertEqual(developed.noiseReduction, 0); XCTAssertEqual(developed.sharpness, 0); XCTAssertEqual(developed.clarity, 20)
        // A filter that is off replaces nothing.
        stack.filters[1].enabled = false
        XCTAssertEqual(stack.setAside, [.sharpening])
        XCTAssertEqual(stack.developing(edits).noiseReduction, 40)
        // Parameters fall back to their defaults, and round-trip.
        var polarizer = CreativeFilter(.polarizer)
        XCTAssertEqual(polarizer["elevation"], 30); XCTAssertTrue(polarizer.isDefault)
        polarizer["azimuth"] = -120
        let decoded = try JSONDecoder().decode(CreativeFilterStack.self, from: JSONEncoder().encode(CreativeFilterStack([polarizer])))
        XCTAssertEqual(decoded.filters[0]["azimuth"], -120); XCTAssertEqual(decoded.filters[0]["elevation"], 30)
        polarizer["azimuth"] = 400
        XCTAssertThrowsError(try CreativeFilterStack([polarizer]).validated())
        var bloom = CreativeFilter(.bloom)
        bloom.amount = 80
        XCTAssertThrowsError(try CreativeFilterStack([bloom]).validated(), "Bloom runs to 30 %")
        XCTAssertTrue(CreativeFilterStack([]).isEmpty)
    }

    /// Pro Contrast reads the picture: a flat one is stretched to black and white, one that already spans them is left.
    func testProContrastStretchesToThePicturesOwnRange() throws {
        var filter = CreativeFilter(.proContrast)
        filter["contrast"] = 100; filter["dynamic"] = 0
        let flat = picture(200, 120) { x, _ in 0.2 + 0.3 * Float(x) / 199 }
        let levels = try FilterRenderer.levels(flat, context: context)
        XCTAssertEqual(levels.black, 0.2, accuracy: 0.01); XCTAssertEqual(levels.white, 0.5, accuracy: 0.01)
        XCTAssertNotNil(levels.neutral, "a grey picture is all neutral")
        let after = greens(try FilterRenderer.proContrast(flat, filter: filter, context: context))
        XCTAssertEqual(after[60 * 200], 0, accuracy: 0.02); XCTAssertEqual(after[60 * 200 + 199], 1, accuracy: 0.03)
        filter["contrast"] = 50
        let half = greens(try FilterRenderer.proContrast(flat, filter: filter, context: context))
        XCTAssertEqual(half[60 * 200], 0.154, accuracy: 0.02, "half way: black at 0.1, white at 0.75")
        let full = picture(200, 120) { x, _ in Float(x) / 199 }
        filter["contrast"] = 100
        let kept = greens(try FilterRenderer.proContrast(full, filter: filter, context: context))
        XCTAssertEqual(kept[60 * 200 + 100], greens(full)[60 * 200 + 100], accuracy: 0.02)
    }

    /// Pro Contrast takes a cast out of the neutrals and keeps their luminance.
    func testProContrastNeutralizesACast() throws {
        var pixels = [Float](repeating: 1, count: 160 * 100 * 4)
        for i in 0..<(160 * 100) { let v = 0.15 + 0.5 * Float(i % 160) / 159; pixels[i * 4] = v * 1.15; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v * 0.9 }
        let warm = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 160 * 16, size: CGSize(width: 160, height: 100), format: .RGBAf, colorSpace: space)
        var filter = CreativeFilter(.proContrast)
        filter["cast"] = 100; filter["contrast"] = 0; filter["dynamic"] = 0
        let output = try FilterRenderer.proContrast(warm, filter: filter, context: context)
        var out = [Float](repeating: 0, count: 160 * 100 * 4)
        out.withUnsafeMutableBytes { context.render(output, toBitmap: $0.baseAddress!, rowBytes: 160 * 16, bounds: output.extent, format: .RGBAf, colorSpace: space) }
        let i = (50 * 160 + 80) * 4
        XCTAssertEqual(out[i], out[i + 1], accuracy: 0.01); XCTAssertEqual(out[i + 2], out[i + 1], accuracy: 0.01)
        let before = 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2]
        XCTAssertEqual(out[i + 1], before, accuracy: 0.01)
    }

    /// Detail Extractor lifts the shadows, holds the highlights back, and raises the texture in both.
    func testDetailExtractorCompressesTonesAndRaisesDetail() {
        let image = picture(320, 200) { x, y in (x < 160 ? 0.02 : 0.7) * (1 + 0.08 * ((x / 20 + y / 20) % 2 == 0 ? 1 : -1)) }
        var filter = CreativeFilter(.detailExtractor)
        filter.amount = 60
        let before = greens(image), after = greens(FilterRenderer.detailExtractor(image, filter: filter))
        func mean(_ values: [Float], _ columns: Range<Int>) -> Float { var sum: Float = 0; for y in 60..<140 { for x in columns { sum += values[y * 320 + x] } }; return sum / Float(80 * columns.count) }
        func spread(_ values: [Float], _ columns: Range<Int>) -> Float { let m = mean(values, columns); var sum: Float = 0; for y in 60..<140 { for x in columns { sum += abs(values[y * 320 + x] - m) } }; return sum / Float(80 * columns.count) / m }
        XCTAssertGreaterThan(mean(after, 40..<120), mean(before, 40..<120) * 1.5, "shadows come up")
        XCTAssertLessThan(mean(after, 200..<280), mean(before, 200..<280), "highlights come down")
        XCTAssertGreaterThan(spread(after, 40..<120), spread(before, 40..<120) * 1.3); XCTAssertGreaterThan(spread(after, 200..<280), spread(before, 200..<280) * 1.3)
        filter.amount = 0
        XCTAssertTrue(FilterRenderer.detailExtractor(image, filter: filter) === image, "nothing asked, nothing done")
    }

    /// Darken / Lighten Center: the middle by its stops, the border by its own, around the placed centre.
    func testCenterSetsMiddleAndBorderApart() {
        let grey = picture(300, 200) { _, _ in 0.2 }
        var filter = CreativeFilter(.center)
        filter["center"] = 100; filter["border"] = -100; filter["shape"] = 0
        var after = greens(FilterRenderer.center(grey, filter: filter))
        XCTAssertEqual(log2(after[100 * 300 + 150] / 0.2), 1.5, accuracy: 0.05); XCTAssertEqual(log2(after[2 * 300 + 2] / 0.2), -1.5, accuracy: 0.05)
        // Placed top left, the light follows.
        filter["x"] = 10; filter["y"] = 10
        after = greens(FilterRenderer.center(grey, filter: filter))
        XCTAssertGreaterThan(after[20 * 300 + 30], after[100 * 300 + 150]); XCTAssertEqual(log2(after[198 * 300 + 298] / 0.2), -1.5, accuracy: 0.05)
        filter["center"] = 0; filter["border"] = 0
        XCTAssertTrue(FilterRenderer.center(grey, filter: filter) === grey)
    }

    private func rgb(_ image: CIImage) -> [SIMD3<Float>] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space) }
        return stride(from: 0, to: pixels.count, by: 4).map { SIMD3(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) }
    }
    private func colored(_ width: Int, _ height: Int, _ value: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let v = value(x, y); for c in 0..<3 { pixels[(y * width + x) * 4 + c] = v[c] } } }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }

    /// Bleach Bypass takes colour out and spreads the tones; Cross Processing splits the channels by tone.
    func testBleachBypassAndCrossProcessing() {
        let patches = colored(90, 30) { x, _ in x < 30 ? SIMD3(0.05, 0.02, 0.02) : x < 60 ? SIMD3(0.18, 0.18, 0.18) : SIMD3(0.8, 0.5, 0.4) }
        var bleach = CreativeFilter(.bleachBypass)
        bleach.amount = 100
        let before = rgb(patches), bleached = rgb(FilterRenderer.bleachBypass(patches, filter: bleach))
        func chroma(_ v: SIMD3<Float>) -> Float { (v.max() - v.min()) / v.max() }
        func luminance(_ v: SIMD3<Float>) -> Float { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
        XCTAssertLessThan(chroma(bleached[15 * 90 + 75]), chroma(before[15 * 90 + 75]) * 0.6)
        XCTAssertLessThan(luminance(bleached[15 * 90 + 15]), luminance(before[15 * 90 + 15]), "shadows go down")
        XCTAssertGreaterThan(luminance(bleached[15 * 90 + 75]), luminance(before[15 * 90 + 75]), "highlights go up")
        bleach.amount = 0
        XCTAssertTrue(FilterRenderer.bleachBypass(patches, filter: bleach) === patches)

        let greys = colored(90, 30) { x, _ in x < 30 ? SIMD3(repeating: 0.01) : x < 60 ? SIMD3(repeating: 0.18) : SIMD3(repeating: 0.85) }
        var cross = CreativeFilter(.crossProcess)
        cross.amount = 100
        let slide = rgb(FilterRenderer.crossProcess(greys, filter: cross))
        XCTAssertGreaterThan(slide[15 * 90 + 15].z, slide[15 * 90 + 15].x, "slide film in C-41: blue shadows")
        XCTAssertLessThan(slide[15 * 90 + 75].z, slide[15 * 90 + 75].y, "and yellow highlights")
        cross["method"] = 1
        let negative = rgb(FilterRenderer.crossProcess(greys, filter: cross))
        XCTAssertGreaterThan(negative[15 * 90 + 45].z, negative[15 * 90 + 45].x, "negative film in E-6: cool")
    }

    /// Fog lifts the blacks, everywhere or on one side of the horizon; a reflector fills shadows from its side; a
    /// light leak adds light at its edge only.
    func testFogReflectorAndLightLeak() {
        let dark = picture(200, 120) { _, _ in 0.02 }
        var fog = CreativeFilter(.fog)
        fog.amount = 60
        var after = greens(FilterRenderer.fog(dark, filter: fog))
        XCTAssertGreaterThan(after[60 * 200 + 100], 0.15); XCTAssertEqual(after[5 * 200 + 100], after[115 * 200 + 100], accuracy: 0.01)
        fog["cover"] = 1
        after = greens(FilterRenderer.fog(dark, filter: fog))
        XCTAssertGreaterThan(after[2 * 200 + 100], 0.15, "fog at the top"); XCTAssertEqual(after[118 * 200 + 100], 0.02, accuracy: 0.005, "none at the bottom")

        var reflector = CreativeFilter(.reflector)
        reflector.amount = 100
        let filled = rgb(FilterRenderer.reflector(dark, filter: reflector))
        XCTAssertGreaterThan(filled[118 * 200 + 100].y, 0.03, "from below, the bottom is filled"); XCTAssertEqual(filled[2 * 200 + 100].y, 0.02, accuracy: 0.002)
        XCTAssertGreaterThan(filled[118 * 200 + 100].x, filled[118 * 200 + 100].z, "gold")
        reflector["direction"] = 90
        XCTAssertGreaterThan(greens(FilterRenderer.reflector(dark, filter: reflector))[60 * 200 + 198], greens(FilterRenderer.reflector(dark, filter: reflector))[60 * 200 + 2], "from the right")
        let bright = picture(200, 120) { _, _ in 0.9 }
        XCTAssertEqual(greens(FilterRenderer.reflector(bright, filter: CreativeFilter(.reflector, amount: 100, ["direction": 0])))[118 * 200 + 100], 0.9, accuracy: 0.06, "highlights hardly move")

        var leak = CreativeFilter(.lightLeak)
        leak.amount = 100
        let leaked = rgb(FilterRenderer.lightLeak(dark, filter: leak))
        XCTAssertGreaterThan(leaked[36 * 200 + 2].x, 0.5, "light at the left edge"); XCTAssertLessThan(leaked[36 * 200 + 198].x, 0.07, "only a trace reaches the far edge")
        XCTAssertGreaterThan(leaked[36 * 200 + 2].x, leaked[36 * 200 + 2].z, "warm")
        leak["edge"] = 3
        XCTAssertGreaterThan(rgb(FilterRenderer.lightLeak(dark, filter: leak))[118 * 200 + 60].x, 0.5, "and at the bottom when asked")
    }

    /// Bokeh leaves its zone sharp, blurs past it, and keeps a point of light as a disc rather than losing it.
    func testBokehBlursOutsideItsZone() {
        let stripes = picture(300, 200) { x, _ in x % 4 < 2 ? 0.1 : 0.5 }
        var bokeh = CreativeFilter(.bokeh)
        bokeh.amount = 100; bokeh["size"] = 20; bokeh["falloff"] = 20; bokeh["highlights"] = 0
        func contrast(_ values: [Float], _ x: Int, _ y: Int) -> Float { let row = (x..<(x + 8)).map { values[y * 300 + $0] }; return row.max()! - row.min()! }
        var after = greens(FilterRenderer.bokeh(stripes, filter: bokeh))
        XCTAssertEqual(contrast(after, 146, 100), 0.4, accuracy: 0.02, "sharp in the zone"); XCTAssertLessThan(contrast(after, 10, 100), 0.05, "defocused at the side")
        // A band keeps the whole row through its point; placed at the top, the bottom goes soft.
        bokeh["shape"] = 1; bokeh["y"] = 10
        after = greens(FilterRenderer.bokeh(stripes, filter: bokeh))
        XCTAssertEqual(contrast(after, 10, 20), 0.4, accuracy: 0.02); XCTAssertLessThan(contrast(after, 10, 190), 0.05)
        // A lamp out of focus: with Highlights its disc is brighter than a plain blur makes it.
        let lamp = picture(300, 200) { x, y in (28..<32).contains(x) && (98..<102).contains(y) ? 6 : 0.05 }
        bokeh["shape"] = 0; bokeh["y"] = 50
        let plain = greens(FilterRenderer.bokeh(lamp, filter: bokeh))[100 * 300 + 34]
        bokeh["highlights"] = 100
        XCTAssertGreaterThan(greens(FilterRenderer.bokeh(lamp, filter: bokeh))[100 * 300 + 34], plain * 1.5)
        bokeh.amount = 0
        XCTAssertTrue(FilterRenderer.bokeh(lamp, filter: bokeh) === lamp)
    }

    /// Dust & Scratches lays a texture's marks over the picture, white or black, and leaves the rest alone.
    func testDustMarksThePicture() {
        let grey = picture(300, 200) { _, _ in 0.2 }
        for (place, texture) in FilmTexture.all.enumerated() {
            XCTAssertNotNil(texture.image, texture.id)
            var dust = CreativeFilter(.dust)
            dust.amount = 100; dust["texture"] = Double(place)
            let white = greens(FilterRenderer.dust(grey, filter: dust))
            XCTAssertGreaterThan(white.max()!, 0.4, "\(texture.id): marks, faint for the fine scratches and drying marks"); XCTAssertEqual(white.sorted()[white.count / 2], 0.2, accuracy: 0.02, "\(texture.id): most of the picture is untouched")
            dust["tone"] = 1
            let black = greens(FilterRenderer.dust(grey, filter: dust))
            XCTAssertLessThan(black.min()!, 0.15, texture.id); XCTAssertLessThanOrEqual(black.max()!, 0.201)
        }
        var dust = CreativeFilter(.dust)
        dust.amount = 100
        let first = greens(FilterRenderer.dust(grey, filter: dust))
        dust["variation"] = 1
        XCTAssertNotEqual(first, greens(FilterRenderer.dust(grey, filter: dust)), "a variation moves the marks")
        XCTAssertEqual(FilterRenderer.dust(picture(200, 300) { _, _ in 0.2 }, filter: dust).extent, CGRect(x: 0, y: 0, width: 200, height: 300))
    }

    /// The contrast filters stay finite on a hard picture: pure black, colours outside the gamut (a negative
    /// channel), and highlights far above white, one after another as a chain runs them.
    func testContrastFiltersStayFiniteOnAHardPicture() throws {
        let hard = colored(240, 160) { x, y in
            if x < 60 { return SIMD3(0, 0, 0) }
            if x < 120 { return SIMD3(0.9, -0.05, 0.02) }
            if x < 180 { return SIMD3(Float(y) / 160 * 0.02, 0.001, 0.3) }
            // A highlight past what a half-float holds: infinite by the time a filter reads it.
            if x > 228 && y < 6 { return SIMD3(.infinity, .infinity, .infinity) }
            return SIMD3(12, 9, 4)
        }
        var tonal = CreativeFilter(.tonalContrast)
        tonal["highs"] = 40; tonal["mids"] = 60; tonal["shadows"] = 50; tonal["radius"] = 60
        var extractor = CreativeFilter(.detailExtractor)
        extractor.amount = 25
        for (name, stack) in [("tonal", [tonal]), ("extractor", [extractor]), ("tonal then extractor", [tonal, extractor]), ("extractor then tonal", [extractor, tonal]),
                              ("pro contrast", [CreativeFilter(.proContrast), tonal, extractor])] {
            let pixels = rgb(try FilterRenderer.print(hard, stack: CreativeFilterStack(stack), context: context))
            // Only the overflowed highlight itself may stay as it came; nothing around it is dragged down.
            let broken = pixels.enumerated().filter { !($0.element.x.isFinite && $0.element.y.isFinite && $0.element.z.isFinite) }.map(\.offset)
            XCTAssertTrue(broken.allSatisfy { $0 % 240 > 228 && $0 / 240 < 6 }, "\(name): \(broken.count) pixels are not numbers")
            XCTAssertGreaterThan(pixels[80 * 240 + 30].x + pixels[80 * 240 + 150].z, 0.05, "\(name): the dark patches are not crushed")
            XCTAssertGreaterThan(pixels[80 * 240 + 90].x, 0.2, "\(name): the red patch is still there")
            XCTAssertGreaterThan(pixels[80 * 240 + 210].x, 1, "\(name): the highlight is still bright")
        }
    }

    /// Every filter hands on a picture that is exactly opaque. One that came out more than opaque (blur layers added
    /// with their alphas) loses light when the export lays it over white: only the brightest areas survive.
    func testFiltersLeaveThePictureOpaque() throws {
        let scene = colored(240, 160) { x, y in SIMD3(0.05 + 0.6 * Float(x) / 240, 0.2, 0.05 + 0.5 * Float(y) / 160) }
        for kind in CreativeFilterKind.allCases where kind != .polarizer && kind != .denoise && kind != .border {
            var filter = CreativeFilter(kind)
            filter.amount = kind.amountRange.upperBound
            let stack = CreativeFilterStack([filter])
            var image = try FilterRenderer.scene(scene, stack: stack, photo: FilterRenderer.Photo(), context: context)
            image = try FilterRenderer.print(image, stack: stack, context: context)
            var pixels = [Float](repeating: 0, count: 240 * 160 * 4)
            pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 240 * 16, bounds: scene.extent, format: .RGBAf, colorSpace: space) }
            let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
            XCTAssertEqual(alphas.min()!, 1, accuracy: 0.002, "\(kind.rawValue)"); XCTAssertEqual(alphas.max()!, 1, accuracy: 0.002, "\(kind.rawValue)")
        }
    }

    /// A border grows the picture by its width on every side, round all the other print filters.
    func testBorderGrowsThePicture() throws {
        let grey = picture(200, 100) { _, _ in 0.3 }
        var black = CreativeFilter(.border)
        black.amount = 5; black["tone"] = 1
        let stack = CreativeFilterStack([black, CreativeFilter(.center)])
        XCTAssertEqual(stack.border, .margins(BorderInsets(top: 0.05, left: 0.05, bottom: 0.05, right: 0.05)))
        let framed = try FilterRenderer.print(grey, stack: stack, context: context)
        XCTAssertEqual(framed.extent, CGRect(x: 0, y: 0, width: 220, height: 120))
        let pixels = greens(framed)
        XCTAssertEqual(pixels[5 * 220 + 110], 0, accuracy: 0.001, "the mat"); XCTAssertGreaterThan(pixels[60 * 220 + 110], 0.3, "the picture, with its centre lit")
        XCTAssertEqual(try FilterRenderer.print(grey, stack: CreativeFilterStack([CreativeFilter(.center)]), context: context).extent, grey.extent)
        // 35 mm film: perforation bands above and below, three times the sides, with holes the paper shows through.
        var film = CreativeFilter(.border)
        film.amount = 10; film["style"] = Double(BorderStyle.film35.rawValue)
        let strip = try FilterRenderer.print(grey, stack: CreativeFilterStack([film]), context: context)
        XCTAssertEqual(strip.extent, CGRect(x: 0, y: 0, width: 218, height: 160))
        let rows = greens(strip)
        XCTAssertEqual(rows[80 * 218 + 109], 0.3, accuracy: 0.01, "the picture"); XCTAssertLessThan(rows[80 * 218 + 3], 0.01, "film at the side")
        XCTAssertGreaterThan((0..<218).map { rows[13 * 218 + $0] }.max()!, 0.9, "a perforation"); XCTAssertLessThan((0..<218).map { rows[13 * 218 + $0] }.min()!, 0.01)
        // Shown at any size, the border's sides come back in proportion.
        let shown = BorderStyle.film35.insets(width: 0.1).shown(in: CGSize(width: 436, height: 320))
        XCTAssertEqual(shown.left, 18, accuracy: 0.01); XCTAssertEqual(shown.top, 60, accuracy: 0.01)
        let upright = BorderStyle.instant.insets(width: 0.05).shown(in: CGSize(width: 240, height: 484))
        XCTAssertEqual(upright.bottom, 64, accuracy: 0.01, "400 long: 20 on three sides, 64 at the foot")
        // The pictured borders: every one loads, puts the photo in its opening, and turns for an upright photo.
        XCTAssertEqual(BorderChoice.titles.count, BorderStyle.allCases.count + BorderAsset.all.count)
        XCTAssertEqual(BorderChoice(index: BorderStyle.allCases.count), .asset(BorderAsset.all[0])); XCTAssertEqual(BorderChoice(index: 999), .drawn(.plain))
        for (place, asset) in BorderAsset.all.enumerated() {
            XCTAssertNotNil(asset.image, asset.id)
            for (width, height) in [(300, 200), (200, 300)] {
                let photo = picture(width, height) { _, _ in 0.3 }
                var border = CreativeFilter(.border)
                border["style"] = Double(BorderStyle.allCases.count + place)
                let stack = CreativeFilterStack([border]), framed = try FilterRenderer.print(photo, stack: stack, context: context)
                XCTAssertGreaterThan(framed.extent.width, Double(width), asset.id); XCTAssertGreaterThan(framed.extent.height, Double(height), asset.id)
                // Where the dialog's handles take the photo to be is where the file has it.
                let place = stack.border.pictureRect(in: framed.extent.size, upright: height > width)
                XCTAssertEqual(place.width, Double(width), accuracy: 1.5, asset.id); XCTAssertEqual(place.height, Double(height), accuracy: 1.5, asset.id)
                let pixels = greens(framed), row = Int(place.midY), column = Int(place.midX)
                XCTAssertEqual(pixels[row * Int(framed.extent.width) + column], 0.3, accuracy: 0.02, "\(asset.id): the photo shows in the middle")
            }
        }
        if let folder = ProcessInfo.processInfo.environment["CEVICHE_BORDER_OUTPUT"] {
            for (place, asset) in BorderAsset.all.enumerated() { for (width, height) in [(900, 600), (600, 900), (700, 700)] {
                let card = picture(width, height) { x, y in 0.08 + 0.5 * Float(x + y) / Float(width + height) }
                var border = CreativeFilter(.border)
                border["style"] = Double(BorderStyle.allCases.count + place)
                let framed = try FilterRenderer.print(card, stack: CreativeFilterStack([border]), context: context)
                try context.writePNGRepresentation(of: framed, to: URL(fileURLWithPath: folder).appendingPathComponent("\(asset.id)-\(width)x\(height).png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            } }
        }
        // CEVICHE_BORDER_OUTPUT=<folder> writes each style round a grey card, to look at.
        if let folder = ProcessInfo.processInfo.environment["CEVICHE_BORDER_OUTPUT"] {
            let card = picture(900, 600) { x, y in 0.08 + 0.5 * Float(x + y) / 1500 }
            for style in BorderStyle.allCases { for black in [false, true] {
                var border = CreativeFilter(.border)
                border.amount = 5; border["style"] = Double(style.rawValue); border["tone"] = black ? 1 : 0
                let framed = try FilterRenderer.print(card, stack: CreativeFilterStack([border]), context: context)
                try context.writePNGRepresentation(of: framed, to: URL(fileURLWithPath: folder).appendingPathComponent("\(style.rawValue)-\(black ? "black" : "white").png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            } }
        }
        for style in BorderStyle.allCases { XCTAssertNotNil(BorderRenderer.art(style, size: CGSize(width: 240, height: 160), window: CGRect(x: 20, y: 20, width: 200, height: 120), unit: 20, black: true), style.title) }
    }

    /// Diffusion and Bloom move light and add none, with no threshold: a dim lamp spreads like a bright one.
    /// Light the picture filters add from one edge (Fog, Light Leak, white Dust) stops at the photo: the border round
    /// it is the same film top and bottom.
    func testPictureFiltersStayOffTheBorder() throws {
        let grey = picture(300, 200) { _, _ in 0.1 }
        var film = CreativeFilter(.border)
        film.amount = 4; film["style"] = Double(BorderStyle.film35.rawValue)
        var fog = CreativeFilter(.fog); fog.amount = 40; fog["cover"] = 1
        var leak = CreativeFilter(.lightLeak); leak.amount = 100
        var dust = CreativeFilter(.dust); dust.amount = 100
        for filter in [fog, leak, dust] {
            let framed = try FilterRenderer.print(grey, stack: CreativeFilterStack([filter, film]), context: context)
            let width = Int(framed.extent.width), height = Int(framed.extent.height), pixels = greens(framed)
            for y in [2, 40, height / 2, height - 40, height - 3] {
                XCTAssertLessThan(pixels[y * width + 2], 0.01, "\(filter.kind) on the film's edge, row \(y)")
            }
        }
    }

    func testDiffusionAndBloomConserveLight() {
        for level in [Float(0.2), 4] {
            let lamp = picture(240, 160) { x, y in (116..<124).contains(x) && (76..<84).contains(y) ? level : 0.01 }
            let before = greens(lamp)
            // Diffusion's tail is about 1 % of the long side, so its light lands just outside the lamp; Bloom's goes further.
            for (name, filtered, near) in [("diffusion", FilterRenderer.diffusion(lamp, amount: 0.6, size: 0.5), 126), ("bloom", FilterRenderer.bloom(lamp, amount: 0.2, size: 0.5), 132)] {
                XCTAssertEqual(filtered.extent, lamp.extent)
                let after = greens(filtered)
                // Light that leaves the lamp lands around it; a little spreads past the frame.
                XCTAssertEqual(after.reduce(0, +) / before.reduce(0, +), 1, accuracy: 0.06, "\(name) at \(level)")
                XCTAssertLessThan(after[80 * 240 + 120], before[80 * 240 + 120], "\(name): the lamp gives light up")
                XCTAssertGreaterThan(after[80 * 240 + near], before[80 * 240 + near] * 1.02, "\(name): its surroundings gain it")
            }
            XCTAssertTrue(FilterRenderer.diffusion(lamp, amount: 0, size: 0.5) === lamp)
        }
        // Bloom reaches much further than Diffusion.
        let lamp = picture(400, 200) { x, y in (196..<204).contains(x) && (96..<104).contains(y) ? 4 : 0.01 }
        let far = 100 * 400 + 260
        let bloomed = greens(FilterRenderer.bloom(lamp, amount: 0.2, size: 0.5))[far], diffused = greens(FilterRenderer.diffusion(lamp, amount: 0.2, size: 0.5))[far]
        XCTAssertGreaterThan(bloomed - 0.01, (diffused - 0.01) * 3 + 1e-4, "60 px from the lamp")
    }

    /// Glow's styles each spread a lamp their own way: Halo (the filter before styles) round it, Halation red, Motion
    /// and Streak along their angle, Streak only from the brightest light.
    func testGlowStylesSpreadTheirOwnWay() throws {
        let width = 400, height = 200
        let lamp = picture(width, height) { x, y in (196..<204).contains(x) && (96..<104).contains(y) ? 4 : 0.01 }
        func rendered(_ style: Glow.Style, angle: Double = 0, level: Float = 4) throws -> [Float] {
            var filter = CreativeFilter(.glow, amount: 60, ["style": Double(style.rawValue), "angle": angle])
            filter["size"] = 40
            let source = level == 4 ? lamp : picture(width, height) { x, y in (196..<204).contains(x) && (96..<104).contains(y) ? level : 0.01 }
            let image = try FilterRenderer.scene(source, stack: CreativeFilterStack([filter]), photo: .init(), context: context)
            XCTAssertEqual(image.extent, lamp.extent)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space) }
            return pixels
        }
        func at(_ p: [Float], _ x: Int, _ y: Int, _ c: Int = 1) -> Float { p[(y * width + x) * 4 + c] - 0.01 }
        // Halo, the style a Glow without one gets, is the Glow of before: a halo all round.
        var old = CreativeFilter(.glow, amount: 60); old["size"] = 40
        let halo = try rendered(.halo)
        XCTAssertEqual(greens(try FilterRenderer.scene(lamp, stack: CreativeFilterStack([old]), photo: .init(), context: context)), stride(from: 1, to: halo.count, by: 4).map { halo[$0] })
        XCTAssertGreaterThan(at(halo, 230, 100), 0.003); XCTAssertGreaterThan(at(halo, 200, 130), 0.003)
        // Halation is red: the white lamp's fringe has far more red than blue.
        let halation = try rendered(.halation)
        XCTAssertGreaterThan(at(halation, 215, 100, 0), at(halation, 215, 100, 2) * 4 + 1e-3)
        // Mist takes light out of the highlight as well as round it.
        let mist = try rendered(.mist)
        XCTAssertLessThan(at(mist, 200, 100), 4 - 0.01)
        XCTAssertGreaterThan(at(mist, 230, 100), 0.005)
        // Motion and Streak spread along their angle and hardly across it.
        for style in [Glow.Style.motion, .streak] {
            let flat = try rendered(style), upright = try rendered(style, angle: 90)
            XCTAssertGreaterThan(at(flat, 260, 100), at(flat, 200, 160) * 10 + 1e-3, "\(style) along 0°")
            XCTAssertGreaterThan(at(upright, 200, 160), at(upright, 260, 100) * 10 + 1e-3, "\(style) along 90°")
        }
        // A light just over the threshold glows in Halo but doesn't streak.
        XCTAssertGreaterThan(at(try rendered(.halo, level: 0.75), 215, 100), 1e-3)
        XCTAssertEqual(at(try rendered(.streak, level: 0.75), 260, 100), 0, accuracy: 1e-4)
        // Angle is a slider only for the directional styles, and stays in range.
        var wild = CreativeFilter(.glow); wild["angle"] = 120
        XCTAssertThrowsError(try CreativeFilterStack([wild]).validated())

        // CEVICHE_GLOW_OUTPUT=<folder> writes each style over a night scene, or over CEVICHE_GLOW_PHOTO, to look at.
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["CEVICHE_GLOW_OUTPUT"] {
            let small: CIImage
            if let path = environment["CEVICHE_GLOW_PHOTO"], let photo = CIImage(contentsOf: URL(fileURLWithPath: path)) {
                let scale = 1600 / max(photo.extent.width, photo.extent.height)
                small = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                // A blue neon bar, a white lamp, small warm lamps and a lit window over a dark street, rows from the bottom.
                
                var pixels = [Float](repeating: 1, count: 1200 * 800 * 4)
                for y in 0..<800 { for x in 0..<1200 {
                    var c: (Float, Float, Float) = (0.012, 0.012, 0.015)
                    if (600..<612).contains(y), (200..<560).contains(x) { c = (0.3, 1.2, 3) }
                    if (520..<532).contains(y), (200..<560).contains(x) { c = (3, 0.4, 1.2) }
                    if (700 - x) * (700 - x) + (620 - y) * (620 - y) < 36 { c = (6, 6, 5.5) }
                    for lamp in stride(from: 640, to: 1100, by: 90) where (lamp - x) * (lamp - x) + (300 - y) * (300 - y) < 9 { c = (5, 3, 1.2) }
                    if (180..<320).contains(y), (220..<480).contains(x) { c = (1.4, 0.8, 0.35) }
                    if (100..<180).contains(y), (180..<520).contains(x) { c = (0.05, 0.04, 0.035) }
                    pixels[(y * 1200 + x) * 4] = c.0; pixels[(y * 1200 + x) * 4 + 1] = c.1; pixels[(y * 1200 + x) * 4 + 2] = c.2
                } }

                small = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 1200 * 16, size: CGSize(width: 1200, height: 800), format: .RGBAf, colorSpace: space)
            }
            for style in Glow.Style.allCases {
                let filter = CreativeFilter(.glow, amount: 60, ["style": Double(style.rawValue), "angle": style == .streak ? 20 : 0, "threshold": 50])
                let image = try FilterRenderer.scene(small, stack: CreativeFilterStack([filter]), photo: .init(), context: context)
                try context.writeJPEGRepresentation(of: image, to: URL(fileURLWithPath: folder).appendingPathComponent("\(style.rawValue)-\(style).jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            try context.writeJPEGRepresentation(of: small, to: URL(fileURLWithPath: folder).appendingPathComponent("original.jpg"), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }

    /// Each measured diffusion filter moves the share of light it was fitted with and keeps the rest; Custom stays the
    /// size-driven filter, so stacks saved before the types keep their look.
    func testFittedDiffusionTypesMoveTheirShareOfLight() {
        let lamp = picture(400, 200) { x, y in (196..<204).contains(x) && (96..<104).contains(y) ? 4 : 0.01 }
        let before = greens(lamp), centre = 100 * 400 + 200
        var filter = CreativeFilter(.diffusion, amount: 50)
        XCTAssertNil(DiffusionShape.of(filter))
        XCTAssertEqual(filter.kind.parameters.first?.choices?.count, DiffusionShape.fitted.count + 1)
        var kept: [Double] = []
        for (index, shape) in DiffusionShape.fitted.enumerated() {
            filter["type"] = Double(index + 1)
            XCTAssertEqual(DiffusionShape.of(filter), shape)
            XCTAssertLessThanOrEqual(shape.core + shape.tail, 1)
            let after = greens(FilterRenderer.diffusion(lamp, shape: shape, amount: 1))
            XCTAssertEqual(after.reduce(0, +) / before.reduce(0, +), 1, accuracy: 0.06, shape.name)
            XCTAssertLessThan(after[centre], before[centre], shape.name)
            kept.append(Double(after[centre] / before[centre]))
        }
        // The light softener keeps more of the lamp than the diffuser.
        XCTAssertGreaterThan(kept[0], kept[4])
        // Twice the measured amount caps at all of the light moved, never more.
        let doubled = greens(FilterRenderer.diffusion(lamp, shape: DiffusionShape.fitted[2], amount: 2))
        XCTAssertEqual(doubled.reduce(0, +) / before.reduce(0, +), 1, accuracy: 0.06)
        XCTAssertTrue(FilterRenderer.diffusion(lamp, shape: DiffusionShape.fitted[0], amount: 0) === lamp)
    }

    /// Tonal Contrast lifts fine texture in the tones asked for, leaves a flat area alone, and makes no halo of note
    /// at a hard edge.
    func testTonalContrastBoostsTextureByTone() {
        // Left half: mid grey with a ripple. Right half: flat and bright, behind a hard edge.
        let image = picture(320, 200) { x, _ in x < 160 ? 0.18 * (1 + 0.1 * sin(Float(x) * 0.8)) : 0.8 }
        func spread(_ values: [Float], _ range: Range<Int>) -> Float {
            let row = range.map { values[100 * 320 + $0] }
            return row.max()! - row.min()!
        }
        var filter = CreativeFilter(.tonalContrast)
        filter["highs"] = 0; filter["shadows"] = 0; filter["mids"] = 80
        let before = greens(image), after = greens(FilterRenderer.tonalContrast(image, filter: filter))
        XCTAssertGreaterThan(spread(after, 40..<120), spread(before, 40..<120) * 1.3, "the midtone ripple is stronger")
        XCTAssertEqual(after[100 * 320 + 260], 0.8, accuracy: 0.02, "the flat highlight is untouched")
        // Beside the edge the flat side stays within a tenth of a stop.
        for x in 164..<200 { XCTAssertEqual(log2(after[100 * 320 + x] / 0.8), 0, accuracy: 0.12, "halo at x \(x)") }
        // Midtones only: asking for highlights alone leaves the ripple nearly as it was.
        filter["mids"] = 0; filter["highs"] = 80
        XCTAssertEqual(spread(greens(FilterRenderer.tonalContrast(image, filter: filter)), 40..<120), spread(before, 40..<120), accuracy: spread(before, 40..<120) * 0.25)
        filter["highs"] = 0
        XCTAssertTrue(FilterRenderer.tonalContrast(image, filter: filter) === image, "nothing asked, nothing done")
    }

    /// Output Sharpening overshoots an edge a little, more for matte paper than for a screen, and only near the edge.
    func testOutputSharpeningByMedium() {
        let edge = picture(120, 60) { x, _ in x < 60 ? 0.2 : 0.6 }
        func overshoot(_ medium: Int, _ amount: Double = 1) -> Float { greens(FilterRenderer.outputSharpen(edge, amount: amount, medium: medium))[30 * 120 + 60] - 0.6 }
        let screen = overshoot(0), glossy = overshoot(1), matte = overshoot(2)
        XCTAssertGreaterThan(screen, 0.005); XCTAssertGreaterThan(glossy, screen); XCTAssertGreaterThan(matte, glossy)
        XCTAssertGreaterThan(overshoot(0, 2), screen * 1.5, "Amount scales the medium's strength")
        let sharpened = greens(FilterRenderer.outputSharpen(edge, amount: 1, medium: 2))
        XCTAssertEqual(sharpened[30 * 120 + 100], 0.6, accuracy: 0.002, "away from the edge nothing changes")
        XCTAssertEqual(sharpened[30 * 120 + 20], 0.2, accuracy: 0.002)
    }

    /// The polarizer's pattern: nothing toward the sun, the most a quarter turn away, and a filter turned the other
    /// way brightens what the best rotation darkens.
    func testPolarizerFollowsTheRayleighPattern() {
        let k = 0.6
        let sun = FilterRenderer.sun(azimuth: .pi / 2, elevation: 0)   // on the horizon, to the right
        let ahead = FilterRenderer.direction(x: 0, y: 0, focal: 1000, tilt: 0)
        // Straight ahead is 90° from the sun: fully polarized by k, vertically. A horizontal axis blocks it.
        XCTAssertEqual(FilterRenderer.transmission(ahead, sun: sun, angle: 0, k: k), 1 - k, accuracy: 1e-6)
        XCTAssertEqual(FilterRenderer.transmission(ahead, sun: sun, angle: .pi / 2, k: k), 1 + k, accuracy: 1e-6)
        XCTAssertEqual(log2(FilterRenderer.transmission(ahead, sun: sun, angle: 0, k: k)), -1.32, accuracy: 0.01, "1.3 stops at most")
        // Toward the sun there is nothing to polarize.
        XCTAssertEqual(FilterRenderer.transmission(simd_normalize(sun + SIMD3(0, 0.001, 0)), sun: sun, angle: 0, k: k), 1, accuracy: 0.001)
        // The best rotation is the one that darkens: here the horizontal axis.
        let best = FilterRenderer.bestAngle(width: 3000, height: 2000, focal: 2000, tilt: 0, sun: sun, k: k)
        XCTAssertLessThan(min(best, .pi - best), 0.2)
        // A wide lens shows the band: the corner toward the sun is darkened less than the centre.
        let centre = FilterRenderer.transmission(ahead, sun: sun, angle: best, k: k)
        let corner = FilterRenderer.transmission(FilterRenderer.direction(x: 1500, y: 800, focal: 1200, tilt: 0), sun: sun, angle: best, k: k)
        XCTAssertGreaterThan(corner, centre + 0.1)
        // Tilting the camera up looks higher.
        XCTAssertGreaterThan(FilterRenderer.direction(x: 0, y: 0, focal: 1000, tilt: 0.3).y, 0.29)
    }

    /// Through the export path on a real photo: the scene and print filters change the file, and the stack is
    /// applied to a preview the same way.
    func testFiltersApplyThroughExport() async throws {
        try TestTier.requireSlow("Develops a RAW photo twice")
        let url = try TestSamples.require(TestSamples.landscape)
        let (renderer, defaults) = try RawRenderer.open(url)
        var settings = ExportSettings(); settings.select(.jpeg); settings.profile.preset = .sRGB
        var diffusion = CreativeFilter(.diffusion)
        diffusion.amount = 80
        var contrast = CreativeFilter(.tonalContrast)
        contrast["mids"] = 80
        let stack = CreativeFilterStack([diffusion, contrast, CreativeFilter(.outputSharpen)])
        let plain = try await renderer.exportPreview(defaults, settings: settings, maxDimension: 600)
        let filtered = try await renderer.exportPreview(defaults, settings: settings, maxDimension: 600, filters: stack)
        XCTAssertEqual([filtered.width, filtered.height], [plain.width, plain.height])
        func bytes(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let a = bytes(plain), b = bytes(filtered)
        let difference = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        XCTAssertGreaterThan(difference, 0.5, "the stack changes the picture")
        // An empty stack is the plain export.
        let empty = try await renderer.exportPreview(defaults, settings: settings, maxDimension: 600, filters: CreativeFilterStack())
        XCTAssertEqual(bytes(empty), a)
        // And the file is written with the stack at full size.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.sizing = ExportSettings().sizing
        let output = directory.appendingPathComponent("filtered.jpg")
        try await renderer.export(to: output, adjustments: defaults, settings: settings, filters: stack)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0, 100_000)
    }
}
