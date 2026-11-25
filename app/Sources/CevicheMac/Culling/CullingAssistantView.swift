import SwiftUI
import AppKit
import Combine
import CevicheCore

/// Pick from Bursts: reads the photos' measurements as they land and rebuilds the bursts as they do and as the options
/// change. Each burst gets an action: Pick proposes Pick and Reject for its frames, Group puts it in a group under a
/// cover and leaves its flags alone, Skip leaves it as it is. Nothing changes in the catalog until Apply.
@MainActor
final class CullingAssistantModel: ObservableObject {
    enum Stage: Equatable { case measuring(Int, Int), ready, failed(String) }
    typealias Action = BurstChoices.Action

    let request: CullingAssistantRequest
    let byID: [String: CatalogAsset]
    @Published private(set) var stage: Stage
    @Published private(set) var reports: [String: CatalogCullingReport] = [:]
    /// Photos that could not be measured, and why.
    @Published private(set) var unmeasured: [String: String] = [:]
    @Published var options: CullingPlan.Options { didSet { if options != oldValue { remember(); replan() } } }
    /// The bursts and the person's choices on them, kept by frame since bursts are rebuilt as the options change.
    @Published private(set) var choices: BurstChoices
    var plan: CullingPlan { choices.plan }
    var defaultAction: Action { choices.defaultAction }
    @Published var burstID: String?
    /// The photo in the preview.
    @Published var focusedID: String?
    /// First frames of bursts the person merged into the burst above, kept by frame as bursts are rebuilt.
    @Published private(set) var joins: Set<String> = [] { didSet { if joins != oldValue { replan() } } }
    private var task: Task<Void, Never>?
    private weak var scanner: CullingScanner?
    /// The photos this window queued for measuring, withdrawn again if it closes first.
    private var added: Set<String> = []
    private var subscription: AnyCancellable?
    private var replanPending: Task<Void, Never>?
    private var planGeneration = 0
    private let preferences = UserDefaults.standard

    /// `sensitivity` is the library's, which decides which frames have problems and so can't be the one kept.
    init(request: CullingAssistantRequest, sensitivity: CullingSensitivity) {
        self.request = request
        byID = Dictionary(request.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stage = .measuring(0, request.assets.count)
        choices = BurstChoices(photos: request.assets, partners: request.partners, stacks: request.stacks, oneBurst: request.oneGroup)
        var options = preferences.data(forKey: "cullingOptions").flatMap { try? JSONDecoder().decode(CullingPlan.Options.self, from: $0) } ?? CullingPlan.Options()
        options.sensitivity = sensitivity
        self.options = options
    }

    /// Reads what was already measured, then hands the rest to the catalog's scanner with these photos first; the bursts
    /// fill in as each photo lands, and the work goes on in the background if the window closes before it is done.
    func start(catalog: CatalogModel) {
        guard task == nil, let store = catalog.store else { return }
        let scanner = catalog.cullingScanner, root = catalog.root, assets = request.assets
        self.scanner = scanner
        subscription = scanner.measured.sink { [weak self] measured in self?.receive(measured) }
        task = Task {
            do {
                // Photos the scanner finished while this read ran keep what it sent.
                reports.merge(try await store.cullingReports(assets.map(\.id))) { landed, _ in landed }
                guard !Task.isCancelled else { return }
                replan()
                let pending = assets.filter { reports[$0.id] == nil }
                updateStage()
                if !pending.isEmpty { scanner.urgent = true; added = scanner.enqueue(pending, store: store, root: root, first: true) }
            } catch { abort(catalog: catalog, error) }
        }
    }
    private func receive(_ measured: CullingScanner.Measured) {
        guard byID[measured.assetID] != nil else { return }
        if let report = measured.report { reports[measured.assetID] = report; unmeasured[measured.assetID] = nil }
        else if let failure = measured.failure { unmeasured[measured.assetID] = failure }
        updateStage()
        if stage == .ready { replan() } else { replanSoon() }
    }
    private func updateStage() {
        let done = request.assets.filter { reports[$0.id] != nil || unmeasured[$0.id] != nil }.count
        stage = done < request.assets.count ? .measuring(done, request.assets.count) : .ready
        if stage == .ready { scanner?.urgent = false }
    }
    /// While photos land, the bursts are rebuilt a few times a second rather than for every photo.
    private func replanSoon() {
        guard replanPending == nil else { return }
        replanPending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            replanPending = nil; replan()
        }
    }
    /// Stops listening and withdraws the photos this window queued that are still waiting; ones queued by an import
    /// carry on in the background.
    func stop() {
        task?.cancel(); subscription = nil; replanPending?.cancel(); replanPending = nil
        scanner?.urgent = false; scanner?.withdraw(added); added = []
    }

