import SwiftUI
import Combine
import CevicheCore

/// Find Flawed Photos: measures every photo in scope (reading what was measured before), lists the ones that look
/// blurry, out of focus, badly exposed or blinking as they land, and rejects the ones left ticked. Nothing changes in the
/// catalog until Reject.
@MainActor
final class ProblemPhotosModel: ObservableObject {
    enum Stage: Equatable { case measuring(Int, Int), ready, failed(String) }
    /// The problems this tool looks for; a burst's alternate is Pick from Bursts' business.
    static let kinds = CullingIssue.allCases.filter { !$0.inBurst }

    let request: CullingAssistantRequest
    let byID: [String: CatalogAsset]
    @Published private(set) var stage: Stage
    @Published private(set) var reports: [String: PhotoQualityReport] = [:]
    /// Photos that could not be measured, and why.
    @Published private(set) var unmeasured: [String: String] = [:]
    @Published var sensitivity: CullingSensitivity
    /// The problems that count; all of them unless the person turns some off.
    @Published var kinds = Set(ProblemPhotosModel.kinds)
    /// Photos the person unticked: they keep their flag.
    @Published private(set) var excluded: Set<String> = []
    /// Photos the person had picked and then ticked here; picked photos otherwise start unticked.
    @Published private(set) var overridden: Set<String> = []
    private weak var scanner: CullingScanner?
    /// The photos this window queued for measuring, withdrawn again if it closes first.
    private var added: Set<String> = []
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(request: CullingAssistantRequest, sensitivity: CullingSensitivity) {
        self.request = request
        byID = Dictionary(request.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stage = .measuring(0, request.assets.count)
        self.sensitivity = sensitivity
    }

    /// Reads what was already measured and has the scanner measure the rest first, so the list fills in as photos land.
    func start(catalog: CatalogModel) {
        guard task == nil, let store = catalog.store else { return }
        let scanner = catalog.cullingScanner, root = catalog.root, assets = request.assets
        self.scanner = scanner
        subscription = scanner.measured.sink { [weak self] measured in self?.receive(measured) }
        task = Task {
            do {
                // Photos the scanner finished while this read ran keep what it sent.
                reports.merge(try await store.cullingReports(assets.map(\.id)).mapValues(\.report)) { landed, _ in landed }
                guard !Task.isCancelled else { return }
                let pending = assets.filter { reports[$0.id] == nil && unmeasured[$0.id] == nil }
                updateStage()
                if !pending.isEmpty { scanner.urgent = true; added = scanner.enqueue(pending, store: store, root: root, first: true) }
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
    }
    /// Stops listening and withdraws the photos this window queued that are still waiting; ones queued by an import
    /// carry on in the background.
    func stop() {
        task?.cancel(); subscription = nil
        scanner?.urgent = false; scanner?.withdraw(added); added = []
    }

    // MARK: Results
    func current(_ id: String) -> ReviewState { byID[id]?.review ?? .unreviewed }
    /// The problems that count on this photo at the chosen sensitivity.
    func issues(_ id: String) -> [CullingIssue] { reports[id]?.issues(sensitivity, exposure: byID[id].map(ExposureSettings.init)).filter(kinds.contains) ?? [] }
    var found: [CatalogAsset] { request.assets.filter { !issues($0.id).isEmpty } }
    func count(of issue: CullingIssue) -> Int { request.assets.filter { reports[$0.id]?.issues(sensitivity, exposure: ExposureSettings($0)).contains(issue) == true }.count }
    /// Ticked photos are rejected; a photo the person picked starts unticked, so their pick stands unless they tick it.
    func isIncluded(_ id: String) -> Bool { current(id) == .accepted ? overridden.contains(id) : !excluded.contains(id) }
    func toggle(_ id: String) {
        let picked = current(id) == .accepted
        switch (isIncluded(id), picked) {
        case (true, true): overridden.remove(id)
        case (true, false): excluded.insert(id)
        case (false, true): overridden.insert(id)
        case (false, false): excluded.remove(id)
        }
    }
    func setAll(_ included: Bool) {
        let ids = found.map(\.id)
        excluded = included ? [] : Set(ids)
        overridden = included ? Set(ids.filter { current($0) == .accepted }) : []
    }
    /// Ticked photos that aren't rejected already.
    var toReject: [String] { found.map(\.id).filter { isIncluded($0) && current($0) != .rejected } }

    // MARK: Focus
    /// The photo the arrows move and Space previews.
    @Published var focus: String?
    @Published var previewing = false
    /// Grid columns, for the up and down arrows.
    var columns = 4
    var focusedAsset: CatalogAsset? { focus.flatMap { byID[$0] } }
    func move(_ step: Int) {
        let shown = found
        guard !shown.isEmpty else { return }
        let index = focus.flatMap { id in shown.firstIndex { $0.id == id } }
        focus = shown[index.map { min(max($0 + step, 0), shown.count - 1) } ?? 0].id
    }
    func setIncluded(_ included: Bool) {
        guard let id = focus, isIncluded(id) != included else { return }
        toggle(id)
    }

    func reject(catalog: CatalogModel, editor: EditorModel) {
        let ids = toReject
        guard !ids.isEmpty else { return }
        stop()
        Task { await catalog.applyCulling(Dictionary(uniqueKeysWithValues: ids.map { ($0, .rejected) }), partners: request.partners) }
    }
}

/// Find Flawed Photos takes the whole window, like the importer: the title, the flaws to look for and the buttons in
/// the title bar, the photos found in a grid, and the sensitivity, what Reject does and the thumbnail size along the bottom.
struct ProblemPhotosView: View {
    @ObservedObject var catalog: CatalogModel
    let editor: EditorModel
    @StateObject private var model: ProblemPhotosModel
    @FocusState private var focused: Bool
    @AppStorage("problemPhotosTileSize") private var tileWidth = 220.0
    private static let spacing: CGFloat = 12
    init(catalog: CatalogModel, editor: EditorModel, request: CullingAssistantRequest) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: ProblemPhotosModel(request: request, sensitivity: catalog.cullingSensitivity))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ZStack {
                content
                if model.previewing, let asset = model.focusedAsset { preview(asset) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rule()
            footer
        }
        .background(Theme.canvas)
        .onExitCommand(perform: cancel)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            model.move(press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -model.columns : model.columns)
            return .handled
        }
        // X ticks for rejection and U unticks, as they flag in the library.
        .onKeyPress(characters: CharacterSet(charactersIn: "xXuU")) { press in
            model.setIncluded(press.characters.lowercased() == "x"); return .handled
        }
        .onKeyPress(.space) { if model.focus != nil { model.previewing.toggle() }; return .handled }
        .onAppear { model.start(catalog: catalog); focused = true }
        .onDisappear { model.stop() }
        .onChange(of: model.sensitivity) { _, value in catalog.cullingSensitivity = value }
    }

    /// Escape and Cancel close the preview first, then the view.
    private func cancel() { if model.previewing { model.previewing = false } else { close() } }
    private func close() { model.stop(); catalog.problemPhotos = nil }

    // MARK: Header
    private var header: some View {
        let count = model.toReject.count
        return ToolHeader(title: L10n.tr("Find Flawed Photos"), caption: status) {
            kindBar.fixedSize()
        } actions: {
            // The measuring is itself a catalog activity (`CullingScanner`): its bar here stands for both, and other
            // background work shows once it is done.
            if case .measuring(let done, let total) = model.stage, total > 0 {
                CountRing(done: done, total: total).equatable()
            } else {
                ActivityIndicator(center: catalog.activity)
            }
            ToolCancelButton(action: cancel)
            ToolPrimaryButton(title: count == 1 ? L10n.tr("Reject 1 Photo") : L10n.tr("Reject \(count.formatted()) Photos"), minWidth: 90) {
                model.reject(catalog: catalog, editor: editor)
            }
            .disabled(count == 0).help(L10n.tr("Flag the ticked photos as rejected; nothing is deleted"))
        }
    }
    private var status: String {
        switch model.stage {
        case .measuring(let done, let total): return L10n.tr("Measuring \(done.formatted()) of \(total.formatted()) photos in \(model.request.title)…")
        case .failed(let message): return message
        case .ready:
            let count = model.request.assets.count.formatted(), found = model.found.count.formatted()
            return L10n.tr("\(count) photos in \(model.request.title) - \(found) flawed")
        }
    }
    /// Each flaw with how many photos have it; a click leaves it out or brings it back.
    private var kindBar: some View {
        HStack(spacing: 4) {
            ForEach(ProblemPhotosModel.kinds) { issue in
                let on = model.kinds.contains(issue)
                FilterChip(title: issue.title, count: model.count(of: issue), symbol: issue.symbol, isOn: on) {
                    if on { model.kinds.remove(issue) } else { model.kinds.insert(issue) }
                }
                    .help(on ? L10n.tr("Leave out photos that only have this flaw") : L10n.tr("Include photos with this flaw"))
            }
        }
    }

    // MARK: Grid
    @ViewBuilder private var content: some View {
        if case .failed(let message) = model.stage {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.found.isEmpty {
            ContentUnavailableView(model.stage == .ready ? L10n.tr("No Flaws Found") : L10n.tr("Looking for Flaws…"),
                                   systemImage: model.stage == .ready ? "checkmark.seal" : "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }
    private var grid: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + Self.spacing) / (tileWidth + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                        ForEach(model.found, id: \.id) { tile($0).id($0.id) }
                    }.padding(16)
                }
                .onChange(of: model.focus) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .onAppear { model.columns = columns }
            .onChange(of: columns) { _, value in model.columns = value }
        }
    }

    /// Ticked photos will be rejected; a click ticks or unticks one, a double click previews it.
    private func tile(_ asset: CatalogAsset) -> some View {
        let included = model.isIncluded(asset.id)
        let issues = model.issues(asset.id)
        let current = model.focus == asset.id
        return VStack(alignment: .leading, spacing: 4) {
            Color.black.aspectRatio(3 / 2, contentMode: .fit)
                .overlay { CatalogThumbnail(asset: asset, previews: catalog.previews).opacity(included ? 1 : 0.45) }
                .clipped()
                .selectionRing(included ? Theme.reject : nil)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: included ? "xmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(included ? Theme.reject : .white.opacity(0.8))
                        .background(Circle().fill(.black.opacity(0.4))).padding(4)
                }
                .overlay(alignment: .topLeading) { if model.request.partners[asset.id] != nil { PairBadge().padding(4) } }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 3) {
                        ForEach(issues) { issue in
                            Image(systemName: issue.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 20, height: 18).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark)
                        }
                    }.padding(4)
                }
            HStack(spacing: 4) {
                if model.current(asset.id) != .unreviewed { ReviewFlag(state: model.current(asset.id), active: true, size: 10) }
                Text(asset.filename).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(current ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            // One tap handler, so a single click ticks at once; the second click of a double click undoes it and previews.
            model.focus = asset.id; model.toggle(asset.id)
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.previewing = true }
            focused = true
        }
        .help(help(asset, issues))
        .accessibilityElement(children: .ignore).accessibilityLabel(asset.filename)
        .accessibilityValue(issues.map(\.title).joined(separator: ", "))
        .accessibilityAddTraits(included ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.toggle(asset.id) }
    }
    private func help(_ asset: CatalogAsset, _ issues: [CullingIssue]) -> String {
        var lines = [asset.filename, issues.map(\.title).joined(separator: ", ")]
        if let report = model.reports[asset.id] {
            func percent(_ value: Double?) -> String { value.map { min(100, Int(($0 * 100).rounded())).formatted() } ?? "–" }
            lines.append(L10n.tr("Sharpness \(percent(report.sharpness)) - subject \(percent(report.subjectSharpness)) - brightness \(percent(report.brightness))"))
        }
        return lines.joined(separator: "\n")
    }

    /// The focused photo large over the grid, for a closer look; Space or Escape closes it.
    private func preview(_ asset: CatalogAsset) -> some View {
        CullingPreview(asset: asset, report: model.reports[asset.id], root: catalog.root, previews: catalog.previews)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(asset.filename).font(.system(size: 12, weight: .medium))
                    ForEach(model.issues(asset.id)) { issue in Label(issue.title, systemImage: issue.symbol).font(.system(size: 11)) }
                    if model.isIncluded(asset.id) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.reject) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).environment(\.colorScheme, .dark).padding(10)
            }
    }

    // MARK: Footer
    private var footer: some View {
        ToolOptionsBar(spacing: 10) {
            FormSegments(title: L10n.tr("Sensitivity"), selection: $model.sensitivity, options: CullingSensitivity.allCases, label: { $0.title }).fixedSize()
                .help(L10n.tr("How readily a photo counts as blurry, out of focus, badly exposed or blinking"))
            Rule(.vertical).frame(height: 14)
            Button(L10n.tr("Tick All")) { model.setAll(true) }.buttonStyle(.secondaryAction).controlSize(.small).disabled(model.found.isEmpty)
            Button(L10n.tr("Untick All")) { model.setAll(false) }.buttonStyle(.secondaryAction).controlSize(.small).disabled(model.found.isEmpty)
            if !model.unmeasured.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .help(([model.unmeasured.count == 1 ? L10n.tr("1 photo couldn’t be measured") : L10n.tr("\(model.unmeasured.count.formatted()) photos couldn’t be measured")]
                           + model.unmeasured.prefix(8).map { (model.byID[$0.key]?.filename ?? "") + ": " + $0.value }).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            ThumbnailSizeSlider(size: $tileWidth, range: 140...420)
        }
    }
}

/// Marks a shot that is a RAW + JPEG (or HEIF) pair: the tools show its JPEG, and flag both files.
struct PairBadge: View {
    var body: some View {
        Text(L10n.tr("RAW+JPEG")).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark)
            .help(L10n.tr("A RAW + JPEG pair: shown by its JPEG, and flagged together"))
    }
}
