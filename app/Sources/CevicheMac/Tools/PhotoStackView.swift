import SwiftUI
import AppKit
import CevicheCore

/// Analyzes the photos once, then redraws the preview from that analysis as the options change.
@MainActor
final class PhotoStackModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: PhotoStackRequest
    /// The stack is the Base photo's frame, so its preview takes that photo's development and what is placed on it.
    private lazy var developer = MergePreviewDeveloper(assets: request.assets, placed: EditTransferItem.framedRetouched)
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var analysis: PhotoStackAnalysis?
    @Published private(set) var preview: PhotoStackPreview?
    @Published private(set) var rendering = false
    @Published private(set) var previewError: String?
    @Published var settings = PhotoStackSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.strokes != oldValue.strokes, !history.applying { history.record(oldValue.strokes) }
            if settings.mode != oldValue.mode { modeChanged() }
            remember(); render()
        }
    }
    let history = BrushHistory<PhotoStackStroke>()
    /// The frame brush: showing the chosen photo, or giving an area back to the stack.
    @Published var brush: FocusStackBrushMode? { didSet { if brush == nil { showingPhoto = false } } }
    /// The photo the brush shows, by index: picked in the strip while the brush is up.
    @Published var brushPhoto: Int? { didSet { if brushPhoto != oldValue { photoPicture = nil; if showingPhoto { loadPhoto() } } } }
    /// The brush's width on screen in points.
    @Published var brushDiameter: Double { didSet { preferences.set(brushDiameter, forKey: "stackBrushDiameter") } }
    /// Shows the brush's photo alone instead of the stack, to see what it holds.
    @Published var showingPhoto = false { didSet { if showingPhoto { loadPhoto() } } }
    @Published private(set) var photoPicture: CGImage?
    private(set) var stacker: PhotoStacker?
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let preferences = UserDefaults.standard

    init(request: PhotoStackRequest) {
        self.request = request
        let diameter = preferences.double(forKey: "stackBrushDiameter")
        brushDiameter = diameter > 0 ? NightSkyBrushSize.clamped(diameter) : 60
        settings.mode = request.mode ?? preferences.string(forKey: "stackMode").flatMap(PhotoStackMode.init(rawValue:)) ?? .median
        history.current = { [weak self] in self?.settings.strokes }
        history.apply = { [weak self] in self?.settings.strokes = $0 }
    }

    /// The brush's dabs on the preview, in fractions of its width and height and a radius in fractions of its width.
    func paint(_ dabs: [(x: Double, y: Double, radius: Double)]) {
        guard let preview, let brush, !dabs.isEmpty else { return }
        let aspect = Double(preview.image.height) / Double(preview.image.width)
        if settings.mode.blendsOverBase {
            // One photo's light, taken out or brought back; the base has none to take.
            guard let photo = brushPhoto, photo != analysis?.reference else { return }
            settings.strokes += dabs.map { PhotoStackStroke(x: $0.x, y: $0.y * aspect, radius: $0.radius, photo: photo, hides: brush == .remove) }
        } else {
            guard brush == .remove || brushPhoto != nil else { return }
            settings.strokes += dabs.map { PhotoStackStroke(x: $0.x, y: $0.y * aspect, radius: $0.radius, photo: brush == .remove ? nil : brushPhoto) }
        }
    }
    /// Removes what the brush painted in this kind of mode: Lighten and Darken's dabs are their own.
    func resetPainting() { let blend = settings.mode.blendsOverBase; settings.strokes.removeAll { ($0.hides != nil) == blend } }
    var hasPainting: Bool { let blend = settings.mode.blendsOverBase; return settings.strokes.contains { ($0.hides != nil) == blend } }
    /// Takes the brush up, on the base photo until another is picked (in Lighten and Darken on the first other
    /// photo), or puts it down.
    func use(_ mode: FocusStackBrushMode) {
        brush = brush == mode ? nil : mode
        guard brush != nil, let analysis else { return }
        if settings.mode.blendsOverBase {
            if brushPhoto == nil || brushPhoto == analysis.reference {
                brushPhoto = analysis.frames.map(\.index).first { $0 != analysis.reference && !settings.excluded.contains($0) }
            }
        } else if brush == .add, brushPhoto == nil { brushPhoto = analysis.reference }
    }
    func strength(_ index: Int) -> Double { settings.strengths[index] ?? 1 }
    func setStrength(_ value: Double, for index: Int) { settings.strengths[index] = value >= 0.995 ? nil : value }
    /// Whether the photographer chose the base; until then Lighten starts from the darkest photo and Darken from the
    /// brightest.
    private var basePicked = false
    private func modeChanged() { brush = nil; autoBase() }
    private func autoBase() {
        guard settings.mode.blendsOverBase, !basePicked, let stacker, let base = stacker.extreme(brightest: settings.mode == .darken), base != analysis?.reference else { return }
        makeReference(base, picked: false)
    }
    private func loadPhoto() {
        guard let stacker, let index = brushPhoto else { return }
        let previous = renderTask
        Task {
            await previous?.value
            let picture = await Task.detached(priority: .userInitiated) { stacker.picture(of: index) }.value
            if brushPhoto == index { photoPicture = picture }
        }
    }
    var canStack: Bool { stage == .ready && preview != nil && previewError == nil }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        developer.store = catalog.store
        catalog.photoStackHistory = history
        task = Task {
            do {
                var urls: [URL] = []
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                let stacker = try PhotoStacker(urls: urls)
                stacker.retouch = await catalog.retouching(of: request.assets, at: urls)
                let progress: @Sendable (Double, String) -> Void = { fraction, message in
                    Task { @MainActor in
                        guard case .preparing = self.stage else { return }
                        self.stage = .preparing(message.isEmpty ? L10n.tr("Aligning photos") : message, fraction)
                    }
                }
                let work = Task.detached(priority: .userInitiated) { try stacker.analyze(progress: progress) }
                let analysis = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self.stacker = stacker; self.analysis = analysis
                stage = .preparing(L10n.tr("Creating preview…"), nil)
                render(immediately: true)
                autoBase()
            } catch is CancellationError {
            } catch { abort(catalog: catalog, error) }
        }
    }

    /// Draws the preview for the current options. Renders run one at a time; a newer request replaces a waiting one.
    func render(immediately: Bool = false) {
        guard stacker != nil else { return }
        let previous = renderTask
        previous?.cancel()
        let settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            if !immediately { try? await Task.sleep(for: .milliseconds(25)) }
            guard !Task.isCancelled, let self, let stacker = self.stacker else { return }
            self.rendering = true
            let result = await Task.detached(priority: .userInitiated) { Result { try stacker.preview(settings) } }.value
            guard !Task.isCancelled else { return }
            var developed: CGImage?
            if case .success(let preview) = result {
                developed = await self.developer.image(preview.source, base: stacker.urls[preview.source.base], size: max(preview.image.width, preview.image.height))
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

    /// Makes photo `index` the reference (including it if it was left out). Queued behind any render, since both
    /// read the stacker's reduced copies.
    func makeReference(_ index: Int, picked: Bool = true) {
        if picked { basePicked = true }
        guard let stacker, let analysis, index != analysis.reference else { return }
        let previous = renderTask
        previous?.cancel()
        rendering = true
        renderTask = Task { [weak self] in
            await previous?.value
            let updated = await Task.detached(priority: .userInitiated) { stacker.setReference(index) }.value
            guard let self else { return }
            self.analysis = updated
            self.settings.excluded.remove(index)
            self.photoPicture = nil
            if self.showingPhoto { self.loadPhoto() }
            self.render(immediately: true)
        }
    }

    func toggle(_ index: Int) {
        if settings.excluded.contains(index) { settings.excluded.remove(index) }
        else if index != analysis?.reference, settings.excluded.count < (analysis?.frames.count ?? 0) - 2 {
            settings.excluded.insert(index)
            if brushPhoto == index { brushPhoto = analysis?.reference }
        }
    }

    /// Processed photos are kept as `format` asks; RAW photos give a DNG.
    func stack(catalog: CatalogModel, format: ProcessedFormat = .original) {
        guard canStack, let stacker, let analysis else { return }
        let access = self.access
        self.access = []
        catalog.startStack(stacker, analysis: analysis, settings: settings, editsFrom: developer.asset(for: stacker.urls[analysis.reference]), access: access, format: format)
        close(catalog: catalog)
    }

    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ error: Error) {
        close(catalog: catalog)
        catalog.failure = Failure(L10n.tr("Can’t Stack These Photos"), error)
    }
    func close(catalog: CatalogModel) {
        stop()
        catalog.photoStack = nil
        catalog.photoStackHistory = nil
    }
    func stop() {
        task?.cancel(); renderTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }

    private func remember() { preferences.set(settings.mode.rawValue, forKey: "stackMode") }
}

