import XCTest
import CoreImage
import CoreVideo
@testable import CevicheCore

final class TimelapsePlanTests: XCTestCase {
    private func times(_ seconds: [Double?]) -> [Date?] { seconds.map { $0.map { Date(timeIntervalSince1970: 1_728_600_000 + $0) } } }

    func testSteadySeriesIsOneFramePerPhoto() throws {
        let plan = try TimelapsePlan(times: times([0, 10, 20, 30]), usual: 10, step: 10, fill: .blend, pauseLimit: nil)
        XCTAssertEqual(plan.frames, (0..<4).map { TimelapsePlan.Frame(photo: $0) })
    }

    func testBurstKeepsTheSeriesPace() throws {
        // Photos 1–4 were shot every 2.5 s inside a 10 s series: they share the time of one frame.
        let plan = try TimelapsePlan(times: times([0, 10, 12.5, 15, 17.5, 20, 30]), usual: 10, step: 10, fill: .hold, pauseLimit: nil)
        XCTAssertEqual(plan.frames.map(\.photo), [0, 1, 5, 6], "30 s of capture at 10 s a frame")
        XCTAssertEqual(plan.uses[2], nil, "A photo inside the burst shows in no frame")
    }

    func testPauseIsFilledAndCanBeShortened() throws {
        let gap = times([0, 10, 50, 60])
        let blended = try TimelapsePlan(times: gap, usual: 10, step: 10, fill: .blend, pauseLimit: nil)
        XCTAssertEqual(blended.frames.count, 7)
        XCTAssertEqual(blended.frames[2], TimelapsePlan.Frame(photo: 1, next: 2, weight: 0.25))
        XCTAssertEqual(blended.frames[4], TimelapsePlan.Frame(photo: 1, next: 2, weight: 0.75))
        XCTAssertEqual(blended.frames[5], TimelapsePlan.Frame(photo: 2))
        let shortened = try TimelapsePlan(times: gap, usual: 10, step: 10, fill: .blend, pauseLimit: 20)
        XCTAssertEqual(shortened.frames.count, 5, "The 40 s pause plays as 20 s")
        XCTAssertEqual(shortened.frames[2], TimelapsePlan.Frame(photo: 1, next: 2, weight: 0.5))
    }

    func testHalfStepDoublesTheFramesAndRepeatsTakeNoTime() throws {
        let plan = try TimelapsePlan(times: times([0, 10, 10, 20]), usual: 10, step: 5, fill: .hold, pauseLimit: nil)
        XCTAssertEqual(plan.frames.count, 5)
        XCTAssertFalse(plan.frames.contains { $0.photo == 1 }, "A repeat of the same moment shows only once: the later one")
        let untimed = try TimelapsePlan(times: times([0, 10, nil]), usual: 10, step: 10, fill: .hold, pauseLimit: nil)
        XCTAssertEqual(untimed.frames.map(\.photo), [0, 1, 2], "A photo without a time follows at the usual interval")
    }

    func testTooManyFramesIsRefused() {
        XCTAssertThrowsError(try TimelapsePlan(times: times([0, 3600 * 24]), usual: 10, step: 0.1, fill: .hold, pauseLimit: nil))
    }

    func testSettingsChooseThePlan() throws {
        let captures = [0.0, 10, 12, 20].enumerated().map { TimelapseCapture(filename: "F\($0.offset)", date: Date(timeIntervalSince1970: $0.element)) }
        var settings = TimelapseSettings()
        XCTAssertEqual(try TimelapsePlan(settings: settings, captures: captures, interval: 8).frames.count, 4)
        settings.timing = .captureTime; settings.fill = .hold
        XCTAssertEqual(try TimelapsePlan(settings: settings, captures: captures, interval: 10).frames.map(\.photo), [0, 1, 3], "The usual interval by default")
        settings.frameStep = 5
        XCTAssertEqual(try TimelapsePlan(settings: settings, captures: captures, interval: 10).frames.count, 5)
        let saved = try JSONDecoder().decode(TimelapseSettings.self, from: Data(#"{"codec":"hevc"}"#.utf8))
        XCTAssertEqual(saved.pauseLimit, 3); XCTAssertEqual(saved.timing, .perPhoto)
    }

    func testMovementMarks() {
        func shift(_ x: Double) -> CGVector? { CGVector(dx: x, dy: 0) }
        // A knocked frame goes out and comes back; only it is marked.
        XCTAssertEqual(TimelapseAlignment.marks([shift(0), shift(0), shift(0.05), shift(-0.05), shift(0), shift(0)]),
                       [nil, nil, .unaligned, nil, nil, nil])
        // A camera that moved and stayed.
        XCTAssertEqual(TimelapseAlignment.marks([shift(0), shift(0), shift(0), shift(0.05), shift(0), shift(0), shift(0)]),
                       [nil, nil, nil, .cameraMoved, nil, nil, nil])
        // A steady slide is no movement to warn about.
        XCTAssertEqual(TimelapseAlignment.marks([shift(0)] + Array(repeating: shift(0.02), count: 6)), Array(repeating: nil, count: 7))
    }

    func testRegistrationFindsAShift() throws {
        let context = CIContext()
        func image(offset: CGFloat) -> CGImage {
            // Bars of different widths, so the shift has one answer.
            var scene = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 213))
            for (x, width) in [(40.0, 12.0), (90, 30), (170, 8), (230, 22)] {
                scene = CIImage(color: .white).cropped(to: CGRect(x: x + offset, y: 30, width: width, height: 150)).composited(over: scene)
            }
            return context.createCGImage(scene, from: CGRect(x: 0, y: 0, width: 320, height: 213))!
        }
        let shift = try XCTUnwrap(TimelapseAlignment.shift(from: image(offset: 0), to: image(offset: 16)))
        XCTAssertEqual(abs(shift.dx), 16.0 / 320, accuracy: 0.01, "\(shift)")
        let still = try XCTUnwrap(TimelapseAlignment.shift(from: image(offset: 0), to: image(offset: 0)))
        XCTAssertEqual(hypot(still.dx, still.dy), 0, accuracy: 0.005)
    }

    func testBlendMixesLight() throws {
        let size = CGSize(width: 8, height: 8), context = CIContext()
        func photo(_ value: CGFloat) -> TimelapsePhoto {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_64RGBAHalf, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &buffer)
            context.render(CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: TimelapsePhoto.space)!).cropped(to: CGRect(origin: .zero, size: size)), to: buffer!,
                           bounds: CGRect(origin: .zero, size: size), colorSpace: TimelapsePhoto.space)
            return TimelapsePhoto(pixels: buffer!)
        }
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_64RGBAHalf, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &out)
        let frame = VideoFrameBuffer(pixels: out!, colorSpace: TimelapsePhoto.space)
        try TimelapseCompositor().compose(TimelapsePlan.Frame(photo: 0, next: 1, weight: 0.25), photos: [0: photo(0), 1: photo(0.8)], into: frame)
        CVPixelBufferLockBaseAddress(out!, .readOnly); defer { CVPixelBufferUnlockBaseAddress(out!, .readOnly) }
        let red = Float(CVPixelBufferGetBaseAddress(out!)!.assumingMemoryBound(to: Float16.self)[0])
        XCTAssertEqual(red, 0.2, accuracy: 0.01, "A quarter of the way, in linear light")
    }
}
