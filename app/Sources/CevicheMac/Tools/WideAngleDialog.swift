import SwiftUI
import CevicheCore

/// What the Wide-Angle Faces dialog shows: the photo corrected, beside or split against the photo as shot, with a tag
/// over each person to leave them as shot, and a click on someone missed adding them. The settings are remembered.
@MainActor
final class WideAngleModel: ObservableObject {
    enum Stage: Equatable { case loading, ready, refused(String), failed(String) }

    let request: WideAngleRequest
    @Published private(set) var stage = Stage.loading
    @Published private(set) var before: CGImage?
    @Published private(set) var after: CGImage?
    @Published private(set) var mesh: WideAngleMesh?
    @Published private(set) var rendering = false
    @Published var settings: WideAngleSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.preferenceKey) }
            render()
        }
    }
    /// The people as the dialog has them, once found.
    @Published private(set) var people: [WideAnglePerson]?
    /// A focal length typed in the dialog (35 mm equivalent); it replaces the EXIF's.
    @Published private(set) var typedFocal: Double?
    /// The EXIF's 35 mm equivalent as read from the file: nil inside when the file has none.
    private var readFocal: Double??
    private weak var catalog: CatalogModel?
    private var previewer: WideAnglePreviewer?
    private var access: URL?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private static let preferenceKey = "wideAngleSettings"

    init(request: WideAngleRequest) {
        self.request = request
        settings = UserDefaults.standard.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode(WideAngleSettings.self, from: $0) } ?? WideAngleSettings()
    }

    var asset: CatalogAsset { request.asset }
    /// The EXIF's 35 mm equivalent focal length: the file's once read, else the catalog's.
    var exifFocal: Double? {
        if let readFocal { return readFocal }
        return asset.focalLength35mm.flatMap { $0 > 0 ? $0 : nil }
    }
    var focal: Double? { typedFocal ?? exifFocal }
    /// Known to have no 35 mm equivalent: the file was read, or the catalog has no focal length at all.
    private var lacksFocal: Bool { exifFocal == nil && (readFocal != nil || asset.focalLength == nil) }
    /// Why the photo can't be corrected: no focal length, or one too long. A photo with an actual focal length but no
    /// equivalent in the catalog is tried, as the file's sensor size may give one.
    var refusal: String? {
        if let focal { return WideAngleFaces.refusal(focal: focal) }
        return lacksFocal ? L10n.tr("No focal length in its EXIF") : nil
    }
    /// Sets the focal length, nil or the EXIF's to use the EXIF's.
    func setFocal(_ value: Double?) {
        let value = value.flatMap { $0 > 0 ? $0 : nil }
        typedFocal = value == exifFocal ? nil : value
        if previewer != nil { updateStage(); render() }
    }
    /// Whether Correct can run: a focal length it may correct, and somebody to correct once the people are found.
    var canCorrect: Bool { refusal == nil && people.map { $0.contains(where: \.enabled) } != false }
    var shownPeople: [WideAnglePerson] { people ?? [] }

    func start(catalog: CatalogModel) {
        guard self.catalog == nil else { return }
        self.catalog = catalog
        load()
    }
    func stop() {
        loadTask?.cancel(); renderTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
        previewer = nil
    }

    private func load() {
        guard let catalog else { return }
        let asset = self.asset
        stage = .loading
        loadTask = Task {
            do {
                let url = try await catalog.resolveOriginal(asset)
                if url.startAccessingSecurityScopedResource() { access = url }
                let exposure = await catalog.denoiseExposure(asset)
                let retouch = await catalog.retouching(of: [asset], at: [url])[url] ?? []
                let previewer = try await Task.detached(priority: .userInitiated) { try autoreleasepool { try WideAnglePreviewer(url, exposure: exposure, retouch: retouch) } }.value
                guard !Task.isCancelled else { return }
                self.previewer = previewer
                readFocal = .some(previewer.focalLength)
                people = previewer.analysis.people
                before = previewer.before
                updateStage()
                render()
            } catch {
                guard !Task.isCancelled else { return }
                close(with: Failure(L10n.tr("Couldn’t Correct Faces"), error))
            }
        }
    }

    private func close(with failure: Failure) {
        guard let catalog else { return }
        stop()
        catalog.wideAngle = nil; catalog.failure = failure
    }

    /// Ready, or why not: the focal length first, as the people can be fixed on the photo.
    private func updateStage() {
        if let refusal { stage = .refused(refusal) }
        else { stage = shownPeople.isEmpty ? .refused(L10n.tr("No people found. Click a head to add someone.")) : .ready }
    }

    /// The correction redrawn for the current people and settings; a newer change stops an older one.
    private func render() {
        guard let previewer else { return }
        renderTask?.cancel()
        guard refusal == nil, let focal else { mesh = nil; after = nil; rendering = false; return }
        let people = shownPeople, settings = self.settings
        rendering = true
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (WideAngleMesh, CGImage)? in
                let mesh = WideAngleFaces.solve(previewer.analysis, people: people, focal: focal, settings: settings)
                guard let image = try? previewer.corrected(mesh) else { return nil }
                return (mesh, image)
            }.value
            guard !Task.isCancelled else { return }
            if let result { mesh = result.0; after = result.1 }
            rendering = false
        }
    }

    // MARK: People

    /// Corrects or leaves as shot one person; one added by hand is taken away instead.
    func toggle(_ person: WideAnglePerson) {
        guard var list = people, let i = list.firstIndex(where: { $0.id == person.id }) else { return }
        if list[i].added { list.remove(at: i) } else { list[i].enabled.toggle() }
        people = list
        updateStage()
        render()
    }
    /// Adds someone the search missed, with their head at `point` (fractions of the photo as shot).
    func add(at point: CGPoint) {
        guard let previewer else { return }
        var list = people ?? []
        let id = (list.map(\.id).max() ?? -1) + 1
        list.append(.placed(id: id, at: point, like: previewer.analysis.typicalHead, aspect: previewer.analysis.aspect))
        people = list
        updateStage()
        render()
    }
    var photoAspect: CGFloat { before.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1.5 }
}

