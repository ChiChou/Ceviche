import SwiftUI
import CevicheCore

/// Compare, zoom and the filmstrip for the open photo, in the editor's bottom bar.
struct EditorViewControls: View {
    @ObservedObject var model: EditorModel
    var showsZoomSlider = true
    var body: some View {
        HStack(spacing: 10) {
            Button { model.comparing.toggle() } label: {
                Image(systemName: "rectangle.lefthalf.inset.filled").frame(width: 28, height: 28).contentShape(Rectangle())
            }.foregroundStyle(model.comparing ? Theme.accent : .secondary)
                .help(model.comparing ? L10n.tr("Hide Original Comparison (⇧\\)") : L10n.tr("Compare with Original (⇧\\) · Hold \\ to peek"))
                .accessibilityHint(L10n.tr("Hold \\ to peek at the original"))
                .accessibilityLabel(L10n.tr("Compare")).accessibilityAddTraits(model.comparing ? .isSelected : [])
            PrintProofToggle(proof: model.proof)
            Button { model.showCaptureOverlay.toggle() } label: {
                Image(systemName: "info").frame(width: 28, height: 28).contentShape(Rectangle())
            }.foregroundStyle(model.showCaptureOverlay ? Theme.accent : .secondary)
                .help(L10n.tr("Capture Info (⇧I)"))
                .accessibilityLabel(L10n.tr("Capture Info")).accessibilityAddTraits(model.showCaptureOverlay ? .isSelected : [])
            Rule(.vertical).frame(height: 16)
            ZoomControls(model: model, showsSlider: showsZoomSlider)
            Rule(.vertical).frame(height: 16)
            if model.catalogAssetID != nil { FilmstripToggle(editor: model) }
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).disabled(!model.hasImage)
    }
}

/// Shows the photo as a print would: the proof's settings appear above it.
private struct PrintProofToggle: View {
    @ObservedObject var proof: PrintProofState
    var body: some View {
        Button { proof.on.toggle() } label: {
            Image(systemName: "printer").frame(width: 28, height: 28).contentShape(Rectangle())
        }.foregroundStyle(proof.on ? Theme.accent : .secondary)
            .help(proof.on ? L10n.tr("Hide Print Proof (⌘Y)") : L10n.tr("Print Proof (⌘Y)"))
            .accessibilityLabel(L10n.tr("Print Proof")).accessibilityAddTraits(proof.on ? .isSelected : [])
    }
}

/// Fit, the zoom buttons and slider, and the current magnification.
struct ZoomControls: View {
    @ObservedObject var model: EditorModel
    var showsSlider = true
    private var zoom: Binding<Double> {
        Binding(get: { Self.sliderPosition(for: model.viewport.scale) }, set: { model.zoomImage(to: Self.scale(atSliderPosition: $0)) })
    }
    /// Most work happens between fit and 8×, so that range gets 80% of the travel (logarithmic within it);
    /// the rarely used 8×–16× is compressed into the last 20%. Pinch zoom is unaffected.
    static let detailedRange = 8.0, detailedTravel = 0.8
    static func scale(atSliderPosition t: Double) -> Double {
        let t = min(1, max(0, t))
        if t <= detailedTravel { return pow(detailedRange, t / detailedTravel) }
        return detailedRange * pow(ImageViewport.maximum / detailedRange, (t - detailedTravel) / (1 - detailedTravel))
    }
    static func sliderPosition(for scale: Double) -> Double {
        let scale = min(ImageViewport.maximum, max(1, scale))
        if scale <= detailedRange { return log(scale) / log(detailedRange) * detailedTravel }
        return detailedTravel + log(scale / detailedRange) / log(ImageViewport.maximum / detailedRange) * (1 - detailedTravel)
    }
    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleImageFit() } label: { Text(L10n.tr("Fit")).fixedSize().frame(height: 28).contentShape(Rectangle()) }
                .foregroundStyle(model.viewport.isFitted ? Theme.accent : .secondary)
                .help(model.viewport.isFitted ? L10n.tr("Zoom to 2× fitted size (Space or Z)") : L10n.tr("Fit photograph to canvas (Space or Z)"))
            // Pinch and View > Zoom In/Out (⌘= and ⌘-) step the zoom, so the bar needs only the slider.
            if showsSlider {
                FormSlider(value: zoom, in: 0...1).frame(width: 90)
                    .help(L10n.tr("Magnification relative to fitted size")).accessibilityLabel(L10n.tr("Zoom"))
                    .accessibilityValue(L10n.tr("\(model.viewport.scale, specifier: "%.2g") times"))
            }
            Text(String(format: "%g×", locale: Locale.current, (model.viewport.scale * 10).rounded() / 10)).monospacedDigit().frame(minWidth: 40, alignment: .trailing)
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).disabled(!model.hasImage)
    }
}

/// The filmstrip toggle for Compare, which has no zoom.
struct CompareViewControls: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 10) {
            if editor.catalogAssetID != nil { FilmstripToggle(editor: editor) }
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
    }
}

