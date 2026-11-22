import XCTest
import CevicheTestSupport
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

final class RetouchFillTests: XCTestCase {
    private let width = 256, height = 192
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    }
    /// A tinted gradient with fine texture and a dark blot at the middle, linear, scaled per channel by `gains` the way a
    /// white balance or exposure change scales the image retouching sees.
    private func photo(gains: [Float] = [1, 1, 1]) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = 0.2 + 0.3 * Float(x) / Float(width) + 0.1 * Float(y) / Float(height)
                let texture = 0.03 * sin(Float(x) * 1.7) * cos(Float(y) * 2.3)
                let blot: Float = hypot(Float(x) - 128, Float(y) - 96) < 12 ? -0.15 : 0
                for (c, tint) in [Float(1), 0.9, 0.8].enumerated() { pixels[(y * width + x) * 4 + c] = (base * tint + texture + blot) * gains[c] }
            }
        }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }
    private func pixels(_ image: CIImage, _ context: CIContext) -> [Float] {
        let extent = image.extent
        var values = [Float](repeating: 0, count: Int(extent.width * extent.height) * 4)
        values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: nil) }
        return values
    }
    /// A Remove dab over the blot, with an AI fill of constant `ratio` stored at `resolution` of the render's pixels.
    private func stroke(ratio: Float?, resolution: Double = 1) -> RetouchStroke {
        var stroke = RetouchStroke(mode: .remove, source: MaskPoint(x: 0.25, y: 0.5), target: MaskPoint(x: 0.5, y: 0.5), radius: 0.1, softness: 0.3, opacity: 1)
        guard let ratio else { return stroke }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let bounds = RetouchRenderer.bounds(of: stroke, in: extent).insetBy(dx: -2, dy: -2)
        let w = Int(bounds.width * resolution), h = Int(bounds.height * resolution)
        stroke.fill = RetouchFill(x: bounds.minX / extent.width, y: bounds.minY / extent.height, width: bounds.width / extent.width, height: bounds.height / extent.height,
                                  reach: 0.1, footprint: RetouchFill.footprint(of: stroke),
                                  raster: try! RetouchFillRaster.encode([Float](repeating: ratio, count: w * h * 3), width: w, height: h))
        return stroke
    }
    private func distance(_ i: Int) -> Double { hypot(Double(i % width) - 128, Double(i / width) - 96) }
    /// The largest difference from `expected` over the pixels `where` keeps, reported once.
    private func worst(_ indices: [Int], _ value: (Int, Int) -> Float, _ expected: (Int, Int) -> Float) -> (error: Float, pixel: Int) {
        var worst: (error: Float, pixel: Int) = (0, -1)
        for i in indices { for c in 0..<3 { let e = abs(value(i, c) - expected(i, c)); if !(e <= worst.error) { worst = (e, i) } } }
        return worst
    }

    func testFillChangesOnlyTheFootprintAndRemovesTheBlot() throws {
        let context = try context(), input = photo()
        let original = pixels(input, context)
        let output = pixels(try RetouchRenderer(context: context).apply([stroke(ratio: 1)], to: input), context)
        let radius = 0.1 * Double(height)
        let outside = worst((0..<(width * height)).filter { distance($0) > radius + 1 }, { output[$0 * 4 + $1] }, { original[$0 * 4 + $1] })
        XCTAssertLessThanOrEqual(outside.error, 1e-6, "pixel \(outside.pixel)")
        // With a ratio of 1 the hole takes the tone of its surroundings: the blot (0.15 darker) is gone.
        let center = (96 * width + 128) * 4
        XCTAssertEqual(output[center], 0.2 + 0.15 + 0.05, accuracy: 0.03)
        XCTAssertGreaterThan(output[center], original[center] + 0.1)
    }

    /// A merge burns each photo's AI fills into it, not a patch in their place.
    func testMergesBurnInTheFillNotAPatch() throws {
        let context = try context(), input = photo()
        let extent = input.extent
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { context.render(input, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: PanoramaDecoder.space) }
        let frame = PanoramaFrame(width: width, height: height, pixels: values)
        let filled = PanoramaDecoder.retouched(frame, [stroke(ratio: 1.3)]).pixels
        let patched = PanoramaDecoder.retouched(frame, [stroke(ratio: nil)]).pixels
        let center = (96 * width + 128) * 4
        // The fill is 1.3 times the surroundings; a patch takes the source's tone.
        XCTAssertGreaterThan(filled[center], patched[center] + 0.05)
        XCTAssertEqual(PanoramaDecoder.retouched(frame, []).pixels, values)
    }

    func testFillCoversTheBrushsSoftEdge() throws {
        // 17 pixels from the middle of a 19.2-pixel brush with a 30 % soft edge, where a patch shows at about 38 %.
        let context = try context(), input = photo(), i = (96 * width + 128 + 17) * 4
        let original = pixels(input, context), filled = pixels(try RetouchRenderer(context: context).apply([stroke(ratio: 2)], to: input), context)
        // Twice its surroundings, in full.
        XCTAssertGreaterThan(filled[i + 1], 1.8 * original[i + 1])
        let patched = pixels(try RetouchRenderer(context: context).apply([stroke(ratio: nil)], to: input), context)
        XCTAssertLessThan(abs(patched[i + 1] - original[i + 1]), 0.5 * original[i + 1])
    }

    func testExposureAndWhiteBalanceRelightTheStoredFill() throws {
        let context = try context(), gains: [Float] = [1.6, 1, 0.7]
        // At half resolution the fill also takes the source's grain finer than it, which scales the same way.
        for resolution in [1.0, 0.5] {
            let renderer = RetouchRenderer(context: context), strokes = [stroke(ratio: 0.8, resolution: resolution)]
            let plain = pixels(try renderer.apply(strokes, to: photo()), context)
            let lit = pixels(try renderer.apply(strokes, to: photo(gains: gains)), context)
            let error = worst((0..<(width * height)).filter { distance($0) < 18 }, { lit[$0 * 4 + $1] / max(plain[$0 * 4 + $1], 0.01) }, { _, c in gains[c] })
            // Within the GPU blur's precision.
            XCTAssertLessThan(error.error, 5e-3, "\(resolution) pixel \(error.pixel)")
        }
    }

    func testRasterRowsRunTopDown() throws {
        let context = try context()
        var bright = stroke(ratio: 1)
        let fill = try XCTUnwrap(bright.fill), size = try RetouchFillRaster.decode(fill.raster)
        // The first rows (the top) are twice as bright as their surroundings, the rest half as bright.
        let plane = (0..<(size.width * size.height)).map { $0 / size.width < size.height / 2 ? Float(2) : 0.5 }
        bright.fill?.raster = try RetouchFillRaster.encode(plane + plane + plane, width: size.width, height: size.height)
        let output = pixels(try RetouchRenderer(context: context).apply([bright], to: photo()), context)
        // Bitmap rows run top down too: row 88 is above the middle.
        XCTAssertGreaterThan(output[(88 * width + 128) * 4], 0.6); XCTAssertLessThan(output[(104 * width + 128) * 4], 0.3)
    }

    func testFillMadeForAnotherFootprintFallsBackToPatchRemove() throws {
        let context = try context(), renderer = RetouchRenderer(context: context)
        var moved = stroke(ratio: 0.5); moved.points = [MaskPoint(x: 0.52, y: 0.5)]
        var plain = moved; plain.fill = nil
        XCTAssertEqual(pixels(try renderer.apply([moved], to: photo()), context), pixels(try renderer.apply([plain], to: photo()), context))
        var resized = stroke(ratio: 0.5); resized.radius = 0.12
        var patch = resized; patch.fill = nil
        XCTAssertEqual(pixels(try renderer.apply([resized], to: photo()), context), pixels(try renderer.apply([patch], to: photo()), context))
        XCTAssertNotEqual(pixels(try renderer.apply([stroke(ratio: 0.5)], to: photo()), context), pixels(try renderer.apply([stroke(ratio: nil)], to: photo()), context))
    }

    func testPreviewSizeMatchesFullSize() throws {
        let context = try context(), strokes = [stroke(ratio: 0.9)]
        let full = try RetouchRenderer(context: context).apply(strokes, to: photo())
        let small = photo().transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5), highQualityDownsample: true)
        let preview = pixels(try RetouchRenderer(context: context).apply(strokes, to: small), context)
        let reduced = pixels(full.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5), highQualityDownsample: true).cropped(to: small.extent), context)
        let half = width / 2
        let error = worst((0..<(half * height / 2)).filter { hypot(Double($0 % half) - 64, Double($0 / half) - 48) < 7 }, { preview[$0 * 4 + $1] }, { reduced[$0 * 4 + $1] })
        XCTAssertLessThan(error.error, 0.01, "pixel \(error.pixel)")
    }

    func testRasterKeepsHalfFloatPrecision() throws {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<(37 * 21 * 3)).map { _ in Float.random(in: 0...4, using: &generator) }
        let data = try RetouchFillRaster.encode(values, width: 37, height: 21)
        let decoded = try RetouchFillRaster.decode(data)
        XCTAssertEqual(decoded.width, 37); XCTAssertEqual(decoded.height, 21)
        for (a, b) in zip(values, decoded.planes) { XCTAssertEqual(a, b, accuracy: a / 1000) }
        XCTAssertFalse(RetouchFillRaster.isValid(Data("RFL1junk".utf8)))
        XCTAssertThrowsError(try RetouchFillRaster.encode([1, 2], width: 1, height: 1))
    }

    func testRasterTilesRoundTripAndLeaveTheRestNeutral() throws {
        let tiles = [RetouchFillRaster.Tile(x: 0, y: 0, width: 3, height: 2, planes: (0..<18).map { Float($0) / 4 }),
                     RetouchFillRaster.Tile(x: 5, y: 4, width: 2, height: 3, planes: [Float](repeating: 2, count: 18))]
        let data = try RetouchFillRaster.encode(tiles: tiles, width: 8, height: 7)
        let decoded = try RetouchFillRaster.tiles(data)
        XCTAssertEqual(decoded.width, 8); XCTAssertEqual(decoded.height, 7); XCTAssertEqual(decoded.tiles, tiles)
        // Tile rows run top down: the first tile is at the top left, the second at the bottom right; elsewhere clear.
        let context = try context(), image = try RetouchFillRaster.image(data)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 8, height: 7))
        var pixels = [Float](repeating: -1, count: 8 * 7 * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 8 * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
        XCTAssertEqual(pixels[(1 * 8 + 2) * 4], 5.0 / 4); XCTAssertEqual(pixels[(6 * 8 + 6) * 4 + 1], 2); XCTAssertEqual(pixels[(3 * 8 + 3) * 4 + 3], 0)
        // A one-rectangle raster reads as one tile covering its grid.
        let single = try RetouchFillRaster.tiles(RetouchFillRaster.encode([Float](repeating: 1, count: 12), width: 2, height: 2))
        XCTAssertEqual(single.tiles.count, 1); XCTAssertEqual(single.tiles[0].width, 2)
        XCTAssertThrowsError(try RetouchFillRaster.encode(tiles: [RetouchFillRaster.Tile(x: 7, y: 0, width: 2, height: 1, planes: [Float](repeating: 1, count: 6))], width: 8, height: 7))
        XCTAssertFalse(RetouchFillRaster.isValid(data.prefix(20)))
    }

    func testThicknessIsTheDistanceToTheNearestKnownPixel() {
        func grid(_ width: Int, _ height: Int, _ inside: (Int, Int) -> Bool) -> [Float] { (0..<(width * height)).map { inside($0 % width, $0 / width) ? 1 : 0 } }
        let disc = grid(200, 200) { hypot(Double($0) - 100, Double($1) - 100) < 40 }
        XCTAssertEqual(InpaintPlan.thickness(disc, width: 200, height: 200, open: (false, false, false, false)), 40, accuracy: 3)
        // A line 12 pixels wide is 6 thick however long it is.
        let line = grid(2000, 40) { _, y in (14..<26).contains(y) }
        XCTAssertEqual(InpaintPlan.thickness(line, width: 2000, height: 40, open: (false, false, false, false)), 6, accuracy: 1)
        // A stroke along the frame's edge is twice as thick: nothing beyond the edge is known.
        let edge = grid(100, 20) { _, y in y < 6 }
        XCTAssertEqual(InpaintPlan.thickness(edge, width: 100, height: 20, open: (false, false, false, true)), 6, accuracy: 1)
        XCTAssertEqual(InpaintPlan.thickness(edge, width: 100, height: 20, open: (false, false, false, false)), 3, accuracy: 1)
    }

    func testPlansKeepTheHoleThinEnoughForTheNetwork() throws {
        let frame = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        // A dust-sized dab is filled at full resolution in one window with 512 pixels of context.
        let dab = try XCTUnwrap(InpaintPlan.plan(footprint: CGRect(x: 1000, y: 1000, width: 40, height: 40), thickness: 20, frame: frame))
        XCTAssertEqual(dab.scale, 1); XCTAssertEqual(dab.cells.count, 1)
        XCTAssertEqual(dab.window(dab.cells[0]), CGRect(x: 764, y: 764, width: 512, height: 512))
        // A wire across most of the frame stays at full resolution, in cells along it.
        let wire = CGRect(x: 1300, y: 3000, width: 4000, height: 1000)
        let long = try XCTUnwrap(InpaintPlan.plan(footprint: wire, thickness: 11, frame: frame))
        XCTAssertEqual(long.scale, 1); XCTAssertGreaterThan(long.cells.count, 20)
        // A thick hole is scaled until it is 160 network pixels across.
        let thick = try XCTUnwrap(InpaintPlan.plan(footprint: CGRect(x: 2000, y: 1500, width: 800, height: 400), thickness: 200, frame: frame))
        XCTAssertEqual(thick.scale, 0.4, accuracy: 1e-12); XCTAssertEqual(2 * 200 * thick.scale, InpaintPlan.maxHole, accuracy: 1e-9)
        // A frame narrower than the window gets a window of its shorter side, scaled up to the network.
        let narrow = try XCTUnwrap(InpaintPlan.plan(footprint: CGRect(x: 100, y: 100, width: 30, height: 30), thickness: 15, frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        XCTAssertGreaterThan(narrow.scale, 1); XCTAssertEqual(narrow.height, InpaintPlan.side)
        XCTAssertNil(InpaintPlan.plan(footprint: CGRect(x: 0, y: 0, width: 5000, height: 3000), thickness: 1500, frame: frame))
        for plan in [dab, long, thick, narrow] {
            let scaled = CGRect(x: 0, y: 0, width: plan.width, height: plan.height)
            for (i, cell) in plan.cells.enumerated() {
                // Whole pixels; each window holds its cell with context on every side the frame allows, inside the frame.
                XCTAssertEqual(cell, cell.integral); let window = plan.window(cell)
                XCTAssertTrue(window.contains(cell)); XCTAssertTrue(scaled.contains(window)); XCTAssertEqual(window.width, Double(InpaintPlan.side))
                for other in plan.cells[(i + 1)...] { XCTAssertTrue(cell.intersection(other).isEmpty, "Cells do not overlap") }
            }
            // Rows top down, each left to right.
            XCTAssertEqual(plan.cells, plan.cells.sorted { $0.minY != $1.minY ? $0.minY > $1.minY : $0.minX < $1.minX })
        }
        // The cells cover the stroke.
        let covered = long.cells.reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(covered.contains(wire.insetBy(dx: 1, dy: 1)))
    }

    func testRefreshVariantsMoveTheCellsAndKeepTheHoleThin() throws {
        let frame = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        for (footprint, thickness) in [(CGRect(x: 1000, y: 1000, width: 40, height: 40), 20.0), (CGRect(x: 2000, y: 1500, width: 800, height: 400), 200), (CGRect(x: 0, y: 3980, width: 20, height: 20), 20)] {
            let plans = try (0..<6).map { try XCTUnwrap(InpaintPlan.plan(footprint: footprint, thickness: thickness, frame: frame, variant: $0)) }
            XCTAssertEqual(plans[0], InpaintPlan.plan(footprint: footprint, thickness: thickness, frame: frame))
            for plan in plans {
                XCTAssertLessThanOrEqual(2 * thickness * plan.scale, InpaintPlan.maxHole * 1.2 + 1e-9)
                let area = CGRect(x: footprint.minX * plan.scale, y: footprint.minY * plan.scale, width: footprint.width * plan.scale, height: footprint.height * plan.scale)
                XCTAssertTrue(plan.cells.reduce(CGRect.null) { $0.union($1) }.contains(area.insetBy(dx: 1, dy: 1)))
            }
            // Away from the frame's edges every refresh in a cycle sees other windows.
            if footprint.minX > 0 { XCTAssertEqual(Set(plans.prefix(5).map { "\($0.scale) \($0.cells.map { $0.origin })" }).count, 5) }
        }
    }

    func testStrokesAskForFillsByFootprint() throws {
        var drawn = self.stroke(ratio: 0.75)
        XCTAssertFalse(drawn.needsFill, "Not generative")
        drawn.generative = true
        XCTAssertFalse(drawn.needsFill)
        drawn.points.append(MaskPoint(x: 0.52, y: 0.5))
        XCTAssertTrue(drawn.needsFill, "Moved or extended since the fill was made")
        drawn.enabled = false; XCTAssertFalse(drawn.needsFill)
        drawn.enabled = true; drawn.mode = .heal; XCTAssertFalse(drawn.needsFill)
        drawn.mode = .remove; drawn.fill = nil; XCTAssertTrue(drawn.needsFill)
        // Encoded only when set, so older documents and strokes without it read the same.
        let plain = try JSONEncoder().encode(self.stroke(ratio: nil))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("generative"))
        XCTAssertEqual(try JSONDecoder().decode(RetouchStroke.self, from: JSONEncoder().encode(drawn)), drawn)
    }

    private func filled() -> Adjustments {
        var settings = Adjustments(); settings.exposure = 0.5
        settings.retouch = [stroke(ratio: 0.75), stroke(ratio: nil)]
        settings.retouch[0].generative = true
        return settings
    }

    func testFillsAreBlobsInTheCatalog() async throws {
        let settings = filled()
        var blobs: [String: Data] = [:]
        let stored = try RevisionPayload.encode(settings, blob: { data in let id = UUID().uuidString; blobs[id] = data; return id }, resource: { _ in throw EditorError.render })
        XCTAssertEqual(blobs.count, 1); XCTAssertLessThan(stored.count, 5_000, "The ratio is not inline")
        XCTAssertEqual(try RevisionPayload.decode(stored, blob: { blobs[$0]! }, resource: { _ in throw EditorError.render }), settings)

        let (directory, url) = try CatalogTests().fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Library")
        let asset: CatalogAsset
        do {
            let store = try CatalogStore(root: root)
            let prepared = try CatalogImporter.prepare(url)
            asset = try await store.insert(prepared.0, thumbnail: prepared.1)
            try await store.saveEdits(settings, assetID: asset.id, baseline: Adjustments())
        }
        let reopened = try CatalogStore(root: root)
        let saved = try await reopened.savedAdjustments(of: try await reopened.asset(asset.id))
        XCTAssertEqual(saved, settings)
    }

    func testFillsStayOutOfXMPAndOtherPhotos() throws {
        let settings = filled()
        let restored = try XMPCodec.apply(XMPPacket(data: XMPCodec.encode(adjustments: settings)), to: Adjustments()).adjustments
        XCTAssertEqual(restored, settings.removingRetouchFills)
        XCTAssertTrue(restored.retouch.allSatisfy { $0.fill == nil }); XCTAssertEqual(restored.retouch.count, 2)
        XCTAssertTrue(restored.retouch[0].needsFill)
        for items: Set<EditTransferItem> in [[.brushStrokes], [.brushStrokes, .dustSpots]] {
            let pasted = try EditTransfer(sourceName: "photo.jpg", adjustments: settings, items: items).applying(to: Adjustments())
            XCTAssertEqual(pasted.retouch.map(\.id), settings.retouch.map(\.id)); XCTAssertTrue(pasted.retouch.allSatisfy { $0.fill == nil })
            // The stroke still asks for a fill, so the editor makes one from the photo it lands on.
            XCTAssertEqual(pasted.retouch.map(\.generative), [true, false]); XCTAssertTrue(pasted.retouch[0].needsFill)
        }
        var damaged = settings; damaged.retouch[0].fill?.raster = Data("RFL1".utf8)
        XCTAssertThrowsError(try damaged.validated())
    }
}

