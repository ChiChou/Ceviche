import SwiftUI
import AppKit
import CevicheCore

struct BestFacesRequest: Identifiable {
    let id = UUID()
    let assets: [CatalogAsset]
}

extension CatalogModel {
    /// A burst of one group: two to twelve photos, all RAW or all processed.
    func canMergeBestFaces(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && (2...12).contains(targets.count) && targets.allSatisfy { $0.inLibrary && !$0.isLatent }
            && (targets.allSatisfy(Self.isRAW) || !targets.contains(where: Self.isRAW))
    }
    func requestBestFaces(_ targets: [CatalogAsset]) {
        guard canMergeBestFaces(targets) else { return }
        bestFaces = BestFacesRequest(assets: targets)
    }
}

/// Reads the burst once, then shows the base frame with the faces chosen from the others.
@MainActor
final class BestFacesModel: ObservableObject {
    enum Stage: Equatable { case preparing(String, Double?), ready, failed(String) }

    let request: BestFacesRequest
    @Published private(set) var stage = Stage.preparing(L10n.tr("Reading photos…"), nil)
    @Published private(set) var merger: BestFacesMerger?
    /// The frame the others' faces go into.
    @Published private(set) var base = 0
    /// Per person, the frame their face comes from.
    @Published private(set) var choice: [Int] = []
    @Published private(set) var swaps: [[BestFacesMerger.Swap?]] = []
    /// The faces the tool suggests for this base.
    @Published private(set) var suggested: [Int] = []
    @Published private(set) var preview: CGImage?
    /// The result at full size, made once the choice has settled, for zooming in on the seams.
    @Published private(set) var full: CGImage?
    /// The filmstrip's pictures, by frame.
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    /// Face crops by person and frame, cut once.
    @Published private(set) var faces: [String: CGImage] = [:]
    private var urls: [URL] = []
    private var access: [URL] = []
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(request: BestFacesRequest) { self.request = request }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        task = Task {
            do {
                for asset in request.assets {
                    let url = try await catalog.resolveOriginal(asset)
                    if url.startAccessingSecurityScopedResource() { access.append(url) }
                    urls.append(url)
                }
                let urls = self.urls
                let progress: @Sendable (Double, String) -> Void = { fraction, message in
                    Task { @MainActor in
                        guard case .preparing = self.stage else { return }
                        self.stage = .preparing(message, fraction)
                    }
                }
                let work = Task.detached(priority: .userInitiated) { try BestFacesMerger(urls: urls, progress: progress) }
                let merger = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                merger.retouch = await catalog.retouching(of: request.assets, at: urls)
                self.merger = merger
                await setBase(merger.suggestedBase)
                stage = .ready
                for f in merger.names.indices { thumbnails[f] = await Task.detached(priority: .utility) { merger.thumbnail(frame: f, pixels: 264) }.value }
                await cutFaces(merger)
            } catch is CancellationError {
            } catch { abort(catalog: catalog, error) }
        }
    }

    /// A new base: its swaps checked, each person on the preset again.
    func setBase(_ frame: Int) async {
        guard let merger else { return }
        base = frame
        let (swaps, preset) = await Task.detached(priority: .userInitiated) { (merger.swaps(base: frame), merger.preset(base: frame)) }.value
        guard base == frame else { return }
        self.swaps = swaps; choice = preset; suggested = preset
        refreshPreview()
    }
    func choose(person: Int, frame: Int) {
        guard choice.indices.contains(person), choice[person] != frame else { return }
        choice[person] = frame
        refreshPreview()
    }
    func resetChoices() async { await setBase(base) }

    private func refreshPreview() {
        guard let merger else { return }
        let (base, choice) = (self.base, self.choice)
        previewTask?.cancel()
        full = nil
        previewTask = Task {
            let image = await Task.detached(priority: .userInitiated) { merger.preview(base: base, choice: choice, longEdge: 2400) }.value
            guard !Task.isCancelled else { return }
            preview = image
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let whole = await Task.detached(priority: .utility) { merger.preview(base: base, choice: choice, longEdge: .infinity) }.value
            if !Task.isCancelled { full = whole }
        }
    }

    private func cutFaces(_ merger: BestFacesMerger) async {
        for p in merger.persons.indices { for f in merger.names.indices where merger.persons[p].faces[f] != nil {
            if Task.isCancelled { return }
            let image = await Task.detached(priority: .utility) { merger.face(person: p, frame: f, pixels: 160) }.value
            if let image { faces["\(p)/\(f)"] = image }
        } }
    }

    /// Whether a face was picked other than the suggested one.
    var changed: Bool { choice != suggested }
    var swapped: Int { choice.enumerated().filter { $0.element != base }.count }

    /// Takes the base photo's edits, like the other merges: a DNG for RAW photos, processed ones kept as `format` asks.
    func merge(catalog: CatalogModel, format: ProcessedFormat = .original) {
        guard stage == .ready, let merger else { return }
        let (base, choice) = (self.base, self.choice)
        let first = urls.first { $0.lastPathComponent == merger.names[base] } ?? urls[0]
        let access = self.access
        self.access = []
        let count = choice.enumerated().filter { $0.element != base }.count
        let edits = request.assets.first { $0.filename == merger.names[base] }
        catalog.runMergeJob(beside: first, suffix: "BestFaces", title: L10n.tr("Merging Best Faces"), editsFrom: edits, placed: EditTransferItem.framedRetouched,
                            access: access, format: format, merge: { url, progress in try merger.write(base: base, choice: choice, to: url, progress: progress) },
                            done: count == 0 ? L10n.tr("Best faces merged") : count == 1 ? L10n.tr("Best faces merged, 1 face swapped") : L10n.tr("Best faces merged, \(count) faces swapped"),
                            detail: "", stopped: L10n.tr("Best faces merge stopped"), failed: { L10n.tr("The photos couldn’t be merged. \($0)") })
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
        catalog.bestFaces = nil
    }
    func stop() {
        task?.cancel(); previewTask?.cancel()
        access.forEach { $0.stopAccessingSecurityScopedResource() }; access = []
    }
}

