import XCTest
@testable import CevicheCore

final class CropConstraintTests: XCTestCase {
    private let size = CGSize(width: 6000, height: 4000)
    /// Converging verticals, as in a photo taken looking up.
    private func keystone() -> GeometryAdjustments {
        var geometry = GeometryAdjustments()
        geometry.uprightMode = .guided
        geometry.guides = [UprightGuide(axis: .vertical, start: MaskPoint(x: 0.25, y: 0.1), end: MaskPoint(x: 0.3, y: 0.9)),
                           UprightGuide(axis: .vertical, start: MaskPoint(x: 0.75, y: 0.1), end: MaskPoint(x: 0.7, y: 0.9))]
        return geometry
    }
    func testUprightCropIsRefitInsideThePhotoKeepingItsShape() throws {
        var geometry = keystone()
        XCTAssertFalse(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0), "The full frame shows empty corners after upright")
        let fitted = geometry.constrainedCrop(sourceSize: size, quarterTurns: 0)
        geometry.crop = fitted
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
        let plan = try GeometryPlan(size: size, settings: geometry, quarterTurns: 0)
        XCTAssertEqual(fitted.width * plan.fullSize.width / (fitted.height * plan.fullSize.height),
                       plan.fullSize.width / plan.fullSize.height, accuracy: 0.01, "The crop keeps its proportions")
        XCTAssertGreaterThan(fitted.width * fitted.height, 0.4, "The fit is as large as the outline allows, not a tiny safe box")
    }
    func testStraightenedCropFitsAndAFittingCropIsLeftAlone() {
        var geometry = GeometryAdjustments(); geometry.straighten = 8
        geometry.crop = geometry.constrainedCrop(sourceSize: size, quarterTurns: 1)
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: size, quarterTurns: 1))
        var small = geometry; small.crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertEqual(small.constrainedCrop(sourceSize: size, quarterTurns: 1), small.crop)
    }
    /// A crop drawn in a corner and then turned shrinks where it is; it used to become the largest crop of its shape,
    /// centred and bigger.
    func testTurnedHandDrawnCropShrinksAboutItsOwnCentre() {
        var geometry = GeometryAdjustments(); geometry.straighten = 8
        geometry.crop = CropRect(x: 0.02, y: 0.25, width: 0.3, height: 0.3)
        XCTAssertFalse(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
        let fitted = geometry.constrainedCrop(sourceSize: size, quarterTurns: 0)
        XCTAssertEqual(fitted.x + fitted.width / 2, 0.17, accuracy: 1e-6); XCTAssertEqual(fitted.y + fitted.height / 2, 0.4, accuracy: 1e-6)
        XCTAssertLessThan(fitted.width, 0.3); XCTAssertEqual(fitted.width / fitted.height, 1, accuracy: 1e-6)
        geometry.crop = fitted
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
        // A sliver whose centre is off the turned photo is placed anew, no bigger than it was.
        geometry.crop = CropRect(x: 0, y: 0, width: 0.02, height: 0.02)
        let placed = geometry.constrainedCrop(sourceSize: size, quarterTurns: 0)
        XCTAssertEqual(placed.width, 0.02, accuracy: 1e-6)
        geometry.crop = placed
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: size, quarterTurns: 0))
    }
    func testCropsMayTouchThePhotoBorderWhenNothingIsTurned() {
        var geometry = GeometryAdjustments()
        geometry.crop = CropRect(x: 0.1, y: 0, width: 0.9, height: 0.9)
        XCTAssertTrue(geometry.cropFitsImage(sourceSize: CGSize(width: 600, height: 400), quarterTurns: 0))
        XCTAssertEqual(geometry.constrainedCrop(sourceSize: CGSize(width: 600, height: 400), quarterTurns: 0), geometry.crop)
        geometry.straighten = 3
        XCTAssertFalse(geometry.cropFitsImage(sourceSize: CGSize(width: 600, height: 400), quarterTurns: 0))
    }
    /// Upright analysed on a photo taken looking up: Auto converges strongly, Level turns it a hundredth of a degree.
    private func analysed(_ mode: UprightMode) -> GeometryAdjustments {
        let turn = 0.01 * Double.pi / 180, c = cos(turn), s = sin(turn)
        let level = [c, -s, 0.5 - 0.5*c + 0.5*s, s, c, 0.5 - 0.5*s - 0.5*c, 0, 0, 1]
        let keystone = [1, 0, 0, 0, 1, 0, 0, 0.3, 1]
        var geometry = GeometryAdjustments()
        geometry.uprightAnalysis = UprightAnalysis(auto: keystone, level: level, vertical: keystone, full: keystone)
        geometry.uprightMode = mode
        return geometry
    }
    private func pixels(_ geometry: GeometryAdjustments, _ source: CGSize, turns: Int = 0) throws -> (crop: CGRect, full: CGSize) {
        let plan = try GeometryPlan(size: source, settings: geometry, quarterTurns: turns)
        return (plan.cropPixels, plan.fullSize)
    }
    func testCropFittedToOneUprightModeGrowsBackForANearZeroLevel() throws {
        let source = CGSize(width: 7952, height: 5304)
        var auto = analysed(.auto)
        auto.crop = auto.constrainedCrop(after: GeometryAdjustments(), previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        XCTAssertLessThan(auto.crop.width * auto.crop.height, 0.9, "Auto's convergence leaves empty corners to crop away")
        var level = auto; level.uprightMode = .level
        level.crop = level.constrainedCrop(after: auto, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        XCTAssertTrue(level.cropFitsImage(sourceSize: source, quarterTurns: 0))
        let (crop, full) = try pixels(level, source)
        // The turn's sliver of empty edge (under a pixel), the outline's one pixel margin, and rounding.
        XCTAssertEqual(crop.minX, 0, accuracy: 4); XCTAssertEqual(crop.minY, 0, accuracy: 4)
        XCTAssertEqual(crop.maxX, full.width, accuracy: 4); XCTAssertEqual(crop.maxY, full.height, accuracy: 4)
        var off = level; off.uprightMode = .off
        XCTAssertEqual(off.constrainedCrop(after: level, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0), .full)
    }
    func testCropFollowingThePhotoIsTheLargestThatFitsARealTurn() throws {
        let source = CGSize(width: 7952, height: 5304)
        var auto = analysed(.auto)
        auto.crop = auto.constrainedCrop(after: GeometryAdjustments(), previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        var turned = GeometryAdjustments(); turned.straighten = 8
        turned.uprightAnalysis = auto.uprightAnalysis; turned.crop = auto.crop
        turned.crop = turned.constrainedCrop(after: auto, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        XCTAssertTrue(turned.cropFitsImage(sourceSize: source, quarterTurns: 0))
        let (crop, full) = try pixels(turned, source)
        XCTAssertEqual(crop.width / crop.height, full.width / full.height, accuracy: 0.01, "Free keeps the frame's shape")
        // The largest rectangle of the frame's shape inside a photo turned by θ, from its corners meeting the long edges.
        let theta = 8 * Double.pi / 180, shape = full.width / full.height
        let expected = source.height / (cos(theta) + shape * sin(theta))
        XCTAssertEqual(crop.height, expected, accuracy: 4, "The crop reaches the photo's edge")
        var grown = turned
        grown.crop = CropRect(x: turned.crop.x - 3/full.width, y: turned.crop.y - 3/full.height, width: turned.crop.width + 6/full.width, height: turned.crop.height + 6/full.height)
        XCTAssertFalse(grown.cropFitsImage(sourceSize: source, quarterTurns: 0))
    }
    func testHandDrawnCropIsNotGrownWhenTheCorrectionChanges() {
        let source = CGSize(width: 7952, height: 5304)
        var auto = analysed(.auto); auto.crop = CropRect(x: 0.35, y: 0.3, width: 0.3, height: 0.25)
        XCTAssertTrue(auto.cropFitsImage(sourceSize: source, quarterTurns: 0))
        var level = auto; level.uprightMode = .level
        XCTAssertEqual(level.constrainedCrop(after: auto, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0), auto.crop)
        // A change that brings its own crop (pasted edits, a quarter turn) keeps it.
        var pasted = level; pasted.crop = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        XCTAssertEqual(pasted.constrainedCrop(after: GeometryAdjustments(), previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0), pasted.crop)
    }
    func testFixedAspectCropFollowsThePhotoAtItsAspect() throws {
        let source = CGSize(width: 6000, height: 4000)
        var straight = GeometryAdjustments(); straight.aspect = .square
        straight.crop = CropRect(x: 1.0/6, y: 0, width: 2.0/3, height: 1)
        var turned = straight; turned.straighten = 10
        turned.crop = turned.constrainedCrop(after: straight, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        XCTAssertTrue(turned.cropFitsImage(sourceSize: source, quarterTurns: 0))
        let square = try pixels(turned, source).crop
        XCTAssertEqual(square.width, square.height, accuracy: 2)
        XCTAssertLessThan(square.height, 3900)
        straight.crop = turned.crop
        straight.crop = straight.constrainedCrop(after: turned, previousQuarterTurns: 0, sourceSize: source, quarterTurns: 0)
        let (crop, _) = try pixels(straight, source)
        XCTAssertEqual(crop.width, 4000, accuracy: 2); XCTAssertEqual(crop.height, 4000, accuracy: 2)
    }
    func testOlderDocumentsDecodeWithConstrainOn() throws {
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GeometryAdjustments())) as! [String: Any]
        encoded.removeValue(forKey: "constrainCrop")
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertTrue(decoded.constrainCrop, "Constrain to image is the default, as in other RAW editors")
        XCTAssertEqual(decoded, GeometryAdjustments())
    }
}
