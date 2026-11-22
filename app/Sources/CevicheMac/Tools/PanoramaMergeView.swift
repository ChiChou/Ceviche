import SwiftUI
import AppKit
import CevicheCore

/// Aligns the photos once, then redraws the preview from that alignment as the options change. Photos that are
/// brackets at each position are found from their recorded exposures and merged to HDR before they are stitched.
@MainActor
final class PanoramaMergeModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: PanoramaMergeRequest
    /// The preview and the result take the base photo's edits.
    private lazy var developer = MergePreviewDeveloper(assets: request.assets)
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var alignment: PanoramaAlignment?
    @Published private(set) var preview: CGImage?
    @Published private(set) var rendering = false
    @Published private(set) var previewError: String?
    @Published var settings = PanoramaSettings() { didSet { if settings != oldValue { remember(); render() } } }
    /// Each position's bracket is merged to HDR before the positions are stitched.
    @Published private(set) var hdr = false
    /// How each bracket's merge handles what moved between its exposures.
    @Published private(set) var deghosting = HDRDeghosting.medium
    /// The brackets, one per position, once they have been looked for.
    @Published private(set) var grouping: HDRPanoramaGrouping?
    private(set) var merger: PanoramaMerger?
    private var brackets: HDRPanoramaMerger?
    /// The originals, in the order of the request's photos.
    private var urls: [URL] = []
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let preferences = UserDefaults.standard

    init(request: PanoramaMergeRequest) {
        self.request = request
        settings.autoCrop = preferences.bool(forKey: "panoramaAutoCrop")
        settings.boundaryWarp = min(1, max(0, preferences.double(forKey: "panoramaBoundaryWarp")))
        settings.fillEdges = preferences.bool(forKey: "panoramaFillEdges") && !settings.autoCrop && PanoramaSettings.canFillEdges
        if let latent = request.latent {
            settings = latent.saved.settings; settings.fillEdges = settings.fillEdges && PanoramaSettings.canFillEdges
            hdr = latent.saved.hdr; deghosting = latent.saved.deghosting
            latentAssetID = latent.assetID; savedLatent = latent.saved
        }
    }

    // MARK: Latent image

    /// The latent image this window opened, or the one its merge left.
    private(set) var latentAssetID: String?
    private var savedLatent: PanoramaLatent?
    /// The opened latent image's alignment, taken once in place of aligning; dropped when a source has changed.
    private var restoring: PanoramaSolved?
    /// Whether the alignment on screen came from the latent image rather than from aligning.
    private(set) var restored = false
    /// The first alignment of an opened latent image is done; later ones (HDR, Deghost) suggest a projection again.
    private var openedLatent = false
    /// Keeps the options and the alignment in the latent image: a new one only for a merge with Keep
    /// Latent Image ticked, which closing updates.
    func keepLatent(catalog: CatalogModel, output: Bool) {
        guard output && LatentPreference.keeps(LatentImage.panorama) || latentAssetID != nil, stage == .ready, let merger, let preview, let store = catalog.store else { return }
        let state = PanoramaLatent(settings: settings, hdr: hdr, deghosting: deghosting, solved: merger.solved)
        guard state != savedLatent else { return }
        savedLatent = state
        let sources = request.assets, into = latentAssetID
        let stem = (sources[0].filename as NSString).deletingPathExtension
        Task {
            do {
                var references: [LatentImage.Source] = []
                for asset in sources { references.append(try await catalog.latentSource(asset)) }
                let latent = try LatentImage(catalogID: store.manifest.id, sources: references, panorama: state, width: preview.width, height: preview.height)
                latentAssetID = try await catalog.storeLatent(latent, pictures: try LatentImage.pictures(preview), name: "\(stem)-Panorama",
                                                              sources: sources, into: latentAssetID ?? into, store: store)
            } catch is CancellationError {
            } catch { savedLatent = nil; catalog.failure = Failure(L10n.tr("Couldn’t Keep the Latent Image"), error) }
        }
    }
    var canMerge: Bool { stage == .ready && preview != nil && previewError == nil }
    /// Brackets of two positions need four photos at least.
    var canUseHDR: Bool { request.assets.count >= 4 }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        developer.catalog = catalog
        task = Task {
            do {
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                // A source that changed since the alignment was saved: align again.
                if let latent = request.latent, latent.saved.solved != nil {
                    let urls = self.urls
                    let unchanged = await Task.detached { zip(latent.sources, urls).allSatisfy { (try? $0.validate($1)) != nil } }.value
                    restoring = unchanged && latent.sources.count == urls.count ? latent.saved.solved : nil
                }
                if canUseHDR, request.latent == nil {
                    let urls = self.urls
                    hdr = await Task.detached(priority: .userInitiated) { HDRPanoramaMerger.looksBracketed(urls) }.value
                }
                try await prepare(catalog: catalog)
            } catch is CancellationError {
            } catch { stage = .failed(error.localizedDescription) }
        }
    }

    /// Turns merging each position to HDR on or off, and aligns again.
    func setHDR(_ on: Bool, catalog: CatalogModel) {
        guard on != hdr, canUseHDR else { return }
        hdr = on
        restart(catalog: catalog)
    }

    func setDeghosting(_ deghosting: HDRDeghosting, catalog: CatalogModel) {
        guard deghosting != self.deghosting else { return }
        self.deghosting = deghosting
        if hdr { restart(catalog: catalog) }
    }

    private func restart(catalog: CatalogModel) {
        task?.cancel(); renderTask?.cancel()
        stage = .preparing(L10n.tr("Aligning photos…"), nil)
        task = Task {
            do { try await prepare(catalog: catalog) } catch is CancellationError {
            } catch { stage = .failed(error.localizedDescription) }
        }
    }

    /// Groups the brackets when HDR is on and they haven't been, merges them, aligns, and draws the first preview. A
    /// position whose bracket is short is merged from what it has, and the status says so.
    private func prepare(catalog: CatalogModel) async throws {
        merger = nil; alignment = nil; preview = nil; previewError = nil
        let progress: @Sendable (Double, String) -> Void = { fraction, message in
            Task { @MainActor in
                guard case .preparing = self.stage else { return }
                self.stage = .preparing(message.isEmpty ? L10n.tr("Aligning photos…") : message, fraction)
            }
        }
        // The merger, its alignment, and whether that came from the latent image rather than from aligning.
        let work: Task<(PanoramaMerger, PanoramaAlignment, Bool), Error>
        if hdr {
            if grouping == nil || brackets == nil {
                let brackets = try HDRPanoramaMerger(urls: urls)
                let grouped = Task.detached(priority: .userInitiated) { try brackets.group(progress: { progress(0.3 * $0, $1) }) }
                let found = try await withTaskCancellationHandler { try await grouped.value } onCancel: { grouped.cancel() }
                try Task.checkCancellation()
                self.brackets = brackets; grouping = found
            }
            guard let brackets, let groups = grouping?.groups else { return }
            brackets.retouch = await catalog.retouching(of: request.assets, at: urls)
            let deghosting = self.deghosting
            let solved = restoring
            work = Task.detached(priority: .userInitiated) {
                let merger = try brackets.panorama(groups: groups, deghosting: deghosting, progress: { progress(0.3 + 0.4 * $0, $1) })
                if let solved, let alignment = try? merger.restore(solved, progress: { progress(0.7 + 0.3 * $0, $1) }) { return (merger, alignment, true) }
                return (merger, try merger.align(progress: { progress(0.7 + 0.3 * $0, $1) }), false)
            }
        } else {
            let merger = try PanoramaMerger(urls: urls)
            merger.retouch = await catalog.retouching(of: request.assets, at: urls)
            let solved = restoring
            work = Task.detached(priority: .userInitiated) {
                if let solved, let alignment = try? merger.restore(solved, progress: progress) { return (merger, alignment, true) }
                return (merger, try merger.align(progress: progress), false)
            }
        }
        let opening = !openedLatent && request.latent != nil
        restoring = nil
        let (merger, alignment, restoredNow) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        self.merger = merger; self.alignment = alignment
        stage = .preparing(L10n.tr("Creating preview…"), nil)
        restored = restoredNow
        openedLatent = true
        // An opened latent image keeps the projection it was left with, when the photos can still show it.
        var initial = settings
        if !opening || !alignment.available.contains(initial.projection) { initial.projection = alignment.suggested }
        settings = initial
        render(immediately: true)
    }

    /// Draws the preview for the current options. Renders run one at a time; a newer request replaces a waiting one.
    func render(immediately: Bool = false) {
        guard merger != nil else { return }
        let previous = renderTask
        previous?.cancel()
        let settings = self.settings
        renderTask = Task { [weak self] in
            await previous?.value
            // A fill takes seconds, so it waits until the options settle.
            if !immediately { try? await Task.sleep(for: .milliseconds(settings.fillEdges && !settings.autoCrop ? 200 : 25)) }
            guard !Task.isCancelled, let self, let merger = self.merger else { return }
            self.rendering = true
            let result = await Task.detached(priority: .userInitiated) { Result { try merger.preview(settings) } }.value
            guard !Task.isCancelled else { return }
            var developed: CGImage?
            if case .success(let preview) = result, let source = preview.source {
                developed = await self.developer.image(source, base: merger.urls[source.base], size: max(preview.image.width, preview.image.height))
                guard !Task.isCancelled else { return }
            }
            self.rendering = false
            switch result {
            case .success(let preview): self.preview = developed ?? preview.image; self.previewError = nil
            case .failure(let error): self.previewError = error.localizedDescription
            }
            if case .preparing = self.stage { self.stage = .ready }
        }
    }

    /// Hands the merge to the catalog's background jobs; the originals stay open until it finishes.
    func merge(catalog: CatalogModel) {
        guard canMerge, let merger, let alignment else { return }
        let access = self.access
        self.access = []
        catalog.startPanoramaMerge(merger, alignment: alignment, settings: settings, hdr: hdr,
                                   editsFrom: developer.asset(for: merger.urls[alignment.included.first ?? 0]), access: access)
        keepLatent(catalog: catalog, output: true)
        close(catalog: catalog)
    }

    func close(catalog: CatalogModel) {
        keepLatent(catalog: catalog, output: false)
        stop()
        catalog.panoramaMerge = nil
    }
    /// Ends the alignment and releases the originals; also when the catalog closes the merge from outside.
    func stop() {
        task?.cancel(); renderTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }

    private func remember() {
        preferences.set(settings.autoCrop, forKey: "panoramaAutoCrop")
        preferences.set(settings.boundaryWarp, forKey: "panoramaBoundaryWarp")
        preferences.set(settings.fillEdges, forKey: "panoramaFillEdges")
    }
}

