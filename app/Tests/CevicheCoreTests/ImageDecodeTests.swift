import XCTest
import ImageIO
import CevicheTestSupport
@testable import CevicheCore

/// A 640 px RAW thumbnail needs 128–256 KB of stack in RawCamera; with Ceviche's import frames above it, that once
/// overflowed a 512 KB worker stack (see `AdjustmentsSizeTests`). `ImageDecode` gives the decoder its own stack.
final class ImageDecodeTests: XCTestCase {
    func testWorkRunsOnALargeStackAndReturnsItsResult() async {
        let size = await Task.detached { ImageDecode.onLargeStack { Thread.current.stackSize } }.value
        XCTAssertGreaterThanOrEqual(size, ImageDecode.stackSize)
    }
    /// Without the helper this crashes (SIGBUS): a plain decode fails on a 128 KB stack and here only 64 KB is left.
    func testRAWThumbnailsDecodeUnderASmallStack() throws {
        let urls = TestSamples.raws.compactMap { try? TestSamples.require($0) }
        guard !urls.isEmpty else { throw XCTSkip("No sample RAWs") }
        var sizes: [Int] = []
        let done = expectation(description: "decoded")
        let thread = Thread {
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let image = ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
                sizes.append(image.map { max($0.width, $0.height) } ?? 0)
            }
            done.fulfill()
        }
        thread.stackSize = 64 << 10
        thread.start()
        wait(for: [done], timeout: 120)
        XCTAssertEqual(sizes, Array(repeating: 640, count: urls.count))
    }
}
