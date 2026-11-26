import SwiftUI
import AppKit
import CevicheCore

/// What the Match Series dialog shows and changes: each photo's values now, what it was matched on and the values that
/// bring it to the reference.
@MainActor
final class MatchSeriesModel: ObservableObject {
    enum Stage: Equatable { case reading, ready, failed(String) }
    typealias Photo = SeriesMatchPhoto

    let request: MatchSeriesRequest
    @Published private(set) var stage = Stage.reading
    /// The photos in capture order and the one they are matched to.
    @Published private(set) var series: SeriesMatchSeries
    var photos: [Photo] { series.photos }
    var reference: Int { series.reference }
    /// Each photo's catalog thumbnail, by asset ID.
    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published var selected: Int { didSet { if selected != oldValue { renderSelected() } } }
    @Published var matchExposure: Bool { didSet { preferences.set(matchExposure, forKey: "matchSeriesExposure"); renderSelected() } }
    @Published var matchWhiteBalance: Bool { didSet { preferences.set(matchWhiteBalance, forKey: "matchSeriesWhiteBalance"); renderSelected() } }
    /// Matches on skin wherever the reference and the photo both show a face.
    @Published var skin = false { didSet { if skin != oldValue { rematch() } } }
    @Published private(set) var referenceHasFace = false
    @Published private(set) var referenceImage: CGImage?
    @Published private(set) var before: CGImage?
    @Published private(set) var after: CGImage?
    private var renderers: [String: RawRenderer] = [:]
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let preferences = UserDefaults.standard

    init(request: MatchSeriesRequest) {
        self.request = request
        let first = request.assets.firstIndex { $0.id == request.referenceID } ?? 0
        series = SeriesMatchSeries(request.assets, reference: first)
        selected = request.assets.count > 1 ? (first == 0 ? 1 : 0) : 0
        matchExposure = preferences.object(forKey: "matchSeriesExposure") as? Bool ?? true
        matchWhiteBalance = preferences.object(forKey: "matchSeriesWhiteBalance") as? Bool ?? true
    }

    /// The values to write, by photo: matched, included, and different from what the photo has.
    var changes: [String: SeriesMatchValues] { series.changes(exposure: matchExposure, whiteBalance: matchWhiteBalance) }
    var matching: Bool { stage == .ready && series.matching }
    var canApply: Bool { stage == .ready && !matching && !changes.isEmpty && (matchExposure || matchWhiteBalance) }

    func start(catalog: CatalogModel) {
        guard task == nil, let store = catalog.store else { return }
        task = Task {
            for index in photos.indices {
                if Task.isCancelled { return }
                let asset = photos[index].asset
                guard let url = try? await catalog.resolveOriginal(asset) else { series.photos[index].outcome = .failed(L10n.tr("The original isn’t available.")); continue }
                if url.startAccessingSecurityScopedResource() { access.append(url) }
                series.photos[index].url = url
                if let data = try? await catalog.previews?.data(assetID: asset.id) {
                    thumbnails[asset.id] = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                do {
                    let (renderer, defaults) = try await Task.detached(priority: .userInitiated) { try RawRenderer.open(url) }.value
                    renderers[asset.id] = renderer
                    series.photos[index].defaults = defaults
                    series.photos[index].saved = try await store.savedAdjustments(of: store.asset(asset.id))
                } catch { series.photos[index].outcome = .failed(error.localizedDescription) }
            }
            guard photos[reference].readable else {
                stage = .failed(L10n.tr("The reference photo’s original isn’t available.")); return
            }
            stage = .ready
            await match()
        }
    }

    /// Matches every photo that is waiting, one after the other, showing each as it is done.
    private func match() async {
        guard let url = photos[reference].url, let values = photos[reference].current else { return }
        renderSelected()
        let matcher: SeriesMatcher
        do { matcher = try await Task.detached(priority: .userInitiated) { try autoreleasepool { try SeriesMatcher(reference: url, values: values) } }.value }
        catch { stage = .failed(error.localizedDescription); return }
        if Task.isCancelled { return }
        referenceHasFace = matcher.referenceHasFace
        while let index = series.next, let url = photos[index].url, let current = photos[index].current {
            if Task.isCancelled { return }
            series.photos[index].outcome = .matching
            let prefer = series.preference(index, skin: skin)
            let outcome = await Task.detached(priority: .userInitiated) { autoreleasepool { Result { try matcher.match(url, current: current, prefer: prefer) } } }.value
            if Task.isCancelled { return }
            switch outcome {
            case .success(let result): series.photos[index].outcome = .matched(result)
            case .failure(let error): series.photos[index].outcome = .failed(error.localizedDescription)
            }
            if index == selected { renderSelected() }
        }
    }

    /// Matches again from the start: after another reference, or another way to match.
    private func rematch(only index: Int? = nil) {
        guard stage == .ready else { return }
        task?.cancel()
        series.rematch(only: index)
        task = Task { await match() }
    }

    func makeReference(_ index: Int) {
        guard series.makeReference(index) else { return }
        referenceImage = nil
        if selected == index { selected = photos.indices.first { $0 != index } ?? index }
        rematch()
    }
    func setPreference(_ prefer: SeriesMatchPreference, for index: Int) {
        series.photos[index].prefer = prefer; series.photos[index].included = true
        rematch(only: index)
    }
    func toggleIncluded(_ index: Int) { series.photos[index].included.toggle(); if index == selected { renderSelected() } }

    /// The values the photo would get, with the options applied to its own edits.
    func adjusted(_ index: Int) -> Adjustments? { series.adjusted(index, exposure: matchExposure, whiteBalance: matchWhiteBalance) }

    /// Develops the reference and the selected photo, before and after, with each one's own edits.
    private func renderSelected() {
        guard stage == .ready else { return }
        renderTask?.cancel()
        let index = selected, referenceIndex = reference
        let needsReference = referenceImage == nil
        renderTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            @MainActor func develop(_ k: Int, _ settings: Adjustments?) async -> CGImage? {
                guard let settings, let renderer = renderers[photos[k].id] else { return nil }
                return try? await renderer.displayImage(settings, maxDimension: 1400, sdr: true)
            }
            if needsReference {
                let image = await develop(referenceIndex, photos[referenceIndex].edits)
                guard !Task.isCancelled else { return }
                referenceImage = image
            }
            let original = await develop(index, photos[index].edits)
            guard !Task.isCancelled else { return }
            before = original
            let matched = await develop(index, adjusted(index))
            guard !Task.isCancelled else { return }
            after = matched
        }
    }

