import XCTest
@testable import CevicheCore

final class ColorGradeCurvesTests: XCTestCase {
    private func graded(_ s: SplitToning, _ p: SIMD3<Double>) -> SIMD3<Double> { ColorGradeCurves(s)!.apply(p) }

    func testTablesDecodeAndNeutralSettingsChangeNothing() {
        XCTAssertEqual(ColorGradeCurves.tables.count, ColorGradeCurves.count)
        XCTAssertNil(ColorGradeCurves(SplitToning()))
        XCTAssertEqual(SplitToning().transform(SIMD3(0.2, 0.4, 0.6)), SIMD3(0.2, 0.4, 0.6))
    }
    func testChannelsAreGradedIndependently() {
        var s = SplitToning(); s.shadowHue = 30; s.shadowSaturation = 50
        let a = graded(s, SIMD3(0.02, 0.3, 0.6)), b = graded(s, SIMD3(0.02, 0.05, 0.9))
        XCTAssertEqual(a.x, b.x)
        XCTAssertGreaterThan(a.x, 0.02 * 1.2)
    }
    func testBalanceMovesShadowsUpTheRange() {
        var s = SplitToning(); s.shadowHue = 210; s.shadowSaturation = 50
        let blue = { (s: SplitToning) in self.graded(s, SIMD3(repeating: 0.1)).z / 0.1 }
        let atDefault = blue(s)
        s.balance = -100; XCTAssertGreaterThan(blue(s), atDefault + 0.1)
        s.balance = 100; XCTAssertLessThan(blue(s), atDefault - 0.1)
    }
    func testBlendingWidensTheRegions() {
        var s = SplitToning(); s.highlightHue = 40; s.highlightSaturation = 50
        let red = { (s: SplitToning) in self.graded(s, SIMD3(repeating: 0.05)).x / 0.05 }
        s.blending = 0; let narrow = red(s)
        s.blending = 100; XCTAssertGreaterThan(red(s), narrow + 0.02)
    }
    func testLuminanceDarkensAndLiftsShadowsAndFollowsBlending() {
        var s = SplitToning(); s.shadowLuminance = -50
        let dark = graded(s, SIMD3(repeating: 0.01))
        for v in [dark.x, dark.y, dark.z] { XCTAssertEqual(v / 0.01, 0.5, accuracy: 0.1) }
        let atDefault = graded(s, SIMD3(repeating: 0.04)).y / 0.04
        s.balance = 100; XCTAssertGreaterThan(graded(s, SIMD3(repeating: 0.04)).y / 0.04, atDefault + 0.1)
        s.balance = 0; s.blending = 100; XCTAssertLessThan(graded(s, SIMD3(repeating: 0.04)).y / 0.04, atDefault)
        s = SplitToning(); s.shadowLuminance = 50
        XCTAssertGreaterThan(graded(s, SIMD3(repeating: 0.01)).y, 0.02)
        XCTAssertEqual(graded(s, SIMD3(repeating: 0.95)).y, 0.95, accuracy: 0.01, "Unchanged near white")
    }
    func testSplitToningWithoutColorGradingImportsAtFullBlending() throws {
        func blending(_ attributes: String) throws -> Double {
            let xml = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(attributes)/>
            </rdf:RDF></x:xmpmeta>
            """
            return try XMPCodec.apply(XMPPacket(data: Data(xml.utf8)), to: Adjustments()).adjustments.splitToning.blending
        }
        XCTAssertEqual(try blending(#"crs:SplitToningShadowHue="51" crs:SplitToningShadowSaturation="17""#), 100)
        XCTAssertEqual(try blending(#"crs:SplitToningShadowHue="51" crs:SplitToningShadowSaturation="17" crs:ColorGradeBlending="30""#), 30)
        XCTAssertEqual(try blending(#"crs:SplitToningShadowHue="51" crs:SplitToningShadowSaturation="17" crs:ColorGradeMidtoneSat="0""#), 50)
    }
}

final class ColorMixerTablesTests: XCTestCase {
    func testTablesDecodeAndBandCentersFollowTheWheel() {
        XCTAssertEqual(ColorMixerTables.data.count, 48 * ColorMixerTables.table)
        let degrees = ColorMixerTables.centers.map { $0 * 360 }
        for (center, expected) in zip(degrees, [0.0, 29, 60, 102, 161, 224, 278, 323]) {
            let distance = abs(center - expected)
            XCTAssertLessThan(min(distance, 360 - distance), 3)
        }
    }
    func testNoBandMovesANeutral() {
        for band in 0..<8 {
            for kind in 0..<3 {
                for amount in [-100.0, 100] {
                    var bands = SelectiveColor.defaults
                    switch kind { case 0: bands[band].hue = amount * 0.6; case 1: bands[band].saturation = amount; default: bands[band].luminance = amount }
                    XCTAssertEqual(SelectiveColor.transform(SIMD3(repeating: 0.4), adjustments: bands), SIMD3(repeating: 0.4))
                }
            }
        }
    }
    func testOrangeLuminanceIsNotLinearInTheSlider() {
        let skin = SIMD3(0.75, 0.55, 0.42)
        func luma(_ amount: Double) -> Double {
            var bands = SelectiveColor.defaults; bands[1].luminance = amount
            return FilmMath.luma(FilmMath.decode(SelectiveColor.transform(skin, adjustments: bands)))
        }
        let base = FilmMath.luma(FilmMath.decode(skin))
        XCTAssertLessThan(luma(-100), luma(-50)); XCTAssertLessThan(luma(-50), base); XCTAssertGreaterThan(luma(100), base)
        // Darkening follows the slider to the power 1.6: −50 does about a third of −100's change in log value.
        let ratio = log2(luma(-50) / base) / log2(luma(-100) / base)
        XCTAssertEqual(ratio, pow(0.5, 1.6), accuracy: 0.12)
    }
    func testRangeWidensABandAlongHue() {
        var bands = SelectiveColor.defaults; bands[5].saturation = -100
        let aqua = SIMD3(0.2, 0.65, 0.8)
        let normal = SelectiveColor.transform(aqua, adjustments: bands)
        bands[5].range = 2
        let wide = SelectiveColor.transform(aqua, adjustments: bands)
        XCTAssertLessThan(wide.max() - wide.min(), normal.max() - normal.min())
    }
}
