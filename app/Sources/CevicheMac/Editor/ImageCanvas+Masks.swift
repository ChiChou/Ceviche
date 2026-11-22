import AppKit
import SwiftUI
import CevicheCore

/// The gradient and radial mask handles drawn over the photo.
extension ImageCanvas {
    /// A source-space point on the canvas, through the current geometry (upright, straighten, rotation, flips).
    func sourceCanvasPoint(_ p: MaskPoint) -> CGPoint {
        guard let model else { return .zero }
        return canvasPoint(canvasPlan?.displayPoint(p) ?? p.rotated(model.adjustments.quarterTurns))
    }
    /// The ellipse's center, half-extents and rotation (radians) in source space. `start` and `end` are the
    /// corners of the unrotated bounding box; the rotation turns the ellipse about its center.
    /// The ellipse turns in pixels, as `MaskRenderer` draws it, so the axes work in units of the photo's height
    /// (x scaled by `aspect`, width over height); otherwise a turned ellipse on a non-square photo would shear.
    struct RadialGeometry {
        let center: MaskPoint, rx: Double, ry: Double, angle: Double, aspect: Double
        init(start: MaskPoint, end: MaskPoint, rotation: Double?, aspect: Double = 1) {
            self.aspect = aspect > 0 && aspect.isFinite ? aspect : 1
            center = MaskPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            rx = abs(end.x - start.x) / 2 * self.aspect; ry = abs(end.y - start.y) / 2; angle = (rotation ?? 0) * .pi / 180
        }
        /// A point on the ellipse's own axes, placed into source space.
        func world(_ x: Double, _ y: Double) -> MaskPoint {
            MaskPoint(x: center.x + (x * cos(angle) - y * sin(angle)) / aspect, y: center.y + x * sin(angle) + y * cos(angle))
        }
        /// A source point expressed on the ellipse's own axes.
        func local(_ p: MaskPoint) -> (x: Double, y: Double) {
            let dx = (p.x - center.x) * aspect, dy = p.y - center.y
            return (dx * cos(angle) + dy * sin(angle), -dx * sin(angle) + dy * cos(angle))
        }
        /// The bounding box corners for half-extents on the ellipse's own axes, about the same center.
        func corners(rx: Double, ry: Double) -> (start: MaskPoint, end: MaskPoint) {
            (MaskPoint(x: center.x - rx / aspect, y: center.y - ry), MaskPoint(x: center.x + rx / aspect, y: center.y + ry))
        }
        /// The pointer's angle about the center, in the ellipse's units.
        func bearing(_ p: MaskPoint) -> Double { atan2(p.y - center.y, (p.x - center.x) * aspect) }
        /// 1 on the outline, smaller inside.
        func normalizedRadius(_ p: MaskPoint) -> Double {
            let l = local(p); return hypot(l.x / max(rx, 1e-6), l.y / max(ry, 1e-6))
        }
    }
    /// Width over height of the source photo, the space a radial mask turns in.
    var sourceAspect: Double {
        guard let info = model?.info, info.width > 0, info.height > 0 else { return 1 }
        return Double(info.width) / Double(info.height)
    }
    func radialGeometry(_ mask: MaskSelection) -> RadialGeometry {
        RadialGeometry(start: mask.start, end: mask.end, rotation: mask.rotation, aspect: sourceAspect)
    }
    /// The rotation knob: on a stem out from the ellipse's top (source y runs up), in canvas points, with the axis handle it grows from.
    static let radialKnobReach = 22.0
    func radialKnob(_ mask: MaskSelection) -> (knob: CGPoint, base: CGPoint) {
        let g = radialGeometry(mask)
        let base = sourceCanvasPoint(g.world(0, g.ry)), center = sourceCanvasPoint(g.center)
        let dx = base.x - center.x, dy = base.y - center.y, length = hypot(dx, dy)
        guard length > 0.5 else { return (CGPoint(x: base.x, y: base.y - Self.radialKnobReach), base) }
        return (CGPoint(x: base.x + dx / length * Self.radialKnobReach, y: base.y + dy / length * Self.radialKnobReach), base)
    }
    /// Handle positions in source space, in hit-testing order (edge handles before the whole-shape handle).
    func gradientHandles(_ mask: MaskSelection) -> [(GradientHandle, MaskPoint)] {
        if mask.kind == .linear {
            return [(.start, mask.start), (.end, mask.end), (.move, MaskPoint(x: (mask.start.x + mask.end.x) / 2, y: (mask.start.y + mask.end.y) / 2))]
        }
        let g = radialGeometry(mask)
        // The feather handle rides the inner ring on the ellipse's own x axis, as in other RAW editors.
        return [(.feather, g.world(g.rx * (1 - 2 * mask.feather), 0)),
                (.axis(x: true, positive: true), g.world(g.rx, 0)), (.axis(x: true, positive: false), g.world(-g.rx, 0)),
                (.axis(x: false, positive: true), g.world(0, g.ry)), (.axis(x: false, positive: false), g.world(0, -g.ry)),
                (.move, g.center)]
    }
    /// An ellipse in source space, drawn through the geometry so it stays true under straighten and upright.
    private func ellipsePoints(_ g: RadialGeometry, scale: Double = 1) -> [CGPoint] {
        (0...72).map { i in
            let t = Double(i) / 72 * 2 * Double.pi
            return sourceCanvasPoint(g.world(cos(t) * g.rx * scale, sin(t) * g.ry * scale))
        }
    }
    private func ellipsePath(_ g: RadialGeometry, scale: Double = 1) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, q) in ellipsePoints(g, scale: scale).enumerated() { if i == 0 { path.move(to: q) } else { path.line(to: q) } }
        path.close(); return path
    }
    /// Whether a canvas point would turn the radial mask: on its knob, or on its outline away from the handles.
    func radialRotateHit(_ point: CGPoint, _ mask: MaskSelection) -> Bool {
        guard mask.kind == .radial else { return false }
        let knob = radialKnob(mask).knob
        if hypot(knob.x - point.x, knob.y - point.y) <= 10 { return true }
        if gradientHandles(mask).contains(where: { let q = sourceCanvasPoint($0.1); return hypot(q.x - point.x, q.y - point.y) <= 10 }) { return false }
        return outlineDistance(point, radialGeometry(mask)) <= 10
    }
    /// Distance from a canvas point to the ellipse's outline, in canvas points.
    private func outlineDistance(_ point: CGPoint, _ g: RadialGeometry) -> Double {
        let points = ellipsePoints(g)
        return (0..<points.count - 1).map { Self.distance(from: point, toSegment: points[$0], points[$0 + 1]) }.min() ?? .infinity
    }
    func drawGradient(_ mask: MaskSelection, in rect: CGRect) {
        let a = sourceCanvasPoint(mask.start), b = sourceCanvasPoint(mask.end)
        guard hypot(a.x - b.x, a.y - b.y) > 2 else { return }
        func dot(_ p: CGPoint, radius: Double = 4) {
            NSColor.black.withAlphaComponent(0.5).setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - radius - 1, y: p.y - radius - 1, width: 2 * radius + 2, height: 2 * radius + 2)).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)).fill()
        }
        func square(_ p: CGPoint, half: Double = 3.5) {
            NSColor.black.withAlphaComponent(0.5).setFill(); NSBezierPath(rect: CGRect(x: p.x - half - 1, y: p.y - half - 1, width: 2 * half + 2, height: 2 * half + 2)).fill()
            NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: p.x - half, y: p.y - half, width: 2 * half, height: 2 * half)).fill()
        }
        if mask.kind == .linear {
            // Three lines as in other RAW editors: full effect, the midpoint, and no effect; the dashed axis joins them.
            let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy), extent = max(rect.width, rect.height)
            let nx = -dy / len * extent, ny = dx / len * extent
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            for (p, alpha, width) in [(a, 0.85, 1.0), (mid, 0.4, 0.5), (b, 0.85, 1.0)] {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: p.x - nx, y: p.y - ny)); line.line(to: CGPoint(x: p.x + nx, y: p.y + ny))
                NSColor.black.withAlphaComponent(alpha * 0.4).setStroke(); line.lineWidth = width + 2; line.stroke()
                NSColor.white.withAlphaComponent(alpha).setStroke(); line.lineWidth = width; line.stroke()
            }
            let axis = NSBezierPath(); axis.move(to: a); axis.line(to: b)
            NSColor.white.withAlphaComponent(0.85).setStroke(); axis.lineWidth = 0.5; axis.setLineDash([4, 4], count: 2, phase: 0); axis.stroke()
            dot(a); dot(b); square(mid)
        } else {
            // Two rings: the outer edge of the mask and the inner ring where the feather begins; the inner handle sets the feather.
            let g = radialGeometry(mask)
            guard g.rx > 0.0005, g.ry > 0.0005 else { return }
            let outer = ellipsePath(g), inner = ellipsePath(g, scale: 1 - 2 * mask.feather)
            NSColor.black.withAlphaComponent(0.35).setStroke(); outer.lineWidth = 3; outer.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke(); outer.lineWidth = 1; outer.stroke()
            if mask.feather > 0.005 {
                NSColor.black.withAlphaComponent(0.3).setStroke(); inner.lineWidth = 2.5; inner.stroke()
                inner.setLineDash([3, 3], count: 2, phase: 0); inner.lineWidth = 1
                NSColor.white.withAlphaComponent(0.75).setStroke(); inner.stroke()
            }
            // The rotation knob on its stem, lit while it is held or under the pointer.
            let (knob, base) = radialKnob(mask)
            let stem = NSBezierPath(); stem.move(to: base); stem.line(to: knob)
            NSColor.black.withAlphaComponent(0.35).setStroke(); stem.lineWidth = 2.5; stem.stroke()
            NSColor.white.withAlphaComponent(0.85).setStroke(); stem.lineWidth = 1; stem.stroke()
            let lit = gradientHandle == .rotate || gradientHandle == nil && pointerPosition.map { radialRotateHit($0, mask) } == true
            let ring = NSBezierPath(ovalIn: CGRect(x: knob.x - 4.5, y: knob.y - 4.5, width: 9, height: 9))
            NSColor.black.withAlphaComponent(0.5).setStroke(); ring.lineWidth = 3.5; ring.stroke()
            (lit ? NSColor.controlAccentColor : NSColor.white).setFill(); ring.fill()
            NSColor.white.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            for (handle, p) in gradientHandles(mask) {
                switch handle {
                case .feather: dot(sourceCanvasPoint(p), radius: 3.5)
                case .move: dot(sourceCanvasPoint(p), radius: 3)
                default: dot(sourceCanvasPoint(p))
                }
            }
        }
    }
}
