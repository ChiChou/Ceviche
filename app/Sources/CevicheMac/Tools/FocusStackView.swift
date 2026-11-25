import SwiftUI
import AppKit
import CevicheCore

/// What dragging over the preview repairs or paints.
enum FocusStackBrushMode: Hashable { case repair, add, remove }

/// A layer brush's history, a step per stroke or reset; Edit › Undo and Redo use it while Focus Stack or HDR Merge fills
/// the window.
@MainActor
final class BrushHistory<Stroke: Equatable>: ObservableObject {
    @Published private(set) var undoStack: [[Stroke]] = []
    @Published private(set) var redoStack: [[Stroke]] = []
    var current: () -> [Stroke]? = { nil }
    var apply: ([Stroke]) -> Void = { _ in }
    private(set) var applying = false
    func record(_ old: [Stroke]) { undoStack.append(old); redoStack = [] }
    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }
    private func step(from: inout [[Stroke]], to: inout [[Stroke]]) {
        guard let current = current(), let target = from.popLast() else { return }
        to.append(current)
        applying = true; apply(target); applying = false
    }
}

typealias FocusStackHistory = BrushHistory<FocusStackStroke>

/// Undo and Redo in the Edit menu for a layer brush.
struct BrushUndoCommands<Stroke: Equatable>: View {
    @ObservedObject var history: BrushHistory<Stroke>
    var body: some View {
        Button(L10n.tr("Undo"), action: history.undo).keyboardShortcut("z").disabled(history.undoStack.isEmpty)
        Button(L10n.tr("Redo"), action: history.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(history.redoStack.isEmpty)
    }
}

/// Analyzes the bracket once, then redraws the preview from that analysis as the options change.
@MainActor
final class FocusStackModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: FocusStackRequest
    /// The preview and the result take the base photo's edits.
    private lazy var developer = MergePreviewDeveloper(assets: request.assets)
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var analysis: FocusStackAnalysis?
    @Published private(set) var preview: FocusStackPreview?
    @Published private(set) var rendering = false
    @Published private(set) var inspecting = false
    @Published private(set) var inspectionUnavailable = false
    @Published var inspectionMode = FocusStackInspectionMode.image {
        didSet {
            guard inspectionMode != oldValue, inspectionMode.requiresInspection else { return }
            inspectionUnavailable = false
            refreshInspection()
        }
    }
    @Published private(set) var previewError: String?
    @Published var settings = FocusStackSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.strokes != oldValue.strokes, !history.applying { history.record(oldValue.strokes) }
            if let selectedLayer, settings.excluded.contains(selectedLayer) { self.selectedLayer = nil }
            remember(); render()
        }
    }
    let history = FocusStackHistory()
    /// The layer listed on the right that is highlighted over the preview and that the brush paints, by photo index.
    @Published var selectedLayer: Int? {
        didSet {
            guard selectedLayer != oldValue else { return }
            if selectedLayer == nil, brush != .repair { brush = nil }
            if selectedLayer != nil, brush == .repair { brush = nil }
            refreshMask()
        }
    }
    /// The selected layer's share of each preview pixel, white where the result comes from it alone.
    @Published private(set) var layerMask: (photo: Int, image: CGImage)?
    @Published var brush: FocusStackBrushMode? = .repair
    /// With it on, a brush stroke selects the connected area at the depth it touches instead of painting only where it
    /// went.
    @Published var smartSelection: Bool { didSet { preferences.set(smartSelection, forKey: "focusStackSmartSelection") } }
    /// The brush's width on screen in points.
    @Published var brushDiameter: Double { didSet { preferences.set(brushDiameter, forKey: "focusStackBrushDiameter") } }
    @Published var showSources: Bool { didSet { preferences.set(showSources, forKey: "focusStackShowSources") } }
    private(set) var stacker: FocusStacker?
    private weak var catalog: CatalogModel?
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let preferences = UserDefaults.standard

    init(request: FocusStackRequest) {
        self.request = request
        smartSelection = UserDefaults.standard.object(forKey: "focusStackSmartSelection") as? Bool ?? true
        let diameter = UserDefaults.standard.double(forKey: "focusStackBrushDiameter")
        brushDiameter = diameter > 0 ? NightSkyBrushSize.clamped(diameter) : 40
        showSources = preferences.bool(forKey: "focusStackShowSources")
        settings.blending = preferences.string(forKey: "focusStackBlending").flatMap(FocusStackBlending.init(rawValue:)) ?? .labels
        settings.correctBreathing = preferences.object(forKey: "focusStackBreathing") as? Bool ?? true
        settings.cropToCoverage = preferences.object(forKey: "focusStackCrop") as? Bool ?? true
        history.current = { [weak self] in self?.settings.strokes }
        history.apply = { [weak self] in self?.settings.strokes = $0 }
        // Set beneath the observer: the strokes it opens with are where Undo starts, not a step of it.
        if let latent = request.latent { _settings = Published(initialValue: latent.saved); latentAssetID = latent.assetID; savedLatent = latent.saved }
    }

    /// The latent image this window opened, or the one its merge left.
    private(set) var latentAssetID: String?
    private var savedLatent: FocusStackSettings?
    /// Keeps the settings and the brush strokes in the latent image: a new one only for a merge with Keep
    /// Latent Image ticked, which closing updates.
    func keepLatent(catalog: CatalogModel, output: Bool) {
        let state = settings
        guard output && LatentPreference.keeps(LatentImage.focusStack) || latentAssetID != nil, stage == .ready, state != savedLatent, let image = preview?.image, let store = catalog.store else { return }
        savedLatent = state
        let sources = request.assets, into = latentAssetID
        let stem = (sources[0].filename as NSString).deletingPathExtension
        Task {
            do {
                var references: [LatentImage.Source] = []
                for asset in sources { references.append(try await catalog.latentSource(asset)) }
                let latent = try LatentImage(catalogID: store.manifest.id, sources: references, focusStack: state, width: image.width, height: image.height)
                latentAssetID = try await catalog.storeLatent(latent, pictures: try LatentImage.pictures(image), name: "\(stem)-Focus",
                                                              sources: sources, into: latentAssetID ?? into, store: store)
            } catch is CancellationError {
            } catch { savedLatent = nil; catalog.failure = Failure(L10n.tr("Couldn’t Keep the Latent Image"), error) }
        }
    }
    var canMerge: Bool {
        stage == .ready && preview != nil && previewError == nil && !rendering && !inspecting
            && (!inspectionMode.requiresInspection || preview?.inspection != nil || inspectionUnavailable)
    }
    var reference: Int? { settings.reference ?? analysis?.suggestedReference }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        developer.store = catalog.store
        self.catalog = catalog
        catalog.focusStackHistory = history
        task = Task {
            do {
                var urls: [URL] = []
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                let stacker = try FocusStacker(urls: urls)
                stacker.retouch = await catalog.retouching(of: request.assets, at: urls)
                let progress: @Sendable (Double, String) -> Void = { fraction, message in
                    Task { @MainActor in
                        guard case .preparing = self.stage else { return }
                        self.stage = .preparing(message.isEmpty ? L10n.tr("Measuring sharpness") : message, fraction)
                    }
                }
                let work = Task.detached(priority: .userInitiated) { try stacker.analyze(progress: progress) }
                let analysis = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self.stacker = stacker; self.analysis = analysis
                stage = .preparing(L10n.tr("Creating preview…"), nil)
                render(immediately: true)
            } catch is CancellationError {
            } catch { abort(catalog: catalog, error) }
        }
    }

    /// Draws the preview for the current options. Renders run one at a time; a newer request replaces a waiting one.
    func render(immediately: Bool = false) {
        guard stacker != nil else { return }
        inspectionUnavailable = false
        let previous = renderTask
        previous?.cancel()
        let settings = self.settings, layer = selectedLayer
        renderTask = Task { [weak self] in
            await previous?.value
            if !immediately { try? await Task.sleep(for: .milliseconds(25)) }
            guard !Task.isCancelled, let self, let stacker = self.stacker else { return }
            self.rendering = true
            let (result, mask) = await Task.detached(priority: .userInitiated) {
                (Result { try stacker.preview(settings) }, layer.flatMap { photo in (try? stacker.layerMask(settings, photo: photo)).map { (photo, $0) } })
            }.value
            guard !Task.isCancelled else { return }
            var developed: CGImage?
            if case .success(let preview) = result {
                developed = await self.developer.image(preview.source, base: stacker.urls[preview.source.base], size: max(preview.image.width, preview.image.height))
                guard !Task.isCancelled else { return }
            }
            self.rendering = false
            switch result {
            case .success(var preview):
                preview.image = developed ?? preview.image
                self.preview = preview; self.previewError = nil; self.layerMask = mask
                self.refreshInspection()
            case .failure(let error): self.previewError = error.localizedDescription
            }
            if case .preparing = self.stage { self.stage = .ready }
        }
    }

    /// Queue map generation behind image/mask work; switching inspection modes shares the same field.
    /// No photograph fusion is repeated for a view change, and stale work cannot attach to a newer preview.
    private func refreshInspection() {
        guard inspectionMode.requiresInspection, preview != nil, preview?.inspection == nil, !inspectionUnavailable else { return }
        let previous = renderTask, settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, let stacker = self.stacker,
                  self.inspectionMode.requiresInspection, self.settings == settings,
                  self.preview?.settings == settings, self.preview?.inspection == nil else { return }
            self.inspecting = true
            defer { self.inspecting = false }
            let work = Task.detached(priority: .userInitiated) { Result { try stacker.inspection(settings) } }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, self.settings == settings, self.preview?.settings == settings else { return }
            switch result {
            case .success(let field): self.preview?.inspection = field; self.inspectionUnavailable = field == nil
            case .failure: self.inspectionUnavailable = true
            }
        }
    }

    /// Draws the selected layer's mask for the current preview, after any render in progress; the stacker runs one
    /// task at a time.
    private func refreshMask() {
        guard stacker != nil else { return }
        guard let layer = selectedLayer else { layerMask = nil; return }
        let previous = renderTask, settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, let stacker = self.stacker else { return }
            let mask = await Task.detached(priority: .userInitiated) { try? stacker.layerMask(settings, photo: layer) }.value
            guard !Task.isCancelled, self.selectedLayer == layer else { return }
            self.layerMask = mask.map { (layer, $0) }
        }
    }

    /// The brush's dabs on the preview, in fractions of its width and height and a radius in fractions of its width,
    /// added to the selected layer.
    func paint(_ dabs: [(x: Double, y: Double, radius: Double)]) {
        guard let preview, let brush, !dabs.isEmpty else { return }
        guard brush == .repair || selectedLayer != nil else { return }
        let selection = (brush == .repair || smartSelection) ? (settings.strokes.compactMap(\.selection).max() ?? 0) + 1 : nil
        settings.strokes += dabs.map { dab in
            let p = CGPoint(x: dab.x, y: dab.y).applying(preview.toBrushSpace)
            return FocusStackStroke(x: p.x, y: p.y, radius: dab.radius * preview.brushScale, photo: brush == .repair ? -1 : selectedLayer!, add: brush != .remove, selection: selection, repair: brush == .repair ? true : nil)
        }
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
        guard canMerge, let stacker, let analysis else { return }
        let access = self.access
        self.access = []
        let reference = settings.reference ?? analysis.suggestedReference
        catalog.startFocusStack(stacker, analysis: analysis, settings: settings, editsFrom: developer.asset(for: stacker.urls[reference]), access: access, format: format)
        keepLatent(catalog: catalog, output: true)
        close(catalog: catalog)
    }

    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ error: Error) {
        stop(); catalog.focusStack = nil; catalog.focusStackHistory = nil
        catalog.failure = Failure(L10n.tr("Can’t Stack These Photos"), error)
    }
    func close(catalog: CatalogModel) {
        keepLatent(catalog: catalog, output: false)
        stop()
        catalog.focusStack = nil
        catalog.focusStackHistory = nil
    }
    /// Ends the analysis and releases the originals; also when the catalog closes the view from outside.
    func stop() {
        task?.cancel(); renderTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }

    private func remember() {
        preferences.set(settings.blending.rawValue, forKey: "focusStackBlending")
        preferences.set(settings.correctBreathing, forKey: "focusStackBreathing")
        preferences.set(settings.cropToCoverage, forKey: "focusStackCrop")
    }
}

