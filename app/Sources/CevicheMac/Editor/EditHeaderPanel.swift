import SwiftUI
import CevicheCore

/// The row above the adjustments, as in other RAW editors: Auto, B&W and HDR as toggles, then the color profile with a menu
/// for importing an ICC profile. HDR's own controls live in the Light panel (HDR limit) and the SDR settings section.
struct EditHeaderPanel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                headerButton(L10n.tr("Auto"), active: false, help: L10n.tr("Set the light sliders from the photo")) { model.autoAdjust() }
                headerButton(L10n.tr("B&W"), active: model.targetAdjustments.monochrome, help: model.targetAdjustments.monochrome ? L10n.tr("Back to color") : L10n.tr("Black & white")) {
                    model.editTarget { $0.monochrome.toggle() }
                }
                Spacer()
                if model.adjustments.hdr.enabled && !model.displaySupportsHDR { DisplayHDRWarning() }
                headerButton(L10n.tr("HDR"), active: model.adjustments.hdr.enabled, help: model.adjustments.hdr.enabled ? L10n.tr("Edit in SDR") : L10n.tr("Edit in HDR: highlights above SDR white are kept and shown on HDR displays")) {
                    model.edit { $0.hdr.enabled.toggle() }
                }
            }
            HStack(spacing: 8) {
                Text(L10n.tr("Color Space")).foregroundStyle(.secondary)
                PanelPicker(title: L10n.tr("Color space"), selection: Binding(get: { model.adjustments.colorProfile.preset }, set: { value in model.edit { $0.colorProfile.preset = value } }),
                            options: RGBProfile.allCases.filter { $0 != .custom || model.adjustments.colorProfile.iccData != nil },
                            label: { profile in profile == .custom ? model.adjustments.colorProfile.name : profile.title })
                    .controlSize(.small)
                Spacer()
                Menu {
                    Button(L10n.tr("Import RGB ICC Profile…"), action: model.importProfile)
                    if model.adjustments.colorProfile.iccData != nil {
                        Button(L10n.tr("Remove Imported Profile")) { model.edit { $0.colorProfile = ColorProfile() } }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 22)
                        .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                    .help(L10n.tr("Import or remove an RGB ICC profile")).accessibilityLabel(L10n.tr("Color space options"))
            }
            ChartProfilePicker(model: model)
        }.font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 12)
        Rule()
    }
}

/// Shown left of the HDR toggle while editing in HDR on a display that cannot show it; hovering explains.
struct DisplayHDRWarning: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warning)
            .frame(width: 22, height: 22).contentShape(Rectangle())
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("This display can’t show HDR")).font(.system(size: 12, weight: .semibold))
                    Text(L10n.tr("Highlights above SDR white are tone-mapped down here, so the photo looks flatter than it is. The edit and its exports keep the full range. Move the window to an HDR display to see it, or switch to SDR to edit what this display shows."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(width: 260)
            }
            .accessibilityLabel(L10n.tr("This display can’t show HDR"))
    }
}

extension EditHeaderPanel {
    private func headerButton(_ title: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 5)
                .background(active ? Theme.accent.opacity(0.22) : Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(active ? Theme.accent : .primary).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(title).accessibilityAddTraits(active ? .isSelected : [])
    }
}
