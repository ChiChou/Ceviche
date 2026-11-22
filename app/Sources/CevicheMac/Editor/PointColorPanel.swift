import SwiftUI
import CevicheCore

struct PointColorPanel: View {
    @ObservedObject var model: EditorModel
    @State private var selected = 0
    private var points: [PointColor] { model.targetAdjustments.pointColors }
    var body: some View {
        VStack(spacing: 8) {
            // Colors come from the photo itself, so every target exists in the file.
            HStack {
                Text(points.count >= 16 ? L10n.tr("16 colors maximum") : L10n.tr("Pick a color from the photo")).foregroundStyle(.secondary)
                Spacer()
                EyedropperButton(model: model, target: .pointColor).disabled(points.count >= 16)
            }
            if !points.isEmpty {
                Picker(L10n.tr("Color"), selection: $selected) { ForEach(points.indices, id: \.self) { i in Text(L10n.tr("\(i+1) - \(Int(points[i].hue*360))°")).tag(i) } }
                adjustment("Hue", \.hueShift, -1...1)
                adjustment("Saturation", \.saturationShift, -1...1)
                adjustment("Luminance", \.luminanceShift, -1...1)
                adjustment("Range", \.range, 0...1)
                adjustment("Variance", \.variance, -100...100)
                Button(L10n.tr("Remove color")) { model.editTarget { a in if a.pointColors.indices.contains(selected) { a.pointColors.remove(at: selected) } }; selected = max(0, min(selected, points.count - 1)) }
            }
        }.font(.system(size: 11)).controlSize(.small)
        .onChange(of: points.count) { old, count in selected = count > old ? count - 1 : max(0, min(selected, count - 1)) }
    }
    /// `title` is the slider's key; AdjustmentSlider shows it translated and picks the track colors from it.
    private func adjustment(_ title: String, _ key: WritableKeyPath<PointColor, Double>, _ range: ClosedRange<Double>) -> some View {
        let index = min(selected, max(0, points.count - 1))
        let hue = points.indices.contains(index) ? points[index].hue : 0
        return AdjustmentSlider(title: title, value: Binding(get: { points.indices.contains(index) ? points[index][keyPath: key] : 0 }, set: { v in model.editTarget { a in if a.pointColors.indices.contains(index) { a.pointColors[index][keyPath: key] = v } } }), range: range, unit: range.upperBound <= 1 ? "fraction" : "", editing: { active in if active { model.beginGesture() } else { model.endGesture() } }, reset: { model.editTarget { a in if a.pointColors.indices.contains(index) { a.pointColors[index][keyPath: key] = PointColor()[keyPath: key] } } }, appearance: title == "Hue" ? .hueShift(hue) : title == "Saturation" ? .saturation(hue) : title == "Luminance" ? .brightness(hue) : .neutral)
    }
}