/// Merge Best Faces fills the window like the other merges: the result to zoom into, and beside it everyone in the
/// group with their face in each frame, to take each person's face from whichever frame is best.
struct BestFacesView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: BestFacesModel
    @State private var hovered: Int?
    /// Asking before a merge that would only copy the base photo.
    @State private var confirmingCopy = false
    @State private var copyFormat = ProcessedFormat.original
    init(catalog: CatalogModel, request: BestFacesRequest) {
        self.catalog = catalog; _model = StateObject(wrappedValue: BestFacesModel(request: request))
    }

    /// Merges, after asking when no face is swapped.
    private func merge(_ format: ProcessedFormat) {
        if model.swapped == 0 { copyFormat = format; confirmingCopy = true } else { model.merge(catalog: catalog, format: format) }
    }

    var body: some View {
        ToolWorkspace(title: L10n.tr("Best Faces"), status: status, statusIsWarning: statusIsWarning, primary: L10n.tr("Merge"),
                      primaryDisabled: model.stage != .ready,
                      primaryOptions: CatalogModel.processed(model.request.assets) ? [(L10n.tr("Merge to TIFF"), { merge(.tiff) })] : [],
                      cancel: { model.close(catalog: catalog) }, action: { merge(.original) }) {
            EmptyView()
        } content: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvas
                    if let merger = model.merger {
                        Rule()
                        filmstrip(merger)
                    }
                }
                if let merger = model.merger {
                    Rule(.vertical)
                    peoplePanel(merger)
                }
            }
        } actions: { EmptyView() }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
        .alert(L10n.tr("Merge Without Swapping Faces?"), isPresented: $confirmingCopy) {
            Button(L10n.tr("Merge")) { model.merge(catalog: catalog, format: copyFormat) }
            // No is the default: the result would only be a copy of one photo.
            Button(L10n.tr("Don’t Merge"), role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text(L10n.tr("Every face comes from \(model.merger?.names[model.base] ?? ""), so the result is a copy of that photo."))
        }
    }

    private var status: String {
        if case .failed(let message) = model.stage { return message }
        guard let merger = model.merger else { return L10n.tr("\(model.request.assets.count) photos") }
        if let best = merger.bestShot, model.base == best, model.swapped == 0 { return L10n.tr("Everyone looks good in \(merger.names[best])") }
        return model.swapped == 1 ? L10n.tr("1 face from another photo") : L10n.tr("\(model.swapped) faces from other photos")
    }
    private var statusIsWarning: Bool { if case .failed = model.stage { return true }; return false }

    private var canvas: some View {
        ZStack {
            ZoomCanvas(image: model.full ?? model.preview, fullSize: model.merger?.size, clickZooms: true) { size in
                if let merger = model.merger { outlines(merger, size: size) }
            }
            switch model.stage {
            case .preparing(let message, let fraction): ToolProgressCard(message: message, fraction: fraction)
            case .failed(let message):
                ContentUnavailableView(L10n.tr("Can’t Merge These Photos"), systemImage: "person.3", description: Text(message))
            case .ready: EmptyView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The photos in the order they were taken: click one to put the others' faces into it.
    private func filmstrip(_ merger: BestFacesMerger) -> some View {
        ToolFilmstrip {
            ForEach(merger.names.indices, id: \.self) { f in
                let isBase = model.base == f
                VStack(alignment: .leading, spacing: 4) {
                    ToolFrameThumbnail(image: model.thumbnails[f], outline: isBase ? Theme.accent : nil, badge: isBase ? L10n.tr("Base") : nil)
                        .onTapGesture { Task { await model.setBase(f) } }
                    HStack(spacing: 4) {
                        if merger.bestShot == f { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                        Text(L10n.tr("\(merger.goodCount(f)) of \(merger.persons.count)")).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        Text(merger.names[f]).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(width: 132, alignment: .leading)
                }
                .help(merger.bestShot == f ? L10n.tr("Everyone looks good in this photo") : L10n.tr("Put the other faces into this photo"))
            }
        }
    }

    /// Each person numbered on the result; a face taken from another photo is outlined.
    private func outlines(_ merger: BestFacesMerger, size: CGSize) -> some View {
        let full = merger.size
        return ZStack(alignment: .topLeading) {
            ForEach(merger.persons.indices, id: \.self) { p in
                if let face = merger.persons[p].faces[model.base] {
                    let r = CGRect(x: face.box.minX / full.width * size.width, y: face.box.minY / full.height * size.height,
                                   width: face.box.width / full.width * size.width, height: face.box.height / full.height * size.height)
                    let swapped = model.choice.indices.contains(p) && model.choice[p] != model.base
                    if swapped || hovered == p {
                        Rectangle().strokeBorder(hovered == p ? Theme.accent : .white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: swapped ? [] : [3, 3]))
                            .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    }
                    Text((p + 1).formatted()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).frame(minWidth: 16).padding(.vertical, 1)
                        .background(hovered == p ? Theme.accent : .black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                        .position(x: r.minX + 9, y: max(8, r.minY - 9))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// A row per person: their face in each photo, the one used marked; a face whose swap would show is dimmed and says why.
    private func peoplePanel(_ merger: BestFacesMerger) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.tr("People")).font(.headline)
                Spacer()
                // Only once a face other than the suggested one is picked.
                if model.changed {
                    Button(L10n.tr("Reset")) { Task { await model.resetChoices() } }.buttonStyle(.secondaryAction).controlSize(.small)
                        .help(L10n.tr("Go back to the suggested faces"))
                } else {
                    Text(L10n.tr("\(merger.persons.count) people")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(height: 22).padding(.horizontal, 12).padding(.vertical, 8)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(merger.persons.indices, id: \.self) { p in row(merger, p) }
                }.padding(10)
            }
        }
        .frame(width: CGFloat(min(6, merger.names.count)) * 62 + 52).frame(maxHeight: .infinity).background(Theme.statusBar)
    }

    private func row(_ merger: BestFacesMerger, _ p: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text((p + 1).formatted()).font(.system(size: 11, weight: .semibold)).monospacedDigit().frame(width: 18, alignment: .trailing).padding(.top, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(merger.names.indices, id: \.self) { f in faceCell(merger, person: p, frame: f) }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? p : (hovered == p ? nil : hovered) }
    }

    @ViewBuilder private func faceCell(_ merger: BestFacesMerger, person p: Int, frame f: Int) -> some View {
        let person = merger.persons[p]
        if person.faces[f] != nil {
            let chosen = model.choice.indices.contains(p) && model.choice[p] == f
            let swap = model.swaps.indices.contains(p) ? model.swaps[p][f] : nil
            let refused = f != model.base && swap?.accepted != true
            Button { model.choose(person: p, frame: f) } label: {
                ZStack {
                    Theme.imageSurround
                    if let image = model.faces["\(p)/\(f)"] { Image(decorative: image, scale: 2).resizable().interpolation(.high).scaledToFill() }
                }
                .frame(width: 58, height: 58).clipped()
                .opacity(refused && !chosen ? 0.45 : 1)
                .overlay { Rectangle().strokeBorder(chosen ? Theme.accent : f == model.base ? Theme.ink.opacity(0.35) : .clear, lineWidth: chosen ? 2.5 : 1) }
                .overlay(alignment: .bottomLeading) {
                    if !person.problems[f].isEmpty {
                        Image(systemName: person.problems[f].contains(.eyesClosed) ? "eye.slash" : "exclamationmark")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 14, height: 13).background(Theme.reject, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).padding(2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if refused && swap != nil {
                        Image(systemName: "nosign").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 14, height: 13).background(Theme.warning, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).padding(2)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(help(merger, person: p, frame: f, swap: swap))
        } else {
            Rectangle().strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 58, height: 58)
                .help(L10n.tr("Not found in \(merger.names[f])"))
        }
    }

    private func help(_ merger: BestFacesMerger, person p: Int, frame f: Int, swap: BestFacesMerger.Swap?) -> String {
        var lines = [merger.names[f] + (f == model.base ? " " + L10n.tr("(base)") : "")]
        lines += merger.persons[p].problems[f].map(\.title)
        if let swap, !swap.accepted { lines.append(L10n.tr("Would show: \(swap.refusals.map(\.title).joined(separator: ", "))")) }
        return lines.joined(separator: "\n")
    }
}

extension BestFacesMerger.Problem {
    var title: String {
        switch self {
        case .eyesClosed: L10n.tr("Eyes look closed")
        case .turned: L10n.tr("Turned away")
        case .lookingUpOrDown: L10n.tr("Looking up or down")
        case .soft: L10n.tr("Softer than in other photos")
        }
    }
}

extension BestFacesMerger.Refusal {
    var title: String {
        switch self {
        case .notInBase: L10n.tr("not found in the base photo")
        case .outOfFrame: L10n.tr("at the edge of the photo")
        case .sizeChanged: L10n.tr("moved closer or further")
        case .turned: L10n.tr("head turned")
        case .tilted: L10n.tr("head tilted")
        case .faceInside: L10n.tr("another face too close")
        case .headMoved: L10n.tr("head moved")
        case .lightDiffers: L10n.tr("light differs")
        case .surroundingsDiffer: L10n.tr("hair, hands or people around moved")
        }
    }
}
