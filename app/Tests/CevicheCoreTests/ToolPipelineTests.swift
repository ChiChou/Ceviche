import XCTest
import CoreGraphics
@testable import CevicheCore

/// The tools' decisions both apps take from CevicheCore: Convert Negative's rolls, Match Series, ID Photo's output,
/// a timelapse as a Live Photo and the merge result names.
final class NegativeRollTests: XCTestCase {
    private func sample(_ frame: FrameQuad = .full, base: SIMD3<Float> = SIMD3(0.8, 0.4, 0.2)) -> NegativeSample {
        let values = (0..<200).map { 0.3 + 1.5 * Float($0) / 199 }
        return NegativeSample(base: base, channels: (0..<3).map { c in values.map { base[c] / exp2($0) } }, frame: frame)
    }
    private let moved = FrameQuad(corners: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)])

    func testSplitsIntoRollsAtTheirStarts() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(NegativeRoll.rolls(ids, id: { $0 }, starts: nil), [ids])
        XCTAssertEqual(NegativeRoll.rolls(ids, id: { $0 }, starts: ["c"]), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(NegativeRoll.rolls([String](), id: { $0 }, starts: nil), [])
    }

    /// A scan is measured again only when its frame moved; one never looked at keeps the sample it has.
    func testMeasuresAgainWhenTheFrameMoved() {
        XCTAssertTrue(NegativeRoll.needsSample(nil, frame: nil))
        XCTAssertFalse(NegativeRoll.needsSample(sample(), frame: nil))
        XCTAssertFalse(NegativeRoll.needsSample(sample(), frame: .full))
        XCTAssertTrue(NegativeRoll.needsSample(sample(), frame: moved))
    }

    /// Each roll is balanced with its own film and base; rolls with nothing measured are left out.
    func testBalancesEachRollOnItsOwn() {
        let samples = ["a": sample(), "b": sample(), "c": sample(base: SIMD3(0.8, 0.6, 0.35))]
        let picked = SIMD3<Float>(0.7, 0.35, 0.18)
        let groups = NegativeRoll.groups([["a", "b"], ["c"], ["d"]], samples: samples) { first in
            first == "a" ? NegativeRollShared(film: .color, orientation: NegativeOrientation(), base: picked) : nil
        }
        XCTAssertEqual(groups.map { $0.scans.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertEqual(groups[0].base, picked)
        XCTAssertNil(groups[1].film)
        let balance = NegativeRoll.balance(groups, scans: [])
        XCTAssertEqual(Set(balance.inversions.keys), ["a", "b", "c"])
        XCTAssertEqual(balance.inversions["a"]?.base, picked)
        XCTAssertEqual(balance.proposed, [])
    }

    /// In a roll each scan takes the roll's shared choices, its own frame or the one it was measured in, and its
    /// inversion; alone, the choices made on it stay. The print goes to every scan.
    func testChoicesForConverting() {
        let turned = NegativeOrientation().rotated(clockwise: true)
        let kept = ["a": NegativeChoice(frame: moved, film: .blackAndWhite, orientation: turned)]
        let samples = ["a": sample(), "b": sample(moved)]
        let inversion = NegativeConverter.balance([sample()], film: .color).inversions[0]
        let print = NegativePrint(stock: "stock", paper: "paper")

        let alone = NegativeRoll.choices(["a", "b"], kept: kept, samples: samples, inversions: nil, shared: { _ in nil }, print: print)
        XCTAssertEqual(alone["a"]?.film, .blackAndWhite)
        XCTAssertEqual(alone["a"]?.orientation, turned)
        XCTAssertNil(alone["b"]?.frame)
        XCTAssertEqual(alone["b"]?.print, print)

        let shared = NegativeRollShared(film: .color, orientation: NegativeOrientation(), base: nil)
        let roll = NegativeRoll.choices(["a", "b"], kept: kept, samples: samples, inversions: ["a": inversion, "b": inversion],
                                        shared: { $0 == "a" ? shared : nil }, print: nil)
        XCTAssertEqual(roll["a"]?.frame, moved)
        XCTAssertEqual(roll["a"]?.film, .color)
        XCTAssertEqual(roll["a"]?.orientation, NegativeOrientation())
        XCTAssertEqual(roll["a"]?.inversion, inversion)
        XCTAssertEqual(roll["b"]?.frame, moved, "A scan never looked at converts in the frame it was measured in")
        XCTAssertNil(roll["b"]?.film)
    }

    func testDestinationIsNumberedWhenTaken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NegativeRollTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = URL(fileURLWithPath: "/scans/DSC_0001.ARW")
        let first = NegativeConverter.destination(for: source, in: folder)
        XCTAssertEqual(first.lastPathComponent, "DSC_0001-Positive.dng")
        try Data().write(to: first)
        XCTAssertEqual(NegativeConverter.destination(for: source, in: folder).lastPathComponent, "DSC_0001-Positive-2.dng")
    }
}

