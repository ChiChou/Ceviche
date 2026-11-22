import SwiftUI
import CevicheCore

struct ExportOptions<Model: ExportTarget>: View {
    @ObservedObject var model: Model
    /// False where the caller has noise reduction of its own (the Filters tool's stack).
    var showsDenoise = true
    /// Observed so AI denoise enables itself once its model is installed in Settings › Models.
    @ObservedObject private var library = ModelLibrary.shared
    private var settings: ExportSettings { model.exportSettings }
    private var preservesAlpha: Bool { settings.preserveAlpha && settings.format.supportsAlpha }
    /// The formats offered for photos, most widely used first. PNG is left out; MCP still writes it.
    static var formats: [ExportFormat] { [.jpeg, .tiff, .heif, .webp, .avif, .jxl] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(L10n.tr("Format")) {
                FormSelect(L10n.tr("Format"), selection: Binding(get: { settings.format }, set: { model.exportSettings.select($0) }), valueLabel: settings.format == .heif ? "HEIC" : settings.format.rawValue) {
                    ForEach(Self.formats, id: \.self) { format in
                        Text(format == .heif ? "HEIC" : format.rawValue).tag(format).disabled(!format.isAvailable)
                    }
                }.labelsHidden().help(formatNote)
            }
            renderedOptions
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the bundled encoders keep, as the format menu's tooltip.
    private var formatNote: String {
        switch settings.format {
        case .webp: L10n.tr("WebP stores 8-bit SDR pixels, with optional transparency. Lossless preserves those rendered pixels, not the original RAW precision.")
        case .jxl: L10n.tr("JPEG XL stores 8- or 16-bit SDR pixels with optional transparency. Lossless preserves the rendered pixels at the selected depth.")
        default: ""
        }
    }
    private func depthLabel(_ depth: Int) -> String { settings.floatingPoint ? L10n.tr("\(depth)-bit float") : L10n.tr("\(depth)-bit") }

    private var renderedOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.hdrAvailable && settings.format.supportsHDR {
                row(L10n.tr("Dynamic range")) {
                    FormSegments(title: L10n.tr("Dynamic range"), selection: Binding(get: { settings.hdr }, set: { model.exportSettings.setHDR($0) }), options: [true, false], label: { $0 ? L10n.tr("HDR") : L10n.tr("SDR") })
                }
                if settings.hdr {
                    row(L10n.tr("HDR encoding")) {
                        FormSelect(L10n.tr("HDR encoding"), selection: Binding(get: { settings.hdrEncoding }, set: { model.exportSettings.setHDREncoding($0) }), valueLabel: settings.hdrEncoding.title) {
                            ForEach(settings.format.hdrEncodings, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().disabled(settings.format.hdrEncodings.count == 1).help(settings.hdrEncoding.summary)
                    }
                }
            }
            if model.exportsManyPhotos { BatchSizeControls(model: model) } else { ExportSizeControls(model: model) }
            VStack(spacing: 14) {
                row(L10n.tr("Bits per channel")) {
                    if settings.depths.count == 1 {
                        Text(depthLabel(settings.depth))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        FormSegments(title: L10n.tr("Bits per channel"), selection: $model.exportSettings.depth, options: settings.depths.sorted(), label: depthLabel)
                    }
                }
                row(settings.hdr && settings.hdrEncoding.isGainMap ? L10n.tr("SDR base") : L10n.tr("Color space")) {
                    if settings.hdr && settings.hdrEncoding.isGainMap {
                        // The picture every viewer sees; only sRGB and Display P3 have the extended-range form the encoder needs.
                        FormSelect(L10n.tr("SDR base profile"), selection: Binding(get: { settings.resolvedProfile.preset == .sRGB ? RGBProfile.sRGB : .displayP3 },
                                                                      set: { model.usesDevelopedProfile = false; model.exportSettings.profile.preset = $0 }), valueLabel: settings.resolvedProfile.preset == .sRGB ? L10n.tr("sRGB + HDR gain map") : L10n.tr("Display P3 + HDR gain map")) {
                            Text(L10n.tr("sRGB + HDR gain map")).tag(RGBProfile.sRGB)
                            Text(L10n.tr("Display P3 + HDR gain map")).tag(RGBProfile.displayP3)
                        }.labelsHidden()
                    } else if settings.hdr {
                        Text(settings.profileLabel).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // A Library export can keep each photo's own profile; Develop starts from the open photo's.
                        let printer = PrintProofState.exportProfile()
                        FormSelect(L10n.tr("Color space"), selection: Binding<RGBProfile?>(
                            get: { model.developedProfile != nil && model.usesDevelopedProfile ? nil : settings.profile.preset },
                            set: { choice in
                                // The proof's printer profile stands in for an imported one when there is none.
                                if choice == .custom, settings.profile.iccData == nil, let printer { model.usesDevelopedProfile = false; model.exportSettings.profile = printer }
                                else if let choice { model.usesDevelopedProfile = false; model.exportSettings.profile.preset = choice }
                                else { model.usesDevelopedProfile = true }
                            }), valueLabel: model.developedProfile != nil && model.usesDevelopedProfile ? L10n.tr("As Developed") : settings.profileLabel) {
                            if model.developedProfile != nil { Text(L10n.tr("As Developed")).tag(RGBProfile?.none) }
                            ForEach(RGBProfile.allCases.filter { $0 != .custom || settings.profile.iccData != nil || printer != nil }, id: \.self) { profile in
                                Text(profile == .custom ? (settings.profile.iccData != nil ? settings.profile.name : printer?.name ?? "") : profile.title(for: settings.format)).tag(RGBProfile?.some(profile))
                            }
                        }.labelsHidden()
                    }
                }
                if settings.format.supportsLosslessChoice {
                    row(L10n.tr("Compression")) {
                        FormSegments(title: L10n.tr("Compression"), selection: $model.exportSettings.lossless, options: [true, false], label: { $0 ? L10n.tr("Lossless") : L10n.tr("Lossy") })
                    }
                }
                if settings.usesLossyCompression || !settings.format.supportsLosslessChoice {
                    row(settings.usesLossyCompression ? L10n.tr("Quality") : L10n.tr("Compression")) {
                        if settings.usesLossyCompression {
                            HStack(spacing: 8) {
                                FormSlider(value: $model.exportSettings.quality, in: 0.1...1).accessibilityLabel(L10n.tr("Export quality")).frame(maxWidth: 180)
                                Text(L10n.tr("\(Int((settings.quality * 100).rounded()))%"))
                                    .monospacedDigit().frame(width: 35, alignment: .trailing)
                            }
                        } else {
                            Text(settings.format == .tiff ? L10n.tr("LZW - Lossless") : L10n.tr("Lossless"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if showsDenoise { row(L10n.tr("AI noise reduction")) {
                HStack(spacing: 8) {
                    FormSlider(value: $model.exportSettings.aiDenoise, in: 0...100).accessibilityLabel(L10n.tr("AI noise reduction")).frame(maxWidth: 180)
                    Text(settings.aiDenoise > 0 ? "\(Int(settings.aiDenoise.rounded()))" : L10n.tr("Off"))
                        .monospacedDigit().frame(width: 35, alignment: .trailing)
                    if !BundledModel.denoise.isAvailable { ModelPrompt(model: .denoise, compact: true) }
                }
                .disabled(!BundledModel.denoise.isAvailable)
                .help(BundledModel.denoise.isAvailable ? L10n.tr("NAFNet machine-learning noise reduction, run on this Mac as the last step before the file is written, at the export size. Zoom into the preview to inspect it.") : L10n.tr("The AI noise reduction model is not installed. Install it in Settings › Models."))
            } }
            WatermarkControls(model: model)
            row(L10n.tr("Options")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.tr("Don’t enlarge"), isOn: Binding(get: { !settings.sizing.allowsEnlarging }, set: { model.exportSettings.sizing.allowsEnlarging = !$0 }))
                        .help(L10n.tr("A size larger than the photo exports at the photo's own size"))
                    Toggle(L10n.tr("Preserve transparency"), isOn: Binding(get: { preservesAlpha }, set: { model.exportSettings.preserveAlpha = $0 }))
                        .disabled(!settings.format.supportsAlpha)
                    Toggle(L10n.tr("Include capture metadata"), isOn: $model.exportSettings.includeMetadata)
                    Toggle(L10n.tr("Include GPS"), isOn: Binding(
                        get: { settings.includeMetadata && settings.includeLocation },
                        set: { model.exportSettings.includeLocation = $0 }))
                        .disabled(!settings.includeMetadata)
                    if let latent = model.latentType { LatentCheckbox(type: latent) }
                }.toggleStyle(.formCheckbox)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View { ExportRow(label, content: content) }
}

/// Label column on the left, control column on the right, both left-aligned so pickers, fields,
/// sliders and checkboxes share one vertical axis.
struct ExportRow<Content: View>: View {
    static var labelWidth: CGFloat { 104 }
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: Self.labelWidth, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 26)
    }
}

private struct ExportSizeControls<Model: ExportTarget>: View {
    @ObservedObject var model: Model
    @State private var widthText = ""
    @State private var heightText = ""
    private var sizing: ExportSizing { model.exportSettings.sizing }
    private var source: CGSize { model.outputSize ?? .zero }
    private var sizeError: String? {
        do { _ = try model.exportSettings.dimensions(for: source); return nil }
        catch { return error.localizedDescription }
    }
    private var upscales: Bool {
        guard let size = try? sizing.dimensions(for: source) else { return false }
        return Double(size.width) > source.width || Double(size.height) > source.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportRow(L10n.tr("Size")) {
                FormSelect(L10n.tr("Export size"), selection: Binding(get: { sizing.preset }, set: {
                    model.exportSettings.sizing.select($0, source: source); synchronizeFields()
                }), valueLabel: presetLabel(sizing.preset)) {
                    ForEach(ExportSizePreset.allCases, id: \.self) { preset in
                        Text(presetLabel(preset)).tag(preset)
                    }
                }.labelsHidden()
            }
            ExportRow("") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        dimension(L10n.tr("Width"), text: Binding(get: { widthText }, set: { text in
                            widthText = text
                            model.exportSettings.sizing.setWidth(Int(text) ?? 0, source: source)
                            if sizing.height > 0 { heightText = String(sizing.height) }
                        }))
                        dimension(L10n.tr("Height"), text: Binding(get: { heightText }, set: { text in
                            heightText = text
                            model.exportSettings.sizing.setHeight(Int(text) ?? 0, source: source)
                            if sizing.width > 0 { widthText = String(sizing.width) }
                        }))
                    }
                    if let sizeError {
                        Text(sizeError).foregroundStyle(Theme.error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    } else if upscales { note(L10n.tr("Larger than the original")) }
                }
            }
        }
        .onAppear(perform: synchronizeFields)
        .onChange(of: sizing) { _, _ in synchronizeFields() }
        .onChange(of: model.outputSize) { _, _ in
            model.exportSettings.sizing.updateSource(source)
            synchronizeFields()
        }
    }

    private func dimension(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, text: text).textFieldStyle(.plain).monospacedDigit().accessibilityLabel(L10n.tr("Export \(label.lowercased()) in pixels"))
                Text(L10n.tr("px")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .formFieldSurface()
        }.frame(maxWidth: 110)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    private func presetLabel(_ preset: ExportSizePreset) -> String {
        guard preset != .custom else { return preset.localizedTitle }
        var value = sizing; value.preset = preset
        guard let size = try? value.dimensions(for: source) else { return preset.localizedTitle }
        return "\(preset.localizedTitle) - \(size.label)"
    }
    private func synchronizeFields() {
        if let size = try? sizing.dimensions(for: source) {
            widthText = String(size.width); heightText = String(size.height)
        }
    }
}

/// Sizes for a selection: a long edge every photo fits in, never fixed width and height.
private struct BatchSizeControls<Model: ExportTarget>: View {
    @ObservedObject var model: Model
    @State private var edgeText = ""
    private var sizing: ExportSizing { model.exportSettings.sizing }
    private var choice: ExportSizePreset { sizing.longEdge != nil ? .custom : sizing.preset }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ExportRow(L10n.tr("Size")) {
                FormSelect(L10n.tr("Export size"), selection: Binding(get: { choice }, set: { value in
                    if value == .custom {
                        let edge = sizing.longEdge ?? sizing.preset.longEdge ?? 2048
                        model.exportSettings.sizing.preset = .original; model.exportSettings.sizing.longEdge = edge; edgeText = String(edge)
                    } else { model.exportSettings.sizing.longEdge = nil; model.exportSettings.sizing.preset = value }
                }), valueLabel: choice == .custom ? L10n.tr("Long edge") : choice.longEdge.map { L10n.tr("\(choice.localizedTitle) - \($0) px long edge") } ?? choice.localizedTitle) {
                    ForEach(ExportSizePreset.allCases, id: \.self) { preset in
                        Text(preset == .custom ? L10n.tr("Long edge") : preset.longEdge.map { L10n.tr("\(preset.localizedTitle) - \($0) px long edge") } ?? preset.localizedTitle).tag(preset)
                    }
                }.labelsHidden()
            }
            if choice == .custom {
                ExportRow("") {
                    HStack(spacing: 4) {
                        TextField(L10n.tr("Long edge"), text: Binding(get: { edgeText }, set: { text in
                            edgeText = text
                            if let edge = Int(text), edge >= 1 { model.exportSettings.sizing.longEdge = min(edge, ExportSizing.maximumDimension) }
                        })).textFieldStyle(.plain).monospacedDigit().accessibilityLabel(L10n.tr("Long edge in pixels"))
                        Text(L10n.tr("px")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .formFieldSurface().frame(maxWidth: 110)
                }
            }
        }
        .onAppear { if let edge = sizing.longEdge { edgeText = String(edge) } }
    }
}
