import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The selection of a list where several items can be chosen: the Library grid, the Develop filmstrip, Tidy Pairs,
/// the timelapse frames, the night sky's lines and the healed dust spots. One set of rules for all of them. Lists
/// that choose with a checkbox in the corner (the card importer, the merge and night sky frame lists) don't use it.
struct MultiSelection<ID: Hashable>: Equatable {
    var ids: Set<ID> = []
    /// Where a ⇧-click range starts: the last item clicked without ⇧.
    var anchor: ID?

    /// A click selects only `id`; ⇧ selects the range from the anchor to it, added to the selection when ⌘ is held
    /// too; ⌘ alone toggles `id`. `order` is the list as shown. A ⇧-click with no anchor in `order` counts as a click
    /// without ⇧.
    mutating func click(_ id: ID, in order: [ID], extending: Bool = false, toggling: Bool = false) {
        if extending, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to)...max(from, to)])
            ids = toggling ? ids.union(range) : range
        } else if toggling {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]; anchor = id
        }
    }
    mutating func selectAll(_ order: [ID]) {
        ids = Set(order)
        if anchor.map({ !ids.contains($0) }) ?? true { anchor = order.first }
    }
    mutating func clear() { ids = []; anchor = nil }
}

/// The modifier keys of the click being handled, as lists read them: ⇧ extends, ⌘ toggles. A touch has neither.
enum SelectionClick {
    static var extending: Bool { flags.extending }
    static var toggling: Bool { flags.toggling }
    private static var flags: (extending: Bool, toggling: Bool) {
        #if os(macOS)
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        return (flags.contains(.shift), flags.contains(.command))
        #else
        return (false, false)
        #endif
    }
}

/// Whether a list using `selectionKeys` has keyboard focus, for the window-wide key handling to stand back from the
/// keys the list answers.
@MainActor
enum SelectionListFocus {
    static var active = false
}

extension View {
    /// Makes a multi-select list focusable and gives it its selection keys, active only while it has focus: ⌘A
    /// selects all, ⇧⌘A selects none, and optionally Escape selects none and Delete runs `delete`. Clicking an item
    /// should set `focus` to true, as clicking a cell focuses the grid. Built from SwiftUI focus, shortcuts and key
    /// presses only, so a hardware keyboard on iPad works the same.
    func selectionKeys(focus: FocusState<Bool>.Binding, hasSelection: Bool, selectAll: @escaping () -> Void,
                       deselectAll: @escaping () -> Void, escapeDeselects: Bool = false, delete: (() -> Void)? = nil) -> some View {
        modifier(SelectionKeys(focus: focus, hasSelection: hasSelection, selectAll: selectAll, deselectAll: deselectAll,
                               escapeDeselects: escapeDeselects, delete: delete))
    }
}

private struct SelectionKeys: ViewModifier {
    var focus: FocusState<Bool>.Binding
    let hasSelection: Bool
    let selectAll: () -> Void
    let deselectAll: () -> Void
    let escapeDeselects: Bool
    let delete: (() -> Void)?
    func body(content: Content) -> some View {
        content
            .focusable().focusEffectDisabled().focused(focus)
            .onChange(of: focus.wrappedValue) { _, focused in SelectionListFocus.active = focused }
            .onDisappear { if focus.wrappedValue { SelectionListFocus.active = false } }
            // The shortcuts exist only while the list has focus, so a text field or another list keeps ⌘A.
            .background {
                if focus.wrappedValue {
                    Group {
                        Button(action: selectAll) { EmptyView() }.keyboardShortcut("a")
                        Button(action: deselectAll) { EmptyView() }.keyboardShortcut("a", modifiers: [.command, .shift])
                    }.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            .onKeyPress(.escape) {
                guard escapeDeselects, hasSelection else { return .ignored }
                deselectAll(); return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                guard let delete, hasSelection, press.modifiers.isEmpty else { return .ignored }
                delete(); return .handled
            }
    }
}
