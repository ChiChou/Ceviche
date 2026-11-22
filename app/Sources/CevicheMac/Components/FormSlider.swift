import AppKit
import SwiftUI

/// A bounded form value or playback position, with native tracking and keyboard adjustment.
/// Double-click resets only when given a `reset`: a form value may have no natural place to go back to.
struct FormSlider: NSViewRepresentable {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void
    /// A double-click puts the value back, as on Light & Color's sliders; nil keeps double-clicks plain.
    var reset: (() -> Void)?
    init(value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double? = nil, reset: (() -> Void)? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.bounds = bounds; self.step = step; self.reset = reset; self.onEditingChanged = onEditingChanged
    }
    func makeNSView(context: Context) -> FormSliderView {
        let view = FormSliderView()
        view.cell = FormSliderCell()
        view.controlSize = .small; view.isContinuous = true
        view.target = view; view.action = #selector(FormSliderView.changed)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: FormSliderView, context: Context) {
        view.minValue = bounds.lowerBound; view.maxValue = bounds.upperBound
        view.doubleValue = value; view.isEnabled = context.environment.isEnabled
        view.step = step; view.onChange = { value = $0 }; view.onEditing = onEditingChanged; view.onReset = reset
        view.needsDisplay = true
    }
}

final class FormSliderView: NSSlider {
    var step: Double?
    var onChange: (Double) -> Void = { _ in }
    var onEditing: (Bool) -> Void = { _ in }
    var onReset: (() -> Void)?
    @objc func changed() {
        if let step, step > 0 {
            doubleValue = min(maxValue, max(minValue, minValue + ((doubleValue - minValue) / step).rounded() * step))
        }
        onChange(doubleValue)
    }
    func move(by direction: Double) -> Bool {
        guard isEnabled, let step else { return false }
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * step))
        onEditing(true); changed(); onEditing(false)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if [123, 125].contains(event.keyCode), move(by: -1) { return }
        if [124, 126].contains(event.keyCode), move(by: 1) { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let onReset { onEditing(true); onReset(); onEditing(false); return }
        onEditing(true); super.mouseDown(with: event); onEditing(false)
    }
}

final class FormSliderCell: ContextSliderCell {
    override func accessibilityPerformIncrement() -> Bool {
        if let view = controlView as? FormSliderView, view.step != nil { return view.move(by: 1) }
        return super.accessibilityPerformIncrement()
    }
    override func accessibilityPerformDecrement() -> Bool {
        if let view = controlView as? FormSliderView, view.step != nil { return view.move(by: -1) }
        return super.accessibilityPerformDecrement()
    }
}
