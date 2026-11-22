import AppKit
import SwiftUI

/// Mutually exclusive choices retain native arrow-key navigation and radio-group accessibility.
/// Only drawing changes; independent boolean options use FormCheckboxStyle instead.
struct FormSegments<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var icon: ((Value) -> String)? = nil
    /// Every segment as wide as the widest, for choices that read as a set of equals, such as a filter.
    var equalWidths = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = FormSegmentControl()
        view.cell = FormSegmentCell()
        view.segmentStyle = .roundRect; view.trackingMode = .selectOne
        view.target = context.coordinator; view.action = #selector(Coordinator.changed(_:))
        view.font = .systemFont(ofSize: 11, weight: .semibold)
        return view
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        view.segmentCount = options.count
        let widest = options.map { ceil((label($0) as NSString).size(withAttributes: [.font: view.font!]).width) + 22 }.max() ?? 0
        for (index, value) in options.enumerated() {
            view.setLabel(label(value), forSegment: index)
            view.setToolTip(label(value), forSegment: index)
            view.setImage(icon.flatMap { NSImage(systemSymbolName: $0(value), accessibilityDescription: label(value)) }, forSegment: index)
            view.setWidth(icon != nil ? 32 : equalWidths ? widest : ceil((label(value) as NSString).size(withAttributes: [.font: view.font!]).width) + 22, forSegment: index)
        }
        view.selectedSegment = options.firstIndex(of: selection) ?? -1
        view.isEnabled = context.environment.isEnabled
        (view as? FormSegmentControl)?.height = Theme.controlHeight(context.environment.controlSize)
        view.setAccessibilityLabel(title)
        context.coordinator.select = { index in
            if options.indices.contains(index) { selection = options[index] }
        }
        view.invalidateIntrinsicContentSize(); view.needsDisplay = true
    }
    /// The height of the buttons and fields beside it, whatever the round-rect style would ask for.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: nsView.intrinsicContentSize.width, height: Theme.controlHeight(context.environment.controlSize))
    }
    final class Coordinator: NSObject {
        var select: (Int) -> Void = { _ in }
        @objc func changed(_ sender: NSSegmentedControl) { select(sender.selectedSegment) }
    }
}

private final class FormSegmentControl: NSSegmentedControl {
    /// The height of the buttons and fields beside it.
    var height: CGFloat = 24 { didSet { if height != oldValue { invalidateIntrinsicContentSize() } } }
    /// The round-rect style keeps a few points outside its alignment rect, and the fill is drawn over the whole frame:
    /// without this the segments stood taller than the buttons beside them.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = height
        return size
    }
}

final class FormSegmentCell: NSSegmentedCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Own the whole bezel as well as the segments: AppKit's roundRect bezel otherwise
        // adds outlined boxes and a second selection fill underneath our drawing.
        Theme.nsInk.withAlphaComponent(isEnabled ? 0.1 : 0.04).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
        let total = (0..<segmentCount).reduce(CGFloat.zero) { $0 + width(forSegment: $1) }
        guard total > 0 else { return }
        var x = cellFrame.minX + 2
        for segment in 0..<segmentCount {
            let width = (cellFrame.width - 4) * width(forSegment: segment) / total
            drawSegment(segment, inFrame: NSRect(x: x, y: cellFrame.minY + 2, width: width, height: cellFrame.height - 4), with: controlView)
            x += width
        }
    }
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        let selected = isSelected(forSegment: segment)
        if selected {
            Theme.nsInk.withAlphaComponent(isEnabled ? 0.2 : 0.06).setFill()
            NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 0), xRadius: Theme.Radius.control - 2, yRadius: Theme.Radius.control - 2).fill()
        }
        let color = Theme.nsInk.withAlphaComponent(isEnabled ? (selected ? 1 : 0.65) : 0.3)
        if let image = image(forSegment: segment) {
            let size = NSSize(width: 16, height: 14)
            let target = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                color.setFill(); rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: target)
        } else {
            let text = (label(forSegment: segment) ?? "") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: color]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
