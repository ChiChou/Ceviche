import XCTest
import CevicheTestSupport
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
@testable import CevicheCore

final class TimelapseTests: XCTestCase {
    private func capture(_ name: String, _ seconds: Double?, camera: String = "Sony ILCE-7RM5", size: CGSize = CGSize(width: 9504, height: 6336)) -> TimelapseCapture {
        TimelapseCapture(filename: name, date: seconds.map { Date(timeIntervalSince1970: 1_728_600_000 + $0) }, camera: camera, size: size)
    }

    func testEXIFTimesKeepSubsecondsAndOffsets() throws {
        let plain = try XCTUnwrap(TimelapseCapture.date("2024:10:11 22:15:03", subseconds: nil, offset: nil))
        let fraction = try XCTUnwrap(TimelapseCapture.date("2024:10:11 22:15:03", subseconds: "250", offset: nil))
        XCTAssertEqual(fraction.timeIntervalSince(plain), 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(TimelapseCapture.date("2024:10:11 22:15:03", subseconds: "07", offset: nil)).timeIntervalSince(plain), 0.07, accuracy: 0.0001)
        let east = try XCTUnwrap(TimelapseCapture.date("2024:10:11 22:15:03", subseconds: nil, offset: "+02:00"))
        XCTAssertEqual(plain.timeIntervalSince(east), 7200, "An offset moves the moment, so series across a time-zone change still order")
        XCTAssertNil(TimelapseCapture.date("0000:00:00 00:00:00", subseconds: nil, offset: nil).flatMap { $0 > Date(timeIntervalSince1970: 0) ? $0 : nil })
        XCTAssertNil(TimelapseCapture.date("not a date", subseconds: nil, offset: nil))
    }

    func testSeriesOrdersByCaptureTimeNotFilename() {
        // A camera counter that wrapped: DSC09999 comes before DSC00001.
        let series = TimelapseSeries([capture("DSC00001.ARW", 10), capture("DSC09998.ARW", 0), capture("DSC09999.ARW", 5), capture("DSC00002.ARW", 15)])
        XCTAssertEqual(series.order, [1, 2, 0, 3])
        XCTAssertEqual(series.interval, 5)
        XCTAssertEqual(series.span, 15)
        XCTAssertEqual(series.issues, [])
    }

    func testBrokenSeriesIsReported() {
        var captures = (0..<10).map { capture(String(format: "A%02d.ARW", $0), Double($0) * 4) }
        captures[6].date = captures[5].date!.addingTimeInterval(20) // 4 frames' worth of pause
        for index in 7..<10 { captures[index].date = captures[6].date!.addingTimeInterval(Double(index - 6) * 4) }
        captures.append(capture("A05 copy.ARW", 20))                // same moment as A05
        captures.append(capture("Z.JPG", nil, camera: "Apple iPhone 16 Pro", size: CGSize(width: 4032, height: 3024)))
        let issues = TimelapseSeries(captures).issues
        XCTAssertTrue(issues.contains(.missingTime(["Z.JPG"])))
        XCTAssertTrue(issues.contains(.gap(after: "A05.ARW", before: "A06.ARW", seconds: 20, missingFrames: 4)), "\(issues)")
        XCTAssertTrue(issues.contains(.sameTime(["A05 copy.ARW", "A05.ARW"])), "\(issues)")
        XCTAssertTrue(issues.contains(.cameras(["Sony ILCE-7RM5", "Apple iPhone 16 Pro"])))
        XCTAssertTrue(issues.contains(.sizes(2)))
        XCTAssertEqual(TimelapseSeries(captures).order.last, captures.count - 1, "Photos without a time play last")
    }

