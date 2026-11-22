import SwiftUI
import CevicheCore

/// The app's push buttons. The system's bordered style reads as disabled on the dark panels, so sheets and panels use
/// these instead: the accent for the main action, a quiet fill for the others, an accent tint for choices on the welcome
/// cards, and red for destructive ones. A disabled button fades, so it still looks different from an idle one.
struct ActionButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, tinted, destructive }
    var role: Role = .secondary
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, role: role) }

    private struct Styled: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false
        var body: some View {
            let small = controlSize == .small || controlSize == .mini
            configuration.label.font(.system(size: small ? 11 : 12, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 3 : 5)
                .frame(minHeight: Theme.controlHeight(controlSize))
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                // Like a system button, act on the click that also brings an inactive sheet or window forward.
                .allowsWindowActivationEvents(true)
                .onHover { hovering = $0 }
        }
        private var foreground: Color {
            switch role {
            case .primary: Theme.onAccent
            case .secondary: .primary
            case .tinted: Theme.accent
            case .destructive: .white
            }
        }
        private var fill: Color {
            let lifted = hovering && isEnabled
            return switch role {
            case .primary: Theme.accent.opacity(lifted ? 0.88 : 1)
            case .secondary: Theme.ink.opacity(lifted ? 0.16 : 0.1)
            case .tinted: Theme.accent.opacity(lifted ? 0.24 : 0.16)
            case .destructive: Color.red.opacity(lifted ? 0.95 : 0.82)
            }
        }
    }
}

/// The main action with its alternatives behind an arrow, as one button: clicking the title does the usual thing, the
/// arrow opens the others. For a tool whose result comes in several forms.
struct SplitActionButton<Items: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder var items: Items
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(title).font(.system(size: 12, weight: .semibold)).padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
            Rectangle().fill(Theme.onAccent.opacity(0.25)).frame(width: 1, height: 16)
            Menu {
                items
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent).frame(width: 26, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L10n.tr("More options"))
        }
        .foregroundStyle(Theme.onAccent)
        .background(Theme.accent.opacity(hovering && isEnabled ? 0.88 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .opacity(isEnabled ? 1 : 0.4)
        .allowsWindowActivationEvents(true)
        .onHover { hovering = $0 }
    }
}

extension SplitActionButton where Items == ForEach<Range<Int>, Int, Button<Text>> {
    init(title: String, action: @escaping () -> Void, options: [(title: String, action: () -> Void)]) {
        self.init(title: title, action: action) { ForEach(options.indices, id: \.self) { index in Button(options[index].title, action: options[index].action) } }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var primaryAction: ActionButtonStyle { ActionButtonStyle(role: .primary) }
    static var secondaryAction: ActionButtonStyle { ActionButtonStyle(role: .secondary) }
    static var destructiveAction: ActionButtonStyle { ActionButtonStyle(role: .destructive) }
}

/// An action written as accent-coloured text, where a filled button would outweigh what it sits beside: a row's own
/// action, or the lesser choices on the welcome screen.
struct TextLinkStyle: ButtonStyle {
    var color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(color)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4).contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextLinkStyle {
    static var textLink: TextLinkStyle { TextLinkStyle() }
    /// A link in another color, such as `Theme.error` for one that removes something.
    static func textLink(_ color: Color) -> TextLinkStyle { TextLinkStyle(color: color) }
}

/// A glyph that acts: quiet until pressed, with its name as the tooltip and for accessibility.
struct IconButton: View {
    let icon: String
    let title: String
    var pointSize: CGFloat = 13
    var size = CGSize(width: 22, height: 22)
    let action: () -> Void
    init(_ icon: String, _ title: String, pointSize: CGFloat = 13, size: CGSize = CGSize(width: 22, height: 22), action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.pointSize = pointSize; self.size = size; self.action = action
    }
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: pointSize)).frame(width: size.width, height: size.height).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(title).accessibilityLabel(title)
    }
}
