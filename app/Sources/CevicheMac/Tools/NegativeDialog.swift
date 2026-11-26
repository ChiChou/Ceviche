import SwiftUI
import CevicheCore

/// What the Convert Negative dialog shows: one scan with its frame's corners to move, as the negative or inverted in
/// place. Each scan keeps its own frame and history while the dialog is open; film, orientation and film base are
/// each scan's own too, unless the scans are balanced as one roll, which shares them and measures one inversion
/// on every scan to convert.
@MainActor
final class NegativeModel: ObservableObject {
    enum Stage: Equatable { case loading, ready, failed(String) }
    /// One step of a scan's history.
    struct State: Equatable { var frame: FrameQuad; var film: NegativeFilm; var orientation: NegativeOrientation; var base: SIMD3<Float>? }

    let request: NegativeRequest
    @Published private(set) var stage = Stage.loading
    /// The scan previewed, by position in the request.
    @Published var index = 0 { didSet { if index != oldValue { remember(request.assets[oldValue]); load() } } }
    @Published private(set) var scan: CGImage?
    /// The scan inverted as the frame measures it, while `invert` is on.
    @Published private(set) var inverted: CGImage?
    @Published private(set) var rendering = false
    @Published var invert = UserDefaults.standard.bool(forKey: "negativeInvert") {
        didSet { UserDefaults.standard.set(invert, forKey: "negativeInvert"); renderInverted() }
    }
    @Published private(set) var frame = FrameQuad.full {
        didSet { if frame != oldValue { if isRoll { if dragStart == nil { measureRoll() } } else { renderInverted() } } }
    }
    @Published private(set) var film = NegativeFilm.color { didSet { if film != oldValue { rememberRoll(); rebalance() } } }
    @Published private(set) var orientation = NegativeOrientation() { didSet { if orientation != oldValue { rememberRoll() } } }
    /// Film base picked on unexposed film at an exposure of 1, instead of the one read around each frame.
    @Published private(set) var base: SIMD3<Float>? { didSet { if base != oldValue { rememberRoll(); rebalance() } } }
    /// Waiting for a click on unexposed film.
    @Published var pickingBase = false
    /// Balance every scan to convert as one roll.
    @Published var roll = UserDefaults.standard.object(forKey: "negativeRoll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(roll, forKey: "negativeRoll"); if roll { measureRoll() } else { rollTask?.cancel(); measuring = nil; rollInversions = nil; apart = []; proposedRolls = []; renderInverted() } }
    }
    /// Each scan's inversion from the roll once every scan to convert is measured.
    @Published private(set) var rollInversions: [String: NegativeInversion]?
    /// Scans in the roll whose film base doesn't match the others', converted on their own.
    @Published private(set) var apart: Set<String> = []
    /// The rolls the measured scans look like, by capture order, settings and film base: a proposal to split the
    /// selection, never applied on its own.
    @Published private(set) var proposedRolls: [[String]] = []
    /// The scans that begin a roll once the selection is split; nil balances every scan as one roll.
    @Published private(set) var rollStarts: Set<String>?
    /// Whether the proposal was taken or turned down.
    @Published private(set) var rollsDecided = false
    /// Scans measured so far and how many, while the roll is measured.
    @Published private(set) var measuring: (done: Int, total: Int)?
    /// The paper color negatives are printed on, for every scan; nil inverts them.
    @Published var print: NegativePrint? = NegativeModel.savedPrint {
        didSet {
            UserDefaults.standard.set(print.flatMap { try? JSONEncoder().encode($0) }, forKey: "negativePrint")
            if print != oldValue { renderInverted() }
        }
    }
    private static var savedPrint: NegativePrint? {
        UserDefaults.standard.data(forKey: "negativePrint").flatMap { try? JSONDecoder().decode(NegativePrint.self, from: $0) }
    }
    @Published private(set) var undoStack: [State] = []
    @Published private(set) var redoStack: [State] = []
    /// Scans left out of the conversion; they can still be previewed.
    @Published private(set) var excluded: Set<String> = []
    private(set) var detected: FrameQuad?
    private var choices: [String: NegativeChoice] = [:]
    private var histories: [String: (undo: [State], redo: [State])] = [:]
    /// The frame when the corner being dragged was picked up.
    private var dragStart: FrameQuad?
    private weak var catalog: CatalogModel?
    private var previewer: NegativePreviewer?
    private var access: URL?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var rollTask: Task<Void, Never>?
    private var balanceTask: Task<Void, Never>?
    /// Each scan's part of the roll's measurement, in the frame it was measured in.
    private var samples: [String: NegativeSample] = [:]
    /// Each roll's shared film, orientation and base, by its first scan, so they carry over to the roll's other scans.
    private var rollStates: [String: State] = [:]
    /// Each scan's capture time and session settings, read when it is measured.
    private var sessions: [String: (captured: Date?, settings: String, camera: String)] = [:]
    /// False while a scan is loading, so the values it loads with aren't taken for a change to its roll.
    private var remembersRoll = true