    func apply(catalog: CatalogModel, editor: EditorModel) {
        guard canApply else { return }
        catalog.applyMatchSeries(photos.map(\.asset), values: changes, exposure: matchExposure, whiteBalance: matchWhiteBalance, editor: editor)
        close(catalog: catalog)
    }
    func close(catalog: CatalogModel) {
        stop()
        catalog.matchSeries = nil
    }
    func stop() {
        task?.cancel(); renderTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }
}

/// Match Series fills the window: the reference beside the selected photo, the series in a strip below with what each
/// was matched on and the change it gets.
struct MatchSeriesDialog: View {
    @ObservedObject var catalog: CatalogModel
    @ObservedObject var editor: EditorModel
    @StateObject private var model: MatchSeriesModel
    @State private var showingBefore = false
    init(catalog: CatalogModel, editor: EditorModel, request: MatchSeriesRequest) {
        self.catalog = catalog; self.editor = editor; _model = StateObject(wrappedValue: MatchSeriesModel(request: request))
    }

    var body: some View {
        ToolWorkspace(title: L10n.tr("Match Series"), status: status, statusIsWarning: statusIsWarning, primary: L10n.tr("Apply"),
                      primaryDisabled: !model.canApply, cancel: { model.close(catalog: catalog) }, action: { model.apply(catalog: catalog, editor: editor) }) {
            Toggle(L10n.tr("Exposure"), isOn: $model.matchExposure)
            Toggle(L10n.tr("White Balance"), isOn: $model.matchWhiteBalance)
            Rule(.vertical).frame(height: 16)
            Toggle(L10n.tr("Skin"), isOn: $model.skin).disabled(!model.referenceHasFace)
                .help(model.referenceHasFace ? L10n.tr("Matches skin where a photo shows a face, instead of the scene. Evens out faces turned to or from the light.")
                                             : L10n.tr("The reference shows no face"))
        } content: {
            VStack(spacing: 0) {
                comparison
                Rule()
                filmstrip
            }
        }
        .toggleStyle(.formCheckbox)
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        if model.stage == .reading { return L10n.tr("Reading photos…") }
        let others = model.photos.count - 1
        if model.matching {
            let done = model.photos.filter { $0.result != nil }.count
            return L10n.tr("Matching \(done + 1) of \(others)")
        }
        let unmatched = model.photos.enumerated().filter { $0.offset != model.reference && ($0.element.result?.method == .unmatched || $0.element.result == nil) }.count
        if unmatched > 0 { return unmatched == 1 ? L10n.tr("1 photo couldn’t be matched") : L10n.tr("\(unmatched) photos couldn’t be matched") }
        return model.changes.count == 1 ? L10n.tr("1 photo changes") : L10n.tr("\(model.changes.count) photos change")
    }
    private var statusIsWarning: Bool {
        if case .failed = model.stage { return true }
        guard model.stage == .ready, !model.matching else { return false }
        return model.photos.enumerated().contains { $0.offset != model.reference && ($0.element.result?.method == .unmatched || $0.element.result == nil) }
    }