    /// Rebuilds the proposal off the main thread; a newer request replaces the result of an older one.
    private func replan() {
        let photos = request.assets.map { asset in
            CullingPlan.Photo(id: asset.id, review: current(asset.id), report: reports[asset.id]?.report, featurePrint: reports[asset.id]?.featurePrint,
                              exposureTime: asset.exposureTime, focalLength: asset.focalLength, exposure: ExposureSettings(asset))
        }
        let options = self.options, oneBurst = request.oneGroup, joins = self.joins
        planGeneration += 1
        let generation = planGeneration
        Task {
            let plan = await Task.detached(priority: .userInitiated) { CullingPlan(photos, options: options, oneBurst: oneBurst, joins: joins) }.value
            guard generation == planGeneration else { return }
            choices.update(plan)
            if burstID == nil || !plan.bursts.contains(where: { $0.id == burstID }) { burstID = plan.bursts.first?.id }
            if let burst, focusedID.map({ !burst.members.contains($0) }) ?? true { focusedID = burst.best }
        }
    }
    private func remember() {
        if let data = try? JSONEncoder().encode(options) { preferences.set(data, forKey: "cullingOptions") }
    }

    // MARK: Flags
    func current(_ id: String) -> ReviewState { choices.current(id) }
    /// The flag the photo will have after Apply: the person's choice, else the assistant's for frames of a burst. A
    /// burst to group or skip keeps its flags.
    func flag(_ id: String) -> ReviewState { choices.flag(id) }
    /// Flagging a frame makes its burst one to pick from.
    func set(_ id: String, _ state: ReviewState) { choices.set(id, state) }
    /// Clicking the flag a photo will have leaves the photo's own flag instead.
    func toggle(_ id: String, _ state: ReviewState) { set(id, flag(id) == state ? .unreviewed : state) }
    /// Switches a frame between kept and rejected.
    func toggleKeep(_ id: String) { set(id, flag(id) == .accepted ? .rejected : .accepted) }
    /// Picks this frame of its burst, rejects the others and moves on to the next burst.
    func keepOnly(_ id: String) {
        guard let burst = choices.burst(of: id) else { return }
        choices.keepOnly(id)
        if burst.id == burstID { moveBurst(1) }
    }
    // MARK: Actions
    func action(_ burst: CullingPlan.Burst) -> Action { choices.action(burst) }
    /// Group All and Skip All: every burst, also those that appear as the options change.
    func setAll(_ action: Action) {
        choices.setAll(action)
        if action == .group, let burst { focusedID = cover(of: burst) }
    }
    /// A burst's Group or Skip button: on, or back to Pick.
    func toggle(_ burst: CullingPlan.Burst, _ action: Action) { setAction(burst, self.action(burst) == action ? .pick : action) }
    func setAction(_ burst: CullingPlan.Burst, _ action: Action) {
        choices.setAction(burst, action)
        if action == .group { showCover(burst) }
    }
    /// A folded burst shows its cover.
    private func showCover(_ burst: CullingPlan.Burst) {
        if let focusedID, burst.members.contains(focusedID) { self.focusedID = cover(of: burst) }
    }
    // MARK: Merge
    /// Every burst but the first can join the one above it.
    func canMerge(_ burst: CullingPlan.Burst) -> Bool { !request.oneGroup && plan.bursts.first?.id != burst.id }
    /// Whether the person merged bursts into this one.
    func isMerged(_ burst: CullingPlan.Burst) -> Bool { burst.members.dropFirst().contains { joins.contains($0) } }
    func mergeWithAbove(_ burst: CullingPlan.Burst) {
        guard canMerge(burst), let index = plan.bursts.firstIndex(where: { $0.id == burst.id }) else { return }
        burstID = plan.bursts[index - 1].id
        joins.insert(burst.members[0])
    }
    /// Undoes the person's merges in this burst.
    func split(_ burst: CullingPlan.Burst) { joins.subtract(burst.members) }

    /// The frame the burst's group shows: the one the person chose, else the best.
    func cover(of burst: CullingPlan.Burst) -> String { choices.cover(of: burst) }
    func makeCover(_ id: String) {
        guard let burst = choices.burst(of: id) else { return }
        choices.makeCover(id)
        showCover(burst)
    }
    /// Space: in a burst to pick from, keeps only this frame; in one to group, makes it the cover. Then the next burst.
    func choose(_ id: String) {
        guard let burst = choices.burst(of: id) else { return }
        switch action(burst) {
        case .pick: keepOnly(id)
        case .group: makeCover(id); if burst.id == burstID { moveBurst(1) }
        case .skip: if burst.id == burstID { moveBurst(1) }
        }
    }
    /// Already exactly one group under its cover, both files of each RAW + JPEG shot included.
    func isGrouped(_ burst: CullingPlan.Burst) -> Bool { choices.isGrouped(burst) }
    /// The bursts Apply groups, both files of a RAW + JPEG shot, under the cover (the RAW of a pair).
    var groupChanges: [CullingChanges.Group] { choices.groupChanges }
    /// Every photo whose flag Apply would change, with its new flag.
    var changes: [String: ReviewState] { choices.changes }
    /// Flags can be applied while photos are still being measured; the rest keep measuring in the background.
    var canApply: Bool { !changes.isEmpty || !groupChanges.isEmpty }

