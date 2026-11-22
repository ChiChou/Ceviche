import SwiftUI
import Combine
import CevicheCore

/// The photos the ID Photo tool is working on: one, or a batch in a filmstrip, laid out on the sheets. The document,
/// background and paper are shared, so a family's photos match and share sheets; markers, head size, white balance
/// and copies are each photo's own.
@MainActor
final class IDPhotoSession: ObservableObject {
    let request: IDPhotoRequest
    /// In the filmstrip's order; one can be taken out, never the last.
    @Published private(set) var photos: [IDPhotoModel]
    /// The photo on the canvas and in the side panel.
    @Published var current = 0
    /// The canvas shows the current photo with its frame and markers instead of the sheets.
    @Published var adjusting = false
    /// The sheets as they'll print, at screen resolution; with Single Photo paper, each print on its own.
    @Published private(set) var sheetPreviews: [CGImage] = []
    private var watching: [AnyCancellable] = []
    private var loading: Task<Void, Never>?
    /// While the session hands one photo's shared settings to the others, their own changes aren't passed on again.
    private var sharing = false

    init(request: IDPhotoRequest) {
        self.request = request
        photos = request.assets.map(IDPhotoModel.init(asset:))
        current = 0
        remembering = IDPhotoModel.rememberedSpec != nil
        // One photo opens on its framing to tweak (after the document prompt, when there is one); a batch on its sheets.
        adjusting = photos.count == 1
        for photo in photos {
            photo.onSharedChange = { [weak self, weak photo] layout in
                guard let self, let photo else { return }
                self.share(layout, from: photo)
            }
            // The grid shows every photo's print and checks, so any change to one redraws the tool.
            watching.append(photo.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
                self?.sheetsChanged()
            })
        }
    }

    var isBatch: Bool { photos.count > 1 }
    var shown: IDPhotoModel { photos[min(current, photos.count - 1)] }

    /// Takes a photo out of the batch: it isn't printed, exported or saved.
    func remove(_ photo: IDPhotoModel) {
        guard photos.count > 1, let index = photos.firstIndex(where: { $0 === photo }) else { return }
        photo.stop()
        let shownID = shown.id
        photos.remove(at: index)
        current = photos.firstIndex { $0.id == shownID } ?? min(index, photos.count - 1)
        sheetsChanged()
    }
    var ready: [IDPhotoModel] { photos.filter { $0.stage == .ready } }
    /// Every photo is developed and nothing is being made that the output would need.
    var settled: Bool { photos.allSatisfy { $0.settled || $0.stage != .loading && $0.stage != .ready } && !ready.isEmpty }
    /// The shared settings, from the first photo that has them.
    var layout: IDPhotoLayout? { ready.first?.layout }

    /// Develops two photos at a time: enough to fill the grid quickly without holding the GPU for one at a time.
    func start(catalog: CatalogModel) {
        guard loading == nil else { return }
        // The photo on screen first.
        let queue = [shown] + photos.filter { $0 !== shown }
        loading = Task {
            await withTaskGroup(of: Void.self) { group in
                var pending = queue[...]
                func next() {
                    // Closing stops the queue; photos already developing stop at their next step.
                    guard !Task.isCancelled, let photo = pending.popFirst() else { return }
                    group.addTask { @MainActor in
                        await photo.load(catalog: catalog)
                        if !Task.isCancelled { self.adoptShared(photo) }
                    }
                }
                next(); next()
                while await group.next() != nil { next() }
            }
        }
    }
    func stop() {
        loading?.cancel(); sheetTask?.cancel()
        photos.forEach { $0.stop() }
    }

    // MARK: Shared settings

    /// The last shared settings set, which photos still loading take when they're ready.
    private var sharedLayout: IDPhotoLayout?

    private func share(_ layout: IDPhotoLayout, from source: IDPhotoModel) {
        guard !sharing else { return }
        sharing = true; defer { sharing = false }
        sharedLayout = layout
        for photo in photos where photo !== source { apply(layout, to: photo) }
    }
    private func adoptShared(_ photo: IDPhotoModel) {
        guard photo.stage == .ready else { return }
        // Waiting for a document: the batch's, once there is one.
        if photo.layout == nil, let sharedLayout { photo.placeMarkers(spec: sharedLayout.spec) }
        guard photo.layout != nil else { return }
        if let sharedLayout { sharing = true; apply(sharedLayout, to: photo); sharing = false }
        else if let layout = photo.layout { sharedLayout = layout; share(layout, from: photo) }
        // A single photo's saved count from an earlier batch is dropped, so it fills its sheet again.
        if isBatch, photo.layout?.sheet.copies == nil { photo.layout?.sheet.copies = Self.defaultCopies }
        else if !isBatch, request.assets.count == 1 { photo.layout?.sheet.copies = nil }
    }
    private func apply(_ shared: IDPhotoLayout, to photo: IDPhotoModel) {
        if photo.layout == nil, photo.stage == .ready { photo.placeMarkers(spec: shared.spec) }
        guard var layout = photo.layout, !layout.sharesSettings(with: shared) else { return }
        layout.adoptSettings(of: shared)
        photo.layout = layout
    }

    /// The document for every photo.
    func select(_ spec: IDPhotoSpec) {
        // Through each photo, so each resets its own head size and position and refits its canvas.
        sharing = true
        for photo in ready { photo.select(spec) }
        sharing = false
        if let layout { sharedLayout = layout; share(layout, from: ready.first!) }
        rememberIfAsked()
    }

    // MARK: Document

    /// No document is chosen yet: nothing remembered, and none saved on the photos.
    var needsDocument: Bool { layout == nil && photos.contains(where: \.needsDocument) }
    /// "Use next time": the document and paper are remembered for the next time the tool opens. Off unless chosen.
    var rememberChoice: Bool {
        get { layout.map { IDPhotoModel.rememberedSpec?.id == $0.spec.id && IDPhotoModel.rememberedSheet.paper == $0.sheet.paper } ?? false }
        set { IDPhotoModel.remember(newValue ? layout : nil); objectWillChange.send(); remembering = newValue }
    }
    /// While ticked, later changes to the document or paper are remembered too. The document prompt sets it before
    /// there is anything to remember, so the document chosen there is kept.
    @Published var remembering = false
    private func rememberIfAsked() { if remembering { IDPhotoModel.remember(layout) } }
    /// The background for every photo; each makes its own matte.
    func replaceBackground(_ on: Bool) {
        IDPhotoModel.replacesBackground = on
        sharing = true
        for photo in ready { photo.replaceBackground(on) }
        sharing = false
        if let layout { sharedLayout = layout }
    }
    /// Sets a shared value on the photo shown (or the first), which passes it on.
    func setShared(_ update: (inout IDPhotoLayout) -> Void) {
        defer { rememberIfAsked() }
        // The photo on screen when it's ready; one still developing (or failed) has no layout to pass on.
        guard let photo = shown.stage == .ready ? shown : ready.first, var layout = photo.layout else { return }
        update(&layout)
        photo.layout = layout
    }
    /// Auto white balance on every photo the check finds warm or cool.
    func balanceWhereNeeded() {
        for photo in ready where photo.checks.contains(where: { $0.id == "cast" && $0.status != .pass }) { photo.autoWhiteBalance() }
    }
    var needsBalance: Bool { ready.contains { $0.checks.contains { $0.id == "cast" && $0.status != .pass } } }

    // MARK: Copies and sheets

    /// Most documents ask for two photos.
    static let defaultCopies = 2
    /// How many copies of `photo` go on the sheets: its own count, or by default two in a batch and a full sheet of
    /// a single photo.
    func copies(of photo: IDPhotoModel) -> Int {
        guard let layout = photo.layout else { return 0 }
        if layout.sheet.paper == .single { return layout.sheet.copies == 0 ? 0 : 1 }
        return layout.sheet.copies ?? (isBatch ? Self.defaultCopies : capacity)
    }
    func setCopies(_ count: Int, of photo: IDPhotoModel) { photo.layout?.sheet.copies = max(0, count) }
    /// Back to the default count.
    func resetCopies(of photo: IDPhotoModel) { photo.layout?.sheet.copies = isBatch ? Self.defaultCopies : nil }
    /// Which photo is in each place of each sheet, by index into `photos`; with Single Photo paper, one print a page.
    var pages: [[Int]] {
        guard let layout else { return [] }
        if layout.sheet.paper == .single { return photos.indices.filter { photos[$0].stage == .ready && copies(of: photos[$0]) > 0 }.map { [$0] } }
        return layout.sheet.pages(copies: counts, spec: layout.spec)
    }
    /// Places on one sheet.
    var capacity: Int {
        guard let layout else { return 0 }
        var sheet = layout.sheet; sheet.copies = nil
        return sheet.arrangement(for: layout.spec)?.origins.count ?? 0
    }
    var counts: [Int] { photos.map { $0.stage == .ready ? copies(of: $0) : 0 } }
    var sheetCount: Int { pages.count }

    private var sheetTask: Task<Void, Never>?
    private func sheetsChanged() {
        // Several photos can change at once (a shared setting); the sheets are laid out once they settle.
        sheetTask?.cancel()
        sheetTask = Task { try? await Task.sleep(for: .milliseconds(60)); if !Task.isCancelled { layOutSheetPreviews() } }
    }
    /// The sheets at about 300 ppi, from the previews: sharp on screen at the size the canvas fits them to.
    static let sheetPreviewPixelsPerMM = 12.0
    /// Zoomed in, the sheets are laid out again at the density the screen shows them, up to what the previews hold.
    private var sheetPixelsPerMM = sheetPreviewPixelsPerMM
    func showSheets(atPixelsPerMM wanted: Double) {
        let ppm = min(24, max(Self.sheetPreviewPixelsPerMM, (wanted / 4).rounded(.up) * 4))
        guard ppm != sheetPixelsPerMM else { return }
        sheetPixelsPerMM = ppm
        sheetsChanged()
    }
    private func layOutSheetPreviews() {
        guard let layout else { sheetPreviews = []; return }
        let ppm = sheetPixelsPerMM, height = Int((layout.spec.heightMM * ppm).rounded())
        // Single Photo paper: each print that goes out, on its own.
        if layout.sheet.paper == .single {
            sheetPreviews = photos.indices.compactMap { index in
                let photo = photos[index]
                guard photo.stage == .ready, copies(of: photo) > 0, let preview = photo.preview, let own = photo.layout else { return nil }
                return IDPhotoRenderer.quickPrint(from: preview, matte: own.background == nil ? nil : photo.matte, layout: own, height: height)
            }
            return
        }
        let prints = photos.map { photo -> CGImage? in
            guard let preview = photo.preview, let own = photo.layout else { return nil }
            return IDPhotoRenderer.quickPrint(from: preview, matte: own.background == nil ? nil : photo.matte, layout: own, height: height)
        }
        // A photo still loading or failed takes no place.
        let blank = prints.compactMap { $0 }.first
        guard let blank else { sheetPreviews = []; return }
        let counts = zip(prints, self.counts).map { $0 == nil ? 0 : $1 }
        sheetPreviews = (try? IDPhotoRenderer.sheets(prints.map { $0 ?? blank }, copies: counts, layout: layout, pixelsPerMM: ppm)) ?? []
    }

    // MARK: Output

    /// Every photo's print at full resolution, in order; nil where a photo isn't ready.
    func renderPrints(_ output: IDPhotoModel.Output) async throws -> [CGImage?] {
        var prints: [CGImage?] = []
        for photo in photos {
            try Task.checkCancellation()
            prints.append(photo.stage == .ready ? try await photo.render(output) : nil)
        }
        return prints
    }
    /// The sheets at the spec's resolution; a single photo on Single Photo paper is just its print.
    func renderSheets() async throws -> [CGImage] {
        guard let layout else { return [] }
        let prints = try await renderPrints(.print)
        guard layout.sheet.paper != .single else { return zip(prints, counts).compactMap { $1 > 0 ? $0 : nil } }
        guard let blank = prints.compactMap({ $0 }).first else { return [] }
        let counts = zip(prints, self.counts).map { $0 == nil ? 0 : $1 }
        return try IDPhotoRenderer.sheets(prints.map { $0 ?? blank }, copies: counts, layout: layout)
    }
    /// Each white balance the tool changed, to write to its photo's development; marked kept, so leaving again doesn't
    /// repeat them.
    func takeSaves() -> [IDPhotoSave] {
        let saves = photos.filter(\.hasChanges).compactMap { photo in
            photo.developChanges.map { IDPhotoSave(asset: photo.asset, balance: $0) }
        }
        photos.filter(\.hasChanges).forEach { $0.markSaved() }
        return saves
    }
    func count(_ readiness: IDPhotoReadiness) -> Int { photos.filter { $0.stage == .ready && $0.readiness == readiness }.count }
    var problems: Int { count(.retake) + count(.needsFix) }

    /// Off the sheets but still in the list, to bring back.
    func leaveOut(_ photo: IDPhotoModel) { setCopies(0, of: photo) }
    func isLeftOut(_ photo: IDPhotoModel) -> Bool { photo.stage == .ready && copies(of: photo) == 0 }
}
