import XCTest
import CoreImage
import Metal
@testable import CevicheCore

final class NegativeConverterTests: XCTestCase {
    /// An asymmetric scan makes every rotation and reflection distinguishable, including the order of operations.
    func testOrientationPixelsAndCropCoordinatesAgree() throws {
        let bytes: [UInt8] = (1...6).flatMap { [UInt8($0 * 30), 0, 0, 255] }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let context = CIContext()
        let expected = [[1, 2, 3, 4, 5, 6], [4, 1, 5, 2, 6, 3], [6, 5, 4, 3, 2, 1], [3, 6, 2, 5, 1, 4]]
        var orientation = NegativeOrientation()
        for turn in 0..<4 {
            for mirrored in [false, true] {
                let value = mirrored ? orientation.flipped(horizontal: true) : orientation
                let image = value.apply(to: CIImage(cgImage: source))
                let w = turn % 2 == 0 ? 3 : 2, h = turn % 2 == 0 ? 2 : 3
                XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: w, height: h))
                var pixels = [UInt8](repeating: 0, count: w * h * 4)
                pixels.withUnsafeMutableBytes {
                    context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: space)
                }
                var wanted = expected[turn]
                if mirrored { wanted = stride(from: 0, to: wanted.count, by: w).flatMap { Array(wanted[$0..<$0 + w].reversed()) } }
                XCTAssertEqual(stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) / 30 }, wanted)
                // The crop handle for each original pixel lands on the very same pixel in the oriented image.
                for y in 0..<2 { for x in 0..<3 {
                    let scan = CGPoint(x: (Double(x) + 0.5) / 3, y: (Double(y) + 0.5) / 2)
                    let shown = value.displayPoint(scan), back = value.scanPoint(shown)
                    XCTAssertEqual(back.x, scan.x, accuracy: 1e-9); XCTAssertEqual(back.y, scan.y, accuracy: 1e-9)
                    XCTAssertEqual(wanted[Int(shown.y * Double(h)) * w + Int(shown.x * Double(w))], y * 3 + x + 1)
                }}
            }
            orientation = orientation.rotated(clockwise: true)
        }
        XCTAssertEqual(orientation, NegativeOrientation())
    }

    func testControlsUseDisplayedAxesAfterMirroringAndRotation() {
        let original = NegativeOrientation(), p = CGPoint(x: 0.2, y: 0.3)
        let mirrored = original.flipped(horizontal: true)
        XCTAssertEqual(mirrored.rotated(clockwise: true).displayPoint(p), CGPoint(x: 0.7, y: 0.8))
        XCTAssertEqual(mirrored.rotated(clockwise: false).displayPoint(p).x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(mirrored.rotated(clockwise: false).displayPoint(p).y, 0.2, accuracy: 1e-9)
        for value in [original, mirrored, original.rotated(clockwise: true), mirrored.rotated(clockwise: true)] {
            let before = value.displayPoint(p), horizontal = value.flipped(horizontal: true).displayPoint(p)
            let vertical = value.flipped(horizontal: false).displayPoint(p)
            XCTAssertEqual(horizontal.x, 1 - before.x, accuracy: 1e-9); XCTAssertEqual(horizontal.y, before.y, accuracy: 1e-9)
            XCTAssertEqual(vertical.x, before.x, accuracy: 1e-9); XCTAssertEqual(vertical.y, 1 - before.y, accuracy: 1e-9)
            XCTAssertEqual(value.flipped(horizontal: true).flipped(horizontal: true), value)
            XCTAssertEqual(value.flipped(horizontal: false).flipped(horizontal: false), value)
            XCTAssertEqual(value.rotated(clockwise: true).rotated(clockwise: false), value)
        }
    }

    /// A skewed frame maps its corners to the straightened frame's and back.
    func testFrameMapsBothWays() {
        let frame = FrameQuad(corners: [CGPoint(x: 0.12, y: 0.08), CGPoint(x: 0.86, y: 0.05), CGPoint(x: 0.9, y: 0.93), CGPoint(x: 0.1, y: 0.9)])
        XCTAssertTrue(frame.isValid)
        let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        for (corner, point) in zip(frame.corners, unit) {
            let mapped = frame.scanPoint(point)
            XCTAssertEqual(mapped.x, corner.x, accuracy: 1e-9); XCTAssertEqual(mapped.y, corner.y, accuracy: 1e-9)
        }
        let inside = CGPoint(x: 0.3, y: 0.7), back = frame.framePoint(frame.scanPoint(inside))
        XCTAssertEqual(back.x, inside.x, accuracy: 1e-9); XCTAssertEqual(back.y, inside.y, accuracy: 1e-9)
        XCTAssertFalse(FrameQuad(corners: [frame.corners[0], frame.corners[2], frame.corners[1], frame.corners[3]]).isValid)
    }

    /// A synthetic scan: dark holder, orange film base, and a picture whose density grows left to right. The frame
    /// is found at the picture's edges and the inversion puts the base at black and the densest part near white.
    func testFindsTheFrameAndInvertsAgainstTheBase() {
        let w = 600, h = 400
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        var rgba = [Float](repeating: 0.002, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let p = 4 * (y * w + x)
            rgba[p + 3] = 1
            guard x >= 60, x < 540 else { continue }  // holder outside the strip
            var v = base
            if x >= 100, x < 500, y >= 30, y < 370 {  // the picture: 0.3 to 3 stops of density
                let d = 0.3 + 2.7 * Float(x - 100) / 400 + 0.2 * Float((x / 7 + y / 5) % 3)
                v = base / exp2(d)
            }
            rgba[p] = v.x; rgba[p + 1] = v.y; rgba[p + 2] = v.z
        }}
        let frame = NegativeConverter.detectFrame(rgba, width: w, height: h)
        let expected = [CGPoint(x: 100, y: 30), CGPoint(x: 500, y: 30), CGPoint(x: 500, y: 370), CGPoint(x: 100, y: 370)]
        for (found, corner) in zip(frame.corners, expected) {
            XCTAssertEqual(found.x * CGFloat(w), corner.x, accuracy: 6); XCTAssertEqual(found.y * CGFloat(h), corner.y, accuracy: 6)
        }
        // The frame's pixels as straightening would give them.
        let x0 = Int(frame.corners[0].x * CGFloat(w)), y0 = Int(frame.corners[0].y * CGFloat(h))
        let x1 = Int(frame.corners[2].x * CGFloat(w)), y1 = Int(frame.corners[2].y * CGFloat(h))
        var picture: [Float] = []
        for y in y0..<y1 { for x in x0..<x1 { let p = 4 * (y * w + x); picture += rgba[p..<p + 4] } }
        let (inversion, suggested) = NegativeConverter.inversion(rgba, width: w, height: h, frame: frame, straightened: picture,
                                                               frameWidth: x1 - x0, frameHeight: y1 - y0, film: nil)
        XCTAssertEqual(suggested, .color)
        XCTAssertEqual(inversion.base.x, base.x, accuracy: 0.02)
        XCTAssertLessThan(inversion.positive(base.x, base.y, base.z).max(), 0.06)
        let dense = base / exp2(3.4)
        XCTAssertGreaterThan(inversion.positive(dense.x, dense.y, dense.z).min(), 0.6)
    }

    /// A roll is balanced on all its scans together: a thin and a dense negative of the same roll share one density
    /// range, so the dense one's highlights reach white and the thin one stays darker, as it was exposed. Each scan
    /// keeps its own base, so one scanned a stop brighter converts the same, and a picked base follows each scan's
    /// exposure.
    func testBalancesARollOnAllItsScans() {
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        func sample(_ densities: ClosedRange<Float>, light: Float = 1, base: SIMD3<Float> = base) -> NegativeSample {
            let values = (0..<400).map { densities.lowerBound + (densities.upperBound - densities.lowerBound) * Float($0) / 399 }
            return NegativeSample(base: base * light, channels: (0..<3).map { c in values.map { light * base[c] / exp2($0) } },
                                  frame: .full, exposure: Double(light))
        }
        let thin = sample(0.3...1.5), dense = sample(0.3...3), brighter = sample(0.3...2, light: 2)
        let alone = NegativeConverter.balance([thin], film: .color).inversions[0]
        let roll = NegativeConverter.balance([thin, dense, brighter], film: .color).inversions
        XCTAssertEqual(roll[0].base.x, base.x, accuracy: 0.01); XCTAssertEqual(roll[2].base.x, 2 * base.x, accuracy: 0.02)
        let thinDensest = base / exp2(1.5), denseDensest = base / exp2(3)
        XCTAssertGreaterThan(alone.positive(thinDensest.x, thinDensest.y, thinDensest.z).y, 0.6)
        XCTAssertLessThan(roll[0].positive(thinDensest.x, thinDensest.y, thinDensest.z).y, 0.4)
        XCTAssertGreaterThan(roll[1].positive(denseDensest.x, denseDensest.y, denseDensest.z).y, 0.6)
        XCTAssertLessThan(roll[0].positive(base.x, base.y, base.z).max(), 0.06)
        // The same density on the brighter scan is the same positive.
        let a = roll[0].positive(thinDensest.x, thinDensest.y, thinDensest.z), b = roll[2].positive(2 * thinDensest.x, 2 * thinDensest.y, 2 * thinDensest.z)
        for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 1e-4) }

        let picked = SIMD3<Float>(0.7, 0.35, 0.18)
        let pickedRoll = NegativeConverter.balance([thin, brighter], film: .color, base: picked).inversions
        XCTAssertEqual(pickedRoll[0].base, picked); XCTAssertEqual(pickedRoll[1].base, 2 * picked)

        // Another stock converts on its own and leaves the roll as it was; red alone off, as when it clips, doesn't.
        let other = sample(0.3...2, base: SIMD3(0.8, 0.6, 0.35)), clipped = sample(0.3...2, base: SIMD3(0.5, 0.4, 0.2))
        let mixed = NegativeConverter.balance([thin, dense, other, brighter], film: .color)
        XCTAssertEqual(mixed.apart, [2])
        XCTAssertEqual(mixed.inversions[2], NegativeConverter.balance([other], film: nil).inversions[0])
        XCTAssertEqual(mixed.inversions[0], roll[0]); XCTAssertEqual(mixed.inversions[3], roll[2])
        XCTAssertEqual(NegativeConverter.balance([thin, dense, clipped], film: .color).apart, [])
        XCTAssertEqual(NegativeConverter.balance([thin, other], film: .color).apart, [])
    }
}