/// Focus Stack fills the window like the HDR merge: the preview in the middle, the layers on the right, the bracket in a
/// strip below in capture order, the options and the layer brush under the title bar, Cancel and Merge in the title bar.
struct FocusStackView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: FocusStackModel
    /// Raised by the inspection controls' Fit button.
    @State private var fit = 0
    @State private var keyMonitor: Any?
    @State private var host = HostWindow()
    @State private var hoveredLayer: Int?
    private var inspectionMode: FocusStackInspectionMode { model.inspectionMode }
    @State private var relief: Float = 0.22
    @State private var inspectionOpacity: Float = 0.65
    @State private var invertRelief = false
    @State private var resetRelief = 0

    init(catalog: CatalogModel, request: FocusStackRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: FocusStackModel(request: request))
    }
    var body: some View {
        ToolWorkspace(title: L10n.tr("Focus Stack"), status: status, statusIsWarning: statusIsWarning,
                      primary: L10n.tr("Merge"), primaryDisabled: !model.canMerge,
                      primaryOptions: CatalogModel.processed(model.request.assets) ? [(L10n.tr("Merge to TIFF"), { model.merge(catalog: catalog, format: .tiff) })] : [],
                      cancel: { model.close(catalog: catalog) }, action: { model.merge(catalog: catalog) },
                      toolbar: { toolbar }) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        previewTabs
                        Rule()
                        canvas
                    }
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
        if !unaligned.isEmpty { return L10n.tr("Couldn’t align \(unaligned.joined(separator: ", ")); stacked as framed") }
        let used = analysis.frames.count - model.settings.excluded.count
        guard let preview = model.preview else { return L10n.tr("\(used) of \(analysis.frames.count) photos") }
        let size = "\(preview.outputWidth.formatted()) × \(preview.outputHeight.formatted())"
        return L10n.tr("\(used) of \(analysis.frames.count) photos - \(size)")
    }
    private var statusIsWarning: Bool {
        if case .failed = model.stage { return true }
        return model.previewError != nil || model.analysis?.frames.contains { $0.shift == nil } == true
    }

    // MARK: Canvas

    /// The preview on the shared canvas. The source tint, the selected layer's highlight and the brush lie over the
    /// picture at its shown size, so they move and zoom with it; the depth and confidence views take its place there.
    /// The relief is a view of its own, turned and zoomed by itself.
    private var canvas: some View {
        let plain = inspectionMode == .image || inspectionMode == .sources
        let waiting = inspectionMode.requiresInspection && model.preview?.inspection == nil
        return ZStack {
            if let preview = model.preview, inspectionMode == .relief, !waiting {
                Theme.imageSurround
                FocusStackInspectionCanvas(preview: preview, mode: .relief, relief: relief, inverted: invertRelief, reset: resetRelief)
            } else if waiting {
                Theme.imageSurround
                if model.inspectionUnavailable { Text(L10n.tr("GPU preview unavailable")).foregroundStyle(.secondary) }
            } else {
                ZoomCanvas(image: model.preview?.image, dragPans: !(plain && (model.brush == .repair || model.selectedLayer != nil) && model.brush != nil),
                           showsControls: plain, fit: fit) { _ in
                    if let preview = model.preview {
                        if plain {
                            if model.showSources { Image(decorative: preview.sources, scale: 1).resizable().interpolation(.none).opacity(0.5) }
                            highlight
                            FocusStackBrush(mode: model.brush == .repair || model.selectedLayer != nil ? model.brush : nil, diameter: model.brushDiameter,
                                            color: model.selectedLayer.flatMap(layerColor) ?? Theme.accent) { model.paint($0) }
                        } else {
                            FocusStackInspectionCanvas(preview: preview, mode: inspectionMode, opacity: inspectionOpacity)
                        }
                    }
                }
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Stack These Photos"), systemImage: "camera.macro", description: Text(message))
            case .ready:
                if model.rendering || (waiting && !model.inspectionUnavailable) { ToolProgressCard(message: L10n.tr("Creating preview…")).transition(.opacity) }
            }
        }
        .overlay(alignment: .bottomTrailing) { if model.preview != nil, !plain { inspectionControls } }
        .background(HostWindowReader(host: host))
        .onAppear { watchBrushKeys() }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    /// The selected layer in its color, and everything else dimmed.
    @ViewBuilder private var highlight: some View {
        if let layer = model.selectedLayer, let mask = model.layerMask, mask.photo == layer {
            ZStack {
                Color.black.opacity(0.55)
                    .mask(Image(decorative: mask.image, scale: 1).resizable().interpolation(.high).colorInvert().luminanceToAlpha())
                (layerColor(layer) ?? Theme.accent).opacity(0.3)
                    .mask(Image(decorative: mask.image, scale: 1).resizable().interpolation(.high).luminanceToAlpha())
            }.allowsHitTesting(false)
        }
    }

    private var inspectionControls: some View {
        HStack(spacing: 10) {
            if inspectionMode == .relief {
                Text(L10n.tr("Relief"))
                FormSlider(value: Binding(get: { Double(relief) }, set: { relief = Float($0) }), in: 0...0.6).frame(width: 100).accessibilityLabel(L10n.tr("Relief"))
                Toggle(L10n.tr("Invert"), isOn: $invertRelief).toggleStyle(.formCheckbox)
                Button { resetRelief += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                    .help(L10n.tr("Reset View")).accessibilityLabel(L10n.tr("Reset View"))
            } else {
                LinearGradient(colors: inspectionMode == .depth ? [.blue, .yellow] : [.red, .green], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 50, height: 8).clipShape(Capsule())
                Text(inspectionMode == .depth ? L10n.tr("First → Last") : L10n.tr("Low → High"))
                FormSlider(value: Binding(get: { Double(inspectionOpacity) }, set: { inspectionOpacity = Float($0) }), in: 0...1).frame(width: 90).accessibilityLabel(L10n.tr("Opacity"))
                Button { fit += 1 } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help(L10n.tr("Fit")).accessibilityLabel(L10n.tr("Fit"))
            }
        }
        .buttonStyle(.borderless).font(.callout).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule()).environment(\.colorScheme, .dark).padding(12)
        .help(inspectionMode == .relief ? L10n.tr("Drag to orbit; scroll to zoom. Gaps mark missing focus evidence or depth jumps.") :
              (inspectionMode == .depth ? L10n.tr("Focus position in capture order, not physical distance. Hatching marks missing focus evidence.") :
               L10n.tr("Focus evidence from sharpness and agreement. Hatching marks missing focus evidence.")))
    }

    /// [ and ] make the brush smaller and larger, and the arrows and ⌫ work the layers, unless a text field is being typed in.
    private func watchBrushKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard host.owns(event) else { return event }
            guard inspectionMode == .image || inspectionMode == .sources else { return event }
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
            Text(L10n.tr("Blend")).foregroundStyle(.secondary)
            FormSegments(title: L10n.tr("Blend"), selection: $model.settings.blending, options: FocusStackBlending.allCases, label: { $0.title }).labelsHidden().fixedSize()
                .help(L10n.tr("Edge-Aware takes each area from the photo that is sharpest there, with joins that follow the picture’s edges. Multiscale blends every detail size separately, for comparison; it can leave halos beside depth edges."))
            Toggle(L10n.tr("Correct Focus Breathing"), isOn: $model.settings.correctBreathing)
                .help(L10n.tr("Matches the small change in magnification that focusing causes, so details line up from photo to photo"))
            Toggle(L10n.tr("Crop to Common Area"), isOn: $model.settings.cropToCoverage)
                .help(L10n.tr("Crops to the area every included photo covers"))
            if model.request.latent == nil { LatentCheckbox(type: LatentImage.focusStack) }
            Rule(.vertical).frame(height: 16)
            paintControls.disabled(inspectionMode != .image && inspectionMode != .sources)
            Spacer(minLength: 0)
        }
        .disabled(model.analysis == nil)
    }

    /// View choices belong to the preview, independently of the processing options and the layer list.
    private var previewTabs: some View {
        FormSegments(title: L10n.tr("View"), selection: $model.inspectionMode,
                         options: FocusStackInspectionMode.allCases, label: { mode in
                switch mode {
                case .image: L10n.tr("Image")
                case .sources: L10n.tr("Sources")
                case .depth: L10n.tr("Depth")
                case .confidence: L10n.tr("Confidence")
                case .relief: L10n.tr("3D")
                }
            }).labelsHidden().fixedSize()
            .frame(maxWidth: .infinity).frame(height: 36).background(Theme.statusBar)
            .disabled(model.analysis == nil)
            .onAppear { if model.showSources { model.inspectionMode = .sources } }
            .onChange(of: inspectionMode) { _, mode in model.showSources = mode == .sources }
    }

    /// Undo and Redo, the brush size, then the brushes that add to and take from the selected layer and its reset, as in
    /// the night-sky tools. A brush icon clicked again puts the brush down.
    @ViewBuilder private var paintControls: some View {
        let layer = model.selectedLayer
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "arrow.uturn.backward", label: L10n.tr("Undo"), action: model.history.undo).disabled(model.history.undoStack.isEmpty)
                .help(L10n.tr("Undoes the last brush stroke or reset (⌘Z)"))
            NightSkyIconButton(icon: "arrow.uturn.forward", label: L10n.tr("Redo"), action: model.history.redo).disabled(model.history.redoStack.isEmpty)
                .help(L10n.tr("Redoes what Undo took back (⇧⌘Z)"))
        }
        NightSkyBrushSize(diameter: $model.brushDiameter)
        NightSkyIconButton(icon: "bandage", label: L10n.tr("Repair Edge"), on: model.brush == .repair) { use(.repair) }
            .help(L10n.tr("Paint over a halo to repair it from an aligned source. No layer selection needed."))
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "paintbrush.pointed", badge: "plus", label: L10n.tr("Add to Layer"), on: model.brush == .add && layer != nil) { use(.add) }
                .help(L10n.tr("Add to Layer: paint over the preview to take those areas from the selected layer’s photo alone"))
            NightSkyIconButton(icon: "paintbrush.pointed", badge: "minus", label: L10n.tr("Remove from Layer"), on: model.brush == .remove && layer != nil) { use(.remove) }
                .help(L10n.tr("Remove from Layer: paint over the preview to take the selected layer’s photo out of those areas; the other photos fill them"))
            NightSkyIconButton(icon: "wand.and.rays", label: L10n.tr("Smart Selection"), on: model.smartSelection) { model.smartSelection.toggle() }
                .help(L10n.tr("Smart Selection: a stroke selects the whole connected area at the depth it touches, with edges that follow the picture. Off, the brushes paint only where they go."))
            NightSkyIconButton(icon: "arrow.counterclockwise", label: L10n.tr("Reset Layer")) { model.resetPainting(layer) }
                .disabled(layer.map { l in !model.settings.strokes.contains { $0.photo == l } } ?? true)
                .help(L10n.tr("Removes what the brushes painted on the selected layer, so it is as the stack chose it"))
        }.disabled(layer == nil)
    }
    private func use(_ mode: FocusStackBrushMode) {
        let next: FocusStackBrushMode? = model.brush == mode ? nil : mode
        model.brush = next
        if next == .repair { model.selectedLayer = nil; model.inspectionMode = .image }
    }

    // MARK: Layers

    /// Each included photo is a layer: the areas the result takes from it. Click one to highlight it and paint it.
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

    /// Included photos in capture order, as in the strip, so rows stay put while painting changes their shares.
    private var layerFrames: [FocusStackFrameInfo] {
        (model.analysis?.frames ?? []).filter { !model.settings.excluded.contains($0.index) }
    }

    private func layerRow(_ frame: FocusStackFrameInfo) -> some View {
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
                    Text(L10n.tr("\(Int((share * 100).rounded()))%")).monospacedDigit()
                    if frame.index == model.reference { Text(L10n.tr("- Base")) }
                    if painted { Image(systemName: "paintbrush.pointed.fill").help(L10n.tr("Painted with the layer brushes")) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selected || hoveredLayer == frame.index {
                Button { leaveOut(frame.index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(!canLeaveOut(frame.index))
                    .help(L10n.tr("Leave this photo out of the stack (⌫)"))
            }
        }
        .padding(5)
        .onHover { hoveredLayer = $0 ? frame.index : (hoveredLayer == frame.index ? nil : hoveredLayer) }
        .contextMenu {
            Button(L10n.tr("Leave Out of Stack")) { leaveOut(frame.index) }.disabled(!canLeaveOut(frame.index))
        }
        .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .opacity(share > 0 || painted || selected ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLayer = selected ? nil : frame.index }
        .help(L10n.tr("Highlight the areas the result takes from \(frame.filename)"))
    }

    /// The reference stays, and so do the last two photos.
    private func canLeaveOut(_ index: Int) -> Bool {
        index != model.reference && layerFrames.count > 2
    }
    /// Leaves a photo out of the stack; when it was selected, the next layer is selected instead.
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

    private func layerColor(_ index: Int) -> Color? {
        guard let frames = model.analysis?.frames, let position = frames.firstIndex(where: { $0.index == index }) else { return nil }
        return FocusStackPreview.layerColor(position: position, count: frames.count)
    }

    // MARK: Filmstrip

    /// The bracket in capture order: click a photo to keep its framing; the checkbox leaves it out.
    private var filmstrip: some View {
        ToolFilmstrip { ForEach(model.analysis?.frames ?? []) { frame in photo(frame) } }
    }

    private func photo(_ frame: FocusStackFrameInfo) -> some View {
        let isReference = model.reference == frame.index
        let included = !model.settings.excluded.contains(frame.index)
        return VStack(alignment: .leading, spacing: 4) {
            ToolFrameThumbnail(image: frame.thumbnail, outline: isReference ? Theme.accent : nil, badge: isReference ? L10n.tr("Base") : nil, dimmed: !included)
            .onTapGesture { model.makeReference(frame.index) }
            .help(L10n.tr("Keep the framing and exposure of this photo"))
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { included }, set: { _ in model.toggle(frame.index) })) { EmptyView() }
                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small)
                    .disabled(isReference || (included && model.settings.excluded.count >= (model.analysis?.frames.count ?? 0) - 2))
                    .help(L10n.tr("Include this photo in the stack"))
                RoundedRectangle(cornerRadius: Theme.Radius.tag).fill(layerColor(frame.index) ?? .gray).frame(width: 9, height: 9).opacity(included ? 1 : 0.35)
                Text(contribution(frame)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Text(frame.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: 132, alignment: .leading)
        }
        .help(alignmentHelp(frame))
    }

    /// The share of the result this photo supplies.
    private func contribution(_ frame: FocusStackFrameInfo) -> String {
        guard !model.settings.excluded.contains(frame.index), let preview = model.preview else { return "–" }
        return L10n.tr("\(Int(((preview.contributions[frame.index] ?? 0) * 100).rounded()))%")
    }

    private func alignmentHelp(_ frame: FocusStackFrameInfo) -> String {
        guard let shift = frame.shift, let scale = frame.scale else { return L10n.tr("\(frame.filename): couldn’t be aligned, used as framed") }
        let magnification = String(format: "%+.2f", locale: Locale.current, (scale - 1) * 100)
        let distance = String(format: "%.1f", locale: Locale.current, (shift.x * shift.x + shift.y * shift.y).squareRoot())
        let degrees = String(format: "%.2f", locale: Locale.current, frame.rotationDegrees ?? 0)
        return L10n.tr("\(frame.filename): magnified \(magnification)%, moved \(distance) px, turned \(degrees)°")
    }
}