    func testFramesAreMarkedForWhatTheyBreak() {
        var captures = (0..<8).map { capture(String(format: "A%02d.ARW", $0), Double($0) * 4) }
        captures[5].date = captures[4].date!.addingTimeInterval(16)        // 3 frames' worth of pause before A05
        for index in 6..<8 { captures[index].date = captures[5].date!.addingTimeInterval(Double(index - 5) * 4) }
        captures.append(capture("A02 copy.ARW", 8))                       // same moment as A02
        captures.append(capture("Z.JPG", nil, camera: "Apple iPhone 16 Pro", size: CGSize(width: 4032, height: 3024)))
        let series = TimelapseSeries(captures)
        let names = series.order.map { captures[$0].filename }
        func marked(_ test: (TimelapseSeries.Mark) -> Bool) -> [String] { series.marks.indices.filter { series.marks[$0].contains(where: test) }.map { names[$0] } }
        XCTAssertEqual(marked { $0 == .missingTime }, ["Z.JPG"])
        XCTAssertEqual(marked { $0 == .afterGap(seconds: 16, missingFrames: 3) }, ["A05.ARW"])
        XCTAssertEqual(marked { $0 == .sameTime }.count, 1, "The first of the same moment stays unmarked")
        XCTAssertEqual(marked { $0 == .otherCamera("Apple iPhone 16 Pro") }, ["Z.JPG"])
        XCTAssertEqual(marked { $0 == .otherSize }, ["Z.JPG"])
        XCTAssertEqual(series.frames(for: .missingTime(["Z.JPG"])).map { names[$0] }, ["Z.JPG"])
        XCTAssertEqual(series.frames(for: .gap(after: "A04.ARW", before: "A05.ARW", seconds: 16, missingFrames: 3)).map { names[$0] }, ["A05.ARW"])
        XCTAssertEqual(series.frames(for: .sameTime(["A02 copy.ARW", "A02.ARW"])).count, 1)
        // Without the odd photos the series reads clean but for its gap.
        let kept = series.order.filter { !["Z.JPG", "A02 copy.ARW"].contains(captures[$0].filename) }.map { captures[$0] }
        XCTAssertEqual(TimelapseSeries(kept).issues, [.gap(after: "A04.ARW", before: "A05.ARW", seconds: 16, missingFrames: 3)])
    }

    func testFasterBurstIsReported() {
        // A burst at 13 s before the intervalometer settled on 96 s, as in a real aurora sequence.
        var times = [0.0]
        for _ in 0..<10 { times.append(times.last! + 13.5) }
        for _ in 0..<20 { times.append(times.last! + 96) }
        let issues = TimelapseSeries(times.enumerated().map { capture(String(format: "F%02d", $0.offset), $0.element) }).issues
        XCTAssertEqual(issues, [.faster(from: "F00", to: "F10", seconds: 13.5, frames: 11)])
        let series = TimelapseSeries(times.enumerated().map { capture(String(format: "F%02d", $0.offset), $0.element) })
        XCTAssertEqual(series.frames(for: issues[0]), Array(0...10))
        XCTAssertEqual(series.marks.filter { $0.contains(.faster) }.count, 11)
    }

    func testIrregularButSteadyIntervalsAreNotGaps() {
        // Exposure ramping changes the interval a little from frame to frame.
        let times = [0, 5.1, 9.9, 15.2, 20.0, 25.3, 30.1, 35.0]
        XCTAssertEqual(TimelapseSeries(times.enumerated().map { capture("F\($0.offset)", $0.element) }).issues, [])
    }

    func testOutputSizesFitTheSizeClass() {
        var settings = TimelapseSettings()
        let photo = CGSize(width: 6000, height: 4000)
        settings.resolution = .uhd2160
        for (aspect, width, height) in [(VideoAspect.widescreen, 3840, 2160), (.standard, 2880, 2160), (.flat, 3840, 2076), (.scope, 3840, 1606), (.original, 3240, 2160)] {
            settings.aspect = aspect
            XCTAssertEqual(settings.outputSize(photo: photo), CGSize(width: width, height: height), "\(aspect)")
        }
        settings.aspect = .original
        XCTAssertEqual(settings.outputSize(photo: CGSize(width: 4000, height: 6000)), CGSize(width: 1440, height: 2160), "Portrait photos make a portrait video")
        settings.aspect = .custom; settings.customWidth = 1081; settings.customHeight = 1349
        XCTAssertEqual(settings.outputSize(photo: photo), CGSize(width: 1082, height: 1350), "Encoders need even sizes")
    }

