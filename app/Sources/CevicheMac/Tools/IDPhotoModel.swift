import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// One photo in the ID Photo tool: the developed portrait, what Vision found in it, and the layout being set up.
@MainActor
final class IDPhotoModel: ObservableObject, Identifiable {
    enum Stage: Equatable { case loading, ready, failed(String) }

    let asset: CatalogAsset
    nonisolated var id: String { asset.id }
    @Published private(set) var stage = Stage.loading
    @Published private(set) var preview: CGImage?
    /// The person's matte for replacing the background, made the first time it is turned on.
    @Published private(set) var matte: CGImage?
    /// The preview with the background replaced, when it is.
    @Published private(set) var replaced: CGImage?
    @Published private(set) var matting = false
    /// Why the background couldn't be replaced, shown under the switch.
    @Published private(set) var matteError: String?
    /// White balance set in the tool, saved to the photo's development with the layout; nil while unchanged.
    @Published private(set) var balance: Adjustments?
    /// A click on the canvas picks the spot that should be neutral.
    @Published var pickingNeutral = false { didSet { if pickingNeutral != oldValue { dropDetail() } } }
    @Published private(set) var balancing = false
    private var balanceTask: Task<Void, Never>?
    @Published private(set) var analysis: IDPhotoAnalysis?
    @Published var layout: IDPhotoLayout? {
        didSet {
            guard layout != oldValue else { return }
            // Head size, position and spec move the frame; dragging a marker doesn't refit the canvas under the pointer.
            let markersMoved = oldValue?.crown != layout?.crown || oldValue?.chin != layout?.chin || oldValue?.eyes != layout?.eyes
            layoutChanged(refit: oldValue != nil && !markersMoved)
            if let layout, let oldValue, !layout.sharesSettings(with: oldValue) { onSharedChange?(layout) }
        }
    }
    @Published private(set) var checks: [IDPhotoCheck] = []
    @Published private(set) var printPreview: CGImage?
    @Published private(set) var reviewing = false
    /// The part of the photo the canvas shows, as fractions; set when the face is found so dragging doesn't move it.
    @Published private(set) var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published private(set) var working = false
    private var hints: [IDPhotoCheck] = []
    @Published private(set) var renderer: IDPhotoRenderer?
    /// The white balance as last written to the photo's development, so leaving only records a History step for a
    /// change. The layout itself is never kept: the tool frames the photo afresh each time it opens.
    private var savedBalance: Adjustments?
    var hasChanges: Bool { stage == .ready && balance != savedBalance }
    func markSaved() { savedBalance = balance }
    private var access: URL?
    private var task: Task<Void, Never>?

    static let specKey = "idPhotoSpec", paperKey = "idPhotoPaper", spacingKey = "idPhotoSpacing", replaceBackgroundKey = "idPhotoReplaceBackground"

    /// Called when this photo's document, background or paper changes, so the other photos of a batch follow.
    var onSharedChange: ((IDPhotoLayout) -> Void)?

    init(asset: CatalogAsset) { self.asset = asset }

