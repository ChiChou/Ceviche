import AppKit
import SwiftUI
import CevicheCore

/// Regions stay locked to the initial mouse-down position throughout a histogram drag.
enum HistogramRegion: Int, CaseIterable {
    case blacks, shadows, exposure, highlights, whites
    var title: String { [L10n.tr("Blacks"), L10n.tr("Shadows"), L10n.tr("Exposure"), L10n.tr("Highlights"), L10n.tr("Whites")][rawValue] }
    var key: WritableKeyPath<Adjustments, Double> {
        switch self {
        case .blacks: return \.blacks
        case .shadows: return \.shadows
        case .exposure: return \.exposure
        case .highlights: return \.highlights
        case .whites: return \.whites
        }
    }
    var range: ClosedRange<Double> { self == .exposure ? -5...5 : -100...100 }
    static func at(_ fraction: Double) -> Self { Self(rawValue: max(0, min(4, Int(fraction * 5))))! }
    func adjusted(start: Double, translation: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, start + translation * (self == .exposure ? 10 : 200)))
    }
}

/// Intercept native double clicks before NSSlider tracking can swallow the event.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let title: String
    let editing: (Bool) -> Void
    let reset: () -> Void
    var appearance: SliderAppearance = .neutral
    func makeNSView(context: Context) -> DoubleClickSlider {
        let view = DoubleClickSlider()
        view.cell = ContextSliderCell()
        view.controlSize = .mini
        view.isContinuous = true
        view.target = view; view.action = #selector(DoubleClickSlider.changed)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: DoubleClickSlider, context: Context) {
        view.minValue = range.lowerBound; view.maxValue = range.upperBound
        view.doubleValue = value; view.isEnabled = context.environment.isEnabled
        (view.cell as? ContextSliderCell)?.appearance = appearance
        view.needsDisplay = true
        view.setAccessibilityLabel(L10n.key(title))
        view.toolTip = L10n.tr("Double-click to reset \(L10n.key(title))")
        view.onChange = { value = $0 }; view.onEditing = editing; view.onReset = reset
    }
}

final class DoubleClickSlider: NSSlider {
    var onChange: (Double) -> Void = { _ in }
    var onEditing: (Bool) -> Void = { _ in }
    var onReset: () -> Void = {}
    @objc func changed() { onChange(doubleValue) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 { onReset(); return }
        onEditing(true)
        super.mouseDown(with: event)
        onEditing(false)
    }
}

/// A value readout that becomes a text field on click. Enter commits the number, clamped to the range;
/// Escape cancels; clicking anywhere else, or the window losing focus, commits what was typed.
/// `scale` is display units per stored unit (100 for a 0–1 percent).
struct EditableValue: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var scale: Double = 1
    var precision: Int = 0
    var title: String
    var width: CGFloat = 56
    var size: CGFloat = 11
    var editing: (Bool) -> Void = { _ in }
    let commit: (Double) -> Void
    @State private var draft: String?
    var body: some View {
        Group {
            if let draft {
                ValueField(text: draft, size: size, finish: finish)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Theme.accent.opacity(0.6)))
            } else {
                Text(label).font(.system(size: size)).monospacedDigit().padding(.horizontal, 3).padding(.vertical, 1).contentShape(Rectangle())
                    .onTapGesture { draft = String(format: "%.\(precision)f", locale: Locale.current, value * scale) }
                    .help(L10n.tr("Click to type a value"))
                    .accessibilityAddTraits(.isButton)
            }
        }.frame(width: width, alignment: .trailing).lineLimit(1)
            .accessibilityLabel(L10n.tr("\(L10n.key(title)) value")).accessibilityValue(label)
    }
    private func finish(_ typed: String?) {
        guard draft != nil else { return }
        draft = nil
        guard let typed else { return }
        let digits = typed.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) }
        guard let number = Double(digits) else { return }
        let clamped = min(range.upperBound, max(range.lowerBound, number / scale))
        guard clamped != value else { return }
        editing(true); commit(clamped); editing(false)
    }
}