/// The view switch at the left of the bottom bar: Map or People where the collection has an overview, then the wall,
/// the grid, Compare and Detail.
struct ViewModePicker: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 2) {
            if let overview = catalog.collectionOverview {
                ViewSwitchButton(icon: overview.icon, title: overview.title, active: catalog.shownOverview != nil, help: L10n.tr("\(overview.title) (⌘↑)")) {
                    catalog.showOverview(editor: editor)
                }
                Rule(.vertical).frame(height: 14).padding(.horizontal, 3)
            }
            ForEach(CatalogModel.GridStyle.allCases.reversed()) { style in
                ViewSwitchButton(icon: style.icon, title: style.title, active: catalog.showingPhotos && catalog.gridStyle == style, help: Self.help(for: style)) {
                    catalog.showPhotos(style, editor: editor)
                }
            }
            ForEach([CatalogModel.ViewMode.compare, .detail]) { mode in
                let active = catalog.viewMode == mode
                ViewSwitchButton(icon: mode.icon, title: mode.title, active: active, help: Self.help(for: mode)) { catalog.show(mode, editor: editor) }
                    .disabled(!active && !catalog.canShow(mode, editor: editor))
            }
        }
    }
    static func help(for mode: CatalogModel.ViewMode) -> String {
        switch mode { case .grid: return L10n.tr("Grid (G, ⌘2)"); case .compare: return L10n.tr("Compare (⌥C, ⌘3)"); case .detail: return L10n.tr("Detail (D, ⌘4)") }
    }
    static func help(for style: CatalogModel.GridStyle) -> String {
        style == .tiles ? L10n.tr("Grid (G, ⌘2)") : L10n.tr("Wall (G from the grid, ⌘1)")
    }
    /// The icon of what the main window shows.
    static func icon(_ catalog: CatalogModel) -> String {
        if let overview = catalog.shownOverview { return overview.icon }
        if catalog.showingPersonFaces { return CatalogModel.Overview.faces.icon }
        return catalog.showingLibrary ? catalog.gridStyle.icon : catalog.viewMode.icon
    }
}

/// The view switch as one menu, for a narrow bottom bar: the current view's icon, then the views.
struct ViewModeMenu: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    var body: some View {
        Menu {
            if let overview = catalog.collectionOverview {
                Toggle(isOn: Binding(get: { catalog.shownOverview != nil }, set: { _ in catalog.showOverview(editor: editor) })) { Label(overview.title, systemImage: overview.icon) }
                Divider()
            }
            ForEach(CatalogModel.GridStyle.allCases.reversed()) { style in
                Toggle(isOn: Binding(get: { catalog.showingPhotos && catalog.gridStyle == style },
                                     set: { _ in catalog.showPhotos(style, editor: editor) })) { Label(style.title, systemImage: style.icon) }
            }
            ForEach([CatalogModel.ViewMode.compare, .detail]) { mode in
                Toggle(isOn: Binding(get: { catalog.viewMode == mode }, set: { _ in catalog.show(mode, editor: editor) })) { Label(mode.title, systemImage: mode.icon) }
                    .disabled(catalog.viewMode != mode && !catalog.canShow(mode, editor: editor))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ViewModePicker.icon(catalog)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 6).frame(height: 28).background(Theme.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
            .help(catalog.showingLibrary ? ViewModePicker.help(for: catalog.gridStyle) : ViewModePicker.help(for: catalog.viewMode))
            .accessibilityLabel(L10n.tr("View"))
    }
}

/// What a narrow bottom bar leaves out: the edit clipboard, and with `viewControls` the view's own controls.
struct StatusBarMoreMenu: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    let viewControls: Bool
    var body: some View {
        Menu {
            Section {
                Button(L10n.tr("Copy Edits")) { catalog.copyCurrentEdits(editor: editor) }
                Button(L10n.tr("Copy Changed Edits")) { catalog.copyCurrentEdits(editor: editor, .edited) }
                Button(L10n.tr("Copy Selected Edits…")) { catalog.copyCurrentEdits(editor: editor, .choosing) }
            }.disabled(!catalog.canCopyEdits(editor: editor))
            Button(L10n.tr("Paste Edits")) { catalog.pasteCopiedEdits(editor: editor) }.disabled(!catalog.canPasteEdits(editor: editor))
            if viewControls { viewItems }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14)).frame(height: 28).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
            .help(L10n.tr("More")).accessibilityLabel(L10n.tr("More"))
    }
    @ViewBuilder private var viewItems: some View {
        if catalog.showingLibrary {
            if catalog.shownOverview != .map {
                Divider()
                Button(L10n.tr("Larger Thumbnails")) { catalog.stepTileSize(larger: true) }.disabled(catalog.tileSize >= CatalogModel.tileSizes.upperBound)
                Button(L10n.tr("Smaller Thumbnails")) { catalog.stepTileSize(larger: false) }.disabled(catalog.tileSize <= CatalogModel.tileSizes.lowerBound)
            }
        } else {
            if catalog.viewMode == .detail {
                Divider()
                Group {
                    Toggle(L10n.tr("Compare with Original"), isOn: $editor.comparing)
                    Toggle(L10n.tr("Capture Info"), isOn: $editor.showCaptureOverlay)
                    Divider()
                    Button(L10n.tr("Zoom to Fit")) { editor.viewport.fit() }.disabled(editor.viewport.isFitted)
                    Button(L10n.tr("Zoom In"), action: editor.zoomImageIn)
                    Button(L10n.tr("Zoom Out"), action: editor.zoomImageOut)
                }.disabled(!editor.hasImage)
            }
            if editor.catalogAssetID != nil {
                Divider()
                Toggle(L10n.tr("Filmstrip"), isOn: $editor.showFilmstrip)
                if !editor.inFolder { Toggle(L10n.tr("Culling Bar"), isOn: $editor.showCullingBar) }
                Picker(L10n.tr("Filmstrip Style"), selection: $editor.filmstripStyle) {
                    Text(L10n.tr("Photo")).tag(EditorModel.FilmstripStyle.photo)
                    Text(L10n.tr("Square")).tag(EditorModel.FilmstripStyle.square)
                }
            }
        }
    }
}

