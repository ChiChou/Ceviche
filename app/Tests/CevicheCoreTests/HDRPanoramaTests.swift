import XCTest
import CevicheTestSupport
import CoreImage
@testable import CevicheCore

/// HDR Panorama on real bracketed panoramas (`TestSamples.hdrPanorama`): the tests skip without them.
final class HDRPanoramaTests: XCTestCase {
    private func photos(_ role: String, _ extensions: Set<String>) throws -> [URL] {
        try TestSamples.requireFiles(role, extensions: extensions)
    }

    /// Brackets split on a pause well above the usual one, on a repeated exposure, or where told to.
    func testSegmentsByTimeAndExposure() {
        func shot(_ time: Double, _ stops: Double?) -> HDRPanoramaMerger.Shot {
            HDRPanoramaMerger.Shot(url: URL(fileURLWithPath: "/\(time)"), time: time, exposureTime: 0.01, stops: stops)
        }
        // Three brackets of 0/−2/+2, a second apart, ten seconds between positions.
        let timed = [0, 1, 2, 12, 13, 14, 24, 25, 26].enumerated().map { shot(Double($1), [0.0, -2, 2][$0 % 3]) }
        XCTAssertEqual(HDRPanoramaMerger.segment(timed), [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        // An even pace: only the repeated exposure tells the brackets apart.
        let paced = (0..<6).map { shot(Double($0) * 9, [0.0, 0.5, -0.5][$0 % 3]) }
        XCTAssertEqual(HDRPanoramaMerger.segment(paced), [[0, 1, 2], [3, 4, 5]])
        // No recorded exposure and an even pace: one group, unless the pictures force a split.
        let bare = (0..<4).map { shot(Double($0), nil) }
        XCTAssertEqual(HDRPanoramaMerger.segment(bare), [[0, 1, 2, 3]])
        XCTAssertEqual(HDRPanoramaMerger.segment(bare, forced: [2]), [[0, 1], [2, 3]])
    }

    /// Merge to Panorama asks for the brackets only when the recorded exposures show them.
    func testRecognisesBracketsFromExposures() {
        func shots(_ stops: [Double?], every gap: Double = 3) -> [HDRPanoramaMerger.Shot] {
            stops.enumerated().map { HDRPanoramaMerger.Shot(url: URL(fileURLWithPath: "/\($0)"), time: Double($0) * gap, exposureTime: 0.01, stops: $1) }
        }
        XCTAssertTrue(HDRPanoramaMerger.bracketed(shots([0, -2, 2, 0, -2, 2, 0, -2, 2])))
        XCTAssertTrue(HDRPanoramaMerger.bracketed(shots([0, 0.5, -0.5, 0, 0.5, -0.5])))
        XCTAssertFalse(HDRPanoramaMerger.bracketed(shots([0, 0, 0, 0, 0])), "fixed exposure")
        XCTAssertFalse(HDRPanoramaMerger.bracketed(shots([0, 0.3, 0.7, 1, 1.3, 1.3, 1.3, 1.3])), "auto exposure drifting")
        XCTAssertFalse(HDRPanoramaMerger.bracketed(shots([0, 0.3, 0, 0.3, 0, 0.3])), "auto exposure hunting")
        XCTAssertFalse(HDRPanoramaMerger.bracketed(shots([nil, nil, nil, nil])), "no exposures recorded")
    }

    /// The real bracketed panoramas are recognised; one frame per position of them is a plain panorama.
    func testRecognisesRealBrackets() throws {
        for (role, ext) in [(TestSamples.hdrPanorama.cr2, "cr2"), (TestSamples.hdrPanorama.dng, "dng")] {
            let urls = try photos(role, [ext])
            XCTAssertTrue(HDRPanoramaMerger.looksBracketed(urls), role)
            let middles = stride(from: 1, to: urls.count, by: 3).map { urls[$0] }
            XCTAssertFalse(HDRPanoramaMerger.looksBracketed(middles), role)
        }
    }

    func testGroupsRealBrackets() throws {
        try TestTier.requireSlow()
        let brackets = try HDRPanoramaMerger(urls: try photos(TestSamples.hdrPanorama.cr2, ["cr2"]).reversed())
        let grouping = try brackets.group()
        XCTAssertEqual(grouping.groups.map(\.count), [3, 3, 3, 3])
        XCTAssertTrue(grouping.oddPositions.isEmpty)
        XCTAssertTrue(grouping.repeatedPositions.isEmpty)
        XCTAssertEqual(brackets.urls.map(\.lastPathComponent), brackets.urls.map(\.lastPathComponent).sorted(), "capture order")
        XCTAssertNotNil(grouping.photos[0].thumbnail)
        // With a frame gone its position is flagged.
        var missing = brackets.urls; missing.remove(at: 4)
        let short = try HDRPanoramaMerger(urls: missing).group()
        XCTAssertEqual(short.groups.map(\.count), [3, 2, 3, 3])
        XCTAssertEqual(short.oddPositions, [1])
    }

    /// Deghosting shapes the merged pixels, not the alignment: falling back to one exposure in wind-blown foliage left
    /// the overlapping positions of this set too few matches to join.
    func testAlignsWhateverTheDeghosting() throws {
        try TestTier.requireSlow()
        let merger = try HDRPanoramaMerger(urls: try photos(TestSamples.hdrPanorama.cr2, ["cr2"]))
        let groups = try merger.group().groups
        for deghosting in [HDRDeghosting.off, .high] {
            let alignment = try merger.panorama(groups: groups, deghosting: deghosting).align()
            XCTAssertEqual(alignment.included, [1, 2], "\(deghosting)")
        }
    }

    /// Canon bodies record no 35 mm equivalent; it comes from the focal plane resolution.
    func testFocalLengthFromFocalPlane() throws {
        let url = try photos(TestSamples.hdrPanorama.cr2, ["cr2"])[0]
        let metadata = try PanoramaDecoder.metadata(url)
        XCTAssertEqual(try XCTUnwrap(metadata.focalLength35mm), 24, accuracy: 1.5)
    }

    /// Merge each bracket, then stitch: the positions join and the DNG opens.
    func testMergesThenStitches() throws {
        try TestTier.requireSlow()
        let merger = try HDRPanoramaMerger(urls: try photos(TestSamples.hdrPanorama.dng, ["dng"]))
        let grouping = try merger.group()
        XCTAssertEqual(grouping.groups.map(\.count), [3, 3, 3])
        let panorama = try merger.panorama(groups: grouping.groups)
        let alignment = try panorama.align()
        XCTAssertEqual(alignment.included.count, 3)
        let preview = try panorama.preview(PanoramaSettings())
        XCTAssertGreaterThan(preview.image.width, preview.image.height)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdrpano-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("merged.dng")
        var settings = PanoramaSettings(); settings.projection = alignment.suggested
        try panorama.merge(settings, to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        XCTAssertGreaterThan(raw.nativeSize.width, 6000)
    }
}
