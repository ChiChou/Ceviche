import XCTest
import CoreImage
import CevicheTestSupport
@testable import CevicheCore

final class ChartProfileTests: XCTestCase {
    /// CIEDE2000 against Sharma's published pairs.
    func testDeltaE2000() {
        let pairs: [(SIMD3<Double>, SIMD3<Double>, Double)] = [
            (SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485), 2.0425), (SIMD3(50, -1.3802, -84.2814), SIMD3(50, 0, -82.7485), 1.0),
            (SIMD3(50, 2.5, 0), SIMD3(73, 25, -18), 27.1492), (SIMD3(60.2574, -34.0099, 36.2677), SIMD3(60.4626, -34.1751, 39.4387), 1.2644),
            (SIMD3(2.0776, 0.0795, -1.135), SIMD3(0.9033, -0.0636, -0.5514), 0.9082),
        ]
        for (a, b, expected) in pairs { XCTAssertEqual(ChartColour.deltaE2000(a, b), expected, accuracy: 1e-4) }
    }

    /// A chart profile survives its file: what the Camera Profiles folder holds reads back the same.
    func testProfileFileRoundTrip() throws {
        var profile = CameraProfile(name: "Camera 5400 K", camera: "Camera")
        profile.calibrationMatrix = [1.02, -0.01, -0.01, 0.03, 0.95, 0.02, 0, 0.04, 0.96]
        let map = ChartHueSatMap.identity(hue: 90, sat: 30)
        profile.calibrationDimensions = [90, 30, 1]; profile.calibrationMap = CameraProfile.data(map.data)
        profile.calibrationTemperature = 5400
        let read = try CameraProfile(dcp: profile.calibrationFile())
        XCTAssertEqual(read.name, profile.name); XCTAssertEqual(read.camera, profile.camera)
        XCTAssertEqual(read.calibrationDimensions, [90, 30, 1]); XCTAssertEqual(read.calibrationMap, profile.calibrationMap)
        XCTAssertEqual(read.calibrationTemperature, 5400)
        for (a, b) in zip(read.calibrationMatrix ?? [], profile.calibrationMatrix!) { XCTAssertEqual(a, b, accuracy: 1e-6) }
        XCTAssertFalse(read.hasTables, "nothing a look profile would apply")
        // Offered near its light only.
        XCTAssertTrue(read.suits(temperature: 5000)); XCTAssertFalse(read.suits(temperature: 2900))
        XCTAssertTrue(CameraProfile(name: "Look").suits(temperature: 2900))
    }

    /// The filter applies the matrix to scene-linear light at any level, and an identity map changes nothing.
    func testCalibrationFilterAppliesTheMatrix() throws {
        var profile = CameraProfile(name: "Test")
        // Linear ProPhoto → itself with red and blue exchanged: easy to recognize, white stays white.
        profile.calibrationMatrix = [0, 0, 1, 0, 1, 0, 1, 0, 0]
        profile.calibrationDimensions = [90, 30, 1]; profile.calibrationMap = CameraProfile.data(ChartHueSatMap.identity(hue: 90, sat: 30).data)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space])
        for level in [0.05, 0.5, 3.0] {
            let colour = SIMD3(0.8, 0.5, 0.2) * level
            let filter = try XCTUnwrap(ChartCalibrationFilter(profile: profile))
            filter.inputImage = CIImage(color: CIColor(red: colour.x, green: colour.y, blue: colour.z, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            var pixels = [Float](repeating: 0, count: 4 * 4 * 4)
            pixels.withUnsafeMutableBytes { context.render(filter.outputImage!, toBitmap: $0.baseAddress!, rowBytes: 64, bounds: CGRect(x: 0, y: 0, width: 4, height: 4), format: .RGBAf, colorSpace: space) }
            let prophoto = ChartColour.prophotoToSRGB.inverse * colour
            let expected = ChartColour.prophotoToSRGB * SIMD3(prophoto.z, prophoto.y, prophoto.x)
            for c in 0..<3 { XCTAssertEqual(Double(pixels[c]), expected[c], accuracy: 0.01 * level, "level \(level)") }
        }
        var plain = CameraProfile(name: "Look")
        plain.amount = 1
        XCTAssertNil(ChartCalibrationFilter(profile: plain), "a profile without a calibration leaves the decoder alone")
    }

    /// On the real chart shots: the chart is found, the profile brings the chart closer to its reference, and it
    /// holds on another exposure of the same chart. A profile made in sunlight is not offered for tungsten.
    /// Corners the photographer placed around the chart: the chart is found inside them, the picture is that frame,
    /// and the profile is the one the whole photo gives. Corners placed somewhere else fall back to the whole photo.
    func testLooksForTheChartInsideAFrame() throws {
        try TestTier.requireSlow("Decodes chart photos several times")
        let url = try TestSamples.require(TestSamples.chart.daylightUnder)
        let whole = try ChartProfiler.profile(url, camera: "Camera")
        let xs = whole.patches.map(\.centre.x), ys = whole.patches.map(\.centre.y)
        let pad = 0.06, x0 = xs.min()! - pad, x1 = xs.max()! + pad, y0 = ys.min()! - pad, y1 = ys.max()! + pad
        let framed = try ChartProfiler.profile(url, camera: "Camera", region: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)])
        XCTAssertEqual(framed.patches.filter(\.usable).count, 24)
        XCTAssertEqual(framed.after, whole.after, accuracy: 0.15); XCTAssertEqual(framed.temperature, whole.temperature, accuracy: 60)
        let picture = try XCTUnwrap(framed.preview), full = try XCTUnwrap(whole.preview)
        XCTAssertEqual(Double(picture.width) / Double(picture.height), (x1 - x0) * Double(full.width) / ((y1 - y0) * Double(full.height)), accuracy: 0.1)
        for patch in framed.patches { XCTAssertTrue((0.02...0.98).contains(patch.centre.x) && (0.02...0.98).contains(patch.centre.y)) }
        // A frame on a corner of the photo with no chart in it.
        let elsewhere = try ChartProfiler.profile(url, camera: "Camera", region: [CGPoint(x: 0, y: 0), CGPoint(x: 0.12, y: 0), CGPoint(x: 0.12, y: 0.12), CGPoint(x: 0, y: 0.12)])
        XCTAssertEqual(elsewhere.after, whole.after, accuracy: 0.01)
        XCTAssertEqual(elsewhere.preview?.width, full.width)
    }

    func testProfilesAChartInDaylightAndTungsten() async throws {
        try TestTier.requireSlow("Decodes chart photos several times")
        func shot(_ role: String) throws -> URL { try TestSamples.require(role) }
        // The shot a stop under keeps all 24 patches below where the decoder stops being linear.
        let sun = try ChartProfiler.profile(try shot(TestSamples.chart.daylightUnder), camera: "Camera")
        XCTAssertEqual(sun.temperature, 5400, accuracy: 700)
        XCTAssertEqual(sun.patches.filter(\.usable).count, 24); XCTAssertEqual(sun.tooBright, 0)
        XCTAssertLessThan(sun.after, sun.before - 0.3); XCTAssertLessThan(sun.heldOut, sun.before)
        XCTAssertFalse(sun.matrixOnly)
        let brighter = try ChartProfiler.score(sun.profile, on: try shot(TestSamples.chart.daylight))
        XCTAssertLessThan(brighter.after, brighter.before - 0.3, "holds on the same chart a stop brighter")
        // The normally exposed shot loses its brightest patches, and says so.
        XCTAssertGreaterThanOrEqual(try ChartProfiler.profile(try shot(TestSamples.chart.daylight), camera: "Camera").tooBright, 3)

        let tungsten = try ChartProfiler.profile(try shot(TestSamples.chart.tungsten), camera: "Camera")
        XCTAssertLessThan(tungsten.temperature, 3400)
        XCTAssertLessThan(tungsten.after, tungsten.before - 1, "tungsten is where the decoder's colour is furthest off")
        let darker = try ChartProfiler.score(tungsten.profile, on: try shot(TestSamples.chart.tungstenUnder))
        XCTAssertLessThan(darker.after, darker.before - 1)
        XCTAssertFalse(sun.profile.suits(temperature: tungsten.temperature)); XCTAssertFalse(tungsten.profile.suits(temperature: sun.temperature))

        // In the app's renderer the profile changes the tungsten photo, half as much at half its amount, and a look
        // profile without a calibration leaves the decoder as it was.
        let (renderer, defaults) = try RawRenderer.open(try shot(TestSamples.chart.tungstenUnder))
        func pixels(_ settings: Adjustments) async throws -> [UInt8] {
            let image = try await renderer.displayImage(settings, maxDimension: 256, sdr: true)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return bytes
        }
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Double { zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) }
        var settings = defaults
        settings.temperature = tungsten.temperature; settings.tint = tungsten.tint
        let plain = try await pixels(settings)
        settings.cameraProfile = tungsten.profile
        let full = try await pixels(settings)
        settings.cameraProfile?.amount = 0.5
        let half = try await pixels(settings)
        XCTAssertGreaterThan(difference(full, plain), 0.3)
        XCTAssertEqual(difference(half, plain), difference(full, plain) / 2, accuracy: 0.3 * difference(full, plain))
        settings.cameraProfile = CameraProfile(name: "Look")
        let look = try await pixels(settings)
        XCTAssertEqual(look, plain)

        // A photo without a chart is refused.
        XCTAssertThrowsError(try ChartProfiler.profile(try TestSamples.require(TestSamples.landscape), camera: "")) { error in
            guard case ChartProfileError.noChart = error else { return XCTFail("\(error)") }
        }
    }
}
