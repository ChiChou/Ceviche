import SwiftUI
import AppKit
import Combine
import CevicheCore

extension PairDecision {
    var title: String {
        switch self {
        case .undecided: return L10n.tr("Undecided")
        case .archiveJPEG: return L10n.tr("Archive JPEG")
        case .keepJPEG: return L10n.tr("Keep JPEG")
        case .keepRAW: return L10n.tr("Keep RAW")
        case .rejectBoth: return L10n.tr("Reject Both")
        }
    }
    /// The digit that sets it.
    var key: Character {
        switch self { case .undecided: "0"; case .archiveJPEG: "1"; case .keepJPEG: "2"; case .keepRAW: "3"; case .rejectBoth: "4" }
    }
    var symbol: String {
        switch self {
        case .undecided: return "questionmark.circle"
        case .archiveJPEG: return "archivebox"
        case .keepJPEG: return "photo"
        case .keepRAW: return "camera.aperture"
        case .rejectBoth: return "xmark.circle"
        }
    }
    init?(key: Character) { guard let match = Self.allCases.first(where: { $0.key == key }) else { return nil }; self = match }
}

/// Tidy RAW + JPEG Pairs: one decision per shot, suggested from the camera JPEG's measures (`PairTriage`) and changed
/// by the person one by one or for a selection. Nothing changes until Apply, which hands the decisions to
/// `CatalogModel.applyFileDecisions`: archived JPEGs leave the library for the Archived view, other files are picked or
/// rejected (a kept JPEG stays in the library to be developed), and rejected ones wait for Trash Rejected. No file moves.
@MainActor
final class TidyPairsModel: ObservableObject {
    struct Pair: Identifiable {
        let raw: CatalogAsset
        let processed: CatalogAsset
        var id: String { raw.id }
        var name: String { (raw.filename as NSString).deletingPathExtension }
        var rawType: String { (raw.filename as NSString).pathExtension.uppercased() }
        var processedType: String { (processed.filename as NSString).pathExtension.uppercased() }
    }
    enum Stage: Equatable { case measuring(Int, Int), ready, failed(String) }

    let request: CullingAssistantRequest
    /// In capture order.
    let pairs: [Pair]
    let sensitivity: CullingSensitivity
    @Published private(set) var stage: Stage
    /// The camera JPEG's measures, by the JPEG's ID.
    @Published private(set) var reports: [String: PhotoQualityReport] = [:]
    @Published private(set) var unmeasured: [String: String] = [:]
    /// Decisions the person made, by pair; the rest follow the suggestion.
    @Published private(set) var overrides: [String: PairDecision] = [:]
    /// Nil shows every pair.
    @Published var filter: PairDecision? { didSet { if filter != oldValue { sticky = []; keepSelectionShown() } } }
    @Published var selection: Set<String> = []
    @Published private(set) var focus: String?
    @Published var previewing = false
    @Published private(set) var working = false
    /// Grid columns, for the up and down arrows.
    var columns = 4
    /// Pairs changed while a filter shows, kept in view until the filter changes so they don't vanish under the cursor.
    private var sticky: Set<String> = []
    private var anchor: String?
    private weak var scanner: CullingScanner?
    /// The photos this window queued for measuring, withdrawn again if it closes first.
    private var added: Set<String> = []
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?

    init(request: CullingAssistantRequest, sensitivity: CullingSensitivity) {
        self.request = request; self.sensitivity = sensitivity
        pairs = RawJPEGPairs.pairs(request.assets).map { Pair(raw: $0.raw, processed: $0.processed) }
            .sorted { ($0.raw.captureTime ?? "", $0.raw.filename) < ($1.raw.captureTime ?? "", $1.raw.filename) }
        stage = .measuring(0, pairs.count)
        focus = pairs.first?.id
        selection = Set(pairs.prefix(1).map(\.id))
        anchor = focus
    }

