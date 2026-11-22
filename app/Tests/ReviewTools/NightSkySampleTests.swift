import XCTest
import CoreGraphics
import CoreImage
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import CevicheCore

/// Runs the night-sky tools on real sequences when `CEVICHE_NIGHT_SKY_SAMPLES` names a folder of RAW photos, writing
/// pictures and numbers to `CEVICHE_NIGHT_SKY_OUTPUT` (or a temporary folder) for inspection. Skipped otherwise.
final class NightSkySampleTests: XCTestCase {
    private func samples() throws -> (urls: [URL], output: URL) {
        guard let folder = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_SAMPLES"] else { throw XCTSkip("Set CEVICHE_NIGHT_SKY_SAMPLES to a folder of RAW photos") }
        let limit = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_LIMIT"].flatMap(Int.init)
        var urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            .filter { ["arw", "cr2", "cr3", "nef", "dng", "raf", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let first = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_FROM"], let start = urls.firstIndex(where: { $0.lastPathComponent == first }) {
            urls = Array(urls[start...])
        }
        if let limit { urls = Array(urls.prefix(limit)) }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_OUTPUT"] ?? NSTemporaryDirectory() + "NightSkySamples")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return (urls, output)
    }

    static func save(_ image: CGImage?, _ url: URL) {
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    func testAnalysisOnSamples() throws {
        let (urls, output) = try samples()
        let analyzer = try NightSkyAnalyzer(urls: urls, space: .sky)
        let start = Date()
        try analyzer.analyze { fraction, message in print(String(format: "%6.1f s %3.0f%% %@", Date().timeIntervalSince(start), fraction * 100, message)) }
        let elapsed = Date().timeIntervalSince(start)
        let aligned = analyzer.alignments.compactMap { $0 }
        print("analysis \(String(format: "%.1f", elapsed)) s for \(urls.count) photos; aligned \(aligned.count); preview \(analyzer.previewWidth)×\(analyzer.previewHeight)")
        for i in analyzer.urls.indices {
            let a = analyzer.alignments[i]
            print("\(analyzer.metadata[i].filename) stars \(analyzer.starCounts[i]) bg \(analyzer.backgrounds[i]) gain \(analyzer.gains[i]) "
                  + (a.map { "matches \($0.matches) p95 \(String(format: "%.2f", $0.heldOutP95)) morph \($0.morph != nil)" } ?? "FAILED \(analyzer.failures[i] ?? "")"))
        }
        for line in analyzer.lines { print("line frame \(analyzer.metadata[line.frame].filename) length \(Int(line.length)) width \(String(format: "%.1f", line.width)) peak \(Int(line.peak))σ persistent \(line.persistent)") }
        let w = analyzer.previewWidth, h = analyzer.previewHeight
        Self.save(NightSkyFinishing.picture(analyzer.previewProbability.flatMap { [$0, $0, $0] }, channels: 3, width: w, height: h, exposure: 1), output.appendingPathComponent("sky-probability.png"))
        let all = Set(analyzer.urls.indices), alignedFrames = Set(all.filter { analyzer.alignments[$0] != nil })
        var exclusions: [Int: [NightSkyLine]] = [:]
        for line in analyzer.lines { exclusions[line.frame, default: []].append(line) }
        let reference = try analyzer.preview(NightSkyAnalyzer.Plan(base: analyzer.anchor, ground: [analyzer.anchor]))
        Self.save(NightSkyFinishing.picture(reference, channels: 3, width: w, height: h, exposure: analyzer.displayExposure), output.appendingPathComponent("reference.png"))
        let mean = try analyzer.preview(NightSkyAnalyzer.Plan(base: analyzer.anchor, sky: alignedFrames, ground: all, skyExclusions: exclusions))
        Self.save(NightSkyFinishing.picture(mean, channels: 3, width: w, height: h, exposure: analyzer.displayExposure), output.appendingPathComponent("mean.png"))
        let trails = try analyzer.preview(NightSkyAnalyzer.Plan(base: analyzer.anchor, ground: all, peak: all))
        Self.save(NightSkyFinishing.picture(trails, channels: 3, width: w, height: h, exposure: analyzer.displayExposure), output.appendingPathComponent("trails.png"))
        let meteors = try analyzer.preview(NightSkyAnalyzer.Plan(base: analyzer.anchor, sky: alignedFrames, ground: all, skyExclusions: exclusions,
                                                                  restore: analyzer.lines.filter { !$0.persistent }))
        Self.save(NightSkyFinishing.picture(meteors, channels: 3, width: w, height: h, exposure: analyzer.displayExposure), output.appendingPathComponent("meteors.png"))
        // A contact sheet of line crops in list order, and the lines drawn over the anchor (red isolated, blue tracks).
        let crops = try analyzer.lines.prefix(96).map { try analyzer.linePicture($0, size: 120) }
        let columns = 12, side = 124
        let sheet = CGContext(data: nil, width: columns * side, height: max(1, (crops.count + columns - 1) / columns) * side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (k, crop) in crops.enumerated() {
            guard let crop else { continue }
            sheet.draw(crop, in: CGRect(x: (k % columns) * side + 2, y: sheet.height - (k / columns + 1) * side + 2, width: 120, height: 120))
        }
        Self.save(sheet.makeImage(), output.appendingPathComponent("lines.png"))
        if let picture = NightSkyFinishing.picture(reference, channels: 3, width: w, height: h, exposure: analyzer.displayExposure) {
            let overlay = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            overlay.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            overlay.setLineWidth(3)
            let k = analyzer.previewScale
            for line in analyzer.lines {
                overlay.setStrokeColor(line.persistent ? CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
                overlay.move(to: CGPoint(x: (line.start.x + 0.5) / k, y: Double(h) - (line.start.y + 0.5) / k))
                overlay.addLine(to: CGPoint(x: (line.end.x + 0.5) / k, y: Double(h) - (line.end.y + 0.5) / k))
                overlay.strokePath()
            }
            Self.save(overlay.makeImage(), output.appendingPathComponent("lines-overview.png"))
        }
    }

    /// Full-size Night Sky Denoise on the samples: GPU against CPU, noise against the reference photo, 100% crops.
    func testDenoiseFullSize() throws {
        let (urls, output) = try samples()
        let denoiser = try NightSkyDenoiser(urls: urls)
        let analysis = try denoiser.analyze()
        var settings = NightSkyDenoiseSettings()
        settings.excluded = analysis.suggestedExclusions
        let analyzer = denoiser.internalAnalyzer
        var start = Date()
        let gpu = try denoiser.render(settings, engine: .gpu)
        print("render GPU \(String(format: "%.1f", Date().timeIntervalSince(start))) s for \(analysis.frames.count - settings.excluded.count) photos at \(gpu.width)×\(gpu.height)")
        let plan = try denoiser.plan(settings)
        let reference = try analyzer.render(NightSkyAnalyzer.Plan(base: plan.base, ground: [plan.base]), engine: .gpu, progress: { _, _ in })
        if ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_CPU"] != nil {
            start = Date()
            let cpu = try denoiser.render(settings, engine: .cpu)
            print("render CPU \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
            var worst: Float = 0, sum = 0.0, over = 0
            for i in stride(from: 0, to: gpu.rgba.count, by: 4) {
                let d = max(abs(gpu.rgba[i] - cpu.rgba[i]), abs(gpu.rgba[i + 1] - cpu.rgba[i + 1]), abs(gpu.rgba[i + 2] - cpu.rgba[i + 2]))
                let scale = max(0.01, abs(cpu.rgba[i + 1]))
                worst = max(worst, d / scale); sum += Double(d * d)
                if d / scale > 0.02 { over += 1 }
            }
            print("RESULT GPU vs CPU: worst relative \(worst), RMS \(sqrt(sum / Double(gpu.rgba.count / 4))), pixels over 2%: \(over) of \(gpu.rgba.count / 4)")
        }
        // High-frequency noise: luminance minus its 5×5 mean, MAD over confident sky, reference against stack.
        func noise(_ raster: PanoramaRaster) -> Double {
            let w = raster.width, h = raster.height
            var l = [Float](repeating: 0, count: w * h)
            for p in 0..<(w * h) { l[p] = 0.2126 * raster.rgba[p * 4] + 0.7152 * raster.rgba[p * 4 + 1] + 0.0722 * raster.rgba[p * 4 + 2] }
            let blurred = HDRMerger.boxBlur(l, width: w, height: h, radius: 2)
            let probability = analyzer.fullSizeProbability()
            var values: [Double] = []
            for p in stride(from: 0, to: w * h, by: 97) where probability[p] > 0.95 { values.append(Double(abs(l[p] - blurred[p]))) }
            return NightSkyStars.median(values)
        }
        let before = noise(reference), after = noise(gpu)
        print("RESULT sky noise reference \(before) stack \(after) reduction \(String(format: "%.2f", before / after))× (ideal √N = \(String(format: "%.2f", Double(plan.sky.count).squareRoot())))")
        // 100% crops, reference left and stack right, at the center and a corner.
        for (name, x, y) in [("center", gpu.width / 2 - 300, gpu.height / 2 - 200), ("corner", 80, 80), ("bottom", gpu.width / 2 - 300, gpu.height - 480)] {
            var crop = [Float](repeating: 0, count: 1200 * 400 * 3)
            for row in 0..<400 { for column in 0..<600 { for c in 0..<3 {
                crop[(row * 1200 + column) * 3 + c] = reference.rgba[((y + row) * reference.width + x + column) * 4 + c]
                crop[(row * 1200 + column + 600) * 3 + c] = gpu.rgba[((y + row) * gpu.width + x + column) * 4 + c]
            }}}
            Self.save(NightSkyFinishing.picture(crop, channels: 3, width: 1200, height: 400, exposure: analyzer.displayExposure), output.appendingPathComponent("crop-\(name).png"))
        }
        print("RESULT hot pixels found: \(analyzer.hotPixels.count)")
        // The design's acceptance checks, as far as one session allows.
        let w = gpu.width, h = gpu.height
        func luminance(_ raster: PanoramaRaster) -> [Float] {
            (0..<(w * h)).map { 0.2126 * raster.rgba[$0 * 4] + 0.7152 * raster.rgba[$0 * 4 + 1] + 0.0722 * raster.rgba[$0 * 4 + 2] }
        }
        let probability = analyzer.fullSizeProbability()
        let sky = (0..<(w * h)).filter { $0 % 13 == 0 && probability[$0] > 0.95 }
        // 1. Independent half stacks: odd and even photos agree in broad structure, and the full stack is quieter by about √2.
        let members = plan.sky.sorted()
        func half(_ parity: Int) throws -> PanoramaRaster {
            var halfPlan = plan; halfPlan.sky = Set(members.enumerated().filter { $0.offset % 2 == parity }.map(\.element))
            return try analyzer.render(halfPlan, engine: .gpu, progress: { _, _ in })
        }
        let a = try half(0), b = try half(1)
        let la = HDRMerger.boxBlur(luminance(a), width: w, height: h, radius: 32), lb = HDRMerger.boxBlur(luminance(b), width: w, height: h, radius: 32)
        let offsets = sky.map { Double(abs(la[$0] - lb[$0]) / max(1e-6, (la[$0] + lb[$0]) / 2)) }
        let halfNoise = (noise(a) + noise(b)) / 2
        print("RESULT split stacks of \(members.count / 2 + members.count % 2) and \(members.count / 2): broad-structure difference median \(String(format: "%.3f", NightSkyStars.median(offsets) * 100))%, half-stack noise \(halfNoise), full \(after), ratio \(String(format: "%.2f", halfNoise / after)) (√2 ≈ 1.41)")
        XCTAssertLessThan(NightSkyStars.median(offsets), 0.01)
        // 2. Star flux by brightness: aperture photometry of the reference's stars, in thirds by flux.
        let lr = luminance(reference), ls = luminance(gpu)
        let stars = try NightSkyStars.detect(lr, width: w, height: h, mask: probability.map { $0 > 0.95 ? 1 : 0 }, limit: 3000)
            .filter { $0.point.x > 12 && $0.point.y > 12 && $0.point.x < Double(w - 12) && $0.point.y < Double(h - 12) }
        func aperture(_ l: [Float], _ p: SIMD2<Double>) -> Double {
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            var core = 0.0, ring = 0.0, n = 0.0
            for dy in -4...4 { for dx in -4...4 { core += Double(l[(y + dy) * w + x + dx]) } }
            for dy in -9...9 { for dx in -9...9 where max(abs(dx), abs(dy)) >= 7 { ring += Double(l[(y + dy) * w + x + dx]); n += 1 } }
            return core - 81 * ring / n
        }
        let measured = stars.map { (aperture(lr, $0.point), aperture(ls, $0.point)) }.filter { $0.0 > 0 }.sorted { $0.0 < $1.0 }
        for (k, name) in ["faint", "middle", "bright"].enumerated() {
            let bin = measured[(measured.count * k / 3)..<(measured.count * (k + 1) / 3)]
            let ratio = NightSkyStars.median(bin.map { $0.1 / $0.0 })
            print("RESULT \(name) third of \(measured.count) stars: median stack/reference aperture flux \(String(format: "%.3f", ratio))")
            XCTAssertEqual(ratio, 1, accuracy: k == 0 ? 0.15 : 0.08, name)
        }
        // 3. The Milky Way's broad structure: blurred over 40 pixels, the stack follows the reference.
        let br = HDRMerger.boxBlur(lr, width: w, height: h, radius: 40), bs = HDRMerger.boxBlur(ls, width: w, height: h, radius: 40)
        let xs = sky.map { Double(br[$0]) }, ys = sky.map { Double(bs[$0]) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let correlation = cov / (xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) } * ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }).squareRoot()
        let level = NightSkyStars.median(zip(xs, ys).map { $0.1 / $0.0 })
        print("RESULT Milky Way structure over 40 px: correlation \(String(format: "%.4f", correlation)), median level \(String(format: "%.4f", level))")
        XCTAssertGreaterThan(correlation, 0.99); XCTAssertEqual(level, 1, accuracy: 0.03)
        // 4. The robust variant beside the plain mean.
        var robustSettings = settings; robustSettings.rejectOutliers = true
        start = Date()
        var stages: [String: Double] = [:]
        let robust = try analyzer.render(try denoiser.plan(robustSettings), engine: .gpu, progress: { _, _ in }, timing: { stages[$0, default: 0] += $1 })
        let elapsed = Date().timeIntervalSince(start)
        print("RESULT robust stages \(stages.mapValues { String(format: "%.1f", $0) })")
        let robustNoise = noise(robust), lrobust = luminance(robust)
        let robustFlux = NightSkyStars.median(measured.indices.map { k in aperture(lrobust, stars[k].point) }.indices.compactMap { k -> Double? in
            let r = aperture(lr, stars[k].point); return r > 0 ? aperture(lrobust, stars[k].point) / r : nil })
        print("RESULT robust variant: \(String(format: "%.1f", elapsed)) s, sky noise reduction \(String(format: "%.2f", before / robustNoise))×, median star flux \(String(format: "%.3f", robustFlux))")
        let url = output.appendingPathComponent("denoise.dng")
        try? FileManager.default.removeItem(at: url)
        try denoiser.merge(settings, to: url)
        print("RESULT wrote \(url.path)")
    }

    /// One tool end to end on the samples, `CEVICHE_NIGHT_SKY_TOOL` = trails, denoise or meteors: preview, full-size DNG,
    /// and a 2000-pixel picture of the full-size result.
    func testToolOnSamples() throws {
        let (urls, output) = try samples()
        let tool = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_TOOL"] ?? "denoise"
        let progress: @Sendable (Double, String) -> Void = { _, _ in }
        var start = Date()
        func lap(_ name: String) { print("RESULT \(name) \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); start = Date() }
        let dng = output.appendingPathComponent("\(tool).dng")
        try? FileManager.default.removeItem(at: dng)
        let preview: NightSkyPreview
        switch tool {
        case "trails":
            let merger = try StarTrailsMerger(urls: urls)
            let analysis = try merger.analyze(progress: progress)
            lap("analysis of \(urls.count) photos")
            var settings = StarTrailsSettings(); settings.excluded = analysis.suggestedExclusions
            // CEVICHE_NIGHT_SKY_TRAILS_SKY=one draws the trails over one photo's sky; =gaps also fills the pauses.
            if let mode = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_TRAILS_SKY"] {
                settings.sky = .onePhoto
                settings.fillGaps = mode == "gaps"
                print("RESULT trails over one photo's sky\(settings.fillGaps ? ", \(merger.filledGaps(settings)) pauses drawn in" : "")")
            }
            print("RESULT left out \(settings.excluded.sorted().map { analysis.frames[$0].filename }); lines \(analysis.lines.count), tracks \(analysis.lines.filter { $0.kind == .track }.count)")
            preview = try merger.preview(settings)
            lap("preview")
            if ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_PREVIEW_ONLY"] != nil {
                var plain = settings; plain.fillGaps = false
                _ = try merger.preview(plain); lap("preview without gaps")
                plain.sky = .brightest; _ = try merger.preview(plain); lap("preview, brightest sky")
                Self.save(preview.image, output.appendingPathComponent("trails-preview.png"))
                return
            }
            try merger.merge(settings, to: dng, progress: progress)
        case "meteors":
            let merger = try MeteorShowerMerger(urls: urls)
            let analysis = try merger.analyze(progress: progress)
            lap("analysis of \(urls.count) photos")
            var settings = MeteorShowerSettings(); settings.excluded = analysis.suggestedExclusions
            settings.skyPhotos = ProcessInfo.processInfo.environment["CEVICHE_NIGHT_SKY_STACK"].flatMap { Int($0) } ?? 1
            for line in analysis.lines {
                print("RESULT line \(line.id) \(analysis.frames[line.frame].filename) \(Int(line.length)) px \(line.kind)")
            }
            Self.save(sheet(analysis.lines.compactMap(\.thumbnail)), output.appendingPathComponent("meteor-lines.png"))
            preview = try merger.preview(settings)
            lap("preview")
            try merger.merge(settings, to: dng, progress: progress)
        default:
            let merger = try NightSkyDenoiser(urls: urls)
            let analysis = try merger.analyze(progress: progress)
            lap("analysis of \(urls.count) photos")
            var settings = NightSkyDenoiseSettings(); settings.excluded = analysis.suggestedExclusions
            preview = try merger.preview(settings)
            lap("preview")
            try merger.merge(settings, to: dng, progress: progress)
        }
        lap("full-size merge and DNG")
        Self.save(preview.image, output.appendingPathComponent("\(tool)-preview.png"))
        // The written DNG as Core Image develops it, for a look at the full-size result.
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: dng))
        raw.scaleFactor = Float(2000 / max(raw.nativeSize.width, raw.nativeSize.height))
        let context = CIContext()
        let image = try XCTUnwrap(raw.outputImage)
        Self.save(context.createCGImage(image, from: image.extent), output.appendingPathComponent("\(tool)-result.png"))
        print("RESULT DNG \(Int(raw.nativeSize.width))×\(Int(raw.nativeSize.height)), \((try FileManager.default.attributesOfItem(atPath: dng.path)[.size] as? Int ?? 0) / 1_000_000) MB")
    }