    init(request: NegativeRequest) { self.request = request }

    var asset: CatalogAsset { request.assets[index] }
    private var state: State { State(frame: frame, film: film, orientation: orientation, base: base) }
    /// The scans to convert, in the request's order.
    var included: [CatalogAsset] { request.assets.filter { !excluded.contains($0.id) } }
    /// Whether the scans are balanced as one roll; a single scan is always its own.
    var isRoll: Bool { roll && request.assets.count > 1 }
    /// The scans to convert as the rolls they are balanced in: one, unless the selection was split.
    var rolls: [[CatalogAsset]] { NegativeRoll.rolls(included, id: \.id, starts: rollStarts) }
    /// What a scan's roll is known by: its first scan.
    private func rollKey(_ id: String) -> String { rolls.first { $0.contains { $0.id == id } }?.first?.id ?? id }
    /// Whether a scan begins a roll other than the first.
    func startsRoll(_ id: String) -> Bool { rolls.dropFirst().contains { $0.first?.id == id } }
    /// The number of the roll a scan is in, from 1.
    func rollNumber(_ id: String) -> Int? { rolls.firstIndex { $0.contains { $0.id == id } }.map { $0 + 1 } }
    private func rememberRoll() {
        guard isRoll, remembersRoll, stage == .ready else { return }
        rollStates[rollKey(asset.id)] = state
    }
    /// Splits the selection into the proposed rolls, or keeps it as one.
    func decideRolls(split: Bool) {
        rollsDecided = true
        guard split, proposedRolls.count > 1 else { return }
        // The roll on screen keeps what was set on it.
        let shared = rollStates[rollKey(asset.id)]
        rollStarts = Set(proposedRolls.compactMap(\.first))
        if let shared { rollStates[rollKey(asset.id)] = shared }
        balanceRoll()
    }
    /// Starts a roll at this scan, or joins it to the roll before.
    func toggleRollStart(_ id: String) {
        guard isRoll, included.first?.id != id, included.contains(where: { $0.id == id }) else { return }
        rollsDecided = true
        var starts = rollStarts ?? []
        if starts.contains(id) { starts.remove(id) } else { starts.insert(id) }
        rollStarts = starts.isEmpty ? nil : starts
        balanceRoll()
    }
    /// Whether everything converting needs is measured.
    var canConvert: Bool { stage != .loading && (!isRoll || rollInversions != nil) }
    /// Whether the scan's frame, film or orientation was changed here rather than left as detected.
    func changed(_ id: String) -> Bool { id == asset.id ? !undoStack.isEmpty : !(histories[id]?.undo.isEmpty ?? true) }
    /// Leaves a scan out of the conversion or takes it back; the last scan left can't go.
    func toggle(_ id: String) {
        if excluded.contains(id) { excluded.remove(id) } else if included.count > 1 { excluded.insert(id) }
        measureRoll()
    }
    /// Previews the scan `offset` places along, staying within the request.
    func step(_ offset: Int) { index = min(request.assets.count - 1, max(0, index + offset)) }

