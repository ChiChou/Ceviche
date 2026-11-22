import SwiftUI
import Combine
import CevicheCore

/// Check Faces: the photos in scope with people, each as a card of its faces, so the person judges eyes and focus face by
/// face and flags the photo. The culling measure (`CullingScanner`) says which photos have faces; each of those is then
/// looked at again, harder (`FaceFinder`: a larger reading, tiles, a face looked for on every person), which finds the
/// small faces of a group the measure misses and measures their eyes. The cards show the measure's faces until then.
/// Faces are cut from the original only for the cards on screen. Flags set here change nothing until Apply.
@MainActor
final class FaceCheckModel: ObservableObject {
    enum Stage: Equatable { case measuring(Int, Int), ready, failed(String) }

    let request: CullingAssistantRequest
    let byID: [String: CatalogAsset]
    let sensitivity: CullingSensitivity
    @Published private(set) var stage: Stage
    @Published private(set) var reports: [String: PhotoQualityReport] = [:]
    /// The faces the closer look found, by photo.
    @Published private(set) var found: [String: [PhotoQualityReport.Face]] = [:]
    /// Photos the closer look couldn't read; their cards keep the measure's faces.
    private var unread: Set<String> = []
    private var looking: Task<Void, Never>?
    private var root: URL?
    /// Photos that could not be measured, and why.
    @Published private(set) var unmeasured: [String: String] = [:]
    /// Only photos with a face whose eyes look closed.
    @Published var closedOnly = false
    /// Flags set here, applied together.
    @Published private(set) var flags: [String: ReviewState] = [:]
    /// The photo the arrows move, the keys flag and the preview panel shows.
    @Published var focus: String?
    /// A request to the panel: zoom to a face (its number from 0) at actual pixels, or back to fit. A new id each time,
    /// so asking for the same face twice still zooms.
    struct FaceZoom: Equatable { var face: Int?; var id = UUID() }
    @Published var faceZoom: FaceZoom?
    /// Grid columns, for the up and down arrows.
    var columns = 4
    /// The people of the shown photo's series side by side, frame under frame, or cards of every photo.
    enum Layout: Hashable { case people, photos }
    @Published var layout: Layout = .people
    private weak var scanner: CullingScanner?
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(request: CullingAssistantRequest, sensitivity: CullingSensitivity) {
        self.request = request
        self.sensitivity = sensitivity
        byID = Dictionary(request.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stage = .measuring(0, request.assets.count)
    }

    /// Reads what was already measured and has the scanner measure the rest first, so cards appear as photos land.
    func start(catalog: CatalogModel) {
        guard task == nil, let store = catalog.store else { return }
        let scanner = catalog.cullingScanner, root = catalog.root, assets = request.assets
        self.scanner = scanner; self.root = root
        subscription = scanner.measured.sink { [weak self] measured in self?.receive(measured) }
        task = Task {
            do {
                reports.merge(try await store.cullingReports(assets.map(\.id)).mapValues(\.report)) { landed, _ in landed }
                guard !Task.isCancelled else { return }
                let pending = assets.filter { reports[$0.id] == nil && unmeasured[$0.id] == nil }
                updateStage()
                if !pending.isEmpty { scanner.urgent = true; scanner.enqueue(pending, store: store, root: root, first: true) }
            } catch { stage = .failed(error.localizedDescription) }
        }
    }
    private func receive(_ measured: CullingScanner.Measured) {
        guard byID[measured.assetID] != nil else { return }
        if let report = measured.report { reports[measured.assetID] = report.report; unmeasured[measured.assetID] = nil }
        else if let failure = measured.failure { unmeasured[measured.assetID] = failure }
        updateStage()
    }
    private func updateStage() {
        let done = request.assets.filter { reports[$0.id] != nil || unmeasured[$0.id] != nil }.count
        stage = done < request.assets.count ? .measuring(done, request.assets.count) : .ready
        if stage == .ready { scanner?.urgent = false }
        if focus == nil || !shown.contains(where: { $0.id == focus }) { focus = shown.first?.id }
        lookCloser()
    }
    /// Stops listening; the scanner carries on with what is left, in the background.
    func stop() {
        task?.cancel(); subscription = nil
        looking?.cancel(); looking = nil
        scanner?.urgent = false
    }

    // MARK: Faces
    /// The photo's faces, left to right: the closer look's once it has run, else the measure's, whose eyes count only
    /// where the face was large enough in the small image it was measured on.
    func faces(_ id: String) -> [PhotoQualityReport.Face] {
        if let found = found[id] { return found }
        return (reports[id]?.faces ?? []).map { face in
            guard face.bounds.width < PhotoQualityReport.Face.judgedWidth else { return face }
            var face = face; face.leftEye = nil; face.rightEye = nil; return face
        }.sorted { $0.bounds.midX < $1.bounds.midX }
    }
    func eyesClosed(_ face: PhotoQualityReport.Face) -> Bool { face.eyesClosed(sensitivity) }
    /// Photos the measure found a face in, at any size; the closer look keeps the ones where it finds one.
    var withFaces: [CatalogAsset] { request.assets.filter { !(reports[$0.id]?.faces ?? []).isEmpty && found[$0.id]?.isEmpty != true } }
    /// Photos still to be looked at closely, and how many have been.
    var lookedAt: Int { request.assets.filter { found[$0.id] != nil || unread.contains($0.id) }.count }
    var toLookAt: Int { request.assets.filter { !(reports[$0.id]?.faces ?? []).isEmpty }.count }

    /// Looks closely at each photo with a face, one at a time, the one shown first, then in order.
    private func lookCloser() {
        guard looking == nil else { return }
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pending = self.withFaces.filter { self.found[$0.id] == nil && !self.unread.contains($0.id) }
                guard let next = pending.first(where: { $0.id == self.focus }) ?? pending.first else { break }
                let key = FaceFinderCache.key(next)
                if let cached = FaceFinderCache.faces.object(forKey: key) { self.found[next.id] = cached.faces; continue }
                guard case .available(let url) = next.availability(catalog: self.root) else { self.unread.insert(next.id); continue }
                let faces = await Task.detached(priority: .userInitiated) { () -> [PhotoQualityReport.Face]? in
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return autoreleasepool { try? FaceFinder.faces(at: url) }
                }.value
                guard !Task.isCancelled else { return }
                if let faces {
                    FaceFinderCache.faces.setObject(.init(faces), forKey: key)
                    self.found[next.id] = faces
                } else {
                    self.unread.insert(next.id)
                }
            }
            self?.looking = nil
        }
    }
    var closedCount: Int { withFaces.filter { faces($0.id).contains(where: eyesClosed) }.count }
    var shown: [CatalogAsset] { closedOnly ? withFaces.filter { faces($0.id).contains(where: eyesClosed) } : withFaces }
    var focusedAsset: CatalogAsset? { focus.flatMap { byID[$0] } }

    // MARK: Series
    /// Frames this far apart or closer can be one series: a group shot again and again.
    static let seriesGap = 60.0
    /// The photos shot with this one, in capture order: neighbours no more than `seriesGap` apart whose faces mostly
    /// stand where the other's do, so the same group re-arranged a minute later is a series of its own.
    func series(of id: String) -> [CatalogAsset] {
        // Every frame of it, whatever the filter shows.
        let photos = withFaces.enumerated().sorted { a, b in
            let (ta, tb) = (reports[a.element.id]?.captureDate, reports[b.element.id]?.captureDate)
            if let ta, let tb, ta != tb { return ta < tb }
            return a.offset < b.offset
        }.map(\.element)
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return [] }
        func together(_ a: Int, _ b: Int) -> Bool {
            guard let ta = reports[photos[a].id]?.captureDate, let tb = reports[photos[b].id]?.captureDate, abs(tb - ta) <= Self.seriesGap else { return false }
            let (fa, fb) = (faces(photos[a].id), faces(photos[b].id))
            // Most of everyone, not most of the smaller frame: a pair of people shot before a group of five isn't its series.
            return Double(Self.match(fa, fb).count) >= 0.8 * Double(max(fa.count, fb.count))
        }
        var first = index, last = index
        while first > 0, together(first - 1, first) { first -= 1 }
        while last < photos.count - 1, together(last, last + 1) { last += 1 }
        return Array(photos[first...last])
    }

    /// Faces of one frame paired with those of the next, by where they stand once the group's shift between the frames
    /// is taken out; a pair is no further apart than most of a face. Keys index `a`, values `b`.
    static func match(_ a: [PhotoQualityReport.Face], _ b: [PhotoQualityReport.Face]) -> [Int: Int] {
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        func centre(_ f: PhotoQualityReport.Face) -> CGPoint { CGPoint(x: f.bounds.midX, y: f.bounds.midY) }
        // The shift: the median offset of each face in `b` from the nearest in `a`.
        let offsets = b.map { fb in
            let c = centre(fb), near = a.map(centre).min { hypot($0.x - c.x, $0.y - c.y) < hypot($1.x - c.x, $1.y - c.y) }!
            return CGPoint(x: c.x - near.x, y: c.y - near.y)
        }
        let dx = offsets.map(\.x).sorted(), dy = offsets.map(\.y).sorted()
        let shift = CGPoint(x: dx[dx.count / 2], y: dy[dy.count / 2])
        var pairs: [(Int, Int, Double)] = []
        for (i, fa) in a.enumerated() { for (j, fb) in b.enumerated() {
            let d = hypot(centre(fb).x - shift.x - centre(fa).x, centre(fb).y - shift.y - centre(fa).y)
            if d < 0.7 * max(fa.bounds.width, fb.bounds.width) { pairs.append((i, j, d)) }
        } }
        var result: [Int: Int] = [:], used = Set<Int>()
        for (i, j, _) in pairs.sorted(by: { $0.2 < $1.2 }) where result[i] == nil && !used.contains(j) { result[i] = j; used.insert(j) }
        return result
    }

    /// The same people across `frames`: per frame, per person, the index of that person's face, or nil where they
    /// aren't found. Each frame is matched with the one before it; people are ordered left to right as they stand.
    func people(in frames: [CatalogAsset]) -> [[Int?]] {
        var rows: [[Int?]] = [], xs: [[Double]] = []
        var previous: (faces: [PhotoQualityReport.Face], person: [Int]) = ([], [])
        for frame in frames {
            let current = faces(frame.id)
            let pairs = Self.match(previous.faces, current)
            var person = [Int](repeating: -1, count: current.count)
            for (i, j) in pairs { person[j] = previous.person[i] }
            for j in current.indices where person[j] < 0 { person[j] = xs.count; xs.append([]) }
            var row = [Int?](repeating: nil, count: xs.count)
            for (j, p) in person.enumerated() { row[p] = j; xs[p].append(current[j].bounds.midX) }
            rows.append(row)
            previous = (current, person)
        }
        rows = rows.map { $0 + [Int?](repeating: nil, count: max(0, xs.count - $0.count)) }
        let order = xs.indices.sorted { xs[$0].reduce(0, +) / Double(max(1, xs[$0].count)) < xs[$1].reduce(0, +) / Double(max(1, xs[$1].count)) }
        return rows.map { row in order.map { row[$0] } }
    }

    // MARK: Flags
    func flag(_ id: String) -> ReviewState { flags[id] ?? byID[id]?.review ?? .unreviewed }
    func set(_ id: String, _ state: ReviewState) { flags[id] = state == byID[id]?.review ? nil : state }
    func setFocused(_ state: ReviewState) { if let focus { set(focus, state) } }
    var changes: [String: ReviewState] { flags }

    func move(_ step: Int) {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return }
        let index = focus.flatMap { ids.firstIndex(of: $0) }
        focus = ids[index.map { min(max($0 + step, 0), ids.count - 1) } ?? 0]
    }

    func apply(catalog: CatalogModel) {
        stop()
        guard !flags.isEmpty else { catalog.faceCheck = nil; return }
        Task { await catalog.applyCulling(flags, partners: request.partners) }
    }
}

