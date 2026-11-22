import XCTest
import Metal
import ImageIO
import UniformTypeIdentifiers
import CevicheTestSupport
@testable import CevicheCore

final class FocusStackInspectionTests: XCTestCase {
    private func renderer() throws -> FocusStackInspectionRenderer {
        try TestTier.requireSlow("Metal focus inspection")
        return try FocusStackInspectionRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }
    private func samples(_ field: FocusStackInspection) -> [SIMD2<Float>] {
        var values = [SIMD2<Float>](repeating: .zero, count: field.field.width * field.field.height)
        values.withUnsafeMutableBytes { bytes in
            field.field.getBytes(bytes.baseAddress!, bytesPerRow: field.field.width * 8,
                                 from: MTLRegionMake2D(0, 0, field.field.width, field.field.height), mipmapLevel: 0)
        }
        return values
    }

    func testGPUFocusEvidenceCropAndExcludedFrames() throws {
        let gpu = try renderer()
        let focus: [[Float]] = [
            [5, 3, 0.2, -.infinity, 2, 4],
            [1, 3, 0.1, -.infinity, 8, 2],
            [0, 1, 0.0, -.infinity, 2, 9]
        ]
        let full = try gpu.measure(focus: focus, included: [0, 1, 2], width: 3, height: 2,
                                   outputWidth: 3, outputHeight: 2, offset: .zero, scale: 1)
        let values = samples(full)
        XCTAssertEqual(values[0], SIMD2(0, 1))
        XCTAssertEqual(values[1], SIMD2(0, 0)) // Sharp but tied: low confidence, stable first winner.
        XCTAssertEqual(values[2], SIMD2(-1, 0)) // All blurry.
        XCTAssertEqual(values[3], SIMD2(-1, 0)) // No coverage.
        XCTAssertEqual(values[4], SIMD2(0.5, 1))
        XCTAssertEqual(values[5], SIMD2(1, 1))
        let cropped = try gpu.measure(focus: focus, included: [0, 2], width: 3, height: 2,
                                      outputWidth: 2, outputHeight: 1, offset: SIMD2(1, 1), scale: 1)
        XCTAssertEqual(samples(cropped), [SIMD2(0, 0), SIMD2(1, 1)])
        // Excluding the middle frame keeps original capture positions instead of renumbering depth.
        let middle = try gpu.measure(focus: focus, included: [1, 2], width: 3, height: 2,
                                     outputWidth: 1, outputHeight: 1, offset: SIMD2(1, 1), scale: 1)
        XCTAssertEqual(samples(middle), [SIMD2(0.5, 1)])
    }

    func testGPUOverlayAndReliefRendering() throws {
        let gpu = try renderer(), w = 160, h = 100, count = 9
        var focus = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: count)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let p = y * w + x
            let depth = 0.2 + 0.55 * Float(x) / Float(w) + 0.15 * sin(Float(y) * 0.07)
            for i in 0..<count {
                let delta = Float(i) / Float(count - 1) - depth
                focus[i][p] = (x < 18 && y < 25) ? 0.2 : 6 - 48 * delta * delta
            }
            pixels[p * 4] = UInt8(80 + x)
            pixels[p * 4 + 1] = UInt8(90 + y)
            pixels[p * 4 + 2] = UInt8((x / 8 + y / 8) % 2 == 0 ? 160 : 100)
        }}
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let field = try gpu.measure(focus: focus, included: Array(0..<count), width: w, height: h,
                                    outputWidth: w, outputHeight: h, offset: .zero, scale: 1)
        try gpu.setContent(inspection: field, image: image, sources: image)
        func render(_ mode: FocusStackInspectionMode, _ camera: FocusStackInspectionCamera = .init(), opacity: Float = 1) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 640, height: 400, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            let target = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
            let commands = try gpu.render(target: target, mode: mode, camera: camera, opacity: opacity)
            commands.commit(); commands.waitUntilCompleted(); XCTAssertNil(commands.error)
            var bytes = [UInt8](repeating: 0, count: 640 * 400 * 4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 400), mipmapLevel: 0) }
            return bytes
        }
        let base = try render(.image), depth = try render(.depth), confidence = try render(.confidence)
        XCTAssertNotEqual(base, depth); XCTAssertNotEqual(depth, confidence)
        XCTAssertEqual(try render(.depth, opacity: 0), base)
        let relief = try render(.relief)
        var rotated = FocusStackInspectionCamera(); rotated.yaw = 0.85
        let orbit = try render(.relief, rotated)
        XCTAssertNotEqual(relief, orbit)
        var flat = rotated; flat.relief = 0
        XCTAssertNotEqual(orbit, try render(.relief, flat))
        rotated.inverted = true
        let inverted = try render(.relief, rotated)
        XCTAssertNotEqual(inverted, orbit)
        XCTAssertEqual(try render(.relief), relief) // Stable camera, deterministic redraw.
        // Unknown top-left area is hatched in 2D and absent in the mesh.
        XCTAssertNotEqual(Array(depth[0..<4]), Array(depth[8 * 4..<8 * 4 + 4]))
        let missing = try gpu.measure(focus: [[Float](repeating: 0.2, count: w * h)], included: [0], width: w, height: h,
                                     outputWidth: w, outputHeight: h, offset: .zero, scale: 1)
        try gpu.setContent(inspection: missing, image: image, sources: image)
        let empty = try render(.relief)
        let clear = Array(empty[0..<4])
        for p in stride(from: 0, to: empty.count, by: 4) { XCTAssertEqual(Array(empty[p..<p + 4]), clear) }
        try gpu.setContent(inspection: field, image: image, sources: image)
        if let path = ProcessInfo.processInfo.environment["CEVICHE_FOCUS_INSPECTION_REVIEW"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, bytes) in [("image", base), ("depth", depth), ("confidence", confidence), ("relief", relief), ("orbit", orbit), ("inverted", inverted)] {
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let output = try XCTUnwrap(CGImage(width: 640, height: 400, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 640 * 4,
                                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, output, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
