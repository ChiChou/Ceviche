import XCTest
import CevicheTestSupport
import AVFoundation
import CoreImage
import ImageIO
import Photos
@testable import CevicheCore

final class LivePhotoTests: XCTestCase {
    func testSizesShrinkToAnIPhonesAndStayEven() {
        XCTAssertEqual(LivePhoto.fit(CGSize(width: 9504, height: 6336), longEdge: LivePhoto.stillLongEdge), CGSize(width: 4032, height: 2688))
        XCTAssertEqual(LivePhoto.fit(CGSize(width: 4032, height: 3024), longEdge: LivePhoto.videoLongEdge), CGSize(width: 1920, height: 1440))
        XCTAssertEqual(LivePhoto.fit(CGSize(width: 1001, height: 667), longEdge: LivePhoto.stillLongEdge), CGSize(width: 1002, height: 668), "Never enlarged")
    }

    /// The frame's proportions at an iPhone's long edge, never more than the photo's cut.
    func testSizeFollowsTheFrame() {
        XCTAssertEqual(LivePhoto.size(ratio: 16.0 / 9, longEdge: LivePhoto.videoLongEdge), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(LivePhoto.size(ratio: 3.0 / 4, longEdge: LivePhoto.stillLongEdge), CGSize(width: 3024, height: 4032))
        XCTAssertEqual(LivePhoto.size(ratio: 1.5, longEdge: LivePhoto.stillLongEdge, limit: 3000), CGSize(width: 3000, height: 2000))
    }

    /// A sequence fits 3 seconds: every frame up to 90, then 90 spread from the first to the last.
    func testSequenceFitsThreeSeconds() {
        XCTAssertEqual(LivePhoto.sample(20), Array(0..<20))
        let long = LivePhoto.sample(600)
        XCTAssertEqual(long.count, 90)
        XCTAssertEqual(long.first, 0); XCTAssertEqual(long.last, 599)
        XCTAssertEqual(Set(long).count, 90, "No frame twice")
        XCTAssertEqual(LivePhoto.sampleDuration(90), CMTime(value: 1, timescale: 30))
        XCTAssertEqual(LivePhoto.sampleDuration(20).seconds * 20, 3, accuracy: 0.01)
    }

    /// The pair carries one identifier in both files and the still's moment in the movie, and Photos accepts it.
    func testPairIsALivePhoto() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("IMG.heic"), movie = directory.appendingPathComponent("IMG.mov")
        let identifier = UUID().uuidString, size = CGSize(width: 640, height: 480), context = CIContext()
        func picture(_ shift: CGFloat) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 640 * shift, y: 0), "inputPoint1": CIVector(x: 640 * shift + 200, y: 480),
                "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.9), "inputColor1": CIColor(red: 1, green: 0.8, blue: 0.3)])!.outputImage!
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        let cg = try XCTUnwrap(context.createCGImage(picture(0.5), from: CGRect(origin: .zero, size: size)))
        try LivePhoto.writeStill(cg, to: still, identifier: identifier, source: nil)
        let writer = try LivePhotoWriter(url: movie, size: size, frameDuration: CMTime(value: 1, timescale: 10), stillFrame: 5, identifier: identifier)
        for index in 0..<10 {
            let frame = try writer.makeBuffer()
            context.render(picture(CGFloat(index) / 10), to: frame.pixels, bounds: CGRect(origin: .zero, size: size), colorSpace: frame.colorSpace)
            try await writer.append(frame)
        }
        try await writer.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(still as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let apple = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        XCTAssertEqual(apple["17"] as? String, identifier)

        let asset = AVURLAsset(url: movie)
        let items = try await asset.load(.metadata)
        let content = items.first { ($0.key as? String) == "com.apple.quicktime.content.identifier" }
        let value = try await content?.load(.stringValue)
        XCTAssertEqual(value, identifier)
        let timed = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(timed.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.01)

        let accepted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            var finished = false
            PHLivePhoto.request(withResourceFileURLs: [still, movie], placeholderImage: nil, targetSize: .zero, contentMode: .default) { live, info in
                guard !finished, (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true || info[PHLivePhotoInfoErrorKey] != nil else { return }
                finished = true
                done.resume(returning: live != nil && info[PHLivePhotoInfoErrorKey] == nil)
            }
        }
        XCTAssertTrue(accepted, "Photos reads the files as one Live Photo")
    }

    /// Develops sample RAWs the way the Timelapse window's job does: the still at 12 MP, the frames at the movie's size.
    func testRAWBurstMakesALivePhoto() async throws {
        let sources = try TestSamples.require([TestSamples.burst.first, TestSamples.burst.second])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ceviche-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("IMG.heic"), movie = directory.appendingPathComponent("IMG.mov"), identifier = UUID().uuidString
        let (key, defaults) = try RawRenderer.open(sources[0])
        let ratio = 1.5, stillSize = LivePhoto.size(ratio: ratio, longEdge: LivePhoto.stillLongEdge)
        let image = try await key.livePhotoStill(defaults, crop: TimelapseCrop(), ratio: ratio, size: stillSize)
        XCTAssertEqual(CGSize(width: image.width, height: image.height), stillSize)
        try LivePhoto.writeStill(image, to: still, identifier: identifier, source: sources[0])
        let size = LivePhoto.fit(CGSize(width: image.width, height: image.height), longEdge: LivePhoto.videoLongEdge)
        XCTAssertEqual(max(size.width, size.height), 1920)
        let writer = try LivePhotoWriter(url: movie, size: size, frameDuration: CMTime(value: 1, timescale: 10), stillFrame: 0, identifier: identifier)
        for source in sources {
            let (renderer, adjustments) = try RawRenderer.open(source)
            let frame = try writer.makeBuffer()
            try await renderer.renderTimelapseFrame(adjustments, crop: TimelapseCrop(), ratio: ratio, into: frame)
            try await writer.append(frame)
        }
        try await writer.finish()
        let properties = try XCTUnwrap(CGImageSourceCreateWithURL(still as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertNotNil(exif[kCGImagePropertyExifDateTimeOriginal as String], "Capture tags carried over")
        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .video)
        let natural = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(natural, size)
    }
}
