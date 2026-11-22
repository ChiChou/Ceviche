import XCTest
import CoreImage
import Metal
import simd
@testable import CevicheCore

/// Times the film print on a synthetic scene, through the renderer the editor and the export use:
/// CEVICHE_FILM_BENCH=1 prints a table, and CEVICHE_FILM_BENCH_OUT names a JSON file the rows are written to.
/// CEVICHE_FILM_BENCH_SIZES ("1500x1000,6000x4000") and CEVICHE_FILM_BENCH_FILMS ("portra400,trix400:screen") narrow it.
final class FilmBenchmarkTests: XCTestCase {
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])

    /// A scene with what the film's stages each respond to: a tonal ramp, colored patches, fine texture and a few
    /// small lights well above white for the halation. Held as a bitmap, so a render pays for the film alone.
    static func scene(width: Int, height: Int) -> [Float] {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                var state = UInt32(truncatingIfNeeded: y &* 2654435761) | 1
                let v = Float(y) / Float(height)
                for x in 0..<width {
                    state = state &* 747796405 &+ 2891336453
                    let noise = Float(state >> 8) / 16777216
                    let u = Float(x) / Float(width)
                    let ramp = 0.01 * powf(2, 9 * u)
                    let patch = SIMD3<Float>(0.5 + 0.5 * sinf(u * 40), 0.5 + 0.5 * sinf(v * 30 + 1), 0.5 + 0.5 * sinf((u + v) * 25 + 2))
                    var color = ramp * (0.6 + 0.4 * patch) * (0.9 + 0.2 * noise)
                    let cell = SIMD2(Float(x % 512) - 256, Float(y % 512) - 256)
                    if simd_length(cell) < 6 { color = SIMD3(40, 32, 20) }
                    let i = (y * width + x) * 4
                    p[i] = color.x; p[i + 1] = color.y; p[i + 2] = color.z
                }
            }
        }
        return pixels
    }
    private func image(_ pixels: [Float], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }

    func testTimeFilmPrint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CEVICHE_FILM_BENCH"] == "1" else { throw XCTSkip("Set CEVICHE_FILM_BENCH=1") }
        try XCTSkipUnless(FilmCatalog.shared.isAvailable)
        let sizes = (environment["CEVICHE_FILM_BENCH_SIZES"] ?? "1500x1000,3000x2000,6000x4000,8192x5464").split(separator: ",").compactMap { text -> (Int, Int)? in
            let parts = text.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let films = (environment["CEVICHE_FILM_BENCH_FILMS"] ?? "portra400,portra400:screen,vision500t,velvia50,trix400").split(separator: ",").map { text -> (String, String?) in
            let parts = text.split(separator: ":").map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }
        var rows: [[String: Any]] = []
        func record(_ what: String, _ film: String, _ size: (Int, Int), _ seconds: [Double]) {
            let sorted = seconds.sorted(), median = sorted[sorted.count / 2]
            print(String(format: "bench %-10@ %-22@ %5dx%-5d  %8.1f ms  (min %.1f, max %.1f, n=%d)", what as NSString, film as NSString, size.0, size.1,
                         median * 1000, sorted[0] * 1000, sorted[sorted.count - 1] * 1000, sorted.count))
            rows.append(["what": what, "film": film, "width": size.0, "height": size.1, "ms": median * 1000, "min": sorted[0] * 1000, "max": sorted[sorted.count - 1] * 1000])
        }
        // The first render of a film builds its tables and whatever the engine compiles: timed apart, small.
        for (stock, medium) in films {
            var settings = FilmSimulation(stock: stock); settings.medium = medium
            let name = stock + (medium.map { ":" + $0 } ?? "")
            let (w, h) = (750, 500), small = image(Self.scene(width: w, height: h), width: w, height: h)
            var out = [Float](repeating: 0, count: w * h * 4)
            let start = Date()
            out.withUnsafeMutableBytes { context.render(FilmSimulationRenderer().apply(settings, to: small), toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: small.extent, format: .RGBAf, colorSpace: nil) }
            record("first", name, (w, h), [Date().timeIntervalSince(start)])
        }
        for (w, h) in sizes {
            let scene = Self.scene(width: w, height: h), source = image(scene, width: w, height: h)
            var out = [Float](repeating: 0, count: w * h * 4)
            for (stock, medium) in films {
                var settings = FilmSimulation(stock: stock); settings.medium = medium
                let name = stock + (medium.map { ":" + $0 } ?? "")
                func render(_ settings: FilmSimulation) -> Double {
                    autoreleasepool {
                        let start = Date()
                        out.withUnsafeMutableBytes { context.render(FilmSimulationRenderer().apply(settings, to: source), toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: source.extent, format: .RGBAf, colorSpace: nil) }
                        return Date().timeIntervalSince(start)
                    }
                }
                _ = render(settings)
                let runs = w * h > 20_000_000 ? 3 : 5
                record("develop", name, (w, h), (0..<runs).map { _ in render(settings) })
                // A print control moved a step at a time, as a slider drags: each step is a development the engine has
                // not seen.
                if w * h <= 8_000_000 {
                    record("step", name, (w, h), (1...runs).map { step in var moved = settings; moved.printExposure = Double(step) * 0.07; moved.magenta = Double(step); return render(moved) })
                }
            }
            // A scanned negative printed on paper.
            let base = SIMD3<Float>(0.8, 0.45, 0.25)
            var scan = scene
            for i in stride(from: 0, to: scan.count, by: 4) { for c in 0..<3 { scan[i + c] = base[c] * powf(10, -min(2.2, 0.25 * log2f(1 + 8 * scan[i + c]))) } }
            var settings = FilmSimulation(stock: "portra400"); settings.grain = 0
            let runs = w * h > 20_000_000 ? 2 : 4
            record("print-scan", "portra400", (w, h), (0..<runs).map { _ in
                // Timed on its own: an assertion handed the picture itself would box every float of it.
                let start = Date()
                let printed = FilmSimulationRenderer.print(scan: scan, width: w, height: h, base: base, settings: settings)
                let seconds = Date().timeIntervalSince(start)
                XCTAssertTrue(printed != nil)
                return seconds
            })
        }
        if let path = environment["CEVICHE_FILM_BENCH_OUT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }
}
