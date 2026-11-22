import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// The tool panels with the histogram, 350 points wide unless widened from its left edge; with the inspector hidden
/// only the tool rail stays.
struct EditorInspector: View {
    static let widths: ClosedRange<Double> = 350...560
    static let defaultWidth = 350.0
    @AppStorage("editorInspectorWidth") private var width = EditorInspector.defaultWidth
    @ObservedObject var model: EditorModel
    /// Not observed here, so catalog changes don't redraw every slider; the views that need it observe it themselves.
    let catalog: CatalogModel
    @State private var mixerColor = 0
    var body: some View {
        Group {
            if model.showInspector { inspector.frame(width: min(Self.widths.upperBound, max(Self.widths.lowerBound, width))) } else { toolRail.background(Theme.panel) }
        }
        .onChange(of: model.targetAdjustments.selectiveColors.count) { _, count in model.selectiveColorBand = min(model.selectiveColorBand, count - 1) }
    }
    private var inspector: some View {
        HStack(spacing: 0) {
            // No title above the panel: the rail's icons carry the names, as accessibility labels and tooltips, and
            // VoiceOver reads the open tool's name for the panel.
            VStack(spacing: 0) {
                if [.light, .detail].contains(model.toolTab) { AdjustmentTargetBar(model: model); Rule() }
                // Only the combined Light & Color panel needs the histogram.
                if model.toolTab == .light {
                    HistogramView(model: model).padding(.horizontal, 18).padding(.vertical, 12)
                    Rule()
                }
                // Looks scrolls only its library, between the applied looks and the search bar.
                // Info brings the Library's inspector, which scrolls itself.
                if model.toolTab == .looks { LooksPanel(model: model, catalog: catalog) }
                else if model.toolTab == .info { DevelopInfoPanel(editor: model, catalog: catalog) } else { ScrollView {
                    // Rebuilt for each photo so no panel keeps the last one's state; the scroll position stays.
                    Group { switch model.toolTab {
                    case .crop: CropPanel(model: model)
                    case .remove: RetouchPanel(model: model)
                    case .face: FacePanel(model: model)
                    case .history: HistoryPanel(model: model)
                    case .masks: MaskPanel(model: model)
                    case .darkroom: FilmPanel(model: model)
                    default: controls.disabled(!model.hasImage || model.busy).opacity(model.hasImage ? 1 : 0.4)
                    } }.id(model.documentID)
                } }
            }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain).accessibilityLabel(model.toolTab.localizedTitle)
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1)
            toolRail
        }.background(Theme.panel)
    }
    /// Stays visible when the inspector is hidden; choosing a tool brings the inspector back. The editing tools sit at the
    /// top and the panels that only show information (History, Info) at the bottom.
    private var toolRail: some View {
        VStack(spacing: 8) {
            ForEach(ToolTab.allCases.filter { !$0.isReference }, id: \.self, content: railButton)
            Spacer()
            // History is the catalog's; a folder's photo has none to show.
            ForEach(ToolTab.allCases.filter { $0.isReference && !($0 == .history && catalog.isFolderIndex) }, id: \.self, content: railButton)
        }.padding(.horizontal, 6).padding(.vertical, 8)
    }
    private func railButton(_ tab: ToolTab) -> some View {
        ToolRailButton(icon: tab.icon, title: tab.localizedTitle, shortcut: tab.shortcutLabel, active: model.showInspector && model.toolTab == tab) { model.toggleTool(tab) }
    }
    private var controls: some View {
        VStack(spacing: 0) {
            if model.toolTab == .light {
            if !model.isLocalTarget { EditHeaderPanel(model: model) }
            EditorSection(key: "Light", title: L10n.tr("Light"), icon: "sun.max", open: true, reset: { model.resetSection(.light) }, isEnabled: sectionBinding(.light)) {
                adjustment("Exposure", \.exposure, -5...5, unit: "EV")
                adjustment("Contrast", \.contrast)
                adjustment("Highlights", \.highlights)
                adjustment("Shadows", \.shadows)
                adjustment("Whites", \.whites)
                adjustment("Blacks", \.blacks)
            }
            if model.adjustments.hdr.enabled && !model.isLocalTarget { hdrSection }
            EditorSection(key: "Tone curve", title: L10n.tr("Tone curve"), icon: "point.topleft.down.to.point.bottomright.curvepath", open: false, reset: { model.resetSection(.curve) }, isEnabled: sectionBinding(.curve)) {
                CurveChannelPicker(selection: $model.curveChannel)
                CurveView(model: model).frame(height: 164)
                adjustment("Refine saturation", \.curveSaturation, 0...100)
            }
            parametricSection
            EditorSection(key: "Color", title: L10n.tr("Color"), icon: "thermometer.medium", open: true, reset: { model.resetSection(.color) }, isEnabled: sectionBinding(.color)) {
                if !model.isLocalTarget {
                HStack {
                    Text(L10n.tr("White balance")).foregroundStyle(.secondary)
                    Spacer()
                    if model.info?.isRAW == true { EyedropperButton(model: model, target: .whiteBalance) }
                    Menu(L10n.tr("Preset")) {
                        Button(L10n.tr("As shot")) { model.whiteBalance(nil) }
                        Button(L10n.tr("Daylight - 5500 K")) { model.whiteBalance(5500) }
                        Button(L10n.tr("Cloudy - 6500 K")) { model.whiteBalance(6500) }
                        Button(L10n.tr("Shade - 7500 K")) { model.whiteBalance(7500) }
                        Button(L10n.tr("Tungsten - 2850 K")) { model.whiteBalance(2850) }
                    }.fixedSize().menuStyle(.borderlessButton).foregroundStyle(Theme.accent)
                }.font(.system(size: 11)).padding(.bottom, 7)
                adjustment("Temperature", \.temperature, 2000...50000, unit: "K")
                } else { adjustment("Warmth", \.warmth) }
                adjustment("Tint", \.tint, -150...150)
                adjustment("Vibrance", \.vibrance)
                adjustment("Saturation", \.saturation)
                // The photo's own B&W is the header's button; a mask has no header, so its switch is here.
                if model.isLocalTarget {
                    Toggle(L10n.tr("Black & white"), isOn: Binding(get: { model.targetAdjustments.monochrome }, set: { value in model.editTarget { $0.monochrome = value } })).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).padding(.top, 4)
                }
            }
            // In black and white the mixer is the color control that matters, so it comes forward.
            if model.targetAdjustments.monochrome { blackWhiteSection }
            // Keyed by its old name so the disclosure the photographer chose carries over.
            EditorSection(key: "Selective Color", title: L10n.tr("Color Mixer"), icon: "circle.hexagongrid.fill", open: true, reset: { model.resetSection(.selectiveColor) }, isEnabled: sectionBinding(.selectiveColor)) {
                ColorBandPicker(selection: $model.selectiveColorBand)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 2) {
                            TargetedMixerButton(model: model)
                            EyedropperButton(model: model, target: .selectiveColor)
                        }
                    }
                selectiveSlider("Hue", \.hue, -60...60, unit: "°")
                selectiveSlider("Saturation", \.saturation, -100...100)
                selectiveSlider("Luminance", \.luminance, -100...100)
                selectiveSlider("Range", \.range, 0.2...2, unit: "fraction")
            }
            if !model.targetAdjustments.monochrome { blackWhiteSection }
            pointColorSection
            splitToningSection
            calibrationSection
            if !model.isLocalTarget { renderingSection }
            }
            if model.toolTab == .detail {
            // Sharpening and noise reduction first, open until the photographer folds them; Presence and Optics
            // after them, and the effects folded at the end.
            EditorSection(key: "Sharpening", title: L10n.tr("Sharpening"), icon: "triangle", open: true, reset: { model.resetSection(.sharpening) }, isEnabled: sectionBinding(.sharpening)) {
                adjustment("Amount", \.sharpness, model.isLocalTarget ? -100...100 : 0...100)
                adjustment("Radius", \.sharpenRadius, 0.5...3, unit: "fraction")
                adjustment("Detail", \.sharpenDetail, 0...100)
                adjustment("Edge masking", \.sharpenMasking, 0...100)
            }
            EditorSection(key: "Noise Reduction", title: L10n.tr("Noise Reduction"), icon: "aqi.medium", open: true, reset: { model.resetSection(.noiseReduction) }, isEnabled: sectionBinding(.noiseReduction)) {
                adjustment("Luminance noise", \.noiseReduction, 0...100)
                AdjustmentSlider(title: "Color noise", value: Binding(get: { model.targetAdjustments.colorNoiseReduction ?? model.targetAdjustments.noiseReduction }, set: { value in model.editTarget { $0.colorNoiseReduction = value } }), range: 0...100, unit: "", editing: gesture, reset: { model.editTarget { $0.colorNoiseReduction = model.targetDefaults.colorNoiseReduction ?? 0 } })
                if !model.isLocalTarget { AIDenoiseButton(catalog: catalog, editor: model).padding(.top, 4) }
            }
            EditorSection(key: "Presence", title: L10n.tr("Presence"), icon: "circle.and.line.horizontal", open: true, reset: { model.resetSection(.detail) }, isEnabled: sectionBinding(.detail)) {
                adjustment("Texture", \.texture, -100...100)
                adjustment("Clarity", \.clarity, -100...100)
                adjustment("Dehaze", \.dehaze, -100...100)
                if model.isLocalTarget { adjustment("Blur", \.blur, 0...100) }
            }
            if !model.isLocalTarget { opticsSection }
            EditorSection(key: "Defringe", title: L10n.tr("Defringe"), icon: "camera.filters", open: false, reset: { model.resetSection(.defringe) }, isEnabled: sectionBinding(.defringe)) {
                adjustment("Purple amount", \.defringe.purpleAmount, 0...20, appearance: .saturation(0.78))
                rangeAdjustment("Purple hue", \.defringe.purpleLow, \.defringe.purpleHigh, 0...100, appearance: .hueRange(0.667, 1.0), eyedropper: .defringe(.purple))
                adjustment("Green amount", \.defringe.greenAmount, 0...20, appearance: .saturation(0.333))
                rangeAdjustment("Green hue", \.defringe.greenLow, \.defringe.greenHigh, 0...100, appearance: .hueRange(0.167, 0.5), eyedropper: .defringe(.green))
            }
            // A film brings its own grain.
            if model.adjustments.rendering != .film { grainSection }
            EditorSection(key: "Vignette", title: L10n.tr("Vignette"), icon: "circle.lefthalf.filled", open: false, reset: { model.resetSection(.vignette) }, isEnabled: sectionBinding(.vignette)) {
                adjustment("Amount", \.postCropVignette.amount)
                adjustment("Midpoint", \.postCropVignette.midpoint, 0...100)
                adjustment("Feather", \.postCropVignette.feather, 0...100)
                adjustment("Roundness", \.postCropVignette.roundness)
                adjustment("Highlights", \.postCropVignette.highlights, 0...100)
                if model.targetAdjustments.vignette != 0 {
                    adjustment("Legacy strength", \.vignette, 0...100)
                    adjustment("Legacy radius", \.vignetteRadius, 0...1, unit: "fraction")
                    adjustment("Legacy softness", \.vignetteSoftness, 0...1, unit: "fraction")
                }
            }
            }
        }
    }
    private func gesture(_ active: Bool) { if active { model.beginGesture() } else { model.endGesture() } }
    private var parametricSection: some View {
        EditorSection(key: "Parametric curve", title: L10n.tr("Parametric curve"), icon: "waveform.path", open: false, reset: { model.resetSection(.parametricCurve) }, isEnabled: sectionBinding(.parametricCurve)) {
            adjustment("Highlights", \.parametricCurve.highlights)
            adjustment("Lights", \.parametricCurve.lights)
            adjustment("Darks", \.parametricCurve.darks)
            adjustment("Shadows", \.parametricCurve.shadows)
            splitSlider(L10n.tr("Shadow split"), \.shadowSplit, 1...(model.targetAdjustments.parametricCurve.midtoneSplit - 1))
            splitSlider(L10n.tr("Midtone split"), \.midtoneSplit, (model.targetAdjustments.parametricCurve.shadowSplit + 1)...(model.targetAdjustments.parametricCurve.highlightSplit - 1))
            splitSlider(L10n.tr("Highlight split"), \.highlightSplit, (model.targetAdjustments.parametricCurve.midtoneSplit + 1)...99)
        }
    }
    private func splitSlider(_ title: String, _ key: WritableKeyPath<ParametricCurve, Double>, _ range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { model.targetAdjustments.parametricCurve[keyPath: key] }, set: { value in model.editTarget { $0.parametricCurve[keyPath: key] = value } }), range: range, unit: "", editing: gesture, reset: { model.editTarget { $0.parametricCurve[keyPath: key] = min(range.upperBound, max(range.lowerBound, ParametricCurve()[keyPath: key])) } })
    }
    private var blackWhiteSection: some View {
        EditorSection(key: "B&W mixer", title: L10n.tr("B&W mixer"), icon: "circle.lefthalf.filled", open: false, reset: { model.resetSection(.blackWhite) }, isEnabled: sectionBinding(.blackWhite)) {
            ColorBandPicker(selection: $mixerColor)
            AdjustmentSlider(title: "Luminance", value: Binding(get: { model.targetAdjustments.blackWhiteMixer.values[mixerColor] }, set: { value in model.editTarget { $0.blackWhiteMixer.values[mixerColor] = value } }), range: -100...100, unit: "", editing: gesture, reset: { model.editTarget { $0.blackWhiteMixer.values[mixerColor] = 0 } }, appearance: .brightness(ColorBandPicker.hue(at: mixerColor)))
        }
    }
    private var pointColorSection: some View {
        EditorSection(key: "Point color", title: L10n.tr("Point color"), icon: "eyedropper", open: false, reset: { model.resetSection(.pointColor) }, isEnabled: sectionBinding(.pointColor)) { PointColorPanel(model: model) }
    }
    /// HDR output: how far above SDR white it may reach, and the exposure of the tone-mapped SDR rendition that SDR
    /// exports, thumbnails and viewers get. Preview SDR shows that rendition; it changes the view, not the edit.
    private var hdrSection: some View {
        EditorSection(key: "HDR", title: L10n.tr("HDR"), icon: "sun.max.circle", open: true, reset: {
            let defaults = model.targetDefaults
            model.edit { $0.hdr.headroom = defaults.hdr.headroom; $0.hdr.sdrExposure = defaults.hdr.sdrExposure }
        }) {
            adjustment("HDR limit", \.hdr.headroom, 0...10, unit: "EV")
            adjustment("SDR exposure", \.hdr.sdrExposure, -5...5, unit: "EV")
            Toggle(L10n.tr("Preview SDR"), isOn: $model.sdrPreview).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                .help(L10n.tr("Preview the SDR rendition that SDR exports, thumbnails and SDR viewers show."))
        }
    }
    private var splitToningSection: some View {
        EditorSection(key: "Color grading", title: L10n.tr("Color grading"), icon: "circle.lefthalf.striped.horizontal", open: false, reset: { model.resetSection(.splitToning) }, isEnabled: sectionBinding(.splitToning)) {
            ColorGradingPanel(model: model)
        }
    }
    /// How the RAW decoder renders before any adjustment: its tone response. Its lens correction is Detail › Optics.
    private var renderingSection: some View {
        EditorSection(key: "Rendering", title: L10n.tr("Rendering"), icon: "camera.aperture", open: false, reset: {
            guard let defaults = model.info?.defaults else { return }
            model.edit { $0.neutralRAW = defaults.neutralRAW }
        }) {
            HStack {
                Text(L10n.tr("Tone response")).foregroundStyle(.secondary)
                Spacer()
                PanelPicker(title: L10n.tr("Tone response"), selection: Binding(get: { model.adjustments.neutralRAW }, set: { v in model.edit { $0.neutralRAW = v } }),
                            options: [false, true], label: { $0 ? L10n.tr("Neutral - linear tone") : L10n.tr("Camera default") })
                    .controlSize(.small).disabled(model.info?.isRAW != true || model.adjustments.rendering != .camera)
            }.font(.system(size: 11))
            if model.adjustments.cameraProfile.map({ $0.enabled && $0.hasToneCurve }) == true && !model.adjustments.neutralRAW && model.adjustments.rendering == .camera {
                Text(L10n.tr("The camera profile's tone curve replaces the camera default.")).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    /// The lens: the RAW decoder's distortion and vignetting correction, and Wide-Angle Faces beside it. The photo's own,
    /// so a mask shows none of it.
    private var opticsSection: some View {
        EditorSection(key: "Optics", title: L10n.tr("Optics"), icon: "camera.aperture", open: false, reset: {
            guard let defaults = model.info?.defaults else { return }
            model.edit { $0.lensCorrection = defaults.lensCorrection }
        }) {
            Toggle(L10n.tr("Lens correction"), isOn: Binding(get: { model.adjustments.lensCorrection }, set: { v in model.edit { $0.lensCorrection = v } }))
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.info?.lensCorrectionSupported != true)
                .help(model.info?.lensCorrectionSupported == true ? L10n.tr("Distortion and vignetting correction from the RAW decoder") : L10n.tr("This camera or lens has no built-in correction data"))
            WideAngleButton(catalog: catalog, editor: model).padding(.top, 4)
        }
    }
    private var calibrationSection: some View {
        EditorSection(key: "Primary calibration", title: L10n.tr("Primary calibration"), icon: "slider.horizontal.3", open: false, reset: { model.resetSection(.calibration) }, isEnabled: sectionBinding(.calibration)) {
            adjustment("Shadow tint", \.calibration.shadowTint)
            adjustment("Red hue", \.calibration.redHue)
            adjustment("Red saturation", \.calibration.redSaturation)
            adjustment("Green hue", \.calibration.greenHue)
            adjustment("Green saturation", \.calibration.greenSaturation)
            adjustment("Blue hue", \.calibration.blueHue)
            adjustment("Blue saturation", \.calibration.blueSaturation)
        }
    }
    /// Global only: the film replaces the RAW's tone response, which masks cannot change locally.
    private var grainSection: some View {
        EditorSection(key: "Film grain", title: L10n.tr("Film grain"), icon: "circle.dotted", open: false, reset: { model.resetSection(.grain) }, isEnabled: sectionBinding(.grain)) {
            adjustment("Amount", \.grain.amount, 0...100)
            adjustment("Size", \.grain.size, 0...100)
            adjustment("Roughness", \.grain.roughness, 0...100)
        }
    }
    private func sectionBinding(_ section: AdjustmentGroup) -> Binding<Bool> {
        Binding(get: { !model.targetAdjustments.disabledSections.contains(section) }, set: { model.setSection(section, enabled: $0) })
    }
    private func selectiveSlider(_ title: String, _ key: WritableKeyPath<SelectiveColorAdjustment, Double>, _ range: ClosedRange<Double>, unit: String = "") -> some View {
        let selectedColor = min(model.selectiveColorBand, model.targetAdjustments.selectiveColors.count - 1)
        let hue = ColorBandPicker.hue(at: selectedColor)
        return AdjustmentSlider(title: title, value: Binding(get: { model.targetAdjustments.selectiveColors[selectedColor][keyPath: key] }, set: { value in model.editTarget { $0.selectiveColors[selectedColor][keyPath: key] = value } }), range: range, unit: unit, editing: { active in if active { model.beginGesture() } else { model.endGesture() } }, reset: { model.editTarget { $0.selectiveColors[selectedColor][keyPath: key] = SelectiveColorAdjustment()[keyPath: key] } }, appearance: title == "Hue" ? .hueShift(hue) : title == "Saturation" ? .saturation(hue) : title == "Luminance" ? .brightness(hue) : .neutral)
    }
    private func adjustment(_ title: String, _ key: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double> = -100...100, unit: String = "", appearance: SliderAppearance? = nil) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { model.targetAdjustments[keyPath: key] }, set: { value in model.editTarget { $0[keyPath: key] = value } }), range: range, unit: unit, editing: { active in if active { model.beginGesture() } else { model.endGesture() } }, reset: { model.editTarget { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, model.targetDefaults[keyPath: key])) } }, appearance: appearance)
    }
    /// A low/high pair of adjustments on one two-thumb slider; the bounds keep their order whichever one moves.
    private func rangeAdjustment(_ title: String, _ lowKey: WritableKeyPath<Adjustments, Double>, _ highKey: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>, unit: String = "", appearance: SliderAppearance? = nil, eyedropper: EyedropperTarget? = nil) -> some View {
        func clamp(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
        return AdjustmentRangeSlider(title: title, low: model.targetAdjustments[keyPath: lowKey], high: model.targetAdjustments[keyPath: highKey], range: range, unit: unit,
            set: { low, high in model.editTarget { $0[keyPath: lowKey] = low; $0[keyPath: highKey] = high } },
            editing: { active in if active { model.beginGesture() } else { model.endGesture() } },
            reset: { model.editTarget { $0[keyPath: lowKey] = clamp(model.targetDefaults[keyPath: lowKey]); $0[keyPath: highKey] = clamp(model.targetDefaults[keyPath: highKey]) } },
            appearance: appearance, eyedropper: eyedropper.map { EyedropperButton(model: model, target: $0) })
    }
}