final class SeriesMatchSeriesTests: XCTestCase {
    private func asset(_ id: String) -> CatalogAsset {
        CatalogAsset(id: id, importPath: "file:///\(id).ARW", sourcePath: "/\(id).ARW", bookmark: nil, filename: "\(id).ARW", kind: "RAW",
                     infoData: Data(), xmpWarnings: "", title: "", caption: "", keywords: "", rating: 0, review: .unreviewed, captureDay: "",
                     latitude: nil, longitude: nil, suggestedTags: "", analysisVersion: nil, thumbnailKey: nil, thumbnailRenderKey: nil,
                     renderKey: "", importedAt: Date(), updatedAt: Date(), origin: "file:///\(id).ARW")
    }
    private func series(_ count: Int, reference: Int = 0) -> SeriesMatchSeries {
        var series = SeriesMatchSeries((0..<count).map { asset("p\($0)") }, reference: reference)
        for index in series.photos.indices {
            var defaults = Adjustments()
            defaults.exposure = 0; defaults.temperature = 5000; defaults.tint = 0
            series.photos[index].url = URL(fileURLWithPath: "/p\(index).ARW")
            series.photos[index].defaults = defaults
        }
        return series
    }
    private func matched(_ exposure: Double, _ temperature: Double, method: SeriesMatchMethod = .overlap) -> SeriesMatchOutcome {
        .matched(SeriesMatchResult(method: method, values: SeriesMatchValues(exposure: exposure, temperature: temperature, tint: 0), agreement: nil, hasFace: false))
    }

    /// The reference is never matched, so it doesn't hold the series back; the next to match skips it.
    func testMatchingSkipsTheReference() {
        var series = series(3, reference: 1)
        XCTAssertTrue(series.matching)
        XCTAssertEqual(series.next, 0)
        series.photos[0].outcome = matched(0.5, 5000)
        XCTAssertEqual(series.next, 2)
        series.photos[2].outcome = .failed("no")
        XCTAssertNil(series.next)
        XCTAssertFalse(series.matching)
    }

    /// Only changes the sliders show count, for what is matched; an unmatched or left-out photo doesn't change.
    func testChanges() {
        var series = series(4)
        series.photos[1].outcome = matched(0.003, 5000)
        series.photos[2].outcome = matched(0.5, 5200)
        series.photos[3].outcome = matched(1, 6000, method: .unmatched)
        XCTAssertEqual(Set(series.changes(exposure: true, whiteBalance: true).keys), ["p2"])
        XCTAssertEqual(Set(series.changes(exposure: false, whiteBalance: false).keys), [])
        series.photos[2].included = false
        XCTAssertTrue(series.changes(exposure: true, whiteBalance: true).isEmpty)
    }

    func testAdjustedSetsOnlyWhatIsAsked() throws {
        var series = series(2)
        series.photos[1].outcome = matched(0.7, 5600)
        let exposureOnly = try XCTUnwrap(series.adjusted(1, exposure: true, whiteBalance: false))
        XCTAssertEqual(exposureOnly.exposure, 0.7)
        XCTAssertEqual(exposureOnly.temperature, 5000)
        let both = try XCTUnwrap(series.adjusted(1, exposure: true, whiteBalance: true))
        XCTAssertEqual(both.temperature, 5600)
        XCTAssertEqual(series.adjusted(0, exposure: true, whiteBalance: true)?.exposure, 0, "The reference keeps its own")
    }

    func testRematchAndReference() {
        var series = series(3)
        series.photos[1].outcome = matched(0.5, 5000)
        series.photos[2].outcome = .matching
        series.photos[2].prefer = .exif
        XCTAssertEqual(series.preference(1, skin: true), .skin)
        XCTAssertEqual(series.preference(2, skin: true), .exif)
        series.rematch(only: 1)
        guard case .waiting = series.photos[1].outcome, case .waiting = series.photos[2].outcome else { return XCTFail("Both wait again") }
        XCTAssertFalse(series.makeReference(0))
        series.photos[2].url = nil
        XCTAssertFalse(series.makeReference(2), "A photo whose original isn't read can't be the reference")
        XCTAssertTrue(series.makeReference(1))
        XCTAssertEqual(series.reference, 1)
    }
}

