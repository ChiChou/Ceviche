import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

struct HistogramView: View {
    @ObservedObject var model: EditorModel
    @State private var hovered: HistogramRegion?
    @State private var dragging: HistogramRegion?
    @State private var capture = PhotoMetadataSummary()
    @Environment(\.colorScheme) private var colorScheme
    private var region: HistogramRegion? { dragging ?? hovered }
    private var enabled: Bool { model.hasImage && !model.busy && !model.adjustments.disabledSections.contains(.light) }
    /// The HDR histogram: SDR in the left half, the stops above white in the right, with range bars below.
    private var hdrStops: Double? { model.curveHDRStops }
    @State private var plateHovered = false
    /// Where the pointer is over a scope, as a fraction of the plot from its bottom-left.
    @State private var probe: CGPoint?
    var body: some View {
        VStack(spacing: 5) {
            // The plates grow with the panel: levels keep a wide strip, the vectorscope stays round.
            histogram.aspectRatio(Self.levelsAspect, contentMode: .fit)
            footer
            // Capture settings under the histogram, as in other RAW editors; the Info panel has the rest.
            let details = [capture.iso, capture.focalLength, capture.aperture, capture.shutter].compactMap { $0 }
            if !details.isEmpty {
                HStack { ForEach(details, id: \.self) { Text($0); if $0 != details.last { Spacer() } } }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).frame(height: 10)
            }
            ScopeTabs(model: model).padding(.top, 5)
            if let scope = model.scope { plot(scope) }
        }
        .task(id: model.sourceURL) {
            guard let url = model.sourceURL else { capture = PhotoMetadataSummary(); return }
            capture = await Task.detached(priority: .utility) { PhotoMetadataSummary(url: url) }.value
        }
        .onChange(of: model.scope) { probe = nil; hovered = nil }
    }
    /// Width over height of the histogram, waveform and parade plates.
    static let levelsAspect = 3.2
    /// The scope under the tabs, with its option in the top-left corner and the reading under the pointer in the
    /// bottom-right.
    private func plot(_ scope: EditorScope) -> some View {
        Group {
            switch scope {
            case .waveform, .parade: ScopePlot(model: model, scope: scope, probe: $probe).aspectRatio(Self.levelsAspect * 0.8, contentMode: .fit)
            case .vectorscope: VectorscopePlot(model: model, probe: $probe).aspectRatio(1, contentMode: .fit)
            }
        }
        .onHover { plateHovered = $0 }
        .overlay(alignment: .topLeading) {
            // It stays fully visible while on.
            ScopeOptionToggle(model: model, scope: scope).padding(4).opacity(plateHovered || model.scopeOptionOn(scope) ? 1 : 0.45)
        }
        .overlay(alignment: .bottomTrailing) {
            if let probe {
                Text(scope == .vectorscope ? VectorscopePlot.reading(probe) : ScopePlot.reading(probe, scope: scope, model: model))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                    .padding(5).allowsHitTesting(false)
            }
        }
    }
    @ViewBuilder private var footer: some View {
        HStack {
            if let region, enabled {
                let value = model.targetAdjustments[keyPath: region.key]
                Spacer()
                Text(region.title + " " + (region == .exposure ? String(format: "%+.2f EV", locale: Locale.current, value) : String(format: "%+.0f", locale: Locale.current, value))).foregroundStyle(Theme.accent)
                Spacer()
            } else if let stops = hdrStops {
                Text(L10n.tr("SDR")).frame(maxWidth: .infinity)
                Text(L10n.tr("HDR")).frame(maxWidth: .infinity)
                    .help(L10n.tr("Up to \(stops, specifier: "%.1f") stops above SDR white (HDR limit)"))
            } else {
                Text("0"); Spacer(); Text(L10n.tr("RGB")); Spacer(); Text("255")
            }
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(height: 12)
    }
    private var histogram: some View {
            GeometryReader { geometry in
                Canvas { context, size in
                    let stops = hdrStops
                    let graph = CGSize(width: size.width, height: stops == nil ? size.height : size.height - 7)
                    if let region, enabled {
                        let rect = CGRect(x: size.width * Double(region.rawValue) / 5, y: 0, width: size.width / 5, height: graph.height)
                        context.fill(Path(rect), with: .color(Color.white.opacity(0.09)))
                    }
                    func vertical(_ x: Double, _ color: Color, dash: [CGFloat] = []) {
                        var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: graph.height))
                        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
                    }
                    if stops == nil { for i in 1..<5 { vertical(size.width * Double(i) / 5, Color.white.opacity(0.06)) } }
                    for (channel, bins) in model.histogram.enumerated() where bins.count > 1 {
                        var path = Path(); path.move(to: CGPoint(x: 0, y: graph.height))
                        for (index, value) in bins.enumerated() { path.addLine(to: CGPoint(x: Double(index) / Double(bins.count - 1) * size.width, y: graph.height * (1 - value * 0.94))) }
                        path.addLine(to: CGPoint(x: size.width, y: graph.height)); path.closeSubpath()
                        context.blendMode = .screen
                        context.fill(path, with: .color([Color.red, .green, .blue][channel].opacity(0.42)))
                    }
                    context.blendMode = .normal
                    if let stops {
                        let mid = size.width / 2
                        // SDR white is solid; each whole stop above it is dashed, as in other RAW editors.
                        vertical(mid, Color.white.opacity(0.7))
                        let marks = (1..<max(1, Int(ceil(stops)))).map { mid + mid * Double($0) / stops }
                        for x in marks { vertical(x, Color.white.opacity(0.45), dash: [3, 3]) }
                        // Range bars: SDR up to white, HDR from white to the output headroom, broken at the stops.
                        let y = size.height - 2
                        func bar(_ from: Double, _ to: Double) {
                            guard to - from > 2 else { return }
                            var line = Path(); line.move(to: CGPoint(x: from, y: y)); line.addLine(to: CGPoint(x: to, y: y))
                            context.stroke(line, with: .color(Color.white.opacity(0.75)), lineWidth: 2)
                        }
                        bar(0, mid - 3)
                        var start = mid + 3
                        for x in marks { bar(start, x - 3); start = x + 3 }
                        bar(start, size.width)
                    }
                }
                // Channels add up by screen blending, which only reads on a dark plate: on the light palette's panel
                // they washed out to pastels. The plate is dark in both palettes, as the photo's own tones are.
                .background(scopePlate(colorScheme)).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = HistogramRegion.at(point.x / max(1, geometry.size.width))
                    case .ended: hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    guard enabled else { return }
                    if dragging == nil {
                        let selected = HistogramRegion.at(value.startLocation.x / max(1, geometry.size.width))
                        dragging = selected; model.beginHistogramDrag(selected)
                    }
                    model.updateHistogramDrag(translation: value.translation.width / max(1, geometry.size.width))
                }.onEnded { _ in model.endHistogramDrag(); dragging = nil })
                .help(hdrStops == nil ? L10n.tr("Drag left or right: Blacks - Shadows - Exposure - Highlights - Whites") : L10n.tr("SDR tones on the left, stops above SDR white on the right. Drag left or right: Blacks - Shadows - Exposure - Highlights - Whites"))
                .accessibilityLabel(L10n.tr("Interactive histogram: drag a tonal region horizontally to adjust it"))
            }
        }
}
