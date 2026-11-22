import XCTest
import CevicheTestSupport
import CoreImage
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import CevicheCore

/// No real focus brackets are on hand, so these tests synthesize them: a textured scene with a known depth map (a near
/// disc, a mid-distance block and a far background) is blurred per focus plane by each pixel's depth, then framed with a
/// known breathing magnification and shift per photo, as a lens refocusing on a tripod would.
final class FocusStackTests: XCTestCase {
    static let width = 720, height = 480, margin = 48
    /// Layer per depth: 0 near, 1 mid, 2 far.
    static let layers = 3
    /// Blur (Gaussian σ in pixels) of each layer in each photo, focused near to far.
    static let blur: [[Float]] = [[0, 2.5, 4.5], [1.2, 1.2, 3.2], [2.5, 0, 2.0], [4.5, 2.0, 0]]
    /// Each photo's magnification onto the reference (the third photo, the middle of four), shift and roll.
    static let magnification = [0.982, 0.991, 1.0, 1.012]
    static let shifts = [SIMD2(1.5, -2.0), SIMD2(-0.7, 0.4), SIMD2(0, 0), SIMD2(2.2, 1.3)]
    static let roll = [0, 0, 0, 0.05]
    /// Read noise per photo; the far-focused photo is much noisier, so a noise-blind measure would pick it for detail
    /// that is really blurred.
    static let noise: [Float] = [0.003, 0.003, 0.003, 0.012]

    /// Each photo's pixels onto the reference's: T(p) = c + m R (p − c) + t.
    static func truth(_ k: Int) -> HDRSimilarity {
        let angle = roll[k] * .pi / 180, m = magnification[k]
        let linear = simd_double2x2(columns: (SIMD2(cos(angle), sin(angle)), SIMD2(-sin(angle), cos(angle)))) * m
        let centre = SIMD2(Double(width), Double(height)) / 2
        return HDRSimilarity(linear: linear, translation: centre - linear * centre + shifts[k])
    }

    /// The depth layer at a point in reference coordinates.
    static func layer(_ x: Double, _ y: Double) -> Int {
        if hypot(x - 200, y - 250) < 115 { return 0 }
        if (410...650).contains(x), (70...400).contains(y) { return 1 }
        return 2
    }

    /// Smooth value noise with lattice spacing `scale`.
    static func valueNoise(_ x: Double, _ y: Double, scale: Double, seed: UInt64) -> Double {
        func hash(_ i: Int, _ j: Int) -> Double {
            var h = UInt64(bitPattern: Int64(i)) &* 0x9E3779B97F4A7C15 ^ UInt64(bitPattern: Int64(j)) &* 0xC2B2AE3D27D4EB4F ^ seed &* 0x165667B19E3779F9
            h ^= h >> 29; h = h &* 0xBF58476D1CE4E5B9; h ^= h >> 32
            return Double(h % 10_000) / 10_000
        }
        let u = x / scale, v = y / scale, i = Int(floor(u)), j = Int(floor(v))
        let fx = u - floor(u), fy = v - floor(v)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let top = hash(i, j) * (1 - sx) + hash(i + 1, j) * sx, bottom = hash(i, j + 1) * (1 - sx) + hash(i + 1, j + 1) * sx
        return top * (1 - sy) + bottom * sy - 0.5
    }

    /// The sharp scene at a reference point: per-layer texture at several scales, with its own tint and brightness.
    static func scene(_ x: Double, _ y: Double) -> SIMD3<Float> {
        let l = layer(x, y)
        let base = [0.32, 0.18, 0.45][l], tint = [SIMD3<Double>(1, 0.85, 0.7), SIMD3(0.75, 1, 0.8), SIMD3(0.8, 0.9, 1)][l]
        var detail = 0.0
        for (s, amplitude) in [(2.0, 0.55), (4.0, 0.45), (9.0, 0.35), (23.0, 0.3)] {
            detail += amplitude * valueNoise(x, y, scale: s, seed: UInt64(l * 17 + Int(s)))
        }
        let v = base * max(0.15, 1 + detail)
        return SIMD3<Float>(Float(v * tint.x), Float(v * tint.y), Float(v * tint.z))
    }

