import XCTest
import CevicheTestSupport
import CoreImage
import Vision
@testable import CevicheCore

final class CullingTests: XCTestCase {
    func testBurstsAreQuickRunsFromOneCameraOfTheSameScene() {
        let frames: [BurstDetector.Frame] = [
            .init(date: 100, camera: "A"), .init(date: 100.4, camera: "A"), .init(date: 101, camera: "A"),
            // Too long a pause.
            .init(date: 110, camera: "A"),
            // Another camera at the same moment.
            .init(date: 110.2, camera: "B"),
            .init(date: 200, camera: "A"), .init(date: 201, camera: "A"),
            // A different scene right after.
            .init(date: 201.5, camera: "A"),
            .init(date: nil, camera: "A"),
        ]
        let distances: [Set<Int>: Double] = [[0, 1]: 0.1, [1, 2]: 0.2, [5, 6]: 0.3, [6, 7]: 0.8]
        let groups = BurstDetector.groups(frames, settings: BurstSettings(gap: 3, distance: 0.35)) { distances[[$0, $1]] }
        XCTAssertEqual(groups, [[0, 1, 2], [5, 6]])
        // Shuffled input gives the same runs, in capture order.
        let order = [8, 3, 0, 7, 5, 1, 4, 2, 6]
        let shuffled = order.map { frames[$0] }
        let regrouped = BurstDetector.groups(shuffled, settings: BurstSettings()) { distances[[order[$0], order[$1]]] }.map { $0.map { order[$0] } }
        XCTAssertEqual(regrouped, [[0, 1, 2], [5, 6]])
        // Without feature prints only frames a second apart or less are linked.
        let timeOnly = BurstDetector.groups(frames, settings: BurstSettings()) { _, _ in nil }
        XCTAssertEqual(timeOnly, [[0, 1, 2], [5, 6, 7]])
        // A wider window joins the slower run too.
        let wide = BurstDetector.groups(frames, settings: BurstSettings(gap: 10, distance: 0.35)) { distances[[$0, $1]] ?? 0.1 }
        XCTAssertEqual(wide, [[0, 1, 2, 3], [5, 6]])
    }

    func testLongExposuresCountThePauseAfterTheShutterCloses() {
        // 30 s night frames stamped 31 s apart: a 1 s pause, so one burst.
        let night: [BurstDetector.Frame] = (0..<3).map { .init(date: 100 + Double($0) * 31, camera: "A", exposure: 30) }
        XCTAssertEqual(BurstDetector.groups(night, settings: BurstSettings()) { _, _ in 0.1 }, [[0, 1, 2]])
        // Without the shutter time the same frames are too far apart.
        let unknown = night.map { BurstDetector.Frame(date: $0.date, camera: $0.camera) }
        XCTAssertEqual(BurstDetector.groups(unknown, settings: BurstSettings()) { _, _ in 0.1 }, [])
        // A long pause after a long exposure still splits.
        let paused: [BurstDetector.Frame] = [.init(date: 0, camera: "A", exposure: 30), .init(date: 60, camera: "A", exposure: 30)]
        XCTAssertEqual(BurstDetector.groups(paused, settings: BurstSettings()) { _, _ in 0.1 }, [])
    }

