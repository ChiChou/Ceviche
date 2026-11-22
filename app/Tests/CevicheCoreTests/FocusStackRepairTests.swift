import XCTest
import Metal
import CevicheTestSupport
@testable import CevicheCore

final class FocusStackRepairTests: XCTestCase {
    func testOldStrokesDecodeAndRepairRoundTrip() throws {
        let old = Data(#"{"x":0.3,"y":0.2,"radius":0.01,"photo":2,"add":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FocusStackStroke.self, from: old).repair)
        let repair = FocusStackStroke(x: 0.3, y: 0.2, radius: 0.01, photo: -1, add: true, selection: 1, repair: true)
        XCTAssertEqual(try JSONDecoder().decode(FocusStackStroke.self, from: JSONEncoder().encode(repair)), repair)
    }

    func testGPURepairsSpillAndProtectsForegroundAndUnpaintedPixels() throws {
        try TestTier.requireSlow("Metal edge repair")
        let w = 100, h = 80
        let gpu = try FocusStackRepairGPU(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var clean = [Float](repeating: 1, count: w * h * 4), halo = clean, soft = clean
        for y in 0..<h { for x in 0..<w {
            let k = (y * w + x) * 4, foreground = y >= 40
            let detail: Float = foreground && (x + y) % 2 == 0 ? 0.01 : 0
            let value: Float = foreground ? 0.35 + detail : 0.04
            let spill: Float = (!foreground && y > 29) ? Float(y - 29) * 0.005 : 0
            for c in 0..<3 {
                clean[k + c] = value; halo[k + c] = value + spill
                soft[k + c] = 0.04 + 0.31 * Float(max(0, min(20, y - 30))) / 20
            }
        } }
        let base = PanoramaRaster(width: w, height: h, rgba: halo)
        let dabs = stride(from: Float(24), through: 76, by: 2).map { SIMD4<Float>($0, 36, 16, 0) }
        let hints = try gpu.hints(base, dabs: dabs)
        let sharpScore = try gpu.score(proxy: FocusStackFocus.proxy(clean), width: w, height: h, dabs: dabs, hints: hints)
        let softScore = try gpu.score(proxy: FocusStackFocus.proxy(soft), width: w, height: h, dabs: dabs, hints: hints)
        XCTAssertGreaterThan(sharpScore, softScore * 2)
        let source = try XCTUnwrap(gpu.device.makeBuffer(bytes: clean, length: clean.count * 4, options: .storageModeShared))
        let result = try gpu.apply(base, source: source, dabs: dabs, hints: hints, scale: 1)
        XCTAssertEqual(result.rgba[(36 * w + 50) * 4], clean[(36 * w + 50) * 4], accuracy: 0.00001)
        var changed = 0
        for y in 0..<h { for x in 0..<w {
            let k = (y * w + x) * 4
            if y >= 42 || x < 8 || x > 92 || y < 20 || y > 52 { XCTAssertEqual(Array(result.rgba[k..<k + 4]), Array(halo[k..<k + 4])) }
            if result.rgba[k] != halo[k] { changed += 1 }
        } }
        XCTAssertGreaterThan(changed, 100)
        let flat = PanoramaRaster(width: w, height: h, rgba: [Float](repeating: 0.1, count: w * h * 4))
        let flatHints = try gpu.hints(flat, dabs: dabs)
        XCTAssertEqual(try gpu.score(proxy: FocusStackFocus.proxy(flat.rgba), width: w, height: h, dabs: dabs, hints: flatHints), 0)
        let flatSource = try XCTUnwrap(gpu.device.makeBuffer(bytes: flat.rgba, length: flat.rgba.count * 4, options: .storageModeShared))
        XCTAssertEqual(try gpu.apply(flat, source: flatSource, dabs: dabs, hints: flatHints, scale: 1).rgba, flat.rgba)
    }
}
