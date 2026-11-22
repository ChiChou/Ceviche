import XCTest
@testable import CevicheCore
@testable import CevicheMac

final class GroupReshapeTests: XCTestCase {
    /// In a group picture Facial Features reshapes the selected person: each keeps their own warp on their own face,
    /// taking one out leaves the other's, and Everyone reshapes no one.
    @MainActor func testEachPickedPersonKeepsTheirOwnReshape() throws {
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let left = PortraitFace(id: 0, box: CGRect(x: 0.1, y: 0.4, width: 0.15, height: 0.2), thumbnail: pixel)
        let right = PortraitFace(id: 1, box: CGRect(x: 0.6, y: 0.4, width: 0.15, height: 0.2), thumbnail: pixel)
        model.portraitFaces = [left, right]
        model.groupPlacements = [0: FaceLiquify(region: left.box.insetBy(dx: -0.02, dy: -0.02)), 1: FaceLiquify(region: right.box.insetBy(dx: -0.02, dy: -0.02))]

        model.selectedFaceID = 1
        model.setLiquify(\.width, -0.5)
        XCTAssertEqual(model.adjustments.faceLiquifies.count, 1)
        XCTAssertTrue(model.adjustments.faceLiquifies[0].region.contains(CGPoint(x: right.box.midX, y: right.box.midY)))

        model.selectedFaceID = 0
        XCTAssertEqual(model.liquify.width, 0, "The other person starts unchanged")
        model.setLiquify(\.eyeSize, 0.3)
        XCTAssertEqual(model.adjustments.faceLiquifies.count, 2)
        model.selectedFaceID = 1
        XCTAssertEqual(model.liquify.width, -0.5)
        XCTAssertEqual(model.liquify.eyeSize, 0)

        model.selectedFaceID = nil
        XCTAssertNil(model.currentFaceRegion, "Everyone has no face to reshape")
        model.setLiquify(\.width, 0.9)
        XCTAssertEqual(model.adjustments.faceLiquifies.count, 2, "Nothing changes on Everyone")
        model.selectedFaceID = 1
        model.resetLiquify()
        XCTAssertEqual(model.adjustments.faceLiquifies.count, 1)
        XCTAssertEqual(model.adjustments.faceLiquifies[0].eyeSize, 0.3, "Resetting one person leaves the other's")
    }

    /// On one person, a correction's Amount, Even tone and the card resets touch only that person; on Everyone, all.
    @MainActor func testSelectionKeepsPeopleApart() throws {
        let model = EditorModel(preferences: UserDefaults(suiteName: UUID().uuidString)!)
        let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let a = CGRect(x: 0.1, y: 0.4, width: 0.15, height: 0.2), b = CGRect(x: 0.6, y: 0.4, width: 0.15, height: 0.2)
        model.portraitFaces = [PortraitFace(id: 0, box: a, thumbnail: pixel), PortraitFace(id: 1, box: b, thumbnail: pixel)]
        var shineA = PhotoMask(kind: .radial); shineA.portraitCorrection = .shine; shineA.face = a
        var shineB = PhotoMask(kind: .radial); shineB.portraitCorrection = .shine; shineB.face = b
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var spotA = RetouchStroke(mode: .heal, source: MaskPoint(x: 0.15, y: 0.5), target: MaskPoint(x: 0.15, y: 0.5), radius: 0.01, softness: 0.4, opacity: 1)
        spotA.face = true; spotA.faceBox = a
        var spotB = spotA; spotB.id = UUID(); spotB.faceBox = b
        model.edit { s in
            s.masks = [shineA, shineB]; s.retouch = [spotA, spotB]
            s.skinTone = SkinTone(faces: [SkinTone.Face(x: a.minX, y: a.minY, width: a.width, height: a.height, layer: png),
                                         SkinTone.Face(x: b.minX, y: b.minY, width: b.width, height: b.height, layer: png)])
        }

        model.selectedFaceID = 0
        model.setSkinToneAmount(0.2)
        XCTAssertEqual(model.adjustments.skinTone?.faces.map(\.amount), [0.2, 0.7], "Only the selected person's Even tone moves")
        model.removePortraitCorrections()
        XCTAssertEqual(model.adjustments.masks.map(\.id), [shineB.id], "Light's reset takes only the selected person's")
        XCTAssertEqual(model.adjustments.skinTone?.faces.count, 1)
        model.removeFaceStrokes()
        XCTAssertEqual(model.adjustments.retouch.map(\.id), [spotB.id], "Blemishes' reset takes only their spots")

        var spotA2 = spotA; spotA2.id = UUID()
        model.edit { $0.retouch.append(spotA2) }
        XCTAssertTrue(model.hasFaceSpots(on: a))
        model.removeFaceSpots(on: a)
        XCTAssertEqual(model.adjustments.retouch.map(\.id), [spotB.id], "Clear under a face takes only that face's spots")
        XCTAssertFalse(model.hasFaceSpots(on: a))

        model.selectedFaceID = nil
        model.removePortraitCorrections(); model.removeFaceStrokes()
        XCTAssertTrue(model.adjustments.masks.isEmpty && model.adjustments.retouch.isEmpty && model.adjustments.skinTone == nil, "Everyone resets everyone")
    }
}