    func testSteadySequencesAreSeriesThroughSmallHoles() {
        // Night frames as a camera stamps them: 15 s exposures every 16–17 s in whole seconds, auto ISO changing.
        var dates: [Double] = []
        var time = 0.0
        for index in 0..<30 { dates.append(time); time += index % 3 == 0 ? 16 : 17 }
        // A hole of two frames is bridged.
        time += 33; for index in 0..<12 { dates.append(time); time += index % 2 == 0 ? 17 : 16 }
        // One of six splits; a short run after it is still the timelapse, and joins the next run over a small hole.
        time += 99; for _ in 0..<3 { dates.append(time); time += 17 }
        time += 50; for _ in 0..<12 { dates.append(time); time += 17 }
        // Half an hour later, the next sequence: a new scene.
        time += 1861; for _ in 0..<20 { dates.append(time); time += 17 }
        let scene = dates.indices.map { $0 < 57 ? 0 : 1 }
        let frames = dates.map { BurstDetector.Frame(date: $0, camera: "A", exposure: 15, focalLength: 16) }
        let found = BurstDetector.detect(frames, settings: BurstSettings()) { scene[$0] == scene[$1] ? 0.06 : 0.57 }
        XCTAssertEqual(found.map(\.members), [Array(0..<42), Array(42..<57), Array(57..<77)])
        XCTAssertEqual(found.map { $0.series?.missingFrames }, [2, 3, 0])
        XCTAssertEqual(found[0].series?.interval ?? 0, 16.6, accuracy: 0.3)
        // Without feature prints the timing alone splits them.
        XCTAssertEqual(BurstDetector.detect(frames, settings: BurstSettings()) { _, _ in nil }.map(\.members),
                       [Array(0..<42), Array(42..<57), Array(57..<77)])
        // A short run at another interval is not part of the timelapse.
        let off = frames.prefix(42) + [700.0, 709, 718].map { BurstDetector.Frame(date: dates[41] + $0, camera: "A", exposure: 8, focalLength: 16) }
        XCTAssertEqual(BurstDetector.detect(Array(off), settings: BurstSettings()) { _, _ in 0.06 }.filter { $0.series != nil }.map(\.members),
                       [Array(0..<42)])
        // Zooming in starts a new composition.
        let zoomed = frames.enumerated().map { BurstDetector.Frame(date: $1.date, camera: "A", exposure: 15, focalLength: $0 < 15 ? 16 : 24) }
        XCTAssertEqual(BurstDetector.detect(zoomed, settings: BurstSettings()) { scene[$0] == scene[$1] ? 0.06 : 0.57 }.map(\.members),
                       [Array(0..<15), Array(15..<42), Array(42..<57), Array(57..<77)])
    }

    func testMergedGroupsJoinTheOneAbove() {
        func photo(_ id: String, _ date: Double) -> CullingPlan.Photo {
            .init(id: id, review: .unreviewed, report: PhotoQualityReport(sharpness: 0.7, subjectSharpness: 0.7, captureDate: date, camera: "A"), featurePrint: nil,
                  exposureTime: 15, focalLength: 16)
        }
        // Two timelapses six frames apart, and a burst after them.
        let first: [CullingPlan.Photo] = (0..<12).map { photo("a\($0)", Double($0) * 17) }
        let second: [CullingPlan.Photo] = (0..<12).map { photo("b\($0)", 18 * 17 + Double($0) * 17) }
        let burst: [CullingPlan.Photo] = (0..<3).map { photo("c\($0)", 5000 + Double($0) * 0.2) }
        let photos = first + second + burst
        XCTAssertEqual(CullingPlan(photos, options: CullingPlan.Options()).bursts.count, 3)
        var plan = CullingPlan(photos, options: CullingPlan.Options(), joins: ["b0"])
        XCTAssertEqual(plan.bursts.map { $0.members.count }, [24, 3])
        XCTAssertEqual(plan.bursts[0].series?.missingFrames, 6)
        // Pick keeps one frame of the merged group, not one of each half.
        XCTAssertEqual(plan.bursts[0].members.filter { plan.proposals[$0] == ReviewState.accepted }.count, 1)
        // A burst joined to a timelapse makes it a longer timelapse; a join whose frame no longer starts a group does nothing.
        plan = CullingPlan(photos, options: CullingPlan.Options(), joins: ["b0", "c0", "a5"])
        XCTAssertEqual(plan.bursts.map { $0.members.count }, [27])
        XCTAssertNotNil(plan.bursts[0].series)
    }