/// Tools › AI Noise Reduction… from the Detail section: opens the same dialog for the same photos.
private struct AIDenoiseButton: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        let targets = catalog.cullingTargets(editor: editor)
        Button { catalog.requestDenoise(targets) } label: {
            Label(L10n.tr("AI Noise Reduction…"), systemImage: "wand.and.sparkles").frame(maxWidth: .infinity)
        }
        .buttonStyle(.secondaryAction)
        .disabled(!catalog.canDenoise(targets) || catalog.denoise != nil)
        .help(L10n.tr("Cleans RAW noise with the AI model into a new DNG beside the photo"))
    }
}

/// Tools › Wide-Angle Faces… from Rendering, beside the lens's own correction: opens the dialog for the same photos.
private struct WideAngleButton: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        let targets = catalog.cullingTargets(editor: editor)
        Button { catalog.requestWideAngle(targets) } label: {
            Label(L10n.tr("Wide-Angle Faces…"), systemImage: "person.2.wave.2").frame(maxWidth: .infinity)
        }
        .buttonStyle(.secondaryAction)
        .disabled(!catalog.canCorrectWideAngle(targets) || catalog.wideAngle != nil)
        .help(L10n.tr("Undoes the stretch of people at the sides of a wide-angle shot into a new copy beside the photo"))
    }
}