    // MARK: Measuring
    /// Reads the JPEGs' saved measures and has the scanner measure the rest first; suggestions fill in as they land.
    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ error: Error) {
        stop(); catalog.tidyPairs = nil
        catalog.failure = Failure(L10n.tr("Can’t Cull These Photos"), error)
    }
    func start(catalog: CatalogModel) {
        guard task == nil, let store = catalog.store else { return }
        let scanner = catalog.cullingScanner, root = catalog.root, jpegs = pairs.map(\.processed)
        self.scanner = scanner
        subscription = scanner.measured.sink { [weak self] in self?.receive($0) }
        task = Task {
            do {
                reports.merge(try await store.cullingReports(jpegs.map(\.id)).mapValues(\.report)) { landed, _ in landed }
                guard !Task.isCancelled else { return }
                let pending = jpegs.filter { reports[$0.id] == nil && unmeasured[$0.id] == nil }
                updateStage()
                if !pending.isEmpty { scanner.urgent = true; added = scanner.enqueue(pending, store: store, root: root, first: true) }
            } catch { abort(catalog: catalog, error) }
        }
    }
    private func receive(_ measured: CullingScanner.Measured) {
        guard pairs.contains(where: { $0.processed.id == measured.assetID }) else { return }
        if let report = measured.report { reports[measured.assetID] = report.report; unmeasured[measured.assetID] = nil }
        else if let failure = measured.failure { unmeasured[measured.assetID] = failure }
        updateStage()
    }
    private func updateStage() {
        let done = pairs.filter { reports[$0.processed.id] != nil || unmeasured[$0.processed.id] != nil }.count
        stage = done < pairs.count ? .measuring(done, pairs.count) : .ready
        if stage == .ready { scanner?.urgent = false }
    }
    func stop() { task?.cancel(); subscription = nil; scanner?.urgent = false; scanner?.withdraw(added); added = [] }

    // MARK: Decisions
    func suggestion(_ pair: Pair) -> PairTriage.Suggestion {
        PairTriage.suggest(raw: pair.raw, processed: pair.processed, report: reports[pair.processed.id], sensitivity: sensitivity)
    }
    func decision(_ pair: Pair) -> PairDecision { overrides[pair.id] ?? suggestion(pair).decision }
    func isOverridden(_ pair: Pair) -> Bool { overrides[pair.id].map { $0 != suggestion(pair).decision } ?? false }
    func count(_ decision: PairDecision?) -> Int { decision.map { d in pairs.filter { self.decision($0) == d }.count } ?? pairs.count }
    var shown: [Pair] { filter.map { f in pairs.filter { decision($0) == f || sticky.contains($0.id) } } ?? pairs }

    /// Sets the decision for the selection; with one pair selected the cursor moves on to the next, as when culling.
    func set(_ decision: PairDecision) {
        let ids = selection.isEmpty ? Set(focus.map { [$0] } ?? []) : selection
        guard !ids.isEmpty else { return }
        for id in ids { overrides[id] = decision }
        if filter != nil { sticky.formUnion(ids) }
        if ids.count == 1 { move(1, extend: false) }
    }
    func set(_ decision: PairDecision, for id: String) {
        if !selection.contains(id) { select(id) }
        set(decision)
    }
    func resetToSuggestions() { overrides = [:]; sticky = [] }

    // MARK: Selection
    func select(_ id: String, extend: Bool = false, toggle: Bool = false) {
        var picked = MultiSelection(ids: selection, anchor: anchor)
        picked.click(id, in: shown.map(\.id), extending: extend, toggling: toggle)
        selection = picked.ids; anchor = picked.anchor
        focus = id
    }
    func selectAll() {
        var picked = MultiSelection(ids: selection, anchor: anchor)
        picked.selectAll(shown.map(\.id))
        selection = picked.ids; anchor = picked.anchor
    }
    func deselectAll() { selection = []; anchor = focus }
    /// Moves the cursor `step` places through the shown pairs; `extend` grows the selection from the anchor.
    func move(_ step: Int, extend: Bool) {
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return }
        let index = focus.flatMap(ids.firstIndex(of:)) ?? 0
        let next = ids[max(0, min(ids.count - 1, index + step))]
        select(next, extend: extend)
    }
    private func keepSelectionShown() {
        let ids = Set(shown.map(\.id))
        selection.formIntersection(ids)
        if let focus, !ids.contains(focus) { self.focus = shown.first?.id; anchor = self.focus }
        if selection.isEmpty, let focus { selection = [focus] }
    }
    var focused: Pair? { focus.flatMap { id in pairs.first { $0.id == id } } }

    // MARK: Apply
    struct Plan {
        var decisions = FileDecisions()
        var archived = 0, picked = 0, rejectedFiles = 0
        var rejectedBytes: Int64 = 0
        var isEmpty: Bool { decisions.isEmpty }
    }
    var plan: Plan {
        var plan = Plan()
        func reject(_ asset: CatalogAsset) {
            plan.decisions.set(asset.id, review: .rejected)
            if asset.review != .rejected { plan.rejectedFiles += 1; plan.rejectedBytes += asset.fileSize ?? 0 }
        }
        /// Picks `kept`, which takes over what `other` was given, so the stars aren't lost with it.
        func pick(_ kept: CatalogAsset, over other: CatalogAsset) {
            var change = FileDecisions.Change(review: .accepted)
            if kept.rating == 0, other.rating > 0 { change.rating = other.rating }
            if kept.label == nil, let label = other.label { change.label = .some(label) }
            if kept.review != .accepted || change.rating != nil || change.label != nil { plan.decisions.changes[kept.id] = change; plan.picked += 1 }
        }
        for pair in pairs {
            switch decision(pair) {
            case .undecided: break
            case .archiveJPEG:
                plan.decisions.archive.append(pair.processed); plan.archived += 1
                reject(pair.raw)
            case .keepJPEG:
                pick(pair.processed, over: pair.raw)
                reject(pair.raw)
            case .keepRAW:
                pick(pair.raw, over: pair.processed)
                reject(pair.processed)
            case .rejectBoth:
                reject(pair.raw); reject(pair.processed)
            }
        }
        return plan
    }
    func apply(catalog: CatalogModel, editor: EditorModel) {
        let plan = self.plan
        guard !plan.isEmpty, !working else { return }
        working = true; stop()
        Task {
            if !catalog.showingLibrary { await catalog.closePhoto(editor: editor) }
            let result = await catalog.applyFileDecisions(plan.decisions, undoTitle: L10n.tr("Tidy RAW + JPEG Pairs"))
            working = false
            guard let result else { return }
            catalog.tidyPairs = nil
            var parts: [String] = []
            if result.archived > 0 { parts.append(L10n.tr("\(result.archived.formatted()) archived")) }
            if result.picked > 0 { parts.append(L10n.tr("\(result.picked.formatted()) picked")) }
            if result.rejected > 0 { parts.append(L10n.tr("\(result.rejected.formatted()) rejected")) }
            catalog.notice = parts.isEmpty ? L10n.tr("No flags changed") : parts.joined(separator: ", ")
            if !result.failures.isEmpty {
                catalog.failure = Failure(L10n.tr("Some Pairs Weren’t Tidied"), summary: "", items: result.failures)
            }
        }
    }
}

