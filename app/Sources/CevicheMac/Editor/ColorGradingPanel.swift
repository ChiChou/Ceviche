import AppKit
import SwiftUI
import CevicheCore

/// How the color grading section presents the same shadow/midtone/highlight/global values.
enum ColorGradingMode: String, CaseIterable {
    case wheels, global, sliders
    var title: String {
        switch self { case .wheels: L10n.tr("Three-way wheels"); case .global: L10n.tr("Global wheel"); case .sliders: L10n.tr("Sliders") }
    }
    var icon: String {
        switch self { case .wheels: "circle.grid.3x3.circle"; case .global: "circle.circle"; case .sliders: "slider.horizontal.3" }
    }
}

/// One grading range: the wheel edits hue and saturation, the slider below edits luminance.
enum GradingRange: Int, CaseIterable {
    case shadows, midtones, highlights, global
    var title: String { [L10n.tr("Shadows"), L10n.tr("Midtones"), L10n.tr("Highlights"), L10n.tr("Global")][rawValue] }
    var hue: WritableKeyPath<Adjustments, Double> { [\.splitToning.shadowHue, \.splitToning.midtoneHue, \.splitToning.highlightHue, \.splitToning.globalHue][rawValue] }
    var saturation: WritableKeyPath<Adjustments, Double> { [\.splitToning.shadowSaturation, \.splitToning.midtoneSaturation, \.splitToning.highlightSaturation, \.splitToning.globalSaturation][rawValue] }
    var luminance: WritableKeyPath<Adjustments, Double> { [\.splitToning.shadowLuminance, \.splitToning.midtoneLuminance, \.splitToning.highlightLuminance, \.splitToning.globalLuminance][rawValue] }
}

struct ColorGradingPanel: View {
    @ObservedObject var model: EditorModel
    @AppStorage("colorGradingMode") private var mode = ColorGradingMode.wheels
    @State private var sliderRange = GradingRange.shadows
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(ColorGradingMode.allCases, id: \.self) { item in
                    Button { mode = item } label: {
                        Image(systemName: item.icon).font(.system(size: 13)).frame(width: 30, height: 26)
                            .background(mode == item ? Theme.accent.opacity(0.2) : Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                            .foregroundStyle(mode == item ? Theme.accent : .secondary)
                    }.buttonStyle(.plain).help(item.title).accessibilityLabel(item.title).accessibilityAddTraits(mode == item ? .isSelected : [])
                }
                Spacer()
            }
            switch mode {
            case .wheels:
                wheel(.midtones, diameter: 142)
                HStack(alignment: .top, spacing: 14) { wheel(.shadows, diameter: 104); wheel(.highlights, diameter: 104) }
            case .global:
                wheel(.global, diameter: 170)
            case .sliders:
                // Equal-width buttons rather than a segmented control, whose labels would widen the inspector.
                HStack(spacing: 4) {
                    ForEach(GradingRange.allCases, id: \.self) { range in
                        Button { sliderRange = range } label: {
                            Text(range.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity).frame(height: 22)
                                .background(sliderRange == range ? Theme.accent.opacity(0.2) : Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                .foregroundStyle(sliderRange == range ? Theme.accent : .secondary)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(sliderRange == range ? .isSelected : [])
                    }
                }
                slider(L10n.tr("Hue"), sliderRange.hue, 0...360, unit: "°", appearance: .hue)
                slider(L10n.tr("Saturation"), sliderRange.saturation, 0...100, appearance: .saturation(hue(sliderRange)))
                slider(L10n.tr("Luminance"), sliderRange.luminance, appearance: .brightness(hue(sliderRange)))
            }
            Rule().padding(.vertical, 2)
            slider(L10n.tr("Blending"), \.splitToning.blending, 0...100)
            slider(L10n.tr("Balance"), \.splitToning.balance)
        }
    }
    private func hue(_ range: GradingRange) -> Double { model.targetAdjustments[keyPath: range.hue] / 360 }
    private func wheel(_ range: GradingRange, diameter: Double) -> some View {
        let adjustments = model.targetAdjustments
        let saturation = adjustments[keyPath: range.saturation]
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(range.title).foregroundStyle(.secondary)
                if saturation > 0 {
                    Circle().fill(Color(hue: hue(range), saturation: 0.75, brightness: 0.9)).frame(width: 6, height: 6)
                }
                EyedropperButton(model: model, target: .grading(range))
            }.font(.system(size: 11, weight: .medium))
            ColorWheel(hue: Binding(get: { model.targetAdjustments[keyPath: range.hue] }, set: { value in model.editTarget { $0[keyPath: range.hue] = value } }),
                       saturation: Binding(get: { model.targetAdjustments[keyPath: range.saturation] }, set: { value in model.editTarget { $0[keyPath: range.saturation] = value } }),
                       title: range.title, editing: gesture,
                       reset: { model.editTarget { $0[keyPath: range.hue] = model.targetDefaults[keyPath: range.hue]; $0[keyPath: range.saturation] = model.targetDefaults[keyPath: range.saturation] } })
                .frame(width: diameter, height: diameter)
            HStack(spacing: 2) {
                EditableValue(label: String(format: "%.0f°", locale: Locale.current, adjustments[keyPath: range.hue]), value: adjustments[keyPath: range.hue], range: 0...360, title: L10n.tr("\(range.title) hue"), width: 36, size: 10, editing: gesture) { value in model.editTarget { $0[keyPath: range.hue] = value } }
                Text("-")
                EditableValue(label: String(format: "%.0f", locale: Locale.current, saturation), value: saturation, range: 0...100, title: L10n.tr("\(range.title) saturation"), width: 30, size: 10, editing: gesture) { value in model.editTarget { $0[keyPath: range.saturation] = value } }
            }.font(.system(size: 10)).foregroundStyle(saturation > 0 ? .secondary : .tertiary)
            slider(L10n.tr("Luminance"), range.luminance, appearance: .luminance, compact: true)
        }.frame(maxWidth: .infinity)
    }
    private func gesture(_ active: Bool) { if active { model.beginGesture() } else { model.endGesture() } }
    @ViewBuilder private func slider(_ title: String, _ key: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double> = -100...100, unit: String = "", appearance: SliderAppearance? = nil, compact: Bool = false) -> some View {
        let value = Binding(get: { model.targetAdjustments[keyPath: key] }, set: { value in model.editTarget { $0[keyPath: key] = value } })
        let reset = { model.editTarget { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, model.targetDefaults[keyPath: key])) } }
        if compact {
            HStack(spacing: 6) {
                Image(systemName: "sun.max").font(.system(size: 10)).foregroundStyle(.secondary).help(title)
                ResettableSlider(value: value, range: range, title: title, editing: gesture, reset: reset, appearance: appearance ?? .luminance).frame(height: 18)
                EditableValue(label: String(format: "%+.0f", locale: Locale.current, value.wrappedValue), value: value.wrappedValue, range: range, title: title, width: 34, size: 10, editing: gesture) { value.wrappedValue = $0 }
                    .foregroundStyle(value.wrappedValue == 0 ? .secondary : .primary)
            }
        } else {
            AdjustmentSlider(title: title, value: value, range: range, unit: unit, editing: gesture, reset: reset, appearance: appearance)
        }
    }
}

