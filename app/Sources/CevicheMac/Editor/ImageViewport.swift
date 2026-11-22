import AppKit
import SwiftUI
import CevicheCore

/// Magnification is relative to the fitted image, independent of preview resolution.
struct ImageViewport: Equatable {
    static let steps: [Double] = [1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16]
    static let maximum = 16.0
    private(set) var scale = 1.0
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    /// Set by a focus that keeps its region centered even where that leaves the photo off-center or past the canvas
    /// edge, as cropping does; fitting, zooming and panning keep the photo in view again.
    private(set) var unclamped = false
    /// Space kept clear around the fitted photo; Crop uses it so the frame's handles and the rotation ring stay on the canvas.
    var inset = 0.0
    var isFitted: Bool { scale <= 1.000001 }
    var canZoomIn: Bool { scale < Self.maximum - 0.000001 }
    var canZoomOut: Bool { !isFitted }
    var nextLarger: Double { Self.steps.first { $0 > scale + 0.000001 } ?? Self.maximum }
    var nextSmaller: Double { Self.steps.last { $0 < scale - 0.000001 } ?? 1 }

    func imageRect(image: CGSize, canvas: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let fit = fitScale(image: image, canvas: canvas)
        let size = CGSize(width: image.width * fit * scale, height: image.height * fit * scale)
        let origin = CGPoint(x: canvas.width / 2 - center.x * size.width, y: canvas.height / 2 - center.y * size.height)
        return CGRect(origin: clamped(origin: origin, size: size, canvas: canvas), size: size)
    }
    private func fitScale(image: CGSize, canvas: CGSize) -> Double {
        min(max(1, canvas.width - 2 * inset) / image.width, max(1, canvas.height - 2 * inset) / image.height)
    }
    private func clamped(origin: CGPoint, size: CGSize, canvas: CGSize) -> CGPoint {
        if unclamped { return origin }
        return CGPoint(x: size.width <= canvas.width ? (canvas.width - size.width) / 2 : min(0, max(canvas.width - size.width, origin.x)),
                y: size.height <= canvas.height ? (canvas.height - size.height) / 2 : min(0, max(canvas.height - size.height, origin.y)))
    }
    mutating func fit() { scale = 1; center = CGPoint(x: 0.5, y: 0.5); unclamped = false }
    mutating func zoom(to value: Double, anchor: CGPoint? = nil, image: CGSize, canvas: CGSize) {
        guard value.isFinite else { return }
        let old = imageRect(image: image, canvas: canvas)
        guard old.width > 0, old.height > 0 else { return }
        let anchor = anchor ?? CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let point = CGPoint(x: (anchor.x - old.minX) / old.width, y: (anchor.y - old.minY) / old.height)
        let next = min(Self.maximum, max(1, value))
        unclamped = false
        let size = CGSize(width: old.width * next / scale, height: old.height * next / scale)
        scale = next
        if isFitted { fit(); return }
        let origin = clamped(origin: CGPoint(x: anchor.x - point.x * size.width, y: anchor.y - point.y * size.height), size: size, canvas: canvas)
        center = CGPoint(x: (canvas.width / 2 - origin.x) / size.width, y: (canvas.height / 2 - origin.y) / size.height)
    }
    /// Shows a region of the image (normalized, top-left origin) as large as the canvas allows, centered, with a small margin.
    /// `unclamped` keeps the region centered even when the photo then sits off-center or past the canvas edge.
    mutating func focus(on region: CGRect, image: CGSize, canvas: CGSize, unclamped: Bool = false) {
        guard region.width > 0, region.height > 0, image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return }
        let fit = fitScale(image: image, canvas: canvas)
        let regionSize = CGSize(width: region.width * image.width * fit, height: region.height * image.height * fit)
        scale = min(Self.maximum, max(1, min(canvas.width / regionSize.width, canvas.height / regionSize.height) * 0.96))
        center = CGPoint(x: region.midX, y: region.midY)
        self.unclamped = unclamped
        if isFitted && !unclamped { center = CGPoint(x: 0.5, y: 0.5) }
    }
    /// Shows the image at exactly `target` on the canvas (at least fitted), past the canvas edge if need be.
    mutating func show(at target: CGRect, image: CGSize, canvas: CGSize) {
        guard target.width > 0, target.height > 0, image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return }
        scale = min(Self.maximum, max(1, target.width / (image.width * fitScale(image: image, canvas: canvas))))
        if isFitted { fit(); return }
        center = CGPoint(x: (canvas.width / 2 - target.minX) / target.width, y: (canvas.height / 2 - target.minY) / target.height)
        unclamped = true
    }
    mutating func pan(by delta: CGSize, image: CGSize, canvas: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        let rect = imageRect(image: image, canvas: canvas)
        guard !isFitted, rect.width > 0, rect.height > 0 else { return }
        unclamped = false
        let origin = clamped(origin: CGPoint(x: rect.minX + delta.width, y: rect.minY + delta.height), size: rect.size, canvas: canvas)
        center = CGPoint(x: (canvas.width / 2 - origin.x) / rect.width, y: (canvas.height / 2 - origin.y) / rect.height)
    }
}