/// Arms the targeted adjustment: drag on the photo to move the bands of the color under the pointer.
private struct TargetedMixerButton: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let active = model.targetedMixer != nil
        Button(action: model.toggleTargetedMixer) {
            Image(systemName: "scope").font(.system(size: 12)).frame(width: 22, height: 20)
                .background(active ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(active ? Theme.accent : .secondary).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!model.hasImage)
            .help(active ? L10n.tr("Stop adjusting on the photo (Esc)") : L10n.tr("Adjust on the photo: drag left or right over a color to change its hue, saturation or luminance"))
            .accessibilityLabel(L10n.tr("Adjust colors on the photo")).accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Floats over the photo while the targeted adjustment is armed: which property a drag changes, as in other RAW editors.
struct TargetedMixerBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        PhotoBar {
            Image(systemName: "scope").foregroundStyle(Theme.accent).padding(.horizontal, 6)
            Rectangle().fill(Theme.ink.opacity(0.15)).frame(width: 1, height: 16)
            ForEach(MixerProperty.allCases, id: \.self) { property in
                PhotoBarChoice(title: property.localizedTitle, selected: model.targetedMixer == property) { model.targetedMixer = property }
            }
            Text(L10n.tr("Drag on the photo")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
            Button { model.targetedMixer = nil } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Close (Esc)")).accessibilityLabel(L10n.tr("Close"))
        }
    }
}

