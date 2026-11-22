import SwiftUI
import CevicheCore

/// A percentage slider of the Remove and Portrait panels, with its name and value above it. `gesture` makes one drag a
/// single undo step, for values that are part of the edit; `ended` runs when that drag is over. A measured correction
/// adds `measure` (a wand that measures it again) and `remove`; `resetTo` is what a double-click on the slider puts back.
/// `label` replaces the shown percentage, as a dash where the selected people differ.
struct RetouchSlider: View {
    let model: EditorModel
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var gesture = false
    var ended: (() -> Void)? = nil
    var resetTo: Double? = nil
    var label: String? = nil
    var measure: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(title); Spacer()
                EditableValue(label: label ?? "\(Int((value.wrappedValue * 100).rounded()))%", value: value.wrappedValue, range: range, scale: 100,
                              title: title, width: 56, size: 12) { value.wrappedValue = $0 }.foregroundStyle(.secondary)
                if let measure {
                    Button(action: measure) { Image(systemName: "wand.and.stars").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Measure Again")).accessibilityLabel(L10n.tr("Measure Again"))
                }
                if let remove { RemoveButton(action: remove) }
            }
            FormSlider(value: value, in: range, reset: resetTo.map { v in { value.wrappedValue = v } }) { editing in
                guard gesture else { return }
                if editing { model.beginGesture() } else { model.endGesture(); ended?() }
            }
        }
    }
}

/// A correction's row before it is made, or one that is an action rather than a value (Red eye): its name, a note such
/// as Whole photo, and a button (Auto, Fix, Remove). The name is dimmed until the correction is on.
struct CorrectionRow: View {
    let title: String
    var note: String? = nil
    var on = false
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(on ? .primary : .secondary)
            if let note { Text(note).font(.system(size: 10)).foregroundStyle(.tertiary) }
            Spacer()
            Button(button, action: action).buttonStyle(.secondaryAction).controlSize(.small)
        }
    }
}

/// Takes something made out, as if it had never been made.
struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help(L10n.tr("Remove")).accessibilityLabel(L10n.tr("Remove"))
    }
}
