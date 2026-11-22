import SwiftUI
import CevicheCore

/// A group in the Remove and Portrait panels: a row that opens in place, with an optional reset for what the group made.
struct DisclosureRow<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var open: Bool
    var reset: (() -> Void)? = nil
    /// The group's on/off, as in Light & Color: off keeps its settings but leaves them out of the photo.
    var isEnabled: Binding<Bool>? = nil
    @ViewBuilder let content: () -> Content
    /// The card and header of Light & Color's sections (`EditorSection`), so every panel's groups look alike.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { open.toggle() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(open ? .isSelected : [])
                if let reset {
                    Button(action: reset) { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(L10n.tr("Reset \(title)")).accessibilityLabel(L10n.tr("Reset \(title)"))
                }
                if let isEnabled {
                    let enabled = isEnabled.wrappedValue
                    Button { isEnabled.wrappedValue.toggle() } label: {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                            .foregroundStyle(enabled ? Theme.accent : .secondary)
                    }.buttonStyle(.plain).help(enabled ? L10n.tr("Disable \(title)") : L10n.tr("Enable \(title)"))
                        .accessibilityLabel(L10n.tr("Enable \(title)")).accessibilityValue(enabled ? L10n.tr("On") : L10n.tr("Off"))
                }
            }.padding(.vertical, 13)
            if open {
                let enabled = isEnabled?.wrappedValue ?? true
                VStack(alignment: .leading, spacing: 10, content: content).padding(.bottom, 16).disabled(!enabled).opacity(enabled ? 1 : 0.4)
            }
        }.padding(.horizontal, 14)
            .card()
    }
}

