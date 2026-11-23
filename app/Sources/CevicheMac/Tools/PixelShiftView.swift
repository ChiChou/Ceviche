import SwiftUI
import AppKit
import CevicheCore

/// Reads and aligns the set once, then shows its first four shots merged.
@MainActor
final class PixelShiftModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: PixelShiftRequest
    /// The preview and the result take the base photo's edits.
    private lazy var developer = MergePreviewDeveloper(assets: request.assets, placed: EditTransferItem.framed)
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var analysis: PixelShiftAnalysis?
    @Published private(set) var preview: PixelShiftPreview?
    @Published var showMotion: Bool { didSet { UserDefaults.standard.set(showMotion, forKey: "pixelShiftShowMotion") } }
    private var merger: PixelShiftMerger?
    private var first: URL?
    private var access: [URL] = []
    private var task: Task<Void, Never>?

    init(request: PixelShiftRequest) {
        self.request = request
        showMotion = UserDefaults.standard.object(forKey: "pixelShiftShowMotion") as? Bool ?? true
    }
    var canMerge: Bool { stage == .ready && preview != nil }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        developer.catalog = catalog
        task = Task {
            do {
                var urls: [URL] = []
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                let merger = try PixelShiftMerger(urls: urls)
                let progress: @Sendable (Double, String) -> Void = { fraction, message in
                    Task { @MainActor in
                        guard case .preparing = self.stage else { return }
                        self.stage = .preparing(message, fraction)
                    }
                }
                let work = Task.detached(priority: .userInitiated) { () -> (PixelShiftAnalysis, PixelShiftPreview) in
                    let analysis = try merger.analyze(progress: progress)
                    progress(0.96, L10n.tr("Creating preview…"))
                    return (analysis, try merger.preview())
                }
                let (analysis, preview) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                self.merger = merger; self.analysis = analysis; self.preview = preview
                first = urls.first { $0.lastPathComponent == analysis.frames[0].filename } ?? urls[0]
                // A merge too large for a DNG is kept without the edits, so its preview shows none.
                if analysis.developable, let image = await developer.image(preview.source, base: first, size: max(preview.image.width, preview.image.height)) {
                    self.preview?.image = image
                }
                stage = .ready
            } catch is CancellationError {
            } catch { abort(catalog: catalog, error) }
        }
    }

    /// Merges into a linear DNG, or with `export` into a full-quality JPEG or a 16-bit TIFF alone: a 16-shot DNG is
    /// very large.
    func merge(catalog: CatalogModel, export: ExportFormat? = nil) {
        guard canMerge, let merger, let analysis, let first else { return }
        let access = self.access
        self.access = []
        catalog.startPixelShift(merger, analysis: analysis, first: first, editsFrom: developer.asset(for: first), access: access, export: export)
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
        catalog.pixelShift = nil
    }
    func stop() {
        task?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }
}

