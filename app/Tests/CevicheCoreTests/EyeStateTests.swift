import XCTest
@testable import CevicheCore

/// The closed-eyes rule on readings measured from a group shot at night: Vision's eye outline and the face mesh's lids.
final class EyeStateTests: XCTestCase {
    private let balanced = CullingSensitivity.balanced.closedEye

    func testBlinkIsClosedByBoth() {
        XCTAssertTrue(EyeState.closed(vision: (0.08, 0.07), mesh: (0.06, 0.05), below: balanced))
    }

    func testLaughingSquintIsOpenWhenTheMeshSeesTheLids() {
        // Vision alone calls it closed at the strict setting; the mesh sees the eyes open.
        XCTAssertTrue(EyeState.closed(vision: (0.14, 0.14), mesh: nil, below: CullingSensitivity.strict.closedEye))
        XCTAssertFalse(EyeState.closed(vision: (0.14, 0.14), mesh: (0.20, 0.22), below: CullingSensitivity.strict.closedEye))
    }

    func testEyesShutBehindGlassesNeedVisionAndOneMeshEye() {
        // The mesh misreads one eye through the frame (0.17); Vision and the other eye agree it is shut.
        XCTAssertTrue(EyeState.closed(vision: (0.02, 0.05), mesh: (0.17, 0.06), below: balanced))
    }

    func testNarrowSmilingEyesStayOpen() {
        // One mesh eye under the threshold is not enough when Vision sees them open.
        XCTAssertFalse(EyeState.closed(vision: (0.15, 0.18), mesh: (0.16, 0.10), below: balanced))
    }

    func testWithoutAnyReadingNothingIsClosed() {
        XCTAssertFalse(EyeState.closed(vision: nil, mesh: nil, below: balanced))
    }

    func testReportCountsOnlyJudgedFaces() {
        let small = PhotoQualityReport.Face(bounds: CGRect(x: 0, y: 0, width: 0.02, height: 0.03), leftEye: 0.02, rightEye: 0.02)
        let squint = PhotoQualityReport.Face(bounds: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.12), leftEye: 0.14, rightEye: 0.14,
                                             meshLeftEye: 0.21, meshRightEye: 0.2)
        let blink = PhotoQualityReport.Face(bounds: CGRect(x: 0.5, y: 0.2, width: 0.1, height: 0.12), leftEye: 0.05, rightEye: 0.06,
                                            meshLeftEye: 0.05, meshRightEye: 0.04)
        var report = PhotoQualityReport()
        report.faces = [small, squint, blink]
        XCTAssertEqual(report.closedEyes(.strict), 1)
    }
}