    // MARK: Navigation
    var burst: CullingPlan.Burst? { plan.bursts.first { $0.id == burstID } }
    /// Through the frames of the burst, a folded one included: its preview shows each, to choose the cover.
    /// ← and →: past the first or last frame, on into the burst before or after.
    func moveFocus(_ offset: Int) {
        guard let burst, let bursts = Optional(plan.bursts), let at = bursts.firstIndex(where: { $0.id == burst.id }) else { moveBurst(offset); return }
        let members = burst.members
        let index = members.firstIndex { $0 == focusedID } ?? (offset > 0 ? -1 : members.count)
        let next = index + offset
        if members.indices.contains(next) { focusedID = members[next]; return }
        let neighbour = at + (offset > 0 ? 1 : -1)
        guard bursts.indices.contains(neighbour) else { return }
        burstID = bursts[neighbour].id
        focusedID = offset > 0 ? bursts[neighbour].members.first : bursts[neighbour].members.last
    }
    func moveBurst(_ offset: Int) {
        guard let index = plan.bursts.firstIndex(where: { $0.id == burstID }) ?? (offset > 0 ? -1 : nil) else { return }
        let next = plan.bursts[max(0, min(plan.bursts.count - 1, index + offset))]
        burstID = next.id; focusedID = action(next) == .group ? cover(of: next) : next.best
    }

    func apply(catalog: CatalogModel, editor: EditorModel) {
        guard canApply else { return }
        let changes = self.changes, groups = groupChanges
        stop()
        Task { await catalog.applyCulling(changes, partners: request.partners, groups: groups) }
    }
    /// Setup failed outright (an original missing, photos the tool can't take): there is nothing to work with, so the
    /// tool closes and says why.
    private func abort(catalog: CatalogModel, _ error: Error) {
        close(catalog: catalog)
        catalog.failure = Failure(L10n.tr("Can’t Cull These Photos"), error)
    }
    func close(catalog: CatalogModel) {
        stop()
        catalog.cullingAssistant = nil
    }
}