/// Pixel Shift fills the window like the other merges: the merged preview to zoom into, the shots listed beside it.
/// The shots differ only by where the sensor sat, so they get no thumbnails: a diagram of those positions and a table.
/// What moved between the shots is the one thing to look at before merging.
struct PixelShiftView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: PixelShiftModel
    init(catalog: CatalogModel, request: PixelShiftRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: PixelShiftModel(request: request))
    }

    var body: some View {
        // Every form is added to the catalog beside the sources. TIFF first: the DNG of a 16-shot set is very large.
        ToolWorkspace(title: L10n.tr("Pixel Shift"), status: status, statusIsWarning: statusIsWarning, primary: L10n.tr("Merge to TIFF"),
                      primaryDisabled: !model.canMerge,
                      // A DNG wider than Apple's decoder develops would open blank.
                      primaryOptions: [(L10n.tr("Merge to JPEG"), { model.merge(catalog: catalog, export: .jpeg) })]
                        + (model.analysis?.developable == false ? [] : [(L10n.tr("Merge to DNG"), { model.merge(catalog: catalog) })]),
                      cancel: { model.close(catalog: catalog) }, action: { model.merge(catalog: catalog, export: .tiff) }) {
            Toggle(L10n.tr("Show Motion"), isOn: $model.showMotion).toggleStyle(.formCheckbox)
                .disabled(model.preview?.motion == nil).help(motionHelp)
            if let analysis = model.analysis, analysis.shots == 16 {
                Text(L10n.tr("Preview: first 4 of 16")).foregroundStyle(.secondary)
            }
        } content: {
            HStack(spacing: 0) {
                canvas
                if let analysis = model.analysis {
                    Rule(.vertical)
                    PixelShiftShotsPanel(analysis: analysis)
                }
            }
        } actions: { EmptyView() }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        guard let analysis = model.analysis else { return L10n.tr("\(model.request.assets.count) photos") }
        return L10n.tr("\(analysis.shots) photos - \(analysis.width.formatted()) × \(analysis.height.formatted())")
    }
    private var statusIsWarning: Bool { if case .failed = model.stage { return true }; return false }

    private var motionHelp: String {
        guard let preview = model.preview, preview.motion != nil else { return L10n.tr("Nothing moved between the photos") }
        let percent = String(format: "%.1f", locale: Locale.current, preview.motionCoverage * 100)
        return L10n.tr("Tints what moved between the photos; those areas come from one photo alone (\(percent)% of the photo)")
    }

    private var canvas: some View {
        let orientation = Image.Orientation(exif: model.analysis?.orientation ?? 1)
        return ZStack {
            ZoomCanvas(image: model.preview?.image, orientation: orientation) { _ in
                if model.showMotion, let motion = model.preview?.motion {
                    Color.pink.opacity(0.55)
                        .mask(Image(decorative: motion, scale: 1, orientation: orientation).resizable().interpolation(.high).luminanceToAlpha())
                        .allowsHitTesting(false)
                }
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Merge These Photos"), systemImage: "square.grid.2x2", description: Text(message))
            case .ready: EmptyView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The shots of a set, beside the preview: where the sensor sat for each, then a row per shot.
struct PixelShiftShotsPanel: View {
    let analysis: PixelShiftAnalysis
    /// The shot under the pointer, in the diagram or the table, marked in both.
    @State private var hovered: Int?

    /// A multi-shot file holds every shot, so its name is said once rather than on every row.
    private var oneFile: String? {
        let names = Set(analysis.frames.map(\.filename))
        return names.count == 1 ? names.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Shots")).font(.headline)
                if let oneFile {
                    Text(L10n.tr("All in \(oneFile)")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(oneFile)
                }
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            PixelShiftPositions(frames: analysis.frames, hovered: $hovered)
                .frame(maxWidth: .infinity).frame(height: 120).padding(.horizontal, 12).padding(.bottom, 10)
                .help(L10n.tr("Where the sensor sat for each shot, as the sensor is oriented"))
            Rule()
            header
            Rule()
            ScrollView {
                VStack(spacing: 0) { ForEach(analysis.frames) { row($0) } }
            }
        }
        .frame(width: 256).frame(maxHeight: .infinity).background(Theme.statusBar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.tr("Shot")).frame(width: 30, alignment: .leading)
            Text(oneFile == nil ? L10n.tr("File") : "").frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.tr("X")).frame(width: 40, alignment: .trailing)
            Text(L10n.tr("Y")).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 5)
        .help(L10n.tr("How far the sensor moved from the first shot, in pixels"))
    }

    private func row(_ frame: PixelShiftFrameInfo) -> some View {
        HStack(spacing: 8) {
            Text(L10n.tr("\(frame.index + 1)")).fontWeight(.semibold).frame(width: 30, alignment: .leading)
            Text(oneFile == nil ? frame.filename : "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(pixels(frame.shift.x)).frame(width: 40, alignment: .trailing)
            Text(pixels(frame.shift.y)).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 11)).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(hovered == frame.index ? Theme.cardFill : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? frame.index : (hovered == frame.index ? nil : hovered) }
        .help(shiftHelp(frame))
    }

    /// Rounded first, so a shot a hair off zero doesn't read −0.0.
    private func pixels(_ value: Double) -> String {
        String(format: "%+.1f", locale: Locale.current, (value * 10).rounded() / 10 + 0)
    }
    private func shiftHelp(_ frame: PixelShiftFrameInfo) -> String {
        let x = String(format: "%+.2f", locale: Locale.current, frame.shift.x), y = String(format: "%+.2f", locale: Locale.current, frame.shift.y)
        let stops = String(format: "%+.2f", locale: Locale.current, frame.stops)
        return L10n.tr("\(frame.filename): sensor moved \(x), \(y) px, \(stops) EV evened out")
    }
}

/// Each shot's sensor position as a numbered dot on a pixel grid (half-pixel lines too when the set uses them).
struct PixelShiftPositions: View {
    let frames: [PixelShiftFrameInfo]
    @Binding var hovered: Int?

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(frames: frames, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for line in layout.lines {
                        context.stroke(Path { $0.move(to: line.0); $0.addLine(to: line.1) }, with: .color(Theme.ink.opacity(line.2 ? 0.16 : 0.07)), lineWidth: 1)
                    }
                }
                ForEach(frames) { frame in
                    let lit = hovered == frame.index
                    Text(L10n.tr("\(frame.index + 1)")).font(.system(size: layout.dot > 18 ? 10 : 8, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(lit ? Theme.onAccent : Theme.ink.opacity(0.85))
                        .frame(width: layout.dot, height: layout.dot)
                        .background(lit ? Theme.accent : Theme.panel, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(lit ? 0 : 0.25)))
                        .position(layout.point(frame.shift))
                        .onHover { hovered = $0 ? frame.index : (hovered == frame.index ? nil : hovered) }
                }
            }
        }
    }

    private struct Layout {
        let origin: CGPoint, scale: CGFloat, dot: CGFloat
        let lines: [(CGPoint, CGPoint, Bool)]

        init(frames: [PixelShiftFrameInfo], size: CGSize) {
            let halves = frames.contains { ($0.shift.x * 2).rounded().truncatingRemainder(dividingBy: 2) != 0 || ($0.shift.y * 2).rounded().truncatingRemainder(dividingBy: 2) != 0 }
            // Measured shifts sit a hair off the grid; the grid's bounds snap to it, so +0.1 px adds no row.
            let step = halves ? 0.5 : 1
            let xs = frames.map { ($0.shift.x / step).rounded() * step }, ys = frames.map { ($0.shift.y / step).rounded() * step }
            // At least one pixel across, so a set that barely moved still draws a square cell.
            let minX = xs.min() ?? 0, maxX = max(xs.max() ?? 0, minX + 1)
            let minY = ys.min() ?? 0, maxY = max(ys.max() ?? 0, minY + 1)
            let span = max(maxX - minX, maxY - minY)
            dot = halves || span > 2 ? 16 : 22
            let inset = dot / 2 + 2
            scale = (min(size.width, size.height) - inset * 2) / CGFloat(span)
            let w = CGFloat(maxX - minX) * scale, h = CGFloat(maxY - minY) * scale
            origin = CGPoint(x: (size.width - w) / 2 - CGFloat(minX) * scale, y: (size.height - h) / 2 - CGFloat(minY) * scale)
            var lines: [(CGPoint, CGPoint, Bool)] = []
            for x in stride(from: minX, through: maxX, by: step) {
                let px = origin.x + CGFloat(x) * scale
                lines.append((CGPoint(x: px, y: origin.y + CGFloat(minY) * scale), CGPoint(x: px, y: origin.y + CGFloat(maxY) * scale), x.rounded() == x))
            }
            for y in stride(from: minY, through: maxY, by: step) {
                let py = origin.y + CGFloat(y) * scale
                lines.append((CGPoint(x: origin.x + CGFloat(minX) * scale, y: py), CGPoint(x: origin.x + CGFloat(maxX) * scale, y: py), y.rounded() == y))
            }
            self.lines = lines
        }
        func point(_ shift: SIMD2<Double>) -> CGPoint { CGPoint(x: origin.x + CGFloat(shift.x) * scale, y: origin.y + CGFloat(shift.y) * scale) }
    }
}
