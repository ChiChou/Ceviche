import SwiftUI
import AppKit
import CevicheCore

/// Analyzes the brackets once, then redraws the preview from that analysis as the options change.
@MainActor
final class HDRMergeModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: HDRMergeRequest
    /// The preview and the result take the base photo's edits.
    private lazy var developer = MergePreviewDeveloper(assets: request.assets)
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var analysis: HDRMergeAnalysis?
    @Published private(set) var preview: HDRMergePreview?
    @Published private(set) var rendering = false
    @Published private(set) var previewError: String?
    @Published var settings = HDRMergeSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.strokes != oldValue.strokes, !history.applying { history.record(oldValue.strokes) }
            if let selectedLayer, settings.excluded.contains(selectedLayer) { self.selectedLayer = nil }
            remember(); render()
        }
    }
    @Published var showMotion: Bool { didSet { preferences.set(showMotion, forKey: "hdrShowMotion") } }
    let history = BrushHistory<HDRMergeStroke>()
    /// The layer listed on the right that is highlighted over the preview and that the brush paints, by photo index.
    @Published var selectedLayer: Int? { didSet { if selectedLayer == nil { brush = nil } } }
    @Published var brush: FocusStackBrushMode?
    /// The brush's width on screen in points.
    @Published var brushDiameter: Double { didSet { preferences.set(brushDiameter, forKey: "hdrBrushDiameter") } }
    private(set) var merger: HDRMerger?
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let preferences = UserDefaults.standard

    init(request: HDRMergeRequest) {
        self.request = request
        showMotion = preferences.bool(forKey: "hdrShowMotion")
        let diameter = preferences.double(forKey: "hdrBrushDiameter")
        brushDiameter = diameter > 0 ? NightSkyBrushSize.clamped(diameter) : 40
        settings.deghosting = preferences.string(forKey: "hdrDeghosting").flatMap(HDRDeghosting.init(rawValue:)) ?? .medium
        history.current = { [weak self] in self?.settings.strokes }
        history.apply = { [weak self] in self?.settings.strokes = $0 }
    }
    var canMerge: Bool { stage == .ready && preview != nil && previewError == nil && !rendering }
    var reference: Int? { settings.reference ?? analysis?.suggestedReference }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        developer.store = catalog.store
        catalog.hdrMergeHistory = history
        task = Task {
            do {
                var urls: [URL] = []
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                let merger = try HDRMerger(urls: urls)
                merger.retouch = await catalog.retouching(of: request.assets, at: urls)
                let progress: @Sendable (Double, String) -> Void = { fraction, message in
                    Task { @MainActor in
                        guard case .preparing = self.stage else { return }
                        self.stage = .preparing(message.isEmpty ? L10n.tr("Analyzing exposures…") : message, fraction)
                    }
                }
                let work = Task.detached(priority: .userInitiated) { try autoreleasepool { try merger.analyze(progress: progress) } }
                let analysis = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self.merger = merger; self.analysis = analysis
                stage = .preparing(L10n.tr("Creating preview…"), nil)
                render(immediately: true)
            } catch is CancellationError {
            } catch { abort(catalog: catalog, error) }
        }
    }

    /// Draws the preview for the current options. Renders run one at a time; a newer request replaces a waiting one.
    func render(immediately: Bool = false) {
        guard merger != nil else { return }
        let previous = renderTask
        previous?.cancel()
        let settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            if !immediately { try? await Task.sleep(for: .milliseconds(25)) }
            guard !Task.isCancelled, let self, let merger = self.merger else { return }
            self.rendering = true
            let result = await Task.detached(priority: .userInitiated) { autoreleasepool { Result { try merger.preview(settings) } } }.value
            guard !Task.isCancelled else { return }
            var developed: CGImage?
            if case .success(let preview) = result {
                developed = await self.developer.image(preview.source, base: merger.urls[preview.source.base], size: max(preview.image.width, preview.image.height))
                guard !Task.isCancelled else { return }
            }
            self.rendering = false
            switch result {
            case .success(var preview): preview.image = developed ?? preview.image; self.preview = preview; self.previewError = nil
            case .failure(let error): self.previewError = error.localizedDescription
            }
            if case .preparing = self.stage { self.stage = .ready }
        }
    }

    /// The brush's dabs on the preview, in fractions of its width and height and a radius in fractions of its width,
    /// added to the selected layer.
    func paint(_ dabs: [(x: Double, y: Double, radius: Double)]) {
        guard let preview, let layer = selectedLayer, let brush, !dabs.isEmpty else { return }
        let aspect = Double(preview.image.height) / Double(preview.image.width)
        settings.strokes += dabs.map { HDRMergeStroke(x: $0.x, y: $0.y * aspect, radius: $0.radius, photo: layer, add: brush == .add) }
    }
    /// Removes what the brush painted on one layer, or on every layer.
    func resetPainting(_ layer: Int?) {
        settings.strokes.removeAll { layer == nil || $0.photo == layer }
    }

    func toggle(_ index: Int) {
        if settings.excluded.contains(index) { settings.excluded.remove(index) } else { settings.excluded.insert(index) }
    }
    func makeReference(_ index: Int) {
        settings.excluded.remove(index)
        settings.reference = index == analysis?.suggestedReference ? nil : index
    }

    /// Hands the merge to the catalog's background jobs; the originals stay open until it finishes.
    /// Processed photos are kept as `format` asks; RAW photos give a DNG.
    func merge(catalog: CatalogModel, format: ProcessedFormat = .original) {
        guard canMerge, let merger, let analysis else { return }
        let access = self.access
        self.access = []
        let reference = settings.reference ?? analysis.suggestedReference
        catalog.startHDRMerge(merger, analysis: analysis, settings: settings, editsFrom: developer.asset(for: merger.urls[reference]), access: access, format: format)
        close(catalog: catalog)
    }

    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ error: Error) {
        close(catalog: catalog)
        catalog.failure = Failure(L10n.tr("Can’t Merge These Photos"), error)
    }
    func close(catalog: CatalogModel) {
        stop()
        catalog.hdrMerge = nil
        catalog.hdrMergeHistory = nil
    }
    /// Ends the analysis and releases the originals; also when the catalog closes the merge from outside.
    func stop() {
        task?.cancel(); renderTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }

    private func remember() {
        preferences.set(settings.deghosting.rawValue, forKey: "hdrDeghosting")
    }
}

