import XCTest
import CoreImage
import ImageIO
import Metal
import DustRemoval
@testable import CevicheCore

final class DustFinderTests: XCTestCase {
    /// A flat sky with soft dark discs at pixel positions (row 0 at the top), each 60 levels dark at its centre.
    private func sky(width w: Int, height h: Int, spots: [(x: Int, y: Int, r: Int)], noise: Bool = false) -> RGBAImage {
        var image = RGBAImage(width: w, height: h)
        var seed: UInt32 = 7
        for i in 0..<(w * h) {
            seed = seed &* 1664525 &+ 1013904223
            let n = noise ? Int(seed >> 30) : 0
            image.pixels[i * 4] = UInt8(180 + n); image.pixels[i * 4 + 1] = UInt8(200 + n); image.pixels[i * 4 + 2] = UInt8(230 + n); image.pixels[i * 4 + 3] = 255
        }
        for s in spots { for y in (s.y - s.r)...(s.y + s.r) { for x in (s.x - s.r)...(s.x + s.r) {
            let d = hypot(Double(x - s.x), Double(y - s.y)) / Double(s.r)
            guard d <= 1 else { continue }
            let dip = 60 * (1 - d * d), o = (y * w + x) * 4
            for c in 0..<3 { image.pixels[o + c] = UInt8(max(0, Double(image.pixels[o + c]) - dip)) }
        } } }
        return image
    }
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device)
    }
    private func value(_ image: CIImage, _ x: Double, _ y: Double, _ context: CIContext) -> Double {
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        return Double(pixel[0])
    }

    func testClassicDetectorFindsSpotsButNotStarRings() throws {
        let remover = DustRemover()
        XCTAssertEqual(try remover.detect(in: sky(width: 400, height: 300, spots: [(200, 150, 10)]), parameters: DustRemovalParameters()).blobs.count, 1)
        // A bright star on a dark sky: the adaptive threshold draws a dark ring around it, which the contrast gate rejects.
        var night = RGBAImage(width: 400, height: 300)
        var seed: UInt32 = 7
        for i in 0..<(400 * 300) {
            seed = seed &* 1664525 &+ 1013904223
            let v = UInt8(40 + Int(seed >> 29))
            night.pixels[i * 4] = v; night.pixels[i * 4 + 1] = v; night.pixels[i * 4 + 2] = v &+ 10; night.pixels[i * 4 + 3] = 255
        }
        for y in 147...153 { for x in 197...203 where (x - 200) * (x - 200) + (y - 150) * (y - 150) <= 9 {
            let o = (y * 400 + x) * 4; night.pixels[o] = 255; night.pixels[o + 1] = 255; night.pixels[o + 2] = 255
        } }
        var p = DustRemovalParameters()
        XCTAssertEqual(try remover.detect(in: night, parameters: p).blobs.count, 0)
        p.minContrast = 0; p.maxBrightExcess = 0
        XCTAssertEqual(try remover.detect(in: night, parameters: p).blobs.count, 1)
    }
    func testClassicSpotsLandInRetouchFrameAndCoverTheSpot() throws {
        let spots = [(x: 200, y: 100, r: 9), (x: 620, y: 380, r: 6)]
        let found = try DustFinder.classicSpots(in: sky(width: 800, height: 500, spots: spots, noise: true), options: DustFinder.Options())
        XCTAssertEqual(found.count, 2)
        for s in spots {
            let hit = try XCTUnwrap(found.first { abs($0.center.x * 800 - Double(s.x)) < 2 && abs((1 - $0.center.y) * 500 - Double(s.y)) < 2 }, "spot at \(s)")
            XCTAssertGreaterThanOrEqual(hit.radius * 500, Double(s.r), "the circle covers the spot")
            XCTAssertLessThan(hit.radius * 500, Double(s.r) * 3, "but not the dilated blob around it")
        }
    }
    func testHealSourceMatchesToneAndAvoidsOtherSpots() {
        // Dark left half, bright right half; the spot sits near the boundary with a second spot to its left.
        let w = 400, h = 300
        var plane = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { plane[y * w + x] = x < 230 ? 0.2 : 0.6 } }
        let target = DustSpot(center: MaskPoint(x: 200.0 / 400, y: 1 - 150.0 / 300), radius: 10.0 / 300)
        let neighbour = DustSpot(center: MaskPoint(x: 160.0 / 400, y: 1 - 150.0 / 300), radius: 10.0 / 300)
        let strokes = DustFinder.strokes(for: [target, neighbour], luminance: plane, width: w, height: h)
        XCTAssertEqual(strokes.count, 2)
        let stroke = strokes[0], sx = stroke.source.x * 400, sy = (1 - stroke.source.y) * 300
        XCTAssertTrue(stroke.suggested); XCTAssertEqual(stroke.mode, .heal); XCTAssertEqual(stroke.points, [target.center])
        XCTAssertLessThan(sx + 10, 230, "the source stays on the dark side")
        XCTAssertGreaterThanOrEqual(hypot(sx - 160, sy - 150), 20, "the source does not cover the other spot")
        XCTAssertNoThrow(try stroke.validate())
    }
    func testPaintedStrokeSourceClearsItsOwnPathAndRefreshMovesOn() throws {
        // Bright top band, dark below; a horizontal stroke across the dark part.
        let w = 400, h = 300
        var plane = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { plane[y * w + x] = y < 100 ? 0.7 : 0.2 } }
        let finder = try XCTUnwrap(RetouchSourceFinder(luminance: plane, width: w, height: h))
        let points = (0...10).map { MaskPoint(x: (150.0 + Double($0) * 10) / 400, y: 1 - 200.0 / 300) }
        let radius = 8.0 / 300
        let source = finder.source(for: points, radius: radius)
        let dx = (source.x - points[0].x) * 400, dy = (source.y - points[0].y) * 300
        for p in points { for q in points {
            XCTAssertGreaterThanOrEqual(hypot((p.x - q.x) * 400 + dx, (p.y - q.y) * 300 + dy), 16, "no copied point lands in the stroke")
        } }
        XCTAssertGreaterThan((1 - source.y) * 300 - 8, 100, "the source stays on the dark side")
        let next = finder.source(for: points, radius: radius, refused: [source])
        XCTAssertGreaterThanOrEqual(hypot((next.x - source.x) * 400, (next.y - source.y) * 300), 8)
    }
    func testMeterAndRenderSignedSpotExposure() throws {
        let context = try context(), engine = RetouchRenderer(context: context)
        let target = MaskPoint(x: 0.5, y: 0.5)
        for center: Float in [0.125, 0.5] {
            var plane = [Float](repeating: 0.25, count: 100 * 100)
            for y in 42..<58 { for x in 42..<58 { plane[y*100+x] = center } }
            let finder = try XCTUnwrap(RetouchSourceFinder(luminance: plane, width: 100, height: 100))
            var stroke = RetouchStroke(mode: .tone, source: target, target: target, radius: 0.1, softness: 0.8, opacity: 1)
            stroke.exposure = finder.spotExposure(at: target, radius: stroke.radius)
            XCTAssertEqual(stroke.exposure, center < 0.25 ? 1 : -1, accuracy: 0.01)
            let rgba = plane.flatMap { [$0, $0, $0, Float(1)] }
            let input = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: 1600,
                                size: CGSize(width: 100, height: 100), format: .RGBAf, colorSpace: nil)
            let result = try engine.apply([stroke], to: input)
            XCTAssertEqual(value(result, 50, 50, context), 0.25, accuracy: 0.005)
            XCTAssertEqual(value(result, 67, 50, context), 0.25, accuracy: 0.005)
            XCTAssertEqual(try JSONDecoder().decode(RetouchStroke.self, from: JSONEncoder().encode(stroke)), stroke)
        }
    }
    /// A dust spot's Dodge/Burn on a roughly drawn circle: the soft shadow, off the circle's centre, is lifted pixel by
    /// pixel to its surroundings, the texture under it kept, and the clean part of the circle left alone.
    func testDustDodgeFindsTheSpotInsideARoughCircle() throws {
        let context = try context(), engine = RetouchRenderer(context: context)
        let n = 200
        func texture(_ x: Int, _ y: Int) -> Float { 0.02 * sin(Float(x) * 1.3) * cos(Float(y) * 1.9) }
        var plane = [Float](repeating: 0, count: n * n), clean = plane
        for y in 0..<n { for x in 0..<n {
            let base = 0.3 + 0.1 * Float(x) / Float(n) + texture(x, y)
            // A shadow 0.7 stop deep at its middle, radius 14, at (110, 92) in a circle of radius 30 around (100, 100).
            let d = hypot(Float(x - 110), Float(y - 92)) / 14
            plane[y * n + x] = base * (d < 1 ? 1 - (1 - exp2(-0.7)) * (1 - d * d) : 1)
            clean[y * n + x] = base
        } }
        let finder = try XCTUnwrap(RetouchSourceFinder(luminance: plane, width: n, height: n))
        let center = MaskPoint(x: 0.5, y: 0.5)
        var stroke = RetouchStroke(mode: .tone, source: center, target: center, radius: 0.15, softness: 0.9, opacity: 1)
        stroke.suggested = true
        stroke.exposure = finder.spotDepth(at: center, radius: stroke.radius)
        XCTAssertGreaterThan(stroke.exposure, 0.4)
        let rgba = plane.flatMap { [$0, $0, $0, Float(1)] }
        // Row 0 of the plane is the image's top, where Core Image's y is highest.
        let input = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: n * 16, size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
        let result = try engine.apply([stroke], to: input)
        func at(_ x: Int, _ y: Int) -> Double { value(result, Double(x), Double(n - 1 - y), context) }
        // The spot's middle and its flank come back to the clean photo, texture included.
        for (x, y) in [(110, 92), (104, 95), (116, 88), (111, 93)] { XCTAssertEqual(at(x, y), Double(clean[y * n + x]), accuracy: 0.012, "(\(x), \(y))") }
        // The clean side of the circle is not brightened, as a uniform exposure would.
        for (x, y) in [(84, 110), (90, 118), (80, 100)] { XCTAssertEqual(at(x, y), Double(clean[y * n + x]), accuracy: 0.006, "(\(x), \(y))") }
        var uniform = stroke; uniform.suggested = false
        let flat = try engine.apply([uniform], to: input)
        XCTAssertGreaterThan(value(flat, 84, Double(n - 1 - 110), context), Double(clean[110 * n + 84]) + 0.03)
    }
    func testRemoveBlendsLikeHeal() throws {
        let context = try context(), engine = RetouchRenderer(context: context)
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var stroke = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.2, y: 0.5), target: MaskPoint(x: 0.6, y: 0.5), radius: 0.1, softness: 0.3, opacity: 1)
        let healed = try engine.apply([stroke], to: image)
        stroke.mode = .remove
        XCTAssertEqual(value(try engine.apply([stroke], to: image), 60, 50, context), value(healed, 60, 50, context), accuracy: 1e-4)
    }
    func testHealRemovesTheSpotsOwnTone() throws {
        let context = try context(), engine = RetouchRenderer(context: context), size = 200
        var pixels = [Float](repeating: 0, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let d = hypot(Double(x - 100), Double(y - 100)) / 10, v = 0.5 * (1 - 0.3 * max(0, 1 - d * d)), o = (y * size + x) * 4
            pixels[o] = Float(v); pixels[o + 1] = Float(v); pixels[o + 2] = Float(v); pixels[o + 3] = 1
        } }
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: size * 16, size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
        XCTAssertEqual(value(image, 100, 100, context), 0.35, accuracy: 0.01)
        var stroke = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.25, y: 0.5), target: MaskPoint(x: 0.5, y: 0.5), radius: 16.0 / 200, softness: 0.4, opacity: 1)
        let healed = try engine.apply([stroke], to: image)
        XCTAssertEqual(healed.extent, image.extent)
        XCTAssertEqual(value(healed, 100, 100, context), 0.5, accuracy: 0.01, "the dark disc is gone, not just softened")
        XCTAssertEqual(value(healed, 100, 160, context), 0.5, accuracy: 0.001, "nothing outside the stroke changes")
        stroke.opacity = 0.5
        XCTAssertEqual(value(try engine.apply([stroke], to: image), 100, 100, context), 0.425, accuracy: 0.015)
    }
    func testRendererFindsAndHealsSpotsInTheRetouchFrame() async throws {
        _ = try context()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A spot near the top: row 0 of the scanned image must be the top of the photo.
        let photo = sky(width: 1200, height: 800, spots: [(300, 150, 9)], noise: true)
        let url = dir.appendingPathComponent("dusty.png")
        let provider = try XCTUnwrap(CGDataProvider(data: Data(photo.pixels) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 1200, height: 800, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4800, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let renderer = try RawRenderer(sourceURL: url)
        var edits = renderer.info.defaults
        edits.geometry.straighten = 5; edits.quarterTurns = 1
        let spots = try await renderer.findDust(edits, options: DustFinder.Options())
        XCTAssertEqual(spots.count, 1)
        let spot = try XCTUnwrap(spots.first)
        XCTAssertEqual(spot.center.x, 300.0 / 1200, accuracy: 0.003); XCTAssertEqual(spot.center.y, 1 - 150.0 / 800, accuracy: 0.003)
        let strokes = try await renderer.dustStrokes(spots, settings: edits)
        edits.retouch = strokes
        XCTAssertNoThrow(try edits.validated())
        let again = try await renderer.findDust(edits, options: DustFinder.Options())
        XCTAssertTrue(again.isEmpty, "a healed spot is not found again")
    }
    /// The map engine finds faint soft spots from small to far beyond the classic detector's sizes, and nothing in
    /// texture or along a dark subject's edge.
    func testMapSpotsFindSmallAndLargeSoftSpotsButNotTexture() throws {
        let w = 1600, h = 1000
        let spots: [(x: Double, y: Double, r: Double, dark: Double)] = [(300, 200, 6, 0.12), (800, 250, 14, 0.06), (1250, 300, 30, 0.05), (500, 600, 22, 0.04)]
        var image = RGBAImage(width: w, height: h)
        var seed: UInt32 = 11
        for y in 0..<h { for x in 0..<w {
            seed = seed &* 1664525 &+ 1013904223
            var v = 150 + 50 * Double(y) / Double(h) + Double(seed >> 30)   // a graded sky with a little noise
            for s in spots {
                let d = hypot(Double(x) - s.x, Double(y) - s.y) / s.r
                if d < 1 { v *= 1 - s.dark * (1 - d * d) }
            }
            if x >= 1300 && y >= 700 { v = (x / 6 + y / 6) % 2 == 0 ? 70 : 200 }   // fine texture
            if x < 200 && y >= 800 { v = 30 }                                       // a dark subject
            let o = (y * w + x) * 4
            image.pixels[o] = UInt8(v); image.pixels[o + 1] = UInt8(v); image.pixels[o + 2] = UInt8(min(255, v + 20)); image.pixels[o + 3] = 255
        } }
        let found = DustFinder.mapSpots(in: image, options: DustFinder.Options(), context: try context())
        for s in spots {
            let hit = found.first { hypot($0.center.x * Double(w) - s.x, (1 - $0.center.y) * Double(h) - s.y) < max(3, s.r / 3) }
            XCTAssertNotNil(hit, "spot at \(s)")
            if let hit { XCTAssertGreaterThanOrEqual(hit.radius * Double(h), s.r * 0.8, "the circle covers the spot at \(s)") }
        }
        XCTAssertEqual(found.count, spots.count, "\(found.map { ($0.center.x * Double(w), (1 - $0.center.y) * Double(h)) })")
    }
    /// Visualize lights a soft spot a few percent darker than the sky, and leaves the sky beside a bright block dark,
    /// where a blurred background would glow.
    func testVisualizeShowsSoftSpotsWithoutHalos() throws {
        let w = 400, h = 300
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            var v = 120.0
            if x >= 300 && y >= 150 { v = 250 }
            let d = hypot(Double(x - 100), Double(y - 100))
            if d < 12 { v *= 1 - 0.04 * (1 - d / 12) }   // a soft, 4 % spot of radius 12
            pixels[i] = UInt8(v); pixels[i + 1] = UInt8(v); pixels[i + 2] = UInt8(v)
        } }
        let image = try XCTUnwrap(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let context = CIContext()
        // Sizes on a 4000-pixel frame: this 400-pixel image is a tenth of it, so a 12-pixel spot is 120 there.
        let map = try XCTUnwrap(DustVisualizer.render(image, photoSize: Double(w), options: .init(strength: 0.5, size: 200, smoothing: 5), context: context))
        let data = try XCTUnwrap(map.dataProvider?.data as Data?)
        func gray(_ x: Int, _ y: Int) -> UInt8 { data[y * map.bytesPerRow + x * 4] }
        XCTAssertGreaterThan(gray(100, 100), 100, "the spot shows")
        XCTAssertLessThan(gray(290, 200), 20, "the sky beside the bright block stays dark")
        XCTAssertLessThan(gray(200, 50), 20, "clean sky stays dark")
    }
}