    func start(catalog: CatalogModel) {
        guard self.catalog == nil else { return }
        self.catalog = catalog
        catalog.negativeHistory = self
        load()
    }
    func stop() {
        loadTask?.cancel(); renderTask?.cancel(); rollTask?.cancel(); balanceTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
        if catalog?.negativeHistory === self { catalog?.negativeHistory = nil }
    }
    /// Every scan's choices, the one on screen included.
    func allChoices() -> [String: NegativeChoice] {
        if stage == .ready { remember(asset) }
        return NegativeRoll.choices(request.assets.map(\.id), kept: choices, samples: samples, inversions: isRoll ? rollInversions : nil,
                                    shared: { self.rollShared(self.rollKey($0)) }, print: print)
    }
    /// What a roll's scans share, by the roll's first scan.
    private func rollShared(_ key: String) -> NegativeRollShared? {
        rollStates[key].map { NegativeRollShared(film: $0.film, orientation: $0.orientation, base: $0.base) }
    }
    private func remember(_ asset: CatalogAsset) {
        guard previewer != nil else { return }
        choices[asset.id] = NegativeChoice(frame: frame, film: film, orientation: orientation, base: base)
        histories[asset.id] = (undoStack, redoStack)
    }

    /// What the crop shows: the inverted scan once there is one, else the negative.
    var shown: CGImage? { invert ? inverted ?? scan : scan }

    // MARK: Changes

    /// Moves one corner while it is dragged; the whole drag is one step of history.
    func drag(corner: Int, to point: CGPoint) {
        var moved = frame
        moved.corners[corner] = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        guard moved.isValid else { return }
        if dragStart == nil { dragStart = frame }
        frame = moved
    }
    func endDrag() {
        if let dragStart, dragStart != frame { record(State(frame: dragStart, film: film, orientation: orientation, base: base)) }
        dragStart = nil
        if isRoll { measureRoll() }
    }
    func resetFrame() {
        guard let detected, detected != frame else { return }
        record(state); frame = detected
    }
    func setFilm(_ new: NegativeFilm) {
        guard new != film else { return }
        record(state); film = new
    }
    /// Takes the film base from unexposed film at `point` on the scan.
    func pickBase(at point: CGPoint) {
        pickingBase = false
        guard stage == .ready, let previewer, dragStart == nil else { return }
        let color = previewer.base(at: CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))))
        guard color.min() > 0 else { return }
        record(state); base = color
    }
    /// Reads the film base around the frame again.
    func clearBase() {
        guard stage == .ready, base != nil else { return }
        record(state); base = nil
    }
    func rotate(clockwise: Bool) {
        guard stage == .ready, dragStart == nil else { return }
        record(state); orientation = orientation.rotated(clockwise: clockwise)
    }
    func flip(horizontal: Bool) {
        guard stage == .ready, dragStart == nil else { return }
        record(state); orientation = orientation.flipped(horizontal: horizontal)
    }
    private func record(_ old: State) { undoStack.append(old); redoStack = [] }
    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }
    private func step(from: inout [State], to: inout [State]) {
        guard stage == .ready, dragStart == nil, let target = from.popLast() else { return }
        to.append(state)
        frame = target.frame; film = target.film; orientation = target.orientation; base = target.base
    }

    // MARK: Rendering

    private func load() {
        guard let catalog else { return }
        loadTask?.cancel(); renderTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
        previewer = nil; scan = nil; inverted = nil; dragStart = nil; stage = .loading
        let asset = self.asset
        (undoStack, redoStack) = histories[asset.id] ?? ([], [])
        loadTask = Task {
            do {
                let url = try await catalog.resolveOriginal(asset)
                if url.startAccessingSecurityScopedResource() { access = url }
                let previewer = try await Task.detached(priority: .userInitiated) { try autoreleasepool { try NegativePreviewer(url) } }.value
                guard !Task.isCancelled else { return }
                let saved = choices[asset.id]
                let frame = saved?.frame ?? previewer.detected
                // A roll keeps the film, orientation and base it had on the scan before.
                let shared = isRoll ? rollStates[rollKey(asset.id)] : nil
                let film = await Task.detached(priority: .userInitiated) { shared?.film ?? saved?.film ?? previewer.suggestedFilm(frame) }.value
                guard !Task.isCancelled else { return }
                sessions[asset.id] = NegativeRollScan.session(url)
                self.previewer = previewer; detected = previewer.detected; scan = previewer.scan
                remembersRoll = false
                orientation = shared?.orientation ?? saved?.orientation ?? NegativeOrientation(); base = shared.map(\.base) ?? saved?.base
                self.frame = frame; self.film = film
                remembersRoll = true
                stage = .ready
                rememberRoll()
                if isRoll { measureRoll() }
                renderInverted()
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(error.localizedDescription)
                if request.assets.count == 1 { close(with: Failure(L10n.tr("Couldn’t Convert the Negatives"), error)) }
            }
        }
    }
    /// The only photo couldn't be read: there is nothing to work with, so the tool closes and says why. With several,
    /// the failure stays on that photo and the others can still be used.
    private func close(with failure: Failure) {
        guard let catalog else { return }
        stop(); catalog.negative = nil; catalog.failure = failure
    }

    /// Shows the scan inverted again after its film or base changed, or the roll's inversion once it is measured anew.
    private func rebalance() { if isRoll { balanceRoll() } else { renderInverted() } }

    private func renderInverted() {
        renderTask?.cancel()
        guard invert else { rendering = false; return }
        guard let previewer, frame.isValid else { return }
        let roll = isRoll ? rollInversions?[asset.id] : nil
        // A roll still being measured keeps the preview it has.
        guard !isRoll || roll != nil else { rendering = true; return }
        let frame = self.frame, film = self.film, base = self.base, print = self.print
        rendering = true
        renderTask = Task {
            // Dragging a corner moves it many times a second; only where it rests is rendered.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) {
                try? roll.map { try previewer.inverted($0, print: print) } ?? previewer.inverted(frame, film: film, base: base, print: print)
            }.value
            guard !Task.isCancelled else { return }
            if let image { inverted = image }
            rendering = false
        }
    }
}