/// Panorama merge fills the window, as in other RAW editors: the preview in the middle, the options on the right,
/// Cancel and Merge in the title bar.
struct PanoramaMergeView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: PanoramaMergeModel
    init(catalog: CatalogModel, request: PanoramaMergeRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: PanoramaMergeModel(request: request))
    }
    var body: some View {
        ToolWorkspace(title: L10n.tr("Panorama Merge"),
                      status: status, statusIsWarning: statusIsWarning, statusHelp: alignmentHelp,
                      primary: L10n.tr("Merge"), primaryDisabled: !model.canMerge,
                      cancel: { model.close(catalog: catalog) }, action: { model.merge(catalog: catalog) },
                      toolbar: { options.disabled(model.alignment == nil) }, content: { canvas })
            .onAppear { model.start(catalog: catalog) }
            .onDisappear { model.stop() }
    }

    private var alignmentHelp: String {
        model.alignment.map { L10n.tr("Aligned within \(String(format: "%.1f", locale: Locale.current, $0.medianErrorPixels)) px (median), \(String(format: "%.1f", locale: Locale.current, $0.p95ErrorPixels)) px (95th percentile)") } ?? ""
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        if let error = model.previewError { return error }
        guard let alignment = model.alignment else {
            return L10n.tr("\(model.request.assets.count) photos")
        }
        let total = alignment.filenames.count, left = alignment.excluded.count
        if model.hdr, let grouping = model.grouping {
            if let repeated = grouping.repeatedPositions.first {
                return L10n.tr("Positions \(repeated) and \(repeated + 1) show the same view")
            }
            if let odd = grouping.oddPositions.first {
                return L10n.tr("Position \(odd + 1) has \(grouping.groups[odd].count) photos, most have \(grouping.usualSize)")
            }
            if left > 0 { return L10n.tr("\(left) of \(total) positions couldn’t be merged: \(alignment.excluded.joined(separator: ", "))") }
            return L10n.tr("\(total) positions - \(model.request.assets.count) photos")
        }
        if left > 0 { return L10n.tr("\(left) of \(total) photos couldn’t be merged: \(alignment.excluded.joined(separator: ", "))") }
        return L10n.tr("\(total) photos")
    }
    private var statusIsWarning: Bool {
        if case .failed = model.stage { return true }
        if model.hdr, let grouping = model.grouping, !grouping.oddPositions.isEmpty || !grouping.repeatedPositions.isEmpty { return true }
        return model.previewError != nil || model.alignment?.excluded.isEmpty == false
    }

    private var canvas: some View {
        ZStack {
            ZoomCanvas(image: model.preview, checkerboard: true)
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Merge These Photos"), systemImage: "pano", description: Text(message))
            case .ready: if model.rendering { ToolProgressCard(message: L10n.tr("Creating preview…")).transition(.opacity) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The options in one row under the title bar, so the preview keeps the window's full width.
    @ViewBuilder private var options: some View {
        FormSegments(title: L10n.tr("Projection"), selection: $model.settings.projection, options: PanoramaProjection.allCases, label: { $0.title }, icon: { switch $0 { case .cylindrical: "cylinder"; case .spherical: "globe"; case .perspective: "perspective" } }).fixedSize()
            .disabled(model.alignment.map { $0.available.count < 2 } ?? true)
            .help(projectionHelp)
        Rule(.vertical).frame(height: 16)
        Text(L10n.tr("Boundary Warp")).foregroundStyle(.secondary)
        FormSlider(value: Binding(get: { model.settings.boundaryWarp * 100 }, set: { model.settings.boundaryWarp = ($0 / 100) }), in: 0...100, step: 1)
            .frame(width: 110).labelsHidden()
            .help(L10n.tr("Bends the edges out to fill the frame"))
        Text(verbatim: String(Int((model.settings.boundaryWarp * 100).rounded()))).font(.callout).monospacedDigit().frame(width: 26, alignment: .leading)
        Rule(.vertical).frame(height: 16)
        Toggle(L10n.tr("Auto Crop"), isOn: Binding(get: { model.settings.autoCrop }, set: { on in
            model.settings.autoCrop = on; if on { model.settings.fillEdges = false }
        })).help(L10n.tr("Crops to the largest rectangle the photos cover"))
        Toggle(L10n.tr("Fill Edges"), isOn: Binding(get: { model.settings.fillEdges && PanoramaSettings.canFillEdges }, set: { on in
            model.settings.fillEdges = on; if on { model.settings.autoCrop = false }
        }))
        .disabled(!PanoramaSettings.canFillEdges)
        .help(PanoramaSettings.canFillEdges ? L10n.tr("Fills the empty edges with AI fill")
              : L10n.tr("The \(BundledModel.inpaint.feature) model is not installed. Install it in Settings › Models."))
        if model.canUseHDR {
            Rule(.vertical).frame(height: 16)
            Toggle(L10n.tr("HDR"), isOn: Binding(get: { model.hdr }, set: { model.setHDR($0, catalog: catalog) }))
                .help(L10n.tr("Merges each position’s bracket to HDR, then stitches"))
            if model.hdr {
                Text(L10n.tr("Deghost")).foregroundStyle(.secondary)
                FormSegments(title: L10n.tr("Deghost"), selection: Binding(get: { model.deghosting }, set: { model.setDeghosting($0, catalog: catalog) }),
                             options: HDRDeghosting.allCases, label: { $0.title }).labelsHidden().fixedSize()
                    .help(L10n.tr("Where the exposures disagree because something moved, takes that area from the base exposure alone. Higher settings catch smaller changes."))
            }
        }
        if model.request.latent == nil {
            Rule(.vertical).frame(height: 16)
            LatentCheckbox(type: LatentImage.panorama)
        }
    }

    private var projectionHelp: String {
        if let alignment = model.alignment, alignment.available.count < 2 {
            let missing = PanoramaProjection.allCases.filter { !alignment.available.contains($0) }.map(\.title).joined(separator: ", ")
            return L10n.tr("\(missing) can’t show these photos: they cover too wide a view.")
        }
        return L10n.tr("Cylindrical keeps verticals straight in wide panoramas; Spherical suits tall and whole-sky ones; Perspective keeps every straight line straight, for narrower ones.")
    }
}

/// The transparency pattern behind areas no photo covers.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.8)))
            for row in 0..<Int(ceil(size.height / side)) {
                for column in 0..<Int(ceil(size.width / side)) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)), with: .color(Color(white: 0.95)))
                }
            }
        }
    }
}