/// SwiftUI's focus state does not drop when the user clicks a slider or the photo, so the field itself
/// watches for clicks outside its bounds and for the window resigning key, and reports once.
private struct ValueField: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let finish: (String?) -> Void
    func makeNSView(context: Context) -> ValueTextField {
        let field = ValueTextField()
        field.stringValue = text
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        field.alignment = .right
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.cell?.wraps = false; field.cell?.isScrollable = true; field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.onFinish = finish
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }
    func updateNSView(_ field: ValueTextField, context: Context) { field.onFinish = finish }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? ValueTextField else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) { field.finish(field.stringValue); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { field.finish(nil); return true }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? ValueTextField else { return }
            field.finish(field.stringValue)
        }
    }
}

final class ValueTextField: NSTextField {
    var onFinish: (String?) -> Void = { _ in }
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var finished = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { finish(stringValue) }
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            finish(stringValue)
        }
    }
    func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        stopWatching()
        onFinish(value)
    }
    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    }
    deinit { stopWatching() }
}

struct CurveView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> CurveControl { CurveControl() }
    func updateNSView(_ view: CurveControl, context: Context) {
        view.model = model; view.isEnabled = context.environment.isEnabled
        view.needsDisplay = true
    }
}

/// AppKit mouse events distinguish insertion, dragging, double-click removal and context menus.
final class CurveControl: NSView {
    weak var model: EditorModel?
    var isEnabled = true
    private var selected: Int?
    private var menuPoint: Int?
    override var isFlipped: Bool { true }
    private var graph: NSRect { bounds.insetBy(dx: 7, dy: 7) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = L10n.tr("Click to add a point. Drag to move. Double-click or right-click an interior point to remove. With HDR, the right half is the range above SDR white, in stops.")
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.tr("Editable tone curve"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .crosshair) } }
    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }
    /// HDR shows SDR in the left half and the stops above white in the right half, like the HDR histogram.
    private var stops: Double? { model?.curveHDRStops }
    private func fraction(_ value: Double) -> Double {
        guard let stops else { return value }
        return value <= 1 ? value * 0.5 : 0.5 + (value - 1) / (2 * stops)
    }
    private func value(_ fraction: Double) -> Double {
        guard let stops else { return fraction }
        return fraction <= 0.5 ? fraction * 2 : 1 + (fraction - 0.5) * 2 * stops
    }
    private func normalized(_ point: NSPoint) -> CurvePoint {
        CurvePoint(x: value(min(1, max(0, (point.x - graph.minX) / max(1, graph.width)))),
                   y: value(min(1, max(0, 1 - (point.y - graph.minY) / max(1, graph.height)))))
    }
    private func screen(_ point: CurvePoint) -> NSPoint {
        NSPoint(x: graph.minX + fraction(point.x) * graph.width, y: graph.minY + (1 - min(1, fraction(point.y))) * graph.height)
    }
    /// Points beyond SDR white are hidden (and kept) while editing SDR.
    private func visible(_ point: CurvePoint) -> Bool { point.x <= (model?.curveUpperInput ?? 1) }
    func hitPoint(_ location: NSPoint) -> Int? {
        guard let points = model?.selectedCurve.points else { return nil }
        return points.indices.filter { visible(points[$0]) }.min(by: {
            let a = screen(points[$0]), b = screen(points[$1])
            return hypot(a.x - location.x, a.y - location.y) < hypot(b.x - location.x, b.y - location.y)
        }).flatMap { index in
            let point = screen(points[index])
            return hypot(point.x - location.x, point.y - location.y) <= 10 ? index : nil
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let curve = model?.selectedCurve else { return }
        NSColor.black.withAlphaComponent(0.16).setFill(); NSBezierPath(rect: graph).fill()
        let grid = NSBezierPath()
        // Quarters of the SDR range, plus one line per stop above white when editing HDR.
        var lines = (0...4).map { fraction(Double($0) / 4) }
        if let stops { lines += (1...Int(stops.rounded(.up))).map { fraction(1 + min(stops, Double($0))) } }
        for t in lines {
            grid.move(to: NSPoint(x: graph.minX + t * graph.width, y: graph.minY)); grid.line(to: NSPoint(x: graph.minX + t * graph.width, y: graph.maxY))
            grid.move(to: NSPoint(x: graph.minX, y: graph.maxY - t * graph.height)); grid.line(to: NSPoint(x: graph.maxX, y: graph.maxY - t * graph.height))
        }
        Theme.nsInk.withAlphaComponent(0.07).setStroke(); grid.lineWidth = 1; grid.stroke()
        if stops != nil {
            let white = NSBezierPath(), w = screen(CurvePoint(x: 1, y: 1))
            white.move(to: NSPoint(x: w.x, y: graph.minY)); white.line(to: NSPoint(x: w.x, y: graph.maxY))
            white.move(to: NSPoint(x: graph.minX, y: w.y)); white.line(to: NSPoint(x: graph.maxX, y: w.y))
            white.setLineDash([2, 3], count: 2, phase: 0); white.lineWidth = 1
            Theme.nsInk.withAlphaComponent(0.3).setStroke(); white.stroke()
            (L10n.tr("SDR white") as NSString).draw(at: NSPoint(x: w.x + 3, y: graph.maxY - 13), withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: Theme.nsInk.withAlphaComponent(0.4)])
        }
        drawHistogram()
        let diagonal = NSBezierPath(), top = model?.curveUpperInput ?? 1
        diagonal.move(to: screen(CurvePoint(x: 0, y: 0))); diagonal.line(to: screen(CurvePoint(x: 1, y: 1))); diagonal.line(to: screen(CurvePoint(x: top, y: top)))
        diagonal.setLineDash([3, 4], count: 2, phase: 0)
        Theme.nsInk.withAlphaComponent(0.16).setStroke(); diagonal.stroke()
        // Other edited channels stay visible as faint references.
        if let model {
            for channel in CurveChannel.allCases where channel != model.curveChannel {
                let other = model.targetAdjustments[keyPath: channel.key]
                guard !other.isIdentity else { continue }
                Self.color(channel).withAlphaComponent(0.4).setStroke()
                let path = path(other); path.lineWidth = 1; path.stroke()
            }
        }
        let gold = Self.color(model?.curveChannel ?? .rgb)
        let line = path(curve)
        gold.setStroke(); line.lineWidth = 1.5; line.stroke()
        for (index, value) in curve.points.enumerated() where visible(value) {
            let point = screen(value)
            (selected == index ? gold : Theme.dynamic(dark: NSColor(white: 0.85, alpha: 1), light: NSColor(white: 0.3, alpha: 1))).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        }
    }
    private static func color(_ channel: CurveChannel) -> NSColor {
        switch channel {
        case .rgb: return Theme.nsAccent
        case .red: return .systemRed; case .green: return .systemGreen; case .blue: return .systemBlue
        }
    }
    private func path(_ curve: ToneCurve) -> NSBezierPath {
        let line = NSBezierPath()
        for i in 0...512 {
            let x = value(Double(i) / 512), point = screen(CurvePoint(x: x, y: curve.value(at: x)))
            if i == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        return line
    }
    /// The selected channel's distribution sits behind the curve: luma for RGB, otherwise that channel.
    private func drawHistogram() {
        guard let model else { return }
        let channel: (bins: [Double], color: NSColor)
        switch model.curveChannel {
        case .rgb: channel = (model.luminanceHistogram, Theme.nsInk)
        case .red: channel = (model.histogram.count == 3 ? model.histogram[0] : [], .systemRed)
        case .green: channel = (model.histogram.count == 3 ? model.histogram[1] : [], .systemGreen)
        case .blue: channel = (model.histogram.count == 3 ? model.histogram[2] : [], .systemBlue)
        }
        // The extended HDR histogram already uses the graph's layout: SDR in the left half, stops in the right.
        var bins = channel.bins
        guard bins.count > 2 else { return }
        bins = bins.indices.map { i in (bins[max(0, i - 1)] + 2 * bins[i] + bins[min(bins.count - 1, i + 1)]) / 4 }
        // A near-top percentile keeps one clipped spike from flattening the rest of the distribution.
        let peak = max(0.0001, bins.sorted()[Int(Double(bins.count - 1) * 0.98)])
        let outline = NSBezierPath()
        for (index, value) in bins.enumerated() {
            let point = NSPoint(x: graph.minX + Double(index) / Double(bins.count - 1) * graph.width, y: graph.maxY - min(1, value / peak) * graph.height * 0.92)
            if index == 0 { outline.move(to: point) } else { outline.line(to: point) }
        }
        let fill = outline.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: graph.maxX, y: graph.maxY)); fill.line(to: NSPoint(x: graph.minX, y: graph.maxY)); fill.close()
        channel.color.withAlphaComponent(0.13).setFill(); fill.fill()
        channel.color.withAlphaComponent(0.22).setStroke(); outline.lineWidth = 1; outline.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let model else { return }
        let point = location(event), hit = hitPoint(point)
        if event.clickCount == 2 {
            if let hit { model.removeCurvePoint(at: hit) }
            selected = nil; needsDisplay = true; return
        }
        guard graph.insetBy(dx: -5, dy: -5).contains(point) else { return }
        model.beginGesture()
        let value = normalized(point)
        selected = hit ?? model.addCurvePoint(x: value.x, y: value.y)
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let selected else { return }
        let value = normalized(location(event))
        model?.moveCurvePoint(at: selected, x: value.x, y: value.y)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { model?.endGesture(); selected = nil; needsDisplay = true }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled, let model, let index = hitPoint(location(event)), !model.selectedCurve.isAnchor(index) else { return nil }
        menuPoint = index
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = NSMenuItem(title: L10n.tr("Remove Point"), action: #selector(removePoint), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc private func removePoint() {
        if let menuPoint { model?.removeCurvePoint(at: menuPoint) }
        menuPoint = nil; needsDisplay = true
    }
}

