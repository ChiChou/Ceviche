import XCTest
import Metal
import ImageIO
import CoreGraphics
@testable import CevicheCore

final class AdvancedAdjustmentsTests: XCTestCase {
    func testSelectiveColorTargetsHueAndPreservesNeutrals() {
        var bands = SelectiveColor.defaults
        bands[0].hue = 60; bands[0].saturation = -25
        let red = SelectiveColor.transform(SIMD3(0.8, 0.2, 0.2), adjustments: bands)
        // Red Hue +100 turns red about 31° toward orange.
        XCTAssertGreaterThan(red.y, 0.4)
        XCTAssertEqual(SelectiveColor.transform(SIMD3(0.2, 0.8, 0.2), adjustments: bands), SIMD3(0.2, 0.8, 0.2))
        XCTAssertEqual(SelectiveColor.transform(SIMD3(0.5, 0.5, 0.5), adjustments: bands), SIMD3(0.5, 0.5, 0.5))
        let adjacent = SIMD3(0.8, 0.45, 0.2)
        bands[0].range = 0.2
        let narrow = SelectiveColor.transform(adjacent, adjustments: bands)
        bands[0].range = 2
        XCTAssertNotEqual(SelectiveColor.transform(adjacent, adjustments: bands), narrow)
    }
    func testBandWeightsFollowTheMixerFalloffAndPeakAtOne() {
        // Exactly on blue: only blue; between aqua and blue: blue in full, aqua by the same falloff the renderer blends with.
        let blue = SelectiveColor.bandWeights(hue: 240.0 / 360)
        XCTAssertEqual(blue[5], 1); XCTAssertEqual(blue.filter { $0 > 0 }.count, 1)
        let between = SelectiveColor.bandWeights(hue: 225.0 / 360)
        XCTAssertEqual(between[5], 1); XCTAssertEqual(between[4], 0.185, accuracy: 0.001)
        XCTAssertEqual(between.filter { $0 > 0 }.count, 2)
        // Wraps around red.
        XCTAssertEqual(SelectiveColor.bandWeights(hue: 355.0 / 360)[0], 1)
    }
    /// Portrait's groups switch off on their own: each leaves out only what it made, and keeps it in the edit.
    func testPortraitGroupsSwitchOffWhatTheyMade() {
        var settings = Adjustments()
        var spot = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.4, y: 0.5), target: MaskPoint(x: 0.5, y: 0.5), radius: 0.01, softness: 0.4, opacity: 1)
        spot.face = true
        let drawn = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.2, y: 0.5), target: MaskPoint(x: 0.3, y: 0.5), radius: 0.01, softness: 0.4, opacity: 1)
        settings.retouch = [drawn, spot]
        var shine = PhotoMask(kind: .radial); shine.portraitCorrection = .shine
        let other = PhotoMask(kind: .radial)
        settings.masks = [other, shine]
        settings.faceLiquify = FaceLiquify(region: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        settings.disabledSections = [.faceSpots, .portraitLight, .facialFeatures]
        let effective = settings.effective(defaults: Adjustments())
        XCTAssertEqual(effective.retouch.map(\.id), [drawn.id])
        XCTAssertEqual(effective.masks.map(\.id), [other.id])
        XCTAssertNil(effective.faceLiquify)
        XCTAssertEqual(settings.retouch.count, 2)
        XCTAssertEqual(settings.masks.count, 2)
    }
    func testDisableKeepsValuesAndLegacyDocumentsDefaultToEnabled() throws {
        var settings = Adjustments()
        settings.exposure = 2; settings.temperature = 8000; settings.clarity = 50; settings.vignette = 80
        settings.vignetteRadius = 0.3; settings.vignetteSoftness = 0.8
        settings.selectiveColors[2].luminance = 25
        settings.curve.insert(x: 0.4, y: 0.2)
        let edited = settings
        settings.disabledSections = Set(AdjustmentGroup.allCases)
        let effective = settings.effective(defaults: Adjustments())
        for group in AdjustmentGroup.allCases { for key in group.keys { XCTAssertEqual(effective[keyPath: key], Adjustments()[keyPath: key]) } }
        XCTAssertEqual(effective.curve, ToneCurve())
        XCTAssertEqual(effective.selectiveColors, SelectiveColor.defaults)
        settings.disabledSections = []
        XCTAssertEqual(settings, edited)
        settings.disabledSections = [.color, .vignette]
        XCTAssertEqual(try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(settings)), settings)
        var partial = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments())) as! [String: Any]
        for key in ["disabledSections", "selectiveColors", "vignetteRadius", "vignetteSoftness"] { partial.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Adjustments.self, from: JSONSerialization.data(withJSONObject: partial))
        XCTAssertEqual(restored, Adjustments())
    }
    func testGPUSelectiveVignetteAndSectionBypass() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("colors.png")
        let bitmap = CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 2400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index, rgb) in [SIMD3(0.8, 0.2, 0.2), SIMD3(0.2, 0.8, 0.2), SIMD3(0.2, 0.2, 0.8)].enumerated() {
            bitmap.setFillColor(CGColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1))
            bitmap.fill(CGRect(x: index * 200, y: 0, width: 200, height: 300))
        }
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let (renderer, defaults) = try RawRenderer.open(imageURL)
        let original = try await renderer.preview(defaults)
        var settings = defaults; settings.selectiveColors[0].hue = 60
        let changed = try await renderer.preview(settings)
        let red = sample(changed.image, x: 100, y: 150)
        XCTAssertGreaterThan(red[1], sample(original.image, x: 100, y: 150)[1] + 0.15)
        for channel in 0..<3 { XCTAssertEqual(sample(changed.image, x: 300, y: 150)[channel], sample(original.image, x: 300, y: 150)[channel], accuracy: 0.015) }
        settings.disabledSections = [.selectiveColor]
        let bypass = try await renderer.preview(settings)
        XCTAssertEqual(bypass.thumbnail, original.thumbnail)
        settings = defaults; settings.vignette = 80; settings.vignetteRadius = 0.2; settings.vignetteSoftness = 0.4
        let vignette = try await renderer.preview(settings)
        XCTAssertLessThan(sample(vignette.image, x: 5, y: 5).reduce(0, +), sample(original.image, x: 5, y: 5).reduce(0, +))
        settings.vignetteRadius = 0.8
        let large = try await renderer.preview(settings)
        XCTAssertNotEqual(large.thumbnail, vignette.thumbnail)
        settings.vignetteSoftness = 0.9
        let soft = try await renderer.preview(settings)
        XCTAssertNotEqual(soft.thumbnail, large.thumbnail)
        settings.disabledSections = [.vignette]
        let disabled = try await renderer.preview(settings)
        XCTAssertEqual(disabled.thumbnail, original.thumbnail)
        settings.selectiveColors[4].saturation = -50
        settings.disabledSections.insert(.selectiveColor)
        let (reopened, restored) = try await reopenThroughCatalog(renderer, settings)
        XCTAssertEqual(restored, settings)
        let preview = try await reopened.preview(restored)
        XCTAssertEqual(preview.thumbnail, original.thumbnail)
        var allDisabled = settings
        allDisabled.exposure = 1; allDisabled.temperature = 8000; allDisabled.shadows = 30
        allDisabled.curve.insert(x: 0.4, y: 0.2); allDisabled.sharpness = 50
        allDisabled.disabledSections = Set(AdjustmentGroup.allCases)
        let neutral = try await renderer.preview(allDisabled)
        XCTAssertEqual(neutral.thumbnail, original.thumbnail)
    }
    private func sample(_ image: CGImage, x: Int, y: Int) -> [Double] {
        let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }
}