/// Hue runs counterclockwise from red at 3 o'clock; distance from the center is saturation (0–100).
/// Drag to place the puck. Shift keeps the hue, Control keeps the saturation, Option gives fine control; double-click resets.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    let title: String
    let editing: (Bool) -> Void
    let reset: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragStart: (hue: Double, saturation: Double, location: CGPoint)?
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height), radius = size / 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let angle = hue * .pi / 180, distance = min(1, saturation / 100) * radius
            let puck = CGPoint(x: center.x + cos(angle) * distance, y: center.y - sin(angle) * distance)
            ZStack {
                Circle().fill(AngularGradient(colors: stride(from: 1.0, through: 0, by: -1.0 / 12).map { Color(hue: $0, saturation: 0.85, brightness: 0.9) }, center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.82), Color(white: 0.82).opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: center.x - 5, y: center.y)); path.addLine(to: CGPoint(x: center.x + 5, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - 5)); path.addLine(to: CGPoint(x: center.x, y: center.y + 5))
                }.stroke(.black.opacity(0.3), lineWidth: 1)
                Circle().fill(saturation > 0 ? Color(hue: hue / 360, saturation: min(1, saturation / 100), brightness: 0.95) : Color(white: 0.92))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(puck)
            }
            .frame(width: size, height: size).position(center)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard isEnabled else { return }
                if dragStart == nil { dragStart = (hue, saturation, value.startLocation); editing(true) }
                update(value.location, center: center, radius: radius)
            }.onEnded { _ in dragStart = nil; editing(false) })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if isEnabled { reset() } })
        }
        .help(L10n.tr("Drag to set \(title.lowercased()) hue and saturation - Shift changes saturation only - Control changes hue only - Option for fine control - double-click to reset"))
        .accessibilityElement()
        .accessibilityLabel(L10n.tr("\(title) color wheel"))
        .accessibilityValue(saturation > 0 ? L10n.tr("Hue \(hue, specifier: "%.0f") degrees, saturation \(saturation, specifier: "%.0f")") : L10n.tr("Neutral"))
        .accessibilityAdjustableAction { direction in
            saturation = min(100, max(0, saturation + (direction == .increment ? 5 : -5)))
        }
    }
    private func update(_ location: CGPoint, center: CGPoint, radius: Double) {
        guard let start = dragStart, radius > 0 else { return }
        let flags = NSEvent.modifierFlags
        var target = location
        if flags.contains(.option) {
            // Fine control moves the puck a quarter of the pointer distance from where it started.
            let a = start.hue * .pi / 180, d = start.saturation / 100 * radius
            target = CGPoint(x: center.x + cos(a) * d + (location.x - start.location.x) / 4, y: center.y - sin(a) * d + (location.y - start.location.y) / 4)
        }
        let dx = target.x - center.x, dy = center.y - target.y
        let newSaturation = min(100, (hypot(dx, dy) / radius * 100).rounded())
        if flags.contains(.shift) && start.saturation > 0 {
            saturation = newSaturation
        } else if flags.contains(.control) {
            hue = ((atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)).rounded()
        } else {
            let degrees = atan2(dy, dx) * 180 / .pi
            hue = ((degrees + 360).truncatingRemainder(dividingBy: 360)).rounded()
            saturation = newSaturation
        }
    }
}