/// Painting the selected layer over the preview: each drag lays dabs half a radius apart, committed when the drag ends so
/// the preview redraws once per stroke. The stroke being drawn shows in the layer's color; the redrawn highlight then
/// shows what changed.
struct FocusStackBrush: View {
    let mode: FocusStackBrushMode?
    /// The brush's width on screen in points, whatever the zoom, so a zoomed preview paints finer.
    let diameter: CGFloat
    let color: Color
    /// The dabs of one stroke, in fractions of the preview's width and height, with radii in fractions of its width.
    let commit: ([(x: Double, y: Double, radius: Double)]) -> Void
    @State private var pending: [(x: Double, y: Double, radius: Double)] = []
    /// Where the stroke being drawn began; a drag starting elsewhere is a new stroke, so dabs a cancelled drag left
    /// behind are dropped rather than committed with it.
    @State private var strokeStart: CGPoint?
    @State private var pointer: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                guard let mode else { return }
                var path = Path()
                for dab in pending {
                    let r = dab.radius * size.width
                    path.addEllipse(in: CGRect(x: dab.x * size.width - r, y: dab.y * size.height - r, width: 2 * r, height: 2 * r))
                }
                context.fill(path, with: .color(mode != .remove ? color.opacity(0.35) : .black.opacity(0.5)))
                if let pointer {
                    let ring = Path(ellipseIn: CGRect(x: pointer.x - diameter / 2, y: pointer.y - diameter / 2, width: diameter, height: diameter))
                    context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 3)
                    context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in if case .active(let location) = phase { pointer = location } else { pointer = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    pointer = value.location
                    if strokeStart != value.startLocation { strokeStart = value.startLocation; pending = [] }
                    let radius = Double(diameter / 2 / max(1, size.width))
                    let point = (x: Double(max(0, min(1, value.location.x / size.width))), y: Double(max(0, min(1, value.location.y / size.height))), radius: radius)
                    guard let last = pending.last else { pending.append(point); return }
                    let step = radius * size.width / 2, distance = hypot((point.x - last.x) * size.width, (point.y - last.y) * size.height)
                    guard distance >= step else { return }
                    let count = Int((distance / step).rounded(.up))
                    for i in 1...count {
                        let t = Double(i) / Double(count)
                        pending.append((x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t, radius: radius))
                    }
                }
                .onEnded { _ in commit(pending); pending = []; strokeStart = nil })
            .allowsHitTesting(mode != nil)
            // Putting the brush down or switching it cancels a drag without ending it; its dabs aren't a stroke.
            .onChange(of: mode) { pending = []; strokeStart = nil }
        }
    }
}
