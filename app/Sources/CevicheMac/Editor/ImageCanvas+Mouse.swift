import AppKit
import SwiftUI
import CevicheCore

/// Pinch, click and drag on the photo, for whichever tool is up.
extension ImageCanvas {
    override func magnify(with event: NSEvent) {
        updateGeometry()
        model?.magnifyImage(by: event.magnification, anchor: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func smartMagnify(with event: NSEvent) {
        updateGeometry()
        model?.toggleImageFit(anchor: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard model?.peekingOriginal != true else { return }
        window?.makeFirstResponder(self)
        updateGeometry()
        let point = convert(event.locationInWindow, from: nil)
        if model?.spaceHeld == true {
            spacePanning = true; lastDrag = point; NSCursor.closedHand.set(); return
        }
        if let model, model.comparing, abs(point.x - bounds.width * model.comparisonSplit) <= 12 {
            if event.clickCount == 2 { model.setComparisonSplit(0.5) }
            else { draggingSplit = true; NSCursor.resizeLeftRight.set() }
            needsDisplay = true; return
        }
        if let model, model.eyedropper != nil {
            if let p = maskPoint(point, clamp: false) { model.pickColor(at: p) }
            window?.invalidateCursorRects(for: self); needsDisplay = true; return
        }
        if let model, model.targetedMixer != nil, !model.busy {
            if let p = maskPoint(point, clamp: false) { model.beginMixerDrag(at: p); mixerDragOrigin = point.x }
            needsDisplay = true; return
        }
        if let model, model.toolTab == .crop, !model.comparing, !model.busy, !model.cropPlacingCorners,
           model.cropStraightening || event.modifierFlags.contains(.command), maskPoint(point, clamp: false) != nil {
            model.cropStraightening = true; rulerDraft = (point, point); pointerPosition = point; needsDisplay = true; return
        }
        if let model, !model.comparing, !model.busy, !event.modifierFlags.contains(.command) {
            // Touch Up: a click on a face part opens its controls; elsewhere it does nothing.
            if showsFaceParts(model) {
                if let hit = facePart(at: point) { openFacePart(hit, model: model) }
                needsDisplay = true; return
            }
            // People on the photo: a click on a face or its tag ticks or unticks it.
            if let face = faceTag(at: point) {
                // The selected person again goes back to Everyone.
                model.selectedFaceID = model.selectedFaceID == face.id ? nil : face.id
                needsDisplay = true; return
            }
            // Framings on the photo: a click takes the one under the pointer.
            if model.toolTab == .face, model.showingFramings {
                // A picked framing waits for Apply or Dismiss; a click on another frame picks that one.
                if let picked = model.pickedFraming, let buttons = framingButtons(for: picked) {
                    if buttons.apply.contains(point) { model.applyFraming(picked); needsDisplay = true; return }
                    if buttons.dismiss.contains(point) { model.pickedFraming = nil; needsDisplay = true; return }
                }
                if let framing = framingAt(point) { model.pickedFraming = framing }
                needsDisplay = true; return
            }
            if model.placingFaceRegion {
                // In a group picture a click on someone else's face, outside the region being reshaped, picks them.
                if model.isGroupPortrait, let p = maskPoint(point, clamp: false), !(model.currentFaceRegion?.contains(CGPoint(x: p.x, y: p.y)) ?? false),
                   let face = model.portraitFaces.first(where: { $0.box.contains(CGPoint(x: p.x, y: p.y)) }), face.id != model.reshapeFace?.id {
                    model.faceRegion = nil; model.selectedFaceID = face.id
                    needsDisplay = true; return
                }
                beginFaceRegion(at: point, model: model, clickCount: event.clickCount); needsDisplay = true; return
            }
            if model.picksObject {
                // Object: what is under the click is removed; a click a few points off a wire still finds it.
                if let p = maskPoint(point, clamp: false) { model.removeObject(at: p, tolerance: objectTolerance(at: point, p), modifier: ObjectModifier(event.modifierFlags)) }
                needsDisplay = true; return
            }
            if model.selectsRetouch {
                // Select: a pin is clicked into the selection (Shift adds or takes out); anywhere else a box is drawn
                // over the pins, starting from nothing unless Shift keeps what is selected. Nothing moves or pans.
                let shift = event.modifierFlags.contains(.shift)
                if let (stroke, _) = retouchHit(at: point) {
                    if shift { model.toggleRetouchSelection(stroke.id) }
                    else { model.selectedRetouchIDs = [stroke.id]; model.selectedRetouchID = stroke.id }
                } else {
                    if !shift { model.selectedRetouchIDs = [] }
                    handleMarquee = (point, point, model.selectedRetouchIDs)
                }
                needsDisplay = true; return
            }
            // Find blemishes under a face's frame searches that face.
            if let (face, action) = spotFrameButton(at: point) {
                switch action {
                case .find: if let url = BlemishDetector.modelURL { model.findBlemishes(url, faces: [face.box]) }
                case .clear: model.removeFaceSpots(on: face.box)
                }
                needsDisplay = true; return
            }
            if model.editsFaceSpots {
                // Spots only: a pin or a selected spot's outline is taken hold of to move; Shift-click adds to the
                // selection or takes out; a drag on bare skin boxes several (Shift keeps what is selected), and a
                // click there adds a spot.
                let shift = event.modifierFlags.contains(.shift)
                if !event.modifierFlags.contains(.option), let (stroke, _) = retouchHit(at: point) {
                    if shift { model.toggleRetouchSelection(stroke.id) }
                    else if let p = maskPoint(point, clamp: true) {
                        if !model.selectedRetouchIDs.contains(stroke.id) { model.selectedRetouchIDs = [stroke.id] }
                        model.selectedRetouchID = stroke.id; model.beginGesture()
                        retouchDrag = (stroke.id, .target, stroke, p); NSCursor.closedHand.set()
                    }
                } else {
                    handleMarquee = (point, point, shift ? model.selectedRetouchIDs : [])
                    if !shift, maskPoint(point, clamp: false) != nil { faceSpotAddPoint = point }
                }
                needsDisplay = true; return
            }
            if model.paintsRetouch {
                // Option-drag boxes pins. Shift-click on another stroke's pin takes it into the selection or out of it,
                // elsewhere it carries the selected stroke on in a straight line; otherwise a pin or the selected stroke's
                // outline is taken hold of, and anywhere else on the photo paints a new stroke.
                let shift = event.modifierFlags.contains(.shift)
                if event.modifierFlags.contains(.option) {
                    handleMarquee = (point, point, shift ? model.selectedRetouchIDs : [])
                } else if shift, let (stroke, _) = retouchHit(at: point), stroke.id != model.selectedRetouchID {
                    model.toggleRetouchSelection(stroke.id)
                } else if shift, let p = maskPoint(point, clamp: true), model.extendRetouch(to: p) {
                    drawingRetouch = true; extendingRetouch = true
                } else if let (stroke, part) = retouchHit(at: point), let p = maskPoint(point, clamp: true) {
                    model.selectRetouch(stroke.id); model.beginGesture()
                    retouchDrag = (stroke.id, part, stroke, p); NSCursor.closedHand.set()
                } else if let p = maskPoint(point, clamp: false) { model.startRetouch(p); drawingRetouch = true }
                needsDisplay = true; return
            }
            if model.reviewingDust {
                let adding = event.modifierFlags.contains(.shift)
                if let (spot, edge) = dustHit(at: point) {
                    // Shift-click adds a spot to the selection or takes it out; a plain click picks it alone, to drag.
                    if adding {
                        model.toggleRetouchSelection(spot.id)
                    } else {
                        model.selectedRetouchID = spot.id
                        if let stroke = model.adjustments.retouch.first(where: { $0.id == spot.id && $0.suggested }) {
                            // A healed spot's stroke is part of the edit: the whole drag is one undo step.
                            model.beginGesture(); healedDustDrag = stroke
                        }
                        if edge { dustDrag = .resize(spot.id) } else if let p = maskPoint(point, clamp: true) { dustDrag = .move(spot.id, center: spot.center, from: p) }
                    }
                } else {
                    if maskPoint(point, clamp: false) != nil, !model.dustWorking, !adding { dustAddPoint = point }
                    handleMarquee = (point, point, adding ? model.selectedRetouchIDs : [])
                }
                needsDisplay = true; return
            }
            if model.toolTab == .crop, model.cropPlacingCorners {
                // The nearest corner within reach is taken hold of.
                let corners = model.adjustments.geometry.perspective?.corners ?? []
                let reach = corners.map { hypot(point.x - sourceCanvasPoint($0).x, point.y - sourceCanvasPoint($0).y) }
                if let index = reach.indices.min(by: { reach[$0] < reach[$1] }), reach[index] <= 18 {
                    model.guideMessage = nil; model.cornerDraft = corners; cornerDrag = index; pointerPosition = point
                }
                needsDisplay = true; return
            }
            if model.toolTab == .crop, let image {
                if model.cropDrawingGuide {
                    model.guideMessage = nil
                    for guide in model.adjustments.geometry.guides {
                        let a = sourceCanvasPoint(guide.start), b = sourceCanvasPoint(guide.end)
                        if min(hypot(point.x - a.x, point.y - a.y), hypot(point.x - b.x, point.y - b.y)) <= 12 {
                            model.selectedGuideID = guide.id; model.guideDraft = guide
                            movingGuideStart = hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
                            guideDragOrigin = point; needsDisplay = true; return
                        }
                        if Self.distance(from: point, toSegment: a, b) <= 6 { model.selectedGuideID = guide.id; needsDisplay = true; return }
                    }
                    guard model.adjustments.geometry.guides.count < 4 else {
                        model.guideMessage = L10n.tr("Four guides are already placed. Move an endpoint or delete a guide."); return
                    }
                    if let p = maskPoint(point, clamp: false) {
                        model.guideDraft = UprightGuide(axis: model.sourceGuideAxis, start: p, end: p)
                        movingGuideStart = false; guideDragOrigin = point
                    }
                } else if let p = displayPoint(point, clamp: true) {
                    cropOriginal = model.adjustments.geometry.crop
                    let frame = cropFrame(cropOriginal, in: photoRect(model, image))
                    cropHandle = nil; cropPointer = nil; cropMoving = nil; cropRotation = nil; cropTurn = nil
                    switch Self.cropZone(at: point, frame: frame) {
                    case .corner(let corner): cropHandle = .corner(corner)
                    case .edge(let edge): cropHandle = .edge(edge)
                    case .move: cropMoving = point; NSCursor.closedHand.set()
                    case .rotate:
                        cropRotation = (atan2(point.y - frame.midY, point.x - frame.midX), model.adjustments.geometry.straighten)
                        if let size = canvasPlan?.fullSize, size.width > 0 {
                            let rect = photoRect(model, image), crop = cropOriginal
                            cropTurn = (frame, rect.width / size.width,
                                        CGSize(width: (crop.x + crop.width / 2 - 0.5) * size.width, height: (0.5 - crop.y - crop.height / 2) * size.height))
                        }
                    case nil:
                        // Away from the frame a double-click toggles the zoom and a drag pans a zoomed view.
                        if event.clickCount == 2 { model.toggleImageFit(anchor: point) }
                        else if !model.viewport.isFitted { lastDrag = point; NSCursor.closedHand.set() }
                        needsDisplay = true; return
                    }
                    cropStart = p; cropReached = nil
                    model.beginGesture()
                }
                needsDisplay = true; return
            }
        }
        if let model, model.toolTab == .masks, !model.comparing, !model.busy, !event.modifierFlags.contains(.command), !model.awaitingGradient,
           model.maskTool == nil || model.maskTool == .linear || model.maskTool == .radial,
           let mask = model.editableSelection, mask.kind == .linear || mask.kind == .radial {
            func grab(_ handle: GradientHandle) {
                gradientHandle = handle; gradientOriginal = (mask.start, mask.end, mask.rotation ?? 0); gradientDragOrigin = maskPoint(point, clamp: true)
                model.beginGesture()
            }
            if mask.kind == .radial {
                let knob = radialKnob(mask).knob
                if hypot(knob.x - point.x, knob.y - point.y) <= 10 { grab(.rotate); return }
            }
            for (handle, p) in gradientHandles(mask) {
                let q = sourceCanvasPoint(p)
                if hypot(q.x - point.x, q.y - point.y) <= 10 { grab(handle); return }
            }
            // As in other RAW editors: inside the ellipse drags it, its outline or the knob turns it, and a drag anywhere
            // else does nothing (Redraw in the panel, or Add mask, is how a new line gets drawn).
            if mask.kind == .radial, let p = maskPoint(point, clamp: true) {
                if radialRotateHit(point, mask) { grab(.rotate); return }
                if radialGeometry(mask).normalizedRadius(p) < 1 { grab(.move); return }
            }
            if (model.maskTool == .linear || model.maskTool == .radial) && !model.redrawGradient { return }
        }
        if let model, model.toolTab == .masks, model.maskTool != nil, !model.comparing, !event.modifierFlags.contains(.command), !model.busy {
            if let normalized = maskPoint(point, clamp: false) {
                model.beginMask(at: normalized, erase: event.modifierFlags.contains(.option))
                drawingMask = model.maskTool == .brush || model.maskTool == .linear || model.maskTool == .radial
            }
            return
        }
        if event.clickCount == 2 { model?.toggleImageFit(anchor: point); lastDrag = nil; needsDisplay = true; return }
        if model?.viewport.isFitted == false { lastDrag = point; NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerPosition = point
        if spacePanning {
            if let previous = lastDrag, model?.spaceHeld == true {
                model?.spaceDragged = true
                model?.panImage(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
            }
            lastDrag = point; needsDisplay = true; return
        }
        if faceRegionDrag != nil, let model { dragFaceRegion(to: point, model: model); needsDisplay = true; return }
        if drawingRetouch { if let p = maskPoint(point, clamp: true) { model?.dragRetouch(p) }; needsDisplay = true; return }
        if let drag = retouchDrag, let p = maskPoint(point, clamp: true) {
            let dx = p.x - drag.from.x, dy = p.y - drag.from.y
            func moved(_ q: MaskPoint) -> MaskPoint { MaskPoint(x: min(1, max(0, q.x + dx)), y: min(1, max(0, q.y + dy))) }
            model?.updateRetouch(drag.id) { stroke in
                switch drag.part {
                case .target: stroke.points = drag.original.points.map(moved)
                case .source: stroke.source = moved(drag.original.source)
                }
            }
            needsDisplay = true; return
        }
        if let drag = dustDrag, let model, let info = model.info, let p = maskPoint(point, clamp: true) {
            switch drag {
            case .move(let id, let center, let from): model.updateDustSpot(id, center: MaskPoint(x: center.x + p.x - from.x, y: center.y + p.y - from.y))
            case .resize(let id):
                if let spot = (model.dustSpots + model.healedDustHandles).first(where: { $0.id == id }) {
                    let dx = (p.x - spot.center.x) * Double(info.width), dy = (p.y - spot.center.y) * Double(info.height)
                    model.updateDustSpot(id, radius: hypot(dx, dy) / Double(min(info.width, info.height)))
                }
            }
            needsDisplay = true; return
        }
        if let marquee = handleMarquee, let model {
            if hypot(point.x - marquee.start.x, point.y - marquee.start.y) > 3 { dustAddPoint = nil; faceSpotAddPoint = nil }
            if dustAddPoint == nil, faceSpotAddPoint == nil {
                handleMarquee?.end = point
                model.selectedRetouchIDs = marquee.base.union(retouchHandles(in: CGRect(x: min(marquee.start.x, point.x), y: min(marquee.start.y, point.y),
                                                                               width: abs(point.x - marquee.start.x), height: abs(point.y - marquee.start.y))))
            }
            needsDisplay = true; return
        }
        if let origin = mixerDragOrigin { model?.updateMixerDrag(points: point.x - origin); needsDisplay = true; return }
        if let start = rulerDraft?.start { rulerDraft = (start, point); needsDisplay = true; return }
        if let index = cornerDrag, let model {
            if let p = maskPoint(point, clamp: true), model.cornerDraft?.indices.contains(index) == true { model.cornerDraft?[index] = p }
            pointerPosition = point; needsDisplay = true; return
        }
        if let model, model.guideDraft != nil {
            if let p = maskPoint(point, clamp: true) {
                if movingGuideStart { model.guideDraft?.start = p } else { model.guideDraft?.end = p }
                if let draft = model.guideDraft, let info = model.info {
                    // Infer direction in source pixels, so rotation and flips cannot swap the stored constraint.
                    let dx = (draft.end.x - draft.start.x) * Double(info.width), dy = (draft.end.y - draft.start.y) * Double(info.height)
                    model.guideDraft?.axis = abs(dy) > abs(dx) ? .vertical : .horizontal
                }
            }
            needsDisplay = true; return
        }
        if let rotation = cropRotation, let model, let image {
            let rect = model.viewport.imageRect(image: CGSize(width: image.width, height: image.height), canvas: bounds.size)
            let frame = cropTurn?.frame ?? cropFrame(cropOriginal, in: rect), center = CGPoint(x: frame.midX, y: frame.midY)
            let start = CGPoint(x: center.x + cos(rotation.angle), y: center.y + sin(rotation.angle))
            let mirrored = model.adjustments.geometry.flipHorizontal != model.adjustments.geometry.flipVertical
            let degrees = rotation.straighten + Self.straightenDelta(start: start, current: point, center: center, mirrored: mirrored)
            model.turnPhoto(straighten: min(45, max(-45, (degrees * 10).rounded() / 10)))
            needsDisplay = true; return
        }
        if cropStart != nil, let p = displayPoint(point, clamp: true), let model {
            if let start = cropMoving, let image {
                // The frame follows the pointer over the photo; Shift keeps it to the axis it has moved along most.
                let rect = photoRect(model, image)
                guard rect.width > 0, rect.height > 0 else { return }
                var dx = (point.x - start.x) / rect.width, dy = -(point.y - start.y) / rect.height
                if event.modifierFlags.contains(.shift) { if abs(dx * rect.width) >= abs(dy * rect.height) { dy = 0 } else { dx = 0 } }
                let original = cropOriginal
                func moved(_ offset: CGPoint) -> CropRect? {
                    var crop = original
                    crop.x = min(1 - crop.width, max(0, crop.x + offset.x)); crop.y = min(1 - crop.height, max(0, crop.y + offset.y))
                    return crop
                }
                // Against the edge of a turned photo the frame stops on it and slides along it.
                if let hit = Self.reach(from: cropReached ?? .zero, to: CGPoint(x: dx, y: dy), frame: moved, fits: model.cropFitsImage) {
                    cropReached = hit.point; model.edit { $0.geometry.crop = hit.crop }
                }
            } else { cropPointer = p; resizeCrop(to: p, modifiers: event.modifierFlags) }
            needsDisplay = true; return
        }
        if let handle = gradientHandle, let p = maskPoint(point, clamp: true), let model, let original = gradientOriginal, let origin = gradientDragOrigin {
            let shift = event.modifierFlags.contains(.shift)
            switch handle {
            case .start: let q = shift ? p.constrainedToCardinal(from: original.end) : p; model.updateSelection { $0.start = q }
            case .end: let q = shift ? p.constrainedToCardinal(from: original.start) : p; model.updateSelection { $0.end = q }
            case .move:
                let dx = p.x - origin.x, dy = p.y - origin.y
                model.updateSelection { $0.start = MaskPoint(x: original.start.x + dx, y: original.start.y + dy); $0.end = MaskPoint(x: original.end.x + dx, y: original.end.y + dy) }
            case .axis(let x, _):
                // One axis of the ellipse, measured on its own (rotated) axes; the center stays. Shift makes it a circle.
                let g = RadialGeometry(start: original.start, end: original.end, rotation: original.rotation, aspect: sourceAspect), l = g.local(p)
                var nx = x ? max(0.002, abs(l.x)) : g.rx, ny = x ? g.ry : max(0.002, abs(l.y))
                if shift { nx = max(nx, ny); ny = nx }
                let corners = g.corners(rx: nx, ry: ny)
                model.updateSelection { $0.start = corners.start; $0.end = corners.end }
            case .feather:
                // The inner ring sits where the feather begins: from the edge (0) to half way in (0.25).
                let g = RadialGeometry(start: original.start, end: original.end, rotation: original.rotation, aspect: sourceAspect)
                model.updateSelection { $0.feather = (1 - min(1, max(0.5, g.normalizedRadius(p)))) / 2 }
            case .rotate:
                // Turn with the pointer around the center; Shift snaps to 15° steps.
                let g = RadialGeometry(start: original.start, end: original.end, rotation: original.rotation, aspect: sourceAspect)
                let from = g.bearing(origin), to = g.bearing(p)
                var degrees = original.rotation + (to - from) * 180 / .pi
                degrees -= (degrees / 360).rounded(.towardZero) * 360
                if shift { degrees = (degrees / 15).rounded() * 15 }
                model.updateSelection { $0.rotation = degrees == 0 ? nil : degrees }
            }
            needsDisplay = true; return
        }
        if drawingMask { if let p = maskPoint(point, clamp: true) { model?.dragMask(to: p, shift: event.modifierFlags.contains(.shift)) }; needsDisplay = true; return }
        if draggingSplit { model?.setComparisonSplit(point.x / max(1, bounds.width)); needsDisplay = true; return }
        guard let previous = lastDrag else { return }
        model?.panImage(by: CGSize(width: point.x - previous.x, height: point.y - previous.y))
        lastDrag = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if spacePanning { spacePanning = false; lastDrag = nil; window?.invalidateCursorRects(for: self); return }
        if let drag = faceRegionDrag {
            if case .liquify = drag { model?.endGesture() } else { model?.finishFaceRegion() }
            faceRegionDrag = nil; needsDisplay = true
            if let model { faceRegionCursor(at: convert(event.locationInWindow, from: nil), model: model).set() }
            return
        }
        if drawingRetouch { model?.endRetouch(extended: extendingRetouch); drawingRetouch = false; extendingRetouch = false }
        if let drag = retouchDrag, let model {
            model.endGesture(); retouchDrag = nil
            // Remove has no source of its own to keep, so a moved stroke takes a new one.
            if let stroke = model.selectedRetouch, stroke.mode == .remove, stroke.points != drag.original.points { model.chooseRetouchSource(stroke.id) }
        }
        if let original = healedDustDrag, let model {
            model.endGesture(); healedDustDrag = nil
            // The old source may now overlap the spot or no longer match its tone.
            if let stroke = model.adjustments.retouch.first(where: { $0.id == original.id }), stroke.points != original.points || stroke.radius != original.radius {
                model.chooseRetouchSource(original.id)
            }
        }
        dustDrag = nil; handleMarquee = nil
        if let start = dustAddPoint { dustAddPoint = nil; if let p = maskPoint(start, clamp: false) { model?.addDustSpot(at: p) } }
        if let start = faceSpotAddPoint { faceSpotAddPoint = nil; if let p = maskPoint(start, clamp: false) { model?.addFaceSpot(p) } }
        if let ruler = rulerDraft { if model?.cropStraightening == true { model?.straightenAlong(from: ruler.start, to: ruler.end) }; rulerDraft = nil }
        if cornerDrag != nil { cornerDrag = nil; model?.acceptCorners() }
        if model?.guideDraft != nil {
            let point = convert(event.locationInWindow, from: nil)
            if let origin = guideDragOrigin, hypot(point.x - origin.x, point.y - origin.y) >= 2 { model?.acceptGuide() }
            else { model?.guideDraft = nil }
            guideDragOrigin = nil
        }
        if cropStart != nil {
            if cropRotation != nil { model?.finishTurningPhoto() }
            // Letting go keeps the photo where the turn left it rather than refitting the larger turned canvas.
            // Sized for the turned photo (whose preview may still be rendering), so it lands exactly once it arrives.
            if let turn = cropTurn, let model, let size = model.geometryPlan?.fullSize, size.width > 0 {
                cropTurn = nil
                let crop = model.adjustments.geometry.crop, w = size.width * turn.pointsPerPixel, h = size.height * turn.pointsPerPixel
                // Placed by the crop as it ends (Constrain Crop may have refitted it), centered where the frame was.
                let rect = CGRect(x: turn.frame.midX - (crop.x + crop.width / 2) * w, y: turn.frame.midY - (1 - crop.y - crop.height / 2) * h, width: w, height: h)
                model.viewport.show(at: rect, image: size, canvas: bounds.size)
            }
            model?.endGesture(); cropStart = nil; cropHandle = nil; cropPointer = nil; cropMoving = nil; cropRotation = nil; cropReached = nil
            updateGeometry()
            updateCropCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
        }
        if let pending = pendingPreview { setPreview(pending.0, geometry: pending.1); updateGeometry() }
        if mixerDragOrigin != nil { model?.endMixerDrag(); mixerDragOrigin = nil }
        needsDisplay = true; if gradientHandle != nil { model?.endGesture(); gradientHandle = nil; gradientOriginal = nil; gradientDragOrigin = nil }; if drawingMask { model?.endMask(); drawingMask = false }; lastDrag = nil; draggingSplit = false; window?.invalidateCursorRects(for: self) }
}
