import AppKit
import CevicheCore

/// Portrait › Framing on the photo: each framing's outline on the whole frame; the one under the pointer is lit and
/// everything outside it tinted, as it would crop. A click picks one, which stays lit with Dismiss and Apply below it.
extension ImageCanvas {
    /// The framing under `point`: the smallest frame holding it, since they nest around the face.
    func framingAt(_ point: CGPoint) -> FramingCandidate? {
        guard let model, let image else { return nil }
        let rect = photoRect(model, image)
        return model.framingFrames.filter { cropFrame($0.crop, in: rect).contains(point) }
            .min { $0.crop.width * $0.crop.height < $1.crop.width * $1.crop.height }
    }
    /// Dismiss and Apply under a picked framing's bottom right, kept on screen.
    func framingButtons(for candidate: FramingCandidate) -> (dismiss: CGRect, apply: CGRect)? {
        guard let model, let image else { return nil }
        let frame = cropFrame(candidate.crop, in: photoRect(model, image))
        let height = Self.canvasButtonHeight, applyWidth = Self.canvasButtonWidth(L10n.tr("Apply")), dismissWidth = Self.canvasButtonWidth(L10n.tr("Dismiss"))
        // Rows run downward on this canvas: below the frame, or inside its bottom edge when there is no room.
        var y = frame.maxY + 8
        if y + height > bounds.maxY - 4 { y = frame.maxY - height - 8 }
        let right = min(frame.maxX, bounds.maxX - 8)
        let apply = CGRect(x: right - applyWidth, y: y, width: applyWidth, height: height)
        return (CGRect(x: apply.minX - 6 - dismissWidth, y: y, width: dismissWidth, height: height), apply)
    }
    func drawFramings(in rect: CGRect, model: EditorModel) {
        let lit = model.pickedFraming ?? pointerPosition.flatMap(framingAt)
        if let lit {
            let frame = cropFrame(lit.crop, in: rect)
            let shade = NSBezierPath(rect: rect); shade.append(NSBezierPath(rect: frame)); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill(); shade.fill()
        }
        for candidate in model.framingFrames {
            let frame = cropFrame(candidate.crop, in: rect), on = candidate.id == lit?.id
            let outline = NSBezierPath(rect: frame)
            NSColor.black.withAlphaComponent(0.4).setStroke(); outline.lineWidth = on ? 3.5 : 2.5; outline.stroke()
            (on ? NSColor.white : NSColor.white.withAlphaComponent(0.6)).setStroke(); outline.lineWidth = on ? 1.5 : 1
            if !on { outline.setLineDash([5, 4], count: 2, phase: 0) }
            outline.stroke()
            drawLabel(candidate.framing.localizedTitle, near: CGPoint(x: frame.minX + 4, y: frame.minY + 4))
        }
        if let picked = model.pickedFraming, let buttons = framingButtons(for: picked) {
            drawCanvasButton(L10n.tr("Dismiss"), in: buttons.dismiss)
            drawCanvasButton(L10n.tr("Apply"), in: buttons.apply, prominent: true)
        }
    }
}
