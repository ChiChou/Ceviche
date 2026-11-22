import XCTest
import simd
@testable import CevicheCore

final class PanoramaBlendTests: XCTestCase {
    /// The CPU blend, for Macs without a usable GPU, is the GPU's arithmetic: two overlapping textured photos agree.
    func testCPUBlendMatchesGPU() throws {
        let width = 320, height = 240
        func frame(_ shift: Double) -> PanoramaFrame {
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let u = Double(x) + shift, v = Double(y)
                let value = Float(0.3 + 0.2 * sin(u / 9) * cos(v / 7) + (Int(u / 40) % 2 == 0 ? 0.1 : 0))
                for c in 0..<3 { pixels[(y * width + x) * 4 + c] = value * Float(1 - 0.1 * Double(c)) }
            }}
            return PanoramaFrame(width: width, height: height, pixels: pixels)
        }
        let camera = PanoramaCamera(width: Double(width), height: Double(height), focal: 300)
        let angle = atan(100.0 / 300)
        let rotations = [matrix_identity_double3x3, simd_double3x3(simd_quatd(angle: angle, axis: SIMD3(0, 1, 0)))]
        let frames = [frame(0), frame(100)]
        for projection in PanoramaProjection.allCases {
            let layout = try XCTUnwrap(PanoramaLayout(cameras: [camera, camera], rotations: rotations, members: [0, 1], projection: projection, focal: 297.3, maxPixels: 1e6))
            let gpu = PanoramaCompositor()
            guard gpu.device != nil else { throw XCTSkip("No GPU") }
            let cpu = PanoramaCompositor(useGPU: false)
            func render(_ compositor: PanoramaCompositor) throws -> PanoramaRaster {
                try compositor.render(layout: layout, cameras: [camera, camera], rotations: rotations, gains: [1, 1.1], frames: [0, 1],
                                      texture: { try compositor.texture(frames[$0]) }, progress: { _ in }, cancelled: { false })
            }
            let a = try render(gpu), b = try render(cpu)
            var total: Float = 0, worst: Float = 0, covered = 0, edges = 0
            for i in stride(from: 0, to: a.rgba.count, by: 4) where a.rgba[i + 3] > 0 || b.rgba[i + 3] > 0 {
                // Float on the GPU, double on the CPU: a pixel exactly on a photo's edge can fall either way.
                guard a.rgba[i + 3] > 0, b.rgba[i + 3] > 0 else { edges += 1; continue }
                for c in 0..<3 { let d = abs(a.rgba[i + c] - b.rgba[i + c]); total += d; worst = max(worst, d) }
                covered += 1
            }
            XCTAssertGreaterThan(covered, width * height)
            XCTAssertLessThan(edges, 20, "\(projection)")
            // The CPU approximates the Gaussian low band with box passes; the mean difference is rounding-sized.
            XCTAssertLessThan(total / Float(covered * 3), 2e-3, "\(projection)")
            XCTAssertLessThan(worst, 0.06, "\(projection)")
        }
    }
}