    private func sheet(_ crops: [CGImage]) -> CGImage? {
        let columns = 10, side = 124
        guard !crops.isEmpty, let context = CGContext(data: nil, width: columns * side, height: (crops.count + columns - 1) / columns * side, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (k, crop) in crops.enumerated() {
            context.draw(crop, in: CGRect(x: (k % columns) * side + 2, y: context.height - (k / columns + 1) * side + 2, width: 120, height: 120))
        }
        return context.makeImage()
    }

    /// The design's injected-source check on real backgrounds: 500 artificial stars in five brightness bins (1 to 16 times
    /// one photo's noise), moved with the measured sky so they behave like real ones, are added to every developed photo,
    /// which is written as a float TIFF and stacked. Reports flux recovered, completeness in the stack against one photo,
    /// and a split audit of false stars.
    func testInjectedStarsOnSamples() throws {
        let (urls, output) = try samples()
        let clean = try NightSkyDenoiser(urls: urls)
        let cleanAnalysis = try clean.analyze()
        var settings = NightSkyDenoiseSettings(); settings.excluded = cleanAnalysis.suggestedExclusions
        let analyzer = clean.internalAnalyzer, scale = analyzer.scale
        let reference = try clean.plan(settings).base
        let cleanStack = try clean.render(settings, engine: .gpu)
        let w = cleanStack.width, h = cleanStack.height
        func luminance(_ rgba: [Float]) -> [Float] { (0..<(w * h)).map { 0.2126 * rgba[$0 * 4] + 0.7152 * rgba[$0 * 4 + 1] + 0.0722 * rgba[$0 * 4 + 2] } }
        // One photo's per-pixel noise in the sky, from the reference's high-pass.
        let referenceFrame = try HDRMergeDecoder.decode(analyzer.urls[reference], metadata: analyzer.metadata[reference].base, longEdge: nil, whiteBalance: analyzer.whiteBalance, context: analyzer.context)
        let lr = luminance(referenceFrame.pixels), blurred = HDRMerger.boxBlur(lr, width: w, height: h, radius: 2)
        let probability = analyzer.fullSizeProbability()
        let noise = Float(1.4826 * NightSkyStars.median(stride(from: 0, to: w * h, by: 101).filter { probability[$0] > 0.95 }.map { Double(abs(lr[$0] - blurred[$0])) }))
        // Positions on the reference's sky, away from the edges, the skyline and real stars.
        let real = try NightSkyStars.detect(lr, width: w, height: h, mask: nil, limit: .max).map(\.point)
        var occupied = Set<Int>()
        for p in real { occupied.insert(Int(p.y / 12) * 10_000 + Int(p.x / 12)) }
        var state: UInt64 = 42
        func random() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) }
        let psf = 1.3, bins: [Float] = [1, 2, 4, 8, 16]
        var injected: [(point: SIMD2<Double>, peak: Float, bin: Int)] = []
        while injected.count < 500 {
            let p = SIMD2(40 + random() * Double(w - 80), 40 + random() * Double(h - 80))
            let cell = Int(p.y / 12) * 10_000 + Int(p.x / 12)
            guard probability[Int(p.y) * w + Int(p.x)] > 0.98, !occupied.contains(cell) else { continue }
            occupied.insert(cell)
            let bin = injected.count % bins.count
            injected.append((p, bins[bin] * noise, bin))
        }
        // Every photo, developed, with the stars added where its sky puts them, written as a float TIFF.
        let folder = output.appendingPathComponent("injected", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for i in analyzer.urls.indices {
            try autoreleasepool {
                let frame = try HDRMergeDecoder.decode(analyzer.urls[i], metadata: analyzer.metadata[i].base, longEdge: nil, whiteBalance: analyzer.whiteBalance, context: analyzer.context)
                var rgb = [Float](repeating: 0, count: w * h * 3)
                for p in 0..<(w * h) { for c in 0..<3 { rgb[p * 3 + c] = frame.pixels[p * 4 + c] } }
                for star in injected {
                    // Reference pixels to this photo's, through the analysis-size alignment.
                    let a = (star.point + 0.5) / scale - 0.5
                    let source = ((i == analyzer.anchor ? a : analyzer.alignments[i]?.sourcePoint(a) ?? a) + 0.5) * scale - 0.5
                    let amplitude = star.peak / analyzer.gains[i]
                    for dy in -5...5 { for dx in -5...5 {
                        let x = Int(source.x.rounded()) + dx, y = Int(source.y.rounded()) + dy
                        guard x >= 0, y >= 0, x < w, y < h else { continue }
                        let d2 = pow(Double(x) - source.x, 2) + pow(Double(y) - source.y, 2)
                        let v = amplitude * Float(exp(-d2 / (2 * psf * psf)))
                        for c in 0..<3 { rgb[(y * w + x) * 3 + c] += v }
                    }}
                }
                let url = folder.appendingPathComponent(String(format: "%02d.tif", i))
                let provider = CGDataProvider(data: rgb.withUnsafeBufferPointer { Data(buffer: $0) } as CFData)!
                let image = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 96, bytesPerRow: w * 12, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                let original = CGImageSourceCreateWithURL(analyzer.urls[i] as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary as String: original[kCGImagePropertyExifDictionary as String] ?? [:]] as CFDictionary)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                written.append(url)
            }
        }
        let denoiser = try NightSkyDenoiser(urls: written)
        let analysis = try denoiser.analyze()
        var injectedSettings = NightSkyDenoiseSettings(); injectedSettings.excluded = analysis.suggestedExclusions; injectedSettings.reference = reference
        let stack = try denoiser.render(injectedSettings, engine: .gpu)
        let ls = luminance(stack.rgba), lc = luminance(cleanStack.rgba)
        let single = luminance(try HDRMergeDecoder.decode(written[reference], metadata: denoiser.internalAnalyzer.metadata[reference].base, longEdge: nil,
                                                          whiteBalance: denoiser.internalAnalyzer.whiteBalance, context: denoiser.internalAnalyzer.context).pixels)
        // Forced photometry at the known places: flux above the local ring, against the clean stack's.
        func aperture(_ l: [Float], _ p: SIMD2<Double>) -> Double {
            let x = Int(p.x.rounded()), y = Int(p.y.rounded())
            var core = 0.0, ring = 0.0, n = 0.0
            for dy in -3...3 { for dx in -3...3 { core += Double(l[(y + dy) * w + x + dx]) } }
            for dy in -7...7 { for dx in -7...7 where max(abs(dx), abs(dy)) >= 5 { ring += Double(l[(y + dy) * w + x + dx]); n += 1 } }
            return core - 49 * ring / n
        }
        // Detection as the star finder judges it: the high-pass peak (luminance minus its 13-pixel mean) against the local
        // noise, the median absolute deviation of the high-pass in the surrounding 64-pixel tile. Crowding by faint real
        // stars barely moves that median, so this measures noise, not confusion.
        func significance(_ l: [Float]) -> (SIMD2<Double>) -> Double {
            let background = HDRMerger.boxBlur(l, width: w, height: h, radius: 6)
            let high = zip(l, background).map { $0 - $1 }
            var tiles: [Int: Double] = [:]
            return { p in
                let x = Int(p.x.rounded()), y = Int(p.y.rounded()), key = (y / 64) * 1000 + x / 64
                let noise = tiles[key] ?? {
                    var values: [Double] = []
                    for yy in stride(from: (y / 64) * 64, to: min(h, (y / 64) * 64 + 64), by: 2) {
                        for xx in stride(from: (x / 64) * 64, to: min(w, (x / 64) * 64 + 64), by: 2) { values.append(Double(high[yy * w + xx])) }
                    }
                    let m = NightSkyStars.median(values)
                    let n = max(1e-9, 1.4826 * NightSkyStars.median(values.map { abs($0 - m) }))
                    tiles[key] = n
                    return n
                }()
                var peak = -Double.infinity
                for dy in -1...1 { for dx in -1...1 { peak = max(peak, Double(high[(y + dy) * w + x + dx])) } }
                return peak / noise
            }
        }
        let stackSignificance = significance(ls), singleSignificance = significance(single)
        let total = 2 * Double.pi * psf * psf
        for (k, level) in bins.enumerated() {
            let members = injected.filter { $0.bin == k }
            let recovered = NightSkyStars.median(members.map { (aperture(ls, $0.point) - aperture(lc, $0.point)) / (Double($0.peak) * total) })
            let inStack = Double(members.filter { stackSignificance($0.point) > 5 }.count) / Double(members.count)
            let inSingle = Double(members.filter { singleSignificance($0.point) > 5 }.count) / Double(members.count)
            print("RESULT injected peak \(Int(level))σ of one photo's noise: flux recovered \(String(format: "%.3f", recovered)), found at 5σ in the stack \(Int((inStack * 100).rounded()))%, in one photo \(Int((inSingle * 100).rounded()))%")
            XCTAssertEqual(recovered, 1, accuracy: 0.1, "flux at \(level)σ")
            XCTAssertGreaterThanOrEqual(inStack + 0.02, inSingle, "stacking shouldn't lose sources at \(level)σ")
        }
        // False stars: local maxima at 5σ in one half-stack that the other half doesn't show at 2.5σ, by significance.
        let plan = try denoiser.plan(injectedSettings), members = plan.sky.sorted()
        func half(_ parity: Int) throws -> [Float] {
            var halfPlan = plan; halfPlan.sky = Set(members.enumerated().filter { $0.offset % 2 == parity }.map(\.element))
            return luminance(try denoiser.internalAnalyzer.render(halfPlan, engine: .gpu, progress: { _, _ in }).rgba)
        }
        let la = try half(0), lb = try half(1)
        let sa = significance(la), sb = significance(lb)
        let blurA = HDRMerger.boxBlur(la, width: w, height: h, radius: 6)
        var found: [(Double, Bool)] = []
        // The central region, where the sky is deep and well covered by both halves.
        for y in stride(from: h / 4, to: 3 * h / 4, by: 1) { for x in stride(from: w / 4, to: 3 * w / 4, by: 1) where probability[y * w + x] > 0.98 {
            let i = y * w + x, v = la[i] - blurA[i]
            guard v > la[i - 1] - blurA[i - 1], v > la[i + 1] - blurA[i + 1], v > la[i - w] - blurA[i - w], v > la[i + w] - blurA[i + w] else { continue }
            let p = SIMD2(Double(x), Double(y)), z = sa(p)
            guard z > 5 else { continue }
            found.append((z, sb(p) > 2.5))
        }}
        for (name, range) in [("5–7σ", 5.0..<7.0), ("7–10σ", 7.0..<10.0), ("over 10σ", 10.0..<Double.infinity)] {
            let group = found.filter { range.contains($0.0) }
            let unmatched = Double(group.filter { !$0.1 }.count) / Double(max(1, group.count))
            print("RESULT half-stack sources at \(name): \(group.count), \(String(format: "%.1f", unmatched * 100))% not confirmed by the other half")
            if range.lowerBound >= 10 { XCTAssertLessThan(unmatched, 0.02, "bright false stars") }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The design's aurora tests on a star-trail sequence: literal maximum over everything and over the photos not
    /// suggested for leaving out (night only), one photo's sky with and without filled pauses, and the per-photo quality
    /// decisions. Writes each preview and the night-only maximum at full size.
    func testStarTrailVariantsOnSamples() throws {
        let (urls, output) = try samples()
        var start = Date()
        func lap(_ name: String) { print("RESULT \(name) \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); start = Date() }
        let merger = try StarTrailsMerger(urls: urls)
        let analysis = try merger.analyze()
        lap("analysis of \(urls.count) photos")
        if let timing = analysis.timing {
            print("RESULT span \(Int(timing.span)) s, usual interval \(String(format: "%.0f", timing.interval)) s, \(timing.gaps) longer pauses")
        }
        var notes: [String: [String]] = [:]
        for frame in analysis.frames { if let note = frame.note { notes[note.text, default: []].append(frame.filename) } }
        for (note, files) in notes.sorted(by: { $0.key < $1.key }) {
            print("RESULT \(files.count) flagged — \(note): \(files.prefix(12).joined(separator: ", "))\(files.count > 12 ? ", …" : "")")
        }
        print("RESULT lines \(analysis.lines.count): \(analysis.lines.filter { $0.kind == .meteor }.count) meteor-like, \(analysis.lines.filter { $0.kind == .track }.count) tracks, \(analysis.lines.filter { $0.kind == .shake }.count) shake")
        var settings = StarTrailsSettings()
        func save(_ name: String) throws {
            let preview = try merger.preview(settings)
            lap("preview \(name)")
            Self.save(preview.image, output.appendingPathComponent("trails-\(name).png"))
        }
        try save("brightest-all")
        settings.excluded = analysis.suggestedExclusions
        try save("brightest-night-only")
        settings.sky = .onePhoto
        try save("one-photo")
        settings.fillGaps = true
        print("RESULT \(merger.filledGaps(settings)) pauses drawn in")
        try save("one-photo-gaps")
        settings = StarTrailsSettings(); settings.excluded = analysis.suggestedExclusions
        let dng = output.appendingPathComponent("trails-night-only.dng")
        try? FileManager.default.removeItem(at: dng)
        try merger.merge(settings, to: dng)
        lap("full-size night-only maximum and DNG")
    }
}
