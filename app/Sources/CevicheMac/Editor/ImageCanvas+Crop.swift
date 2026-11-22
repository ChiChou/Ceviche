import AppKit
import SwiftUI
import CevicheCore

/// The crop frame: its zones, handles, cursors and resizing.
extension ImageCanvas {
    /// What a drag at a canvas point does. On a handle (within `cropHandleRadius` of a corner or an edge's midpoint) or
    /// along an edge (within `cropEdgeGrip`) it resizes; inside the frame it moves the frame; in the ring outside the
    /// frame from the handle out to `cropRotateRadius` it turns only the photo (the frame keeps its size until the drag
    /// ends); anywhere else nothing (nil).
    enum CropZone: Equatable { case corner(Int), edge(Int), move, rotate }
    static let cropHandleRadius = 10.0, cropEdgeGrip = 6.0, cropRotateRadius = 36.0
    /// How far past both of a corner's edges its bracket reaches; beyond that, diagonally out, a drag turns the photo
    /// rather than resizing, so a turn begun close to a corner never takes hold of it.
    static let cropCornerOutside = 4.0
    static func cropZone(at point: CGPoint, frame: CGRect) -> CropZone? {
        // Corners run bottom-left, bottom-right, top-right, top-left (the canvas is flipped, so the bottom is maxY);
        // edges are left, right, bottom, top.
        let corners = [CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY)]
        let edges = [CGPoint(x: frame.minX, y: frame.midY), CGPoint(x: frame.maxX, y: frame.midY), CGPoint(x: frame.midX, y: frame.maxY), CGPoint(x: frame.midX, y: frame.minY)]
        func distance(_ q: CGPoint) -> Double { hypot(q.x - point.x, q.y - point.y) }
        let outsideX = max(frame.minX - point.x, point.x - frame.maxX), outsideY = max(frame.minY - point.y, point.y - frame.maxY)
        let diagonallyOut = outsideX > cropCornerOutside && outsideY > cropCornerOutside
        if !diagonallyOut, let corner = corners.indices.min(by: { distance(corners[$0]) < distance(corners[$1]) }), distance(corners[corner]) <= cropHandleRadius { return .corner(corner) }
        if let edge = edges.indices.min(by: { distance(edges[$0]) < distance(edges[$1]) }), distance(edges[edge]) <= cropHandleRadius { return .edge(edge) }
        if (frame.minY...frame.maxY).contains(point.y) {
            if abs(point.x - frame.minX) <= cropEdgeGrip { return .edge(0) }
            if abs(point.x - frame.maxX) <= cropEdgeGrip { return .edge(1) }
        }
        if (frame.minX...frame.maxX).contains(point.x) {
            if abs(point.y - frame.maxY) <= cropEdgeGrip { return .edge(2) }
            if abs(point.y - frame.minY) <= cropEdgeGrip { return .edge(3) }
        }
        if frame.contains(point) { return .move }
        return (corners + edges).contains { distance($0) <= cropRotateRadius } ? .rotate : nil
    }
    /// Crop's frame is on the canvas and takes the pointer (not the ruler, guides or the before/after split).
    var croppingFrame: Bool {
        guard let model else { return false }
        return model.toolTab == .crop && !model.cropDrawingGuide && !model.cropPlacingCorners && !model.cropStraightening && !model.comparing && image != nil
    }
    private func currentCropZone(at point: CGPoint) -> CropZone? {
        guard let model, let image else { return nil }
        return Self.cropZone(at: point, frame: cropFrame(model.adjustments.geometry.crop, in: photoRect(model, image)))
    }
    /// The pointer for a crop zone: resize arrows on handles and edges, a hand inside, a turning arrow facing away
    /// from the frame in the rotation ring. ⌘ arms the straighten ruler.
    private func cropCursor(at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> NSCursor {
        if modifiers.contains(.command) { return .crosshair }
        switch currentCropZone(at: point) {
        case .corner(let corner): return .frameResize(position: [.bottomLeft, .bottomRight, .topRight, .topLeft][corner], directions: .all)
        case .edge(let edge): return .frameResize(position: [.left, .right, .bottom, .top][edge], directions: .all)
        case .move: return cropMoving != nil ? .closedHand : .openHand
        case .rotate:
            guard let model, let image else { return .arrow }
            let frame = cropFrame(model.adjustments.geometry.crop, in: photoRect(model, image))
            // Canvas y runs down; the cursor images count angles with y up.
            let angle = atan2(frame.midY - point.y, point.x - frame.midX)
            return Self.rotateCursors[(Int((angle / (.pi / 4)).rounded()) % 8 + 8) % 8]
        case nil: return model?.viewport.isFitted == false ? .openHand : .arrow
        }
    }
    /// The handle being dragged, or the one under the pointer while nothing is.
    func activeCropZone(frame: CGRect) -> CropZone? {
        switch cropHandle {
        case .corner(let corner): return .corner(corner)
        case .edge(let edge): return .edge(edge)
        case nil: return cropStart == nil && !NSEvent.modifierFlags.contains(.command) ? pointerPosition.flatMap { Self.cropZone(at: $0, frame: frame) } : nil
        }
    }
    /// Corner brackets and edge bars just outside the frame line; the active one is lit.
    func drawCropHandles(frame: CGRect, active: CropZone?) {
        let length = min(18, frame.width / 3, frame.height / 3), thickness = 3.0, half = thickness / 2
        func bracket(_ corner: CGPoint, _ sx: Double, _ sy: Double) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: corner.x + sx * length, y: corner.y - sy * half))
            path.line(to: CGPoint(x: corner.x - sx * half, y: corner.y - sy * half))
            path.line(to: CGPoint(x: corner.x - sx * half, y: corner.y + sy * length))
            return path
        }
        let corners = [bracket(CGPoint(x: frame.minX, y: frame.maxY), 1, -1), bracket(CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
                       bracket(CGPoint(x: frame.maxX, y: frame.minY), -1, 1), bracket(CGPoint(x: frame.minX, y: frame.minY), 1, 1)]
        func bar(_ a: CGPoint, _ b: CGPoint) -> NSBezierPath { let path = NSBezierPath(); path.move(to: a); path.line(to: b); return path }
        let edges = [bar(CGPoint(x: frame.minX - half, y: frame.midY - length / 2), CGPoint(x: frame.minX - half, y: frame.midY + length / 2)),
                     bar(CGPoint(x: frame.maxX + half, y: frame.midY - length / 2), CGPoint(x: frame.maxX + half, y: frame.midY + length / 2)),
                     bar(CGPoint(x: frame.midX - length / 2, y: frame.maxY + half), CGPoint(x: frame.midX + length / 2, y: frame.maxY + half)),
                     bar(CGPoint(x: frame.midX - length / 2, y: frame.minY - half), CGPoint(x: frame.midX + length / 2, y: frame.minY - half))]
        for (index, path) in (corners + edges).enumerated() {
            let lit = index < 4 ? active == .corner(index) : active == .edge(index - 4)
            path.lineCapStyle = .square; path.lineJoinStyle = .miter
            NSColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = thickness + 2; path.stroke()
            (lit ? NSColor.controlAccentColor : NSColor.white).setStroke(); path.lineWidth = thickness; path.stroke()
        }
    }
    func updateCropCursor(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard croppingFrame || model?.toolTab == .crop && model?.cropDrawingGuide == false && model?.cropPlacingCorners == false && model?.comparing == false && modifiers.contains(.command) else { return }
        // While a handle is held the pointer keeps the mode the drag started in.
        if cropHandle != nil || cropRotation != nil { return }
        cropCursor(at: point, modifiers: modifiers).set()
    }
    func cropFrame(_ crop: CropRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + crop.x * rect.width, y: rect.minY + (1 - crop.y - crop.height) * rect.height, width: crop.width * rect.width, height: crop.height * rect.height)
    }
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    /// Drags one edge; the opposite edge stays put, or with `centered` mirrors the drag about the center.
    /// With an aspect ratio the other axis follows, centered where it was.
    static func edgeResized(_ crop: CropRect, edge: Int, to p: MaskPoint, ratio: Double?, centered: Bool = false) -> CropRect {
        var r = crop
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        if centered {
            if edge < 2 { let half = min(min(cx, 1 - cx), max(0.005, abs(p.x - cx))); r.x = cx - half; r.width = 2 * half }
            else { let half = min(min(cy, 1 - cy), max(0.005, abs(p.y - cy))); r.y = cy - half; r.height = 2 * half }
        } else {
            switch edge {
            case 0: let maxX = r.x + r.width; r.x = min(maxX - 0.01, max(0, p.x)); r.width = maxX - r.x
            case 1: r.width = min(1 - r.x, max(0.01, p.x - r.x))
            case 2: let maxY = r.y + r.height; r.y = min(maxY - 0.01, max(0, p.y)); r.height = maxY - r.y
            default: r.height = min(1 - r.y, max(0.01, p.y - r.y))
            }
        }
        guard let ratio else { return r }
        if edge < 2 {
            let maxH = 2 * min(cy, 1 - cy)
            var h = r.width / ratio
            if h > maxH {
                h = maxH; let w = h * ratio
                if centered { r.x = cx - w / 2 } else if edge == 0 { r.x = r.x + r.width - w }
                r.width = w
            }
            r.y = cy - h / 2; r.height = h
        } else {
            let maxW = 2 * min(cx, 1 - cx)
            var w = r.height * ratio
            if w > maxW {
                w = maxW; let h = w / ratio
                if centered { r.y = cy - h / 2 } else if edge == 2 { r.y = r.y + r.height - h }
                r.height = h
            }
            r.x = cx - w / 2; r.width = w
        }
        return r
    }
    /// Drags one corner; the opposite corner stays put, or with `centered` the frame grows about its center.
    static func cornerResized(_ crop: CropRect, corner: Int, to p: MaskPoint, ratio: Double?, centered: Bool = false) -> CropRect? {
        if centered {
            let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
            let maxW = 2 * min(cx, 1 - cx), maxH = 2 * min(cy, 1 - cy)
            var w = max(0.01, 2 * abs(p.x - cx)), h = max(0.01, 2 * abs(p.y - cy))
            if let ratio { h = w / ratio; let scale = min(1, min(maxW / w, maxH / h)); w *= scale; h *= scale }
            else { w = min(w, maxW); h = min(h, maxH) }
            guard w >= 0.01, h >= 0.01 else { return nil }
            return CropRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
        let anchorX = corner == 1 || corner == 2 ? crop.x : crop.x + crop.width, anchorY = corner >= 2 ? crop.y : crop.y + crop.height
        var w = max(0.01, abs(p.x - anchorX)), h = max(0.01, abs(p.y - anchorY))
        let sx = p.x >= anchorX ? 1.0 : -1.0, sy = p.y >= anchorY ? 1.0 : -1.0
        let maxW = sx > 0 ? 1 - anchorX : anchorX, maxH = sy > 0 ? 1 - anchorY : anchorY
        if let ratio { h = w / ratio; let scale = min(1, min(maxW / w, maxH / h)); w *= scale; h *= scale }
        else { w = min(w, maxW); h = min(h, maxH) }
        guard w >= 0.01, h >= 0.01 else { return nil }
        return CropRect(x: sx > 0 ? anchorX : anchorX - w, y: sy > 0 ? anchorY : anchorY - h, width: w, height: h)
    }
    /// Shift keeps the frame's current proportions even without a set aspect; Option resizes about the center.
    func resizeCrop(to p: MaskPoint, modifiers: NSEvent.ModifierFlags) {
        guard let model, let handle = cropHandle else { return }
        let ratio = model.normalizedCropAspect ?? (modifiers.contains(.shift) ? cropOriginal.width / cropOriginal.height : nil)
        let centered = modifiers.contains(.option)
        let original = cropOriginal
        func frame(_ q: CGPoint) -> CropRect? {
            let q = MaskPoint(x: q.x, y: q.y)
            switch handle {
            case .edge(let edge): return Self.edgeResized(original, edge: edge, to: q, ratio: ratio, centered: centered)
            case .corner(let corner): return Self.cornerResized(original, corner: corner, to: q, ratio: ratio, centered: centered)
            }
        }
        guard let start = cropReached ?? cropStart.map({ CGPoint(x: $0.x, y: $0.y) }),
              let hit = Self.reach(from: start, to: CGPoint(x: p.x, y: p.y), frame: frame, fits: model.cropFitsImage) else { return }
        cropReached = hit.point; model.edit { $0.geometry.crop = hit.crop }
    }
    /// How far a drag gets from `start` (a pointer or offset whose frame fits) toward `target`: all the way when that
    /// frame fits, else to where it stops fitting, then along each axis for what is left. A fast drag past a turned
    /// photo's edge so ends on the edge, sliding along it, instead of wherever the last fitting mouse event left it.
    static func reach(from start: CGPoint, to target: CGPoint, frame: (CGPoint) -> CropRect?, fits: (CropRect) -> Bool) -> (point: CGPoint, crop: CropRect)? {
        func fitting(_ q: CGPoint) -> CropRect? { frame(q).flatMap { fits($0) ? $0 : nil } }
        if let crop = fitting(target) { return (target, crop) }
        guard var crop = fitting(start) else { return nil }
        // Fitting frames along a straight drag form one stretch from the start (the photo is convex).
        func farthest(from a: CGPoint, to b: CGPoint) -> CGPoint {
            var low = 0.0, high = 1.0
            for _ in 0..<20 {
                let t = (low + high) / 2, q = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                if let fitted = fitting(q) { low = t; crop = fitted } else { high = t }
            }
            return CGPoint(x: a.x + (b.x - a.x) * low, y: a.y + (b.y - a.y) * low)
        }
        var point = farthest(from: start, to: target)
        point = farthest(from: point, to: CGPoint(x: target.x, y: point.y))
        point = farthest(from: point, to: CGPoint(x: point.x, y: target.y))
        return (point, crop)
    }
}