/// What the closer look found, by photo and its file's version, kept for the session.
@MainActor
enum FaceFinderCache {
    final class Box { let faces: [PhotoQualityReport.Face]; init(_ faces: [PhotoQualityReport.Face]) { self.faces = faces } }
    static let faces = NSCache<NSString, Box>()
    static func key(_ asset: CatalogAsset) -> NSString { "\(asset.id)/\(asset.originalUpdatedAt.timeIntervalSince1970)" as NSString }
}

/// Faces cut for the cards, kept while they may be scrolled back to.
@MainActor
enum FaceCropCache {
    final class Box { let images: [CGImage?]; init(_ images: [CGImage?]) { self.images = images } }
    static let tiles: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.totalCostLimit = 192 << 20; return cache }()
    /// Which faces were cut: the measure's and the closer look's differ.
    static func key(_ faces: [PhotoQualityReport.Face]) -> String {
        faces.map { String(format: "%.3f,%.3f", $0.bounds.midX, $0.bounds.midY) }.joined(separator: ";")
    }
    static func cost(_ images: [CGImage?]) -> Int { images.compactMap { $0.map { $0.bytesPerRow * $0.height } }.reduce(0, +) }
    /// Originals read at once: each renders only its face regions.
    static let gate = DecodeGate(3)
}

