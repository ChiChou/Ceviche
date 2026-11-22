import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class RenderingMethodTests: XCTestCase {
    private let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    private func render(_ colors: [SIMD3<Double>], _ transform: (CIImage) -> CIImage) -> [SIMD3<Double>] {
        var data = [Float]()
        for c in colors { data += [Float(c.x), Float(c.y), Float(c.z), 1] }
        let image = CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: colors.count * 16, size: CGSize(width: colors.count, height: 1), format: .RGBAf, colorSpace: nil)
        let out = transform(image)
        var result = [Float](repeating: 0, count: colors.count * 4)
        result.withUnsafeMutableBytes { context.render(out, toBitmap: $0.baseAddress!, rowBytes: colors.count * 16, bounds: CGRect(x: 0, y: 0, width: colors.count, height: 1), format: .RGBAf, colorSpace: nil) }
        return colors.indices.map { SIMD3(Double(result[$0 * 4]), Double(result[$0 * 4 + 1]), Double(result[$0 * 4 + 2])) }
    }

    func testACESTableIsBundledAndTheGPUMatchesIt() throws {
        let colors: [SIMD3<Double>] = [SIMD3(repeating: 0.18), SIMD3(repeating: 0.02), SIMD3(repeating: 4), SIMD3(0.5, 0.1, 0.05), SIMD3(0.05, 0.3, 0.1), SIMD3(0.04, 0.08, 0.6)]
        let gpu = render(colors, ACESRenderer.apply)
        for (color, measured) in zip(colors, gpu) {
            let expected = ACESRenderer.render(color)
            for c in 0..<3 { XCTAssertEqual(measured[c], expected[c], accuracy: 0.002 + abs(expected[c]) * 0.01, "\(color) channel \(c)") }
        }
    }

    /// ACES 2's tone scale: neutrals stay neutral, mid gray lands well below white, and highlights roll off below it.
    func testACESToneScale() throws {
        let gray = ACESRenderer.render(SIMD3(repeating: 0.18))
        XCTAssertEqual(gray.x, gray.z, accuracy: 0.003)
        XCTAssertGreaterThan(gray.y, 0.05); XCTAssertLessThan(gray.y, 0.2)
        let bright = ACESRenderer.render(SIMD3(repeating: 16))
        XCTAssertGreaterThan(bright.y, gray.y * 4); XCTAssertLessThanOrEqual(bright.y, 1.001)
        let darker = ACESRenderer.render(SIMD3(repeating: 0.09))
        XCTAssertLessThan(darker.y, gray.y)
    }

    func testGlowSpreadsHighlightsAndLeavesDimPhotosAlone() {
        let size = 200
        var data = [Float](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) { data[i * 4] = 0.05; data[i * 4 + 1] = 0.05; data[i * 4 + 2] = 0.05; data[i * 4 + 3] = 1 }
        for y in 95..<105 { for x in 95..<105 { let o = (y * size + x) * 4; data[o] = 8; data[o + 1] = 8; data[o + 2] = 8 } }
        let image = CIImage(bitmapData: data.withUnsafeBytes { Data($0) }, bytesPerRow: size * 16, size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: nil)
        func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> SIMD4<Float> {
            var p = [Float](repeating: 0, count: 4)
            p.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return SIMD4(p[0], p[1], p[2], p[3])
        }
        let glowed = GlowRenderer.apply(Glow(), to: image)
        XCTAssertEqual(glowed.extent, image.extent)
        XCTAssertGreaterThan(pixel(glowed, 100, 115).x, 0.06, "the halo reaches past the source")
        XCTAssertEqual(pixel(glowed, 5, 5).x, 0.05, accuracy: 0.005, "far away stays as it was")
        XCTAssertEqual(pixel(glowed, 100, 115).w, 1, accuracy: 0.001)
        var off = Glow(); off.enabled = false
        XCTAssertTrue(GlowRenderer.apply(off, to: image) === image)
    }

    func testRenderingFollowsTheFilmThenACES() throws {
        var a = Adjustments()
        XCTAssertEqual(a.rendering, .camera)
        a.aces = true
        XCTAssertEqual(a.rendering, .aces)
        a.film = FilmSimulation()
        // A build without the film engine leaves the film's settings on the photo and renders without it.
        XCTAssertEqual(a.rendering, FilmCatalog.shared.isAvailable ? .film : .aces)
        a.film?.enabled = false
        XCTAssertEqual(a.rendering, .aces)
        let decoded = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded, a)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Adjustments()), as: UTF8.self).contains("\"aces\""))
    }
}