struct ZoomableImage: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    let image: CGImage
    func makeNSView(context: Context) -> ImageCanvas { ImageCanvas() }
    func updateNSView(_ view: ImageCanvas, context: Context) {
        view.model = model
        view.setPreview(image, geometry: model.renderedGeometry)
        view.updateGeometry()
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

/// Native magnification events preserve the photograph beneath the gesture's focal point.
final class ImageCanvas: NSView {
    weak var model: EditorModel?
    var image: CGImage?
    private let photograph = HDRPhotographView()
    /// The visible region developed from the source at the size it is shown, layered over the preview.
    let detailPhotograph = HDRPhotographView()
    private var reportedDetailRegion: CGRect??
    private var reportedPhotoWidth = 0.0
    private let originalClip = PassthroughCanvasView()
    private let originalPhotograph = HDRPhotographView()
    private let toolsOverlay = CanvasToolsOverlay()
    /// Redraws while Object's removal is animating.
    var removalAnimation: Timer?
    var lastDrag: CGPoint?
    var spacePanning = false
    var draggingSplit = false
    var drawingMask = false
    /// Which part of a gradient mask the pointer took hold of; axis and feather handles belong to radial masks.
    enum GradientHandle: Equatable { case start, end, move, axis(x: Bool, positive: Bool), feather, rotate }
    var gradientHandle: GradientHandle?
    var gradientDragOrigin: MaskPoint?
    var gradientOriginal: (start: MaskPoint, end: MaskPoint, rotation: Double)?
    var drawingRetouch = false
    /// The stroke being drawn was carried on with Shift-click rather than started.
    var extendingRetouch = false
    /// A retouch stroke's target or source held by the pointer: the stroke as it was and where the drag began.
    enum RetouchPart { case target, source }
    var faceRegionDrag: FaceRegionDrag?
    var retouchDrag: (id: UUID, part: RetouchPart, original: RetouchStroke, from: MaskPoint)?
    /// A dust spot held by its body (moving from its center and the pointer's start) or by its edge (resizing).
    enum DustDrag { case move(UUID, center: MaskPoint, from: MaskPoint), resize(UUID) }
    var dustDrag: DustDrag?
    /// A healed spot's stroke as it was when the drag began; moving or resizing it takes a new source on release.
    var healedDustDrag: RetouchStroke?
    /// A click on the photo away from every spot adds one; a drag there instead boxes spots to select (Shift adds to
    /// the selection, which it started from).
    var dustAddPoint: CGPoint?
    /// Portrait's Spots: where a press on bare skin went down, adding a spot there unless it turns into a box.
    var faceSpotAddPoint: CGPoint?
    /// A box dragged around handles to select them: dust spots with a plain drag, brush strokes' pins with Option.
    var handleMarquee: (start: CGPoint, end: CGPoint, base: Set<UUID>)?
    var pointerPosition: CGPoint?
    private var pointerTracking: NSTrackingArea?
    private var displayedPlan: GeometryPlan?
    var pendingPreview: (CGImage, GeometryPlan?)?
    var canvasPlan: GeometryPlan? { displayedPlan ?? model?.renderedGeometry ?? model?.geometryPlan }
    /// Keep the pixels and their mapping together; a late render must not move an edge under a dragged guide.
    func setPreview(_ image: CGImage, geometry: GeometryPlan?) {
        if model?.guideDraft != nil || rulerDraft != nil { pendingPreview = (image, geometry); return }
        self.image = image; displayedPlan = geometry; pendingPreview = nil
    }
    var rulerDraft: (start: CGPoint, end: CGPoint)?
    var movingGuideStart = false
    /// The perspective corner being dragged.
    var cornerDrag: Int?
    var guideDragOrigin: CGPoint?
    var cropStart: MaskPoint?
    var cropOriginal = CropRect.full
    enum CropHandle: Equatable { case corner(Int), edge(Int) }
    var cropHandle: CropHandle?
    var cropPointer: MaskPoint?
    /// The last pointer (or move offset) whose frame fitted the photo, where the next step of the drag starts from.
    var cropReached: CGPoint?
    /// Dragging inside the frame moves the frame with the pointer over the still photo, from where the drag began.
    var cropMoving: CGPoint?
    /// Dragging in the ring just outside a handle straightens the photo about the frame's center.
    var cropRotation: (angle: Double, straighten: Double)?
    /// While a corner turns the photo, the frame stays where it was on screen and the photo keeps its scale under it:
    /// the frame, screen points per pixel of the photo, and the crop center's offset from the photo's center in pixels
    /// (which turning keeps, as it keeps the crop's size in pixels).
    var cropTurn: (frame: CGRect, pointsPerPixel: Double, offset: CGSize)?
    var mixerDragOrigin: Double?
    static let pixelPeepingScale = 2.0
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    /// A curved two-headed arrow bowed away from the frame, one for each of eight directions (0 points right,
    /// counting counterclockwise in 45° steps), so the pointer shows a drag there turns the photo.
    static let rotateCursors: [NSCursor] = (0..<8).map { index in
        let size = NSSize(width: 28, height: 28), center = CGPoint(x: 14, y: 14)
        let outward = Double(index) * .pi / 4, spread = 0.95, radius = 8.0
        let image = NSImage(size: size, flipped: false) { _ in
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: (outward - spread) * 180 / .pi, endAngle: (outward + spread) * 180 / .pi)
            func head(at angle: Double, turning sign: Double) -> NSBezierPath {
                let end = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                let tangent = CGPoint(x: -sin(angle) * sign, y: cos(angle) * sign), normal = CGPoint(x: cos(angle), y: sin(angle))
                let path = NSBezierPath()
                path.move(to: CGPoint(x: end.x + tangent.x * 4, y: end.y + tangent.y * 4))
                path.line(to: CGPoint(x: end.x + normal.x * 3.5 - tangent.x, y: end.y + normal.y * 3.5 - tangent.y))
                path.line(to: CGPoint(x: end.x - normal.x * 3.5 - tangent.x, y: end.y - normal.y * 3.5 - tangent.y))
                path.close(); return path
            }
            let heads = [head(at: outward + spread, turning: 1), head(at: outward - spread, turning: -1)]
            NSColor.black.setStroke(); arc.lineWidth = 4; arc.stroke()
            for path in heads { path.lineWidth = 2; path.lineJoinStyle = .round; path.stroke() }
            NSColor.white.setStroke(); arc.lineWidth = 1.6; arc.stroke()
            NSColor.white.setFill(); for path in heads { path.fill() }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
    }
    /// The straighten change for a pointer that moved from `start` to `current` around `center`, in degrees;
    /// positive is clockwise on screen. One flip mirrors the rotation, so the photo still follows the pointer.
    static func straightenDelta(start: CGPoint, current: CGPoint, center: CGPoint, mirrored: Bool) -> Double {
        var delta = atan2(current.y - center.y, current.x - center.x) - atan2(start.y - center.y, start.x - center.x)
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        return delta * 180 / .pi * (mirrored ? -1 : 1)
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        originalClip.wantsLayer = true; originalClip.layer?.masksToBounds = true
        addSubview(photograph); addSubview(detailPhotograph); addSubview(originalClip); originalClip.addSubview(originalPhotograph)
        toolsOverlay.canvas = self; addSubview(toolsOverlay)
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.tr("Photograph. Pinch to zoom; drag or scroll to pan; double-click to toggle fit."))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updateGeometry() {
        guard let image else { return }
        model?.updateViewportGeometry(image: CGSize(width: image.width, height: image.height), canvas: bounds.size)
        updatePhotographs()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateGeometry(); needsDisplay = true }
    /// Where the photo is drawn: the viewport's place for it.
    func photoRect(_ model: EditorModel, _ image: CGImage) -> CGRect {
        if let turn = cropTurn, let size = canvasPlan?.fullSize, size.width > 0 {
            let w = size.width * turn.pointsPerPixel, h = size.height * turn.pointsPerPixel
            let cx = turn.frame.midX - turn.offset.width * turn.pointsPerPixel, cy = turn.frame.midY - turn.offset.height * turn.pointsPerPixel
            return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
        return model.viewport.imageRect(image: CGSize(width: image.width, height: image.height), canvas: bounds.size)
    }
    override func draw(_ dirtyRect: NSRect) {
        updatePhotographs()
        guard let image, let model, !model.peekingOriginal else { return }
        let rect = photoRect(model, image)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        if model.adjustments.masks.contains(where: { $0.enabled && $0.cutsOutBackground }) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            let tile = 12.0
            for y in stride(from: max(0, rect.minY), to: min(bounds.height, rect.maxY), by: tile) {
                for x in stride(from: max(0, rect.minX), to: min(bounds.width, rect.maxX), by: tile) {
                    let odd = (Int(x / tile) + Int(y / tile)) % 2 == 0
                    NSColor(white: odd ? 0.22 : 0.3, alpha: 1).setFill()
                    NSBezierPath(rect: CGRect(x: x, y: y, width: tile, height: tile)).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func updatePhotographs() {
        guard let model, let image else { return }
        let rect = photoRect(model, image)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        photograph.frame = rect; photograph.image = image
        photograph.isHidden = model.peekingOriginal
        let backing = window?.backingScaleFactor ?? 2
        // Past 2 screen pixels per image pixel, smoothing only invents detail; show hard pixel edges instead.
        func filter(_ pixels: Int) -> CALayerContentsFilter { rect.width * backing / Double(max(1, pixels)) >= Self.pixelPeepingScale ? .nearest : .linear }
        photograph.layer?.magnificationFilter = filter(image.width); originalPhotograph.layer?.magnificationFilter = filter(image.width)
        // The preview follows the sliders; once they rest, the visible region is developed from the source at the
        // size it is shown, so even the fitted view ends on full-resolution pixels averaged down to the screen.
        let showsDetail = !model.comparing && model.toolTab != .crop
        let visible = rect.intersection(bounds)
        let region: CGRect? = showsDetail && !visible.isEmpty ? CGRect(x: (visible.minX - rect.minX) / rect.width, y: (visible.minY - rect.minY) / rect.height,
                                                                         width: visible.width / rect.width, height: visible.height / rect.height) : nil
        let photoWidth = (rect.width * backing).rounded()
        if reportedDetailRegion != .some(region) || reportedPhotoWidth != photoWidth {
            reportedDetailRegion = .some(region); reportedPhotoWidth = photoWidth
            DispatchQueue.main.async { [weak model] in model?.requestDetail(region, photoWidth: photoWidth) }
        }
        if showsDetail, !model.peekingOriginal, let detail = model.detail {
            detailPhotograph.isHidden = false
            detailPhotograph.frame = CGRect(x: rect.minX + detail.region.minX * rect.width, y: rect.minY + detail.region.minY * rect.height,
                                            width: detail.region.width * rect.width, height: detail.region.height * rect.height)
            detailPhotograph.image = detail.image
            detailPhotograph.layer?.magnificationFilter = filter(Int((Double(detail.image.width) / detail.region.width).rounded()))
        } else { detailPhotograph.isHidden = true; detailPhotograph.image = nil }
        if model.comparing {
            let mask = CAShapeLayer()
            mask.path = CGPath(rect: CGRect(x: max(0, bounds.width * model.comparisonSplit - rect.minX), y: 0, width: rect.width, height: rect.height), transform: nil)
            photograph.layer?.mask = mask
        } else { photograph.layer?.mask = nil }
        originalClip.frame = CGRect(x: 0, y: 0, width: bounds.width * (model.peekingOriginal ? 1 : model.comparisonSplit), height: bounds.height)
        originalClip.isHidden = !model.comparing && !model.peekingOriginal
        originalPhotograph.frame = rect; originalPhotograph.image = model.originalPreview
        toolsOverlay.frame = bounds; toolsOverlay.needsDisplay = true
        CATransaction.commit()
    }
    fileprivate func drawTools() {
        guard let image, let model, !model.peekingOriginal else { return }
        let rect = photoRect(model, image)
        if model.toolTab == .masks, !model.comparing {
            if model.showMaskOverlay, let overlay = model.maskOverlay {
                NSImage(cgImage: overlay, size: CGSize(width: overlay.width, height: overlay.height)).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
            for (preview, opacity) in model.partPreviews {
                NSImage(cgImage: preview, size: CGSize(width: preview.width, height: preview.height)).draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
            if let stroke = model.liveStroke { drawLiveStroke(stroke, removes: model.liveStrokeRemoves, model: model) }
            if let mask = model.editableSelection, mask.kind == .linear || mask.kind == .radial, !model.awaitingGradient {
                drawGradient(mask, in: rect)
            }
        }
        // The zone map stands in for the photo; one measured from an earlier preview of the same size stays until the
        // newest is measured, so dragging a slider doesn't flash the photo.
        if model.zonesOnCanvas, let zones = model.zoneDisplay, zones.source.width == image.width, zones.source.height == image.height {
            NSImage(cgImage: zones.image, size: CGSize(width: zones.image.width, height: zones.image.height))
                .draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            // A new map can put a new zone under a pointer that hasn't moved.
            DispatchQueue.main.async { [weak self] in self?.updateZonePointer() }
        }
        if !model.comparing { drawGeometryTools(in: rect, model: model) }
        if model.reviewingDust, !model.comparing, model.dustVisualize { drawDustMaps(model: model, in: rect) }
        if model.reviewingDust, !model.comparing { drawDustSpots(model: model) }
        if model.removing, !model.comparing { drawHoveredRetouch(model: model) }
        // What Object is taking out keeps moving until its fill lands.
        let removing = model.removing && !model.comparing && drawRemovingObjects(model: model)
        if removing, removalAnimation == nil {
            removalAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        } else if !removing, let timer = removalAnimation { timer.invalidate(); removalAnimation = nil }
        if model.toolTab == .face, model.showingFramings, !model.comparing { drawFramings(in: rect, model: model) }
        if showsFaceTags(model) { drawFaceTags(model: model) }
        if showsFaceParts(model) { drawFaceParts(model: model) }
        if model.toolTab == .face, !model.comparing { drawHoveredFace(model: model) }
        if model.comparing, model.originalPreview != nil {
            let divider = bounds.width * model.comparisonSplit
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: NSRect(x: divider - 0.75, y: 0, width: 1.5, height: bounds.height)).fill()
            let handle = NSRect(x: divider - 11, y: bounds.midY - 17, width: 22, height: 34)
            NSColor(white: 0.15, alpha: 0.95).setFill(); NSBezierPath(roundedRect: handle, xRadius: 5, yRadius: 5).fill()
            let arrows = NSBezierPath()
            arrows.move(to: CGPoint(x: divider - 3, y: bounds.midY - 4)); arrows.line(to: CGPoint(x: divider - 7, y: bounds.midY)); arrows.line(to: CGPoint(x: divider - 3, y: bounds.midY + 4))
            arrows.move(to: CGPoint(x: divider + 3, y: bounds.midY - 4)); arrows.line(to: CGPoint(x: divider + 7, y: bounds.midY)); arrows.line(to: CGPoint(x: divider + 3, y: bounds.midY + 4))
            NSColor.white.setStroke(); arrows.lineWidth = 1.5; arrows.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
            (L10n.tr(" ORIGINAL ") as NSString).draw(at: CGPoint(x: 10, y: 10), withAttributes: attributes)
            (L10n.tr(" EDITED ") as NSString).draw(at: CGPoint(x: bounds.width - 70, y: 10), withAttributes: attributes)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        pointerTracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) {
        if model?.spaceHeld == true { NSCursor.openHand.set(); return }
        pointerPosition = convert(event.locationInWindow, from: nil); needsDisplay = true
        updateZonePointer()
        // Placing the Face region draws no brush, so the pointer shows what a drag would do instead of hiding.
        if let model, model.toolTab == .face, model.showingFramings, !model.comparing, let pointerPosition {
            (framingAt(pointerPosition) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if let model, showsFaceParts(model), let pointerPosition {
            (facePart(at: pointerPosition) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if let model, showsFaceTags(model), let pointerPosition {
            (faceTag(at: pointerPosition) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
        } else if let model, model.placingFaceRegion, !model.comparing, let pointerPosition {
            faceRegionCursor(at: pointerPosition, model: model).set()
        } else if let model, model.selectsRetouch, !model.comparing {
            NSCursor.arrow.set()
        } else if let model, model.picksObject, !model.comparing, let pointerPosition {
            let p = maskPoint(pointerPosition, clamp: false)
            // The pointing hand: a click picks what is under it.
            (p != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
            model.hoverObject(at: p, tolerance: p.map { objectTolerance(at: pointerPosition, $0) } ?? 0, modifier: ObjectModifier(event.modifierFlags))
        } else if let model, model.toolTab == .masks, model.maskTool == .object, !model.comparing, let pointerPosition {
            let p = maskPoint(pointerPosition, clamp: false)
            (p != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
            model.hoverMaskObject(at: p)
        } else if let model, model.editsFaceSpots, !model.comparing, let pointerPosition, spotFrameButton(at: pointerPosition) != nil {
            NSCursor.pointingHand.set()
        } else if let model, model.editsFaceSpots, !model.comparing, let pointerPosition {
            // Over a spot the hand that moves it; on the photo a crosshair, where a click adds a spot.
            (retouchHit(at: pointerPosition) != nil ? NSCursor.openHand : maskPoint(pointerPosition, clamp: false) != nil ? NSCursor.crosshair : NSCursor.arrow).set()
        } else if let model, model.paintsRetouch, !model.comparing, let pointerPosition, maskPoint(pointerPosition, clamp: false) != nil {
            let extending = event.modifierFlags.contains(.shift) && model.extendableRetouch != nil
            // Option boxes pins instead of painting.
            if event.modifierFlags.contains(.option) { NSCursor.crosshair.set() }
            else { (retouchHit(at: pointerPosition) != nil && !extending ? NSCursor.openHand : Self.blankCursor).set() }
        }
        if let pointerPosition { updateCropCursor(at: pointerPosition, modifiers: event.modifierFlags) }
        if let model, model.toolTab == .masks, !model.comparing, !model.awaitingGradient, model.maskTool == nil || model.maskTool == .radial,
           let mask = model.editableSelection, mask.kind == .radial, let pointerPosition {
            // The knob and the outline turn the ellipse; the pointer curls the way the drag would.
            if radialRotateHit(pointerPosition, mask) {
                let center = sourceCanvasPoint(radialGeometry(mask).center)
                let angle = atan2(center.y - pointerPosition.y, pointerPosition.x - center.x)
                Self.rotateCursors[(Int((angle / (.pi / 4)).rounded()) % 8 + 8) % 8].set()
            } else if let p = maskPoint(pointerPosition, clamp: false), radialGeometry(mask).normalizedRadius(p) < 1 {
                NSCursor.openHand.set()
            }
        }
        if let model, model.reviewingDust, !model.comparing, let pointerPosition {
            // Dust circles come and go too often for cursor rects; the pointer shows what a drag would do.
            if let (_, edge) = dustHit(at: pointerPosition) { (edge ? NSCursor.frameResize(position: .bottomRight, directions: .all) : NSCursor.openHand).set() }
            else { (maskPoint(pointerPosition, clamp: false) != nil ? NSCursor.crosshair : NSCursor.arrow).set() }
        }
        // Let [ and ] reach the brush without a click first, but never steal focus from text editing.
        if paintsWithBrush, let window, window.firstResponder !== self, !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
    }
    /// The zone under the pointer, for the zone strip.
    func updateZonePointer() {
        guard let model, model.zonesOnCanvas, let image, let pointerPosition, let zones = model.zoneDisplay else { return }
        let rect = photoRect(model, image)
        let zone = zones.map.zone(at: CGPoint(x: (pointerPosition.x - rect.minX) / max(1, rect.width), y: (pointerPosition.y - rect.minY) / max(1, rect.height)))
        if model.zonePointer.zone != zone { model.zonePointer.zone = zone }
    }
    override func mouseExited(with event: NSEvent) {
        pointerPosition = nil; needsDisplay = true
        if model?.zonePointer.zone != nil { model?.zonePointer.zone = nil }
        if let model, model.picksObject { model.hoverObject(at: nil, tolerance: 0, modifier: nil) }
        if let model, model.toolTab == .masks, model.maskTool == .object { model.hoverMaskObject(at: nil) }
    }
    /// How far off a wire a click at `point` may land and still find it: 8 points on screen, as a fraction of the photo.
    func objectTolerance(at point: CGPoint, _ p: MaskPoint) -> Double {
        guard let q = maskPoint(CGPoint(x: point.x + 8, y: point.y), clamp: true) else { return 0.006 }
        return min(0.02, max(0.002, hypot(q.x - p.x, q.y - p.y)))
    }
    override func resetCursorRects() {
        if model?.spaceHeld == true { addCursorRect(bounds, cursor: .openHand); return }
        // Brushes draw their own footprint and center mark, so the system cursor would only hide it.
        if model?.placingFaceRegion == true {
            addCursorRect(bounds, cursor: .crosshair)
        } else if model?.selectsRetouch == true {
            addCursorRect(bounds, cursor: .arrow)
        } else if model?.picksObject == true {
            addCursorRect(bounds, cursor: .pointingHand)
        } else if paintsWithBrush, let image, let model {
            let photo = model.viewport.imageRect(image: CGSize(width: image.width, height: image.height), canvas: bounds.size).intersection(bounds)
            for strip in [CGRect(x: 0, y: 0, width: bounds.width, height: photo.minY), CGRect(x: 0, y: photo.maxY, width: bounds.width, height: bounds.height - photo.maxY),
                          CGRect(x: 0, y: photo.minY, width: photo.minX, height: photo.height), CGRect(x: photo.maxX, y: photo.minY, width: bounds.width - photo.maxX, height: photo.height)] where strip.width > 0 && strip.height > 0 {
                addCursorRect(strip, cursor: .arrow)
            }
            if !photo.isEmpty { addCursorRect(photo, cursor: Self.blankCursor) }
        } else if croppingFrame {
            // The crop zones are circles around the handles, so the pointer is set as it moves (`updateCropCursor`).
        } else {
            let objects = model?.toolTab == .masks && model?.maskTool == .object
            let picking = !objects && model?.toolTab == .crop || model?.reviewingDust == true || model?.toolTab == .masks && model?.maskTool != nil || model?.targetedMixer != nil
            addCursorRect(bounds, cursor: objects ? .pointingHand : picking ? .crosshair : (model?.viewport.isFitted == false ? .openHand : .arrow))
        }
        if let model, model.comparing { addCursorRect(NSRect(x: bounds.width * model.comparisonSplit - 10, y: 0, width: 20, height: bounds.height), cursor: .resizeLeftRight) }
    }
    func displayPoint(_ point: CGPoint, clamp: Bool) -> MaskPoint? {
        guard let image, let model else { return nil }
        let rect = photoRect(model, image)
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return MaskPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, 1 - (point.y - rect.minY) / rect.height)))
    }
    func maskPoint(_ point: CGPoint, clamp: Bool) -> MaskPoint? {
        guard let p = displayPoint(point, clamp: clamp), let model else { return nil }
        let source = canvasPlan?.sourcePoint(p) ?? p.unrotated(model.adjustments.quarterTurns)
        guard source.x.isFinite, source.y.isFinite, clamp || (0...1).contains(source.x) && (0...1).contains(source.y) else { return nil }
        return MaskPoint(x: min(1, max(0, source.x)), y: min(1, max(0, source.y)))
    }
    func canvasPoint(_ p: MaskPoint) -> CGPoint {
        guard let image, let model else { return .zero }
        let rect = photoRect(model, image)
        return CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + (1 - p.y) * rect.height)
    }
    private var paintsWithBrush: Bool {
        guard let model, !model.comparing else { return false }
        return model.eyedropper != nil || model.paintsRetouch && !model.placingFaceRegion || model.toolTab == .masks && model.maskTool == .brush
    }
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Pressing or releasing Shift/Option mid-drag re-applies the resize without waiting for the pointer to move.
        if cropStart != nil, let p = cropPointer { resizeCrop(to: p, modifiers: event.modifierFlags) }
        if paintsWithBrush || model?.toolTab == .crop { window?.invalidateCursorRects(for: self); needsDisplay = true }
        if let pointerPosition { updateCropCursor(at: pointerPosition, modifiers: event.modifierFlags) }
        // Object: holding Shift or Option shows at once what a click would add or take away.
        if let model, model.picksObject, let pointerPosition, let p = maskPoint(pointerPosition, clamp: false) {
            model.hoverObject(at: p, tolerance: objectTolerance(at: pointerPosition, p), modifier: ObjectModifier(event.modifierFlags))
        }
    }
    /// Edit › Select All (⌘A) on the photo in Retouch selects every handle the tool shows, dust spots or the strokes'
    /// pins; elsewhere the menu item is off (see `validateMenuItem`).
    @objc override func selectAll(_ sender: Any?) {
        guard let model, model.removing else { return }
        model.selectedRetouchIDs = Set(model.retouchHandleIDs); needsDisplay = true
    }
    /// [ and ] resize the active brush, as in most editors.
    override func keyDown(with event: NSEvent) {
        // A framing picked on the photo: Return applies it, Esc lets it go.
        if let model, model.toolTab == .face, let picked = model.pickedFraming {
            if event.keyCode == 36 || event.keyCode == 76 { model.applyFraming(picked); needsDisplay = true; return }
            if event.keyCode == 53 { model.pickedFraming = nil; needsDisplay = true; return }
        }
        if let model, event.keyCode == 53, model.dismissTool() { window?.invalidateCursorRects(for: self); needsDisplay = true; return }
        if let model, event.keyCode == 36 || event.keyCode == 76, model.finishCrop() { window?.invalidateCursorRects(for: self); needsDisplay = true; return }
        if let model, model.toolTab == .crop, model.cropDrawingGuide, event.keyCode == 51 || event.keyCode == 117 { model.deleteSelectedGuide(); needsDisplay = true; return }
        if let model, model.toolTab == .crop, let key = event.charactersIgnoringModifiers?.lowercased(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if key == "x" { model.swapCropAspect(); needsDisplay = true; return }
            if key == "o" { model.cycleCropOverlay(reverseOrientation: event.modifierFlags.contains(.shift)); needsDisplay = true; return }
        }
        if let model, event.keyCode == 51 || event.keyCode == 117, model.toolTab == .masks, model.selectedMaskID != nil { model.deleteSelectedMaskOrComponent(); needsDisplay = true; return }
        if let model, model.removing, !model.selectedRetouchIDs.isEmpty {
            if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelectedRetouch(); needsDisplay = true; return }
            if event.charactersIgnoringModifiers == "R", !model.selectedStrokes.isEmpty { if !event.isARepeat { model.refreshRetouch(model.selectedRetouchIDs) }; return }
        }
        guard let model, model.eyedropper == nil, paintsWithBrush, let key = event.charactersIgnoringModifiers, key == "[" || key == "]" else { return super.keyDown(with: event) }
        let factor = key == "]" ? 1.15 : 1 / 1.15
        if model.removing { model.retouchRadius = min(0.15, max(0.001, model.retouchRadius * factor)) }
        else { model.brushRadius = min(0.25, max(0.003, model.brushRadius * factor)) }
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard model?.viewport.isFitted == false else { return }
        updateGeometry()
        let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        model?.panImage(by: CGSize(width: event.scrollingDeltaX * multiplier, height: event.scrollingDeltaY * multiplier))
        needsDisplay = true
    }
}

/// Layer contents retain floating-point pixels and their measured headroom. Core
/// Animation adapts them to the current screen, including SDR-only displays.
final class HDRPhotographView: PassthroughCanvasView {
    var image: CGImage? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // EDR display of the float contents: the macOS 26 preference, or the older per-layer opt-in before that.
        if #available(macOS 26, *) { layer?.preferredDynamicRange = .high } else { layer?.wantsExtendedDynamicRangeContent = true }
        layer?.toneMapMode = .automatic
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { layer?.contents = image }
}
class PassthroughCanvasView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private final class CanvasToolsOverlay: PassthroughCanvasView {
    weak var canvas: ImageCanvas?
    override func draw(_ dirtyRect: NSRect) { canvas?.drawTools() }
}

extension ImageCanvas: NSMenuItemValidation {
    /// Select All only means something on the photo where Remove shows handles.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(selectAll(_:)) ? model.map { $0.removing && !$0.retouchHandleIDs.isEmpty } == true : true
    }
}