    func testH264RejectsSizesBeyondItsLevel() {
        var settings = TimelapseSettings()
        settings.resolution = .uhd4320; settings.codec = .h264
        XCTAssertThrowsError(try settings.validate(photo: CGSize(width: 6000, height: 4000)))
        settings.codec = .hevc
        XCTAssertNoThrow(try settings.validate(photo: CGSize(width: 6000, height: 4000)))
    }

    func testCropStaysInsideThePhotoAndKeepsItsProportions() {
        let photo = CGSize(width: 6000, height: 4000)
        XCTAssertEqual(TimelapseCrop().rect(in: photo, aspect: 16.0 / 9), CGRect(x: 0, y: 312.5, width: 6000, height: 3375))
        let corner = TimelapseCrop(centerX: 0.99, centerY: 0.01, scale: 0.5).rect(in: photo, aspect: 16.0 / 9)
        XCTAssertEqual(corner.maxX, 6000, accuracy: 0.001); XCTAssertEqual(corner.minY, 0, accuracy: 0.001)
        XCTAssertEqual(corner.width / corner.height, 16.0 / 9, accuracy: 0.0001)
        let framed = TimelapseCrop.framing(CGRect(x: 1000, y: 1000, width: 1600, height: 900), in: photo, aspect: 16.0 / 9)
        XCTAssertEqual(framed.rect(in: photo, aspect: 16.0 / 9).origin.x, 1000, accuracy: 0.001)
        XCTAssertEqual(framed.rect(in: photo, aspect: 16.0 / 9).width, 1600, accuracy: 0.001)
        // The same crop on a portrait photo still has the video's proportions.
        let portrait = framed.rect(in: CGSize(width: 4000, height: 6000), aspect: 16.0 / 9)
        XCTAssertEqual(portrait.width / portrait.height, 16.0 / 9, accuracy: 0.0001)
    }