// MARK: Roll

extension NegativeModel {
    /// The frame a scan is converted in, if it was looked at here.
    private func knownFrame(_ asset: CatalogAsset) -> FrameQuad? {
        asset.id == self.asset.id && stage == .ready ? frame : choices[asset.id]?.frame
    }

    /// Measures the scans to convert that have no sample in their frame yet, one after another, then balances the roll.
    fileprivate func measureRoll() {
        rollTask?.cancel()
        guard isRoll, let catalog else { return }
        let missing = included.filter { NegativeRoll.needsSample(samples[$0.id], frame: knownFrame($0)) }
        guard !missing.isEmpty else { measuring = nil; balanceRoll(); return }
        rollInversions = nil
        rollTask = Task {
            for (number, asset) in missing.enumerated() {
                measuring = (number, missing.count)
                let frame = knownFrame(asset)
                do {
                    let sample: NegativeSample
                    if asset.id == self.asset.id, stage == .ready, let previewer {
                        let frame = frame ?? previewer.detected
                        sample = await Task.detached(priority: .userInitiated) { previewer.rollSample(frame) }.value
                    } else {
                        let url = try await catalog.resolveOriginal(asset)
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        sample = try await Task.detached(priority: .userInitiated) { try autoreleasepool { try NegativeConverter.rollSample(url, frame: frame) } }.value
                        if sessions[asset.id] == nil { sessions[asset.id] = await Task.detached(priority: .userInitiated) { NegativeRollScan.session(url) }.value }
                    }
                    guard !Task.isCancelled else { return }
                    samples[asset.id] = sample
                } catch {
                    // A scan that can't be read is left out of the measurement; converting reports it.
                    if Task.isCancelled { return }
                }
            }
            measuring = nil
            balanceRoll()
        }
    }

    /// One inversion from every measured scan to convert, with the roll's film and base.
    fileprivate func balanceRoll() {
        balanceTask?.cancel()
        guard isRoll, measuring == nil else { return }
        rollInversions = nil
        // Each roll on its own, with the film and base set on it; a roll never looked at is measured as it comes.
        let groups = NegativeRoll.groups(rolls.map { $0.map(\.id) }, samples: samples, shared: rollShared)
        guard !groups.isEmpty else { return }
        let scans = included.compactMap { asset -> (id: String, scan: NegativeRollScan)? in
            guard let sample = samples[asset.id], let session = sessions[asset.id] else { return nil }
            return (asset.id, NegativeRoll.rollScan(sample, session: session))
        }
        balanceTask = Task {
            let result = await Task.detached(priority: .userInitiated) { NegativeRoll.balance(groups, scans: scans) }.value
            guard !Task.isCancelled else { return }
            rollInversions = result.inversions; apart = result.apart; proposedRolls = result.proposed
            renderInverted()
        }
    }
}

