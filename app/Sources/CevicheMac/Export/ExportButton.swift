import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// Shared by Develop and the photo view so both can export the open photo.
struct ExportButton: View {
    @ObservedObject var editor: EditorModel
    var compact = false
    let editIn: (URL) -> Void
    var body: some View {
        ExportSplitButton(compact: compact, disabled: !editor.hasImage || editor.busy, export: { editor.prepareExport() }) {
            ExportMenuItems(export: { editor.export(preset: $0) }, share: editor.share, editIn: editIn)
        }
    }
}

/// Export and the arrow of its presets as one quiet split button, drawn the same in the Library and in Develop.
struct ExportSplitButton<Items: View>: View {
    var compact = false
    let disabled: Bool
    let export: () -> Void
    @ViewBuilder var items: Items
    var body: some View {
        // The button opens the dialog; the chevron lists presets that go straight to the save panel.
        HStack(spacing: 0) {
            Button(action: export) {
                Label(L10n.tr("Export"), systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                    .labelStyle(TitleHiddenLabelStyle(hidden: compact))
                    .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false).help(L10n.tr("Export (⇧⌘E)")).accessibilityLabel(L10n.tr("Export"))
            Rectangle().fill(Theme.ink.opacity(0.12)).frame(width: 1, height: 16)
            Menu { items } label: {
                // Labelled on the image too: an enabled menu otherwise names itself after the symbol ("Go Down").
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 10).contentShape(Rectangle())
                    .accessibilityLabel(L10n.tr("Export presets"))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(L10n.tr("Export using a preset"))
                .focusable(false).accessibilityLabel(L10n.tr("Export presets"))
        }
        // Quiet like the other header controls; the accent lives in the glyph and text only.
        .background(PhotoShareAnchor())
        .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .foregroundStyle(Theme.accent).disabled(disabled)
    }
}

/// What every Export button's arrow lists: presets and Share…, anything particular to that button, then Edit In.
struct ExportMenuItems<Extra: View>: View {
    let export: (ExportPreset) -> Void
    let share: () -> Void
    let editIn: (URL) -> Void
    @ViewBuilder var extra: Extra
    var body: some View {
        Section { ExportPresetItems(export: export, share: share) }
        if Extra.self != EmptyView.self { Section { extra } }
        Section { Menu(L10n.tr("Edit In")) { EditInItems(open: editIn) } }
    }
}

extension ExportMenuItems where Extra == EmptyView {
    init(export: @escaping (ExportPreset) -> Void, share: @escaping () -> Void, editIn: @escaping (URL) -> Void) {
        self.init(export: export, share: share, editIn: editIn) { EmptyView() }
    }
}

/// Size and format presets, then social networks; shared by the Export buttons and the File menu.
struct ExportPresetItems: View {
    let export: (ExportPreset) -> Void
    let share: () -> Void
    var body: some View {
        let userPresets = ExportPreset.savedByUser()
        if !userPresets.isEmpty {
            ForEach(userPresets) { preset in Button(L10n.tr("\(preset.name)")) { export(preset) }.help(preset.detail) }
            Divider()
        }
        ForEach(ExportPreset.standard) { preset in Button(L10n.tr("\(preset.name)")) { export(preset) }.help(preset.detail) }
        Divider()
        ForEach(ExportPreset.socialByPlatform, id: \.platform) { group in
            if group.presets.count == 1, let preset = group.presets.first {
                Button(L10n.tr("\(preset.name)")) { export(preset) }.help(preset.detail)
            } else {
                Menu(group.platform) {
                    ForEach(group.presets) { preset in Button(L10n.tr("\(preset.shortName)")) { export(preset) }.help(preset.detail) }
                }
            }
        }
        Divider()
        Button(L10n.tr("Share…"), systemImage: "square.and.arrow.up", action: share)
        if !userPresets.isEmpty {
            Divider()
            Menu(L10n.tr("Manage Presets")) {
                ForEach(userPresets) { preset in
                    Button(L10n.tr("Delete \"\(preset.name)\""), role: .destructive) { ExportPreset.deleteUserPreset(preset.id) }
                }
            }
        }
    }
}
