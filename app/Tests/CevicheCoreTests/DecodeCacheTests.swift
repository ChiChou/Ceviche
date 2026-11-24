import XCTest
import CevicheTestSupport
import CoreImage
import Metal
@testable import CevicheCore

final class DecodeCacheTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    func testWrittenDecodeReadsBackAtItsExtent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let folder = try XCTUnwrap(DecodeCache.folder)
        let file = folder.appendingPathComponent("test-\(UUID()).rgbah")
        defer { try? FileManager.default.removeItem(at: file) }
        let extent = CGRect(x: 4, y: 2, width: 64, height: 48)
        let source = CIImage(color: CIColor(red: 0.25, green: 1.5, blue: 0.004, colorSpace: space)!).cropped(to: extent)
        let image = try XCTUnwrap(DecodeCache.write(source, to: file, context: RawRenderer.makeContext(device, cacheIntermediates: false)))
        XCTAssertEqual(image.extent, extent)
        var pixel = [Float](repeating: 0, count: 4)
        RawRenderer.makeContext(device, cacheIntermediates: false).render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        XCTAssertEqual(pixel[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(pixel[1], 1.5, accuracy: 0.002)
        XCTAssertEqual(pixel[2], 0.004, accuracy: 0.0001)
        // A file of the wrong size is not a decode of this extent, and goes.
        XCTAssertNil(DecodeCache.read(file, extent: CGRect(x: 0, y: 0, width: 65, height: 48)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTrimRemovesTheLeastRecentlyUsedFirst() throws {
        let folder = try XCTUnwrap(DecodeCache.folder)
        let old = folder.appendingPathComponent("old-\(UUID()).rgbah"), recent = folder.appendingPathComponent("recent-\(UUID()).rgbah")
        defer { for url in [old, recent] { try? FileManager.default.removeItem(at: url) } }
        try Data(count: 1000).write(to: old); try Data(count: 1000).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        DecodeCache.trim(limit: 1500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    /// The preview developed from the cached decode matches the one from the decoder, and the cache key follows the
    /// decoder's settings: a white balance change misses.
    func testRAWPreviewFromTheCacheMatchesTheDecoder() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let file = try XCTUnwrap(try TestSamples.require(TestSamples.raws).first)
        let (live, defaults) = try RawRenderer.open(file)
        await live.setDecodeUse(.off)
        let direct = try await live.preview(defaults)
        let (cached, _) = try RawRenderer.open(file)
        _ = try await cached.prepareDetail(defaults, region: CGRect(x: 0, y: 0, width: 1, height: 1), photoWidth: 1500)
        let fromCache = try await cached.preview(defaults)
        let liveDecode = await cached.liveDecode
        XCTAssertFalse(liveDecode, "the detail render stored the decode the preview reads")
        XCTAssertEqual(fromCache.image.width, direct.image.width)
        XCTAssertLessThan(meanDifference(fromCache.image, direct.image), 0.002)
        var warmer = defaults; warmer.temperature += 800
        _ = try await cached.preview(warmer)
        let missed = await cached.liveDecode
        XCTAssertTrue(missed)
    }

    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage) -> [UInt16] {
            var data = [UInt16](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: image.width * 8,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let x = pixels(a), y = pixels(b)
        return zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(x.count) / 65535
    }
}
