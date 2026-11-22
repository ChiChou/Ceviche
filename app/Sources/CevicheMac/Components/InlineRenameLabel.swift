import AppKit
import SwiftUI
import CevicheCore

/// Names are edited as a draft: Return or focus loss commits, Escape cancels.
/// A native field keeps double-click editing separate from the surrounding row's actions.
struct InlineRenameLabel: NSViewRepresentable {
    let name: String
    @Binding var editing: Bool
    var fontSize: CGFloat = 12
    var semibold = false
    var select: () -> Void = {}
    let commit: (String) -> Void

    func makeNSView(context: Context) -> InlineRenameField { InlineRenameField() }
    func updateNSView(_ view: InlineRenameField, context: Context) {
        view.isEnabled = context.environment.isEnabled
        view.font = .systemFont(ofSize: fontSize, weight: semibold ? .semibold : .regular)
        view.onSelect = select
        view.onEditing = { editing = $0 }
        view.onCommit = commit
        view.toolTip = L10n.tr("Double-click to rename")
        view.setAccessibilityLabel(name)
        if !view.renaming { view.stringValue = name }
        view.requestedEditing = editing
        if editing && !view.renaming {
            // SwiftUI may update before the field is attached to its window.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil, view.requestedEditing, !view.renaming else { return }
                view.beginRename()
            }
        } else if !editing && view.renaming { view.finishRename(save: false) }
    }
}

final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    private(set) var renaming = false
    private var original = ""
    var requestedEditing = false
    var onSelect: () -> Void = {}
    var onEditing: (Bool) -> Void = { _ in }
    var onCommit: (String) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if renaming { super.mouseDown(with: event) }
        else if event.clickCount == 2 { beginRename() }
        else { onSelect() }
    }
    func beginRename() {
        guard isEnabled, !renaming else { return }
        original = stringValue; renaming = true
        isEditable = true; isSelectable = true; isBordered = true
        drawsBackground = true; backgroundColor = Theme.nsCanvas
        onEditing(true)
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }
    func finishRename(save: Bool) {
        guard renaming else { return }
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        let changed = save && !name.isEmpty && name != original
        stringValue = changed ? name : original
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        onEditing(false)
        if changed { onCommit(name) }
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishRename(save: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(save: false); window?.makeFirstResponder(nil); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(save: true); window?.makeFirstResponder(nil); return true
        }
        return false
    }
}
