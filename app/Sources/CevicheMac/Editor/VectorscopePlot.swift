import SwiftUI
import CevicheCore

/// The vectorscope: hue around the circle and saturation out from the centre, inside a rim of hues with a dot on each
/// primary and secondary, with sRGB's outline at 100 %, 75 % and 25 % and the skin tone line.
struct VectorscopePlot: View {
    @ObservedObject var model: EditorModel
    @Binding var probe: CGPoint?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        GeometryReader { geometry in plot(Layout(size: geometry.size, zoom: model.scopeOptions.vectorZoom ? 2 : 1)) }
    }
    /// Where the round plot sits in the plate, and how chroma maps onto it.
    private struct Layout {
        let square: CGRect, centre: CGPoint, side: Double, zoom: Double
        /// Points per unit of chroma: `chromaReach` reaches the circle's edge at 1×.
        let unit: Double
        init(size: CGSize, zoom: Double) {
            // Room for the target dots, which grow with the plot (side / 34), to sit on the rim unclipped.
            side = max(1, (min(size.width, size.height) - 4) * 17 / 18)
            square = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            centre = CGPoint(x: square.midX, y: square.midY)
            self.zoom = zoom
            unit = side / 2 / Scopes.chromaReach * zoom
        }
        func point(_ cb: Double, _ cr: Double) -> CGPoint { CGPoint(x: centre.x + cb * unit, y: centre.y - cr * unit) }
    }
    private func plot(_ layout: Layout) -> some View {
        let square = layout.square, centre = layout.centre, side = layout.side, zoom = layout.zoom, unit = layout.unit
        let point = layout.point
        return Canvas { context, _ in
                let display = model.scopeDisplay(.vectorscope)
                var clipped = context
                clipped.clip(to: Path(ellipseIn: square.insetBy(dx: -1, dy: -1)))
                let faint = Color.white.opacity(0.08)
                var cross = Path()
                cross.move(to: CGPoint(x: square.minX, y: centre.y)); cross.addLine(to: CGPoint(x: square.maxX, y: centre.y))
                cross.move(to: CGPoint(x: centre.x, y: square.minY)); cross.addLine(to: CGPoint(x: centre.x, y: square.maxY))
                clipped.stroke(cross, with: .color(faint))
                if let display {
                    var layer = clipped
                    layer.blendMode = .screen
                    let size = side * zoom
                    layer.draw(Image(decorative: display.image, scale: 1).interpolation(.high),
                               in: CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size))
                }
                // sRGB's outline at 100 %, 75 % and 25 %: where colours run out of the gamut, and the reference most
                // photos' colours fall around (the only one left inside at 2×).
                for (fraction, opacity) in [(1.0, 0.24), (0.75, 0.12), (0.25, 0.1)] {
                    var hexagon = Path()
                    for (index, target) in Scopes.targets.enumerated() {
                        let p = point(target.cb * fraction, target.cr * fraction)
                        if index == 0 { hexagon.move(to: p) } else { hexagon.addLine(to: p) }
                    }
                    hexagon.closeSubpath()
                    clipped.stroke(hexagon, with: .color(Color.white.opacity(opacity)), lineWidth: 1)
                }
                // The rim shows each direction's hue, so colours read without labels; a dot in each target's own
                // colour marks red, yellow, green, cyan, blue and magenta. Angles don't change with the zoom.
                let radius = side / 2, ring = max(2.5, side / 70)
                func rim(_ angle: Double, _ inset: Double = 0) -> CGPoint {
                    CGPoint(x: centre.x + cos(angle) * (radius - inset), y: centre.y - sin(angle) * (radius - inset))
                }
                let segments = 120
                for index in 0..<segments {
                    let from = Double(index) / Double(segments) * 2 * .pi, to = Double(index + 1) / Double(segments) * 2 * .pi
                    var arc = Path()
                    arc.addArc(center: centre, radius: radius - ring / 2, startAngle: .radians(-from), endAngle: .radians(-to - 0.01), clockwise: true)
                    context.stroke(arc, with: .color(Self.hue(at: (from + to) / 2).opacity(0.85)), lineWidth: ring)
                }
                // Skin tone line from the centre to the rim, ending in a person, as on photo editors' scopes.
                let skin = Scopes.skinLineAngle, dot = max(3.5, side / 34)
                var line = Path(); line.move(to: centre); line.addLine(to: rim(skin, ring))
                clipped.stroke(line, with: .color(Color.white.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                for target in Scopes.targets {
                    let p = rim(atan2(target.cr, target.cb), ring / 2)
                    let disc = Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
                    context.fill(disc, with: .color(Self.hue(at: atan2(target.cr, target.cb))))
                    context.stroke(disc, with: .color(Color.black.opacity(0.6)), lineWidth: 1)
                }
                let person = rim(skin, ring / 2), badge = dot * 1.25
                context.fill(Path(ellipseIn: CGRect(x: person.x - badge, y: person.y - badge, width: badge * 2, height: badge * 2)), with: .color(Color(white: 0.12)))
                var icon = context.resolve(Image(systemName: "person.fill"))
                icon.shading = .color(Color(.sRGB, red: 0.95, green: 0.76, blue: 0.62))
                context.draw(icon, in: CGRect(x: person.x - badge * 0.6, y: person.y - badge * 0.62, width: badge * 1.2, height: badge * 1.2))
                if let probe {
                    let p = point(probe.x, probe.y)
                    clipped.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Theme.accent.opacity(0.9)), lineWidth: 1)
                }
            }
            .background(scopePlate(colorScheme)).contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location) where model.hasImage && hypot(location.x - centre.x, location.y - centre.y) <= side / 2:
                    // Probe in chroma units: x is Cb, y is Cr.
                    probe = CGPoint(x: (location.x - centre.x) / unit, y: (centre.y - location.y) / unit)
                default: probe = nil
                }
            }
            .accessibilityLabel(EditorScope.vectorscope.title)
    }
    /// The fully saturated colour in a direction of the plot (radians from +Cb, counter-clockwise).
    static func hue(at angle: Double) -> Color {
        let cb = cos(angle) * 0.3, cr = sin(angle) * 0.3
        let r = 0.5 + 1.5748 * cr, b = 0.5 + 1.8556 * cb, g = (0.5 - 0.2126 * r - 0.0722 * b) / 0.7152
        let low = min(r, g, b), span = max(0.0001, max(r, g, b) - low)
        return Color(.sRGB, red: (r - low) / span, green: (g - low) / span, blue: (b - low) / span)
    }
    /// Hue in degrees and saturation as a share of the sRGB edge in that direction.
    static func reading(_ probe: CGPoint) -> String {
        let reading = Scopes.reading(cb: probe.x, cr: probe.y)
        return String(format: "%.0f°  %.0f%%", locale: Locale.current, reading.hue, reading.saturation * 100)
    }
}
