import AppKit
import SwiftUI
import CevicheCore

/// Retouch strokes, brush cursors and dust spots drawn over the photo, and their hit-testing.
extension ImageCanvas {
    /// Shows the stroke footprint before painting: the outer ring is the full radius, the dashed ring is where
    /// the falloff starts (as the renderer applies softness), and a soft fill previews the feather.
    /// A circle in source pixels, `radius` a fraction of the shorter side, drawn through the current geometry.
    private func sourceCircle(center: MaskPoint, radius: Double, info: ImageInfo, model: EditorModel) -> NSBezierPath {
        let plan = canvasPlan, path = NSBezierPath(), pixels = radius * Double(min(info.width, info.height))
        for i in 0...72 {
            let angle = Double(i) / 72 * 2 * Double.pi
            let p = MaskPoint(x: center.x + cos(angle) * pixels / Double(info.width), y: center.y + sin(angle) * pixels / Double(info.height))
            let q = canvasPoint(plan?.displayPoint(p) ?? p.rotated(model.adjustments.quarterTurns))
            if i == 0 { path.move(to: q) } else { path.line(to: q) }
        }
        path.close(); return path
    }
    /// The stroke being painted, over the mask as it was when the stroke began: in the overlay's own tint where it
    /// adds, and cut out of the overlay where it takes away. It is a picture of the stroke, not the mask made again;
    /// that happens once, on release.
    func drawLiveStroke(_ stroke: MaskStroke, removes: Bool, model: EditorModel) {
        guard let first = stroke.points.first, let info = model.info, let context = NSGraphicsContext.current?.cgContext else { return }
        let ring = sourceCircle(center: first, radius: stroke.radius, info: info, model: model).bounds
        let width = max(1, max(ring.width, ring.height))
        let path = CGMutablePath()
        path.move(to: sourceCanvasPoint(first))
        // A single point is a dab: a line to itself draws the round cap.
        for point in stroke.points.count > 1 ? Array(stroke.points.dropFirst()) : [first] { path.addLine(to: sourceCanvasPoint(point)) }
        context.saveGState()
        context.setLineCap(.round); context.setLineJoin(.round)
        // The soft edge, then the full core: two passes stand in for the falloff.
        let passes: [(Double, Double)] = stroke.softness > 0.05 ? [(1, 0.45), (max(0.15, 1 - stroke.softness), 1)] : [(1, 1)]
        if removes && model.showMaskOverlay && model.maskOverlay != nil {
            context.setBlendMode(.destinationOut)
            for (scale, strength) in passes {
                context.setStrokeColor(NSColor.black.withAlphaComponent(strength).cgColor); context.setLineWidth(width * scale)
                context.addPath(path); context.strokePath()
            }
        } else {
            // One layer for the stroke, so its own overlaps don't build up: the mask is no denser where it crosses itself.
            context.setAlpha(removes ? 0.3 : 0.45)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let tint = removes ? NSColor.white : NSColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1)
            for (scale, strength) in passes {
                context.setStrokeColor(tint.withAlphaComponent(strength).cgColor); context.setLineWidth(width * scale)
                context.addPath(path); context.strokePath()
            }
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }
    func drawBrushCursor(at pointer: CGPoint, radius: Double, softness: Double, erase: Bool, model: EditorModel) {
        guard let center = maskPoint(pointer, clamp: false), let info = model.info else { return }
        func ring(_ r: Double) -> NSBezierPath { sourceCircle(center: center, radius: r, info: info, model: model) }
        let outer = ring(radius), inner = ring(radius * max(0, 1 - softness))
        let bounds = outer.bounds, screenRadius = max(bounds.width, bounds.height) / 2
        let tint = erase ? NSColor.systemRed : NSColor.white
        NSGraphicsContext.saveGraphicsState()
        outer.addClip()
        let core = max(0.001, min(0.999, 1 - softness))
        NSGradient(colors: [tint.withAlphaComponent(0.16), tint.withAlphaComponent(0.16), tint.withAlphaComponent(0)], atLocations: [0, core, 1], colorSpace: .sRGB)?
            .draw(fromCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: 0, toCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: screenRadius, options: [])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.55).setStroke(); outer.lineWidth = 3; outer.stroke()
        tint.withAlphaComponent(0.95).setStroke(); outer.lineWidth = 1; outer.stroke()
        if softness > 0.02, screenRadius > 6 {
            NSColor.black.withAlphaComponent(0.4).setStroke(); inner.lineWidth = 2.5; inner.stroke()
            inner.setLineDash([3, 3], count: 2, phase: 0); inner.lineWidth = 1
            tint.withAlphaComponent(0.85).setStroke(); inner.stroke()
        }
        // A small mark keeps the exact center readable for tiny brushes and shows add versus erase.
        let mark = NSBezierPath(), m = 4.0
        mark.move(to: CGPoint(x: pointer.x - m, y: pointer.y)); mark.line(to: CGPoint(x: pointer.x + m, y: pointer.y))
        if !erase { mark.move(to: CGPoint(x: pointer.x, y: pointer.y - m)); mark.line(to: CGPoint(x: pointer.x, y: pointer.y + m)) }
        NSColor.black.withAlphaComponent(0.55).setStroke(); mark.lineWidth = 3; mark.stroke()
        tint.setStroke(); mark.lineWidth = 1; mark.stroke()
    }
    /// Where a stroke's pin sits: the point of its path nearest the middle of the path, so it is always on the footprint.
    private static func retouchPin(_ points: [MaskPoint]) -> MaskPoint {
        guard let first = points.first else { return MaskPoint(x: 0, y: 0) }
        let xs = points.map(\.x), ys = points.map(\.y), mid = MaskPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        return points.min { hypot($0.x - mid.x, $0.y - mid.y) < hypot($1.x - mid.x, $1.y - mid.y) } ?? first
    }
    /// The selected stroke's source (Heal and Clone), then its target, then any hand-drawn stroke's pin.
    func retouchHit(at point: CGPoint) -> (RetouchStroke, RetouchPart)? {
        guard let model, let info = model.info else { return nil }
        if let stroke = model.selectedRetouch, let p = maskPoint(point, clamp: false) {
            let r = stroke.radius * Double(min(info.width, info.height))
            func covers(_ points: [MaskPoint]) -> Bool { points.contains { hypot((p.x - $0.x) * Double(info.width), (p.y - $0.y) * Double(info.height)) <= r } }
            if stroke.mode.hasSourceHandle, model.toolTab != .face, covers(Self.shifted(stroke)) { return (stroke, .source) }
            if covers(stroke.points) { return (stroke, .target) }
        }
        for stroke in model.adjustments.retouch.reversed() where model.showsRetouchPin(stroke) {
            let q = sourceCanvasPoint(Self.retouchPin(stroke.points))
            if hypot(point.x - q.x, point.y - q.y) <= 8 { return (stroke, .target) }
        }
        return nil
    }
    /// The stroke's path moved onto its source.
    private static func shifted(_ stroke: RetouchStroke) -> [MaskPoint] {
        guard let first = stroke.points.first else { return [] }
        return stroke.points.map { MaskPoint(x: $0.x + stroke.source.x - first.x, y: $0.y + stroke.source.y - first.y) }
    }
    /// The outline of a stroke's footprint on the canvas: a circle for a dab, the outline of the painted band otherwise.
    private func retouchOutline(_ points: [MaskPoint], radius: Double, info: ImageInfo, model: EditorModel) -> NSBezierPath? {
        guard let first = points.first else { return nil }
        let circle = sourceCircle(center: first, radius: radius, info: info, model: model)
        guard points.count > 1 else { return circle }
        let path = CGMutablePath(); path.addLines(between: points.map(sourceCanvasPoint))
        let band = path.copy(strokingWithWidth: max(circle.bounds.width, circle.bounds.height), lineCap: .round, lineJoin: .round, miterLimit: 1).normalized()
        return NSBezierPath(cgPath: band)
    }
    /// The stroke under the pointer in the stroke list: its footprint in the accent color inside a ring wide enough to find
    /// a dust-sized spot at any zoom, and for Heal and Clone its source, dashed.
    func drawHoveredRetouch(model: EditorModel) {
        guard let id = model.hoveredRetouchID, let stroke = model.adjustments.retouch.first(where: { $0.id == id }),
              let info = model.info,
              let target = retouchOutline(stroke.points, radius: stroke.radius, info: info, model: model) else { return }
        let accent = Theme.nsAccent
        if stroke.mode.hasSourceHandle, model.toolTab != .face, let source = retouchOutline(Self.shifted(stroke), radius: stroke.radius, info: info, model: model) {
            NSColor.black.withAlphaComponent(0.5).setStroke(); source.lineWidth = 3; source.stroke()
            source.setLineDash([4, 3], count: 2, phase: 0); source.lineWidth = 1.5; accent.setStroke(); source.stroke()
        }
        NSColor.black.withAlphaComponent(0.55).setStroke(); target.lineWidth = 4; target.stroke()
        accent.setStroke(); target.lineWidth = 2; target.stroke()
        let bounds = target.bounds, center = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = max(bounds.width, bounds.height) / 2 + 10
        guard r < 40 else { return }
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        for (dx, dy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)] {
            ring.move(to: CGPoint(x: center.x + dx * r, y: center.y + dy * r)); ring.line(to: CGPoint(x: center.x + dx * (r + 8), y: center.y + dy * (r + 8)))
        }
        NSColor.black.withAlphaComponent(0.55).setStroke(); ring.lineWidth = 3.5; ring.stroke()
        accent.setStroke(); ring.lineWidth = 1.5; ring.stroke()
    }
    /// Pins for the hand-drawn strokes; for the selected one its outline, and for Heal and Clone its source outline and
    /// an arrow from the source to the target.
    /// Object's outline under the pointer: what a click there would take out, tinted.
    func drawObjectPreview(model: EditorModel) {
        guard let info = model.info, !model.comparing else { return }
        // What Shift-click collected, and what a click under the pointer would add or change.
        let preview = model.objectPreview
        var strokes: [RetouchStroke] = []
        for (i, pick) in model.objectSelection.enumerated() where preview?.replacing != i { strokes += pick.strokes }
        if let preview { strokes += preview.strokes }
        guard !strokes.isEmpty else { return }
        let paths = strokes.compactMap { retouchOutline($0.points, radius: $0.radius, info: info, model: model) }
        Theme.nsAccent.withAlphaComponent(0.3).setFill()
        for path in paths { path.fill() }
        for path in paths {
            NSColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.25; path.stroke()
        }
    }
    /// What Object just took out, while its AI fill is made: the area pulses in the accent colour inside a moving dashed
    /// line. Returns whether anything is still being taken out, so the canvas keeps redrawing.
    func drawRemovingObjects(model: EditorModel) -> Bool {
        guard !model.removingObjects.isEmpty, let info = model.info else { return false }
        let now = Date()
        let strokes = model.adjustments.retouch.filter { stroke in
            guard let added = model.removingObjects[stroke.id], stroke.enabled else { return false }
            return model.pendingFills.contains(stroke.id) || (stroke.generative && now.timeIntervalSince(added) < 0.6)
        }
        guard !strokes.isEmpty else { model.removingObjects = [:]; return false }
        let t = CACurrentMediaTime()
        let pulse = 0.5 + 0.5 * sin(t * 2 * .pi / 1.4)
        let paths = strokes.compactMap { retouchOutline($0.points, radius: $0.radius, info: info, model: model) }
        Theme.nsAccent.withAlphaComponent(0.12 + 0.22 * pulse).setFill()
        for path in paths { path.fill() }
        for path in paths {
            NSColor.black.withAlphaComponent(0.4).setStroke(); path.setLineDash(nil, count: 0, phase: 0); path.lineWidth = 3; path.stroke()
            path.setLineDash([6, 5], count: 2, phase: CGFloat((t * 22).truncatingRemainder(dividingBy: 11)))
            NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
        }
        return true
    }
    /// Masks › Object's outline under the pointer: the mask a click there would make.
    func drawMaskObjectPreview(model: EditorModel) {
        guard let preview = model.maskObjectPreview, !model.comparing, !preview.outline.isEmpty else { return }
        let path = NSBezierPath()
        for (a, b) in preview.outline { path.move(to: sourceCanvasPoint(a)); path.line(to: sourceCanvasPoint(b)) }
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.5).setStroke(); path.lineWidth = 3.5; path.stroke()
        Theme.nsAccent.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
    func drawRetouchOverlay(model: EditorModel) {
        guard let info = model.info else { return }
        let selected = model.selectedRetouch
        func pin(_ q: CGPoint, active: Bool) {
            let outer = NSBezierPath(ovalIn: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12))
            NSColor.black.withAlphaComponent(0.5).setStroke(); outer.lineWidth = 2; outer.stroke()
            (active ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.5)).setFill(); outer.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)).fill()
        }
        func outline(_ path: NSBezierPath) {
            NSColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = 1.25; path.stroke()
        }
        // Several selected: each with its outline and a lit pin. A selected dust stroke shows its outline too, though a
        // brush has no handle for it, so nothing is deleted unseen.
        let picked = model.selectedRetouchIDs
        for stroke in model.adjustments.retouch where stroke.id != selected?.id {
            let lit = picked.contains(stroke.id)
            if lit, let path = retouchOutline(stroke.points, radius: stroke.radius, info: info, model: model) { outline(path) }
            if model.showsRetouchPin(stroke), stroke.enabled || lit { pin(sourceCanvasPoint(Self.retouchPin(stroke.points)), active: lit) }
        }
        drawMarquee()
        guard let stroke = selected, let target = retouchOutline(stroke.points, radius: stroke.radius, info: info, model: model) else { return }
        outline(target)
        let to = sourceCanvasPoint(Self.retouchPin(stroke.points))
        // Face spots choose their own sources: only the spot shows.
        if stroke.mode.hasSourceHandle, model.toolTab != .face, let source = retouchOutline(Self.shifted(stroke), radius: stroke.radius, info: info, model: model) {
            outline(source)
            let from = sourceCanvasPoint(Self.retouchPin(Self.shifted(stroke)))
            let length = hypot(to.x - from.x, to.y - from.y)
            if length > 24 {
                let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
                let a = CGPoint(x: from.x + ux * 10, y: from.y + uy * 10), b = CGPoint(x: to.x - ux * 10, y: to.y - uy * 10)
                let arrow = NSBezierPath(); arrow.move(to: a); arrow.line(to: b)
                arrow.move(to: CGPoint(x: b.x - ux * 6 - uy * 4, y: b.y - uy * 6 + ux * 4)); arrow.line(to: b); arrow.line(to: CGPoint(x: b.x - ux * 6 + uy * 4, y: b.y - uy * 6 - ux * 4))
                NSColor.black.withAlphaComponent(0.45).setStroke(); arrow.lineWidth = 3; arrow.stroke()
                NSColor.white.setStroke(); arrow.lineWidth = 1.25; arrow.stroke()
            }
            pin(from, active: true)
        }
        pin(to, active: true)
    }
    /// Visualize Spots: the map in place of the photo, black until its first map is made, and the sharper map of the
    /// detail on screen over it, as the photo's detail lies over the preview.
    func drawDustMaps(model: EditorModel, in rect: CGRect) {
        func draw(_ map: CGImage, _ frame: CGRect) {
            NSImage(cgImage: map, size: CGSize(width: map.width, height: map.height))
                .draw(in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        if let (source, map) = model.dustPreviewMap, source === model.preview { draw(map, rect) } else { NSColor.black.setFill(); rect.fill() }
        if let detail = model.detail, let (source, map) = model.dustDetailMap, source === detail.image, model.toolTab != .crop {
            draw(map, CGRect(x: rect.minX + detail.region.minX * rect.width, y: rect.minY + detail.region.minY * rect.height,
                             width: detail.region.width * rect.width, height: detail.region.height * rect.height))
        }
    }
    /// Each spot under review as a ring; the selected one in the accent color with a grip on its edge.
    func drawDustSpots(model: EditorModel) {
        guard let info = model.info else { return }
        let accent = Theme.nsAccent
        let single = model.selectedRetouchID
        // Healed spots first and dashed, beneath the ones still under review.
        for spot in model.healedDustHandles {
            let selected = model.selectedRetouchIDs.contains(spot.id)
            let ring = sourceCircle(center: spot.center, radius: spot.radius, info: info, model: model)
            if selected { accent.withAlphaComponent(0.35).setFill(); ring.fill() }
            NSColor.black.withAlphaComponent(0.5).setStroke(); ring.lineWidth = selected ? 4 : 2.5; ring.stroke()
            ring.setLineDash([4, 3], count: 2, phase: 0)
            (selected ? accent : NSColor.white.withAlphaComponent(0.85)).setStroke(); ring.lineWidth = selected ? 2 : 1.25; ring.stroke()
            if spot.id == single { drawDustGrip(spot, info: info, accent: accent) }
        }
        for spot in model.dustSpots {
            let selected = model.selectedRetouchIDs.contains(spot.id)
            let ring = sourceCircle(center: spot.center, radius: spot.radius, info: info, model: model)
            // A tint inside, so a selection reads on the map and with a neutral accent too.
            if selected { accent.withAlphaComponent(0.35).setFill(); ring.fill() }
            NSColor.black.withAlphaComponent(0.6).setStroke(); ring.lineWidth = selected ? 4 : 3; ring.stroke()
            (selected ? accent : NSColor.white).setStroke()
            ring.lineWidth = selected ? 2 : 1.25; ring.stroke()
            if spot.id == single { drawDustGrip(spot, info: info, accent: accent) }
        }
        drawMarquee()
    }
    /// The box being dragged around handles to select them.
    private func drawMarquee() {
        guard let marquee = handleMarquee, dustAddPoint == nil, faceSpotAddPoint == nil else { return }
        let accent = Theme.nsAccent
        let box = NSBezierPath(rect: CGRect(x: min(marquee.start.x, marquee.end.x), y: min(marquee.start.y, marquee.end.y),
                                            width: abs(marquee.end.x - marquee.start.x), height: abs(marquee.end.y - marquee.start.y)))
        accent.withAlphaComponent(0.12).setFill(); box.fill()
        accent.setStroke(); box.lineWidth = 1; box.stroke()
    }
    /// The resize grip on the selected spot's right edge.
    private func drawDustGrip(_ spot: DustSpot, info: ImageInfo, accent: NSColor) {
        let (center, radius) = dustScreenCircle(spot, info: info)
        let grip = CGRect(x: center.x + radius - 3.5, y: center.y - 3.5, width: 7, height: 7)
        NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(rect: grip.insetBy(dx: -1, dy: -1)).fill()
        accent.setFill(); NSBezierPath(rect: grip).fill()
    }
    /// The active tool's handles in a canvas rectangle: dust spots by their centers, hand-drawn strokes by their pins.
    func retouchHandles(in rect: CGRect) -> Set<UUID> {
        guard let model else { return [] }
        if model.retouchTool == .dust { return Set(model.shownDustSpots.filter { rect.contains(sourceCanvasPoint($0.center)) }.map(\.id)) }
        return Set(model.adjustments.retouch.filter { model.showsRetouchPin($0) && rect.contains(sourceCanvasPoint(Self.retouchPin($0.points))) }.map(\.id))
    }
    /// A spot's center and radius on screen; geometry rarely stretches a circle enough to matter for picking it.
    private func dustScreenCircle(_ spot: DustSpot, info: ImageInfo) -> (CGPoint, Double) {
        let center = sourceCanvasPoint(spot.center), pixels = spot.radius * Double(min(info.width, info.height))
        let edge = sourceCanvasPoint(MaskPoint(x: spot.center.x + pixels / Double(info.width), y: spot.center.y))
        return (center, hypot(edge.x - center.x, edge.y - center.y))
    }
    /// The topmost spot under a canvas point, and whether the point is on its edge (resize) rather than inside (move).
    /// Spots under review come before healed ones.
    func dustHit(at point: CGPoint) -> (DustSpot, Bool)? {
        guard let model, let info = model.info else { return nil }
        for spot in model.dustSpots.reversed() + model.healedDustHandles.reversed() {
            let (center, radius) = dustScreenCircle(spot, info: info), d = hypot(point.x - center.x, point.y - center.y)
            if d <= radius + 5 && d >= radius - min(5, radius * 0.35) { return (spot, true) }
            if d < radius { return (spot, false) }
        }
        return nil
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, model.removing, !model.comparing else { return super.menu(for: event) }
        // On a selected spot or stroke (or off every one, with several selected) the menu removes the whole selection.
        let point = convert(event.locationInWindow, from: nil), dust = model.retouchTool == .dust
        let hit = dust ? dustHit(at: point)?.0.id : retouchHit(at: point)?.0.id
        if let hit, !model.selectedRetouchIDs.contains(hit) { model.selectedRetouchID = hit }
        let targets = model.selectedRetouchIDs
        guard !targets.isEmpty, hit != nil || targets.count > 1 else { return dust ? nil : super.menu(for: event) }
        needsDisplay = true
        let title = !dust ? L10n.tr("Delete") : targets.count == 1 ? L10n.tr("Remove Spot") : L10n.tr("Remove \(targets.count) Spots")
        let menu = NSMenu(), item = NSMenuItem(title: title, action: #selector(removeRetouchItems(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = targets
        menu.addItem(item)
        return menu
    }
    @objc private func removeRetouchItems(_ item: NSMenuItem) {
        if let ids = item.representedObject as? Set<UUID> { model?.removeRetouch(ids); needsDisplay = true }
    }
}