/// At most `limit` holders at once; the rest wait in order.
actor DecodeGate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { free = limit }
    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// Check Faces takes the whole window, like Find Flawed Photos: the title, the filter and the buttons in the title bar,
/// a card per photo with faces in a grid beside a resizable panel with the chosen photo to zoom into, and the keys and the
/// card size along the bottom. Clicking a card or the arrows choose the photo.
struct FaceCheckView: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: FaceCheckModel
    @FocusState private var keyFocus: Bool
    @AppStorage("faceCheckCardSize") private var cardWidth = 280.0
    @AppStorage("faceCheckPanelWidth") private var panelWidth = 560.0
    private static let spacing: CGFloat = 14

    init(catalog: CatalogModel, request: CullingAssistantRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: FaceCheckModel(request: request, sensitivity: catalog.cullingSensitivity))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            GeometryReader { geometry in
                // The grid keeps at least 320 points beside the panel.
                let range = 320.0...max(320.0, Double(geometry.size.width) - 320)
                HStack(spacing: 0) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let asset = model.focusedAsset {
                        SidebarResizeHandle(width: $panelWidth, range: range, defaultWidth: 560, panelOnRight: true)
                        FacePreviewPanel(asset: asset, faces: model.faces(asset.id), model: model, catalog: catalog)
                            .frame(width: min(max(panelWidth, range.lowerBound), range.upperBound))
                    }
                }
            }
            Rule()
            footer
        }
        .background(Theme.canvas)
        .focusable().focusEffectDisabled().focused($keyFocus)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            // In People, frames are rows: up and down step through the series, as left and right do.
            let rows = model.layout == .people ? 1 : model.columns
            model.move(press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -rows : rows)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU")) { press in
            switch press.characters.lowercased() {
            case "p": model.setFocused(.accepted)
            case "x": model.setFocused(.rejected)
            default: model.setFocused(.unreviewed)
            }
            return .handled
        }
        // 1 to 9 zoom the panel to that face at actual pixels, 0 back to fit.
        .onKeyPress(characters: CharacterSet(charactersIn: "0123456789")) { press in
            guard model.focus != nil, let digit = Int(press.characters) else { return .ignored }
            model.faceZoom = .init(face: digit == 0 ? nil : digit - 1)
            return .handled
        }
        .onAppear { model.start(catalog: catalog); keyFocus = true }
        // The panel always shows a photo: the first one, until another is chosen or the filter hides it.
        .onChange(of: model.shown.map(\.id), initial: true) { _, ids in
            if model.focus.map({ !ids.contains($0) }) ?? true { model.focus = ids.first }
        }
        .onDisappear { model.stop() }
        .onExitCommand(perform: cancel)
    }

    private func cancel() { model.stop(); catalog.faceCheck = nil }

    // MARK: Header
    private var header: some View {
        ToolHeader(title: L10n.tr("Check Faces"), caption: status) {
            HStack(spacing: 10) {
                Picker(L10n.tr("Layout"), selection: $model.layout) {
                    Text(L10n.tr("People", context: "Check Faces layout")).tag(FaceCheckModel.Layout.people)
                    Text(L10n.tr("Photos", context: "Check Faces layout")).tag(FaceCheckModel.Layout.photos)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help(L10n.tr("The people of a series side by side, frame under frame, or each photo as a card"))
                HStack(spacing: 4) {
                FilterChip(title: L10n.tr("All Faces"), count: model.withFaces.count, isOn: !model.closedOnly) { model.closedOnly = false }
                FilterChip(title: L10n.tr("Eyes Closed"), count: model.closedCount, symbol: "eye.slash", isOn: model.closedOnly) { model.closedOnly = true }
                    .help(L10n.tr("Only photos with a face whose eyes look closed"))
                }
                .disabled(model.layout == .people)
            }.fixedSize()
        } actions: {
            if case .measuring(let done, let total) = model.stage, total > 0 {
                CountRing(done: done, total: total).equatable()
            } else if model.lookedAt < model.toLookAt {
                CountRing(done: model.lookedAt, total: model.toLookAt).equatable()
            } else {
                ActivityIndicator(center: catalog.activity)
            }
            summary
            ToolCancelButton(action: cancel)
            ToolPrimaryButton(title: L10n.tr("Apply")) { model.apply(catalog: catalog) }.disabled(model.changes.isEmpty)
                .help(L10n.tr("Set the flags shown here"))
        }
    }
    private var status: String {
        let total = model.request.assets.count.formatted(), found = model.withFaces.count.formatted()
        switch model.stage {
        case .measuring(let done, let total): return L10n.tr("Finding faces in \(done.formatted()) of \(total.formatted()) photos in \(model.request.title)…")
        case .failed(let message): return message
        case .ready:
            let looked = model.lookedAt, all = model.toLookAt
            if looked < all { return L10n.tr("Looking closer at faces in \(looked.formatted()) of \(all.formatted()) photos…") }
            return L10n.tr("\(found) of \(total) photos in \(model.request.title) have faces")
        }
    }
    private var summary: some View {
        let rejected = model.changes.values.filter { $0 == .rejected }.count, picked = model.changes.values.filter { $0 == .accepted }.count
        return HStack(spacing: 10) {
            if picked > 0 { Text(L10n.tr("\(picked.formatted()) to pick")).foregroundStyle(Theme.pick) }
            if rejected > 0 { Text(L10n.tr("\(rejected.formatted()) to reject")).foregroundStyle(Theme.reject) }
        }.font(.callout.weight(.medium)).monospacedDigit()
    }

    // MARK: Grid
    @ViewBuilder private var content: some View {
        if case .failed(let message) = model.stage {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.shown.isEmpty {
            if model.stage == .ready {
                ContentUnavailableView(model.closedOnly ? L10n.tr("No Closed Eyes") : L10n.tr("No Faces Found"),
                                       systemImage: model.closedOnly ? "eye" : "person.crop.circle.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                looking
            }
        } else if model.layout == .people, let focus = model.focus {
            PeopleCompare(model: model, catalog: catalog, frames: model.series(of: focus)) { keyFocus = true }
        } else {
            grid
        }
    }
    /// While the first photos are measured: a face frame scanning, and how far along it is.
    private var looking: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                .overlay { Image(systemName: "face.smiling").font(.system(size: 22, weight: .regular)).foregroundStyle(.secondary).symbolEffect(.pulse, options: .repeating) }
                .symbolEffect(.breathe, options: .repeating)
            Text(L10n.tr("Looking for Faces…")).font(.title3.weight(.semibold))
            if case .measuring(let done, let total) = model.stage, total > 0 {
                CountRing(done: done, total: total, size: 72).equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var grid: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + Self.spacing) / (cardWidth + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                        ForEach(model.shown, id: \.id) { asset in
                            FaceCard(asset: asset, faces: model.faces(asset.id), model: model, previews: catalog.previews, root: catalog.root, partner: model.request.partners[asset.id] != nil)
                                .id(asset.id)
                                // A click shows the photo in the panel.
                                .onTapGesture { model.focus = asset.id; keyFocus = true }
                        }
                    }.padding(16)
                }
                .onChange(of: model.focus) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            }
            .onAppear { model.columns = columns }
            .onChange(of: columns) { _, value in model.columns = value }
        }
    }

    // MARK: Footer
    private var footer: some View {
        ToolOptionsBar(spacing: 10) {
            KeyHint(key: "P", label: L10n.tr("Pick"))
            KeyHint(key: "X", label: L10n.tr("Reject"))
            KeyHint(key: "U", label: L10n.tr("Clear"))
            KeyHint(key: "1–9", label: L10n.tr("Zoom to Face"))
            if !model.unmeasured.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .help(([model.unmeasured.count == 1 ? L10n.tr("1 photo couldn’t be measured") : L10n.tr("\(model.unmeasured.count.formatted()) photos couldn’t be measured")]
                           + model.unmeasured.prefix(8).map { (model.byID[$0.key]?.filename ?? "") + ": " + $0.value }).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            ThumbnailSizeSlider(size: $cardWidth, range: 200...520)
        }
    }
}