/// Stack fills the window like the HDR merge: the preview in the middle, the photos in a strip below it, the mode under
/// the title bar, Cancel and Stack in the title bar.
struct PhotoStackView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: PhotoStackModel
    init(catalog: CatalogModel, request: PhotoStackRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: PhotoStackModel(request: request))
    }
    var body: some View {
        ToolWorkspace(title: L10n.tr("Stack"), status: status, statusIsWarning: statusIsWarning,
                      primary: L10n.tr("Stack", context: "verb"), primaryDisabled: !model.canStack,
                      primaryOptions: CatalogModel.processed(model.request.assets) ? [(L10n.tr("Stack to TIFF"), { model.stack(catalog: catalog, format: .tiff) })] : [],
                      cancel: { model.close(catalog: catalog) }, action: { model.stack(catalog: catalog) },
                      toolbar: { toolbar }) {
            VStack(spacing: 0) {
                canvas
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
        let included = analysis.frames.count - model.settings.excluded.count
        if model.settings.mode == .sequence, let leftOut = model.preview?.leftOut, leftOut > 0 {
            return leftOut == 1 ? L10n.tr("\(included) of \(analysis.frames.count) photos, 1 overlapping region left out")
                : L10n.tr("\(included) of \(analysis.frames.count) photos, \(leftOut) overlapping regions left out")
        }
        return L10n.tr("\(included) of \(analysis.frames.count) photos")
    }
    private var statusIsWarning: Bool {
        if case .failed = model.stage { return true }
        return model.previewError != nil || model.analysis?.frames.contains { $0.shift == nil } == true
    }

    private var canvas: some View {
        let showsPhoto = model.showingPhoto && model.photoPicture != nil
        return ZStack {
            ZoomCanvas(image: showsPhoto ? model.photoPicture : model.preview?.image, dragPans: model.brush == nil) { _ in
                // Where the brush's photo shows instead of the stack, then the brush itself.
                if !showsPhoto, model.brush != nil, let photo = model.brushPhoto, let mask = model.preview?.painted[photo] {
                    Theme.accent.opacity(0.3).mask(Image(decorative: mask, scale: 1).resizable().interpolation(.high).luminanceToAlpha()).allowsHitTesting(false)
                }
                if model.brush != nil {
                    FocusStackBrush(mode: model.brush, diameter: model.brushDiameter, color: Theme.accent) { model.paint($0) }
                }
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Stack These Photos"), systemImage: "square.stack.3d.down.right", description: Text(message))
            case .ready: if model.rendering { ToolProgressCard(message: L10n.tr("Creating preview…")).transition(.opacity) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(L10n.tr("Mode")).foregroundStyle(.secondary)
            FormSegments(title: L10n.tr("Mode"), selection: $model.settings.mode, options: PhotoStackMode.allCases, label: { $0.title }).labelsHidden().fixedSize()
                .help(modeHelp)
            if model.settings.mode == .sequence {
                Text(L10n.tr("Overlaps")).foregroundStyle(.secondary)
                FormSegments(title: L10n.tr("Overlaps"), selection: $model.settings.overlap, options: PhotoStackOverlap.allCases, label: { $0.title }).labelsHidden().fixedSize()
                    .help(L10n.tr("Where two subjects overlap, the one that shows. The other is left out whole: brush it in from its photo."))
            }
            if model.settings.mode.keepsGround {
                Text(L10n.tr("Ground")).foregroundStyle(.secondary)
                FormSegments(title: L10n.tr("Ground"), selection: $model.settings.ground, options: PhotoStackGround.allCases, label: { $0.title }).labelsHidden().fixedSize()
                    .help(L10n.tr("What shows below the sky, which goes on blending: the stack, the median without the people who walked through, or the base photo. The brush changes where."))
            }
            if model.settings.mode == .lighten {
                Toggle(L10n.tr("Strokes Only"), isOn: $model.settings.strokesOnly)
                    .help(L10n.tr("A photo adds only light clearly brighter than the base: for light painting on black, where each pass also spills light on the room. Cuts faint light too."))
            }
            Rule(.vertical).frame(height: 16)
            paintControls
            Spacer(minLength: 0)
        }
        .disabled(model.analysis == nil)
    }

    /// Undo and Redo, the brush size, then the brush that shows one photo where the stack chose wrongly, the one that
    /// gives an area back to the stack, a look at the brush's photo alone, and the reset.
    @ViewBuilder private var paintControls: some View {
        HStack(spacing: 2) {
            NightSkyIconButton(icon: "arrow.uturn.backward", label: L10n.tr("Undo"), action: model.history.undo).disabled(model.history.undoStack.isEmpty)
                .help(L10n.tr("Undoes the last brush stroke or reset (⌘Z)"))
            NightSkyIconButton(icon: "arrow.uturn.forward", label: L10n.tr("Redo"), action: model.history.redo).disabled(model.history.redoStack.isEmpty)
                .help(L10n.tr("Redoes what Undo took back (⇧⌘Z)"))
        }
        NightSkyBrushSize(diameter: $model.brushDiameter)
        HStack(spacing: 2) {
            if model.settings.mode.blendsOverBase {
                NightSkyIconButton(icon: "paintbrush.pointed", badge: "plus", label: L10n.tr("Bring Light Back"), on: model.brush == .add) { model.use(.add) }
                    .help(L10n.tr("Bring Light Back: paint to use a photo’s light again where it was taken out"))
                NightSkyIconButton(icon: "paintbrush.pointed", badge: "minus", label: L10n.tr("Take Light Out"), on: model.brush == .remove) { model.use(.remove) }
                    .help(L10n.tr("Take Light Out: paint where one photo’s light shouldn’t show, such as spill or glare. Click a photo below to choose which."))
            } else {
                NightSkyIconButton(icon: "paintbrush.pointed", badge: "plus", label: L10n.tr("Show Photo Here"), on: model.brush == .add) { model.use(.add) }
                    .help(L10n.tr("Show Photo Here: paint where the stack chose wrongly to show one photo there instead. Click a photo below to choose which."))
                NightSkyIconButton(icon: "paintbrush.pointed", badge: "minus", label: L10n.tr("Back to Stack"), on: model.brush == .remove) { model.use(.remove) }
                    .help(L10n.tr("Back to Stack: paint to give an area back to the stack"))
            }
            NightSkyIconButton(icon: "eye", label: L10n.tr("Show Photo Alone"), on: model.showingPhoto) { model.showingPhoto.toggle() }
                .disabled(model.brush == nil || model.brushPhoto == nil)
                .help(L10n.tr("Shows the brush’s photo alone, to see what it holds"))
            NightSkyIconButton(icon: "arrow.counterclockwise", label: L10n.tr("Reset Brush")) { model.resetPainting() }
                .disabled(!model.hasPainting)
                .help(L10n.tr("Removes everything the brush painted"))
        }
        if model.brush == .add || model.brush != nil && model.settings.mode.blendsOverBase, let photo = model.brushPhoto, let frame = model.analysis?.frames.first(where: { $0.index == photo }) {
            Text(frame.filename).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
        }
    }

    private var modeHelp: String {
        switch model.settings.mode {
        case .median: L10n.tr("Removes people and traffic that move through the frame")
        case .mean: L10n.tr("Smooths water and clouds and lowers noise")
        case .clippedMean: L10n.tr("Averages out noise, leaving out what passes through only some photos")
        case .sequence: L10n.tr("Shows a moving subject once for every photo, each whole from its own photo")
        case .lighten: L10n.tr("Adds each photo’s light to the base without lifting the shadows’ noise: lighting passes, light painting")
        case .darken: L10n.tr("Takes each photo’s darker areas over the base")
        case .maximum: L10n.tr("Keeps the brightest value: light and star trails")
        case .minimum: L10n.tr("Keeps the darkest value")
        }
    }

    private var filmstrip: some View {
        ToolFilmstrip(height: model.settings.mode.blendsOverBase ? 172 : 148) { ForEach(model.analysis?.frames ?? []) { frame in photo(frame) } }
    }

    private func photo(_ frame: PhotoStackFrameInfo) -> some View {
        let isReference = model.analysis?.reference == frame.index
        let included = !model.settings.excluded.contains(frame.index)
        // While the brush is up, a click picks the photo it shows.
        let brushing = model.brush != nil, isBrushPhoto = brushing && model.brushPhoto == frame.index
        let blending = model.settings.mode.blendsOverBase
        return VStack(alignment: .leading, spacing: 4) {
            ToolFrameThumbnail(image: frame.thumbnail, outline: brushing ? (isBrushPhoto ? .white : nil) : isReference ? Theme.accent : nil,
                               badge: isReference ? L10n.tr("Base") : nil, dimmed: !included)
                .overlay(alignment: .bottomTrailing) {
                    if model.settings.strokes.contains(where: { $0.photo == frame.index && ($0.hides != nil) == model.settings.mode.blendsOverBase }) {
                        Image(systemName: "paintbrush.pointed.fill").font(.system(size: 9)).foregroundStyle(.white)
                            .padding(3).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark).padding(3)
                            .help(L10n.tr("Brushed in"))
                    }
                }
            .onTapGesture {
                if !brushing { model.makeReference(frame.index) }
                else if included, !(blending && isReference) { model.brushPhoto = frame.index; if !blending, model.brush != .add { model.brush = .add } }
            }
            .contextMenu {
                Button(L10n.tr("Use as Base")) { model.makeReference(frame.index) }.disabled(isReference)
                Divider()
                if included {
                    Button(L10n.tr("Leave Out of Stack")) { model.toggle(frame.index) }
                        .disabled(isReference || model.settings.excluded.count >= (model.analysis?.frames.count ?? 0) - 2)
                } else {
                    Button(L10n.tr("Include in Stack")) { model.toggle(frame.index) }
                }
            }
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { included }, set: { _ in model.toggle(frame.index) })) { EmptyView() }
                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small)
                    .disabled(isReference || (included && model.settings.excluded.count >= (model.analysis?.frames.count ?? 0) - 2))
                    .help(L10n.tr("Include this photo in the stack"))
                Text(frame.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: 132, alignment: .leading)
            if blending {
                // How much of this photo's light is used; the base is whole by definition.
                FormSlider(value: Binding(get: { model.strength(frame.index) }, set: { model.setStrength($0, for: frame.index) }), in: 0...1)
                    .frame(width: 132).disabled(isReference || !included).opacity(isReference ? 0 : 1)
                    .help(L10n.tr("How much of this photo’s light is used"))
            }
        }
        .help(brushing ? (blending ? L10n.tr("Click to brush this photo’s light. \(alignmentHelp(frame))") : L10n.tr("Click to brush this photo in. \(alignmentHelp(frame))")) : isReference ? alignmentHelp(frame) : L10n.tr("Click to use as the base. \(alignmentHelp(frame))"))
    }

    private func alignmentHelp(_ frame: PhotoStackFrameInfo) -> String {
        guard let shift = frame.shift else { return L10n.tr("\(frame.filename): couldn’t be aligned, used as framed") }
        let distance = String(format: "%.1f", locale: Locale.current, (shift.x * shift.x + shift.y * shift.y).squareRoot())
        let degrees = String(format: "%.2f", locale: Locale.current, frame.rotationDegrees ?? 0)
        let stops = String(format: "%+.2f", locale: Locale.current, frame.stops)
        return L10n.tr("\(frame.filename): moved \(distance) px, turned \(degrees)°, \(stops) EV evened out")
    }
}
