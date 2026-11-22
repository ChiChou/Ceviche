import SwiftUI

/// A bar floating over the photo (Darkroom's views, Portrait's tools, the targeted adjustment): a dark plate with the
/// app's control radius, whatever the appearance, so it reads on any picture.
struct PhotoBar<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 4, content: content)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .environment(\.colorScheme, .dark)
    }
}

/// One choice in a `PhotoBar`: semibold on a light plate when selected, dimmed otherwise.
struct PhotoBarChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.system(size: 12, weight: selected ? .semibold : .regular)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Theme.ink.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .foregroundStyle(selected ? .primary : .secondary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thin divider between groups of choices in a `PhotoBar`.
struct PhotoBarDivider: View {
    var body: some View { Rectangle().fill(Theme.ink.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 4) }
}
