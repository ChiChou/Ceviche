import XCTest
@testable import CevicheCore

final class MaskEditingTests: XCTestCase {
    func testNewMasksStartAsBothAppsMakeThem() {
        XCTAssertEqual(PhotoMask.new(.brush).feather, 0)
        XCTAssertEqual(PhotoMask.new(.color).feather, MaskSelection(kind: .color).feather)
        let point = MaskPoint(x: 0.4, y: 0.6)
        let radial = PhotoMask.gradient(.radial, at: point), linear = PhotoMask.gradient(.linear, at: point)
        XCTAssertEqual(radial.feather, 0.125)
        XCTAssertEqual(linear.feather, MaskSelection(kind: .linear).feather)
        XCTAssertEqual(radial.start, point); XCTAssertEqual(radial.end, point)
        XCTAssertTrue(radial.selection.isUndrawnGradient)
        XCTAssertFalse(PhotoMask.new(.brush).selection.isUndrawnGradient)
        XCTAssertTrue(MaskKind.linear.isGradient && MaskKind.radial.isGradient && !MaskKind.brush.isGradient)
        XCTAssertFalse(MaskKind.generatedOnPhoto.contains(.object))
    }

    func testMasksOfAKindAreNumberedFromTheSecond() {
        var a = Adjustments()
        let first = a.acceptSelection(PhotoMask.new(.subject), operation: nil, parentID: nil)
        let second = a.acceptSelection(PhotoMask.new(.subject), operation: nil, parentID: nil)
        a.acceptSelection(PhotoMask.new(.sky), operation: nil, parentID: nil)
        XCTAssertEqual(first?.maskID, a.masks[0].id); XCTAssertNil(first?.componentID)
        XCTAssertEqual(second?.maskID, a.masks[1].id)
        XCTAssertEqual(a.masks.map(\.name), [MaskKind.subject.localizedTitle, "\(MaskKind.subject.localizedTitle) 2", MaskKind.sky.localizedTitle])
    }

    func testComponentJoinsItsParentAndAnInvertedMaskKeepsWhatItShowed() throws {
        var a = Adjustments()
        var base = PhotoMask.new(.subject); base.inverted = true
        let parent = try XCTUnwrap(a.acceptSelection(base, operation: nil, parentID: nil)).maskID
        let placed = try XCTUnwrap(a.acceptSelection(PhotoMask.new(.brush), operation: .subtract, parentID: parent))
        XCTAssertEqual(placed.maskID, parent)
        XCTAssertEqual(a.masks.count, 1)
        let mask = a.masks[0]
        XCTAssertFalse(mask.inverted); XCTAssertTrue(mask.selection.inverted)
        XCTAssertEqual(mask.components.map(\.id), [placed.componentID])
        XCTAssertEqual(mask.components[0].operation, .subtract)
        XCTAssertEqual(mask.components[0].selection.feather, 0)
        // A second part leaves the base as it is.
        a.acceptSelection(PhotoMask.new(.color), operation: .add, parentID: parent)
        XCTAssertTrue(a.masks[0].selection.inverted); XCTAssertEqual(a.masks[0].components.count, 2)
    }

    func testCapsAndMissingParentsRefuse() throws {
        var a = Adjustments()
        XCTAssertNil(a.acceptSelection(PhotoMask.new(.brush), operation: .add, parentID: UUID()))
        XCTAssertNil(a.acceptSelection(PhotoMask.new(.brush), operation: .add, parentID: nil))
        XCTAssertTrue(a.masks.isEmpty)
        let parent = try XCTUnwrap(a.acceptSelection(PhotoMask.new(.brush), operation: nil, parentID: nil)).maskID
        XCTAssertTrue(a.canAddComponent(to: parent)); XCTAssertFalse(a.canAddComponent(to: UUID()))
        for _ in 0..<PhotoMask.maxComponents { XCTAssertNotNil(a.acceptSelection(PhotoMask.new(.brush), operation: .add, parentID: parent)) }
        XCTAssertFalse(a.canAddComponent(to: parent))
        XCTAssertNil(a.acceptSelection(PhotoMask.new(.brush), operation: .add, parentID: parent))
        while a.masks.count < PhotoMask.maxCount { a.masks.append(PhotoMask.new(.color)) }
        XCTAssertFalse(a.canAddMask)
        XCTAssertNil(a.acceptSelection(PhotoMask.new(.color), operation: nil, parentID: nil))
        XCTAssertEqual(a.masks.count, PhotoMask.maxCount)
    }

    func testTargetReadsAndWritesAMasksOwnAdjustments() throws {
        var a = Adjustments(); a.pixels.exposure = 1; a.pixels.contrast = 20
        var mask = PhotoMask.new(.subject); mask.adjustments.exposure = -0.5
        a.masks = [mask]
        // The mask shows over neutral adjustments, not the photo's.
        XCTAssertEqual(a.target(mask.id).pixels.exposure, -0.5)
        XCTAssertEqual(a.target(mask.id).pixels.contrast, 0)
        XCTAssertEqual(a.target(nil), a)
        XCTAssertEqual(a.target(UUID()), a)
        a.editTarget(mask.id) { $0.pixels.contrast = 15; $0.pixels.exposure += 0.25; $0.quarterTurns = 1 }
        XCTAssertEqual(a.masks[0].adjustments.contrast, 15)
        XCTAssertEqual(a.masks[0].adjustments.exposure, -0.25)
        // Only what a mask takes lands; the photo is untouched.
        XCTAssertEqual(a.quarterTurns, 0); XCTAssertEqual(a.pixels.exposure, 1); XCTAssertEqual(a.pixels.contrast, 20)
        a.editTarget(nil) { $0.pixels.exposure = 2 }
        XCTAssertEqual(a.pixels.exposure, 2); XCTAssertEqual(a.masks[0].adjustments.exposure, -0.25)
    }

    func testDrawingGradients() {
        let origin = MaskPoint(x: 0.5, y: 0.5), point = MaskPoint(x: 0.6, y: 0.55)
        var radial = MaskSelection(kind: .radial)
        radial.drawGradient(from: origin, to: point)
        XCTAssertEqual(radial.start.x, 0.4, accuracy: 1e-9); XCTAssertEqual(radial.start.y, 0.45, accuracy: 1e-9)
        XCTAssertEqual(radial.end.x, 0.6, accuracy: 1e-9); XCTAssertEqual(radial.end.y, 0.55, accuracy: 1e-9)
        radial.drawGradient(from: origin, to: point, constrained: true)
        XCTAssertEqual(radial.start.y, 0.4, accuracy: 1e-9); XCTAssertEqual(radial.end.y, 0.6, accuracy: 1e-9)
        var linear = MaskSelection(kind: .linear); linear.start = origin
        linear.drawGradient(from: origin, to: point)
        XCTAssertEqual(linear.end, point); XCTAssertEqual(linear.start, origin)
        linear.drawGradient(from: origin, to: MaskPoint(x: 0.7, y: 0.51), constrained: true)
        XCTAssertEqual(linear.end.y, 0.5, accuracy: 1e-9)
    }
}