/// Pick from Bursts fills the window like the merges: every run of similar shots as a row of its frames on the left, the
/// frame being looked at large on the right, the burst options under the title bar and what Apply will change along the
/// bottom.
struct CullingAssistantView: View {
    @ObservedObject var catalog: CatalogModel
    let editor: EditorModel
    @StateObject private var model: CullingAssistantModel
    @FocusState private var keyFocus: Bool
    @AppStorage("cullingPreviewWidth") private var previewWidth = 480.0
    init(catalog: CatalogModel, editor: EditorModel, request: CullingAssistantRequest) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: CullingAssistantModel(request: request, sensitivity: catalog.cullingSensitivity))
    }
    /// With a model made outside, for snapshots that set it up first.
    init(catalog: CatalogModel, editor: EditorModel, model: CullingAssistantModel) {
        self.catalog = catalog; self.editor = editor
        _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            toolbar
            Rule()
            Group {
                if case .failed(let message) = model.stage {
                    ContentUnavailableView(L10n.tr("Can’t Cull These Photos"), systemImage: "square.stack.3d.down.right", description: Text(message))
                } else {
                    bursts
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .focusable().focusEffectDisabled().focused($keyFocus)
        .onKeyPress(.leftArrow) { model.moveFocus(-1); return .handled }
        .onKeyPress(.rightArrow) { model.moveFocus(1); return .handled }
        .onKeyPress(.upArrow) { model.moveBurst(-1); return .handled }
        .onKeyPress(.downArrow) { model.moveBurst(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "gGsS")) { press in
            guard !model.request.oneGroup, let burst = model.burst else { return .ignored }
            model.toggle(burst, press.characters.lowercased() == "g" ? .group : .skip); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pxuPXU")) { press in
            guard let id = model.focusedID else { return .ignored }
            switch press.characters.lowercased() {
            case "p": model.set(id, .accepted)
            case "x": model.set(id, .rejected)
            default: model.set(id, .unreviewed)
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard let id = model.focusedID else { return .ignored }
            model.choose(id); return .handled
        }
        .onAppear { model.start(catalog: catalog); keyFocus = true }
        .onDisappear { model.stop() }
        .onExitCommand { model.close(catalog: catalog) }
        // A control used in the bar keeps the arrow keys for the list.
        .onChange(of: model.options) { keyFocus = true }
        .onChange(of: model.defaultAction) { keyFocus = true }
    }

    // MARK: Header and options
    private var header: some View {
        ToolHeader(title: L10n.tr("Pick from Bursts"), caption: status, center: { Color.clear }) {
            if case .measuring(let done, let total) = model.stage, total > 0 {
                CountRing(done: done, total: total).equatable()
            }
            ToolCancelButton { model.close(catalog: catalog) }
            ToolPrimaryButton(title: L10n.tr("Apply")) { model.apply(catalog: catalog, editor: editor) }.disabled(!model.canApply)
                .help(L10n.tr("Set the flags and groups shown here; nothing is deleted"))
        }
    }

    private var status: String {
        switch model.stage {
        case .measuring(let done, let total): return L10n.tr("Measuring \(done.formatted()) of \(total.formatted()) photos in \(model.request.title)…")
        case .failed(let message): return message
        case .ready where model.request.oneGroup: return L10n.tr("\(model.request.assets.count.formatted()) photos in \(model.request.title)")
        case .ready:
            let series = model.plan.bursts.filter { $0.series != nil }.count, bursts = model.plan.bursts.count - series
            let count = model.request.assets.count.formatted(), title = model.request.title
            return series == 0 ? L10n.tr("\(count) photos in \(title) - \(bursts.formatted()) bursts")
                : L10n.tr("\(count) photos in \(title) - \(bursts.formatted()) bursts, \(series.formatted()) timelapses")
        }
    }

    private var toolbar: some View {
        ToolOptionsBar {
            // A group the person made is the burst, so there is nothing to tell bursts apart by.
            if model.request.oneGroup { Text(L10n.tr("Pick one photo from the group")).foregroundStyle(.secondary) } else {
                HStack(spacing: 4) {
                    BurstActionButton(title: L10n.tr("Group All")) { model.setAll(.group) }
                        .help(L10n.tr("Fold every burst under its key photo"))
                    BurstActionButton(title: L10n.tr("Skip All")) { model.setAll(.skip) }
                        .help(L10n.tr("Leave every burst as it is"))
                }.padding(.trailing, 8)
                burstOptions
            }
            Spacer(minLength: 0)
            // What Apply will do, under the button that does it.
            changeSummary
        }
    }
    @ViewBuilder private var burstOptions: some View {
        // What makes a burst, in the toolbar like Sensitivity in Find Flawed Photos; only the time is a menu.
        FormSegments(title: L10n.tr("Similarity"), selection: $model.options.burst.distance, options: [0.2, 0.35, 0.5], label: { $0 == 0.2 ? L10n.tr("Nearly Identical") : $0 == 0.35 ? L10n.tr("Same Scene") : L10n.tr("Similar Scene") }).fixedSize()
            .help(L10n.tr("How alike neighbouring photos must look to belong to one burst"))
        // A slider over fixed stops: the useful gaps are uneven, and dragging regroups the bursts as it goes.
        HStack(spacing: 8) {
            Text(L10n.tr("Frames Apart"))
            FormSlider(value: gapStop, in: 0...Double(Self.gaps.count - 1), step: 1).frame(width: 120)
                .accessibilityLabel(L10n.tr("Frames Apart")).accessibilityValue(seconds(model.options.burst.gap))
            Text(seconds(model.options.burst.gap)).monospacedDigit().frame(minWidth: 72, alignment: .leading)
        }.help(L10n.tr("Photos from one camera taken within this time of each other that show the same scene form a burst"))
    }
    private static let gaps: [Double] = [1, 2, 3, 5, 10, 30]
    /// The gap as a stop on the slider; a saved gap that isn't a stop shows at the nearest one.
    private var gapStop: Binding<Double> {
        Binding(get: {
            let gap = model.options.burst.gap
            return Double(Self.gaps.indices.min { abs(Self.gaps[$0] - gap) < abs(Self.gaps[$1] - gap) } ?? 2)
        }, set: { model.options.burst.gap = Self.gaps[min(Self.gaps.count - 1, max(0, Int($0.rounded())))] })
    }
    private func seconds(_ value: Double) -> String { value == 1 ? L10n.tr("1 second") : L10n.tr("\(Int(value)) seconds") }

    private var changeSummary: some View {
        let changes = model.changes, groups = model.groupChanges.count
        let rejected = changes.values.filter { $0 == .rejected }.count, picked = changes.values.filter { $0 == .accepted }.count
        // Only what Apply does: a count of nothing is left out.
        let parts = [rejected > 0 ? Text(L10n.tr("\(rejected.formatted()) to reject")).foregroundStyle(Theme.reject) : nil,
                     picked > 0 ? Text(L10n.tr("\(picked.formatted()) to pick")).foregroundStyle(Theme.pick) : nil,
                     groups > 0 ? Text(groups == 1 ? L10n.tr("1 burst to group") : L10n.tr("\(groups.formatted()) bursts to group")) : nil].compactMap { $0 }
        return HStack(spacing: 12) {
            if !model.unmeasured.isEmpty {
                Label(model.unmeasured.count == 1 ? L10n.tr("1 photo couldn’t be measured") : L10n.tr("\(model.unmeasured.count.formatted()) photos couldn’t be measured"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .help(model.unmeasured.prefix(8).map { (model.byID[$0.key]?.filename ?? "") + ": " + $0.value }.joined(separator: "\n"))
            }
            if parts.isEmpty {
                Text(L10n.tr("Nothing to change")).foregroundStyle(.secondary)
            } else {
                parts.dropFirst().reduce(parts[0]) { $0 + Text("  -  ").foregroundStyle(.tertiary) + $1 }.fontWeight(.medium)
            }
        }.monospacedDigit().lineLimit(1)
    }

    // MARK: Bursts
    /// Every burst as a row of its frames on the left, so each burst and each decision shows at a glance, and the frame
    /// being looked at large on the right.
    private var bursts: some View {
        Group {
            if model.plan.bursts.isEmpty {
                ContentUnavailableView(model.stage == .ready ? L10n.tr("No Bursts") : L10n.tr("Looking for Bursts…"), systemImage: "square.stack.3d.down.right")
            } else {
                GeometryReader { geometry in
                    // The rows keep at least 360 points however wide the preview was left.
                    let range: ClosedRange<Double> = 320...max(320, min(1400, Double(geometry.size.width) - 365))
                    HStack(spacing: 0) {
                        rows.frame(minWidth: 360, maxWidth: .infinity)
                        SidebarResizeHandle(width: $previewWidth, range: range, defaultWidth: 480, panelOnRight: true)
                        preview.frame(width: min(range.upperBound, max(range.lowerBound, previewWidth)))
                    }
                }
            }
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Bursts apart by a line, not boxed.
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.plan.bursts.enumerated()), id: \.element.id) { index, burst in
                        if index > 0 { Rule().padding(.horizontal, 10) }
                        burstRow(burst).id(burst.id)
                    }
                }.padding(.vertical, 4)
            }
            .onChange(of: model.burstID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }.background(Theme.canvas)
    }

    /// A burst: its frames to pick from, folded to its cover when it is to be grouped, or a strip of small frames
    /// when it is skipped. Group and Skip in its header switch between them; with neither on, the burst is picked from.
    private func burstRow(_ burst: CullingPlan.Burst) -> some View {
        let current = burst.id == model.burstID, action = model.action(burst)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // The burst being looked at reads brighter.
                Text(L10n.tr("\(burst.members.count.formatted()) photos")).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(current ? Color.primary : Color.secondary)
                Text(captured(burst.members[0])).font(.system(size: 11)).foregroundStyle(current ? Color.secondary : Color.secondary.opacity(0.7)).lineLimit(1)
                if let series = burst.series {
                    Text(seriesCaption(series, burst)).font(.system(size: 11)).foregroundStyle(current ? Color.secondary : Color.secondary.opacity(0.7)).lineLimit(1)
                        .help(L10n.tr("Shot at a steady interval: grouped rather than picked from, so every frame stays for the timelapse or star trails"))
                }
                Spacer(minLength: 8)
                switch action {
                case .pick:
                    // What Apply does to this burst.
                    let picked = burst.members.filter { model.flag($0) == .accepted }.count
                    let rejected = burst.members.filter { model.flag($0) == .rejected }.count
                    (Text(L10n.tr("\(picked.formatted()) picked")).foregroundStyle(picked > 0 ? Theme.pick : Color.secondary)
                     + Text("  -  ").foregroundStyle(.tertiary)
                     + Text(L10n.tr("\(rejected.formatted()) rejected")).foregroundStyle(rejected > 0 ? Theme.reject : Color.secondary))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                case .group:
                    if model.isGrouped(burst) { Text(L10n.tr("Grouped")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                case .skip: EmptyView()
                }
                if !model.request.oneGroup {
                    HStack(spacing: 4) {
                        if model.isMerged(burst) {
                            BurstActionButton(title: L10n.tr("Split", context: "burst action")) { model.split(burst) }
                                .help(L10n.tr("Undo the merges in this group"))
                        }
                        if model.canMerge(burst) {
                            BurstActionButton(title: L10n.tr("Merge with Above")) { model.mergeWithAbove(burst) }
                                .help(L10n.tr("Join this group to the one above"))
                        }
                        BurstActionButton(title: L10n.tr("Group", context: "burst action"), on: action == .group) { model.toggle(burst, .group) }
                            .help(L10n.tr("Fold the burst under its key photo, flags as they are (G)"))
                        BurstActionButton(title: L10n.tr("Skip", context: "burst action"), on: action == .skip) { model.toggle(burst, .skip) }
                            .help(L10n.tr("Leave the burst as it is (S)"))
                    }
                }
            }
            switch action {
            case .pick:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 10)], alignment: .leading, spacing: 8) {
                    ForEach(burst.members, id: \.self) { id in frame(id, in: burst) }
                }
            // A burst to group folds to its cover, as the library will show it; it stays in the list.
            case .group: folded(burst)
            case .skip: strip(burst)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    /// A skipped burst, small and dimmed, so a run of them stays short. A click looks at a frame.
    private func strip(_ burst: CullingPlan.Burst) -> some View {
        let shown = burst.members.prefix(12)
        return HStack(spacing: 4) {
            ForEach(shown, id: \.self) { id in
                Color.black.aspectRatio(4 / 3, contentMode: .fit).frame(height: 40)
                    .overlay { thumbnail(id, fills: true) }
                    .clipped()
                    .selectionRing(id == model.focusedID ? Theme.accent : nil)
                    .contentShape(Rectangle())
                    .onTapGesture { model.burstID = burst.id; model.focusedID = id; keyFocus = true }
                    .contextMenu { frameMenu(id, in: burst) }
            }
            if burst.members.count > shown.count {
                Text("+\((burst.members.count - shown.count).formatted())").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.opacity(0.55)
    }

    /// One frame: a picked frame framed in green, a rejected one dimmed, the assistant's choice marked Best. A click looks at the frame; a click on the frame already being looked at switches it
    /// between picked and rejected.
    private func frame(_ id: String, in burst: CullingPlan.Burst) -> some View {
        let focused = id == model.focusedID
        let flag = model.flag(id)
        // A 4:3 tile whatever the frame's shape, so the badges sit in the same places on every frame.
        return Color.black.aspectRatio(4 / 3, contentMode: .fit)
            .overlay { thumbnail(id, fills: false).opacity(flag == .rejected ? 0.35 : 1) }
            .clipped()
            .overlay(Rectangle().strokeBorder(flag == .accepted ? Theme.pick : .clear, lineWidth: 1.5))
            // The frame being looked at gets an accent ring outside it.
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 1).padding(-4))
            .overlay(alignment: .topLeading) {
                if burst.best == id {
                    Text(L10n.tr("Best")).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).foregroundStyle(Theme.onAccent).padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.request.partners[id] != nil { PairBadge().padding(6) }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                keyFocus = true
                if focused { model.toggleKeep(id) } else { model.burstID = burst.id; model.focusedID = id }
            }
            .help(model.byID[id]?.filename ?? "")
            .contextMenu { frameMenu(id, in: burst) }
            .accessibilityElement(children: .contain).accessibilityLabel(model.byID[id]?.filename ?? "")
            .accessibilityValue(flag == .accepted ? L10n.tr("Picked") : flag == .rejected ? L10n.tr("Rejected") : "")
            .accessibilityAddTraits(focused ? .isSelected : [])
    }

    /// A burst to group as the library will show it: its cover alone, with the count of its frames. A click looks
    /// at the cover; ← and → go through the frames in the preview, to make another one the cover.
    private func folded(_ burst: CullingPlan.Burst) -> some View {
        let cover = model.cover(of: burst), shown = burst.id == model.burstID
        return Group {
            Color.black.aspectRatio(4 / 3, contentMode: .fit)
                .overlay { thumbnail(cover, fills: false) }
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(shown ? Theme.accent : .clear, lineWidth: 1).padding(-4))
                .overlay(alignment: .topLeading) {
                    Text(L10n.tr("Key Photo")).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).foregroundStyle(Theme.onAccent).padding(5)
                }
                .overlay(alignment: .bottomTrailing) {
                    Label(burst.members.count.formatted(), systemImage: "square.stack").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.6), in: Capsule()).environment(\.colorScheme, .dark).foregroundStyle(.white).padding(6)
                }
        }
        // One picture, a little smaller than the frames of a burst to pick from.
        .frame(width: 220)
        .contentShape(Rectangle())
        .onTapGesture { model.burstID = burst.id; model.focusedID = cover; keyFocus = true }
        .contextMenu { actionMenu(burst) }
        .help(L10n.tr("← → to look through the frames; Make Key Photo to show another"))
        .accessibilityElement(children: .ignore).accessibilityLabel(model.byID[cover]?.filename ?? "")
    }

    /// A frame's menu: what Space and the detail bar do, its flag, and its burst's action.
    @ViewBuilder private func frameMenu(_ id: String, in burst: CullingPlan.Burst) -> some View {
        Button(L10n.tr("Pick This")) { model.burstID = burst.id; model.focusedID = id; model.keepOnly(id) }
        if !model.request.oneGroup { Button(L10n.tr("Make Key Photo")) { model.burstID = burst.id; model.makeCover(id); model.focusedID = id } }
        Divider()
        ForEach([(ReviewState.accepted, L10n.tr("Pick")), (.rejected, L10n.tr("Reject")), (.unreviewed, L10n.tr("Unflagged"))], id: \.0) { state, title in
            Toggle(title, isOn: Binding(get: { model.flag(id) == state }, set: { _ in model.set(id, state) }))
        }
        actionMenu(burst)
    }
    /// The burst's Group and Skip, as in its row.
    @ViewBuilder private func actionMenu(_ burst: CullingPlan.Burst) -> some View {
        if !model.request.oneGroup {
            Divider()
            Toggle(L10n.tr("Group", context: "burst action"), isOn: Binding(get: { model.action(burst) == .group }, set: { _ in model.toggle(burst, .group) }))
            Toggle(L10n.tr("Skip", context: "burst action"), isOn: Binding(get: { model.action(burst) == .skip }, set: { _ in model.toggle(burst, .skip) }))
            Divider()
            Button(L10n.tr("Merge with Above")) { model.mergeWithAbove(burst) }.disabled(!model.canMerge(burst))
            if model.isMerged(burst) { Button(L10n.tr("Split", context: "burst action")) { model.split(burst) } }
        }
    }


    // MARK: Preview
    /// The photo with what was measured floating over its top, and what can be done to it in a bar below.
    @ViewBuilder private var preview: some View {
        if let id = model.focusedID, let asset = model.byID[id] {
            VStack(spacing: 0) {
                CullingPreview(asset: asset, report: model.reports[id]?.report, root: catalog.root, previews: catalog.previews)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        info(asset)
                            .environment(\.colorScheme, .dark)
                            // No panel: a shadow keeps the text readable on a light photo.
                            .shadow(color: .black.opacity(0.8), radius: 2)
                            // Clear of the zoom button in the corner.
                            .padding(.leading, 12).padding(.top, 12).padding(.trailing, 52)
                    }
                Rule()
                actions(asset)
            }
        } else {
            Theme.imageSurround.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The photo's name, its problems and its measurements.
    private func info(_ asset: CatalogAsset) -> some View {
        let report = model.reports[asset.id]?.report
        // A frame not kept is a fault only when picking from its burst.
        let picking = model.burst.map { model.action($0) == .pick } ?? true
        let issues = model.plan.issues[asset.id, default: []].filter { picking || !$0.inBurst }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(asset.filename).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                ForEach(issues) { issue in Label(issue.title, systemImage: issue.symbol).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(1) }
            }
            if let report {
                HStack(spacing: 14) {
                    metric(L10n.tr("Sharpness"), report.sharpness.map(percent) ?? "–")
                    metric(L10n.tr("Subject"), report.subjectSharpness.map(percent) ?? "–")
                    metric(L10n.tr("Brightness"), percent(report.brightness))
                    metric(L10n.tr("Clipped"), String(format: "%.1f%%", locale: Locale.current, report.highlights * 100))
                    if !report.faces.isEmpty { metric(L10n.tr("Faces"), report.faces.count.formatted()) }
                    if let aesthetics = report.aesthetics { metric(L10n.tr("Appeal"), String(format: "%+.2f", locale: Locale.current, aesthetics)) }
                }
            } else if let reason = model.unmeasured[asset.id] {
                Text(reason).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
    }

    /// The photo's Pick and Reject, Make Key Photo and Pick This.
    private func actions(_ asset: CatalogAsset) -> some View {
        HStack(spacing: 8) {
            flagButtons(asset.id, size: 13)
            Spacer(minLength: 0)
            if !model.request.oneGroup {
                Button(L10n.tr("Make Key Photo")) { model.makeCover(asset.id) }.buttonStyle(.secondaryAction).controlSize(.small)
                    .disabled(model.burst.map { model.action($0) == .group && model.cover(of: $0) == asset.id } ?? true)
                    .help(L10n.tr("Group the burst under this photo"))
            }
            Button(L10n.tr("Pick This")) { model.keepOnly(asset.id) }.buttonStyle(.secondaryAction).controlSize(.small)
                .help(L10n.tr("Pick this photo, reject the rest of the burst and go to the next (Space)"))
        }.padding(.horizontal, 12).padding(.vertical, 10).background(Theme.panel)
    }
    private func percent(_ value: Double) -> String { min(100, Int((value * 100).rounded())).formatted() }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    // MARK: Shared
    private func flagButtons(_ id: String, size: CGFloat) -> some View {
        let flag = model.flag(id)
        return HStack(spacing: 0) {
            ForEach([ReviewState.accepted, .rejected], id: \.self) { state in
                Button { model.toggle(id, state) } label: {
                    ReviewFlag(state: state, active: flag == state, size: size,
                               color: flag == state ? (state == .accepted ? Theme.pick : Theme.reject) : nil).frame(width: size * 2.2, height: size * 2.2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help(state == .accepted ? L10n.tr("Pick (P)") : L10n.tr("Reject (X)"))
                    .accessibilityLabel(state == .accepted ? L10n.tr("Pick") : L10n.tr("Reject")).accessibilityAddTraits(flag == state ? .isSelected : [])
            }
        }
    }
    private func thumbnail(_ id: String, fills: Bool) -> some View {
        Group {
            if let asset = model.byID[id] { CatalogThumbnail(asset: asset, previews: catalog.previews, fillsFrame: fills) } else { Color.black }
        }
    }
    /// "Timelapse - every 17 s - 15 s exposures - 8 missing": the interval as the camera kept it, the shutter time most
    /// frames share, and the frames the small holes in the sequence leave out.
    private func seriesCaption(_ series: BurstDetector.Series, _ burst: CullingPlan.Burst) -> String {
        let every = PhotoMetadataSummary.shutter(series.interval >= 10 ? series.interval.rounded() : series.interval)
        var parts = [L10n.tr("Timelapse"), L10n.tr("every \(every)")]
        let shutters = burst.members.compactMap { model.byID[$0]?.exposureTime }.sorted()
        if !shutters.isEmpty { parts.append(L10n.tr("\(PhotoMetadataSummary.shutter(shutters[shutters.count / 2])) exposures")) }
        if series.missingFrames > 0 { parts.append(L10n.tr("\(series.missingFrames.formatted()) missing")) }
        return parts.joined(separator: "  -  ")
    }
    private func captured(_ id: String) -> String {
        guard let time = model.byID[id]?.captureTime, time.count >= 19 else { return "" }
        return CaptureDateNode.title(for: String(time.prefix(10)), full: true) + " " + String(time.suffix(8))
    }
}

/// A small text button. As a switch (`on` set) it is lit while on: a stronger fill and full-strength text, the same
/// size either way so nothing beside it moves. Without `on` it is a plain action.
struct BurstActionButton: View {
    let title: String
    var on: Bool? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(on == false ? Color.secondary : Color.primary)
                .background(Theme.ink.opacity(on == true ? 0.24 : on == false ? 0.07 : 0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityAddTraits(on == true ? .isSelected : [])
    }
}

extension CullingIssue {
    var symbol: String {
        switch self {
        case .blurry: "aqi.medium"
        case .outOfFocus: "scope"
        case .overexposed: "sun.max.fill"
        case .underexposed: "moon.fill"
        case .eyesClosed: "eye.slash"
        case .burstAlternate: "square.stack"
        case .duplicate: "plus.square.on.square"
        }
    }
}

/// A larger look at one photo from its original, undeveloped, to zoom into and move around, with the subject and faces
/// outlined while the pointer is over it. The button in the corner zooms to the subject to judge its focus.
struct CullingPreview: View {
    let asset: CatalogAsset
    let report: PhotoQualityReport?
    let root: URL?
    let previews: PreviewStore?
    @State private var target: ZoomTarget?
    /// The subject and faces are outlined only while the pointer is over the photo, so they don't sit on it otherwise.
    @State private var hovering = false

    private var region: CGRect? {
        guard let subject = report?.subject else { return nil }
        // Room around the subject, and never closer than a quarter of the frame.
        let width = min(1, max(0.25, subject.width * 1.4)), height = min(1, max(0.25, subject.height * 1.4))
        return CGRect(x: min(1 - width, max(0, subject.midX - width / 2)), y: min(1 - height, max(0, subject.midY - height / 2)), width: width, height: height)
    }
    var body: some View {
        OriginalPreview(asset: asset, root: root, previews: previews, target: target) { _ in
            if hovering { outlines }
        }
        .overlay(alignment: .topTrailing) {
            if let region {
                Button { target = .fill(region) } label: { Image(systemName: "viewfinder") }
                    .buttonStyle(.secondaryAction).controlSize(.small).padding(10)
                    .help(L10n.tr("Zoom to the subject to check its focus"))
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: asset.id) { target = nil }
    }
    private var outlines: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let subject = report?.subject {
                Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.white.opacity(0.7))
                    .frame(width: subject.width * size.width, height: subject.height * size.height)
                    .offset(x: subject.minX * size.width, y: subject.minY * size.height)
            }
            ForEach(Array((report?.faces ?? []).enumerated()), id: \.offset) { _, face in
                RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Theme.accent, lineWidth: 1.5)
                    .frame(width: face.bounds.width * size.width, height: face.bounds.height * size.height)
                    .offset(x: face.bounds.minX * size.width, y: face.bounds.minY * size.height)
            }
        }.allowsHitTesting(false)
    }
}
