import XCTest
import CoreImage
import CevicheTestSupport
@testable import CevicheCore

/// Soft proofing through local press and printer profiles (`TestSamples.printProfiles`): the tests skip without them.
final class PrintProofTests: XCTestCase {
    /// Exercise the two overlays independently with a system profile, without external test photos/profiles.
    func testIndependentWarningOverlays() throws {
        let profile = try PrintProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"))
        let space = CGColorSpace(name: CGColorSpace.rommrgb)!
        let context = CIContext()
        func pixel(_ rgb: SIMD3<Double>, _ settings: PrintProofSettings) throws -> [Float] {
            let input = CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            let result = try profile.proof(input, settings: settings)
            var values = [Float](repeating: 0, count: 4)
            context.render(result, toBitmap: &values, rowBytes: 16, bounds: result.extent, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        let green = SIMD3<Double>(0, 1, 0), black = SIMD3<Double>(0, 0, 0)
        let plain = PrintProofSettings()
        let baseGreen = try pixel(green, plain), baseBlack = try pixel(black, plain)
        var gamut = plain; gamut.gamutWarning = true
        var shadow = plain; shadow.shadowWarning = true
        XCTAssertEqual(try pixel(black, gamut), baseBlack)
        XCTAssertEqual(try pixel(green, shadow), baseGreen)
        let markedGreen = try pixel(green, gamut), markedBlack = try pixel(black, shadow)
        XCTAssertGreaterThan(markedGreen[0], markedGreen[1] + 0.3)
        XCTAssertGreaterThan(markedGreen[0], markedGreen[2] + 0.3)
        XCTAssertGreaterThan(markedBlack[2], markedBlack[0] + 0.3)
        gamut.gamutWarning = false
        XCTAssertEqual(try pixel(green, gamut), baseGreen)
        XCTAssertEqual(try profile.cube(gamut), try profile.cube(plain), "Overlay appearance must not change the proof transform")
    }

    private func coated() throws -> PrintProfile {
        try PrintProfile(url: TestSamples.require(TestSamples.printProfiles.coated))
    }
    /// The cube's answer for one ProPhoto-encoded colour, at the nearest node.
    private func lookup(_ cube: Data, _ r: Double, _ g: Double, _ b: Double) -> SIMD3<Double> {
        let n = PrintProfile.size
        func node(_ v: Double) -> Int { Int((v * Double(n - 1)).rounded()) }
        let i = ((node(b) * n + node(g)) * n + node(r)) * 4
        return cube.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            return SIMD3(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
        }
    }

    func testReadsPaperAndBlackFromAPressProfile() throws {
        let profile = try coated()
        XCTAssertEqual(profile.channels, 4)
        XCTAssertFalse(profile.name.isEmpty)
        // Coated offset paper: nearly white with a slight blue cast from brighteners, and a black around L* 12–20.
        XCTAssertEqual(profile.paperWhite.x, 95, accuracy: 3); XCTAssertLessThan(abs(profile.paperWhite.y), 4); XCTAssertLessThan(abs(profile.paperWhite.z), 8)
        XCTAssertGreaterThan(profile.black.x, 5); XCTAssertLessThan(profile.black.x, 25)
        XCTAssertGreaterThan(profile.contrast, 4); XCTAssertLessThan(profile.contrast, 8)
        // A display profile is refused.
        XCTAssertThrowsError(try PrintProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"))) { error in
            guard case PrintProofError.notAPrinter = error else { return XCTFail("\(error)") }
        }
        _ = PrintProfile.installed()
    }

    /// With the paper simulated, white comes out as the paper (dimmer than the screen) and black as the ink's black;
    /// without it both stretch back to the screen's. Greys stay grey either way.
    func testPaperSimulationDimsWhiteAndLiftsBlack() throws {
        let profile = try coated()
        var settings = PrintProofSettings()
        let paper = try profile.cube(settings)
        XCTAssertEqual(paper.count, PrintProfile.size * PrintProfile.size * PrintProfile.size * 16)
        let white = lookup(paper, 1, 1, 1), black = lookup(paper, 0, 0, 0), grey = lookup(paper, 0.5, 0.5, 0.5)
        XCTAssertLessThan(white.max(), 0.99); XCTAssertGreaterThan(white.min(), 0.85, "paper white, L* 95")
        XCTAssertGreaterThan(black.min(), 0.03, "ink black is not the screen's black")
        XCTAssertLessThan(grey.max() - grey.min(), 0.04, "a grey stays near neutral on this paper")
        settings.simulatePaper = false
        let plain = try profile.cube(settings)
        XCTAssertGreaterThan(lookup(plain, 1, 1, 1).min(), 0.97); XCTAssertLessThan(lookup(plain, 0, 0, 0).max(), 0.03)
        // A colour the press can't reach is pulled in; one it can is left close to where it was.
        let green = lookup(plain, 0, 1, 0)
        XCTAssertGreaterThan(green.x, 0.1, "ProPhoto's green primary isn't printable")
        let skin = lookup(plain, 0.5, 0.4, 0.3)
        XCTAssertEqual(skin.x, 0.5, accuracy: 0.06); XCTAssertEqual(skin.y, 0.4, accuracy: 0.06); XCTAssertEqual(skin.z, 0.3, accuracy: 0.06)
        // The same settings give the same cube without building it again.
        XCTAssertEqual(try profile.cube(settings), plain)
    }

    /// The two warnings, separately: a colour outside the gamut, and a shadow below the print's black.
    func testWarnsAboutColourAndShadowSeparately() throws {
        let profile = try coated()
        let colours: [Float] = [0, 1, 0,  0.5, 0.4, 0.3,  0.5, 0.5, 0.5,  0.02, 0.02, 0.02,  1, 1, 1]
        let (colour, shadow) = try profile.limits(colours, count: 5)
        XCTAssertEqual(colour, [true, false, false, false, false])
        XCTAssertEqual(shadow, [false, false, false, true, false])
        // On a picture: half saturated green, half mid grey.
        let image = CIImage(color: CIColor(red: 0, green: 1, blue: 0, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!)!).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
            .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let context = CIContext()
        let picture = try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 200, height: 100), format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!))
        let coverage = try profile.coverage(of: picture)
        XCTAssertEqual(coverage.colour, 0.5, accuracy: 0.03); XCTAssertEqual(coverage.shadow, 0, accuracy: 0.01)
        // And the proof of it is a picture of the same size, the grey half still grey.
        let proofed = try profile.proof(CIImage(cgImage: picture), settings: PrintProofSettings())
        XCTAssertEqual(proofed.extent, CGRect(x: 0, y: 0, width: 200, height: 100))
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { context.render(proofed, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 150, y: 50, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        XCTAssertLessThan(abs(pixel[0] - pixel[2]), 0.05); XCTAssertEqual(pixel[1], 0.48, accuracy: 0.08)
        // With warnings the green half is red, whole, and the grey half is left alone.
        var warned = PrintProofSettings()
        warned.gamutWarning = true; warned.shadowWarning = true
        let tinted = try profile.proof(CIImage(cgImage: picture), settings: warned)
        func sample(_ x: CGFloat) -> [Float] {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { context.render(tinted, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: x, y: 50, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
            return pixel
        }
        let red = sample(50), grey = sample(150)
        XCTAssertGreaterThan(red[0], red[1] + 0.3, "red"); XCTAssertGreaterThan(red[0], red[2] + 0.3, "red")
        XCTAssertLessThan(abs(grey[0] - grey[2]), 0.05, "grey is printable")
    }

    /// Neutral greys stay neutral whatever the intent, with and without black point compensation, when the paper
    /// isn't simulated: ColorSync's own compensation turned them lavender.
    func testGreysStayNeutralWithoutPaper() throws {
        for name in [TestSamples.printProfiles.coated, TestSamples.printProfiles.uncoated] {
            let profile = try PrintProfile(url: TestSamples.require(name))
            for (intent, compensation) in [(PrintIntent.perceptual, true), (.relative, true), (.relative, false)] {
                var settings = PrintProofSettings()
                settings.intent = intent; settings.blackPointCompensation = compensation; settings.simulatePaper = false
                let cube = try profile.cube(settings)
                for level in [0.5, 0.75, 1.0] {
                    let grey = lookup(cube, level, level, level)
                    XCTAssertLessThan(grey.max() - grey.min(), 0.02, "\(name) \(intent) \(compensation) at \(level): \(grey)")
                    XCTAssertEqual(grey.y, level, accuracy: 0.08, "\(name) \(intent) \(compensation)")
                }
                XCTAssertGreaterThan(lookup(cube, 1, 1, 1).min(), 0.97)
            }
            // Compensated, the photo's black prints as the paper's black and a deep shadow keeps apart from it.
            var settings = PrintProofSettings()
            settings.intent = .relative; settings.simulatePaper = false
            let kept = try profile.cube(settings)
            settings.blackPointCompensation = false
            let clipped = try profile.cube(settings)
            XCTAssertGreaterThan(lookup(kept, 0.125, 0.125, 0.125).y, lookup(clipped, 0.125, 0.125, 0.125).y)
        }
    }

    /// A print made in the printer's own colour: with the press profiles there is nothing to send to a desktop
    /// printer, and a local RGB paper profile comes out tagged, the photo's size,
    /// with neutral greys in neutral ink values and its black lifted off zero by compensation.
    func testSeparatesForAnRGBPrinterOnly() throws {
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!)!).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        let photo = try XCTUnwrap(CIContext().createCGImage(grey, from: grey.extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.rommrgb)!))
        XCTAssertThrowsError(try coated().separated(photo, settings: PrintProofSettings()))
        let profile = try PrintProfile(url: TestSamples.require(TestSamples.printProfiles.rgb))
        XCTAssertTrue(profile.isRGB)
        for intent in PrintIntent.allCases {
            var settings = PrintProofSettings(); settings.intent = intent
            let print = try profile.separated(photo, settings: settings)
            XCTAssertEqual(print.width, 40); XCTAssertEqual(print.height, 30)
            XCTAssertEqual(print.colorSpace?.model, .rgb)
            XCTAssertNotEqual(print.colorSpace?.name, CGColorSpace.rommrgb)
            let pixels = try XCTUnwrap(print.dataProvider?.data as Data?)
            let values = pixels.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self).prefix(3)) }.map { Double($0) / 65535 }
            XCTAssertGreaterThan(values[0], 0.2); XCTAssertLessThan(values[0], 0.8)
            XCTAssertEqual(values[0], values[1], accuracy: 0.03); XCTAssertEqual(values[1], values[2], accuracy: 0.03)
        }
    }
}