/// Edit › Undo and Redo while the Convert Negative dialog is open.
struct NegativeUndoCommands: View {
    @ObservedObject var model: NegativeModel
    var body: some View {
        Button(L10n.tr("Undo"), action: model.undo).keyboardShortcut("z").disabled(model.undoStack.isEmpty)
        Button(L10n.tr("Redo"), action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(model.redoStack.isEmpty)
    }
}

struct NegativeDialog: View {
    @ObservedObject var catalog: CatalogModel
    @StateObject private var model: NegativeModel
    /// The scan strip's height, kept across launches.
    @AppStorage("negativeStripHeight") private var stripHeight = 112.0
    private static var stripHeights: ClosedRange<Double> { 84...240 }
    init(catalog: CatalogModel, request: NegativeRequest) {
        self.catalog = catalog
        _model = StateObject(wrappedValue: NegativeModel(request: request))
    }

    var body: some View {
        let count = model.included.count
        ToolWorkspace(title: L10n.tr("Convert Negative"), status: summary,
                      primary: count == 1 ? L10n.tr("Convert 1 Negative") : L10n.tr("Convert \(count) Negatives"),
                      primaryDisabled: !catalog.canStartJob || !model.canConvert, cancel: close,
                      action: { catalog.startNegative(model.included, choices: model.allChoices()); close() },
                      escape: { if model.pickingBase { model.pickingBase = false } else { close() } }) {
            controls
        } content: {
            VStack(spacing: 0) {
                Group {
                    switch model.stage {
                    case .loading:
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("Developing \(model.asset.filename)…")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .ready:
                        cropPane.padding(16)
                            .overlay(alignment: .topTrailing) { if model.invert && model.rendering { ProgressView().controlSize(.small).padding(16) } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.request.assets.count > 1 { Rule(); strip.padding(.horizontal, 16).padding(.vertical, 8).background(Theme.panel) }
            }
        }
        .onAppear { model.start(catalog: catalog) }
        .onDisappear { model.stop() }
    }

    private func close() { model.stop(); catalog.negative = nil }

    private var summary: String {
        let photos = model.request.assets
        return photos.count == 1 ? photos[0].filename : L10n.tr("\(photos.count) photos")
    }

    // MARK: Crop

    /// The negative with the frame's corners, each dragged on its own.
    private var cropPane: some View {
        fitted(model.shown) { size in
            let corners = model.frame.corners.map { model.orientation.displayPoint($0) }
                .map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            ZStack(alignment: .topLeading) {
                // A click on unexposed film while picking the base.
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named("scan")).onEnded {
                        model.pickBase(at: model.orientation.scanPoint(CGPoint(x: $0.location.x / size.width, y: $0.location.y / size.height)))
                    }, including: model.pickingBase ? .all : .none)
                    .onContinuousHover { phase in
                        guard model.pickingBase else { return }
                        if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                    }
                // Outside the frame dimmed.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addLines(corners); path.closeSubpath()
                }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { path in path.addLines(corners); path.closeSubpath() }
                    .stroke(Color.white, lineWidth: 1.5).shadow(radius: 1)
                ForEach(0..<4, id: \.self) { corner in
                    Circle().fill(Color.white).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                        .frame(width: 28, height: 28).contentShape(Circle())
                        .position(corners[corner])
                        .gesture(DragGesture(coordinateSpace: .named("scan"))
                            .onChanged { model.drag(corner: corner, to: model.orientation.scanPoint(CGPoint(x: $0.location.x / size.width, y: $0.location.y / size.height))) }
                            .onEnded { _ in model.endDrag() })
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: "scan")
        }
    }

    /// `image` as large as fits, with `overlay` laid over it in its own size.
    private func fitted(_ image: CGImage?, @ViewBuilder overlay: @escaping (CGSize) -> some View) -> some View {
        let swaps = model.orientation.swapsDimensions
        let aspect = image.map { swaps ? CGFloat($0.height) / CGFloat(max(1, $0.width)) : CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1.5
        return GeometryReader { geometry in
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: swaps ? geometry.size.height : geometry.size.width, height: swaps ? geometry.size.width : geometry.size.height)
                    .rotationEffect(.degrees(Double(model.orientation.quarterTurns) * 90))
                    .scaleEffect(x: model.orientation.mirrored ? -1 : 1, y: 1)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .topLeading) { overlay(geometry.size) }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    /// Inverted, or printed on a paper or print film from the Darkroom with the stock the roll was shot on.
    private var printMenu: some View {
        let catalog = FilmCatalog.shared
        let stock = model.print?.stock ?? NegativePrint.defaultStock
        let media = catalog.printMedia(for: stock)
        return Menu {
            Toggle(L10n.tr("Invert"), isOn: Binding(get: { model.print == nil }, set: { if $0 { model.print = nil } }))
            Section(L10n.tr("Paper")) {
                ForEach(media) { paper in
                    Toggle(paper.name, isOn: Binding(get: { model.print?.paper == paper.id }, set: { if $0 { model.print = NegativePrint(stock: stock, paper: paper.id) } }))
                }
            }
            if let print = model.print {
                Section(L10n.tr("Stock")) {
                    ForEach(catalog.films.filter { !$0.isPositive && !$0.isMonochrome }) { film in
                        Toggle(film.name, isOn: Binding(get: { print.stock == film.id }, set: { if $0 { model.print?.stock = film.id } }))
                    }
                }
            }
        } label: {
            Text(model.print.flatMap { print in media.first { $0.id == print.paper }?.name } ?? L10n.tr("Invert")).lineLimit(1)
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 9)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).nativeMenuItems().fixedSize().help(L10n.tr("Print"))
    }
    /// Preview and frame tools above the preview, drawn like the footer's buttons.
    private var controls: some View {
        HStack(spacing: 8) {
            ToolPill {
                ToolSegment(on: model.invert, help: L10n.tr("Invert")) { model.invert.toggle() } label: { Image(systemName: "circle.lefthalf.filled") }
            }
            ToolPill {
                ForEach(NegativeFilm.allCases, id: \.self) { film in
                    ToolSegment(on: model.film == film, help: film.localizedTitle) { model.setFilm(film) } label: { Text(film.localizedTitle) }
                }
            }
            if model.film == .color { ToolPill { printMenu }.disabled(model.stage != .ready) }
            ToolPill {
                ToolSegment(on: model.pickingBase, help: L10n.tr("Pick film base")) { model.pickingBase.toggle() } label: { Image(systemName: "eyedropper") }
                if let picked = model.base {
                    // The picked color at full brightness; its level depends on the exposure it is given at.
                    let base = picked / max(1e-6, picked.max())
                    ToolSegment(help: L10n.tr("Film base - click to measure it again")) { model.clearBase() } label: {
                        RoundedRectangle(cornerRadius: Theme.Radius.tag)
                            .fill(Color(.sRGBLinear, red: Double(base.x), green: Double(base.y), blue: Double(base.z)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag).strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                            .frame(width: 14, height: 14)
                    }
                }
            }.disabled(model.stage != .ready)
            if model.request.assets.count > 1 {
                ToolPill {
                    ToolSegment(on: model.roll, help: L10n.tr("Balance the scans as one roll")) { model.roll.toggle() } label: {
                        Label(L10n.tr("Roll"), systemImage: "film.stack")
                    }
                }
                if let measuring = model.measuring {
                    ProgressView(value: Double(measuring.done), total: Double(max(1, measuring.total))).controlSize(.small).frame(width: 60)
                        .help(L10n.tr("Measuring \(measuring.done + 1) of \(measuring.total)"))
                } else if model.isRoll, !model.rollsDecided, model.proposedRolls.count > 1 {
                    // The scans look like several rolls: offered, never applied unasked.
                    ToolPill {
                        ToolSegment(help: L10n.tr("Balance each roll on its own. Rolls are told apart by capture order, camera settings and film base.")) { model.decideRolls(split: true) } label: {
                            Text(L10n.tr("Split into \(model.proposedRolls.count) Rolls"))
                        }
                        ToolSegment(help: L10n.tr("Keep the scans as one roll")) { model.decideRolls(split: false) } label: { Image(systemName: "xmark") }
                    }
                }
            }
            ToolPill {
                ToolSegment(help: L10n.tr("Auto Frame")) { model.resetFrame() } label: { Text(L10n.tr("Auto Frame")) }
            }.disabled(model.stage != .ready || model.detected == nil || model.detected == model.frame)
            ToolPill {
                ToolSegment(help: L10n.tr("Rotate left")) { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                ToolSegment(help: L10n.tr("Rotate right")) { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
            }.disabled(model.stage != .ready)
            ToolPill {
                ToolSegment(help: L10n.tr("Flip horizontal")) { model.flip(horizontal: true) } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                ToolSegment(help: L10n.tr("Flip vertical")) { model.flip(horizontal: false) } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
            }.disabled(model.stage != .ready)
            Spacer(minLength: 0)
            ToolPill {
                ToolSegment(help: L10n.tr("Undo")) { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty)
                ToolSegment(help: L10n.tr("Redo")) { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty)
            }
        }
    }

    // MARK: Scans

    /// Every scan under the preview: a click previews it, ← and → step through them, and the checkbox leaves one out of
    /// the conversion. A dot marks the scans whose frame, film or orientation was changed here.
    private var strip: some View {
        let height = min(Self.stripHeights.upperBound, max(Self.stripHeights.lowerBound, stripHeight))
        return VStack(spacing: 0) {
            FilmstripResizeHandle(height: $stripHeight, range: Self.stripHeights, defaultHeight: 112).zIndex(1)
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(model.request.assets.enumerated()), id: \.element.id) { index, asset in
                            if model.isRoll, model.startsRoll(asset.id) { Rule(.vertical).frame(height: height - 30).padding(.horizontal, 4) }
                            scanCell(asset, index: index, side: height - 30).id(asset.id)
                        }
                    }.padding(.vertical, 6)
                }
                .onChange(of: model.index) { _, index in
                    withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(model.request.assets[index].id, anchor: .center) }
                }
            }.frame(height: height)
        }
        .background {
            // ← and → step through the scans wherever the focus is.
            Button("") { model.step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).opacity(0)
            Button("") { model.step(1) }.keyboardShortcut(.rightArrow, modifiers: []).opacity(0)
        }
    }

