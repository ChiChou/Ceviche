import XCTest
import CevicheTestSupport
@testable import CevicheCore

final class NegativeRollsTests: XCTestCase {
    private func scan(_ minute: Double, _ base: SIMD3<Float>, settings: String = "X-T2 / 80 / 5000 K 0", camera: String = "X-T2") -> NegativeRollScan {
        NegativeRollScan(captured: Date(timeIntervalSinceReferenceDate: minute * 60), settings: settings, camera: camera, base: base)
    }
    private let portra = SIMD3<Float>(0.60, 0.30, 0.15), grey = SIMD3<Float>(0.4, 0.4, 0.4)

    /// A new roll where the film base stops matching; a pause alone starts none.
    func testSplitsOnBaseNotOnTime() {
        // Red clipped the same on both stocks, as scans of colour negatives are: green and blue tell them apart.
        let ektar = SIMD3<Float>(0.60, 0.42, 0.21)
        let scans = [scan(0, portra), scan(1, portra * 1.1), scan(600, portra), scan(601, ektar), scan(602, ektar * 0.9), scan(603, grey)]
        XCTAssertEqual(NegativeRolls.rolls(scans), [[0, 1, 2], [3, 4], [5]])
    }

    /// Two rolls of one stock have the same base; the session's settings tell them apart.
    func testSplitsOnSettings() {
        let scans = [scan(0, portra, settings: "X-T2 / 80 / auto"), scan(40, portra), scan(41, portra), scan(42, portra)]
        XCTAssertEqual(NegativeRolls.rolls(scans), [[0], [1, 2, 3]])
        // Another camera's colours don't compare with this one's.
        XCTAssertEqual(NegativeRolls.rolls([scan(0, portra), scan(1, portra, camera: "D750")]), [[0], [1]])
    }

    /// One misread base between matching scans stays in its roll; capture order is what counts, not the order given.
    func testKeepsAnOutlierAndOrdersByCapture() {
        let scans = [scan(3, portra), scan(0, portra), scan(1, portra * 1.4), scan(2, portra), scan(4, grey)]
        XCTAssertEqual(NegativeRolls.rolls(scans), [[1, 2, 3, 0], [4]])
    }

    /// The photographer's own scans: May, June (3), a black and white roll, July colour (6) and one of another stock.
    func testGroupsSampleRolls() throws {
        try TestTier.requireSlow()
        let directory = try TestSamples.requireFolder(TestSamples.negativeScans)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "raf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let scans = try urls.map { url -> NegativeRollScan in
            let session = NegativeRollScan.session(url)
            return NegativeRollScan(captured: session.captured, settings: session.settings, camera: session.camera, base: try NegativeConverter.rollSample(url, frame: nil).comparableBase)
        }
        let rolls = NegativeRolls.rolls(scans).map { $0.map { urls[$0].deletingPathExtension().lastPathComponent } }
        XCTAssertEqual(rolls.map(\.count), [1, 3, 1, 6, 1])
    }
}
