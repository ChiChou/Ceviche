import XCTest
import CoreGraphics
@testable import CevicheCore

/// Portrait's edits both apps write: whose corrections are replaced and what they keep.
final class PortraitEditsTests: XCTestCase {
    private let left = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2), right = CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.2)
    private func mask(_ kind: PortraitCorrection, _ face: CGRect?) -> PhotoMask {
        var m = PhotoMask(kind: .brush); m.portraitCorrection = kind; m.face = face; return m
    }
    private func face(_ id: Int, _ box: CGRect) -> PortraitFace {
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return PortraitFace(id: id, box: box, thumbnail: image)
    }

    func testMainPeopleLeaveOutSmallFaces() {
        let faces = [face(0, left), face(1, CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05)), face(2, right)]
        XCTAssertEqual(PortraitFace.mainIDs(faces), [0, 2])
        XCTAssertEqual(PortraitFace.boxes(faces, ids: [2]), [right])
        XCTAssertNil(PortraitFace.boxes([], ids: [0]), "No faces known: everyone")
    }

    func testCorrectionReplacesOnlyTheChosenPersonAndKeepsAmount() {
        var a = Adjustments()
        var mine = mask(.shine, left); mine.opacity = 0.3
        a.masks = [mine, mask(.shine, right), mask(.eyes, left)]
        a.placePortraitCorrection(.shine, [mask(.shine, left)], faces: [left])
        XCTAssertEqual(a.masks.filter { $0.portraitCorrection == .shine }.count, 2)
        XCTAssertEqual(a.portraitMasks(.shine, faces: [left]).map(\.opacity), [0.3])
        XCTAssertFalse(a.masks.contains { $0.id == mine.id })
        // A face region drawn by hand replaces everyone's.
        a.placePortraitCorrection(.shine, [mask(.shine, nil)], faces: [left], region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(a.masks.filter { $0.portraitCorrection == .shine }.count, 1)
        XCTAssertEqual(a.masks.count, 2)
    }

    func testDetailKeepsStrengthAndRespectsMaskLimit() {
        var a = Adjustments()
        var eyes = mask(.eyes, right); eyes.strength = 1.6
        a.masks = [eyes]
        a.placePortraitDetail(.eyes, [mask(.eyes, right)], faces: nil)
        XCTAssertEqual(a.masks.map(\.strength), [1.6])
        a.masks += (0..<(PhotoMask.maxCount - 1)).map { _ in PhotoMask(kind: .brush) }
        a.placePortraitDetail(.teeth, [mask(.teeth, right), mask(.teeth, right)], faces: nil)
        XCTAssertTrue(a.portraitMasks(.teeth, faces: nil).isEmpty)
        a.setPortraitMasks(.eyes, \.strength, 0.5, faces: [left])
        XCTAssertEqual(a.portraitMasks(.eyes, faces: nil).map(\.strength), [1.6], "Someone else's")
        a.removePortraitCorrection(.eyes, faces: [right])
        XCTAssertTrue(a.portraitMasks(.eyes, faces: nil).isEmpty)
    }

    func testEvenToneKeepsTheOtherPeoplesLayers() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        func layer(_ r: CGRect) -> SkinTone.Face { SkinTone.Face(x: r.minX, y: r.minY, width: r.width, height: r.height, layer: png) }
        var a = Adjustments()
        a.placeSkinTone([layer(left), layer(right)], amount: 0.7, faces: nil)
        a.placeSkinTone([layer(left)], amount: 0.4, faces: [left])
        XCTAssertEqual(a.skinTone?.faces.map(\.amount).sorted(), [0.4, 0.7])
        a.setSkinToneAmount(0.9, faces: [right])
        XCTAssertEqual(a.skinTones(faces: [right]).map(\.amount), [0.9])
        a.removeSkinTone(faces: [left]); a.removeSkinTone(faces: [right])
        XCTAssertNil(a.skinTone)
    }

    func testFaceWarpsPerPersonUpToTheLimit() {
        var a = Adjustments()
        XCTAssertNil(a.faceWarpEdit(nil, on: nil), "Nothing to take out")
        var warp = FaceLiquify(region: left).setting([(\.eyeSize, 3)])
        XCTAssertEqual(warp.eyeSize, 1)
        a.faceWarpEdit(warp, on: left)?(&a)
        XCTAssertEqual(a.faceWarp(on: left), warp); XCTAssertNil(a.faceWarp(on: right))
        warp.smile = -0.5
        a.faceWarpEdit(warp, on: left)?(&a)
        XCTAssertEqual(a.faceLiquifies, [warp])
        a.faceWarpEdit(nil, on: left)?(&a)
        XCTAssertTrue(a.faceLiquifies.isEmpty)
        a.faceLiquifies = (0..<Adjustments.maxFaceWarps).map { FaceLiquify(region: CGRect(x: Double($0) * 0.01, y: 0.9, width: 0.005, height: 0.005)) }
        a.faceWarpEdit(FaceLiquify(region: right), on: right)?(&a)
        XCTAssertEqual(a.faceLiquifies.count, Adjustments.maxFaceWarps)
        a.faceWarpEdit(warp, on: nil)?(&a)
        XCTAssertEqual(a.faceLiquify, warp, "One face: the photo's only warp")
    }

    func testGroupPlacementsSkipFacesFoundAgainMeanwhile() {
        let measured = [face(0, left), face(1, right)]
        var placements: [Int: FaceLiquify] = [:]
        let moved = face(1, right.offsetBy(dx: 0.05, dy: 0))
        FaceLiquify.place([FaceLiquify(region: left), FaceLiquify(region: right)], on: measured, current: [measured[0], moved], into: &placements)
        XCTAssertEqual(Set(placements.keys), [0])
        XCTAssertEqual(FaceLiquify.unplaced([measured[0], moved], in: placements).map(\.id), [1])
    }
}
