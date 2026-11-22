import SwiftUI
import CevicheCore

/// The dark plate scopes are drawn on, in both palettes: channels and colours add up by light, which only reads on dark.
func scopePlate(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.black.opacity(0.12) : Color(white: 0.16) }

/// A waveform in the histogram's place, with its graticule and a level line under the pointer.
struct ScopePlot: View {
    @ObservedObject var model: EditorModel
    /// Waveform or Parade.
    let scope: EditorScope
    @Binding var probe: CGPoint?
    @Environment(\.colorScheme) private var colorScheme
    /// The plot sits a little inside the plate so traces at black and white aren't hidden by its edge.
    static let inset: CGFloat = 3
    var body: some View {
        GeometryReader { geometry in
            let plot = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 0, dy: Self.inset)
            Canvas { context, _ in
                let display = model.scopeDisplay(scope)
                let stops = display?.hdrStops
                func level(_ fraction: Double, _ color: Color, dash: [CGFloat] = []) {
                    let y = plot.maxY - plot.height * fraction
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
                }
                if let stops {
                    // SDR in the lower half, as on the HDR histogram: SDR white solid, each stop above it dashed.
                    for f in [0.125, 0.25, 0.375] { level(f, Color.white.opacity(0.06)) }
                    for stop in 1..<max(1, Int(ceil(max(1, stops)))) { level(0.5 + 0.5 * Double(stop) / max(1, stops), Color.white.opacity(0.3), dash: [3, 3]) }
                } else {
                    for f in [0.25, 0.5, 0.75] { level(f, Color.white.opacity(0.07)) }
                }
                if let display {
                    var layer = context
                    layer.blendMode = .screen
                    layer.draw(Image(decorative: display.image, scale: 1).interpolation(.high), in: plot)
                }
                if stops != nil { level(0.5, Color.white.opacity(0.6)) }
                if scope == .parade {
                    // The three channels side by side, divided by hairlines.
                    for pane in 1..<3 {
                        let x = plot.minX + plot.width * Double(pane) / 3
                        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: plot.maxY + Self.inset))
                        context.stroke(line, with: .color(Color.white.opacity(0.14)), lineWidth: 1)
                    }
                }
                if let probe { level(probe.y, Theme.accent.opacity(0.8)) }
            }
            .background(scopePlate(colorScheme)).contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where model.hasImage:
                    probe = CGPoint(x: min(1, max(0, point.x / max(1, plot.width))), y: min(1, max(0, (plot.maxY - point.y) / max(1, plot.height))))
                default: probe = nil
                }
            }
            .accessibilityLabel(scope.title)
        }
    }
    /// The level under the pointer: percent of white, or for HDR the stops above SDR white; on the parade, after the
    /// channel's initial.
    static func reading(_ probe: CGPoint, scope: EditorScope, model: EditorModel) -> String {
        let stops = model.scopeDisplay(scope)?.hdrStops
        let value: String
        if let stops, probe.y > 0.5 { value = String(format: "%+.1f EV", locale: Locale.current, (probe.y - 0.5) * 2 * max(1, stops)) }
        else { value = String(format: "%.0f%%", locale: Locale.current, (stops == nil ? probe.y : probe.y * 2) * 100) }
        guard scope == .parade else { return value }
        return ["R", "G", "B"][min(2, Int(probe.x * 3))] + " " + value
    }
}

/// The scopes under the histogram, one at a time: choosing the one that is on turns it off. Zones, which draws on the
/// photo rather than here, is its own toggle at the end.
struct ScopeTabs: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorScope.allCases, id: \.self) { scope in
                let on = model.scope == scope
                tab(scope.title, on: on) { model.scope = on ? nil : scope }
            }
            Rectangle().fill(Theme.ink.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 2)
            tab(L10n.tr("Zones"), on: model.zonesShown, fill: false, action: model.toggleZones)
                .help(L10n.tr("Zones (⌥⌘Z)"))
        }
    }
    private func tab(_ title: String, on: Bool, fill: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, fill ? 4 : 6)
                .frame(maxWidth: fill ? .infinity : nil).frame(height: 22)
                .background(on ? Theme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A scope's one option as a lit badge: Y for a luma-only waveform, a magnifier for a zoomed vectorscope. Lit while on, so
/// the state shows at a glance without opening anything.
struct ScopeOptionToggle: View {
    @ObservedObject var model: EditorModel
    let scope: EditorScope
    @State private var hovered = false
    var body: some View {
        if let option {
            let on = model.scopeOptions[keyPath: option.key]
            Button { model.scopeOptions[keyPath: option.key].toggle() } label: {
                Group {
                    if let icon = option.icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                    else { Text(option.badge).font(.system(size: 9, weight: .bold, design: .monospaced)) }
                }
                    .foregroundStyle(on ? Color.black.opacity(0.85) : Color.white.opacity(hovered ? 0.9 : 0.7))
                    .frame(minWidth: 20, minHeight: 15).padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(Color.white.opacity(on ? 0.85 : hovered ? 0.12 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Color.white.opacity(on ? 0 : 0.3)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovered = $0 }
            .help(option.title).accessibilityLabel(option.title).accessibilityAddTraits(on ? .isSelected : [])
        }
    }
    /// Luma reads as the video letter Y; the zoom as a magnifier.
    private var option: (key: WritableKeyPath<ScopeOptions, Bool>, badge: String, icon: String?, title: String)? {
        switch scope {
        case .waveform: (\.waveformLuma, "Y", nil, L10n.tr("Luma"))
        case .vectorscope: (\.vectorZoom, "", "plus.magnifyingglass", L10n.tr("Zoom 2×"))
        case .parade: nil
        }
    }
}