private struct ColorBandPicker: View {
    @Binding var selection: Int
    private var names: [String] { SelectiveColor.names.map { L10n.key($0) } }
    static func hue(at index: Int) -> Double {
        let hues = [0.0, 30, 60, 120, 180, 240, 270, 300]
        return hues[min(max(0, index), hues.count - 1)] / 360
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(names.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        Circle().fill(Color(hue: Self.hue(at: index), saturation: 0.8, brightness: 0.9))
                            .frame(width: 15, height: 15).padding(6)
                            .overlay(Circle().stroke(selection == index ? .white : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).frame(maxWidth: .infinity).help(names[index])
                        .accessibilityLabel(names[index])
                        .accessibilityAddTraits(selection == index ? .isSelected : [])
                }
            }
            Text(names[min(max(0, selection), names.count - 1)]).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The tone curve's channels as a row of segments drawn like the panels' buttons (`ActionButtonStyle`): RGB by name,
/// the single channels as dots of pure red, green and blue.
private struct CurveChannelPicker: View {
    @Binding var selection: CurveChannel
    @State private var hovered: CurveChannel?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(CurveChannel.allCases, id: \.self) { channel in
                let chosen = selection == channel
                Button { selection = channel } label: {
                    Group {
                        if let color = Self.color(channel) { Circle().fill(color).frame(width: 9, height: 9) }
                        else { Text(channel.localizedTitle).font(.system(size: 11, weight: .semibold)) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .background(Theme.ink.opacity(chosen ? 0.2 : hovered == channel ? 0.07 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                .buttonStyle(.plain).foregroundStyle(chosen ? .primary : .secondary)
                .onHover { hovered = $0 ? channel : (hovered == channel ? nil : hovered) }
                .help(channel.localizedTitle).accessibilityLabel(channel.localizedTitle)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2).background(Theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Channel"))
    }
    private static func color(_ channel: CurveChannel) -> Color? {
        switch channel {
        case .rgb: nil
        case .red: Color(.sRGB, red: 1, green: 0, blue: 0)
        case .green: Color(.sRGB, red: 0, green: 1, blue: 0)
        case .blue: Color(.sRGB, red: 0, green: 0, blue: 1)
        }
    }
}

struct EditorSection<Content: View>: View {
    let title: String
    let icon: String
    /// Open or folded: one setting per section for every photo, kept across launches under the section's stable key.
    @AppStorage private var open: Bool
    let reset: () -> Void
    /// The section's on/off switch; settings that cannot be switched off as a group have none.
    var isEnabled: Binding<Bool>?
    @ViewBuilder let content: () -> Content
    /// `open` is how the section starts until it is first folded or opened.
    init(key: String, title: String, icon: String, open: Bool, reset: @escaping () -> Void, isEnabled: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.icon = icon; _open = AppStorage(wrappedValue: open, "developSectionOpen." + key)
        self.reset = reset; self.isEnabled = isEnabled; self.content = content
    }
    private var enabled: Bool { isEnabled?.wrappedValue ?? true }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { open.toggle() } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(action: reset) { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Reset \(L10n.key(title))"))
                    .accessibilityLabel(L10n.tr("Reset \(title)"))
                if let isEnabled {
                    Button { isEnabled.wrappedValue.toggle() } label: {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                            .foregroundStyle(enabled ? Theme.accent : .secondary)
                    }.buttonStyle(.plain).help(enabled ? L10n.tr("Disable \(title)") : L10n.tr("Enable \(title)"))
                        .accessibilityLabel(L10n.tr("Enable \(title)")).accessibilityValue(enabled ? L10n.tr("On") : L10n.tr("Off"))
                }
            }.padding(.vertical, 13)
            if open { VStack(spacing: 10, content: content).padding(.bottom, 16).disabled(!enabled).opacity(enabled ? 1 : 0.4) }
        }.padding(.horizontal, 14)
            .card()
            .padding(.horizontal, 10).padding(.vertical, 4)
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let editing: (Bool) -> Void
    let reset: () -> Void
    var appearance: SliderAppearance? = nil
    private var label: String { unit == "%" ? String(format: "%.0f%%", locale: Locale.current, value) : unit == "fraction" ? String(format: "%.2f", locale: Locale.current, value) : unit == "EV" ? String(format: "%+.2f", locale: Locale.current, value) : unit == "K" ? "\(Int(value)) K" : unit == "px" ? String(format: "%.1f px", locale: Locale.current, value) : unit == "°" ? String(format: "%+.1f°", locale: Locale.current, value) : String(format: "%+.0f", locale: Locale.current, value) }
    private var precision: Int { unit == "fraction" || unit == "EV" ? 2 : unit == "°" || unit == "px" ? 1 : 0 }
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                HStack { Text(L10n.key(title)).foregroundStyle(.secondary); Spacer(minLength: 0) }.contentShape(Rectangle()).onTapGesture(count: 2, perform: reset).help(L10n.tr("Double-click to reset"))
                EditableValue(label: label, value: value, range: range, precision: precision, title: L10n.key(title), width: unit == "K" ? 64 : 56, editing: editing) { value = $0 }
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }.font(.system(size: 11))
            ResettableSlider(value: $value, range: range, title: title, editing: editing, reset: reset, appearance: appearance ?? .parameter(title)).frame(height: 18)
        }
    }
}
