import SwiftUI
import CevicheCore

/// The frame every photo tool fills the window with, as in other RAW editors: the tool's name, a status line, Cancel and
/// the main action in the title bar; an optional row of options under it; then the tool's own content. Esc cancels
/// (or does `escape` first, for tools with a mode to leave), Return runs the main action.
struct ToolWorkspace<Toolbar: View, Content: View, Actions: View>: View {
    let title: String
    var status = ""
    var statusIsWarning = false
    var statusHelp = ""
    let primary: String
    var primaryDisabled = false
    /// Other forms of the main action, behind an arrow on its button.
    var primaryOptions: [(title: String, action: () -> Void)] = []
    /// A full menu behind the arrow instead, such as Export's presets, Share… and Edit In.
    var primaryMenu: AnyView?
    let cancel: () -> Void
    let action: () -> Void
    /// What Esc does; Cancel when nil.
    var escape: (() -> Void)?
    /// Close, for a tool that keeps its work as it goes rather than throwing it away; Cancel when nil.
    var cancelTitle: String?
    /// False for a tool that only shows something: one button closes it.
    var showsCancel = true
    /// False hides the toolbar strip while the tool has nothing to set yet, so the canvas stands alone.
    var showsToolbar = true
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var content: Content
    /// More title-bar actions, between Cancel and the main action: a tool with several outputs keeps them together.
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: title, status: status, statusIsWarning: statusIsWarning, statusHelp: statusHelp) {
                if showsCancel { ToolCancelButton(title: cancelTitle, action: cancel) }
                // Further outputs sit with the main action, apart from Cancel.
                actions
                if let primaryMenu {
                    // Share… opens its picker from here once the files are rendered.
                    SplitActionButton(title: primary, action: action) { primaryMenu }.disabled(primaryDisabled).background(PhotoShareAnchor())
                } else if primaryOptions.isEmpty {
                    ToolPrimaryButton(title: primary, action: action).disabled(primaryDisabled)
                } else {
                    SplitActionButton(title: primary, action: action, options: primaryOptions).disabled(primaryDisabled)
                }
            }
            Rule()
            if Toolbar.self != EmptyView.self && showsToolbar {
                ToolOptionsBar { toolbar; Spacer(minLength: 0) }
                Rule()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .tint(Theme.controlAccent)
        .onExitCommand { (escape ?? cancel)() }
    }
}

extension ToolWorkspace where Actions == EmptyView {
    init(title: String, status: String = "", statusIsWarning: Bool = false, statusHelp: String = "", primary: String, primaryDisabled: Bool = false,
         primaryOptions: [(title: String, action: () -> Void)] = [],
         cancel: @escaping () -> Void, action: @escaping () -> Void, escape: (() -> Void)? = nil,
         @ViewBuilder toolbar: () -> Toolbar, @ViewBuilder content: () -> Content) {
        self.init(title: title, status: status, statusIsWarning: statusIsWarning, statusHelp: statusHelp, primary: primary, primaryDisabled: primaryDisabled,
                  primaryOptions: primaryOptions, cancel: cancel, action: action, escape: escape, toolbar: toolbar, content: content, actions: { EmptyView() })
    }
}

extension ToolWorkspace where Toolbar == EmptyView, Actions == EmptyView {
    init(title: String, status: String = "", statusIsWarning: Bool = false, statusHelp: String = "", primary: String, primaryDisabled: Bool = false,
         cancel: @escaping () -> Void, action: @escaping () -> Void, escape: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, status: status, statusIsWarning: statusIsWarning, statusHelp: statusHelp, primary: primary, primaryDisabled: primaryDisabled,
                  cancel: cancel, action: action, escape: escape, toolbar: { EmptyView() }, content: content, actions: { EmptyView() })
    }
}

/// A tool's side panel: options beside the preview, on the panel colour, scrolling when they don't fit.
struct ToolSidePanel<Content: View>: View {
    var width: CGFloat = 300
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            Rule(.vertical)
            ScrollView { content.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: width).background(Theme.panel)
        }
    }
}
