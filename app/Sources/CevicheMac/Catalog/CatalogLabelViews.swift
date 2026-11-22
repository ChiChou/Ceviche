import SwiftUI
import AppKit
import CevicheCore

extension CatalogLabel {
    var title: String {
        switch self {
        case .red: L10n.tr("Red")
        case .yellow: L10n.tr("Yellow")
        case .green: L10n.tr("Green")
        case .blue: L10n.tr("Blue")
        case .purple: L10n.tr("Purple")
        }
    }
    /// The Finder's tag colors.
    var color: Color {
        switch self {
        case .red: Color(nsColor: .systemRed)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        }
    }
    /// Lightroom's keys: 6 to 9, and none for Purple.
    var key: String? {
        switch self {
        case .red: "6"
        case .yellow: "7"
        case .green: "8"
        case .blue: "9"
        case .purple: nil
        }
    }
    init?(key: String) {
        guard let label = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = label
    }
    /// "Red (6)", with the key where there is one.
    var help: String { key.map { "\(title) (\($0))" } ?? title }
}

/// A label's dot, as the Finder shows a tag.
struct LabelDot: View {
    let label: CatalogLabel
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(label.color).frame(width: size, height: size)
            .accessibilityLabel(label.title)
    }
}

/// The five labels as dots for the inspector's photos. Clicking a label sets it, and clicking the one every photo has
/// clears it, as do 6–9.
struct PhotoLabelControls: View {
    @ObservedObject var catalog: CatalogModel
    let targets: [CatalogAsset]
    var body: some View {
        // A single photo shows the catalog's metadata, including pending changes; several show what they share.
        let labels = Set(targets.map { catalog.selected?.id == $0.id ? catalog.metadata.label : $0.metadata.label })
        let current = labels.count == 1 ? labels.first! : nil
        HStack(spacing: 0) {
            ForEach(CatalogLabel.allCases, id: \.self) { label in
                Button { Task { await catalog.toggleLabel(label, on: targets) } } label: {
                    ZStack {
                        if current == label { Circle().strokeBorder(Theme.ink.opacity(0.8), lineWidth: 1.5).frame(width: 18, height: 18) }
                        LabelDot(label: label, size: 12).opacity(current == nil || current == label ? 1 : 0.55)
                    }.frame(width: 22, height: 24).contentShape(Rectangle())
                }.help(label.help)
                    .accessibilityAddTraits(current == label ? .isSelected : [])
            }
        }.buttonStyle(.plain).disabled(targets.isEmpty || catalog.interactionBusy || (catalog.showingLibrary && catalog.filter.area != .library))
    }
}

/// The Label menu items, for the Photo menu and a photo's context menu.
struct LabelMenuItems: View {
    @ObservedObject var catalog: CatalogModel
    let targets: [CatalogAsset]
    var body: some View {
        ForEach(CatalogLabel.allCases, id: \.self) { label in
            Toggle(isOn: Binding(
                get: { !targets.isEmpty && targets.allSatisfy { $0.metadata.label == label } },
                set: { _ in let targets = targets; Task { await catalog.setQuickMetadata(targets, label: .some(label)) } })) {
                Label { Text(label.title) } icon: { Image(nsImage: Self.swatch(label)) }
            }
        }
        Divider()
        Button(L10n.tr("None")) { let targets = targets; Task { await catalog.setQuickMetadata(targets, label: .some(nil)) } }
    }
    /// Menus draw images, not views: a dot in the label's color.
    static func swatch(_ label: CatalogLabel) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(label.color).setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill(); return true
        }
        return image
    }
}