/// Runs when the compiled models are available (CEVICHE_MODELS=…/models/build/compiled); skipped otherwise.
final class InpaintingModelTests: XCTestCase {
    /// A 1200 × 800 PNG of stripes on a gradient, with a dark disc of radius 40 at (600, 400) to remove, or with `line`'s
    /// dark line across it instead (rows top down), or with neither.
    private func photo(disc: Bool = true, line: ((Double, Double), (Double, Double))? = nil) throws -> URL {
        let width = 1200, height = 800
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let stripe = 0.5 + 0.5 * sin(Double(x) / 9), ramp = Double(y) / Double(height)
                var value = 0.35 + 0.25 * stripe * (0.6 + 0.4 * ramp)
                if disc, hypot(Double(x) - 600, Double(y) - 400) < 40 { value = 0.05 }
                if let line, Self.distance(Double(x), Double(y), line) < 2 { value = 0.05 }
                let p = pixels + (y * width + x) * 4
                p[0] = UInt8(value * 255); p[1] = UInt8(value * 0.9 * 255); p[2] = UInt8(value * 0.8 * 255); p[3] = 255
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testFillRemovesTheDiscAndLeavesTheRestAlone() async throws {
        guard BundledModel.inpaint.isAvailable else { throw XCTSkip("Inpainting model not installed") }
        let url = try photo(); defer { try? FileManager.default.removeItem(at: url) }
        let renderer = try RawRenderer(sourceURL: url)
        var settings = renderer.info.defaults
        var stroke = RetouchStroke(mode: .remove, source: MaskPoint(x: 0.5, y: 0.5), target: MaskPoint(x: 0.5, y: 0.5), radius: 0.06, softness: 0.2, opacity: 1)
        settings.retouch = [stroke]
        stroke.source = try await renderer.retouchSource(for: stroke, settings: settings)
        settings.retouch = [stroke]
        let job = try await renderer.prepareInpaint(stroke.id, settings: settings)
        let fill = try await job.run(on: renderer)
        settings.retouch[0].fill = fill

        // Float throughout, as the renderer's own context: a half-float intermediate would round every pixel.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
        func pixels(_ settings: Adjustments) async throws -> [Float] {
            let image = try await renderer.pipeline(settings, maxDimension: nil)
            var values = [Float](repeating: 0, count: 1200 * 800 * 4)
            values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 1200 * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
            return values
        }
        var untouched = settings; untouched.retouch = []
        var patched = settings; patched.retouch[0].fill = nil
        let before = try await pixels(untouched), after = try await pixels(settings), patch = try await pixels(patched)
        XCTAssertNotEqual(after, patch, "The fill is used")
        let radius = 0.06 * 800
        var inside: [Float] = [], ring: [Float] = [], changed = 0
        for i in 0..<(1200 * 800) {
            let d = hypot(Double(i % 1200) - 600, Double(i / 1200) - 400)
            if d > radius + 1, abs(after[i * 4 + 1] - before[i * 4 + 1]) > 1e-6 { changed += 1 }
            if d < 40 { inside.append(after[i * 4 + 1]) } else if d > radius + 4 && d < radius + 30 { ring.append(after[i * 4 + 1]) }
        }
        XCTAssertEqual(changed, 0, "Pixels outside the stroke changed")
        let mean = { (values: [Float]) in values.reduce(0, +) / Float(values.count) }
        XCTAssertEqual(mean(inside), mean(ring), accuracy: 0.04, "The disc takes its surroundings' tone")
        XCTAssertGreaterThan(inside.min()!, 0.03, "No trace of the disc (0.004 linear) is left")
    }

    static func distance(_ x: Double, _ y: Double, _ line: ((Double, Double), (Double, Double))) -> Double {
        let (a, b) = line, dx = b.0 - a.0, dy = b.1 - a.1
        let t = max(0, min(1, ((x - a.0) * dx + (y - a.1) * dy) / (dx * dx + dy * dy)))
        return hypot(x - a.0 - t * dx, y - a.1 - t * dy)
    }

    /// A line across most of the photo is filled at full resolution, in windows along it, and the network does not draw it
    /// back in: each window treats all of the stroke inside it as missing.
    func testALongLineIsFilledAtFullResolutionAndStaysGone() async throws {
        try TestTier.requireSlow()
        guard BundledModel.inpaint.isAvailable else { throw XCTSkip("Inpainting model not installed") }
        let line = ((60.0, 740.0), (1140.0, 60.0))
        let url = try photo(disc: false, line: line), clean = try photo(disc: false)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: clean) }
        let renderer = try RawRenderer(sourceURL: url), reference = try RawRenderer(sourceURL: clean)
        var settings = renderer.info.defaults
        let points = stride(from: 0.0, through: 1, by: 0.01).map { t in
            MaskPoint(x: (line.0.0 + t * (line.1.0 - line.0.0)) / 1200, y: 1 - (line.0.1 + t * (line.1.1 - line.0.1)) / 800)
        }
        var stroke = RetouchStroke(mode: .remove, source: points[0], target: points[0], radius: 0.012, softness: 0.2, opacity: 1)
        stroke.points = points; stroke.generative = true
        settings.retouch = [stroke]
        stroke.source = try await renderer.retouchSource(for: stroke, settings: settings)
        settings.retouch = [stroke]
        let job = try await renderer.prepareInpaint(stroke.id, settings: settings)
        XCTAssertEqual(job.plan.scale, 1, "Thin, so full resolution however long"); XCTAssertGreaterThan(job.windows, 2)
        let fill = try await job.run(on: renderer)
        settings.retouch[0].fill = fill

        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
        func pixels(_ renderer: RawRenderer, _ settings: Adjustments) async throws -> [Float] {
            let image = try await renderer.pipeline(settings, maxDimension: nil)
            var values = [Float](repeating: 0, count: 1200 * 800 * 4)
            values.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 1200 * 16, bounds: image.extent, format: .RGBAf, colorSpace: nil) }
            return values
        }
        var untouched = settings; untouched.retouch = []
        let before = try await pixels(renderer, untouched), after = try await pixels(renderer, settings), truth = try await pixels(reference, untouched)
        let radius = 0.012 * 800
        var changed = 0, errors: [Float] = [], darkest: Float = 1
        for i in 0..<(1200 * 800) {
            let d = Self.distance(Double(i % 1200), Double(i / 1200), line)
            if d > radius + 1, abs(after[i * 4 + 1] - before[i * 4 + 1]) > 1e-6 { changed += 1 }
            if d < 2 { errors.append(abs(after[i * 4 + 1] - truth[i * 4 + 1])); darkest = min(darkest, after[i * 4 + 1]) }
        }
        XCTAssertEqual(changed, 0, "Pixels outside the stroke changed")
        let mean = errors.reduce(0, +) / Float(errors.count)
        XCTAssertGreaterThan(darkest, 0.03, "No trace of the line (0.004 linear) is left")
        XCTAssertLessThan(mean, 0.02, "The stripes run on under the line")
    }
}