import AppKit
import SwiftUI
import CevicheCore

/// Guides, the straighten line and the loupes drawn over the photo.
extension ImageCanvas {
    func drawGeometryTools(in rect: CGRect, model: EditorModel) {
        let plan = canvasPlan
        func sourcePoint(_ p: MaskPoint) -> CGPoint { canvasPoint(plan?.displayPoint(p) ?? p) }
        if model.toolTab == .crop, !model.cropDrawingGuide, !model.cropPlacingCorners {
            let crop = model.adjustments.geometry.crop
            // While a corner turns the photo the frame holds still where the turn began.
            let frame = cropTurn?.frame ?? CGRect(x: rect.minX + crop.x * rect.width, y: rect.minY + (1 - crop.y - crop.height) * rect.height, width: crop.width * rect.width, height: crop.height * rect.height)
            let shade = NSBezierPath(rect: rect); shade.append(NSBezierPath(rect: frame)); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill(); shade.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke(); NSBezierPath(rect: frame).stroke()
            let forcedGrid = cropRotation != nil || rulerDraft != nil || model.volumeAdjusting
            let showOverlay = forcedGrid || model.cropOverlayVisibility == .always || model.cropOverlayVisibility == .auto && (pointerPosition != nil || cropStart != nil)
            if showOverlay {
                let grid = NSBezierPath()
                let overlay: CropOverlay = forcedGrid ? .grid : model.cropOverlay
                for line in overlay.lines(in: frame, orientation: model.cropOverlayOrientation) {
                    if let first = line.first { grid.move(to: first); for point in line.dropFirst() { grid.line(to: point) } }
                }
                NSColor.white.withAlphaComponent(0.35).setStroke(); grid.stroke()
            }
            drawCropHandles(frame: frame, active: activeCropZone(frame: frame))
            if cropRotation != nil, let pointerPosition {
                drawLabel(String(format: "%+.1f°", model.adjustments.geometry.straighten), near: pointerPosition)
            }
            if let ruler = rulerDraft, model.cropStraightening {
                let line = NSBezierPath(); line.move(to: ruler.start); line.line(to: ruler.end)
                NSColor.black.setStroke(); line.lineWidth = 3.5; line.stroke()
                NSColor.systemYellow.setStroke(); line.lineWidth = 1.5; line.stroke()
                drawLabel(String(format: "%+.2f°", EditorModel.rulerCorrection(from: ruler.start, to: ruler.end)), near: ruler.end)
            }

        }
        if model.toolTab == .crop, model.cropPlacingCorners, let corners = model.cornerDraft ?? model.adjustments.geometry.perspective?.corners, corners.count == 4 {
            let points = corners.map(sourcePoint)
            // Drawn around their centre, so the outline is the quadrilateral whichever corner is which.
            let centre = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
            let around = points.sorted { atan2($0.y - centre.y, $0.x - centre.x) < atan2($1.y - centre.y, $1.x - centre.x) }
            let outline = NSBezierPath(); outline.move(to: around[0]); around.dropFirst().forEach(outline.line(to:)); outline.close()
            let shade = NSBezierPath(rect: rect); shade.append(outline); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
            let valid = PerspectiveCrop(corners: corners).isValid
            NSColor.black.withAlphaComponent(0.65).setStroke(); outline.lineWidth = 3.5; outline.stroke()
            (valid ? NSColor.white : NSColor.systemOrange).setStroke(); outline.lineWidth = 1.5; outline.stroke()
            for (index, p) in points.enumerated() {
                let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                (index == cornerDrag ? NSColor.controlAccentColor : NSColor.white).setFill(); dot.fill()
                NSColor.black.withAlphaComponent(0.5).setStroke(); dot.lineWidth = 1; dot.stroke()
            }
            if let index = cornerDrag { drawGeometryLoupe(at: points[index]) }
        }
        if model.toolTab == .crop, model.cropDrawingGuide {
            if model.showGuideGrid {
                let grid = NSBezierPath()
                for line in CropOverlay.grid.lines(in: rect, orientation: 0) {
                    if let first = line.first { grid.move(to: first); for point in line.dropFirst() { grid.line(to: point) } }
                }
                NSColor.white.withAlphaComponent(0.35).setStroke(); grid.stroke()
            }
            do {
                let guides = model.adjustments.geometry.guides.filter { $0.id != model.guideDraft?.id } + (model.guideDraft.map { [$0] } ?? [])
                for (index, guide) in guides.enumerated() {
                    let a = sourcePoint(guide.start), b = sourcePoint(guide.end), line = NSBezierPath()
                    let color: NSColor = guide.id == model.selectedGuideID || guide.id == model.guideDraft?.id ? .systemYellow : .white
                    line.move(to: a); line.line(to: b); line.lineWidth = 3.5; NSColor.black.withAlphaComponent(0.65).setStroke(); line.stroke()
                    color.setStroke(); line.lineWidth = 1.5; line.stroke()
                    for p in [a, b] { color.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill() }
                    drawLabel(L10n.tr("\(index+1)"), near: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                }
                if model.showGuideLoupe, model.guideDraft != nil, let pointerPosition { drawGeometryLoupe(at: pointerPosition) }
            }
        }
        if let property = model.targetedMixer, let pointerPosition {
            // The band the drag is moving, and its value, follow the pointer.
            let bands = model.targetAdjustments.selectiveColors, band = min(model.selectiveColorBand, bands.count - 1)
            if mixerDragOrigin != nil, band >= 0 {
                let value = bands[band][keyPath: property.key]
                drawLabel(L10n.tr("\(L10n.key(SelectiveColor.names[band])) \(property.localizedTitle.lowercased()) ") + String(format: property == .hue ? "%+.0f°" : "%+.0f", value), near: pointerPosition)
            } else if maskPoint(pointerPosition, clamp: false) != nil {
                let q = pointerPosition, arrows = NSBezierPath()
                for sign in [-1.0, 1.0] {
                    arrows.move(to: CGPoint(x: q.x + sign * 14, y: q.y)); arrows.line(to: CGPoint(x: q.x + sign * 9, y: q.y - 4))
                    arrows.move(to: CGPoint(x: q.x + sign * 14, y: q.y)); arrows.line(to: CGPoint(x: q.x + sign * 9, y: q.y + 4))
                }
                NSColor.black.withAlphaComponent(0.6).setStroke(); arrows.lineWidth = 3; arrows.stroke()
                NSColor.white.setStroke(); arrows.lineWidth = 1; arrows.stroke()
            }
            return
        }
        if model.eyedropper != nil {
            if let pointerPosition {
                drawLoupe(at: pointerPosition, model: model)
                let q = pointerPosition, cross = NSBezierPath()
                cross.move(to: CGPoint(x: q.x - 8, y: q.y)); cross.line(to: CGPoint(x: q.x + 8, y: q.y)); cross.move(to: CGPoint(x: q.x, y: q.y - 8)); cross.line(to: CGPoint(x: q.x, y: q.y + 8))
                NSColor.black.withAlphaComponent(0.6).setStroke(); cross.lineWidth = 3; cross.stroke()
                NSColor.white.setStroke(); cross.lineWidth = 1; cross.stroke()
            }
            return
        }
        if model.toolTab == .masks, model.maskTool == .object { drawMaskObjectPreview(model: model) }
        if model.toolTab == .masks, model.maskTool == .brush, let pointerPosition {
            drawBrushCursor(at: pointerPosition, radius: model.brushRadius, softness: model.brushSoftness,
                            erase: model.brushErase || NSEvent.modifierFlags.contains(.option), model: model)
        }
        if model.placingFaceRegion {
            if let rect = model.currentFaceRegion { drawFaceRegion(rect) }
            return
        }
        if model.editsFaceSpots || model.selectsRetouch || model.picksObject {
            if showsSpotFrames(model) { drawSpotFrames(model: model) }
            drawRetouchOverlay(model: model)
            if model.picksObject { drawObjectPreview(model: model) }
            return
        }
        if model.paintsRetouch, let mode = model.retouchTool.mode {
            drawRetouchOverlay(model: model)
            // With Shift held, the line a click would add to the selected stroke.
            let last = NSEvent.modifierFlags.contains(.shift) && !drawingRetouch && retouchDrag == nil ? model.extendableRetouch?.points.last : nil
            let extending = last != nil
            if let last, let pointerPosition, maskPoint(pointerPosition, clamp: false) != nil {
                let line = NSBezierPath(); line.move(to: sourceCanvasPoint(last)); line.line(to: pointerPosition)
                NSColor.black.withAlphaComponent(0.5).setStroke(); line.lineWidth = 3; line.stroke()
                NSColor.white.setStroke(); line.lineWidth = 1; line.setLineDash([5, 4], count: 2, phase: 0); line.stroke()
            }
            // The brush shows its footprint wherever a click would paint.
            let boxing = handleMarquee != nil || !drawingRetouch && NSEvent.modifierFlags.contains(.option)
            if let pointerPosition, retouchDrag == nil, !boxing, drawingRetouch || extending || retouchHit(at: pointerPosition) == nil {
                drawBrushCursor(at: pointerPosition, radius: model.retouchRadius, softness: mode == .remove ? 0.3 : model.retouchSoftness, erase: false, model: model)
            }
        }
    }
    /// A small readout beside the pointer, kept inside the canvas.
    func drawLabel(_ text: String, near pointer: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: pointer.x + 16, y: pointer.y + 14)
        if origin.x + size.width + 12 > bounds.maxX { origin.x = pointer.x - size.width - 28 }
        if origin.y + size.height + 8 > bounds.maxY { origin.y = pointer.y - size.height - 22 }
        let bar = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: bar.minX + 6, y: bar.minY + 3), withAttributes: attributes)
    }

    /// A 4× loupe follows a guide endpoint without changing the canvas transform.
    private func drawGeometryLoupe(at pointer: CGPoint) {
        guard let image, let model else { return }
        let rect = model.viewport.imageRect(image: CGSize(width: image.width, height: image.height), canvas: bounds.size)
        let size = 128.0, magnification = 4.0
        let sx = Double(image.width) / rect.width, sy = Double(image.height) / rect.height
        let source = CGRect(x: (pointer.x - rect.minX - size / (2 * magnification)) * sx,
                            y: (pointer.y - rect.minY - size / (2 * magnification)) * sy, width: size / magnification * sx, height: size / magnification * sy)
        guard let crop = image.cropping(to: source) else { return }
        let x = pointer.x + size + 24 < bounds.maxX ? pointer.x + 24 : pointer.x - size - 24
        let y = min(bounds.maxY - size - 4, max(4, pointer.y - size - 24))
        let frame = CGRect(x: x, y: y, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).addClip()
        NSImage(cgImage: crop, size: frame.size).draw(in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: frame.midX - 12, y: frame.midY)); cross.line(to: CGPoint(x: frame.midX + 12, y: frame.midY))
        cross.move(to: CGPoint(x: frame.midX, y: frame.midY - 12)); cross.line(to: CGPoint(x: frame.midX, y: frame.midY + 12))
        NSColor.black.setStroke(); cross.lineWidth = 3; cross.stroke()
        NSColor.white.setStroke(); cross.lineWidth = 1; cross.stroke(); NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).stroke()
    }
    /// A magnified grid of the pixels under the pointer, so the picked pixel is unambiguous.
    private func drawLoupe(at pointer: CGPoint, model: EditorModel) {
        guard let image, maskPoint(pointer, clamp: false) != nil else { return }
        let rect = model.viewport.imageRect(image: CGSize(width: image.width, height: image.height), canvas: bounds.size)
        // Prefer the source-resolution tile when it covers the pointer.
        var source = image, frame = rect
        if let detail = model.detail, !detailPhotograph.isHidden, detailPhotograph.frame.contains(pointer) { source = detail.image; frame = detailPhotograph.frame }
        let px = Int((pointer.x - frame.minX) / frame.width * Double(source.width)), py = Int((pointer.y - frame.minY) / frame.height * Double(source.height))
        let cells = 11, half = cells / 2
        guard let crop = source.cropping(to: CGRect(x: px - half, y: py - half, width: cells, height: cells)), crop.width == cells, crop.height == cells,
              let center = source.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let size = 121.0, cell = size / Double(cells)
        var origin = CGPoint(x: pointer.x + 18, y: pointer.y - size - 18)
        if origin.x + size > bounds.maxX - 4 { origin.x = pointer.x - size - 18 }
        if origin.y < bounds.minY + 4 { origin.y = pointer.y + 18 }
        let loupe = CGRect(origin: origin, size: CGSize(width: size, height: size))
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8); clip.addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: loupe.size).draw(in: loupe, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        NSGraphicsContext.restoreGraphicsState()
        let target = CGRect(x: loupe.minX + Double(half) * cell, y: loupe.minY + Double(half) * cell, width: cell, height: cell)
        NSColor.black.setStroke(); NSBezierPath(rect: target.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke(); NSBezierPath(rect: target).stroke()
        NSColor.white.withAlphaComponent(0.85).setStroke(); let border = NSBezierPath(roundedRect: loupe, xRadius: 8, yRadius: 8); border.lineWidth = 1.5; border.stroke()
        let label = String(format: " #%02X%02X%02X ", rgba[0], rgba[1], rgba[2]) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
        let labelSize = label.size(withAttributes: attributes)
        let bar = CGRect(x: loupe.minX, y: loupe.maxY + 4, width: loupe.width, height: labelSize.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        NSColor(srgbRed: Double(rgba[0]) / 255, green: Double(rgba[1]) / 255, blue: Double(rgba[2]) / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX + 4, y: bar.minY + 3, width: bar.height - 6, height: bar.height - 6), xRadius: 2, yRadius: 2).fill()
        label.draw(at: CGPoint(x: bar.minX + bar.height, y: bar.minY + 3), withAttributes: attributes)
    }
}