/// A key and what it does, along the bottom of a tool.
private struct KeyHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Theme.rule))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A photo's faces filling a 4:3 area, every one of them, left to right as they stand, so a card of a group is read
/// the same way as the photo; its name, flag and photo below. A face whose eyes look closed is marked.
private struct FaceCard: View {
    let asset: CatalogAsset
    let faces: [PhotoQualityReport.Face]
    @ObservedObject var model: FaceCheckModel
    let previews: PreviewStore?
    let root: URL?
    let partner: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var images: [CGImage?] = []

    /// Columns and rows for the faces: as square as the 4:3 card allows.
    private var layout: (columns: Int, rows: Int) {
        let n = max(1, faces.count)
        let columns = max(1, Int(ceil((Double(n) * 4 / 3).squareRoot())))
        return (min(columns, n), Int(ceil(Double(n) / Double(min(columns, n)))))
    }

    var body: some View {
        let flag = model.flag(asset.id), focused = model.focus == asset.id
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                faceGrid(size: geometry.size)
                    .task(id: "\(FaceCropCache.key(faces))/\(pixels(geometry.size))") { await load(pixels(geometry.size)) }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .background(Theme.imageSurround)
            .clipped()
            .opacity(flag == .rejected ? 0.45 : 1)
            .selectionRing(flag == .accepted ? Theme.pick : flag == .rejected ? Theme.reject : nil)
            .overlay(alignment: .topLeading) { if partner { PairBadge().padding(5) } }
            HStack(spacing: 6) {
                CatalogThumbnail(asset: asset, previews: previews).frame(width: 30, height: 22)
                Text(asset.filename).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if faces.count > 1 { Text(L10n.tr("\(faces.count.formatted()) faces")).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit() }
                if flag != .unreviewed { ReviewFlag(state: flag, active: true, size: 11, color: flag == .accepted ? Theme.pick : Theme.reject) }
            }
        }
        .padding(5)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .help(asset.filename)
        .accessibilityElement(children: .ignore).accessibilityLabel(asset.filename)
        .accessibilityValue(faces.count == 1 ? L10n.tr("1 face") : L10n.tr("\(faces.count.formatted()) faces"))
        .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.focus = asset.id }
        .accessibilityAction(named: L10n.tr("Pick")) { model.set(asset.id, .accepted) }
        .accessibilityAction(named: L10n.tr("Reject")) { model.set(asset.id, .rejected) }
    }

    /// Side, in pixels, the faces are cut at: a cell's longer side on this screen, rounded up to steps of 64 so a small
    /// resize of the window doesn't cut them again.
    private func pixels(_ size: CGSize) -> Int {
        let cell = max(size.width / CGFloat(layout.columns), size.height / CGFloat(layout.rows))
        return (Int(cell * displayScale) + 63) / 64 * 64
    }

    private func faceGrid(size: CGSize) -> some View {
        let gap: CGFloat = 2, (columns, rows) = layout
        let cell = CGSize(width: max(0, (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)),
                          height: max(0, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)))
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { column in
                        faceCell(row * columns + column).frame(width: cell.width, height: cell.height).clipped()
                    }
                }
            }
        }
    }

    @ViewBuilder private func faceCell(_ index: Int) -> some View {
        if index < faces.count {
            ZStack {
                if index < images.count, let image = images[index] {
                    Image(decorative: image, scale: displayScale).resizable().interpolation(.high).scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay { if model.eyesClosed(faces[index]) { Rectangle().strokeBorder(Theme.reject, lineWidth: 2) } }
            .overlay(alignment: .bottomLeading) {
                if model.eyesClosed(faces[index]) {
                    Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 18, height: 16).background(Theme.reject, in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
                        .padding(3).help(L10n.tr("Eyes look closed"))
                }
            }
        } else {
            Color.clear
        }
    }

    private func load(_ pixels: Int) async {
        let key = "\(asset.id)/\(FaceCropCache.key(faces))/\(pixels)" as NSString
        if let cached = FaceCropCache.tiles.object(forKey: key) { images = cached.images; return }
        guard case .available(let url) = asset.availability(catalog: root) else { return }
        let bounds = faces.map(\.bounds)
        await FaceCropCache.gate.enter()
        // Scrolled past while waiting: cut when it comes back.
        guard !Task.isCancelled else { await FaceCropCache.gate.leave(); return }
        let cut = await Task.detached(priority: .userInitiated) { () -> [CGImage?] in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            return autoreleasepool { FaceCrops.tiles(at: url, faces: Array(bounds), pixels: pixels) }
        }.value
        await FaceCropCache.gate.leave()
        FaceCropCache.tiles.setObject(.init(cut), forKey: key, cost: FaceCropCache.cost(cut))
        images = cut
    }
}

/// The focused photo beside the grid, to zoom into: pinch, ⌘-scroll or click, drag to move, and a face's number (on the
/// photo, in the bar below or on the keyboard) zooms to that face at actual pixels. The image the faces were measured on
/// shows at once; the original, read whole, replaces it for the detail.
private struct FacePreviewPanel: View {
    let asset: CatalogAsset
    let faces: [PhotoQualityReport.Face]
    @ObservedObject var model: FaceCheckModel
    @ObservedObject var catalog: CatalogModel
    /// Where to zoom, for the photo it was meant for: a new photo's canvas must not take the last one's.
    @State private var target: (asset: String, zoom: ZoomTarget)?
    @State private var canvas: CGSize = .zero
    /// The face zoomed to, kept from photo to photo so a burst can be stepped through on the same person.
    @State private var zoomedFace: Int?

    var body: some View {
        let flag = model.flag(asset.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(asset.filename).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                FlagButtons(id: asset.id, model: model, size: 13)
                if let index = model.shown.firstIndex(where: { $0.id == asset.id }) {
                    Text(L10n.tr("\((index + 1).formatted()) of \(model.shown.count.formatted())")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 36)
            Rule()
            // The outlines show which face is which; zoomed in, they would only be lines across the face.
            OriginalPreview(asset: asset, root: catalog.root, previews: catalog.previews, target: target?.asset == asset.id ? target?.zoom : nil) { size in
                if size.width < canvas.width * 1.5 { outlines(size) }
            }
            .background { GeometryReader { geometry in Color.clear.onAppear { canvas = geometry.size }.onChange(of: geometry.size) { _, size in canvas = size } } }
            Rule()
            faceBar
        }
        .background(Theme.canvas)
        // A new photo opens on the face last zoomed to, when it has one; otherwise fitted.
        .onChange(of: asset.id, initial: true) {
            if let face = zoomedFace, faces.indices.contains(face) { zoom(to: face) } else { zoomedFace = nil; target = nil }
        }
        .onChange(of: model.faceZoom) { _, request in
            guard let request else { return }
            if let face = request.face { zoom(to: face) } else { fit() }
        }
    }

    /// Each face numbered, red where the eyes look closed; a number zooms to its face.
    private func outlines(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                let rect = CGRect(x: face.bounds.minX * size.width, y: face.bounds.minY * size.height, width: face.bounds.width * size.width, height: face.bounds.height * size.height)
                let closed = model.eyesClosed(face)
                Rectangle().strokeBorder(closed ? Theme.reject : .white.opacity(0.7), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                Button { zoom(to: index) } label: { number(index, closed: closed) }.buttonStyle(.plain)
                    .position(x: rect.minX + 9, y: max(8, rect.minY - 9))
                    .help(L10n.tr("Zoom to this face at actual pixels"))
            }
        }
        .frame(width: size.width, height: size.height)
    }
    private func number(_ index: Int, closed: Bool) -> some View {
        Text((index + 1).formatted()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).frame(minWidth: 16).padding(.vertical, 1)
            .background(closed ? Theme.reject : .black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
    }

    /// Every face cut from the original, left to right, the same order from frame to frame so one person can be
    /// followed through a series; closed eyes are marked, and a click zooms the photo to that face.
    private var faceBar: some View {
        FaceStrip(asset: asset, faces: faces, model: model, root: catalog.root, selected: zoomedFace) { zoom(to: $0) }
            .frame(height: 92)
    }

    private func fit() { zoomedFace = nil; target = (asset.id, .fit) }
    /// Actual pixels with the face's eyes, about 30 % down its box, in the middle.
    private func zoom(to index: Int) {
        guard faces.indices.contains(index) else { return }
        let face = faces[index].bounds
        zoomedFace = index
        target = (asset.id, .actualPixels(at: CGPoint(x: face.midX, y: face.minY + face.height * 0.3)))
    }
}

/// The faces of the photo shown, side by side under it.
private struct FaceStrip: View {
    let asset: CatalogAsset
    let faces: [PhotoQualityReport.Face]
    @ObservedObject var model: FaceCheckModel
    let root: URL?
    let selected: Int?
    let zoom: (Int) -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var images: (key: String, cut: [CGImage?])?
    private static let side: CGFloat = 68

    var body: some View {
        let key = "\(asset.id)/\(FaceCropCache.key(faces))"
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                    let closed = model.eyesClosed(face)
                    Button { zoom(index) } label: {
                        ZStack {
                            Theme.imageSurround
                            if images?.key == key, index < images!.cut.count, let image = images!.cut[index] {
                                Image(decorative: image, scale: displayScale).resizable().interpolation(.high).scaledToFill()
                            }
                        }
                        .frame(width: Self.side, height: Self.side).clipped()
                        .overlay { Rectangle().strokeBorder(selected == index ? Theme.accent : closed ? Theme.reject : .clear, lineWidth: 2) }
                        .overlay(alignment: .topLeading) {
                            Text((index + 1).formatted()).font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(minWidth: 14).padding(.vertical, 1)
                                .background(closed ? Theme.reject : .black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).padding(3)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(closed ? L10n.tr("Eyes look closed") : L10n.tr("Zoom to this face at actual pixels"))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task(id: key) {
            let pixels = Int(Self.side * displayScale)
            let cacheKey = "\(key)/\(pixels)" as NSString
            if let cached = FaceCropCache.tiles.object(forKey: cacheKey) { images = (key, cached.images); return }
            guard case .available(let url) = asset.availability(catalog: root) else { return }
            let bounds = faces.map(\.bounds)
            let cut = await Task.detached(priority: .userInitiated) { () -> [CGImage?] in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                return autoreleasepool { FaceCrops.tiles(at: url, faces: bounds, pixels: pixels) }
            }.value
            guard !Task.isCancelled else { return }
            FaceCropCache.tiles.setObject(.init(cut), forKey: cacheKey, cost: FaceCropCache.cost(cut))
            images = (key, cut)
        }
    }
}

/// The people of one series side by side, a column each, and its frames one under another, so each person's eyes and
/// focus are compared frame by frame and the frame where everyone is at their best stands out. A click on a frame
/// shows it beside; a click on a face also zooms to it. Faces whose eyes look closed are marked.
private struct PeopleCompare: View {
    @ObservedObject var model: FaceCheckModel
    @ObservedObject var catalog: CatalogModel
    let frames: [CatalogAsset]
    let focused: () -> Void
    private static let side: CGFloat = 76

    var body: some View {
        let people = model.people(in: frames)
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { row, frame in
                        let current = model.focus == frame.id, flag = model.flag(frame.id)
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(frame.filename).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(current ? Color.primary : Color.secondary)
                                HStack(spacing: 4) {
                                    FlagButtons(id: frame.id, model: model, size: 11)
                                    let closed = model.faces(frame.id).filter(model.eyesClosed).count
                                    if closed > 0 {
                                        Label(closed.formatted(), systemImage: "eye.slash").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.reject)
                                            .help(L10n.tr("Eyes look closed"))
                                    }
                                }
                            }
                            .frame(width: 110, alignment: .leading)
                            FrameFaces(asset: frame, faces: model.faces(frame.id), slots: row < people.count ? people[row] : [], model: model,
                                       root: catalog.root, side: Self.side) { face in
                                model.focus = frame.id
                                if let face { model.faceZoom = .init(face: face) }
                                focused()
                            }
                        }
                        .padding(6)
                        .background(current ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .opacity(flag == .rejected ? 0.5 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { model.focus = frame.id; focused() }
                        .id(frame.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.focus) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
        }
    }
}

/// One frame's faces, each in its person's column; an empty cell where that person isn't found.
private struct FrameFaces: View {
    let asset: CatalogAsset
    let faces: [PhotoQualityReport.Face]
    let slots: [Int?]
    @ObservedObject var model: FaceCheckModel
    let root: URL?
    let side: CGFloat
    let select: (Int?) -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var images: (key: String, cut: [CGImage?])?

    var body: some View {
        let key = "\(asset.id)/\(FaceCropCache.key(faces))"
        HStack(spacing: 3) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                if let index = slot, index < faces.count {
                    let closed = model.eyesClosed(faces[index])
                    ZStack {
                        Theme.imageSurround
                        if images?.key == key, index < images!.cut.count, let image = images!.cut[index] {
                            Image(decorative: image, scale: displayScale).resizable().interpolation(.high).scaledToFill()
                        }
                    }
                    .frame(width: side, height: side).clipped()
                    .overlay { if closed { Rectangle().strokeBorder(Theme.reject, lineWidth: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { select(index) }
                    .help(closed ? L10n.tr("Eyes look closed") : L10n.tr("Zoom to this face at actual pixels"))
                } else {
                    Rectangle().strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: side, height: side)
                }
            }
        }
        .task(id: key) {
            let pixels = Int(side * displayScale)
            let cacheKey = "\(key)/\(pixels)" as NSString
            if let cached = FaceCropCache.tiles.object(forKey: cacheKey) { images = (key, cached.images); return }
            guard case .available(let url) = asset.availability(catalog: root) else { return }
            let bounds = faces.map(\.bounds)
            await FaceCropCache.gate.enter()
            guard !Task.isCancelled else { await FaceCropCache.gate.leave(); return }
            let cut = await Task.detached(priority: .userInitiated) { () -> [CGImage?] in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                return autoreleasepool { FaceCrops.tiles(at: url, faces: bounds, pixels: pixels) }
            }.value
            await FaceCropCache.gate.leave()
            guard !Task.isCancelled else { return }
            FaceCropCache.tiles.setObject(.init(cut), forKey: cacheKey, cost: FaceCropCache.cost(cut))
            images = (key, cut)
        }
    }
}

/// Pick and Reject for one photo, as P and X set them; a second click clears the flag.
private struct FlagButtons: View {
    let id: String
    @ObservedObject var model: FaceCheckModel
    var size: CGFloat = 12

    var body: some View {
        let flag = model.flag(id)
        HStack(spacing: 0) {
            ForEach([ReviewState.accepted, .rejected], id: \.self) { state in
                Button { model.set(id, flag == state ? .unreviewed : state) } label: {
                    ReviewFlag(state: state, active: flag == state, size: size, color: flag == state ? (state == .accepted ? Theme.pick : Theme.reject) : nil)
                        .frame(width: size + 14, height: size + 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state == .accepted ? L10n.tr("Pick (P)") : L10n.tr("Reject (X)"))
                .accessibilityLabel(state == .accepted ? L10n.tr("Pick") : L10n.tr("Reject")).accessibilityAddTraits(flag == state ? .isSelected : [])
            }
        }
    }
}
