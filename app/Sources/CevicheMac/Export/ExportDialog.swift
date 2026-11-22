import SwiftUI
import CevicheCore

/// Export: where the files go and how they are written. There is no preview: the file is the developed photo at full
/// quality, and what it looks like is what the photographer has already been looking at.
struct ExportDialog<Model: ExportTarget>: View {
    /// Fixed: the options scroll when HDR or a watermark makes them taller.
    static var size: CGSize { CGSize(width: 500, height: 620) }
    @ObservedObject var model: Model
    /// False where the caller has noise reduction of its own (the Creative Filters chain).
    var showsDenoise = true
    @State private var showingSavePreset = false
    @State private var presetName = ""
    private var settings: ExportSettings { model.exportSettings }
    private var exportSize: CGSize? {
        guard let source = model.outputSize else { return nil }
        return try? settings.dimensions(for: source).size
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let location = model.locationPanel {
                        location
                        Rule()
                    }
                    ExportOptions(model: model, showsDenoise: showsDenoise)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }
            footer
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.panel)
        // Escape cancels even while a button or field inside the dialog has keyboard focus.
        .background(EscapeKey { model.dismissExport() })
        .tint(Theme.controlAccent)
    }
    private var defaultPresetName: String {
        let fmt = settings.format == .heif ? "HEIC" : settings.format.rawValue
        let depth = settings.depth != 8 ? " \(settings.depth)-bit" : ""
        let size = settings.sizing.longEdge.map { L10n.tr(", \($0) px") } ?? ""
        return "\(fmt)\(depth)\(size)"
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            SheetHeader(title: L10n.tr("Export"), subtitle: model.exportTitle)
            if let subtitle = model.exportSubtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var footer: some View {
        let ready = !model.busy && model.hasImage && settings.format.isAvailable && exportSize != nil
        return HStack(spacing: 10) {
            Button { presetName = defaultPresetName; showingSavePreset = true } label: {
                Label(L10n.tr("Save as Preset"), systemImage: "square.and.arrow.down")
                    .frame(minWidth: 60).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }.buttonStyle(.plain).popover(isPresented: $showingSavePreset, arrowEdge: .top) {
                VStack(spacing: 12) {
                    Text(L10n.tr("Save Export Preset")).font(.headline)
                    TextField(L10n.tr("Preset name"), text: $presetName)
                        .textFieldStyle(.formField).frame(width: 220)
                        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) } }
                    HStack {
                        Button(L10n.tr("Cancel")) { showingSavePreset = false }.keyboardShortcut(.cancelAction).buttonStyle(.secondaryAction)
                        Button(L10n.tr("Save")) {
                            let name = presetName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            ExportPreset.saveUserPreset(name: name, settings: settings, developedProfile: model.developedProfile != nil && model.usesDevelopedProfile)
                            showingSavePreset = false
                        }.keyboardShortcut(.defaultAction).buttonStyle(.primaryAction).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }.padding()
            }
            Spacer()
            Button { model.dismissExport() } label: {
                Text(L10n.tr("Cancel")).frame(minWidth: 60).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            Button(action: model.performExport) {
                Text(model.exportButtonTitle).fontWeight(.semibold).foregroundStyle(Theme.onAccent)
                    .frame(minWidth: 74).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!ready)
        }.font(.system(size: 12))
    }
}