    private func scanCell(_ asset: CatalogAsset, index: Int, side: CGFloat) -> some View {
        let shown = index == model.index, included = !model.excluded.contains(asset.id)
        return VStack(alignment: .leading, spacing: 4) {
            CatalogThumbnail(asset: asset, previews: catalog.previews)
                .frame(width: side * 1.5, height: side).background(Color.black.opacity(0.22))
                .clipped()
                .selectionRing(shown ? Theme.accent : nil)
                .opacity(included ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    if model.changed(asset.id) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(5)
                            .help(L10n.tr("Changed here"))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.isRoll, model.apart.contains(asset.id) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.warning)
                            .padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.tag)).environment(\.colorScheme, .dark).padding(3)
                            .help(L10n.tr("Different film base - converted on its own"))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.index = index }
                .contextMenu {
                    if model.isRoll, included, model.included.first?.id != asset.id {
                        Button(model.startsRoll(asset.id) ? L10n.tr("Join Previous Roll") : L10n.tr("Start New Roll Here")) { model.toggleRollStart(asset.id) }
                    }
                }
                .help(model.isRoll && model.rollStarts != nil ? L10n.tr("\(asset.filename) - roll \(model.rollNumber(asset.id) ?? 1)") : asset.filename)
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { included }, set: { _ in model.toggle(asset.id) })) { EmptyView() }
                    .labelsHidden().toggleStyle(.formCheckbox).controlSize(.small)
                    .disabled(included && model.included.count == 1).help(L10n.tr("Convert this scan"))
                Text(asset.filename).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.frame(width: side * 1.5, alignment: .leading)
        }
    }
}

/// A group of toolbar segments on one quiet fill, the size and shape of the footer's Cancel button.
private struct ToolPill<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 0) { content }.padding(2).frame(height: 30)
            .background(Theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

/// One button in a `ToolPill`: lit with the accent while it is on, like a chosen segment.
private struct ToolSegment<Content: View>: View {
    var on = false
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            label.font(.system(size: 12, weight: .medium)).foregroundStyle(on ? Theme.accent : .primary)
                .frame(minWidth: 16, maxHeight: .infinity).padding(.horizontal, 9)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain).opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help).accessibilityLabel(help).accessibilityAddTraits(on ? .isSelected : [])
    }
    private var fill: Color { on ? Theme.accent.opacity(0.2) : Theme.ink.opacity(hovering && isEnabled ? 0.08 : 0) }
}
