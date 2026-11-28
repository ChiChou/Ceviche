import SwiftUI
import CevicheCore

/// The title-bar row of a full-window tool: what the tool is on the left, the window's drag area in the middle (a status
/// line, or the tool's filters), and its buttons on the right. `ToolWorkspace` builds on it for the tools that need no
/// more than a status line; the culling and import tools, which put filters in the middle, use it directly.
struct ToolHeader<Leading: View, Center: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            leading.padding(.leading, WindowTrafficLights.leadingReservation).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
            center.frame(maxWidth: .infinity, maxHeight: .infinity).background(WindowTitlebarArea())
            // The buttons keep their one-line width, however long a count in them grows; the middle gives way.
            HStack(spacing: 10) { actions }.fixedSize()
        }
        .padding(.horizontal, 16).frame(height: WindowTrafficLights.headerHeight).background(Theme.toolbar).background(WindowTrafficLights())
    }
}

extension ToolHeader where Leading == ToolTitle, Center == ToolStatus {
    /// The title with a status line beside it.
    init(title: String, status: String, statusIsWarning: Bool = false, statusHelp: String = "", @ViewBuilder actions: () -> Actions) {
        self.init(leading: { ToolTitle(title: title) }, center: { ToolStatus(text: status, isWarning: statusIsWarning, help: statusHelp) }, actions: actions)
    }
}

extension ToolHeader where Leading == ToolTitle {
    /// The title over a caption, leaving the middle to the tool's filters.
    init(title: String, caption: String, icon: String? = nil, @ViewBuilder center: () -> Center, @ViewBuilder actions: () -> Actions) {
        self.init(leading: { ToolTitle(title: title, caption: caption, icon: icon) }, center: center, actions: actions)
    }
}

/// A tool's name in its title bar, over a caption of counts when the status line's place is taken by filters.
struct ToolTitle: View {
    let title: String
    var caption: String?
    var icon: String?
    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            if let caption {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            } else {
                Text(title).font(.headline).lineLimit(1)
            }
        }
    }
}

/// The status line of a tool's title bar: what it is working on, or in the warning colour what went wrong.
struct ToolStatus: View {
    let text: String
    var isWarning = false
    var help = ""
    var body: some View {
        Text(text).font(.callout).foregroundStyle(isWarning ? Theme.warning : .secondary).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, maxHeight: .infinity).help(help)
    }
}

/// Cancel in a tool's title bar, on Esc.
struct ToolCancelButton: View {
    var title: String?
    let action: () -> Void
    var body: some View {
        Button(title ?? L10n.tr("Cancel"), action: action).keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
    }
}

/// A tool's main action in its title bar, on Return.
struct ToolPrimaryButton: View {
    let title: String
    var minWidth: CGFloat = 64
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).monospacedDigit().frame(minWidth: minWidth) }
            .keyboardShortcut(.defaultAction).buttonStyle(.primaryAction)
    }
}

/// A strip of options under a tool's title bar, or of counts and view controls along its bottom edge.
struct ToolOptionsBar<Content: View>: View {
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: spacing) { content }
            .toggleStyle(.formCheckbox).font(.callout)
            .padding(.horizontal, 16).frame(height: 38).background(Theme.statusBar)
    }
}

/// What a tool is busy with, over its preview; a bar that fills when the work can say how far it is.
struct ToolProgressCard: View {
    let message: String
    var fraction: Double?
    var body: some View {
        HStack(spacing: 18) {
            Text(message).font(.callout).lineLimit(1)
            Group { if let fraction { ProgressView(value: fraction) } else { ProgressView() } }
                .progressViewStyle(.linear).tint(Theme.accent).frame(width: 140)
            if let fraction { Text(L10n.tr("\(Int(fraction * 100))%")).font(.callout).monospacedDigit().frame(width: 36, alignment: .trailing) }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).environment(\.colorScheme, .dark)
    }
}

/// The photos a tool works on, in a strip along the bottom of its window.
struct ToolFilmstrip<Content: View>: View {
    var height: CGFloat = 148
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) { content }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: height).background(Theme.statusBar)
    }
}

/// One photo of a tool's filmstrip: outlined when it is the one the others follow, dimmed when left out. With its
/// catalog photo, the catalog's stored thumbnail, which shows it as developed; `image`, the tool's own reading of the
/// file, until the photo has one.
struct ToolFrameThumbnail: View {
    let image: CGImage?
    var asset: CatalogAsset? = nil
    var previews: PreviewStore? = nil
    var size = CGSize(width: 132, height: 88)
    var outline: Color?
    /// "Base" or "Reference" when this photo is it.
    var badge: String?
    var dimmed = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let asset, asset.thumbnailKey != nil, let previews { CatalogThumbnail(asset: asset, previews: previews) }
                else if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { Color.black }
            }
            .frame(width: size.width, height: size.height).clipped()
            .overlay(Rectangle().strokeBorder(outline ?? .clear, lineWidth: 2))
            .opacity(dimmed ? 0.35 : 1)
            if let badge { AccentBadge(text: badge).padding(4) }
        }
        .contentShape(Rectangle())
    }
}

/// A word on the accent colour, marking the one photo of a set that the others follow.
struct AccentBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).foregroundStyle(Theme.onAccent)
    }
}

/// The thumbnail size of a tool's grid, between a small and a large grid glyph.
struct ThumbnailSizeSlider: View {
    @Binding var size: Double
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
            FormSlider(value: $size, in: range).frame(width: 110).accessibilityLabel(L10n.tr("Thumbnail size"))
            Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
        }.help(L10n.tr("Thumbnail size"))
    }
}

extension FocusStackPreview {
    /// A layer's colour in the filmstrip and over the preview: warm for the first photo to cool for the last.
    static func layerColor(position: Int, count: Int) -> Color {
        let c = color(position: position, count: count)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// One choice of a tool's title-bar filter: a capsule lit while it is on, with how many photos it stands for.
struct FilterChip: View {
    let title: String
    var count: Int?
    var symbol: String?
    var symbolColor: Color?
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).foregroundStyle(symbolColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground)) }
                Text(title)
                if let count { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? Theme.accent.opacity(0.25) : Theme.ink.opacity(0.06), in: Capsule())
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
        }.buttonStyle(.plain).accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A word over a photo's corner in a tool's grid: its file type, or where it already is.
struct PhotoCornerLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark)
    }
}