/// Tidy RAW + JPEG Pairs takes the whole window, like the importer: the title, the decision filter and the buttons
/// in the title bar, the pairs in a grid, and what Apply does and the thumbnail size along the bottom.
struct TidyPairsView: View {
    @ObservedObject var catalog: CatalogModel
    let editor: EditorModel
    @StateObject private var model: TidyPairsModel
    @FocusState private var focused: Bool
    @AppStorage("tidyPairsTileSize") private var tileWidth = 220.0
    private static let spacing: CGFloat = 12
    init(catalog: CatalogModel, editor: EditorModel, request: CullingAssistantRequest) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: TidyPairsModel(request: request, sensitivity: catalog.cullingSensitivity))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ZStack {
                grid
                if model.previewing, let pair = model.focused { preview(pair) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rule()
            footer
        }
        .background(Theme.canvas)
        .onExitCommand(perform: cancel)
        .disabled(model.working)
        .selectionKeys(focus: $focused, hasSelection: !model.selection.isEmpty, selectAll: model.selectAll, deselectAll: model.deselectAll)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            let step = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -model.columns : model.columns
            model.move(step, extend: press.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "01234")) { press in
            guard let key = press.characters.first, let decision = PairDecision(key: key) else { return .ignored }
            model.set(decision); return .handled
        }
        .onKeyPress(.space) { model.previewing.toggle(); return .handled }
        .onAppear { model.start(catalog: catalog); focused = true }
        .onDisappear { model.stop() }
    }
    /// Escape and Cancel close the preview first, then the view.
    private func cancel() { if model.previewing { model.previewing = false } else { close() } }
    private func close() { if !model.working { model.stop(); catalog.tidyPairs = nil } }

    // MARK: Header
    private var header: some View {
        ToolHeader(title: L10n.tr("Tidy RAW + JPEG Pairs"), caption: status) {
            filterBar.fixedSize()
        } actions: {
            // The measuring is itself a catalog activity (`CullingScanner`): its bar here stands for both, and other
            // background work shows once it is done, as in Find Flawed Photos.
            if case .measuring(let done, let total) = model.stage, total > 0 {
                CountRing(done: done, total: total).equatable()
            } else {
                ActivityIndicator(center: catalog.activity)
            }
            if model.working { ProgressView().controlSize(.small) }
            ToolCancelButton(action: cancel)
            ToolPrimaryButton(title: L10n.tr("Apply")) { model.apply(catalog: catalog, editor: editor) }
                .disabled(model.plan.isEmpty || model.working).help(L10n.tr("Nothing is deleted"))
        }
    }
    private var status: String {
        switch model.stage {
        case .measuring(let done, let total): return L10n.tr("Measuring \(done.formatted()) of \(total.formatted()) in \(model.request.title)…")
        case .failed(let message): return message
        case .ready: return model.pairs.count == 1 ? L10n.tr("1 pair in \(model.request.title)") : L10n.tr("\(model.pairs.count.formatted()) pairs in \(model.request.title)")
        }
    }
    /// All, then each decision with its count and the key that sets it; a click shows only those pairs.
    private var filterBar: some View {
        HStack(spacing: 4) {
            chip(nil)
            ForEach(PairDecision.allCases) { chip($0) }
        }
    }
    private func chip(_ decision: PairDecision?) -> some View {
        let on = model.filter == decision
        return FilterChip(title: decision?.title ?? L10n.tr("All"), count: model.count(decision), symbol: decision?.symbol,
                          symbolColor: decision.map(color), isOn: on) { model.filter = decision }
        .help(decision.map { L10n.tr("Key \(String($0.key))", context: "keyboard key that sets this") } ?? L10n.tr("Show all pairs"))
    }
    private func color(_ decision: PairDecision) -> Color {
        switch decision {
        case .undecided: return .secondary
        case .archiveJPEG: return Theme.accent
        case .keepJPEG, .keepRAW: return Theme.pick
        case .rejectBoth: return Theme.reject
        }
    }

    // MARK: Grid
    private var grid: some View {
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + Self.spacing) / (tileWidth + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    if model.shown.isEmpty {
                        Text(model.filter.map { L10n.tr("No pairs set to \($0.title)") } ?? L10n.tr("No RAW + JPEG pairs in \(model.request.title)"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                        ForEach(model.shown) { tile($0).id($0.id) }
                    }.padding(16)
                }
                .onChange(of: model.focused?.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .onAppear { model.columns = columns }
            .onChange(of: columns) { _, value in model.columns = value }
        }
    }

    private func tile(_ pair: TidyPairsModel.Pair) -> some View {
        let decision = model.decision(pair)
        let suggestion = model.suggestion(pair)
        let selected = model.selection.contains(pair.id), current = model.focused?.id == pair.id
        let outcome = files(decision)
        return VStack(alignment: .leading, spacing: 4) {
            thumbnail(pair, decision: decision, reason: model.isOverridden(pair) ? nil : suggestion.reason)
            HStack(spacing: 4) {
                Text(pair.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                fileChip(pair.rawType, outcome.raw)
                fileChip(pair.processedType, outcome.processed)
            }
        }
        .padding(4)
        .background(selected ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(current ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            // One tap handler, so a single click selects at once instead of waiting to rule out a double click.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.select(pair.id); model.previewing = true }
            else { model.select(pair.id, extend: SelectionClick.extending, toggle: SelectionClick.toggling) }
            focused = true
        }
        .contextMenu {
            ForEach(PairDecision.allCases) { option in
                Button { model.set(option, for: pair.id) } label: { Label(option.title, systemImage: option.symbol) }
                    .keyboardShortcut(KeyEquivalent(option.key), modifiers: [])
            }
        }
        .help(help(pair))
        .accessibilityElement(children: .ignore).accessibilityLabel(pair.name).accessibilityValue(decision.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnail(_ pair: TidyPairsModel.Pair, decision: PairDecision, reason: PairReason?) -> some View {
        Color.black.aspectRatio(3 / 2, contentMode: .fit)
            .overlay { CatalogThumbnail(asset: pair.processed, previews: catalog.previews).opacity(decision == .rejectBoth ? 0.45 : 1) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                // Why the suggestion, while the decision is still the suggestion.
                if let reason {
                    Text(reason.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: decision.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color(decision))
                    .padding(3).background(Color.black.opacity(0.55), in: Circle()).environment(\.colorScheme, .dark).padding(4)
            }
    }

    enum FileOutcome { case unchanged, keep, reject, archive }
    private func files(_ decision: PairDecision) -> (raw: FileOutcome, processed: FileOutcome) {
        switch decision {
        case .undecided: return (.unchanged, .unchanged)
        case .archiveJPEG: return (.reject, .archive)
        case .keepJPEG: return (.reject, .keep)
        case .keepRAW: return (.keep, .reject)
        case .rejectBoth: return (.reject, .reject)
        }
    }
    private func fileChip(_ name: String, _ outcome: FileOutcome) -> some View {
        let color: Color = switch outcome { case .unchanged: .secondary; case .keep: Theme.pick; case .reject: Theme.reject; case .archive: Theme.accent }
        return HStack(spacing: 2) {
            Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(outcome == .reject || outcome == .unchanged ? .secondary : .primary)
            if outcome != .unchanged {
                Image(systemName: outcome == .keep ? "checkmark" : outcome == .reject ? "xmark" : "archivebox.fill")
                    .font(.system(size: 7, weight: .heavy)).foregroundStyle(color)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color.opacity(outcome == .unchanged ? 0.08 : 0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.tag))
    }
    private func help(_ pair: TidyPairsModel.Pair) -> String {
        var lines = [pair.raw.filename + " + " + pair.processed.filename]
        if let report = model.reports[pair.processed.id] {
            func percent(_ value: Double?) -> String { value.map { min(100, Int(($0 * 100).rounded())).formatted() } ?? "–" }
            lines.append(L10n.tr("Sharpness \(percent(report.peakSharpness ?? report.sharpness)) - brightness \(percent(report.brightness)) - clipped \(percent(report.highlights)) - cast \(percent(report.colorCast.map { $0 * 10 }))"))
        } else if let failure = model.unmeasured[pair.processed.id] {
            lines.append(failure)
        }
        return lines.joined(separator: "\n")
    }

    /// The focused pair's JPEG large over the grid, for a closer look; Space or Escape closes it.
    private func preview(_ pair: TidyPairsModel.Pair) -> some View {
        CullingPreview(asset: pair.processed, report: model.reports[pair.processed.id], root: catalog.root, previews: catalog.previews)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(pair.name).font(.system(size: 12, weight: .medium))
                    let decision = model.decision(pair)
                    Label(decision.title, systemImage: decision.symbol).font(.system(size: 11)).foregroundStyle(color(decision))
                }
                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.control)).environment(\.colorScheme, .dark).padding(10)
            }
    }

    // MARK: Footer
    private var footer: some View {
        ToolOptionsBar(spacing: 10) {
            Text(summary(model.plan)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.tail)
            if !model.unmeasured.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    .help(model.unmeasured.count == 1 ? L10n.tr("1 photo couldn’t be measured") : L10n.tr("\(model.unmeasured.count.formatted()) photos couldn’t be measured"))
            }
            Spacer(minLength: 0)
            Button(L10n.tr("Reset"), action: model.resetToSuggestions).buttonStyle(.secondaryAction).controlSize(.small)
                .disabled(!model.pairs.contains(where: model.isOverridden))
                .help(L10n.tr("Go back to the suggested decisions"))
            ThumbnailSizeSlider(size: $tileWidth, range: 140...420)
        }
    }
    private func summary(_ plan: TidyPairsModel.Plan) -> String {
        guard !plan.isEmpty else { return L10n.tr("Nothing to change") }
        var parts: [String] = []
        if plan.archived > 0 { parts.append(L10n.tr("\(plan.archived.formatted()) archived")) }
        if plan.picked > 0 { parts.append(L10n.tr("\(plan.picked.formatted()) picked")) }
        if plan.rejectedFiles > 0 {
            parts.append(L10n.tr("\(plan.rejectedFiles.formatted()) rejected (\(ByteCountFormatter.string(fromByteCount: plan.rejectedBytes, countStyle: .file)))"))
        }
        return parts.joined(separator: " - ")
    }
}
