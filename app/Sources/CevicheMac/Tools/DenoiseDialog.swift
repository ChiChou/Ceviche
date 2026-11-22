import SwiftUI
import ImageIO
import CevicheCore

/// What the AI Noise Reduction dialog shows: one of the photos as shot, and a full-size crop of it before and after
/// the network, as big as the panes showing it, which a click on the photo moves. The crop stays put when another of
/// the selected photos is shown, so the same spot can be compared across them.
@MainActor
final class DenoiseModel: ObservableObject {
    enum Stage: Equatable { case loading, ready, failed(String) }

    let request: DenoiseRequest
    @Published private(set) var stage = Stage.loading
    /// The photo previewed, by position in the request.
    @Published var index = 0 { didSet { if index != oldValue { load() } } }
    @Published private(set) var overview: CGImage?
    @Published private(set) var crop: (before: CGImage, after: CGImage)? { didSet { cropVersion += 1 } }
    /// Counts crop updates, so the loupe knows when a pan has landed.
    @Published private(set) var cropVersion = 0
    @Published private(set) var rendering = false
    /// The middle of the crop, in fractions of the photo's width and height from the top left.
    @Published var center = CGPoint(x: 0.5, y: 0.5) { didSet { if center != oldValue { renderCrop() } } }
    /// The crop's size in full-size pixels: the panes' size on screen, so the crop shows one pixel per pixel, up to
    /// about a megapixel each, which the network denoises in a second or two.
    @Published var cropSize = CGSize(width: 448, height: 448) { didSet { if cropSize != oldValue { renderCrop() } } }
    @Published var settings: DenoiseSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.preferenceKey) } }
    }
    /// The Library thumbnails of the selected photos, for the filmstrip.
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    private weak var catalog: CatalogModel?
    private var previewer: DenoisePreviewer?
    private var access: URL?
    private var loadTask: Task<Void, Never>?
    private var cropTask: Task<Void, Never>?
    private static let preferenceKey = "denoiseSettings"

    init(request: DenoiseRequest) {
        self.request = request
        settings = UserDefaults.standard.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode(DenoiseSettings.self, from: $0) } ?? DenoiseSettings()
    }

    var asset: CatalogAsset { request.assets[index] }

    func start(catalog: CatalogModel) {
        guard self.catalog == nil else { return }
        self.catalog = catalog
        load()
        guard request.assets.count > 1 else { return }
        Task {
            for (number, asset) in request.assets.enumerated() {
                guard let data = try? await catalog.previews?.data(assetID: asset.id),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = ImageDecode.thumbnail(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 240, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
                thumbnails[number] = image
            }
        }
    }
    /// Steps to the next or previous selected photo, wrapping around.
    func step(_ offset: Int) {
        let count = request.assets.count
        guard count > 1 else { return }
        index = ((index + offset) % count + count) % count
    }
    func stop() {
        loadTask?.cancel(); cropTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
    }

    private func load() {
        guard let catalog else { return }
        loadTask?.cancel(); cropTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
        previewer = nil; overview = nil; crop = nil; stage = .loading
        let asset = self.asset
        loadTask = Task {
            do {
                let url = try await catalog.resolveOriginal(asset)
                if url.startAccessingSecurityScopedResource() { access = url }
                let exposure = await catalog.denoiseExposure(asset)
                let previewer = try await Task.detached(priority: .userInitiated) { try DenoisePreviewer(url, exposure: exposure) }.value
                guard !Task.isCancelled else { return }
                self.previewer = previewer; overview = previewer.overview; stage = .ready
                renderCrop()
            } catch {
                if !Task.isCancelled { stage = .failed(error.localizedDescription) }
            }
        }
    }

    private func renderCrop() {
        guard let previewer else { return }
        cropTask?.cancel()
        let center = self.center, size = cropSize
        rendering = true
        cropTask = Task {
            // Dragging moves the crop many times a second; only where it rests is denoised.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            // The panes fill in tile by tile; a newer crop stops this one between tiles.
            let stop = StopFlag()
            let result = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    try? previewer.crop(center: center, size: size, progress: { before, after in
                        Task { @MainActor in if !stop.isSet { self.crop = (before, after) } }
                    }, cancelled: { stop.isSet })
                }.value
            } onCancel: { stop.set() }
            stop.set()
            guard !Task.isCancelled else { return }
            if let result { crop = result }
            rendering = false
        }
    }

    /// The crop's frame over the overview, in fractions of its width and height.
    var cropFrame: CGRect { previewer?.frame(center: center, size: cropSize) ?? .zero }
    /// The photo's full-size width and height, once developed.
    var photoSize: CGSize { previewer?.size ?? .zero }
}

/// Set once, from any thread.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