final class IDPhotoOutputTests: XCTestCase {
    private var icao: IDPhotoSpec { IDPhotoSpecs.spec("icao")! }

    func testDigitalFile() {
        XCTAssertEqual(IDPhotoRenderer.digitalName(stem: "IMG_0001", spec: icao), "IMG_0001-icao.jpg")
        // 35 mm across at 600 pixels.
        XCTAssertEqual(IDPhotoRenderer.digitalDPI(width: 600, spec: icao), 600 / 35 * 25.4, accuracy: 1e-9)
    }

    func testMatteIsMadeOnceAndUsedOnlyWithABackground() {
        var layout = IDPhotoLayout(spec: icao, crown: CGPoint(x: 0.5, y: 0.2), chin: CGPoint(x: 0.5, y: 0.55))
        layout.background = nil
        XCTAssertFalse(IDPhotoMatte.needed(for: layout, made: false, making: false, failed: false))
        layout.background = IDPhotoBackground(for: icao)
        XCTAssertTrue(IDPhotoMatte.needed(for: layout, made: false, making: false, failed: false))
        XCTAssertFalse(IDPhotoMatte.needed(for: layout, made: true, making: false, failed: false))
        XCTAssertFalse(IDPhotoMatte.needed(for: layout, made: false, making: true, failed: false))
        XCTAssertFalse(IDPhotoMatte.needed(for: layout, made: false, making: false, failed: true))
        XCTAssertNotNil(layout.checked(matteFailed: false).background)
        XCTAssertNil(layout.checked(matteFailed: true).background)

        let matte = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()
        XCTAssertNotNil(IDPhotoMatte.used(matte, by: layout))
        layout.background = nil
        XCTAssertNil(IDPhotoMatte.used(matte, by: layout))
    }
}

final class TimelapseLivePhotoTests: XCTestCase {
    func testBounceOrder() {
        XCTAssertEqual(TimelapseLivePhoto.frames(count: 4, bounce: false), [0, 1, 2, 3])
        XCTAssertEqual(TimelapseLivePhoto.frames(count: 4, bounce: true), [0, 1, 2, 3, 2, 1, 0])
        XCTAssertEqual(TimelapseLivePhoto.frames(count: 1, bounce: true), [0])
    }

    /// The still is the first frame that shows the key photo most, else the nearest.
    func testStillFrame() {
        let dominant = [0, 0, 1, 2, 4]
        XCTAssertEqual(TimelapseLivePhoto.stillFrame(order: [0, 1, 2, 3, 4], dominant: dominant, key: 2), 3)
        XCTAssertEqual(TimelapseLivePhoto.stillFrame(order: [0, 1, 2, 3, 4], dominant: dominant, key: 3), 3)
        XCTAssertEqual(TimelapseLivePhoto.stillFrame(order: [4, 3, 2], dominant: dominant, key: 1), 2)
    }

    func testSizesStayWithinThePhoto() {
        let crop = TimelapseCrop(), preset = LivePhotoSize.allCases[0]
        let big = TimelapseLivePhoto.sizes(ratio: 1.5, crop: crop, preset: preset, photo: nil)
        let small = TimelapseLivePhoto.sizes(ratio: 1.5, crop: crop, preset: preset, photo: CGSize(width: 300, height: 200))
        XCTAssertLessThanOrEqual(max(small.still.width, small.still.height), 300)
        XCTAssertGreaterThanOrEqual(big.still.width, small.still.width)
    }
}

final class MergeOutputTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(MergeOutput.panorama.name(stem: "DSC_0001"), "DSC_0001-Panorama")
        XCTAssertEqual(MergeOutput.hdrPanorama.suffix, "HDR-Panorama")
        XCTAssertEqual(MergeOutput.starTrails.suffix, "StarTrails")
        XCTAssertEqual(MergeOutput.nightSky.suffix, "NightSky")
        XCTAssertEqual(Set(MergeOutput.allCases.map(\.suffix)).count, MergeOutput.allCases.count)
    }
}