/// HDR merge fills the window like the panorama merge: the preview in the middle, the layers on the right, the brackets in
/// a strip below it, the options and the layer brush under the title bar, Cancel and Merge in the title bar.
struct HDRMergeView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: HDRMergeModel
    @State private var keyMonitor: Any?
    @State private var hoveredLayer: Int?

    init(catalog: CatalogModel, request: HDRMergeRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: HDRMergeModel(request: request))
    }
    var body: some View {
        ToolWorkspace(title: L10n.tr("HDR Merge"), status: status, statusIsWarning: statusIsWarning,
                      primary: L10n.tr("Merge"), primaryDisabled: !model.canMerge,
                      primaryOptions: CatalogModel.processed(model.request.assets) ? [(L10n.tr("Merge to TIFF"), { model.merge(catalog: catalog, format: .tiff) })] : [],
                      cancel: { model.close(catalog: catalog) }, action: { model.merge(catalog: catalog) },
                      toolbar: { toolbar }) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    canvas
                    if model.analysis != nil { layers }
                }
                if model.analysis != nil {
                    Rule()
                    filmstrip
                }
            }
        }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        if let error = model.previewError { return error }
        guard let analysis = model.analysis else { return L10n.tr("\(model.request.assets.count) photos") }
        let unaligned = analysis.frames.filter { $0.shift == nil }.map(\.filename)
        if !unaligned.isEmpty { return L10n.tr("Couldn’t align \(unaligned.joined(separator: ", ")); merged as framed") }
        let used = analysis.frames.count - model.settings.excluded.count
        let range = String(format: "%.1f", locale: Locale.current, analysis.range)
        return L10n.tr("\(used) of \(analysis.frames.count) exposures - \(range) stops")
    }
    private var statusIsWarning: Bool {
        if case .failed = model.stage { return true }
        return model.previewError != nil || model.analysis?.frames.contains { $0.shift == nil } == true
    }

    // MARK: Canvas

    /// The preview on the shared canvas. The motion tint, the selected layer's highlight and the brush lie over the
    /// picture at its shown size, so they move and zoom with it; while a brush is up, dragging paints.
    private var canvas: some View {
        ZStack {
            ZoomCanvas(image: model.preview?.image, dragPans: model.selectedLayer == nil || model.brush == nil) { _ in
                if let preview = model.preview {
                    if model.showMotion, let motion = preview.motion {
                        Color.pink.opacity(0.5).mask(Image(decorative: motion, scale: 1).resizable().interpolation(.high).luminanceToAlpha())
                            .allowsHitTesting(false)
                    }
                    highlight(preview)
                    FocusStackBrush(mode: model.selectedLayer == nil ? nil : model.brush, diameter: model.brushDiameter,
                                    color: model.selectedLayer.flatMap(layerColor) ?? Theme.accent) { model.paint($0) }
                }
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Merge These Photos"), systemImage: "square.3.layers.3d", description: Text(message))
            case .ready: if model.rendering { ToolProgressCard(message: L10n.tr("Creating preview…")).transition(.opacity) }
            }
        }
        .onAppear { watchKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    /// The selected layer in its color, and everything else dimmed.
    @ViewBuilder private func highlight(_ preview: HDRMergePreview) -> some View {
        if let layer = model.selectedLayer, let mask = preview.layers[layer] {
            ZStack {
                Color.black.opacity(0.55)
                    .mask(Image(decorative: mask, scale: 1).resizable().interpolation(.high).colorInvert().luminanceToAlpha())
                (layerColor(layer) ?? Theme.accent).opacity(0.3)
                    .mask(Image(decorative: mask, scale: 1).resizable().interpolation(.high).luminanceToAlpha())
            }.allowsHitTesting(false)
        }
    }

    /// [ and ] make the brush smaller and larger, and the arrows and ⌫ work the layers, unless a text field is being typed in.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if layerKey(event) { return nil }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers,
                  key == "[" || key == "]", !(event.window?.firstResponder is NSText) else { return event }
            model.brushDiameter = NightSkyBrushSize.stepped(model.brushDiameter, larger: key == "]")
            return nil
        }
    }

    // MARK: Toolbar

    /// The options in one row under the title bar, then the layer brush, so the preview keeps the window's full width.
    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(L10n.tr("Deghost")).foregroundStyle(.secondary)
            FormSegments(title: L10n.tr("Deghost"), selection: $model.settings.deghosting, options: HDRDeghosting.allCases, label: { $0.title }).labelsHidden().fixedSize()
                .help(L10n.tr("Where the exposures disagree because something moved, takes that area from the base exposure alone. Higher settings catch smaller changes."))
            Toggle(L10n.tr("Show Motion"), isOn: $model.showMotion)
                .disabled(model.settings.deghosting == .off)
                .help(motionHelp)
            Rule(.vertical).frame(height: 16)
            paintControls
            Spacer(minLength: 0)
        }
        .disabled(model.analysis == nil)
    }

    private var motionHelp: String {
        guard let preview = model.preview, preview.motion != nil else { return L10n.tr("Tints the areas taken from the base exposure alone") }
        let percent = Int((preview.motionCoverage * 100).rounded())
        return L10n.tr("Tints the areas taken from the base exposure alone (\(percent)% of the photo)")
    }

    /// Undo and Redo, the brush size, then the brushes that add to and take from the selected layer and its reset, as in
    /// Focus Stack. A brush icon clicked again puts the brush down.
    @ViewBuilder private var paintControls: some View {
        let layer = model.selectedLayer
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "arrow.uturn.backward", label: L10n.tr("Undo"), action: model.history.undo).disabled(model.history.undoStack.isEmpty)
                .help(L10n.tr("Undoes the last brush stroke or reset (⌘Z)"))
            NightSkyIconButton(icon: "arrow.uturn.forward", label: L10n.tr("Redo"), action: model.history.redo).disabled(model.history.redoStack.isEmpty)
                .help(L10n.tr("Redoes what Undo took back (⇧⌘Z)"))
        }
        NightSkyBrushSize(diameter: $model.brushDiameter)
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "paintbrush.pointed", badge: "plus", label: L10n.tr("Add to Layer"), on: model.brush == .add && layer != nil) { use(.add) }
                .help(L10n.tr("Add to Layer: paint over the preview to take those areas from the selected exposure alone"))
            NightSkyIconButton(icon: "paintbrush.pointed", badge: "minus", label: L10n.tr("Remove from Layer"), on: model.brush == .remove && layer != nil) { use(.remove) }
                .help(L10n.tr("Remove from Layer: paint over the preview to keep the selected exposure out of those areas; the others fill them"))
            NightSkyIconButton(icon: "arrow.counterclockwise", label: L10n.tr("Reset Layer")) { model.resetPainting(layer) }
                .disabled(layer.map { l in !model.settings.strokes.contains { $0.photo == l } } ?? true)
                .help(L10n.tr("Removes what the brushes painted on the selected layer, so it is as the merge chose it"))
        }.disabled(layer == nil)
    }
    private func use(_ mode: FocusStackBrushMode) { model.brush = model.brush == mode ? nil : mode }

    // MARK: Layers

    /// Each included exposure is a layer: its share of the result. Click one to highlight it and paint it.
    private var layers: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("Layers")).font(.headline)
                Spacer()
                Menu {
                    Button(L10n.tr("Reset All Layers")) { model.resetPainting(nil) }.disabled(model.settings.strokes.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }.padding(.horizontal, 12).frame(height: 36)
            Rule()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(layerFrames) { frame in layerRow(frame).id(frame.index) }
                    }.padding(8)
                }
                .onChange(of: model.selectedLayer) { _, layer in
                    if let layer { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(layer) } }
                }
            }
        }
        .frame(width: 260).background(Theme.statusBar)
        .overlay(alignment: .leading) { Rule(.vertical) }
    }

    /// Included exposures darkest first, as in the strip.
    private var layerFrames: [HDRMergeFrameInfo] {
        (model.analysis?.frames ?? []).filter { !model.settings.excluded.contains($0.index) }
    }

    private func layerRow(_ frame: HDRMergeFrameInfo) -> some View {
        let selected = model.selectedLayer == frame.index
        let share = model.preview?.contributions[frame.index] ?? 0
        let painted = model.settings.strokes.contains { $0.photo == frame.index }
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(layerColor(frame.index) ?? .gray).frame(width: 4, height: 38)
            Group {
                if let thumbnail = frame.thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() } else { Color.black }
            }
            .frame(width: 56, height: 38).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(frame.filename).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(stops(frame)).monospacedDigit()
                    Text(L10n.tr("\(Int((share * 100).rounded()))%")).monospacedDigit()
                    if frame.index == model.reference { Text(L10n.tr("- Base")) }
                    if painted { Image(systemName: "paintbrush.pointed.fill").help(L10n.tr("Painted with the layer brushes")) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected || hoveredLayer == frame.index {
                Button { leaveOut(frame.index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(!canLeaveOut(frame.index))
                    .help(L10n.tr("Leave this exposure out of the merge (⌫)"))
            }
        }
        .padding(5)
        .onHover { hoveredLayer = $0 ? frame.index : (hoveredLayer == frame.index ? nil : hoveredLayer) }
        .contextMenu {
            Button(L10n.tr("Leave Out of Merge")) { leaveOut(frame.index) }.disabled(!canLeaveOut(frame.index))
        }
        .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .opacity(share > 0.005 || painted || selected ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLayer = selected ? nil : frame.index }
        .help(L10n.tr("Highlight the areas the result takes from \(frame.filename)"))
    }

    /// The reference stays, and so do the last two exposures.
    private func canLeaveOut(_ index: Int) -> Bool {
        index != model.reference && layerFrames.count > 2
    }
    /// Leaves an exposure out of the merge; when it was selected, the next layer is selected instead.
    private func leaveOut(_ index: Int) {
        guard canLeaveOut(index) else { return }
        let frames = layerFrames
        if model.selectedLayer == index, let position = frames.firstIndex(where: { $0.index == index }) {
            let rest = frames.filter { $0.index != index }
            model.selectedLayer = rest[min(position, rest.count - 1)].index
        }
        model.toggle(index)
    }
    /// ↑ and ↓ select the layer above or below, ⌫ leaves the selected one out, unless a text field is being typed in.
    private func layerKey(_ event: NSEvent) -> Bool {
        guard model.analysis != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(event.window?.firstResponder is NSText) else { return false }
        let frames = layerFrames
        switch event.keyCode {
        case 125, 126:
            guard !frames.isEmpty else { return false }
            let position = model.selectedLayer.flatMap { layer in frames.firstIndex { $0.index == layer } }
            let next = switch (position, event.keyCode == 125) {
            case (nil, true): 0
            case (nil, false): frames.count - 1
            case (let p?, true): min(frames.count - 1, p + 1)
            case (let p?, false): max(0, p - 1)
            }
            model.selectedLayer = frames[next].index
            return true
        case 51, 117:
            guard let layer = model.selectedLayer else { return false }
            leaveOut(layer)
            return true
        default: return false
        }
    }

    /// Warm for the darkest exposure to cool for the brightest, as Focus Stack colors its layers.
    private func layerColor(_ index: Int) -> Color? {
        guard let frames = model.analysis?.frames, let position = frames.firstIndex(where: { $0.index == index }) else { return nil }
        return FocusStackPreview.layerColor(position: position, count: frames.count)
    }

    // MARK: Filmstrip

    /// The brackets darkest first: click one to take moving things from it; the checkbox leaves it out.
    private var filmstrip: some View {
        ToolFilmstrip { ForEach(model.analysis?.frames ?? []) { frame in bracket(frame) } }
    }

    private func bracket(_ frame: HDRMergeFrameInfo) -> some View {
        let isReference = model.reference == frame.index
        let included = !model.settings.excluded.contains(frame.index)
        return VStack(alignment: .leading, spacing: 4) {
            ToolFrameThumbnail(image: frame.thumbnail, outline: isReference ? Theme.accent : nil, badge: isReference ? L10n.tr("Base") : nil, dimmed: !included)
            .onTapGesture { model.makeReference(frame.index) }
            .help(L10n.tr("Take moving things and the exposure from this photo"))
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { included }, set: { _ in model.toggle(frame.index) })) { EmptyView() }
                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small)
                    .disabled(isReference || (included && model.settings.excluded.count >= (model.analysis?.frames.count ?? 0) - 2))
                    .help(L10n.tr("Include this exposure in the merge"))
                RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(layerColor(frame.index) ?? .gray).frame(width: 9, height: 9).opacity(included ? 1 : 0.35)
                Text(stops(frame)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Text(frame.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: 132, alignment: .leading)
        }
        .help(alignmentHelp(frame))
    }

    /// Stops relative to the reference, as measured from the pixels.
    private func stops(_ frame: HDRMergeFrameInfo) -> String {
        guard let analysis = model.analysis, let reference = model.reference,
              let base = analysis.frames.first(where: { $0.index == reference }) else { return "" }
        let value = frame.stops - base.stops
        return abs(value) < 0.05 ? L10n.tr("0 EV") : L10n.tr("\(String(format: "%+.1f", locale: Locale.current, value)) EV")
    }

    private func alignmentHelp(_ frame: HDRMergeFrameInfo) -> String {
        guard let shift = frame.shift else { return L10n.tr("\(frame.filename): couldn’t be aligned, used as framed") }
        let distance = String(format: "%.1f", locale: Locale.current, (shift.x * shift.x + shift.y * shift.y).squareRoot())
        let degrees = String(format: "%.2f", locale: Locale.current, frame.rotationDegrees ?? 0)
        return L10n.tr("\(frame.filename): moved \(distance) px, turned \(degrees)°")
    }
}
