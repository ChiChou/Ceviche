import AppKit
import CevicheCore

/// Portrait's people on the photo: a tag above each face, filled with a check when the corrections are for that person
/// and hollow when not. The pointer over a face or its tag outlines the face; a click ticks or unticks it, as the faces
/// in the panel's row do. Shown with two faces or more, while clicks on the photo do nothing else (Photo in the bar).
extension ImageCanvas {
    private static let tagRadius = 9.0

    func showsFaceTags(_ model: EditorModel) -> Bool {
        model.toolTab == .face && model.isGroupPortrait && model.portraitTool == .photo && !model.comparing && !model.busy
    }
    /// A face on the canvas (rows run downward here): Vision's box runs from the brows to the chin, so it is carried up
    /// over the forehead.
    func faceFrame(_ vision: CGRect) -> CGRect {
        let box = CGRect(x: vision.minX, y: vision.minY, width: vision.width, height: vision.height * 1.35)
        let corners = [MaskPoint(x: box.minX, y: box.minY), MaskPoint(x: box.maxX, y: box.minY), MaskPoint(x: box.maxX, y: box.maxY), MaskPoint(x: box.minX, y: box.maxY)]
            .map(sourceCanvasPoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    /// The tag's centre: just above the top of the head (about a quarter box over Vision's top edge), kept inside the view.
    private func tagCenter(_ vision: CGRect) -> CGPoint {
        let top = sourceCanvasPoint(MaskPoint(x: vision.midX, y: vision.maxY + vision.height * 0.28))
        let r = Self.tagRadius + 4
        return CGPoint(x: min(max(top.x, bounds.minX + r), bounds.maxX - r), y: min(max(top.y - r, bounds.minY + r), bounds.maxY - r))
    }
    /// The face under `point`, on its tag or its box; the smaller box wins where two overlap.
    func faceTag(at point: CGPoint) -> PortraitFace? {
        guard let model, showsFaceTags(model) else { return nil }
        let placed = model.portraitFaces.map { ($0, faceFrame($0.box)) }
        if let hit = placed.first(where: { let c = tagCenter($0.0.box); return hypot(c.x - point.x, c.y - point.y) <= Self.tagRadius + 3 }) { return hit.0 }
        return placed.filter { $0.1.contains(point) }.min { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
    /// A face's outline: `color` over a dark edge, so it reads on any picture.
    func strokeFaceOutline(_ frame: CGRect, color: NSColor, width: Double) {
        let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.5).setStroke(); outline.lineWidth = width + 2; outline.stroke()
        color.setStroke(); outline.lineWidth = width; outline.stroke()
    }
    /// The face pointed at in the panel's rows, outlined wherever Portrait is.
    func drawHoveredFace(model: EditorModel) {
        guard let id = model.hoveredFaceID, let face = model.portraitFaces.first(where: { $0.id == id }) else { return }
        strokeFaceOutline(faceFrame(face.box), color: Theme.nsAccent, width: 2)
    }
    func drawFaceTags(model: EditorModel) {
        let hovered = pointerPosition.flatMap(faceTag(at:))
        for face in model.portraitFaces {
            let frame = faceFrame(face.box), chosen = model.chosenFaceIDs.contains(face.id)
            if face.id == hovered?.id {
                strokeFaceOutline(frame, color: .white, width: 1.5)
            }
            let c = tagCenter(face.box), r = Self.tagRadius
            let circle = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            NSShadow().then { $0.shadowColor = NSColor.black.withAlphaComponent(0.5); $0.shadowBlurRadius = 3 }.set()
            if chosen {
                Theme.nsAccent.setFill(); circle.fill()
                NSShadow().set()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: c.x - r * 0.42, y: c.y)); check.line(to: CGPoint(x: c.x - r * 0.1, y: c.y + r * 0.32)); check.line(to: CGPoint(x: c.x + r * 0.45, y: c.y - r * 0.3))
                check.lineWidth = 2; check.lineCapStyle = .round; check.lineJoinStyle = .round
                AccentChoice.current.nsOnColor.setStroke(); check.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.35).setFill(); circle.fill()
                NSShadow().set()
            }
            NSColor.white.setStroke(); circle.lineWidth = 1.5; circle.stroke()
        }
    }
}

private extension NSShadow {
    func then(_ body: (NSShadow) -> Void) -> NSShadow { body(self); return self }
}

/// Remove Spots on the photo: each selected person's face is framed, with Find blemishes under it for that face and,
/// once it has spots, Clear beside it to take them off.
extension ImageCanvas {
    private static let findTitle = L10n.tr("Find blemishes"), clearTitle = L10n.tr("Clear")
    enum SpotFrameAction { case find, clear }
    func showsSpotFrames(_ model: EditorModel) -> Bool {
        model.editsFaceSpots && !model.comparing && !model.busy && BlemishDetector.modelURL != nil
    }
    private func spotFaces(_ model: EditorModel) -> [PortraitFace] {
        model.portraitFaces.filter { model.chosenFaceIDs.contains($0.id) }
    }
    /// The buttons under a face's frame, centred together, or inside its bottom edge when the view ends there; Clear
    /// only when the face has spots.
    private func spotButtons(for face: PortraitFace, model: EditorModel) -> (find: CGRect, clear: CGRect?) {
        let frame = faceFrame(face.box), height = Self.canvasButtonHeight
        let findWidth = Self.canvasButtonWidth(Self.findTitle)
        let clearWidth = model.hasFaceSpots(on: face.box) ? Self.canvasButtonWidth(Self.clearTitle) : nil
        let total = findWidth + (clearWidth.map { $0 + 6 } ?? 0)
        var y = frame.maxY + 6
        if y + height > bounds.maxY - 4 { y = frame.maxY - height - 6 }
        let find = CGRect(x: frame.midX - total / 2, y: y, width: findWidth, height: height)
        return (find, clearWidth.map { CGRect(x: find.maxX + 6, y: y, width: $0, height: height) })
    }
    /// The face and the button under `point`.
    func spotFrameButton(at point: CGPoint) -> (face: PortraitFace, action: SpotFrameAction)? {
        guard let model, showsSpotFrames(model) else { return nil }
        for face in spotFaces(model) {
            let buttons = spotButtons(for: face, model: model)
            if buttons.find.contains(point) { return (face, .find) }
            if buttons.clear?.contains(point) == true { return (face, .clear) }
        }
        return nil
    }
    func drawSpotFrames(model: EditorModel) {
        for face in spotFaces(model) {
            let frame = faceFrame(face.box)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
            outline.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.45).setStroke(); outline.lineWidth = 2.5; outline.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke(); outline.lineWidth = 1; outline.stroke()
            let buttons = spotButtons(for: face, model: model)
            drawCanvasButton(Self.findTitle, in: buttons.find)
            if let clear = buttons.clear { drawCanvasButton(Self.clearTitle, in: clear) }
        }
    }
}
