import XCTest
import CevicheTestSupport
import CoreImage
import CoreML
@testable import CevicheCore

/// The tiling around NAFNet. The model's channel attention averages each tile as a whole, so its tiles come out with
/// slightly different casts; a fake network with a cast of its own per tile stands in for it where the model is absent.
final class NAFNetTilesTests: XCTestCase {
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9; z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
    /// A dark night sky with noise, a faint gradient and a bright window frame down the left, as linear RGBA rows top
    /// down, at values a half float holds exactly.
    private func sky(width: Int, height: Int) -> [Float] {
        var random = Random(state: 7)
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let frame = x < width / 4 ? Float(0.25) : 0
                let base: [Float] = [0.012, 0.016, 0.014].map { $0 * (1 + 0.3 * Float(y) / Float(height)) + frame }
                for c in 0..<3 {
                    let noise = (Float.random(in: -1...1, using: &random) + Float.random(in: -1...1, using: &random)) * 0.004
                    pixels[(y * width + x) * 4 + c] = Float(Float16(base[c] + noise))
                }
            }
        }
        return pixels
    }
    /// Casts the tile by an amount that depends on what the tile holds, like the model's.
    private func castingNetwork(_ input: MLMultiArray) throws -> MLMultiArray {
        let count = input.count, values = input.dataPointer.assumingMemoryBound(to: Float.self)
        let output = try MLMultiArray(shape: input.shape, dataType: .float32)
        let result = output.dataPointer.assumingMemoryBound(to: Float.self), plane = count / 3
        var sum = 0.0
        for i in stride(from: 0, to: count, by: 97) { sum += Double(values[i]) }
        for c in 0..<3 {
            let cast = Float(0.004 * sin(sum * 37 + Double(c) * 2))
            for i in (c * plane)..<((c + 1) * plane) { result[i] = NAFNetTiles.encode(NAFNetTiles.decode(values[i]) + cast) }
        }
        return output
    }
    private func run(_ source: inout [Float], width: Int, height: Int, region: (x: Int, y: Int, width: Int, height: Int)? = nil,
                     network: @escaping NAFNetTiles.Network, lanes: Int = 1) throws -> [Float] {
        let region = region ?? (0, 0, width, height)
        var target = [Float](repeating: 0, count: region.width * region.height * 4)
        try source.withUnsafeMutableBufferPointer { source in
            try target.withUnsafeMutableBufferPointer { target in
                try NAFNetTiles.run(NAFNetTiles.Pixels(base: source.baseAddress!, rowLength: width * 4, x: 0, y: 0, width: width, height: height),
                                    into: NAFNetTiles.Pixels(base: target.baseAddress!, rowLength: region.width * 4, x: region.x, y: region.y, width: region.width, height: region.height),
                                    networks: Array(repeating: network, count: lanes))
            }
        }
        return target
    }
    /// The largest step between neighbouring 16-column means of `after − before` over the dark part, per unit of the
    /// sky's level: a tile's cast shows as a step where the tiles meet.
    private func seam(_ before: [Float], _ after: [Float], width: Int, height: Int) -> Float {
        var worst: Float = 0
        for c in 0..<3 {
            var means: [Float] = [], level: Float = 0
            for x0 in stride(from: width / 4 + 32, to: width - 16, by: 16) {
                var sum: Float = 0
                for y in 0..<height { for x in x0..<(x0 + 16) { let i = (y * width + x) * 4 + c; sum += after[i] - before[i]; level += before[i] } }
                means.append(sum / Float(16 * height))
            }
            level /= Float(means.count * 16 * height)
            worst = max(worst, zip(means.dropFirst(), means).map { abs($0 - $1) }.max()! / level)
        }
        return worst
    }

    func testWeightsAddUpToOneWhereTilesOverlap() {
        let weights = NAFNetTiles.weights, step = NAFNetTiles.step
        for t in 0..<NAFNetTiles.overlap { XCTAssertEqual(weights[step + t] + weights[t], 1, accuracy: 1e-5) }
        // Pixel 0 lies in tile 0's margin, so only the tile before reaches it.
        XCTAssertEqual(NAFNetTiles.tiles(0..<1), -1...(-1))
        XCTAssertEqual(NAFNetTiles.tiles(0..<200), -1...0)
        XCTAssertEqual(NAFNetTiles.reach(0..<1), -step..<(NAFNetTiles.tile - step))
    }

    func testCastPerTileLeavesNoSeams() throws {

        try TestTier.requireSlow()
        let width = 1100, height = 700
        var source = sky(width: width, height: height)
        let result = try run(&source, width: width, height: height, network: castingNetwork)
        let error = zip(result, source).map { abs($0 - $1) }.max()!
        // Without the coarse change taken out, each tile would be lifted by its whole cast, up to 0.004.
        XCTAssertLessThan(error, 2e-4)
        XCTAssertLessThan(seam(source, result, width: width, height: height), 0.01)
    }

    /// Core Image renders whatever regions it likes, and the lanes take tiles in any order; each pixel comes out the same.
    func testRegionsMatchTheWholeFrame() throws {
        try TestTier.requireSlow()
        let width = 900, height = 640
        var source = sky(width: width, height: height)
        let whole = try run(&source, width: width, height: height, network: castingNetwork)
        // Two lanes take the tiles in whatever order they finish.
        let laned = try run(&source, width: width, height: height, network: castingNetwork, lanes: 2)
        XCTAssertLessThan(zip(whole, laned).map { abs($0 - $1) }.max()!, 1e-6)
        for region in [(x: 0, y: 0, width: 333, height: 401), (x: 333, y: 401, width: 567, height: 239), (x: 517, y: 13, width: 101, height: 77)] {
            let part = try run(&source, width: width, height: height, region: region, network: castingNetwork)
            for y in 0..<region.height {
                for x in 0..<(region.width * 4) {
                    XCTAssertEqual(part[y * region.width * 4 + x], whole[((region.y + y) * width + region.x) * 4 + x], accuracy: 1e-6)
                }
            }
        }
    }

    /// With the model: Core Image's processor, rendered in two bands, puts the grid where the in-memory frame does.
    func testCoreImageMatchesTheFrameInMemory() throws {
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        let width = 700, height = 560
        let pixels = sky(width: width, height: height)
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        let context = PhotoDenoiser.context()
        let memory = try PhotoDenoiser.denoised(image, width: width, height: height, strength: 100, exposure: 0, context: context)
        let denoised = try NAFNetDenoiseKernel.apply(to: image)
        var rendered = [Float](repeating: 0, count: width * height * 4)
        rendered.withUnsafeMutableBytes { bytes in
            for (top, rows) in [(0, 237), (237, height - 237)] {
                context.render(denoised, toBitmap: bytes.baseAddress! + top * width * 16, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: height - top - rows, width: width, height: rows), format: .RGBAf, colorSpace: PanoramaDecoder.space)
            }
        }
        var worst: Float = 0
        for i in stride(from: 0, to: rendered.count, by: 4) { for c in 0..<3 { worst = max(worst, abs(rendered[i + c] - memory[i + c])) } }
        // Each lane takes whichever tile is next, and the Neural Engine's and the GPU's results for a tile differ by up to
        // about 1e-3 here (2e-4 on the sky, more on the frame), so the two runs differ by that much. A grid misplaced
        // by a row, or counted from the bottom, differs by over 1e-2.
        XCTAssertLessThan(worst, 2e-3)
    }

    /// With the model: on a dark sky beside a bright frame, the casts of tiles cut side by side show as steps; the
    /// cross-faded tiles leave far smaller ones.
    func testModelLeavesNoSeamsOnADarkSky() throws {
        try TestTier.requireSlow()
        guard BundledModel.denoise.isAvailable else { throw XCTSkip("NAFNet model not installed") }
        let width = 1600, height = 900
        var source = sky(width: width, height: height)
        let networks = try NAFNetTiles.networks()
        let result = try run(&source, width: width, height: height, network: networks[0])
        // The tiling this replaced: 512-pixel tiles 448 apart, each keeping its middle as it came out.
        var plain = source
        let tile = NAFNetTiles.tile, context = 32, core = tile - 2 * context
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float32)
        let values = input.dataPointer.assumingMemoryBound(to: Float.self), plane = tile * tile
        for top in stride(from: 0, to: height, by: core) {
            for left in stride(from: 0, to: width, by: core) {
                for ty in 0..<tile { for tx in 0..<tile {
                    let sx = min(width - 1, max(0, left - context + tx)), sy = min(height - 1, max(0, top - context + ty))
                    for c in 0..<3 { values[c * plane + ty * tile + tx] = NAFNetTiles.encode(source[(sy * width + sx) * 4 + c]) }
                } }
                let output = try networks[0](input)
                for y in top..<min(height, top + core) { for x in left..<min(width, left + core) {
                    for c in 0..<3 {
                        let i = (y * width + x) * 4 + c
                        let value = output[[0, NSNumber(value: c), NSNumber(value: y - top + context), NSNumber(value: x - left + context)]].floatValue
                        plain[i] = source[i] + NAFNetTiles.decode(value) - min(1, max(0, source[i]))
                    }
                } }
            }
        }
        let before = seam(source, plain, width: width, height: height), after = seam(source, result, width: width, height: height)
        XCTAssertLessThan(after, before / 2.5)
    }

    /// Measured strength leaves about two display levels of the noise taken out: none on a clean photo, most on a noisy one.
    func testMeasuredStrengthFollowsNoise() {
        var random = Random(state: 7)
        func strength(sigma levels: Float) -> Double {
            let count = 200_000
            var before = [Float16](repeating: 1, count: count * 4), after = [Float](repeating: 1, count: count * 4)
            for p in 0..<count {
                // Mid-grey, 0.5 encoded; noise added in encoded levels and taken back to linear.
                let u1 = max(1e-9, Float(random.next() % 1_000_000) / 1_000_000), u2 = Float(random.next() % 1_000_000) / 1_000_000
                let encoded = 0.5 + levels / 255 * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
                let linear = pow((min(1, max(0, encoded)) + 0.055) / 1.055, 2.4), clean = pow(Float(0.5 + 0.055) / 1.055, 2.4)
                for c in 0..<3 { before[p * 4 + c] = Float16(linear); after[p * 4 + c] = clean }
            }
            return before.withUnsafeBufferPointer { b in after.withUnsafeBufferPointer { a in PhotoDenoiser.measuredStrength(before: b, after: a) } }
        }
        XCTAssertEqual(strength(sigma: 0), 40)
        XCTAssertEqual(strength(sigma: 1), 40)
        XCTAssertEqual(strength(sigma: 8), 75, accuracy: 4)
        XCTAssertEqual(strength(sigma: 20), 90, accuracy: 3)
    }
}