/// One button of a view switch.
struct ViewSwitchButton: View {
    let icon: String
    let title: String
    let active: Bool
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.iconOnly)
                .font(.system(size: 15, weight: active ? .semibold : .regular)).frame(width: 32, height: 28)
                .background(active ? Theme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle()).help(help)
        }.buttonStyle(.plain).foregroundStyle(active ? Theme.accent : .secondary)
            .help(help).accessibilityElement(children: .ignore)
            .accessibilityLabel(title).accessibilityHint(help).accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Shows or hides a panel; highlighted while the panel is visible.
struct PanelToggle<Icon: View>: View {
    let title: String
    let shortcut: String
    @Binding var isOn: Bool
    let icon: Icon
    init(title: String, shortcut: String, isOn: Binding<Bool>, @ViewBuilder icon: () -> Icon) {
        self.title = title; self.shortcut = shortcut; _isOn = isOn; self.icon = icon()
    }
    var body: some View {
        Button { isOn.toggle() } label: {
            icon.frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(isOn ? Theme.accent : .secondary)
            .help((isOn ? L10n.tr("Hide \(title) (\(shortcut))") : L10n.tr("Show \(title) (\(shortcut))")))
            .accessibilityLabel(title).accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
extension PanelToggle where Icon == Image {
    init(icon: String, title: String, shortcut: String, isOn: Binding<Bool>) {
        self.init(title: title, shortcut: shortcut, isOn: isOn) { Image(systemName: icon) }
    }
}

/// The filmstrip's toggle, drawn like the sidebar's with the panel along the bottom edge, and a small menu after it
/// to choose its style.
struct FilmstripToggle: View {
    @ObservedObject var editor: EditorModel
    var body: some View {
        HStack(spacing: 0) {
            PanelToggle(title: L10n.tr("Filmstrip"), shortcut: "/", isOn: $editor.showFilmstrip) { BottomPanelIcon().frame(width: 16.5, height: 12.5) }
            Menu {
                // Choosing a style or the culling bar also shows a hidden filmstrip.
                Picker(L10n.tr("Filmstrip Style"), selection: Binding(get: { editor.filmstripStyle }, set: { editor.filmstripStyle = $0; editor.showFilmstrip = true })) {
                    Text(L10n.tr("Photo")).tag(EditorModel.FilmstripStyle.photo)
                    Text(L10n.tr("Square")).tag(EditorModel.FilmstripStyle.square)
                }.pickerStyle(.inline).labelsHidden()
                Divider()
                if !editor.inFolder { Toggle(L10n.tr("Culling Bar"), isOn: Binding(get: { editor.showCullingBar }, set: { editor.showCullingBar = $0; if $0 { editor.showFilmstrip = true } })) }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(L10n.tr("Filmstrip Style")).accessibilityLabel(L10n.tr("Filmstrip Style"))
        }
    }
}

/// sidebar.left turned to the bottom edge, as SF Symbols has no bottom-panel glyph: the frame, a divider over a bottom
/// strip, and three short marks in it. Proportions follow the symbol at the status bar's 11-point size.
struct BottomPanelIcon: View {
    var body: some View {
        Canvas { context, size in
            let line = size.width * 0.075, inset = line / 2
            let frame = CGRect(x: inset, y: inset, width: size.width - line, height: size.height - line)
            context.stroke(Path(roundedRect: frame, cornerRadius: size.height * 0.22), with: .foreground, lineWidth: line)
            let divider = size.height * 0.6
            context.fill(Path(CGRect(x: inset, y: divider - line * 0.45, width: frame.width, height: line * 0.9)), with: .foreground)
            let markTop = divider + (size.height - divider) * 0.3, markHeight = (size.height - divider) * 0.36
            for i in 0..<3 {
                context.fill(Path(roundedRect: CGRect(x: size.width * (0.17 + Double(i) * 0.1), y: markTop, width: line * 0.8, height: markHeight),
                                  cornerRadius: line * 0.4), with: .foreground)
            }
        }.accessibilityHidden(true)
    }
}