    struct Canvas {
        let width: Int, height: Int
        var rgb: [Float]
        func at(_ x: Double, _ y: Double) -> SIMD3<Float> {
            // Canvas pixel centres sit at reference coordinates −margin + i + 0.5.
            let cx = max(0, min(Double(width - 1), x + Double(FocusStackTests.margin) - 0.5))
            let cy = max(0, min(Double(height - 1), y + Double(FocusStackTests.margin) - 0.5))
            // Catmull-Rom, so framing the photos doesn't soften them beyond their defocus.
            let x0 = Int(cx), y0 = Int(cy)
            let wx = FocusStackCPUFusion.cubicWeights(Float(cx) - Float(x0)), wy = FocusStackCPUFusion.cubicWeights(Float(cy) - Float(y0))
            var sum = SIMD3<Float>.zero
            for j in 0..<4 { for i in 0..<4 {
                let p = (max(0, min(height - 1, y0 - 1 + j)) * width + max(0, min(width - 1, x0 - 1 + i))) * 3
                sum += wx[i] * wy[j] * SIMD3(rgb[p], rgb[p + 1], rgb[p + 2])
            }}
            return sum
        }
    }

    static let sharpCanvas: Canvas = {
        let w = width + 2 * margin, h = height + 2 * margin
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let v = scene(Double(x - margin) + 0.5, Double(y - margin) + 0.5)
            for c in 0..<3 { rgb[(y * w + x) * 3 + c] = v[c] }
        }}
        return Canvas(width: w, height: h, rgb: rgb)
    }()

    /// Photo `k`'s view of the scene before framing: each pixel blurred by its own layer's blur in that photo.
    static func defocused(_ k: Int) -> Canvas {
        let sharp = sharpCanvas, w = sharp.width, h = sharp.height
        var blurred: [Float: [Float]] = [:]
        for sigma in Set(blur[k]) {
            guard sigma > 0 else { blurred[sigma] = sharp.rgb; continue }
            var planes = (0..<3).map { c in (0..<(w * h)).map { sharp.rgb[$0 * 3 + c] } }
            for c in 0..<3 { planes[c] = FocusStackFilters.gaussian(planes[c], width: w, height: h, sigma: sigma) }
            var rgb = [Float](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { for c in 0..<3 { rgb[i * 3 + c] = planes[c][i] } }
            blurred[sigma] = rgb
        }
        var rgb = [Float](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let sigma = blur[k][layer(Double(x - margin) + 0.5, Double(y - margin) + 0.5)]
            let i = (y * w + x) * 3
            for c in 0..<3 { rgb[i + c] = blurred[sigma]![i + c] }
        }}
        return Canvas(width: w, height: h, rgb: rgb)
    }

    /// Writes the bracket as 16-bit linear TIFFs, framed by `truth` and with seeded Gaussian noise.
    static func writeBracket(in directory: URL) throws -> [URL] {
        try (0..<blur.count).map { k in
            let canvas = defocused(k), transform = truth(k)
            var seed = UInt64(k + 1) &* 0x2545F4914F6CDD1D
            func uniform() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Double(seed >> 11) + 0.5) / Double(1 << 53) }
            func gaussian() -> Float { Float((-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())) }
            var pixels = [UInt16](repeating: 0, count: width * height * 3)
            for y in 0..<height { for x in 0..<width {
                let p = transform.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5))
                let v = canvas.at(p.x, p.y)
                for c in 0..<3 {
                    let value = max(0, min(1, v[c] + noise[k] * gaussian()))
                    pixels[(y * width + x) * 3 + c] = UInt16((value * 65535).rounded())
                }
            }}
            let url = directory.appendingPathComponent("focus-\(k).tif")
            let provider = CGDataProvider(data: pixels.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6,
                                space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PanoramaError.message("TIFF not written") }
            return url
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// One analyzed bracket shared by the tests that only read from it.
    private static var shared: (FocusStacker, FocusStackAnalysis, URL)?
    private func analyzedBracket() throws -> (FocusStacker, FocusStackAnalysis) {
        if let (stacker, analysis, _) = Self.shared { return (stacker, analysis) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusStackTests-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stacker = try FocusStacker(urls: try Self.writeBracket(in: directory))
        let analysis = try stacker.analyze()
        Self.shared = (stacker, analysis, directory)
        return (stacker, analysis)
    }

    override class func tearDown() {
        if let (_, _, directory) = shared { try? FileManager.default.removeItem(at: directory) }
        shared = nil
        super.tearDown()
    }

    // MARK: Breathing

    func testJointSolveRecoversTransformsWithoutAccumulatingError() throws {
        // Neighbour links carry small opposite errors; the direct links to the anchor keep the chain from drifting.
        let truths = (0..<5).map { (k: Int) -> HDRSimilarity in
            let offset = Double(k - 2)
            let translation = SIMD2<Double>(0.8 * offset, 0.5 * offset)
            return HDRSimilarity(linear: matrix_identity_double2x2 * (1 + 0.006 * offset), translation: translation)
        }
        func link(_ a: Int, _ b: Int, error: Double) -> FocusStackAlignment.Link {
            var transform = truths[b].inverse.after(truths[a])
            transform.linear = transform.linear * (1 + error)
            return FocusStackAlignment.Link(from: a, to: b, transform: transform, confidence: 0.9)
        }
        let links = [link(0, 1, error: 0.0005), link(1, 2, error: -0.0005), link(2, 3, error: 0.0005), link(3, 4, error: -0.0005),
                     link(0, 2, error: 0), link(4, 2, error: 0)]
        let solved = FocusStackAlignment.solve(links: links, count: 5, anchor: 2, order: Array(0..<5), width: 720, height: 480)
        for k in 0..<5 {
            let model = try XCTUnwrap(solved[k])
            // No worse than a single link's error, rather than the sum along the chain.
            XCTAssertEqual(model.scale, truths[k].scale, accuracy: 6e-4, "photo \(k)")
            for corner in [SIMD2(0.0, 0), SIMD2(720, 480)] {
                XCTAssertLessThan(simd_distance(model.apply(corner), truths[k].apply(corner)), 0.6, "photo \(k)")
            }
        }
        // A photo no link reaches stays unmeasured.
        XCTAssertNil(FocusStackAlignment.solve(links: Array(links.prefix(2)), count: 5, anchor: 2, order: Array(0..<5), width: 720, height: 480)[4])
    }

    func testBreathingScaleAndShiftAreRecovered() throws {

        try TestTier.requireSlow()
        let (_, analysis) = try analyzedBracket()
        XCTAssertEqual(analysis.suggestedReference, 2)
        for frame in analysis.frames {
            let scale = try XCTUnwrap(frame.scale, "\(frame.filename) wasn't aligned")
            XCTAssertEqual(scale, Self.magnification[frame.index], accuracy: 0.0015, "\(frame.filename)")
            XCTAssertEqual(try XCTUnwrap(frame.rotationDegrees), Self.roll[frame.index], accuracy: 0.05)
            // The fitted transform moves every corner where the true one does, to within half a pixel.
            let truth = Self.truth(frame.index)
            let centre = SIMD2(Double(Self.width), Double(Self.height)) / 2, linear = truth.linear * (scale / truth.scale)
            let fitted = HDRSimilarity(linear: linear, translation: centre + (try XCTUnwrap(frame.shift)) - linear * centre)
            let rotation = (try XCTUnwrap(frame.rotationDegrees) - Self.roll[frame.index]) * .pi / 180
            XCTAssertLessThan(abs(rotation), 0.001)
            for corner in [SIMD2(0.0, 0), SIMD2(720, 0), SIMD2(0, 480), SIMD2(720, 480)] {
                XCTAssertLessThan(simd_distance(fitted.apply(corner), truth.apply(corner)), 0.5, "\(frame.filename) at \(corner)")
            }
        }
    }

    // MARK: Fusion

    /// High-pass detail of luminance: the image minus its blur.
    private static func detail(_ rgba: [Float], width: Int, height: Int) -> [Float] {
        var luminance = [Float](repeating: 0, count: width * height)
        for i in luminance.indices { luminance[i] = HDRMerger.luminance(rgba, i * 4) }
        let blurred = FocusStackFilters.gaussian(luminance, width: width, height: height, sigma: 1.5)
        return zip(luminance, blurred).map { $0 - $1 }
    }

    /// The scene and its depth on the merge's output grid, which starts at `origin` in reference pixels.
    private static func truthOnGrid(width: Int, height: Int, origin: SIMD2<Double>) -> (rgba: [Float], layers: [Int]) {
        var rgba = [Float](repeating: 1, count: width * height * 4), layers = [Int](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let px = Double(x) + 0.5 + origin.x, py = Double(y) + 0.5 + origin.y
            let v = sharpCanvas.at(px, py), i = y * width + x
            rgba[i * 4] = v.x; rgba[i * 4 + 1] = v.y; rgba[i * 4 + 2] = v.z
            layers[i] = layer(px, py)
        }}
        return (rgba, layers)
    }

    /// Pixels at least `distance` from any other layer (interior), or within it of one (edges), by layer.
    private static func regions(_ layers: [Int], width: Int, height: Int, distance: Int) -> (interior: [[Int]], edges: [Int]) {
        var interior = [[Int]](repeating: [], count: Self.layers), edges: [Int] = []
        for y in distance..<(height - distance) { for x in distance..<(width - distance) {
            let l = layers[y * width + x]
            var uniform = true
            for dy in stride(from: -distance, through: distance, by: 2) where uniform {
                for dx in stride(from: -distance, through: distance, by: 2) where layers[(y + dy) * width + x + dx] != l { uniform = false; break }
            }
            if uniform { interior[l].append(y * width + x) } else { edges.append(y * width + x) }
        }}
        return (interior, edges)
    }

    /// The share of the true detail an image reproduces over `pixels`: 1 is fully sharp, near 0 fully blurred. Noise,
    /// which doesn't correlate with the scene, doesn't count as sharpness.
    private static func sharpness(_ detail: [Float], truth: [Float], over pixels: [Int]) -> Double {
        var product = 0.0, energy = 0.0
        for i in pixels { product += Double(detail[i] * truth[i]); energy += Double(truth[i] * truth[i]) }
        return product / energy
    }

    func testFusionIsSharperThanEveryPhotoInEveryDepthBand() throws {

        try TestTier.requireSlow()
        let (stacker, _) = try analyzedBracket()
        let settings = FocusStackSettings()
        let fused = try stacker.previewRaster(settings)
        let (frames, sources, origin) = try stacker.alignedRasters(settings)
        let (width, height) = (fused.width, fused.height)
        // Breathing correction crops to what all four photos cover: the tightest one, 1.8% smaller.
        XCTAssertLessThan(width, Self.width); XCTAssertGreaterThan(Double(width), 0.95 * Double(Self.width))
        let truth = Self.truthOnGrid(width: width, height: height, origin: origin)
        let truthDetail = Self.detail(truth.rgba, width: width, height: height)
        let (interior, _) = Self.regions(truth.layers, width: width, height: height, distance: 10)
        let fusedDetail = Self.detail(fused.rgba, width: width, height: height)
        var worstInputs: [Double] = []
        for k in frames.keys.sorted() {
            let inputDetail = Self.detail(frames[k]!.rgba, width: width, height: height)
            let bands = (0..<Self.layers).map { Self.sharpness(inputDetail, truth: truthDetail, over: interior[$0]) }
            worstInputs.append(bands.min()!)
        }
        var fusedBands: [Double] = []
        for l in 0..<Self.layers {
            let best = frames.keys.map { Self.sharpness(Self.detail(frames[$0]!.rgba, width: width, height: height), truth: truthDetail, over: interior[l]) }.max()!
            let value = Self.sharpness(fusedDetail, truth: truthDetail, over: interior[l])
            fusedBands.append(value)
            XCTAssertGreaterThan(value, 0.97 * best, "depth \(l): fused \(value), sharpest photo \(best)")
            XCTAssertGreaterThan(value, 0.85, "depth \(l)")
        }
        // Every photo is blurred somewhere; the merge is sharp everywhere.
        for (k, worst) in worstInputs.enumerated() { XCTAssertGreaterThan(fusedBands.min()!, worst + 0.2, "photo \(k)") }

        // The source map names the in-focus photo for each depth, though the noisy far-focused photo has more raw
        // fine-scale energy than the blurred areas of the others.
        for (l, expected) in [(0, 0), (1, 2), (2, 3)] {
            let share = Double(interior[l].filter { sources[$0] == expected }.count) / Double(interior[l].count)
            XCTAssertGreaterThan(share, 0.9, "depth \(l) should come from photo \(expected)")
        }
    }

    /// At depth edges the edge-aware blend never leaves the range the photos span (a convex blend with one weight for
    /// all channels), so it can't ring; and beyond the boundary pixels themselves its error is that of each pixel's
    /// in-focus photo, so no halo spreads along the edge. The multiscale baseline overshoots there.
    /// The pixels right at a depth boundary stay ambiguous: a sharp edge lends either side the same local detail, and
    /// the defocused photo's background there is contaminated by its blurred foreground. That is the occlusion handling
    /// of the design's second milestone.
    func testDepthEdgesHaveNoHalos() throws {
        try TestTier.requireSlow()
        let (stacker, _) = try analyzedBracket()
        var settings = FocusStackSettings()
        let (frames, _, origin) = try stacker.alignedRasters(settings)
        let labels = try stacker.previewRaster(settings)
        settings.blending = .multiscale
        let multiscale = try stacker.previewRaster(settings)
        let (width, height) = (labels.width, labels.height)
        let truth = Self.truthOnGrid(width: width, height: height, origin: origin)
        let focused = [0: 0, 1: 2, 2: 3]
        // Every pixel within 8 pixels of a depth edge, with its distance to it.
        var band: [(index: Int, distance: Int)] = []
        for y in 8..<(height - 8) { for x in 8..<(width - 8) {
            let i = y * width + x, l = truth.layers[i]
            var distance = 9
            for dy in -8...8 { for dx in -8...8 where truth.layers[(y + dy) * width + x + dx] != l { distance = min(distance, max(abs(dx), abs(dy))) } }
            if distance <= 8 { band.append((i, distance)) }
        }}
        func luminance(_ raster: PanoramaRaster, _ i: Int) -> Float { HDRMerger.luminance(raster.rgba, i * 4) }
        func outside(_ raster: PanoramaRaster) -> Double {
            Double(band.filter { pixel in
                let values = frames.values.map { luminance($0, pixel.index) }, v = luminance(raster, pixel.index)
                return v < values.min()! - 0.004 || v > values.max()! + 0.004
            }.count) / Double(band.count)
        }
        func error(_ value: (Int) -> Float, beyond distance: Int) -> Double {
            let pixels = band.filter { $0.distance > distance }
            return pixels.reduce(0.0) { $0 + Double(abs(value($1.index) - HDRMerger.luminance(truth.rgba, $1.index * 4))) } / Double(pixels.count)
        }
        let inFocus = { (i: Int) in luminance(frames[focused[truth.layers[i]]!]!, i) }
        let edgeAware = (outside: outside(labels), halo: error({ luminance(labels, $0) }, beyond: 2), all: error({ luminance(labels, $0) }, beyond: 0))
        let baseline = (outside: outside(multiscale), halo: error({ luminance(multiscale, $0) }, beyond: 2), all: error({ luminance(multiscale, $0) }, beyond: 0))
        let reference = (halo: error(inFocus, beyond: 2), all: error(inFocus, beyond: 0))
        XCTAssertLessThan(edgeAware.outside, 0.002)
        XCTAssertGreaterThan(baseline.outside, 10 * max(edgeAware.outside, 0.002), "the multiscale baseline should show its halos here")
        XCTAssertLessThan(edgeAware.halo, 1.15 * reference.halo)
        XCTAssertLessThan(edgeAware.all, baseline.all)
    }

    /// Analysis on the GPU (sharpness, noise, exposure and the edge-aware spreading) is the CPU's arithmetic.
    func testGPUAnalysisMatchesCPU() throws {
        try TestTier.requireSlow()
        let (gpu, _) = try analyzedBracket()
        let cpu = try FocusStacker(urls: gpu.urls)
        cpu.analysisEngine = .cpu
        _ = try cpu.analyze()
        for blending in FocusStackBlending.allCases {
            var settings = FocusStackSettings(); settings.blending = blending
            let a = try cpu.previewRaster(settings), b = try gpu.previewRaster(settings)
            let difference = HDRMergeTests.difference(a, b)
            XCTAssertLessThan(difference.mean, 2e-4, "\(blending): \(difference)")
            let ca = try cpu.preview(settings).contributions, cb = try gpu.preview(settings).contributions
            for (photo, share) in ca { XCTAssertEqual(share, cb[photo] ?? 0, accuracy: 0.005, "\(blending): photo \(photo)") }
        }
    }

    /// The GPU merge is the CPU's arithmetic, for both blends.
    func testGPUMergeMatchesCPU() throws {
        try TestTier.requireSlow()
        let (stacker, _) = try analyzedBracket()
        for blending in FocusStackBlending.allCases {
            var settings = FocusStackSettings(); settings.blending = blending
            let cpu = try stacker.mergedRaster(settings, engine: .cpu).0
            let gpu: PanoramaRaster
            do { gpu = try stacker.mergedRaster(settings, engine: .gpu).0 } catch { throw XCTSkip("No GPU: \(error)") }
            XCTAssertEqual(gpu.width, cpu.width); XCTAssertEqual(gpu.height, cpu.height)
            let difference = HDRMergeTests.difference(cpu, gpu)
            XCTAssertLessThan(difference.worst, 2e-3, "\(blending): \(difference)")
            XCTAssertLessThan(difference.mean, 1e-5, "\(blending): \(difference)")
        }
    }

    /// The layer brush: painting a photo into an area makes the result take that area from it alone, in the preview and
    /// at full size on the CPU and the GPU; painting a photo out hands its area to another; and the painted area stays on
    /// the same part of the scene when the reference changes.
    func testLayerBrushRepaintsAreasAndHoldsAtFullSize() throws {
        try TestTier.requireSlow()
        let (stacker, _) = try analyzedBracket()
        var settings = FocusStackSettings()
        let preview = try stacker.preview(settings)
        func share(_ mask: CGImage, _ x: Double, _ y: Double) -> Double {
            var byte: UInt8 = 0
            let context = CGContext(data: &byte, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.interpolationQuality = .none
            // Draw so the sampled pixel lands on the 1 × 1 context (Core Graphics' origin is the bottom left).
            let w = Double(mask.width), h = Double(mask.height)
            context.draw(mask, in: CGRect(x: -(x * w).rounded(.down), y: -(h - 1 - (y * h).rounded(.down)), width: w, height: h))
            return Double(byte) / 255
        }
        // A spot of far background (sharp in photo 3) and one of the near disc (sharp in photo 0).
        let far = (x: 0.12, y: 0.15), radius = 0.04
        XCTAssertGreaterThan(share(try stacker.layerMask(settings, photo: 3), far.x, far.y), 0.9, "photo 3 supplies the far background")
        let nearMask = try stacker.layerMask(settings, photo: 0)
        let near = try XCTUnwrap(stride(from: 0.2, through: 0.8, by: 0.02).flatMap { y in stride(from: 0.2, through: 0.8, by: 0.02).map { (x: $0, y: y) } }
            .first { share(nearMask, $0.x, $0.y) > 0.99 })
        func dab(_ point: (x: Double, y: Double), photo: Int, add: Bool) -> FocusStackStroke {
            let p = CGPoint(x: point.x, y: point.y).applying(preview.toBrushSpace)
            return FocusStackStroke(x: p.x, y: p.y, radius: radius * preview.brushScale, photo: photo, add: add)
        }
        settings.strokes = [dab(far, photo: 0, add: true), dab(near, photo: 0, add: false)]
        XCTAssertGreaterThan(share(try stacker.layerMask(settings, photo: 0), far.x, far.y), 0.99, "painted in")
        XCTAssertLessThan(share(try stacker.layerMask(settings, photo: 3), far.x, far.y), 0.01)
        XCTAssertLessThan(share(try stacker.layerMask(settings, photo: 0), near.x, near.y), 0.01, "painted out")
        XCTAssertGreaterThan(try (1...3).map { share(try stacker.layerMask(settings, photo: $0), near.x, near.y) }.reduce(0, +), 0.99)

        // At full size the painted spot is photo 0's pixels, not the sharper photo 3's, on both engines.
        let (frames, _, _) = try stacker.alignedRasters(settings)
        let cpu = try stacker.mergedRaster(settings, engine: .cpu).0
        XCTAssertEqual(cpu.width, frames[0]!.width)
        func distance(_ raster: PanoramaRaster, to photo: Int) -> Double {
            let cx = Int(far.x * Double(raster.width)), cy = Int(far.y * Double(raster.height)), r = Int(radius * 0.6 * Double(raster.width))
            var total = 0.0, count = 0.0
            for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                let p = (y * raster.width + x) * 4
                total += Double(abs(HDRMerger.luminance(raster.rgba, p) - HDRMerger.luminance(frames[photo]!.rgba, p))); count += 1
            }}
            return total / count
        }
        XCTAssertLessThan(distance(cpu, to: 0), 0.1 * distance(cpu, to: 3), "the painted spot comes from photo 0")
        if let gpu = try? stacker.mergedRaster(settings, engine: .gpu).0 {
            let difference = HDRMergeTests.difference(cpu, gpu)
            XCTAssertLessThan(difference.worst, 2e-3, "\(difference)")
            XCTAssertLessThan(distance(gpu, to: 0), 0.1 * distance(gpu, to: 3))
        }

        // With photo 0 as the reference the scene moves in the uncropped preview; the painted spot moves with it.
        settings.cropToCoverage = false
        let painted = CGPoint(x: settings.strokes[0].x, y: settings.strokes[0].y)
        let before = painted.applying(try stacker.preview(settings).fromBrushSpace)
        settings.reference = 0
        let after = painted.applying(try stacker.preview(settings).fromBrushSpace)
        XCTAssertGreaterThan(hypot(after.x - before.x, after.y - before.y), 0.003, "the reference's framing differs")
        XCTAssertGreaterThan(share(try stacker.layerMask(settings, photo: 0), after.x, after.y), 0.99)
    }

    /// A smart selection's few dabs pick the whole connected area of the depth they touch, not just their discs, and
    /// stay inside it. The test reads the tone fallback (the synthetic scene means nothing to the depth model).
    func testSmartSelectionPicksTheAreaAtTheTouchedDepth() throws {
        try TestTier.requireSlow()
        let (shared, _) = try analyzedBracket()
        let stacker = try FocusStacker(urls: shared.urls)
        stacker.usesDepth = false
        _ = try stacker.analyze()
        var settings = FocusStackSettings()
        let preview = try stacker.preview(settings)
        let (_, sources, origin) = try stacker.alignedRasters(settings)
        let width = preview.image.width, height = preview.image.height
        XCTAssertEqual(sources.count, width * height)
        let truth = Self.truthOnGrid(width: width, height: height, origin: origin).layers
        // A short stroke inside the far background, taken from photo 0 (sharp near), so the selection shows in its layer.
        let radius = 0.02
        let dabs = [(0.1, 0.12), (0.12, 0.13), (0.14, 0.12)].map { x, y in
            let p = CGPoint(x: x, y: y).applying(preview.toBrushSpace)
            return FocusStackStroke(x: p.x, y: p.y, radius: radius * preview.brushScale, photo: 0, add: true, selection: 1)
        }
        settings.strokes = dabs
        let mask = try stacker.layerMask(settings, photo: 0)
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        let before = try stacker.layerMask(FocusStackSettings(), photo: 0)
        var original = [UInt8](repeating: 0, count: width * height)
        let context2 = CGContext(data: &original, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context2.draw(before, in: CGRect(x: 0, y: 0, width: width, height: height))
        let gained = (0..<(width * height)).filter { bytes[$0] > 200 && original[$0] < 50 }
        let far = gained.filter { truth[$0] == 2 }.count
        let disc = Double.pi * pow(radius * Double(width), 2) * 2
        XCTAssertGreaterThan(Double(gained.count), 5 * disc, "the selection reaches beyond the dabs")
        XCTAssertGreaterThan(Double(far), 0.9 * Double(gained.count), "and stays at the touched depth")
    }

    func testMergeWritesCroppedDNGAndPreviewReportsSources() throws {
        let (stacker, analysis) = try analyzedBracket()
        var settings = FocusStackSettings()
        let preview = try stacker.preview(settings)
        XCTAssertEqual(preview.image.width, preview.sources.width)
        XCTAssertNil(preview.inspection) // Image preview never generates inspection maps.
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertNil(try stacker.preview(settings).inspection)
            let inspection = try XCTUnwrap(stacker.inspection(settings))
            XCTAssertEqual(inspection.field.width, preview.image.width)
            XCTAssertEqual(inspection.field.height, preview.image.height)
            XCTAssertTrue(try stacker.inspection(settings) === inspection)
            XCTAssertTrue(try stacker.preview(settings).inspection === inspection)
            // Blend choice does not replace measured focus evidence.
            var blended = settings; blended.blending = .multiscale
            XCTAssertTrue(try stacker.preview(blended).inspection === inspection)
            blended.strokes = [FocusStackStroke(x: 0.5, y: 0.5, radius: 0.01, photo: 0, add: true)]
            XCTAssertTrue(try stacker.inspection(blended) === inspection)
        }
        XCTAssertEqual(preview.contributions.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(preview.contributions[0] ?? 0, 0.1)
        XCTAssertGreaterThan(preview.contributions[3] ?? 0, 0.3)
        let output = try temporaryDirectory().appendingPathComponent("stacked.dng")
        try stacker.merge(settings, to: output)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: output))
        XCTAssertEqual(Int(raw.nativeSize.width), preview.outputWidth)
        XCTAssertEqual(Int(raw.nativeSize.height), preview.outputHeight)
        XCTAssertLessThan(preview.outputWidth, analysis.width)
        // Without the crop the result keeps the reference's whole frame; leaving photos out changes the sources.
        settings.cropToCoverage = false
        settings.excluded = [0]
        let uncropped = try stacker.preview(settings)
        XCTAssertEqual(uncropped.outputWidth, analysis.width)
        XCTAssertNil(uncropped.contributions[0])
        XCTAssertNil(uncropped.inspection) // New grid waits for another explicit inspection request.
        if MTLCreateSystemDefaultDevice() != nil {
            let inspection = try XCTUnwrap(stacker.inspection(settings))
            XCTAssertEqual(inspection.field.width, uncropped.image.width)
            XCTAssertTrue(try stacker.preview(settings).inspection === inspection)
        }
    }

    /// Flat pixels follow what confident pixels at the same depth chose; confident pixels and bins without agreement
    /// keep their own measurement.
    func testDepthVotesFillFlatAreas() {
        // Left half far, right half near; photo 1 is sharp far, photo 0 near. Textured pixels sit on every fourth column.
        let width = 64, height = 32, n = width * height
        var depth = [Float](repeating: 0, count: n), best = [Int](repeating: 2, count: n), confidence = [Float](repeating: 0, count: n)
        for y in 0..<height { for x in 0..<width {
            let k = y * width + x
            depth[k] = x < width / 2 ? 0.1 + 0.001 * Float(y) : 0.9 + 0.001 * Float(y)
            if x % 4 == 0 { best[k] = x < width / 2 ? 1 : 0; confidence[k] = 0.8 }
        }}
        best[5] = 0; confidence[5] = 0.05
        let focus = [[Float]](repeating: [Float](repeating: 1, count: n), count: 3)
        let changed = FocusStacker.depthVotes(depth, best: &best, confidence: &confidence, focus: focus, included: [0, 1, 2], bins: 4)
        XCTAssertGreaterThan(changed, n / 2)
        XCTAssertEqual(best[5], 1, "a flat far pixel takes the far photo")
        XCTAssertEqual(best[width - 3], 0, "a flat near pixel takes the near photo")
        XCTAssertEqual(best[4], 1); XCTAssertEqual(confidence[4], 0.8, "confident pixels keep their measurement")
        XCTAssertLessThanOrEqual(confidence[5], 0.15, "the vote stays weak")
    }

    func testDifferentSizesAreRefused() throws {
        let directory = try temporaryDirectory()
        let urls = try FocusStackPlainPhotos.writePlain(sizes: [(64, 48), (48, 64)], in: directory)
        XCTAssertThrowsError(try FocusStacker(urls: urls).analyze())
        XCTAssertThrowsError(try FocusStacker(urls: [urls[0]]))
    }
}

/// Small flat test photos.
private enum FocusStackPlainPhotos {
    static func writePlain(sizes: [(Int, Int)], in directory: URL) throws -> [URL] {
        try sizes.enumerated().map { k, size in
            let (width, height) = size
            let pixels = [UInt8](repeating: 128, count: width * height * 4)
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = directory.appendingPathComponent("plain-\(k).tif")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PanoramaError.message("TIFF not written") }
            return url
        }
    }
}