struct DenoiseDialog: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: DenoiseModel
    @ObservedObject private var library = ModelLibrary.shared
    init(catalog: CatalogModel, request: DenoiseRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: DenoiseModel(request: request))
    }

    private var modelAvailable: Bool { _ = library.installed; return BundledModel.denoise.isAvailable }

    var body: some View {
        let count = model.request.assets.count
        ToolWorkspace(title: L10n.tr("AI Noise Reduction"), status: summary,
                      primary: count == 1 ? L10n.tr("Reduce Noise for 1 Photo") : L10n.tr("Reduce Noise for \(count) Photos"),
                      primaryDisabled: !modelAvailable || !catalog.canStartJob, cancel: close,
                      action: { catalog.startDenoise(model.request.assets, settings: model.settings); close() }) {
            FormSegments(title: L10n.tr("Compare"), selection: $compare, options: Compare.allCases, label: { $0.title }).labelsHidden().fixedSize()
            FormSegments(title: L10n.tr("Zoom"), selection: $zoom, options: [1, 2], label: { L10n.tr("\($0 * 100)%") }).labelsHidden().fixedSize()
            // \ shows the photo as shot, as in other RAW editors.
            Button(L10n.tr("Before")) { showBefore.toggle() }.keyboardShortcut("\\", modifiers: []).frame(width: 0, height: 0).opacity(0)
        } content: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    photoBar
                    loupe.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if count > 1 { filmstrip }
                }.padding(16)
                ToolSidePanel { options }
            }
        }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private func close() { model.stop(); catalog.denoise = nil }

    private var summary: String {
        let photos = model.request.assets
        return photos.count == 1 ? photos[0].filename : L10n.tr("\(photos.count) photos")
    }

    // MARK: Photos

    /// The photo shown, its capture settings, and with several photos its position and the arrows (← and → too).
    private var photoBar: some View {
        let count = model.request.assets.count, asset = model.asset
        return HStack(spacing: 10) {
            if count > 1 {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 20) }
                    .keyboardShortcut(.leftArrow, modifiers: []).help(L10n.tr("Previous photo"))
                Button { model.step(1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 20) }
                    .keyboardShortcut(.rightArrow, modifiers: []).help(L10n.tr("Next photo"))
            }
            Text(asset.filename).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(asset.info.capture).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if count > 1 {
                Text(L10n.tr("\(model.index + 1) of \(count)")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .buttonStyle(.secondaryAction).controlSize(.small)
    }

    /// The selected photos; a click shows one.
    private var filmstrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.request.assets.indices, id: \.self) { index in
                        Rectangle().fill(Theme.ink.opacity(0.06))
                            .overlay { if let image = model.thumbnails[index] { Image(decorative: image, scale: 1).resizable().scaledToFill() } }
                            .frame(width: 84, height: 56).clipped()
                            .selectionRing(index == model.index ? Theme.accent : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { model.index = index }
                            .help(model.request.assets[index].filename)
                            .id(index)
                    }
                }.padding(.vertical, 2)
            }
            .frame(height: 62)
            .onChange(of: model.index) { _, index in withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(index, anchor: .center) } }
        }
    }

    // MARK: Loupe

    enum Compare: String, CaseIterable, Identifiable {
        case split, sideBySide
        var id: String { rawValue }
        var title: String { self == .split ? L10n.tr("Split") : L10n.tr("Side by Side") }
    }
    @AppStorage("denoiseCompare") private var compare = Compare.split
    @AppStorage("denoiseZoom") private var zoom = 1
    /// Where the split runs, from the left, in fractions of the loupe.
    @State private var split: CGFloat = 0.5
    /// How far the loupe has been dragged and not yet re-rendered there.
    @State private var pan = CGSize.zero
    @State private var showBefore = false
    @Environment(\.displayScale) private var displayScale

    /// The photo at 100 % or 200 %: split down the middle (drag the divider) or side by side. Drag to look around;
    /// the view moves at once and is denoised where it rests.
    private var loupe: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black.opacity(0.22)
                switch model.stage {
                case .loading:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Developing \(model.asset.filename)…")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary).padding()
                case .ready:
                    if let crop = model.crop {
                        if compare == .split { splitView(crop, size: size) } else { sideBySide(crop, size: size) }
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .pointerStyle(.grabIdle)
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { pan = $0.translation }
                .onEnded { drag in land(drag.translation, paneWidth: compare == .split ? size.width : (size.width - 6) / 2) })
            .onChange(of: model.cropVersion) { pan = .zero }
            .onChange(of: model.index) { pan = .zero }
            .onAppear { resize(size) }
            .onChange(of: size) { _, size in resize(size) }
            .onChange(of: compare) { resize(size) }
            .onChange(of: zoom) { resize(size) }
        }
        .help(L10n.tr("Drag to look around. \\ shows Before."))
    }

    /// The crop each pane needs: one full-size pixel per screen pixel at 100 %, half as many at 200 %, up to about
    /// two and a half megapixels.
    private func resize(_ size: CGSize) {
        let pane = compare == .split ? size : CGSize(width: (size.width - 6) / 2, height: size.height)
        let pixels = CGSize(width: pane.width * displayScale / CGFloat(zoom), height: pane.height * displayScale / CGFloat(zoom))
        let limit = min(1, 1600 / max(1, pixels.width, pixels.height))
        model.cropSize = CGSize(width: (pixels.width * limit).rounded(), height: (pixels.height * limit).rounded())
    }

    /// Moves the crop by a drag of `translation` points over a pane `paneWidth` points wide.
    private func land(_ translation: CGSize, paneWidth: CGFloat) {
        let photo = model.photoSize
        guard photo.width > 0, paneWidth > 0 else { pan = .zero; return }
        let perPoint = model.cropSize.width / paneWidth
        model.center = CGPoint(x: min(1, max(0, model.center.x - translation.width * perPoint / photo.width)),
                               y: min(1, max(0, model.center.y - translation.height * perPoint / photo.height)))
    }

    private func pixels(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFill()
    }
    /// The result at the chosen strength, or as shot while Before is held.
    @ViewBuilder private func after(_ crop: (before: CGImage, after: CGImage)) -> some View {
        if showBefore { pixels(crop.before) } else {
            ZStack { pixels(crop.before); pixels(crop.after).opacity(model.settings.strength / 100) }
        }
    }

    private func splitView(_ crop: (before: CGImage, after: CGImage), size: CGSize) -> some View {
        let x = size.width * split
        return ZStack(alignment: .topLeading) {
            after(crop).frame(width: size.width, height: size.height).offset(pan).clipped()
            pixels(crop.before).frame(width: size.width, height: size.height).offset(pan).clipped()
                .mask(alignment: .leading) { Rectangle().frame(width: x) }
            Rectangle().fill(.white.opacity(0.85)).frame(width: 1.5, height: size.height).offset(x: x - 0.75)
            Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.black))
                .offset(x: x - 9, y: size.height / 2 - 9)
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { split = min(0.98, max(0.02, $0.location.x / size.width)) })
                .pointerStyle(.columnResize)
            badge(L10n.tr("Before")).padding(8)
            badge(showBefore ? L10n.tr("Before") : L10n.tr("After")).padding(8).frame(width: size.width, alignment: .trailing)
            busy.frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        }
    }

    private func sideBySide(_ crop: (before: CGImage, after: CGImage), size: CGSize) -> some View {
        let pane = CGSize(width: (size.width - 6) / 2, height: size.height)
        return HStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                pixels(crop.before).frame(width: pane.width, height: pane.height).offset(pan).clipped()
                badge(L10n.tr("Before")).padding(8)
            }
            ZStack(alignment: .topLeading) {
                after(crop).frame(width: pane.width, height: pane.height).offset(pan).clipped()
                badge(showBefore ? L10n.tr("Before") : L10n.tr("After")).padding(8)
                busy.frame(width: pane.width, height: pane.height, alignment: .bottomTrailing)
            }
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
    @ViewBuilder private var busy: some View {
        if model.rendering { ProgressView().controlSize(.mini).padding(10) }
    }

    /// The photo with the crop's frame on it; a click or drag moves the crop.
    private var overview: some View {
        let image = model.overview
        let aspect = image.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1.5
        return GeometryReader { geometry in
            if let image {
                let size = geometry.size, frame = model.cropFrame
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    Rectangle().strokeBorder(Color.white, lineWidth: 1.5).shadow(radius: 1)
                        .frame(width: max(6, frame.width * size.width), height: max(6, frame.height * size.height))
                        .offset(x: frame.minX * size.width, y: frame.minY * size.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    model.center = CGPoint(x: min(1, max(0, drag.location.x / size.width)), y: min(1, max(0, drag.location.y / size.height)))
                })
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .background(Theme.ink.opacity(0.06))
        .clipped()
        .help(L10n.tr("Click or drag to choose the part shown at full size"))
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            overview
            Rule()
            ExportRow(L10n.tr("Strength")) {
                HStack(spacing: 8) {
                    FormSlider(value: $model.settings.strength, in: 10...100).accessibilityLabel(L10n.tr("Noise reduction strength"))
                    Text(L10n.tr("\(Int(model.settings.strength.rounded()))%")).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Text(L10n.tr("Saves a DNG beside each original."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help(L10n.tr("Developed as shot and cleaned on this Mac; the DNG keeps the photo's EXIF and edits. The preview shows the photo at its Exposure only."))
            if !modelAvailable {
                ModelPrompt(model: .denoise)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