    func start(catalog: CatalogModel) {
        guard task == nil else { return }
        task = Task { await load(catalog: catalog) }
    }
    /// Develops the photo and finds the face; returns when it is ready or has failed.
    func load(catalog: CatalogModel) async {
        do {
            let (url, adjustments) = try await catalog.idPhotoSource(asset)
            // Closed meanwhile: don't take access that stop() has already given back.
            try Task.checkCancellation()
            if url.startAccessingSecurityScopedResource() { access = url }
            var renderer = try await IDPhotoRenderer(url: url, adjustments: adjustments)
            var preview = try await renderer.preview()
            guard !Task.isCancelled else { return }
            var analysis = try await Task.detached(priority: .userInitiated) { [preview] in try IDPhotoAnalysis.analyze(preview) }.value
            // A head on its side or upside down: the tool works on the photo turned upright, and finds the face again there.
            if let turns = analysis.face?.uprightTurns, turns != 0 {
                renderer = try await renderer.turned(turns)
                preview = try await renderer.preview()
                guard !Task.isCancelled else { return }
                analysis = try await Task.detached(priority: .userInitiated) { [preview] in try IDPhotoAnalysis.analyze(preview) }.value
            }
            guard !Task.isCancelled else { return }
            self.renderer = renderer; self.preview = preview
            self.analysis = analysis
            placeMarkers()
            frameRegion()
            stage = .ready
            let previous = Self.lastReview
            reviewTask = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await review()
            }
            Self.lastReview = reviewTask
        } catch {
            if !Task.isCancelled { stage = .failed(error.localizedDescription) }
        }
    }
    func stop() {
        task?.cancel(); reviewTask?.cancel(); matteTask?.cancel(); balanceTask?.cancel()
        access?.stopAccessingSecurityScopedResource(); access = nil
    }

    /// Markers from the face Vision found, or a guess in the upper middle when there is none. Everything else the
    /// layout holds (head size, position, background, paper) stays as set.
    /// A photo without a layout gets one only once there is a document: `spec`, or the one remembered for next time.
    func placeMarkers(spec: IDPhotoSpec? = nil) {
        let face = analysis?.face
        let crown = face?.crown ?? CGPoint(x: 0.5, y: 0.2), chin = face?.chin ?? CGPoint(x: 0.5, y: 0.55)
        if var next = layout {
            next.crown = crown; next.chin = chin; next.eyes = face?.eyes
            layout = next
            return
        }
        guard let spec = spec ?? Self.rememberedSpec else { return }
        var next = IDPhotoLayout(spec: spec, crown: crown, chin: chin, eyes: face?.eyes)
        next.sheet = Self.rememberedSheet
        if Self.replacesBackground { next.background = IDPhotoBackground(for: spec) }
        layout = next
        frameRegion()
    }
    /// Whether this photo is waiting for a document to be chosen.
    var needsDocument: Bool { stage == .ready && layout == nil }

    /// The last spec used, else this Mac's country's passport, else ICAO.
    /// The document chosen with "Use next time"; nothing is guessed when there is none.
    static var rememberedSpec: IDPhotoSpec? {
        UserDefaults.standard.string(forKey: specKey).flatMap(IDPhotoTemplateStore.shared.spec)
    }
    /// The paper and spacing remembered with it, or the region's usual paper.
    static var rememberedSheet: IDPhotoSheet {
        var sheet = IDPhotoSheet()
        if let paper = UserDefaults.standard.string(forKey: paperKey).flatMap(IDPhotoSheet.Paper.init) { sheet.paper = paper }
        if let spacing = UserDefaults.standard.string(forKey: spacingKey).flatMap(IDPhotoSheet.Spacing.init) { sheet.spacing = spacing }
        return sheet
    }
    /// Whether a new layout starts with its background replaced: on until the user turns it off, then as last set.
    static var replacesBackground: Bool {
        get { UserDefaults.standard.object(forKey: replaceBackgroundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: replaceBackgroundKey) }
    }
    /// Remembers `layout`'s document and paper for next time, or forgets them.
    static func remember(_ layout: IDPhotoLayout?) {
        let defaults = UserDefaults.standard
        guard let layout else { [specKey, paperKey, spacingKey].forEach(defaults.removeObject(forKey:)); return }
        defaults.set(layout.spec.id, forKey: specKey)
        defaults.set(layout.sheet.paper.rawValue, forKey: paperKey)
        defaults.set(layout.sheet.spacing.rawValue, forKey: spacingKey)
    }

    func select(_ spec: IDPhotoSpec) {
        guard var next = layout else { placeMarkers(spec: spec); return }
        guard next.spec != spec else { return }
        next.spec = spec; next.headSize = 0.5; next.offsetMM = 0
        if next.background != nil { next.background = IDPhotoBackground(for: spec) }
        layout = next
        frameRegion()
    }

    /// Fits the canvas around the print with room to drag the markers.
    func frameRegion() {
        guard let preview, let layout else { return }
        let box = frameBounds(layout, in: preview)
        region = box.insetBy(dx: -box.width * 0.35, dy: -box.height * 0.18)
    }

    // MARK: Detail

    /// What the canvas shows, as fractions of the photo. There is no zoom: the print is small, the tool doesn't
    /// retouch, and a closer look would only show flaws nobody is meant to fix. Actual Size shows the print as it
    /// will come out instead.
    var visibleRegion: CGRect { region }

    /// The visible part of the photo at full resolution, when the canvas has more screen pixels than the preview
    /// has there (a camera RAW on a large display); drawn over the preview at `region`.
    @Published private(set) var detail: (image: CGImage, region: CGRect)?
    private var detailTask: Task<Void, Never>?
    /// Asks for `region` (fractions) at `size` screen pixels, after the view has rested for a moment.
    func requestDetail(_ region: CGRect, size: CGSize) {
        detailTask?.cancel()
        guard let renderer, let layout else { return }
        let background = pickingNeutral ? nil : layout.background, matte = self.matte
        detailTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let image = try? await renderer.detail(region, size: size, background: background, matte: background == nil ? nil : matte)
            guard !Task.isCancelled, let image else { return }
            detail = (image, region)
        }
    }
    /// Counts dropped details, so the canvas asks again even when it shows the same part.
    @Published private(set) var detailGeneration = 0
    func dropDetail() { detailTask?.cancel(); detail = nil; detailGeneration += 1 }


    // MARK: Actual size

    /// The print at its physical size on this screen, while shown.
    @Published var showingActualSize = false { didSet { if showingActualSize { renderActualSize() } else { actualSize = nil } } }
    @Published private(set) var actualSize: CGImage?
    /// Screen points per millimetre and pixels per point, from the display the window is on.
    var screenScale: (pointsPerMM: Double, backing: Double)?
    private var actualSizeTask: Task<Void, Never>?
    private func renderActualSize() {
        actualSizeTask?.cancel()
        guard showingActualSize, let renderer, let layout, let screenScale else { return }
        let matte = layout.background == nil ? nil : self.matte
        actualSizeTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let image = try? await renderer.renderPrint(layout, matte: matte, pixelsPerMM: screenScale.pointsPerMM * screenScale.backing)
            if !Task.isCancelled { actualSize = image }
        }
    }

    private func layoutChanged(refit: Bool = false) {
        guard let layout, let preview, let analysis else { return }
        if refit, !region.contains(frameBounds(layout, in: preview)) { frameRegion() }
        // A background that couldn't be replaced is checked as it is.
        var checked = layout
        if matteError != nil { checked.background = nil }
        let measured = IDPhotoChecks.evaluate(analysis, layout: checked, photoSize: renderer?.size ?? CGSize(width: preview.width, height: preview.height))
        checks = measured + IDPhotoReview.applicable(hints, spec: layout.spec, measured: measured)
        refreshReplaced()
        if showingActualSize { renderActualSize() }
        printPreview = IDPhotoRenderer.quickPrint(from: preview, matte: matte, layout: layout, height: 640)
    }

    /// The colour `replaced` was made with.
    private var replacedWith: IDPhotoBackground?

    /// Keeps the canvas's replaced preview in step with the layout: made when the background is on and the matte
    /// is ready, remade when the colour changes, dropped when it is off.
    private func refreshReplaced() {
        guard let preview, let background = layout?.background else {
            if replaced != nil { dropDetail() }
            replaced = nil; replacedWith = nil; return
        }
        guard let matte else { if matteError == nil { makeMatte() }; return }
        if replaced == nil || replacedWith != background {
            replaced = IDPhotoRenderer.replacingBackground(preview, matte: matte, background: background)
            replacedWith = background
            dropDetail()
        }
    }

    /// Where the print's frame is on the photo, as fractions.
    var frameCorners: CGRect {
        guard let preview, let layout else { return .zero }
        return frameBounds(layout, in: preview)
    }
    /// The print's frame on the photo, as fractions.
    private func frameBounds(_ layout: IDPhotoLayout, in preview: CGImage) -> CGRect {
        layout.bounds(in: CGSize(width: preview.width, height: preview.height))
    }

    /// Turns the solid background on (in the spec's colour) or off.
    func replaceBackground(_ on: Bool) {
        guard let spec = layout?.spec else { return }
        matteError = nil
        layout?.background = on ? IDPhotoBackground(for: spec) : nil
    }
    /// Made once, in the background; a failure turns the background off rather than trying again and again.
    /// A failure stays on this photo: the batch's background setting is left alone, the print keeps its own
    /// background, its check says so, and it isn't tried again until Replace is turned on afresh.
    private func makeMatte() {
        guard let preview, !matting, matteError == nil else { return }
        matting = true
        let previous = Self.lastMatte
        matteTask = Task {
            // One photo's matte at a time across a batch, which may turn on Replace for two dozen at once.
            await previous?.value
            guard !Task.isCancelled else { matting = false; return }
            let result = await Task.detached(priority: .userInitiated) { Result { try IDPhotoMatte.make(preview) } }.value
            matting = false
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let matte): self.matte = matte; replaced = nil
            case .failure(let error): matteError = error.localizedDescription
            }
            layoutChanged()
        }
        Self.lastMatte = matteTask
    }
    private var matteTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    /// The last matte, and the last Apple Intelligence review, started by any photo; the next of each waits for it.
    /// Separate, so turning on Replace doesn't wait behind a batch's reviews.
    private static var lastMatte: Task<Void, Never>?
    private static var lastReview: Task<Void, Never>?

    // MARK: White balance

    /// The development the tool renders, with its own white balance when set.
    var development: Adjustments? { balance ?? renderer?.adjustments }

    /// Balances from the skin and the wall behind the head (see `IDPhotoRenderer.autoBalance`).
    func autoWhiteBalance() {
        guard let skin = analysis?.face?.skinRegion else { return }
        let wall = analysis?.wallRegion
        balance { try await $0.autoBalance(wall: wall, skin: skin) }
    }
    /// Whether Auto has a face to go by.
    var canAutoBalance: Bool { analysis?.face != nil }
    /// Makes the spot at `point` (fractions of the photo from the top left) neutral.
    func pickNeutral(at point: CGPoint) {
        pickingNeutral = false
        let region = CGRect(x: point.x - 0.01, y: point.y - 0.01, width: 0.02, height: 0.02)
        balance { try await $0.neutralize(region) }
    }
    private func balance(_ solve: @escaping @Sendable (IDPhotoRenderer) async throws -> Adjustments?) {
        guard let renderer, let development else { return }
        balanceTask?.cancel()
        balancing = true
        balanceTask = Task {
            let solved = try? await solve(renderer.with(development))
            guard !Task.isCancelled else { return }
            balancing = false
            if let solved { await apply(solved) }
        }
    }
    /// Sets one white balance control from a slider; the photo is developed again once the slider rests.
    func setBalance(_ key: WritableKeyPath<Adjustments, Double>, _ value: Double) {
        guard var next = development else { return }
        next[keyPath: key] = value.rounded()
        balance = next
        // Output waits from the first move, not only once the slider rests.
        balancing = true
        balanceTask?.cancel()
        balanceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await apply(next)
        }
    }
    /// Develops the preview again with `adjustments` and measures it afresh; the layout and the matte stay, since the
    /// geometry hasn't changed.
    private func apply(_ adjustments: Adjustments) async {
        guard let renderer else { return }
        balance = adjustments
        balancing = true; defer { balancing = false }
        let updated = renderer.with(adjustments)
        guard let preview = try? await updated.preview(), !Task.isCancelled,
              let analysis = try? await Task.detached(priority: .userInitiated, operation: { try IDPhotoAnalysis.analyze(preview) }).value,
              !Task.isCancelled else { return }
        self.renderer = updated; self.preview = preview; self.analysis = analysis
        replaced = nil; replacedWith = nil; dropDetail()
        layoutChanged()
    }
    /// What the tool changed in the development, to apply to the saved one.
    var developChanges: IDPhotoWhiteBalance? {
        balance.map { IDPhotoWhiteBalance(temperature: $0.temperature, warmth: $0.warmth, tint: $0.tint) }
    }

    private func review() async {
        guard IDPhotoReview.available, let preview, let face = analysis?.face else { return }
        reviewing = true
        let hints = await IDPhotoReview.review(preview, face: face)
        reviewing = false
        guard !Task.isCancelled else { return }
        self.hints = hints
        layoutChanged()
    }

    var problems: Int { issues.filter { $0.status == .failure }.count }
    var warnings: Int { issues.filter { $0.status == .warning }.count }
    /// Head size and position back to the middle of the spec's ranges.
    func fitToSpec() { layout?.headSize = 0.5; layout?.offsetMM = 0 }

    // MARK: Output

    var stem: String { (asset.filename as NSString).deletingPathExtension }
    /// The checks that fail and those that only need a look.
    var verdict: String {
        problems > 0 ? L10n.tr("\(problems) problems") : warnings > 0 ? L10n.tr("\(warnings) to check") : L10n.tr("Meets the checks")
    }
    /// Ready, and nothing is being made that the output would need.
    var settled: Bool { stage == .ready && !working && !matting && !balancing }

    enum Output { case print, digital }
    func render(_ output: Output) async throws -> CGImage {
        guard let renderer, let layout else { throw CancellationError() }
        working = true; defer { working = false }
        let matte = layout.background == nil ? nil : self.matte
        switch output {
        case .print: return try await renderer.renderPrint(layout, matte: matte)
        case .digital: return try await renderer.renderDigital(layout, matte: matte)
        }
    }
}