    func testQuickRunsAndShortSequencesStayBursts() {
        // Ten frames a second is a burst however long and steady.
        let fast = (0..<30).map { BurstDetector.Frame(date: Double($0) * 0.1, camera: "A") }
        let burst = BurstDetector.detect(fast, settings: BurstSettings()) { _, _ in 0.1 }
        XCTAssertEqual(burst.map(\.members), [Array(0..<30)])
        XCTAssertNil(burst[0].series)
        // A few steady frames are a burst too.
        let few = (0..<5).map { BurstDetector.Frame(date: Double($0) * 17, camera: "A", exposure: 15) }
        XCTAssertNil(BurstDetector.detect(few, settings: BurstSettings()) { _, _ in 0.1 }.first?.series)
        // A burst next to a series stays its own.
        let mixed = (0..<12).map { BurstDetector.Frame(date: Double($0) * 17, camera: "A", exposure: 15) }
            + (0..<3).map { BurstDetector.Frame(date: 1000 + Double($0) * 0.2, camera: "A") }
        let groups = BurstDetector.detect(mixed, settings: BurstSettings()) { _, _ in 0.1 }
        XCTAssertEqual(groups.map(\.members), [Array(0..<12), [12, 13, 14]])
        XCTAssertEqual(groups.map { $0.series != nil }, [true, false])
    }