    /// Writes `frames` frames of a moving gradient, in as many passes as the encoder asks for.
    private func writeMovie(_ settings: TimelapseSettings, to url: URL, frames: Int = 10, metadata: TimelapseMetadata? = nil) async throws -> (writer: TimelapseWriter, passes: Int) {
        let size = CGSize(width: 640, height: 360), context = CIContext()
        let writer = try TimelapseWriter(url: url, settings: settings, size: size, frames: frames, metadata: metadata)
        var passes = 0
        while let runs = await writer.nextPass() {
            passes += 1
            for index in runs.flatMap({ Array($0) }) {
                let buffer = try writer.makeBuffer()
                let shift = CGFloat(index) / CGFloat(frames)
                let image = CIFilter(name: "CILinearGradient", parameters: [
                    "inputPoint0": CIVector(x: 640 * shift, y: 0), "inputPoint1": CIVector(x: 640 * shift + 200, y: 360),
                    "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.9), "inputColor1": CIColor(red: 1, green: 0.8, blue: 0.3)])!.outputImage!
                context.render(image.cropped(to: CGRect(origin: .zero, size: size)), to: buffer.pixels, bounds: CGRect(origin: .zero, size: size), colorSpace: buffer.colorSpace)
                try await writer.append(buffer, at: index)
            }
        }
        try await writer.finish(overwriteExisting: false)
        return (writer, passes)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-timelapse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testEveryEncoderWritesAPlayableMovie() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for codec in VideoCodec.allCases { for container in codec.containers { for range in VideoColor.allCases where range == .sdr || codec.supportsWideColor {
            var settings = TimelapseSettings(); settings.codec = codec; settings.container = container; settings.color = range; settings.framesPerSecond = 25
            let label = "\(codec) \(container) \(range)"
            let url = directory.appendingPathComponent("test.\(container.fileExtension)")
            _ = try await writeMovie(settings, to: url)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 0.4, accuracy: 0.001, label)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let (natural, rate, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
            XCTAssertEqual(natural, CGSize(width: 640, height: 360), label)
            XCTAssertEqual(rate, 25, accuracy: 0.01, label)
            let format = try XCTUnwrap(formats.first)
            let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            XCTAssertEqual(transfer, range.bufferTags.transfer as String, label)
            if codec == .hevc && range != .sdr {
                XCTAssertEqual(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int, 10, "Main 10: \(label)")
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".") }
            XCTAssertEqual(leftovers, [], "The temporary files are moved into place or removed: \(label)")
            let fileType = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
            XCTAssertEqual(fileType, container == .mov ? .quickTimeMovie : .mpeg4Movie, label)
            XCTAssertEqual(try Self.topLevelBoxes(url).filter { ["moov", "mdat"].contains($0) }, ["moov", "mdat"], "The index comes first for fast start: \(label)")
            try FileManager.default.removeItem(at: url)
        } } }
    }

    /// The four-character types of a movie file's top-level boxes, in order.
    private static func topLevelBoxes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var offset = 0, types: [String] = []
        while offset + 8 <= data.count {
            var size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            types.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            if size == 1, offset + 16 <= data.count { size = data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) } }
            guard size >= 8 else { break }
            offset += size
        }
        return types
    }

    func testFractionalFrameRatesKeepExactTiming() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimelapseSettings(); settings.frameRate = VideoFrameRate(24, fractional: true)
        XCTAssertEqual(settings.frameRate.rate, 23.976, accuracy: 0.001)
        XCTAssertEqual(settings.duration(frames: 24000), 1001, accuracy: 0.0001)
        let url = directory.appendingPathComponent("ntsc.mov"); settings.container = .mov
        _ = try await writeMovie(settings, to: url, frames: 48)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 48 * 1001 / 24000, accuracy: 0.0001)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let rate = try await XCTUnwrap(track).load(.nominalFrameRate)
        XCTAssertEqual(Double(rate), 24000.0 / 1001, accuracy: 0.01)
        settings.frameRate = VideoFrameRate(25, fractional: true)
        XCTAssertEqual(settings.frameRate, VideoFrameRate(25), "PAL rates have no NTSC counterpart")
    }

    func testMetadataRecordsWhenWhereAndWhat() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = capture("A.ARW", 0), second = capture("B.ARW", 60)
        first.make = "SONY"; first.model = "ILCE-7RM5"
        second.location = (46.4102, 11.844, 2105)
        let metadata = TimelapseMetadata([first, second])
        XCTAssertEqual(metadata.iso6709, "+46.4102+011.8440+2105.000/")
        for container in VideoContainer.allCases {
            var settings = TimelapseSettings(); settings.container = container
            let url = directory.appendingPathComponent("tagged.\(container.fileExtension)")
            _ = try await writeMovie(settings, to: url, metadata: metadata)
            let asset = AVURLAsset(url: url)
            let date = try await asset.load(.creationDate)
            let dateValue = try await date?.load(.dateValue)
            XCTAssertEqual(dateValue, first.date, "\(container)")
            let items = try await asset.load(.metadata)
            var values: [String] = []
            for item in items { if let value = try await item.load(.stringValue) { values.append(value) } }
            XCTAssertTrue(values.contains("+46.4102+011.8440+2105.000/"), "\(container): \(values)")
            if container == .mov { XCTAssertTrue(values.contains("ILCE-7RM5"), "\(container): \(values)") }
        }
    }

    func testTwoPassEncodingRendersEveryFrameEachPass() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for codec in [VideoCodec.h264, .hevc] {
            var settings = TimelapseSettings(); settings.codec = codec; settings.rateControl = .bitrate; settings.bitrate = 4; settings.multiPass = true
            let url = directory.appendingPathComponent("\(codec).mp4")
            let (writer, passes) = try await writeMovie(settings, to: url, frames: 30)
            XCTAssertEqual(passes > 1, writer.multiPass, "\(codec)")
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            XCTAssertEqual(duration, 30.0 / 24, accuracy: 0.001)
        }
        var quality = TimelapseSettings(); quality.multiPass = true
        XCTAssertFalse(quality.requestsMultiPass, "Two passes only help an average bitrate")
    }

    func testContainersFollowTheEncoder() throws {
        var settings = TimelapseSettings()
        settings.codec = .hevc; settings.container = .mov
        XCTAssertEqual(settings.fileContainer, .mov)
        settings.codec = .proRes422HQ
        XCTAssertEqual(settings.fileContainer, .mov)
        settings.container = .mp4
        XCTAssertEqual(settings.fileContainer, .mov, "MPEG-4 has no ProRes")
        settings.codec = .h264
        XCTAssertEqual(settings.fileContainer, .mp4, "The choice comes back with an encoder that fits it")
        // Settings without a container keep the rest.
        let saved = #"{"codec":"h264","aspect":"scope","resolution":1080,"customWidth":3840,"customHeight":2160,"framesPerSecond":30,"quality":0.6,"crop":{"centerX":0.5,"centerY":0.5,"scale":1}}"#
        let decoded = try JSONDecoder().decode(TimelapseSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded.codec, .h264); XCTAssertEqual(decoded.aspect, .scope); XCTAssertEqual(decoded.framesPerSecond, 30)
        XCTAssertEqual(decoded.container, .mp4)
    }

    func testCancelledVideoLeavesNoFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-timelapse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try TimelapseWriter(url: directory.appendingPathComponent("stopped.mp4"), settings: TimelapseSettings(), size: CGSize(width: 320, height: 180), frames: 1)
        writer.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// Develops sample RAWs into frames the way the Library's job does.
    func testRAWFramesRenderAtTheVideoSize() async throws {
        let sources = try TestSamples.require([TestSamples.burst.first, TestSamples.burst.second])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-timelapse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = TimelapseSettings(); settings.resolution = .hd1080; settings.crop = TimelapseCrop(centerX: 0.4, centerY: 0.6, scale: 0.5)
        let first = try RawRenderer(sourceURL: sources[0])
        let photo = CGSize(width: first.info.width, height: first.info.height)
        let size = settings.outputSize(photo: photo)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let url = directory.appendingPathComponent("raw.mp4")
        let writer = try TimelapseWriter(url: url, settings: settings, size: size, frames: sources.count)
        for (index, source) in sources.enumerated() {
            let (renderer, defaults) = try RawRenderer.open(source)
            let buffer = try writer.makeBuffer()
            try await renderer.renderTimelapseFrame(defaults, crop: settings.crop, ratio: settings.ratio(photo: photo), into: buffer)
            let preview = try await renderer.timelapsePreview(defaults, crop: settings.crop, ratio: settings.ratio(photo: photo), size: CGSize(width: 480, height: 270))
            XCTAssertEqual(preview.width, 480); XCTAssertEqual(preview.height, 270)
            // The Library's path: developed once, then mixed into frames.
            let cached = try await renderer.renderTimelapsePhoto(defaults, crop: settings.crop, ratio: settings.ratio(photo: photo), size: size, hdr: false)
            XCTAssertEqual(CVPixelBufferGetWidth(cached.pixels), Int(size.width))
            try TimelapseCompositor().compose(TimelapsePlan.Frame(photo: 0), photos: [0: cached], into: try writer.makeBuffer())
            try await writer.append(buffer, at: index)
        }
        try await writer.finish(overwriteExisting: false)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let natural = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(natural, size)
    }
}