    // MARK: Comparison

    private var comparison: some View {
        HStack(spacing: 1) {
            pane(model.referenceImage, title: model.photos[model.reference].asset.filename, caption: L10n.tr("Reference"))
            pane(showingBefore ? model.before : model.after ?? model.before, title: model.photos[model.selected].asset.filename,
                 caption: showingBefore ? L10n.tr("Before") : detail(model.selected))
                .overlay(alignment: .bottomTrailing) {
                    Text(L10n.tr("Before")).font(.callout).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(showingBefore ? 0.85 : 0.6), in: Capsule()).padding(12)
                        .onLongPressGesture(minimumDuration: 60, pressing: { showingBefore = $0 }, perform: {})
                        .help(L10n.tr("Hold to see the photo as it is now"))
                }
        }
        .background(Theme.imageSurround)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if model.stage == .reading { ToolProgressCard(message: L10n.tr("Reading photos…")) } }
    }

    private func pane(_ image: CGImage?, title: String, caption: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                ZoomCanvas(image: image)
                if image == nil, model.stage == .ready { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.imageSurround)
    }

    /// What the photo was matched on and the change it gets.
    private func detail(_ index: Int) -> String {
        let photo = model.photos[index]
        switch photo.outcome {
        case .waiting, .matching: return L10n.tr("Matching…")
        case .failed(let message): return message
        case .matched(let result):
            guard result.method != .unmatched, photo.included, let current = photo.current else { return photo.included ? result.method.title : L10n.tr("Unchanged") }
            var parts = [result.method.title]
            if model.matchExposure { parts.append(L10n.tr("\(String(format: "%+.2f", locale: Locale.current, result.values.exposure - current.exposure)) EV")) }
            if model.matchWhiteBalance { parts.append(L10n.tr("\(Int(result.values.temperature)) K")) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in cell(index, photo) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(height: 158).background(Theme.statusBar)
    }

    private func cell(_ index: Int, _ photo: MatchSeriesModel.Photo) -> some View {
        let isReference = index == model.reference, isSelected = index == model.selected
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumbnail = model.thumbnails[photo.id] { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() } else { Color.black }
                }
                .frame(width: 132, height: 88).clipped()
                .selectionRing(isReference ? Theme.accent : isSelected ? Theme.ink.opacity(0.8) : nil)
                .opacity(isReference || photo.included ? 1 : 0.4)
                if isReference {
                    Text(L10n.tr("Reference")).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).foregroundStyle(Theme.onAccent).padding(4)
                }
            }
            Text(photo.asset.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(isReference ? " " : detail(index)).font(.system(size: 10)).monospacedDigit().lineLimit(1)
                .foregroundStyle(photo.result?.method == .unmatched ? Theme.warning : .secondary.opacity(0.8))
        }
        .frame(width: 132, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !isReference { model.selected = index } }
        .contextMenu {
            Button(L10n.tr("Use as Reference")) { model.makeReference(index) }.disabled(isReference || photo.current == nil)
            if !isReference {
                Divider()
                Button(L10n.tr("Match Automatically")) { model.setPreference(.automatic, for: index) }
                Button(L10n.tr("Match by EXIF")) { model.setPreference(.exif, for: index) }
                Button(L10n.tr("Match Skin")) { model.setPreference(.skin, for: index) }.disabled(!model.referenceHasFace || photo.result?.hasFace == false)
                Divider()
                Button(photo.included ? L10n.tr("Leave Unchanged") : L10n.tr("Match This Photo")) { model.toggleIncluded(index) }
            }
        }
        .help(help(index, photo))
    }

    private func help(_ index: Int, _ photo: MatchSeriesModel.Photo) -> String {
        guard index != model.reference, let result = photo.result else { return "" }
        switch result.method {
        case .overlap:
            let share = Int(((result.agreement ?? 0) * 100).rounded())
            return L10n.tr("Matched on the scene it shares with the reference (\(share)% of it agrees)")
        case .exif: return L10n.tr("No shared scene: the reference’s white balance, and the exposure difference the camera recorded")
        case .skin: return L10n.tr("Matched on the skin of the largest face")
        case .unmatched: return L10n.tr("No shared scene, and taken in other light: left as it is")
        }
    }
}