    func testIssuesFollowTheSensitivity() {
        var report = PhotoQualityReport(sharpness: 0.7, subjectSharpness: 0.75, brightness: 0.4, brightPercentile: 0.7, highlights: 0.01)
        report.peakSharpness = 0.9
        XCTAssertEqual(report.issues(.strict), [])
        // A portrait with a soft background: most of it is soft, its subject is not.
        report.sharpness = 0.33; report.subjectSharpness = 0.53; report.subject = CGRect(x: 0.4, y: 0.1, width: 0.3, height: 0.6)
        XCTAssertEqual(report.issues(.balanced), [])
        // Shake: even the crispest detail is soft.
        report.peakSharpness = 0.5; report.subjectSharpness = 0.4
        XCTAssertEqual(report.issues(.relaxed), [])
        XCTAssertEqual(report.issues(.balanced), [.blurry])
        // Crisp foreground, soft subject: focus missed.
        report.peakSharpness = 0.84; report.subjectSharpness = 0.42
        XCTAssertEqual(report.issues(.balanced), [.outOfFocus])
        XCTAssertEqual(report.issues(.relaxed), [])
        report = PhotoQualityReport(sharpness: 0.7, brightness: 0.6, brightPercentile: 1, highlights: 0.2, aesthetics: 0.2)
        XCTAssertEqual(report.issues(.balanced), [.overexposed])
        XCTAssertEqual(report.issues(.relaxed), [])
        report = PhotoQualityReport(sharpness: 0.7, brightness: 0.1, brightPercentile: 0.25, aesthetics: 0.2)
        XCTAssertEqual(report.issues(.balanced), [.underexposed])
        // A photo Vision likes is dark on purpose, except under Strict.
        report.aesthetics = 0.7
        XCTAssertEqual(report.issues(.balanced), [])
        XCTAssertEqual(report.issues(.strict), [.underexposed])
        // Both eyes of a face large enough to judge.
        report = PhotoQualityReport(sharpness: 0.7, faces: [.init(bounds: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), leftEye: 0.08, rightEye: 0.1)])
        XCTAssertEqual(report.issues(.balanced), [.eyesClosed])
        report.faces[0].rightEye = 0.3
        XCTAssertEqual(report.issues(.balanced), [])
        report.faces = [.init(bounds: CGRect(x: 0.4, y: 0.2, width: 0.03, height: 0.04), leftEye: 0.05, rightEye: 0.05)]
        XCTAssertEqual(report.issues(.strict), [])
    }

    func testNightAndDeliberatelyDarkPhotosAreNotUnderexposed() {
        // Measures of a blue-hour frame from the library: sharp, median 0.05, nine tenths under 0.24.
        let report = PhotoQualityReport(sharpness: 0.8, brightness: 0.05, brightPercentile: 0.24, aesthetics: 0.2)
        XCTAssertEqual(report.issues(.strict), [.underexposed])
        // A 20 s star photo (EV −6.7), a handheld dusk frame (1/125, f/4, ISO 10000: EV 4.3).
        let stars = ExposureSettings(exposureTime: 20, iso: 2500, fNumber: 2.2)
        XCTAssertEqual(stars.sceneEV ?? 99, -6.7, accuracy: 0.1)
        XCTAssertEqual(report.issues(.strict, exposure: stars), [])
        XCTAssertEqual(report.issues(.balanced, exposure: ExposureSettings(exposureTime: 0.008, iso: 10000, fNumber: 4)), [])
        // Daylight settings (1/250, f/8, ISO 100: EV 14) that came out this dark: a mistake.
        let daylight = ExposureSettings(exposureTime: 1.0 / 250, iso: 100, fNumber: 8, exposureBias: 0)
        XCTAssertEqual(report.issues(.balanced, exposure: daylight), [.underexposed])
        // Dialled down 1.3 stops for a silhouette or a framing: asked for.
        var silhouette = daylight; silhouette.exposureBias = -1.3
        XCTAssertEqual(report.issues(.balanced, exposure: silhouette), [])
        // No EXIF: judged on the picture alone, as before.
        XCTAssertEqual(report.issues(.balanced, exposure: ExposureSettings()), [.underexposed])
    }

    func testEyeOpennessIgnoresTheTiltOfTheHead() throws {
        let open = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 1.2), CGPoint(x: 6, y: 1.5), CGPoint(x: 9, y: 1.2), CGPoint(x: 12, y: 0),
                    CGPoint(x: 9, y: -1.2), CGPoint(x: 6, y: -1.5), CGPoint(x: 3, y: -1.2)]
        let closed = open.map { CGPoint(x: $0.x, y: $0.y * 0.2) }
        let angle = 0.5
        func turned(_ points: [CGPoint]) -> [CGPoint] { points.map { CGPoint(x: $0.x * cos(angle) - $0.y * sin(angle), y: $0.x * sin(angle) + $0.y * cos(angle)) } }
        XCTAssertEqual(try XCTUnwrap(PhotoQualityAnalyzer.openness(open)), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoQualityAnalyzer.openness(turned(open))), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(PhotoQualityAnalyzer.openness(turned(closed))), 0.05, accuracy: 0.001)
    }

    /// A copy of a frame, or the same moment imported twice, is a frame of its burst like any other, called a duplicate
    /// rather than a similar shot: taken at the same instant with nearly the same print.
    func testCopiesInABurstAreDuplicates() throws {
        func print(_ offset: CGFloat) throws -> Data {
            let c = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            c.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            c.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1)); c.fillEllipse(in: CGRect(x: 120 + offset, y: 140, width: 160, height: 160))
            c.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1)); c.fill(CGRect(x: 360 - offset, y: 80, width: 180, height: 260))
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: c.makeImage()!).perform([request])
            return try NSKeyedArchiver.archivedData(withRootObject: XCTUnwrap(request.results?.first), requiringSecureCoding: true)
        }
        let still = try print(0), moved = try print(120)
        func photo(_ id: String, _ date: Double, _ print: Data, sharpness: Double) -> CullingPlan.Photo {
            .init(id: id, review: .unreviewed, report: PhotoQualityReport(sharpness: sharpness, subjectSharpness: sharpness, captureDate: date, camera: "A"),
                  featurePrint: print)
        }
        let photos = [photo("a", 10, still, sharpness: 0.8), photo("a-copy", 10, still, sharpness: 0.8),
                      photo("b", 10.5, still, sharpness: 0.6), photo("c", 11, moved, sharpness: 0.6)]
        let close = try XCTUnwrap(PhotoQualityAnalyzer.distance(still, moved))
        var options = CullingPlan.Options(); options.burst.distance = max(options.burst.distance, Double(close) + 0.1)
        let plan = CullingPlan(photos, options: options)
        XCTAssertEqual(plan.bursts.map(\.members), [["a", "a-copy", "b", "c"]])
        XCTAssertEqual(plan.bursts.first?.best, "a")
        XCTAssertEqual(plan.issues["a-copy"], [.duplicate])
        XCTAssertEqual(plan.issues["b"], [.burstAlternate], "same picture, another moment: a similar shot")
        XCTAssertEqual(plan.issues["c"], [.burstAlternate])
        XCTAssertEqual(plan.proposals["a-copy"], .rejected)
    }

    func testPlanKeepsTheBestFrameOfABurstAndRejectsProblems() {
        func photo(_ id: String, _ date: Double?, sharpness: Double, review: ReviewState = .unreviewed) -> CullingPlan.Photo {
            .init(id: id, review: review, report: PhotoQualityReport(sharpness: sharpness, subjectSharpness: sharpness, captureDate: date, camera: "A"), featurePrint: nil)
        }
        let photos = [photo("a", 10, sharpness: 0.6), photo("b", 10.3, sharpness: 0.8), photo("c", 10.6, sharpness: 0.7),
                      photo("blurry", 100, sharpness: 0.2), photo("fine", 200, sharpness: 0.7), photo("mine", 300, sharpness: 0.1, review: .accepted)]
        var plan = CullingPlan(photos, options: CullingPlan.Options())
        XCTAssertEqual(plan.bursts.map(\.members), [["a", "b", "c"]])
        XCTAssertEqual(plan.bursts.first?.best, "b")
        XCTAssertEqual(plan.proposals, ["a": .rejected, "b": .accepted, "c": .rejected, "blurry": .rejected, "fine": .unreviewed, "mine": .accepted])
        XCTAssertEqual(plan.issues["a"], [.burstAlternate])
        XCTAssertEqual(plan.issues["b"], [])
        XCTAssertEqual(plan.issues["blurry"], [.blurry])

        // A frame the person picked stands in for the assistant's choice.
        var picked = photos; picked[2] = photo("c", 10.6, sharpness: 0.7, review: .accepted)
        plan = CullingPlan(picked, options: CullingPlan.Options())
        XCTAssertEqual(plan.proposals["a"], .rejected)
        XCTAssertEqual(plan.proposals["b"], .rejected)
        XCTAssertEqual(plan.proposals["c"], .accepted)
        XCTAssertEqual(plan.issues["b"], [.burstAlternate])
        XCTAssertEqual(plan.issues["c"], [])

        // When every frame is blurry none is kept.
        let soft = [photo("x", 10, sharpness: 0.2), photo("y", 10.5, sharpness: 0.25)]
        plan = CullingPlan(soft, options: CullingPlan.Options())
        XCTAssertEqual(plan.proposals, ["x": .rejected, "y": .rejected])
        XCTAssertEqual(plan.bursts.first?.best, "y")

        // A group the person made is one burst however far apart its photos were taken, without capture times too.
        let group = [photo("g1", 10, sharpness: 0.5), photo("g2", 500, sharpness: 0.9), photo("g3", nil, sharpness: 0.6)]
        XCTAssertTrue(CullingPlan(group, options: CullingPlan.Options()).bursts.isEmpty)
        plan = CullingPlan(group, options: CullingPlan.Options(), oneBurst: true)
        XCTAssertEqual(plan.bursts.map(\.members), [["g1", "g2", "g3"]])
        XCTAssertEqual(plan.proposals, ["g1": .rejected, "g2": .accepted, "g3": .rejected])
        // One photo is kept from the group even when every frame is blurry.
        plan = CullingPlan(soft, options: CullingPlan.Options(), oneBurst: true)
        XCTAssertEqual(plan.proposals, ["x": .rejected, "y": .accepted])
    }

    /// A synthetic scene of hard-edged shapes, then the same scene blurred, darkened and brightened.
    func testAnalyzerSeesBlurAndExposureOnASyntheticScene() throws {
        let width = 1600, height = 1067
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.45, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let level = Double.random(in: 0.1...0.85, using: &generator)
            context.setFillColor(CGColor(red: level, green: level * 0.9, blue: 1 - level, alpha: 1))
            context.fill(CGRect(x: .random(in: 0..<width, using: &generator), y: .random(in: 0..<height, using: &generator),
                                width: .random(in: 10...120, using: &generator), height: .random(in: 10...120, using: &generator)))
        }
        let sharp = try XCTUnwrap(context.makeImage())
        let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        func variant(blur: Double = 0, ev: Double = 0) throws -> CGImage {
            var image = CIImage(cgImage: sharp)
            if blur > 0 { image = image.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: CIImage(cgImage: sharp).extent) }
            if ev != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev]) }
            return try XCTUnwrap(ci.createCGImage(image, from: CIImage(cgImage: sharp).extent))
        }
        let crisp = try PhotoQualityAnalyzer.analyze(sharp).report
        let soft = try PhotoQualityAnalyzer.analyze(try variant(blur: 4)).report
        XCTAssertGreaterThan(try XCTUnwrap(crisp.sharpness), 0.6)
        XCTAssertLessThan(try XCTUnwrap(soft.sharpness), 0.3)
        XCTAssertFalse(crisp.issues(.balanced).contains(.blurry))
        XCTAssertTrue(soft.issues(.balanced).contains(.blurry))
        var dark = try PhotoQualityAnalyzer.analyze(try variant(ev: -3)).report, bright = try PhotoQualityAnalyzer.analyze(try variant(ev: 2.5)).report
        dark.aesthetics = nil; bright.aesthetics = nil
        XCTAssertTrue(dark.issues(.balanced).contains(.underexposed), "\(dark)")
        XCTAssertTrue(bright.issues(.balanced).contains(.overexposed), "\(bright)")
        XCTAssertFalse(crisp.issues(.balanced).contains(.overexposed))
        XCTAssertFalse(crisp.issues(.balanced).contains(.underexposed))
    }

    /// The sample RAWs as shot are fine; blurred, they are not, and consecutive shots of one scene are close.
    func testAnalyzerOnSamplePhotos() throws {
        let first = try TestSamples.require(TestSamples.burst.first), second = try TestSamples.require(TestSamples.burst.second)
        let other = try TestSamples.require(TestSamples.landscape)
        let a = try PhotoQualityAnalyzer.analyze(first), b = try PhotoQualityAnalyzer.analyze(second), c = try PhotoQualityAnalyzer.analyze(other)
        for result in [a, b, c] { XCTAssertEqual(result.report.issues(.balanced), [], "\(result.report)") }
        XCTAssertEqual(try XCTUnwrap(b.report.captureDate) - (try XCTUnwrap(a.report.captureDate)), 3, accuracy: 0.5)
        XCTAssertFalse(a.report.camera.isEmpty)
        let near = try XCTUnwrap(PhotoQualityAnalyzer.distance(try XCTUnwrap(a.featurePrint), try XCTUnwrap(b.featurePrint)))
        let far = try XCTUnwrap(PhotoQualityAnalyzer.distance(try XCTUnwrap(a.featurePrint), try XCTUnwrap(c.featurePrint)))
        XCTAssertLessThan(near, BurstSettings().distance)
        XCTAssertGreaterThan(far, BurstSettings().distance)
    }

    func testReportsAreCachedPerOriginal() async throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        let prepared = try CatalogImporter.prepare(url)
        var ids: [String] = []
        for index in 0..<3 {
            var asset = prepared.0; asset.id = "photo-\(index)"; asset.importPath += "-\(index)"; asset.captureTime = "2026-10-31T21:00:0\(index)"
            ids.append(try await store.insert(asset, thumbnail: nil).id)
        }
        let report = PhotoQualityReport(sharpness: 0.35, brightness: 0.4, captureDate: 12, camera: "A")
        for id in ids { try await store.saveCullingReport(report, featurePrint: Data([1, 2]), for: try await store.asset(id)) }
        var cached = try await store.cullingReports(ids)
        XCTAssertEqual(Set(cached.keys), Set(ids))
        XCTAssertEqual(cached[ids[0]]?.report, report)
        XCTAssertEqual(cached[ids[0]]?.featurePrint, Data([1, 2]))
        // Another analyzer version, or a different original, is measured again.
        cached = try await store.cullingReports(ids, version: "quality-v0"); XCTAssertTrue(cached.isEmpty)
        let replacement = directory.appendingPathComponent("replacement.jpg")
        try FileManager.default.copyItem(at: url, to: replacement)
        try await store.replaceOriginal(replacement, assetID: ids[2])
        cached = try await store.cullingReports(ids); XCTAssertEqual(Set(cached.keys), [ids[0], ids[1]])

        // A collapsed group shows only its cover, unless every grouped photo is asked for.
        _ = try await store.stack(ids)
        var all = CatalogFilter()
        var count = try await store.count(filter: all); XCTAssertEqual(count, 1)
        all.everyGroupedPhoto = true
        count = try await store.count(filter: all); XCTAssertEqual(count, 3)

        // Deleting the photo drops its report.
        try await store.removeFromCatalog(try await store.removalPlan(for: [ids[1]]), deletingCopies: false)
        cached = try await store.cullingReports(ids); XCTAssertEqual(Set(cached.keys), [ids[0]])
    }

    func testPairTriageSuggestsFromTheCameraJPEG() throws {
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var raw = try CatalogImporter.prepare(url).0.asset, jpeg = raw
        raw.id = "raw"; jpeg.id = "jpeg"
        raw.lastEditedAt = nil; jpeg.lastEditedAt = nil; raw.review = .unreviewed; jpeg.review = .unreviewed
        raw.exposureTime = 1 / 250; raw.iso = 100; raw.fNumber = 8; raw.exposureBias = 0
        jpeg.exposureTime = nil; jpeg.iso = nil; jpeg.fNumber = nil; jpeg.exposureBias = nil
        let clean = PhotoQualityReport(sharpness: 0.8, subjectSharpness: 0.85, brightness: 0.45, brightPercentile: 0.8, highlights: 0.005, shadows: 0.01, aesthetics: 0.3, colorCast: 0.01)
        func suggest(_ report: PhotoQualityReport?, raw: CatalogAsset = raw, jpeg: CatalogAsset = jpeg) -> PairTriage.Suggestion {
            var measured = report
            if var given = report, given.peakSharpness == nil { given.peakSharpness = given.sharpness; measured = given }
            return PairTriage.suggest(raw: raw, processed: jpeg, report: measured)
        }
        XCTAssertEqual(suggest(clean), .init(.archiveJPEG))
        XCTAssertEqual(suggest(nil), .init(.undecided))

        var report = clean; report.colorCast = 0.07
        XCTAssertEqual(suggest(report), .init(.keepRAW, .whiteBalance))
        report = clean; report.highlights = 0.08
        XCTAssertEqual(suggest(report), .init(.keepRAW, .highlights))
        report = clean; report.shadows = 0.2
        XCTAssertEqual(suggest(report), .init(.keepRAW, .shadows))
        var biased = raw; biased.exposureBias = -1.3
        XCTAssertEqual(suggest(clean, raw: biased), .init(.keepRAW, .exposureCompensation))
        report = clean; report.sharpness = 0.3; report.subjectSharpness = 0.3; report.peakSharpness = 0.3
        XCTAssertEqual(suggest(report), .init(.rejectBoth, .blurry))

        // Dark long exposures are kept for the RAW, soft or not: stars wide open, other night scenes otherwise.
        var night = clean; night.brightness = 0.06; night.brightPercentile = 0.2; night.sharpness = 0.3; night.peakSharpness = 0.3
        var long = raw; long.exposureTime = 20; long.fNumber = 2.8; long.iso = 3200
        XCTAssertEqual(suggest(night, raw: long), .init(.keepRAW, .stars))
        long.exposureTime = 1; long.fNumber = 8; long.iso = 100
        XCTAssertEqual(suggest(night, raw: long), .init(.keepRAW, .night))
        var blank = clean; blank.sharpness = nil; blank.peakSharpness = nil; blank.brightness = 0; blank.brightPercentile = 0.01
        XCTAssertEqual(suggest(blank), .init(.rejectBoth, .blank))

        // The person's edits and flags come first.
        var edited = raw; edited.lastEditedAt = Date()
        XCTAssertEqual(suggest(clean, raw: edited), .init(.keepRAW, .edited))
        var editedJPEG = jpeg; editedJPEG.lastEditedAt = Date()
        XCTAssertEqual(suggest(clean, jpeg: editedJPEG), .init(.keepJPEG, .edited))
        var rejected = raw; rejected.review = .rejected; var rejectedJPEG = jpeg; rejectedJPEG.review = .rejected
        XCTAssertEqual(suggest(clean, raw: rejected, jpeg: rejectedJPEG), .init(.rejectBoth, .flagged))
        var picked = raw; picked.review = .accepted
        XCTAssertEqual(suggest(clean, raw: picked), .init(.keepRAW, .flagged))
        var pickedJPEG = jpeg; pickedJPEG.review = .accepted
        XCTAssertEqual(suggest(clean, raw: rejected, jpeg: pickedJPEG), .init(.keepJPEG, .flagged))
        XCTAssertEqual(suggest(clean, raw: rejected), .init(.archiveJPEG, .flagged))
    }

    func testRawAndJPEGOfOneShotArePaired() async throws {
        let paths = ["/card/DCIM/DSC0001.ARW", "/card/DCIM/DSC0001.JPG", "/card/DCIM/dsc0002.arw", "/card/DCIM/DSC0002.HIF",
                     // Same name in another folder, a lone RAW, and a name with two JPEGs.
                     "/card/OTHER/DSC0003.JPG", "/card/DCIM/DSC0003.ARW", "/card/DCIM/DSC0004.NEF",
                     "/card/DCIM/DSC0005.CR3", "/card/DCIM/DSC0005.JPG", "/card/DCIM/DSC0005.jpeg"]
        let pairs = RawJPEGPairs.pairs(paths) { $0 }.map { [paths[$0.raw], paths[$0.processed]] }
        XCTAssertEqual(pairs, [["/card/DCIM/DSC0001.ARW", "/card/DCIM/DSC0001.JPG"], ["/card/DCIM/dsc0002.arw", "/card/DCIM/DSC0002.HIF"]])

        // Catalog photos also need the same capture time when both have one.
        let (directory, url) = try CatalogTests().fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var raw = try CatalogImporter.prepare(url).0, jpeg = raw, other = raw
        raw.id = "raw"; raw.sourcePath = "/shoot/DSC0010.ARW"; raw.captureTime = "2026-11-02T10:00:00"
        jpeg.id = "jpeg"; jpeg.sourcePath = "/shoot/DSC0010.JPG"; jpeg.captureTime = "2026-11-02T10:00:00"
        other.id = "other"; other.sourcePath = "/shoot/DSC0011.JPG"; other.captureTime = "2026-11-02T10:00:01"
        var later = other; later.id = "later"; later.sourcePath = "/shoot/DSC0011.ARW"; later.captureTime = "2026-11-03T09:00:00"
        let found = RawJPEGPairs.pairs([raw, jpeg, other, later].map(\.asset)).map { [$0.raw.id, $0.processed.id] }
        XCTAssertEqual(found, [["raw", "jpeg"]])

        // A pair's group is under its RAW, whatever sorts first.
        let store = try CatalogStore(root: directory.appendingPathComponent("Catalog"))
        var a = raw, b = jpeg
        a.id = "z-raw"; a.importPath += "-raw"; b.id = "a-jpeg"; b.importPath += "-jpeg"
        _ = try await store.insert(a, thumbnail: nil); _ = try await store.insert(b, thumbnail: nil)
        let cover = try await store.stack(["z-raw", "a-jpeg"], cover: "z-raw")
        XCTAssertEqual(cover, "z-raw")
        let members = try await store.stackMembers(["z-raw"])
        XCTAssertEqual(Set(members.map(\.id)), ["z-raw", "a-jpeg"])
    }

    /// A RAW and the JPEG the camera wrote with it look alike enough to be taken for a burst, which is why the tools
    /// treat them as one shot; the JPEG measures like its RAW.
    func testCameraJPEGMeasuresLikeItsRAW() throws {
        let raw = try TestSamples.require(TestSamples.rawJPEGPair.raw), jpeg = try TestSamples.require(TestSamples.rawJPEGPair.jpeg)
        let a = try PhotoQualityAnalyzer.analyze(raw), b = try PhotoQualityAnalyzer.analyze(jpeg)
        XCTAssertLessThan(try XCTUnwrap(PhotoQualityAnalyzer.distance(try XCTUnwrap(a.featurePrint), try XCTUnwrap(b.featurePrint))), 0.2)
        XCTAssertEqual(a.report.captureDate, b.report.captureDate)
        // A portrait with a soft background: sharp where it matters, so not blurry.
        XCTAssertEqual(a.report.issues(.balanced), [])
        XCTAssertEqual(b.report.issues(.balanced), [])
    }
}