/// Two thumbs bound a span of one track, as Lightroom's hue-range controls. Dragging between them moves the span whole.
struct RangeSlider: NSViewRepresentable {
    let low: Double
    let high: Double
    let range: ClosedRange<Double>
    let title: String
    let change: (Double, Double) -> Void
    let editing: (Bool) -> Void
    let reset: () -> Void
    var appearance: SliderAppearance = .neutral
    func makeNSView(context: Context) -> RangeSliderView {
        let view = RangeSliderView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: RangeSliderView, context: Context) {
        view.range = range; view.style = appearance; view.isEnabled = context.environment.isEnabled
        if !view.dragging { view.low = low; view.high = high }
        view.onChange = change; view.onEditing = editing; view.onReset = reset
        view.setAccessibilityLabel(L10n.key(title))
        view.toolTip = L10n.tr("Drag either end, or between them to move both. Double-click to reset \(L10n.key(title))")
        view.needsDisplay = true
    }
}

final class RangeSliderView: NSView {
    var range: ClosedRange<Double> = 0...100
    var low = 0.0, high = 100.0
    var style: SliderAppearance = .neutral
    var isEnabled = true
    var onChange: (Double, Double) -> Void = { _, _ in }
    var onEditing: (Bool) -> Void = { _ in }
    var onReset: () -> Void = {}
    private(set) var dragging = false
    private enum Grip { case low, high, span }
    private var grip: Grip?
    /// Where the drag started, so a thumb follows the pointer without first jumping under it.
    private var anchor = (value: 0.0, low: 0.0, high: 0.0)
    override var isFlipped: Bool { true }
    private var track: NSRect { NSRect(x: bounds.minX + 4, y: bounds.midY - 1.5, width: bounds.width - 8, height: 3) }
    private var span: Double { max(1e-9, range.upperBound - range.lowerBound) }
    private func x(_ value: Double) -> CGFloat { track.minX + CGFloat((value - range.lowerBound) / span) * track.width }
    private func value(_ x: CGFloat) -> Double { range.lowerBound + Double((x - track.minX) / max(1, track.width)) * span }
    private func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let track = track
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).addClip()
        NSGradient(colors: style.colors.map { isEnabled ? $0 : $0.withAlphaComponent(0.3) })?.draw(in: track, angle: 0)
        // The selected span reads brighter than the rest of the track.
        NSColor.white.withAlphaComponent(isEnabled ? 0.3 : 0.1).setFill()
        NSBezierPath(rect: NSRect(x: x(low), y: track.minY, width: max(0, x(high) - x(low)), height: track.height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (value, grip) in [(low, Grip.low), (high, Grip.high)] {
            let thumb = NSRect(x: x(value) - 3.5, y: track.midY - 6, width: 7, height: 12)
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: thumb.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4).fill()
            let active = dragging && (self.grip == grip || self.grip == .span)
            NSColor(white: isEnabled ? (active ? 1 : 0.85) : 0.45, alpha: 1).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 { onReset(); return }
        let point = convert(event.locationInWindow, from: nil)
        let toLow = abs(point.x - x(low)), toHigh = abs(point.x - x(high))
        if min(toLow, toHigh) <= 8 {
            // Overlapping thumbs part in the direction of the drag; otherwise the nearer one is taken.
            grip = toLow == toHigh ? (point.x < x(low) ? .low : .high) : (toLow < toHigh ? .low : .high)
            anchor = (value(point.x), low, high)
        } else if point.x > x(low) && point.x < x(high) {
            grip = .span; anchor = (value(point.x), low, high)
        } else {
            // A click outside the span moves its nearer end there, as a plain slider jumps to a click.
            grip = point.x < x(low) ? .low : .high
            anchor = (value(point.x), point.x < x(low) ? clamp(value(point.x)) : low, point.x < x(low) ? high : clamp(value(point.x)))
        }
        dragging = true; onEditing(true)
        apply(point.x)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        apply(convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false; grip = nil; onEditing(false); needsDisplay = true
    }
    private func apply(_ x: CGFloat) {
        let delta = value(x) - anchor.value
        switch grip {
        case .low: low = min(high, clamp(anchor.low + delta))
        case .high: high = max(low, clamp(anchor.high + delta))
        case .span:
            let width = anchor.high - anchor.low
            low = min(range.upperBound - width, max(range.lowerBound, anchor.low + delta)); high = low + width
        case nil: return
        }
        onChange(low, high); needsDisplay = true
    }
}

/// A titled range control with both bounds editable as text, shown as "low / high" like a plain slider's readout.
struct AdjustmentRangeSlider: View {
    let title: String
    let low: Double
    let high: Double
    let range: ClosedRange<Double>
    let unit: String
    let set: (Double, Double) -> Void
    let editing: (Bool) -> Void
    let reset: () -> Void
    var appearance: SliderAppearance? = nil
    var eyedropper: EyedropperButton? = nil
    private func label(_ value: Double) -> String { unit == "fraction" ? String(format: "%.2f", locale: Locale.current, value) : String(format: "%.0f", locale: Locale.current, value) }
    private var precision: Int { unit == "fraction" ? 2 : 0 }
    private var width: CGFloat { unit == "fraction" ? 36 : 28 }
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                HStack { Text(L10n.key(title)).foregroundStyle(.secondary); Spacer(minLength: 0) }.contentShape(Rectangle()).onTapGesture(count: 2, perform: reset).help(L10n.tr("Double-click to reset"))
                EditableValue(label: label(low), value: low, range: range.lowerBound...high, precision: precision, title: L10n.tr("\(L10n.key(title)) low"), width: width, editing: editing) { set($0, high) }
                Text("/").foregroundStyle(.tertiary).padding(.horizontal, 1)
                EditableValue(label: label(high), value: high, range: low...range.upperBound, precision: precision, title: L10n.tr("\(L10n.key(title)) high"), width: width, editing: editing) { set(low, $0) }
                if let eyedropper { eyedropper }
            }.font(.system(size: 11))
            RangeSlider(low: low, high: high, range: range, title: title, change: set, editing: editing, reset: reset, appearance: appearance ?? .parameter(title)).frame(height: 18)
        }
    }
}
