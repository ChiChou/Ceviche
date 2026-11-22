import XCTest
@testable import CevicheCore

final class EditTransferTests: XCTestCase {
    func testDefaultTransferKeepsDestinationCompositionAndUsesFrozenValues() throws {
        var source = Adjustments(); source.exposure = 1.25; source.temperature = 5200; source.tint = 14
        source.hdr.enabled = true; source.curve = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.65), .init(x: 1, y: 1)])
        source.selectiveColors[1].saturation = -30; source.geometry.crop = CropRect(width: 0.5)
        var destination = Adjustments(); destination.quarterTurns = 1; destination.geometry.flipHorizontal = true
        destination.masks = [PhotoMask(kind: .linear)]
        destination.retouch = [RetouchStroke(mode: .clone, source: .init(x: 0.1, y: 0.1), target: .init(x: 0.7, y: 0.7), radius: 0.1, softness: 0.5, opacity: 1)]
        destination.colorProfile.preset = .sRGB
        let transfer = EditTransfer(sourceName: "Source", adjustments: source)
        source.exposure = 4
        let result = try transfer.applying(to: destination)
        XCTAssertEqual(result.exposure, 1.25); XCTAssertEqual(result.temperature, 5200); XCTAssertEqual(result.tint, 14)
        XCTAssertTrue(result.hdr.enabled); XCTAssertEqual(result.curve, source.curve)
        XCTAssertEqual(result.selectiveColors, source.selectiveColors)
        XCTAssertEqual(result.geometry, destination.geometry); XCTAssertEqual(result.quarterTurns, 1)
        XCTAssertEqual(result.masks, destination.masks); XCTAssertEqual(result.retouch, destination.retouch)
        XCTAssertEqual(result.colorProfile, destination.colorProfile)
    }
    func testSelectiveTransferPreservesOtherGroupsAndCanClearValues() throws {
        var source = Adjustments(); source.temperature = 7000; source.tint = 12; source.exposure = 2
        var target = Adjustments(); target.exposure = -1; target.temperature = 4800; target.tint = -10
        var copy = EditTransfer(sourceName: "Source", adjustments: source, items: [.whiteBalance])
        let whiteBalance = try copy.applying(to: target)
        XCTAssertEqual(whiteBalance.temperature, 7000); XCTAssertEqual(whiteBalance.tint, 12); XCTAssertEqual(whiteBalance.exposure, -1)
        copy.items = EditTransferItem.defaults.subtracting([.whiteBalance])
        let development = try copy.applying(to: target)
        XCTAssertEqual(development.exposure, 2); XCTAssertEqual(development.temperature, 4800); XCTAssertEqual(development.tint, -10)
        target.masks = [PhotoMask(kind: .radial)]; target.quarterTurns = 2
        let cleared = try EditTransfer(sourceName: "Clean", adjustments: Adjustments(), items: [.masks, .crop, .transform]).applying(to: target)
        XCTAssertTrue(cleared.masks.isEmpty); XCTAssertEqual(cleared.quarterTurns, 0); XCTAssertEqual(cleared.exposure, -1)
    }
    func testMaskCopyHasIndependentIdentifiersAndPreservesGeometry() throws {
        var source = Adjustments(); var mask = PhotoMask(kind: .radial)
        mask.adjustments.exposure = 0.5; mask.components = [MaskComponent(operation: .subtract, selection: PhotoMask(kind: .linear).selection)]
        source.masks = [mask]; source.geometry.crop = CropRect(width: 0.7); source.quarterTurns = 3
        let result = try EditTransfer(sourceName: "Mask", adjustments: source, items: [.crop, .transform, .masks]).applying(to: Adjustments())
        XCTAssertEqual(result.geometry, source.geometry); XCTAssertEqual(result.quarterTurns, 3)
        XCTAssertNotEqual(result.masks[0].id, mask.id); XCTAssertNotEqual(result.masks[0].components[0].id, mask.components[0].id)
        XCTAssertEqual(result.masks[0].selection, mask.selection); XCTAssertEqual(result.masks[0].adjustments, mask.adjustments)
    }
    func testEveryItemTogetherCopiesTheWholeEdit() throws {
        var source = Adjustments()
        source.hdr.enabled = true; source.exposure = 0.7; source.curve = ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)])
        source.parametricCurve.lights = 20; source.temperature = 4100; source.tint = 9; source.vibrance = 12; source.monochrome = true
        source.selectiveColors[2].hue = 10; source.blackWhiteMixer.values[1] = 30; source.splitToning.balance = 20
        source.calibration.redHue = 15; source.colorProfile.preset = .sRGB; source.neutralRAW = true; source.film = FilmSimulation(stock: "ektar100")
        source.clarity = 25; source.sharpness = 40; source.noiseReduction = 30; source.luminanceNoiseDetail = 70
        source.postCropVignette.amount = -30; source.grain.amount = 20; source.lensCorrection = false; source.defringe.purpleAmount = 5
        source.geometry.crop = CropRect(width: 0.6); source.geometry.straighten = 3; source.quarterTurns = 1
        source.geometry.transform.vertical = 12; source.redEyeCorrection = true
        source.faceLiquify = FaceLiquify(region: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5), width: -0.6)
        source.disabledSections = [.grain, .detail]
        var dust = RetouchStroke(mode: .heal, source: .init(x: 0.2, y: 0.2), target: .init(x: 0.3, y: 0.3), radius: 0.05, softness: 0.5, opacity: 1)
        dust.suggested = true
        let brush = RetouchStroke(mode: .clone, source: .init(x: 0.1, y: 0.1), target: .init(x: 0.7, y: 0.7), radius: 0.1, softness: 0.5, opacity: 1)
        var blemish = RetouchStroke(mode: .heal, source: .init(x: 0.4, y: 0.4), target: .init(x: 0.45, y: 0.5), radius: 0.02, softness: 0.4, opacity: 1)
        blemish.face = true
        var person = RetouchStroke(mode: .remove, source: .init(x: 0.6, y: 0.4), target: .init(x: 0.6, y: 0.4), radius: 0.02, softness: 0.5, opacity: 1)
        person.person = true
        // Kinds interleaved: copying them all keeps the order strokes render in.
        source.retouch = [dust, person, blemish, brush]
        let result = try EditTransfer(sourceName: "All", adjustments: source, items: Set(EditTransferItem.allCases)).applying(to: Adjustments())
        XCTAssertEqual(result, source, "Every setting belongs to some item")
        for item in EditTransferItem.allCases where ![.masks, .pointColor, .cameraProfile].contains(item) {
            XCTAssertTrue(item.isModified(in: source), item.rawValue)
        }
    }
    func testDetailSwitchesAreIndependent() {
        var a = Adjustments(); a.sharpness = 40; a.clarity = 20; a.noiseReduction = 30
        a.disabledSections = [.sharpening]
        var e = a.effective(defaults: Adjustments())
        XCTAssertEqual(e.sharpness, Adjustments().sharpness); XCTAssertEqual(e.clarity, 20); XCTAssertEqual(e.noiseReduction, 30)
        a.disabledSections = [.detail]
        e = a.effective(defaults: Adjustments())
        XCTAssertEqual(e.sharpness, 40); XCTAssertEqual(e.clarity, Adjustments().clarity); XCTAssertEqual(e.noiseReduction, 30)
    }
    func testItemsCopyOnlyTheirOwnSettings() throws {
        var source = Adjustments(); source.clarity = 30; source.sharpness = 50; source.disabledSections = [.detail]
        var dust = RetouchStroke(mode: .heal, source: .init(x: 0.2, y: 0.2), target: .init(x: 0.3, y: 0.3), radius: 0.05, softness: 0.5, opacity: 1)
        dust.suggested = true
        source.retouch = [dust]
        var target = Adjustments(); target.sharpness = 10
        let brush = RetouchStroke(mode: .clone, source: .init(x: 0.1, y: 0.1), target: .init(x: 0.7, y: 0.7), radius: 0.1, softness: 0.5, opacity: 1)
        target.retouch = [brush]
        let result = try EditTransfer(sourceName: "Clarity", adjustments: source, items: [.clarity, .dustSpots]).applying(to: target)
        XCTAssertEqual(result.clarity, 30); XCTAssertEqual(result.sharpness, 10)
        XCTAssertTrue(result.disabledSections.contains(.detail), "The panel switch travels with its settings")
        XCTAssertEqual(result.retouch, [brush, dust], "Brushed strokes stay when only dust spots are copied")
        XCTAssertFalse(EditTransferItem.masks.isModified(in: source)); XCTAssertTrue(EditTransferItem.clarity.isModified(in: source))
    }
    func testEditedSettingsCountFromTheCameraDefaultsAndLeaveTheRestOfTheDestination() throws {
        // A RAW's defaults carry its as-shot white balance and the decoder's noise reduction; neither is an edit.
        var baseline = Adjustments(); baseline.temperature = 5200; baseline.tint = 8; baseline.noiseReduction = 20
        var source = baseline; source.exposure = 0.6; source.geometry.crop = CropRect(width: 0.5)
        let edited = EditTransferItem.edited(in: source, from: baseline)
        XCTAssertEqual(edited, [.light, .crop])
        XCTAssertTrue(EditTransferItem.whiteBalance.isModified(in: source), "Against a blank photo the as-shot white balance looks edited")
        var target = Adjustments(); target.temperature = 3100; target.clarity = 15; target.exposure = -1
        let result = try EditTransfer(sourceName: "RAW", adjustments: source, baseline: baseline, items: edited).applying(to: target)
        XCTAssertEqual(result.exposure, 0.6); XCTAssertEqual(result.geometry.crop, source.geometry.crop)
        XCTAssertEqual(result.temperature, 3100); XCTAssertEqual(result.clarity, 15)
    }
    func testEveryItemBelongsToOneSection() {
        XCTAssertEqual(EditTransferSection.allCases.flatMap(\.items), EditTransferItem.allCases)
    }
}
