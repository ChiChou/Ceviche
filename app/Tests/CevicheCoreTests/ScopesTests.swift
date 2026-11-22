import XCTest
import CoreGraphics
@testable import CevicheCore

final class ScopesTests: XCTestCase {
    /// An 8-bit sRGB image filled by `pixel(x, y)`, y from the top.
    private func image(width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let p = (y * width + x) * 4, c = pixel(x, y); bytes[p] = c.0; bytes[p + 1] = c.1; bytes[p + 2] = c.2 } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    /// The level holding most of a column's pixels in one channel.
    private func peakLevel(_ scopes: Scopes, _ channel: Scopes.Channel, column: Int) -> Int {
        (0..<Scopes.levels).max { scopes.waveform[channel.rawValue][$0 * scopes.columns + column] < scopes.waveform[channel.rawValue][$1 * scopes.columns + column] }!
    }
    private func source(_ image: CGImage) -> ScopeSource { ScopeSource(levels: image, colour: image, hdrStops: nil) }

    func testWaveformFollowsTheImageLeftToRight() {
        // A ramp from black on the left to white on the right draws a rising diagonal.
        let ramp = image(width: 256, height: 32) { x, _ in let v = UInt8(x); return (v, v, v) }
        let scopes = Scopes(source(ramp))
        XCTAssertEqual(scopes.columns, 256)
        XCTAssertLessThanOrEqual(peakLevel(scopes, .luma, column: 0), 1)
        XCTAssertGreaterThanOrEqual(peakLevel(scopes, .luma, column: 255), Scopes.levels - 2)
        XCTAssertEqual(Double(peakLevel(scopes, .luma, column: 128)), Double(Scopes.levels - 1) * 128 / 255, accuracy: 2)
        // Every column counts all its pixels.
        for channel in Scopes.Channel.allCases {
            let total = (0..<Scopes.levels).reduce(Float(0)) { $0 + scopes.waveform[channel.rawValue][$1 * scopes.columns + 40] }
            XCTAssertEqual(total, scopes.pixelsPerColumn, accuracy: 0.5)
        }
    }

    func testWaveformSeparatesChannels() {
        let orange = image(width: 64, height: 16) { _, _ in (255, 128, 0) }
        let scopes = Scopes(source(orange))
        XCTAssertEqual(peakLevel(scopes, .red, column: 10), Scopes.levels - 1)
        XCTAssertEqual(Double(peakLevel(scopes, .green, column: 10)), Double(Scopes.levels - 1) * 128 / 255, accuracy: 2)
        XCTAssertEqual(peakLevel(scopes, .blue, column: 10), 0)
    }

    func testWideImagesShrinkToTheColumnLimit() {
        let wide = image(width: 1200, height: 40) { _, _ in (100, 100, 100) }
        XCTAssertEqual(Scopes(source(wide)).columns, Scopes.maximumColumns)
    }

    /// The cell a colour lands in, as offsets from the centre of the plot.
    private func vectorPeak(_ scopes: Scopes) -> (cb: Double, cr: Double) {
        let size = Scopes.vectorSize
        let index = scopes.vectorscope.indices.max { scopes.vectorscope[$0] < scopes.vectorscope[$1] }!
        let half = Double(size) / 2
        return ((Double(index % size) + 0.5 - half) / half * Scopes.chromaReach, (Double(index / size) + 0.5 - half) / half * Scopes.chromaReach)
    }

    func testVectorscopePlacesColoursOnTheirTargets() {
        let grey = vectorPeak(Scopes(source(image(width: 32, height: 32) { _, _ in (128, 128, 128) })))
        XCTAssertEqual(grey.cb, 0, accuracy: 0.01); XCTAssertEqual(grey.cr, 0, accuracy: 0.01)
        for (target, colour) in zip(Scopes.targets, [(255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 0, 255)] as [(UInt8, UInt8, UInt8)]) {
            let peak = vectorPeak(Scopes(source(image(width: 32, height: 32) { _, _ in colour })))
            XCTAssertEqual(peak.cb, target.cb, accuracy: 0.01, target.name)
            XCTAssertEqual(peak.cr, target.cr, accuracy: 0.01, target.name)
        }
        // Red sits up and slightly left, blue right: the broadcast orientation.
        XCTAssertGreaterThan(Scopes.targets[0].cr, 0.45); XCTAssertLessThan(Scopes.targets[0].cb, 0)
        XCTAssertGreaterThan(Scopes.targets[4].cb, 0.45)
    }

    func testVectorscopeShowsColoursBeyondSRGB() throws {
        // Display P3's pure green is outside sRGB: it lands past the green target, outside the hexagon.
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let peak = vectorPeak(Scopes(source(image(width: 32, height: 32, space: p3) { _, _ in (0, 255, 0) })))
        let green = Scopes.targets[2]
        XCTAssertGreaterThan(hypot(peak.cb, peak.cr), hypot(green.cb, green.cr) + 0.02)
    }

    func testHDRLevelsPutSDRWhiteHalfway() {
        // Linear 1.0 (SDR white) on the left half and 4.0 (two stops above) on the right, with a two-stop limit.
        let width = 32, height = 8
        var floats = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in width / 2..<width { for c in 0..<3 { floats[(y * width + x) * 4 + c] = 4 } } }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let provider = CGDataProvider(data: floats.withUnsafeBytes { Data($0) } as CFData)!
        let hdr = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16, space: space,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let scopes = Scopes(ScopeSource(levels: hdr, colour: image(width: 8, height: 8) { _, _ in (255, 255, 255) }, hdrStops: 2))
        XCTAssertEqual(Double(peakLevel(scopes, .luma, column: 4)), Double(Scopes.levels - 1) / 2, accuracy: 1.5)
        XCTAssertEqual(peakLevel(scopes, .luma, column: width - 4), Scopes.levels - 1)
    }

    func testImagesDrawOnlyWhereThereArePixels() throws {
        let scopes = Scopes(source(image(width: 64, height: 16) { x, _ in (UInt8(x * 4), 60, 200) }))
        let parade = try XCTUnwrap(scopes.waveformImage(.parade))
        XCTAssertEqual(parade.width, scopes.columns * 3); XCTAssertEqual(parade.height, Scopes.levels)
        XCTAssertNotNil(scopes.waveformImage(.luma)); XCTAssertNotNil(scopes.waveformImage(.rgb))
        let vector = try XCTUnwrap(scopes.vectorscopeImage())
        XCTAssertEqual(vector.width, Scopes.vectorSize)
    }
}