struct WideAngleDialog: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: WideAngleModel
    init(catalog: CatalogModel, request: WideAngleRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: WideAngleModel(request: request))
    }

    var body: some View {
        ToolWorkspace(title: L10n.tr("Wide-Angle Faces"), status: model.asset.filename, primary: L10n.tr("Correct Faces"),
                      primaryDisabled: !model.canCorrect || !catalog.canStartJob, cancel: close,
                      action: { catalog.startWideAngle(model.asset, settings: model.settings, people: model.people, focal: model.typedFocal); close() }) {
            FormSegments(title: L10n.tr("Compare"), selection: $compare, options: Compare.allCases, label: { $0.title }).labelsHidden().fixedSize()
            Toggle(L10n.tr("Show Grid"), isOn: $showGrid)
            // \ shows the photo as shot, as in other RAW editors.
            Button(L10n.tr("Before")) { showBefore.toggle() }.keyboardShortcut("\\", modifiers: []).frame(width: 0, height: 0).opacity(0)
        } content: {
            HStack(spacing: 0) {
                // The photo runs to the edges on one surround; the name is in the title, so no bar repeats it.
                preview.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.imageSurround)
                ToolSidePanel { options }
            }
        }
        .onAppear { model.start(catalog: catalog); watchScrolling() }
        .onDisappear { model.stop(); if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil }
    }

    private func close() { model.stop(); catalog.wideAngle = nil }

    // MARK: Preview

    enum Compare: String, CaseIterable, Identifiable {
        case sideBySide, split
        var id: String { rawValue }
        var title: String { self == .split ? L10n.tr("Split") : L10n.tr("Side by Side") }
    }
    @AppStorage("wideAngleCompare") private var compare = Compare.sideBySide
    @AppStorage("wideAngleGrid") private var showGrid = true
    /// The zoom and pan, shared by both photos, as in the main window's Compare.
    @State private var viewport = ImageViewport()
    @State private var pinchStart: ImageViewport?
    /// The pane under the pointer, which trackpad and wheel scrolling pan.
    @State private var scrollPane: CGSize?
    @State private var scrollMonitor: Any?
    @State private var split: CGFloat = 0.5
    @State private var showBefore = false
    @State private var hovered: Int?

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                switch model.stage {
                case .loading:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Finding people in \(model.asset.filename)…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary).padding()
                case .refused(let message):
                    if model.before != nil { photos(in: geometry.size) }
                    Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .frame(maxHeight: .infinity, alignment: model.before == nil ? .center : .top).padding(10)
                case .ready:
                    photos(in: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    /// The photo fitted into `size`, as Split or Side by Side. Side by Side gives each photo half the area, as the main
    /// window's Compare does, so a zoomed photo fills its half rather than its fitted frame.
    @ViewBuilder private func photos(in size: CGSize) -> some View {
        if compare == .split || showBefore {
            let fit = fitted(model.photoAspect, in: size)
            splitView(size: fit).frame(width: fit.width, height: fit.height)
                .simultaneousGesture(pinch(pane: fit, gap: 0))
                .onContinuousHover { scrollPane = $0 == .ended ? nil : fit }
        } else {
            let gap: CGFloat = 6
            let pane = CGSize(width: max(1, (size.width - gap) / 2), height: size.height)
            let shown = viewport.imageRect(image: imageSize, canvas: pane).intersection(CGRect(origin: .zero, size: pane))
            HStack(spacing: gap) {
                ZStack(alignment: .topLeading) {
                    zoomed(pane) { image(model.before).frame(width: $0.width, height: $0.height) }.allowsHitTesting(false)
                    badge(L10n.tr("Before")).padding(8).offset(x: shown.minX, y: shown.minY)
                }.frame(width: pane.width, height: pane.height)
                ZStack(alignment: .topLeading) {
                    zoomed(pane) { corrected(size: $0, badges: false, visible: visibleRect(pane)) }
                    badge(L10n.tr("After")).padding(8).offset(x: shown.minX, y: shown.minY).allowsHitTesting(false)
                    busy.frame(width: shown.width, height: shown.height, alignment: .bottomTrailing).offset(x: shown.minX, y: shown.minY).allowsHitTesting(false)
                }.frame(width: pane.width, height: pane.height)
            }
            // Pinching zooms both photos about the point under the fingers and scrolling pans them, over the Before one
            // too (its photo takes no clicks, so the pair is made one shape); a click stays free for the tags.
            .contentShape(Rectangle())
            .simultaneousGesture(pinch(pane: pane, gap: gap))
            .onContinuousHover { scrollPane = $0 == .ended ? nil : pane }
        }
    }

    /// The photo's proportions; the viewport works in fractions of it, so the size itself doesn't matter.
    private var imageSize: CGSize { CGSize(width: model.photoAspect * 1000, height: 1000) }
    /// Zooms about the point under the fingers, in whichever pane (each `pane` wide, `gap` apart) it began over.
    private func pinch(pane: CGSize, gap: CGFloat) -> some Gesture {
        MagnifyGesture().onChanged { value in
            let start = pinchStart ?? viewport
            pinchStart = start
            var x = value.startLocation.x
            while x > pane.width + gap { x -= pane.width + gap }
            var next = start
            next.zoom(to: start.scale * value.magnification, anchor: CGPoint(x: x, y: value.startLocation.y), image: imageSize, canvas: pane)
            viewport = next
        }.onEnded { _ in pinchStart = nil }
    }
    /// Scrolling over the zoomed photos, two fingers on a trackpad or a wheel, pans them; fitted, it does nothing.
    private func watchScrolling() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let pane = scrollPane, !viewport.isFitted else { return event }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            viewport.pan(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale), image: imageSize, canvas: pane)
            return nil
        }
    }
    /// `content` drawn at the viewport's size and place in `canvas`.
    private func zoomed<V: View>(_ canvas: CGSize, @ViewBuilder _ content: (CGSize) -> V) -> some View {
        let rect = viewport.imageRect(image: imageSize, canvas: canvas)
        return content(rect.size)
            .offset(x: rect.minX, y: rect.minY)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipped()
    }
    /// The part of a zoomed photo the pane shows, in the zoomed photo's points: clipping hides the rest but still lets it
    /// take clicks, so clicks outside it are ignored.
    private func visibleRect(_ canvas: CGSize) -> CGRect {
        let rect = viewport.imageRect(image: imageSize, canvas: canvas)
        return CGRect(x: -rect.minX, y: -rect.minY, width: canvas.width, height: canvas.height)
    }

    private func fitted(_ aspect: CGFloat, in size: CGSize) -> CGSize {
        size.width / max(1, size.height) > aspect ? CGSize(width: size.height * aspect, height: size.height) : CGSize(width: size.width, height: size.width / aspect)
    }

    private func image(_ image: CGImage?) -> some View {
        Group { if let image { Image(decorative: image, scale: 1).resizable() } else { Color.clear } }
    }

    private func splitView(size: CGSize) -> some View {
        let x = showBefore ? size.width : size.width * split
        return ZStack(alignment: .topLeading) {
            zoomed(size) { corrected(size: $0, badges: false, visible: visibleRect(size)) }
            zoomed(size) { image(model.before).frame(width: $0.width, height: $0.height) }
                .mask(alignment: .leading) { Rectangle().frame(width: x) }
                .allowsHitTesting(false)
            if !showBefore {
                Rectangle().fill(.white.opacity(0.85)).frame(width: 1.5, height: size.height).offset(x: x - 0.75).allowsHitTesting(false)
                Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.black))
                    .offset(x: x - 9, y: size.height / 2 - 9)
                    .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { split = min(0.98, max(0.02, $0.location.x / size.width)) })
                    .pointerStyle(.columnResize)
            }
            badge(L10n.tr("Before")).padding(8).allowsHitTesting(false)
            if !showBefore { badge(L10n.tr("After")).padding(8).frame(width: size.width, alignment: .trailing).allowsHitTesting(false) }
            busy.frame(width: size.width, height: size.height, alignment: .bottomTrailing).allowsHitTesting(false)
        }
    }

    /// The corrected photo with the grid and each person's tag; a click on a tag corrects or leaves that person, a click
    /// elsewhere adds someone there.
    private func corrected(size: CGSize, badges: Bool = true, visible: CGRect? = nil) -> some View {
        let mesh = model.mesh, people = model.shownPeople
        func place(_ p: CGPoint) -> CGPoint { let q = mesh?.forward(p) ?? p; return CGPoint(x: q.x * size.width, y: q.y * size.height) }
        func tag(_ person: WideAnglePerson) -> CGPoint {
            let top = place(CGPoint(x: person.head.x, y: person.head.y - person.headRadius.height * 1.1))
            return CGPoint(x: min(max(top.x, 13), size.width - 13), y: min(max(top.y - 12, 13), size.height - 13))
        }
        return ZStack(alignment: .topLeading) {
            image(model.after ?? model.before).frame(width: size.width, height: size.height)
            if !showBefore {
                Canvas { context, _ in
                    if showGrid, let mesh { drawGrid(mesh, in: size, context: &context) }
                    for person in people {
                        let lit = hovered == person.id
                        if lit {
                            let c = place(person.head)
                            let head = CGRect(x: c.x - person.headRadius.width * size.width, y: c.y - person.headRadius.height * size.height,
                                              width: person.headRadius.width * 2 * size.width, height: person.headRadius.height * 2 * size.height)
                            context.stroke(Path(ellipseIn: head), with: .color(.black.opacity(0.5)), lineWidth: 3.5)
                            context.stroke(Path(ellipseIn: head), with: .color(.white), lineWidth: 1.5)
                            let a = place(CGPoint(x: person.body.minX, y: person.body.minY)), b = place(CGPoint(x: person.body.maxX, y: person.body.maxY))
                            let body = Path(roundedRect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), cornerRadius: 6)
                            context.stroke(body, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                        drawTag(at: tag(person), on: person.enabled, added: person.added, context: &context)
                    }
                }
                .allowsHitTesting(false)
            }
            if badges {
                badge(showBefore ? L10n.tr("Before") : L10n.tr("After")).padding(8).allowsHitTesting(false)
                busy.frame(width: size.width, height: size.height, alignment: .bottomTrailing).allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case .active(let point) = phase, visible?.contains(point) ?? true else { hovered = nil; return }
            hovered = people.first { hypot(tag($0).x - point.x, tag($0).y - point.y) <= 13 }?.id
                ?? people.first { person in
                    let c = place(person.head)
                    let dx = (point.x - c.x) / (person.headRadius.width * size.width), dy = (point.y - c.y) / (person.headRadius.height * size.height)
                    return dx * dx + dy * dy <= 1
                }?.id
        }
        .onTapGesture { point in
            guard !showBefore, model.before != nil, visible?.contains(point) ?? true else { return }
            if let id = hovered, let person = people.first(where: { $0.id == id }) { model.toggle(person); return }
            let shot = mesh?.backward(CGPoint(x: point.x / size.width, y: point.y / size.height)) ?? CGPoint(x: point.x / size.width, y: point.y / size.height)
            model.add(at: shot)
        }
        .help(L10n.tr("Click a tag to correct or leave that person. Click a head that has no tag to add it."))
    }

    /// Portrait's face tag: filled with a check when the person is corrected, hollow when left as shot; one added by
    /// hand has a plus.
    private func drawTag(at c: CGPoint, on: Bool, added: Bool, context: inout GraphicsContext) {
        let r = 9.0
        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.5), radius: 3))
        shadowed.fill(circle, with: .color(on ? Theme.accent : .black.opacity(0.35)))
        if on {
            var mark = Path()
            if added {
                mark.move(to: CGPoint(x: c.x - r * 0.45, y: c.y)); mark.addLine(to: CGPoint(x: c.x + r * 0.45, y: c.y))
                mark.move(to: CGPoint(x: c.x, y: c.y - r * 0.45)); mark.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.45))
            } else {
                mark.move(to: CGPoint(x: c.x - r * 0.42, y: c.y)); mark.addLine(to: CGPoint(x: c.x - r * 0.1, y: c.y + r * 0.32)); mark.addLine(to: CGPoint(x: c.x + r * 0.45, y: c.y - r * 0.3))
            }
            context.stroke(mark, with: .color(Color(nsColor: AccentChoice.current.nsOnColor)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        context.stroke(circle, with: .color(.white), lineWidth: 1.5)
    }

    /// Every few grid lines of the mesh, where they land: straight where the background kept its lines.
    private func drawGrid(_ mesh: WideAngleMesh, in size: CGSize, context: inout GraphicsContext) {
        let every = max(1, mesh.columns / 24)
        var path = Path()
        func point(_ k: Int) -> CGPoint { CGPoint(x: mesh.target[k].x * size.width, y: mesh.target[k].y * size.height) }
        for j in stride(from: 0, to: mesh.rows, by: every) {
            path.move(to: point(j * mesh.columns))
            for i in 1..<mesh.columns { path.addLine(to: point(j * mesh.columns + i)) }
        }
        for i in stride(from: 0, to: mesh.columns, by: every) {
            path.move(to: point(i))
            for j in 1..<mesh.rows { path.addLine(to: point(j * mesh.columns + i)) }
        }
        context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
    }

    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
    @ViewBuilder private var busy: some View {
        if model.rendering { ProgressView().controlSize(.mini).padding(10) }
    }

    // MARK: Options

    private var options: some View {
        let people = model.shownPeople
        return VStack(alignment: .leading, spacing: 14) {
            ExportRow(L10n.tr("Lens")) { lens }
            if model.before != nil {
                ExportRow(L10n.tr("People")) {
                    Text(L10n.tr("\(people.filter(\.enabled).count) of \(people.count)")).monospacedDigit()
                }
                Rule()
            }
            ExportRow(L10n.tr("Strength")) { percent($model.settings.strength, reset: 1) }
            ExportRow(L10n.tr("Bodies")) {
                HStack(spacing: 8) {
                    Toggle(isOn: $model.settings.bodies) { EmptyView() }.labelsHidden().toggleStyle(.formCheckbox).controlSize(.small)
                        .accessibilityLabel(L10n.tr("Correct bodies"))
                    percent($model.settings.bodyAmount, reset: 0.5).disabled(!model.settings.bodies)
                }
            }
            .help(L10n.tr("Each body follows its head, so a corrected head doesn't sit on a stretched body"))
            ExportRow(L10n.tr("Straight Lines")) { percent($model.settings.straightLines, reset: 0.5) }
                .help(L10n.tr("How firmly the background keeps its lines straight around the people"))
            // A RAW's copy is always a DNG, so the choice is only offered for the rest.
            if !CatalogModel.isRAW(model.asset) {
                ExportRow(L10n.tr("Format")) {
                    Picker(L10n.tr("Format"), selection: $model.settings.format) {
                        Text(L10n.tr("Original")).tag(ProcessedFormat.original)
                        Text("TIFF").tag(ProcessedFormat.tiff)
                    }.pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help(L10n.tr("Original keeps HEIC, JPEG, TIFF and PNG and saves other formats as HEIC. TIFF is 16-bit. RAWs are always saved as DNG."))
            }
            Text(L10n.tr("Saves a copy beside the original."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help(L10n.tr("The copy keeps the photo's EXIF and edits, and the HDR of a HEIC or JPEG, but not crops, masks or retouching."))
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The 35 mm equivalent focal length, the EXIF's until another is typed; Correct waits for one when the EXIF has none.
    private var lens: some View {
        let exif = model.exifFocal
        return HStack(spacing: 6) {
            TextField(L10n.tr("Focal length"), value: Binding(get: { model.focal }, set: { model.setFocal($0) }),
                      format: .number.precision(.fractionLength(0...1)))
                .frame(width: 56).textFieldStyle(.formField).monospacedDigit()
            Text(L10n.tr("mm")).foregroundStyle(.secondary)
            if model.typedFocal != nil, let exif {
                Button(L10n.tr("EXIF")) { model.setFocal(nil) }.buttonStyle(.secondaryAction).controlSize(.small)
                    .help(L10n.tr("Use the EXIF's \(Int(exif.rounded())) mm"))
            }
        }
        .help(L10n.tr("35 mm equivalent focal length"))
    }

    private func percent(_ value: Binding<Double>, reset: Double) -> some View {
        HStack(spacing: 8) {
            FormSlider(value: value, in: 0...1, reset: { value.wrappedValue = reset })
            Text(L10n.tr("\(Int((value.wrappedValue * 100).rounded()))%")).monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}
