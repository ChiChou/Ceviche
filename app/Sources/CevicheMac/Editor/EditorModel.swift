import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Rail order, correction first: Light & Color (where Develop opens), Crop, Detail and Masks, then Retouch and Portrait,
/// which share face spots, and Looks and Darkroom, the creative renderings, together at the end.
enum ToolTab: String, CaseIterable {
    var localizedTitle: String { L10n.key(rawValue) }

    /// `remove` is the Retouch tab, holding the Remove, Heal and Clone brushes.
    case light = "Light & Color", crop = "Crop", detail = "Detail", masks = "Masks", remove = "Retouch", face = "Portrait", looks = "Looks", darkroom = "Darkroom", history = "History", info = "Info"
    var icon: String {
        switch self { case .face: return "face.dashed"; case .looks: return "camera.filters"; case .crop: return "crop.rotate"; case .remove: return "bandage"; case .light: return "slider.horizontal.3"; case .detail: return "triangle"; case .masks: return "circle.dashed"; case .darkroom: return "film"; case .history: return "clock.arrow.circlepath"; case .info: return "info.circle" }
    }
    /// Single-key shortcut in Develop; the conventional letters where they exist (C crop, H heal, M masks, I info).
    var key: Character {
        switch self { case .face: return "j"; case .looks: return "k"; case .light: return "l"; case .detail: return "t"; case .masks: return "m"; case .darkroom: return "f"; case .crop: return "c"; case .remove: return "h"; case .history: return "y"; case .info: return "i" }
    }
    var shortcutLabel: String { String(key).uppercased() }
    /// History and Info describe the photo rather than edit it; the rail keeps them at its foot.
    var isReference: Bool { self == .history || self == .info }
}

/// Retouch's tools: three brushes that paint a retouch stroke of their fill type, and the dust review.
enum RetouchTool: String, CaseIterable {
    var localizedTitle: String { L10n.key(rawValue) }

    case tone = "Dodge/Burn", remove = "Remove", heal = "Heal", clone = "Clone", dust = "Dust Spots"
    var mode: RetouchMode? {
        switch self { case .tone: return .tone; case .remove: return .remove; case .heal: return .heal; case .clone: return .clone; case .dust: return nil }
    }
    init(_ mode: RetouchMode) {
        switch mode { case .tone: self = .tone; case .remove: self = .remove; case .heal: self = .heal; case .clone: self = .clone }
    }
    var symbol: String {
        switch self { case .tone: return "circle.lefthalf.filled"; case .remove: return "eraser"; case .heal: return "bandage"; case .clone: return "square.on.square.dashed"; case .dust: return "aqi.low" }
    }
}

/// The Color Mixer property a targeted drag on the photo adjusts.
enum MixerProperty: String, CaseIterable {
    var localizedTitle: String { L10n.key(rawValue) }

    case hue = "Hue", saturation = "Saturation", luminance = "Luminance"
    var key: WritableKeyPath<SelectiveColorAdjustment, Double> {
        switch self { case .hue: return \.hue; case .saturation: return \.saturation; case .luminance: return \.luminance }
    }
    var range: ClosedRange<Double> { self == .hue ? -60...60 : -100...100 }
    /// Units per dragged point: 200 points span saturation or luminance, 240 points span hue.
    var unitsPerPoint: Double { self == .hue ? 0.5 : 1 }
}

@MainActor
final class EditorModel: ObservableObject {
    /// Whether the display showing the photo can show HDR; `DisplayHDRObserver` keeps it current as the window moves.
    @Published var displaySupportsHDR = true
    /// Print Proof: the canvas shows the photo as a print while it is on.
    let proof = PrintProofState()
    /// The editor as the menu bar shows it (`CatalogCommands`).
    lazy var menuState = EditorMenuState(editor: self)
    /// A proof is made from the photo developed wide, so the print's own gamut is what limits it.
    private static let proofSpace: ColorProfile = { var profile = ColorProfile(); profile.preset = .proPhoto; return profile }()
    /// What the canvas renders: the photo's development, in the proof's working space while one is shown.
    private func canvasRender() -> (settings: Adjustments, sdr: Bool, proof: PrintProofState.Active?) {
        var settings = displayAdjustments
        guard let active = proof.active else { return (settings, sdrPreview, nil) }
        settings.colorProfile = Self.proofSpace
        return (settings, true, active)
    }
    @Published var sdrPreview = false { didSet { if oldValue != sdrPreview { scheduleRender() }; preferences.set(sdrPreview, forKey: "sdrPreview") } }
    var originalHDR = HDRSettings()
    var originalSDRPreview = false
    @Published var curveChannel: CurveChannel = .rgb
    var selectedCurve: ToneCurve { targetAdjustments[keyPath: curveChannel.key] }
    @Published var toolTab: ToolTab = .light {
        didSet { if oldValue != toolTab { endLookPreview(); eyedropper = nil; targetedMixer = nil; awaitingGradient = false; if toolTab == .history { refreshHistory() }; if [.light, .detail].contains(toolTab) { lastAdjustmentTab = toolTab }; endMask(); guideDraft = nil; cropDrawingGuide = false; cropPlacingCorners = false; cornerDraft = nil; cropStraightening = false; selectedGuideID = nil
            // Leaving Crop shows the full canvas again; other adjustment panels retain their zoom.
            if toolTab == .face { retouchTool = .heal }
            if [.remove, .face].contains(toolTab) { retouchPointer = false; retouchSelecting = false; retouchObject = false }
            if oldValue == .face { editingFaceRegion = false; showingFramings = false }
            if oldValue == .crop { viewport.inset = 0; viewport.fit() }
            if toolTab == .crop { viewport.inset = Self.cropMargin; cropFocusPending = true; focusCrop(); markCropEntry() } else { cropEntry = nil }
            // Only Crop displays the photo differently (the whole canvas); other panels keep the rendered preview.
            if oldValue == .crop || toolTab == .crop { scheduleRender() } }
            // The chosen tool panel is remembered locally; editing tools (not Crop or Remove) reopen next launch.
            if ![.crop, .remove, .face].contains(toolTab) { preferences.set(toolTab.rawValue, forKey: "developToolTab") }
            if toolTab != .remove { dustVisualize = false } }
    }
    /// The Retouch panel is showing, so the canvas paints, shows and edits retouch strokes. Hiding the inspector keeps
    /// `toolTab`, but none of that.
    var removing: Bool { showInspector && (toolTab == .remove || toolTab == .face) }
    /// Retouch's brushes paint. Portrait has no brushes: its spots are found, then selected, moved, resized or
    /// deleted, and a click on bare skin adds one.
    var paintsRetouch: Bool { removing && retouchTool.mode != nil && toolTab != .face && !retouchPointer && !retouchSelecting && !retouchObject }
    /// Retouch's Object tool: a click on the photo removes what is under it (`removeObject`); a wire is followed.
    @Published var retouchObject = false { didSet { if retouchObject { _ = currentObjectPicker() } else { endObjectHover() } } }
    var picksObject: Bool { removing && toolTab == .remove && retouchObject }
    /// What a click with Object would take out where the pointer rests, outlined on the photo before the click.
    @Published var objectPreview: ObjectPreview?
    /// The photo developed for Object, kept while its settings stay the same, and the hover being looked up.
    var objectPicker: (renderer: ObjectIdentifier, basis: Adjustments, task: Task<ObjectPicker, Error>)?
    var objectHover: Task<Void, Never>?
    /// Objects Shift-click collected with Object, outlined, to remove together with the next plain click.
    @Published var objectSelection: [ObjectPick] = []
    /// Strokes Object just added, and when: the photo shows them being taken out until their AI fill lands.
    var removingObjects: [UUID: Date] = [:]
    /// Masks › Object: the mask a click would make where the pointer rests, outlined on the photo.
    @Published var maskObjectPreview: MaskObjectPreview?
    /// Retouch's Select tool: the photo shows every stroke's pin to click or box, for changing or deleting several at
    /// once; it neither paints nor pans.
    @Published var retouchSelecting = false
    var selectsRetouch: Bool { removing && toolTab == .remove && retouchSelecting }
    var editsFaceSpots: Bool { showInspector && toolTab == .face && !editingFaceRegion && !retouchPointer }
    /// The brush or spot tool put down in Retouch and Portrait: the photo takes the plain pointer, to zoom and pan,
    /// and nothing is painted or added. Picking a tool, or a stroke in the list, takes it up again.
    @Published var retouchPointer = false
    /// Darkroom is showing a film on a medium that takes an exposure, so the canvas carries the Strip and Ring proofs.
    var printing: Bool { showInspector && toolTab == .darkroom && adjustments.rendering == .film && adjustments.film.map { $0.output?.hasExposure == true && !$0.off.contains(.print) } == true }
    /// Opens a tool panel, or hides the inspector when its panel is already showing (rail click or shortcut key).
    func toggleTool(_ tab: ToolTab) {
        if showInspector && toolTab == tab { showInspector = false; return }
        endMask(); toolTab = tab; showInspector = true
    }
    /// Escape: leaves a one-shot canvas tool before anything else would happen. True when something was cancelled.
    @discardableResult func cancelCanvasTool() -> Bool {
        if eyedropper != nil { eyedropper = nil; return true }
        if targetedMixer != nil { targetedMixer = nil; return true }
        if awaitingGradient { awaitingGradient = false; maskTool = nil; return true }
        if redrawGradient { redrawGradient = false; return true }
        if cropStraightening { cropStraightening = false; return true }
        if cropDrawingGuide { cropDrawingGuide = false; guideDraft = nil; return true }
        if cropPlacingCorners { cropPlacingCorners = false; cornerDraft = nil; return true }
        if editingFaceRegion { editingFaceRegion = false; return true }
        if picksObject, !objectSelection.isEmpty { objectSelection = []; objectPreview = nil; return true }
        if removing, !selectedRetouchIDs.isEmpty { selectedRetouchIDs = []; return true }
        // Then the brush or spot tool is put down for the pointer; the next Escape leaves the tool.
        if removing, !retouchPointer { retouchPointer = true; retouchSelecting = false; retouchObject = false; return true }
        return false
    }
    /// Escape, as in other RAW editors: an armed canvas tool closes first; otherwise the Crop, Remove or Masks tool itself closes and the last
    /// adjustment panel returns. Crop's changes are undone (Return keeps them); other tools' edits are kept and stay undoable. Escape never leaves Develop. True when something changed.
    @discardableResult func dismissTool() -> Bool {
        // AI fills being made stop first: they run on after the stroke, whichever tool is open.
        if cancelFills() { return true }
        if cancelCanvasTool() { return true }
        switch toolTab {
        case .masks:
            // A brush or object tool is put down before the panel closes; a selected component steps back to its mask.
            if maskTool != nil { endMask(); maskTool = nil; return true }
            if selectedComponentID != nil { selectedComponentID = nil; return true }
            endMask(); adjustmentTargetID = nil; toolTab = lastAdjustmentTab; return true
        case .face where touchingUp:
            // Touch Up is put down first, back to the plain photo.
            portraitTool = .photo; return true
        case .crop:
            cancelCrop(); return true
        case .remove, .face:
            toolTab = lastAdjustmentTab; return true
        case .darkroom where printView != .photo:
            printView = .photo; return true
        default:
            return false
        }
    }
    /// Closes whichever canvas tool is open at once, keeping its edits; Compare has no canvas.
    func leaveCanvasTool() {
        cancelCanvasTool()
        endMask(); maskTool = nil; selectedComponentID = nil; adjustmentTargetID = nil
        if [.crop, .remove, .face, .masks].contains(toolTab) { toolTab = lastAdjustmentTab }
        printView = .photo
    }
    /// The photo's geometry as the Crop tool opened on it, which Escape goes back to.
    struct CropEntry { let documentID: UUID; let geometry: GeometryAdjustments; let quarterTurns: Int }
    var cropEntry: CropEntry?
    func markCropEntry() { cropEntry = CropEntry(documentID: documentID, geometry: adjustments.geometry, quarterTurns: adjustments.quarterTurns) }
    /// Escape in Crop: the crop, angle, flips, rotation and perspective go back to how they were when the tool opened (one
    /// undo step), then the tool closes. Upright's analysis describes the photo, so it stays.
    func cancelCrop() {
        if let entry = cropEntry, entry.documentID == documentID {
            edit(constrainingCrop: false) {
                let analysis = $0.geometry.uprightAnalysis
                $0.geometry = entry.geometry; $0.geometry.uprightAnalysis = analysis
                $0.quarterTurns = entry.quarterTurns
            }
        }
        toolTab = lastAdjustmentTab
    }
    /// Return puts down guides first, then finishes the geometry tool, keeping its edits.
    @discardableResult func finishCrop() -> Bool {
        guard toolTab == .crop else { return false }
        if cropDrawingGuide { cropDrawingGuide = false; guideDraft = nil; return true }
        if cropPlacingCorners { cropPlacingCorners = false; cornerDraft = nil; return true }
        guideDraft = nil; cropStraightening = false
        toolTab = lastAdjustmentTab
        return true
    }
    /// What the canvas shows in Darkroom: the photo, a test strip of print exposures or a ring-around of color balance.
    enum PrintView: String, CaseIterable { case photo = "Photo", strip = "Strip", ring = "Ring" }
    @Published var printView: PrintView = .photo
    /// Stops between a test strip's bands, and CC between a ring-around's prints.
    @Published var printStripStep: Double { didSet { preferences.set(printStripStep, forKey: "printStripStep") } }
    @Published var printRingStep: Double { didSet { preferences.set(printRingStep, forKey: "printRingStep") } }
    static let printStripSteps = [1.0 / 3, 0.5, 1], printRingSteps = [5.0, 10, 20]
    /// While set, dragging on the photo adjusts this property for the color under the pointer (the targeted adjustment).
    @Published var targetedMixer: MixerProperty? { didSet { if targetedMixer != nil { comparing = false; eyedropper = nil; if let targetedMixer { lastMixerProperty = targetedMixer } } } }
    private(set) var lastMixerProperty: MixerProperty = .saturation
    private var mixerDrag: (weights: [Double], start: [SelectiveColorAdjustment])?
    private var mixerDragPoints = 0.0
    private var mixerDragID: UUID?
    func toggleTargetedMixer() { targetedMixer = targetedMixer == nil ? lastMixerProperty : nil }
    /// Samples the color under the pointer (with the mixer itself undone, so already-shifted bands are still found), then applies any movement so far.
    func beginMixerDrag(at point: MaskPoint) {
        guard targetedMixer != nil, let renderer, !busy else { return }
        beginGesture(); mixerDrag = nil; mixerDragPoints = 0
        let id = UUID(); mixerDragID = id
        var snapshot = adjustments; snapshot.selectiveColors = SelectiveColor.defaults
        Task {
            do {
                let rgb = try await renderer.sampleColor(at: point, adjustments: snapshot, radius: 1)
                guard mixerDragID == id, self.renderer === renderer else { return }
                armMixerDrag(hue: EyedropperTarget.hue(rgb))
            } catch { self.error = error.localizedDescription }
        }
    }
    /// Locks the bands a drag moves: the band nearest this hue fully, its neighbors by the mixer's own falloff.
    func armMixerDrag(hue: Double) {
        let bands = targetAdjustments.selectiveColors
        let weights = SelectiveColor.bandWeights(hue: hue)
        mixerDrag = (weights, bands)
        if let strongest = weights.indices.max(by: { weights[$0] < weights[$1] }) { selectiveColorBand = strongest }
        applyMixerDrag()
    }
    func updateMixerDrag(points: Double) {
        mixerDragPoints = points; applyMixerDrag()
    }
    private func applyMixerDrag() {
        guard let property = targetedMixer, let (weights, start) = mixerDrag else { return }
        let delta = mixerDragPoints * property.unitsPerPoint
        editTarget { value in
            for index in value.selectiveColors.indices where index < start.count && weights[index] > 0 {
                let moved = start[index][keyPath: property.key] + delta * weights[index]
                value.selectiveColors[index][keyPath: property.key] = min(property.range.upperBound, max(property.range.lowerBound, moved)).rounded()
            }
        }
    }
    func endMixerDrag() { mixerDragID = nil; mixerDrag = nil; mixerDragPoints = 0; endGesture() }
    /// Room around the photo in Crop, in points, for the handles and the rotation ring outside the frame.
    static let cropMargin = 40.0
    /// Set when Crop opens before the canvas has reported its size; the canvas fits once it has.
    var cropFocusPending = false
    /// Crop shows the whole photo inside `cropMargin` and then holds the view still: the frame moves over the photo,
    /// so nothing jumps when a handle is let go. Zooming and panning stay available for precise framing.
    func focusCrop() {
        guard toolTab == .crop, viewportImageSize.width > 0, viewportCanvasSize.width > 0 else { return }
        viewport.fit()
        cropFocusPending = false
    }
    @Published var cropStraightening = false
    @Published var cropOverlay: CropOverlay = .thirds
    @Published var cropOverlayVisibility: CropOverlayVisibility = .auto
    @Published var cropOverlayOrientation = 0
    @Published var selectedGuideID: UUID?
    @Published var guideMessage: String?
    @Published var showGuideLoupe = true
    @Published var showGuideGrid = false
    @Published var autoStraightening = false
    @Published var uprightAnalyzing = false
    var geometryGestureStart: Adjustments? { gestureStart }
    @Published var renderedGeometry: GeometryPlan?
    @Published var cropDrawingGuide = false {
        didSet { if oldValue != cropDrawingGuide { viewport.fit(); scheduleRender() } }
    }
    /// Perspective crop's corners are being placed: the canvas shows the photo before it is pulled square.
    @Published var cropPlacingCorners = false {
        didSet { if oldValue != cropPlacingCorners { viewport.fit(); scheduleRender() } }
    }
    /// The corners while one is dragged; they become the edit when it is let go.
    @Published var cornerDraft: [MaskPoint]?
    @Published var detectingCorners = false
    @Published var guideAxis: GuideAxis = .vertical
    @Published var guideDraft: UprightGuide?
    /// Brush settings for the next stroke; a selected stroke has its own in the Selected section.
    @Published var retouchRadius = 0.025
    @Published var retouchSoftness = 0.5
    /// What is picked in Retouch, on the photo or in the stroke list: strokes of any kind (the dust finder's too) and
    /// found dust spots. Delete removes them all; the Selected card changes them together.
    @Published var selectedRetouchIDs: Set<UUID> = []
    /// Where a ⇧-click range in the stroke list starts.
    var retouchSelectionAnchor: UUID?
    /// The one selected item, which shows its handles on the photo; nil with none or several selected.
    var selectedRetouchID: UUID? {
        get { selectedRetouchIDs.count == 1 ? selectedRetouchIDs.first : nil }
        set { selectedRetouchIDs = newValue.map { [$0] } ?? [] }
    }
    /// The stroke under the pointer in the stroke list, pointed out on the photo.
    @Published var hoveredRetouchID: UUID?
    /// Sources a stroke had before Refresh, so the next pick moves elsewhere. Kept only for this session.
    var refusedRetouchSources: [UUID: [MaskPoint]] = [:]
    /// Whether the next Remove stroke asks for an AI fill (when the model is installed).
    @Published var retouchGenerative = true { didSet { preferences.set(retouchGenerative, forKey: "retouchGenerative") } }
    /// Remove strokes waiting for their AI fill; they are made in stroke order, one at a time.
    @Published var pendingFills: [UUID] = []
    var fillTask: Task<Void, Never>?
    /// The windows done and the total for the fill being made, when it takes more than one (a long or wide stroke).
    @Published var fillProgress: (done: Int, total: Int)?
    /// Why a fill could not be made, by stroke and footprint (`fillKey`), so it is not tried again until the stroke changes.
    @Published var fillFailures: [String: String] = [:]
    /// How often each stroke's fill was refreshed this session; each refresh shows the network other windows.
    var fillVariants: [UUID: Int] = [:]
    @Published var blemishSensitivity = 0.5
    @Published var faceRegion: CGRect?
    /// The detected face's placement for Face Liquify before any control is set.
    @Published var liquifyBase: FaceLiquify?
    /// In a group picture, where each face's warp would go, by `PortraitFace.id`, for faces not reshaped yet.
    @Published var groupPlacements: [Int: FaceLiquify] = [:]
    /// The faces placements were looked for, found or not, so the card can tell a face that can't be reshaped from one
    /// still being measured.
    @Published var loadedPlacements: Set<Int> = []
    @Published var showingLiquify = false
    @Published var editingFaceRegion = false
    var placingFaceRegion: Bool { showInspector && toolTab == .face && editingFaceRegion }
    var faceTask: Task<Void, Never>?
    /// The quiet face search Portrait starts on its own.
    var faceLookup: Task<Void, Never>?
    @Published var blemishReport: String?
    /// What the last Find People did, under its button.
    @Published var peopleReport: String?
    @Published var redEyeReport: String?
    @Published var retouchTool: RetouchTool = .remove {
        didSet {
            // The selection keeps what the new tool shows on the photo: a brush the hand-drawn strokes, Dust Spots the dust.
            if oldValue != retouchTool { selectedRetouchIDs.formIntersection(retouchHandleIDs) }
            if retouchTool != .dust { dustVisualize = false }
        }
    }
    var reviewingDust: Bool { removing && retouchTool == .dust && !retouchPointer && !retouchSelecting }
    @Published var dustSpotSize = 6.0
    @Published var dustSensitivity = 0.5
    @Published var dustNightSky = false
    /// Spots under review in the Dust tab. They become part of the edit only when healed.
    @Published var dustSpots: [DustSpot] = []
    /// Healed dust (the finder's heal strokes) stays on the photo as handles, to be picked out and removed later.
    @Published var dustShowHealed = true {
        didSet { if !dustShowHealed, reviewingDust { selectedRetouchIDs.subtract(adjustments.retouch.lazy.filter(\.suggested).map(\.id)) } }
    }
    /// The spots the photo shows in Dust Spots: found ones, and healed ones while they show.
    var shownDustSpots: [DustSpot] { dustSpots + (dustShowHealed ? healedDustHandles : []) }
    /// Finding or healing.
    @Published var dustWorking = false
    @Published var dustReport: String?
    var dustTask: Task<Void, Never>?
    /// Visualize Spots: the canvas shows `DustVisualizer`'s map of the preview and the detail in place of the photo.
    @Published var dustVisualize = false { didSet { if dustVisualize != oldValue { refreshDustMaps() } } }
    @Published var dustVisualOptions = DustVisualizer.Options() { didSet { if dustVisualOptions != oldValue { refreshDustMaps() } } }
    /// Each map with the image it was made from, so a stale one is never laid over a newer photo.
    @Published var dustPreviewMap: (source: CGImage, map: CGImage)?
    @Published var dustDetailMap: (source: CGImage, map: CGImage)?
    var dustMapTask: Task<Void, Never>?
    func toggleRedEyeCorrection() {
        guard let renderer, !busy else { return }
        let wasEnabled = adjustments.redEyeCorrection
        if wasEnabled { edit { $0.redEyeCorrection = false }; redEyeReport = nil; return }
        Task {
            let count = await renderer.redEyeCount()
            guard self.renderer === renderer else { return }
            if count > 0 {
                edit { $0.redEyeCorrection = true }
                redEyeReport = (count == 1 ? L10n.tr("Fixed \(count) red eye") : L10n.tr("Fixed \(count) red eyes"))
            } else { redEyeReport = L10n.tr("No red eyes detected") }
        }
    }
    var originalGeometry = GeometryAdjustments()
    var displayAdjustments: Adjustments {
        var value = lookPreview ?? adjustments
        // Crop shows the whole canvas around the crop frame, and guides are drawn on the whole photo; otherwise the
        // Transform tab shows the crop as it will export, so Constrain Crop and the sliders take effect at once.
        if toolTab == .crop || toolTab == .face && showingFramings {
            value.geometry.crop = .full
            if cropPlacingCorners { value.geometry.perspective = nil }
        }
        return value
    }
    var geometryPlan: GeometryPlan? {
        guard let info else { return nil }
        return try? GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: displayAdjustments.geometry, quarterTurns: adjustments.quarterTurns)
    }
    var outputSize: CGSize? {
        guard let info else { return nil }
        return try? GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: adjustments.geometry, quarterTurns: adjustments.quarterTurns).outputSize
    }
    @Published var adjustmentTargetID: UUID? {
        didSet {
            if oldValue != adjustmentTargetID, case .defringe? = eyedropper { eyedropper = nil }
        }
    }
    @Published var selectedComponentID: UUID?
    @Published var copiedEdits: EditTransfer?
    @Published var editCopyDraft: EditCopyDraft?
    @Published var copiedMaskAdjustments: PixelAdjustments?
    var lastAdjustmentTab: ToolTab = .light
    var pendingMaskOperation: MaskOperation?
    var pendingMaskParentID: UUID?
    @Published var selectedMaskID: UUID?
    @Published var maskTool: MaskKind?
    /// A gradient tool is chosen but nothing exists yet; the first drag on the photo creates the mask (or component).
    @Published var awaitingGradient = false
    /// Redraw: the next drag replaces the selected gradient's geometry instead of starting a new mask.
    @Published var redrawGradient = false
    /// The gradient created by the current drag; a plain click leaves nothing behind.
    var drawnGradientID: UUID?
    @Published var showMaskOverlay = true { didSet { preferences.set(showMaskOverlay, forKey: "showMaskOverlay") } }
    @Published var maskOverlay: CGImage?
    /// A People part under the pointer in the chooser, tinted on the photo before it is made.
    /// Parts of a person tinted on the photo while the People chooser is open: those ticked and the one under the pointer.
    @Published var partPreviews: [(image: CGImage, opacity: CGFloat)] = []
    /// Portrait's people row: the photo's faces and those ticked, whom Portrait's corrections and sliders are for.
    @Published var portraitFaces: [PortraitFace] = [] { didSet { if portraitFaces.map(\.box) != oldValue.map(\.box) { groupPlacements = [:]; loadedPlacements = []; selectedFaceID = nil } } }
    /// The person Portrait's cards work on (`PortraitFace.id`); nil is Everyone, the main people.
    @Published var selectedFaceID: Int?
    /// The main people: faces at least 0.4 the width of the largest. Smaller ones are usually passers-by, picked one
    /// at a time if at all.
    var mainFaceIDs: Set<Int> {
        let largest = portraitFaces.map(\.box.width).max() ?? 0
        return Set(portraitFaces.filter { $0.box.width >= largest * 0.4 }.map(\.id))
    }
    /// Whom the corrections are for: the selected person, or Everyone's main people.
    var chosenFaceIDs: Set<Int> { selectedFaceID.map { [$0] } ?? mainFaceIDs }
    /// The face under the pointer in a row of faces, outlined on the photo so a picture can be told apart.
    @Published var hoveredFaceID: Int?
    /// Why the last open failed, for the caller to offer a way out (Reset Edits for edits that can't be read).
    var lastOpenError: Error?
    /// Portrait › Framing on the photo: the whole frame shows with the framings drawn on it to pick from.
    /// Portrait's Touch Up: the pointer over a face part tints it and a click opens its controls; `portraitParts` are
    /// the parts of the photo's faces, loaded while it is on.
    @Published var touchingUp = false { didSet { if !touchingUp { portraitParts = [] } } }
    @Published var portraitParts: [PortraitPartOutline] = []
    @Published var showingFramings = false { didSet { if showingFramings != oldValue { if !showingFramings { framingFrames = []; pickedFraming = nil }; scheduleRender() } } }
    /// The framing clicked on the photo, held tinted until Apply or Dismiss.
    @Published var pickedFraming: FramingCandidate?
    /// Framings at the photo's own shape rather than 4:5.
    /// The aspect Reframe's framings take, picked in its bar; nil is the first of `framingAspects`.
    @Published var framingAspectChoice: CropAspect?
    /// Reframe's aspects: a portrait of one person is framed upright at 4:5 or as the photo; a group, standing side by
    /// side, as the photo or wide.
    var framingAspects: [CropAspect] { isGroupPortrait ? [.original, .sixteenNine] : [.fourFive, .original] }
    var framingAspect: CropAspect { framingAspectChoice.flatMap { framingAspects.contains($0) ? $0 : nil } ?? framingAspects[0] }
    @Published var framingFrames: [FramingCandidate] = []
    /// The ticked faces' boxes; nil before the faces are known, so a correction then covers everyone.
    var chosenFaces: [CGRect]? { portraitFaces.isEmpty ? nil : portraitFaces.filter { chosenFaceIDs.contains($0.id) }.map(\.box) }
    /// The brush stroke being painted, not yet part of its mask; nil between strokes. Not published: the canvas redraws
    /// itself as the pointer moves, and nothing else needs to hear of every point.
    var liveStroke: MaskStroke?
    /// Whether the stroke being painted takes away from the mask: an eraser stroke, or any stroke of a component
    /// that subtracts.
    var liveStrokeRemoves: Bool {
        guard let stroke = liveStroke else { return false }
        let subtracts = selectedMask?.components.first { $0.id == selectedComponentID }?.operation == .subtract
        return stroke.erase != subtracts
    }
    @Published var brushRadius = 0.035
    @Published var brushSoftness = 0.7
    @Published var brushErase = false
    @Published var isSelecting = false
    @Published var selectionStatus = ""
    @Published var embeddedSkyAvailable = false
    var skyAvailable: Bool { embeddedSkyAvailable || BundledModel.sky.isAvailable }
    let preferences: UserDefaults
    @Published var showInspector: Bool { didSet { preferences.set(showInspector, forKey: "showDevelopInspector") } }
    @Published var snapshotNameRequested = false
    /// The filmstrip under the photo in Detail and Compare.
    @Published var showFilmstrip: Bool { didSet { preferences.set(showFilmstrip, forKey: "showDevelopFilmstrip") } }
    /// Flags, stars and labels in a band above the filmstrip; it hides with the filmstrip.
    @Published var showCullingBar: Bool { didSet { preferences.set(showCullingBar, forKey: "showFilmstripCullingBar") } }
    enum FilmstripStyle: String, CaseIterable { case photo, square }
    @Published var filmstripStyle: FilmstripStyle { didSet { preferences.set(filmstripStyle.rawValue, forKey: "filmstripStyle") } }
    /// The filmstrip's height, set by dragging its top edge; the cells of both styles scale with it.
    @Published var filmstripHeight: Double { didSet { preferences.set(filmstripHeight, forKey: "filmstripHeight") } }
    static let filmstripHeights: ClosedRange<Double> = 64...260
    static let defaultFilmstripHeight: Double = 140
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        showInspector = preferences.object(forKey: "showDevelopInspector") as? Bool ?? true
        showFilmstrip = preferences.object(forKey: "showDevelopFilmstrip") as? Bool ?? true
        showCullingBar = preferences.object(forKey: "showFilmstripCullingBar") as? Bool ?? true
        filmstripStyle = (preferences.string(forKey: "filmstripStyle")).flatMap(FilmstripStyle.init(rawValue:)) ?? .photo
        filmstripHeight = min(Self.filmstripHeights.upperBound, max(Self.filmstripHeights.lowerBound,
            preferences.object(forKey: "filmstripHeight") as? Double ?? Self.defaultFilmstripHeight))
        // Panel states live in the local preferences plist and are never synced.
        if let stored = preferences.string(forKey: "developToolTab"),
           let tab = ToolTab(rawValue: stored),
           ![.crop, .remove, .face].contains(tab) {
            toolTab = tab
        }
        printStripStep = preferences.object(forKey: "printStripStep") as? Double ?? 0.5
        printRingStep = preferences.object(forKey: "printRingStep") as? Double ?? 10
        sdrPreview = preferences.object(forKey: "sdrPreview") as? Bool ?? false
        retouchGenerative = preferences.object(forKey: "retouchGenerative") as? Bool ?? true
        showMaskOverlay = preferences.object(forKey: "showMaskOverlay") as? Bool ?? true
        showCaptureOverlay = preferences.bool(forKey: "showCaptureOverlay")
        // The menus name the proof by its state, which they read off the editor.
        proof.changed = { [weak self] in self?.objectWillChange.send(); self?.scheduleRender(after: .zero) }
    }
    @Published var showExport = false
    @Published var exportSettings = ExportSettings()
    var selectionTask: Task<Void, Never>?
    var maskDragStart: MaskPoint?
    @Published var adjustments = Adjustments() {
        didSet {
            if Self.filmPreviewsKey(oldValue) != Self.filmPreviewsKey(adjustments) {
                invalidateFilmPreviews()
            }
        }
    }
    @Published var info: ImageInfo?
    @Published var preview: CGImage? { didSet { if dustVisualize, preview !== oldValue { refreshDustMaps() }; if zonesShown, preview !== oldValue { refreshZones() } } }
    @Published var originalPreview: CGImage?
    @Published var histogram: [[Double]] = []
    @Published var luminanceHistogram: [Double] = []
    /// The scope in the histogram's place, and what it shows; computed only while it isn't the histogram.
    @Published var scope: EditorScope? = EditorScope.saved { didSet { if scope != oldValue { EditorScope.save(scope); refreshScope() } } }
    @Published var scopeOptions = ScopeOptions.saved { didSet { if scopeOptions != oldValue { scopeOptions.save(); refreshScope() } } }
    @Published var scopeDisplays: [EditorScope: ScopeDisplay] = [:]
    /// The scope over the photo: whether it is wanted, its own choice, and whether it is on screen now (so its scope
    /// is measured too). Its corner and size are the view's.
    /// The zone map over the photo, with its strip of zones.
    @Published var zonesShown = false { didSet { if zonesShown != oldValue { zoneHovered = nil; zonePinned = nil; refreshZones() } } }
    @Published var zoneDisplay: ZoneDisplay?
    @Published var zoneHovered: Int? { didSet { if zoneHovered != oldValue { refreshZones() } } }
    @Published var zonePinned: Int? { didSet { if zonePinned != oldValue { refreshZones() } } }
    let zonePointer = ZonePointer()
    var zoneTask: Task<Void, Never>?
    var zonePending = false
    var scopeSource: ScopeSource? { didSet { refreshScope() } }
    var scopeTask: Task<Void, Never>?
    var scopePending = false
    /// The open catalog photo's development History (newest first) and named Snapshots.
    @Published var history: [CatalogRevision] = []
    @Published var snapshots: [CatalogSnapshot] = []
    /// The latest rendered catalog thumbnail, reused for Snapshot images.
    var lastThumbnailJPEG: Data?
    /// While set, clicking the photo samples color for this tool instead of editing.
    @Published var eyedropper: EyedropperTarget? {
        didSet {
            if oldValue != eyedropper {
                defringePickTask?.cancel()
                defringePickTask = nil
            }
            if eyedropper != nil { comparing = false }
        }
    }
    private var defringePickTask: Task<Void, Never>?
    @Published var selectiveColorBand = 0
    /// Source-resolution pixels for the visible region while the preview is magnified (top-left normalized region).
    @Published var detail: (image: CGImage, region: CGRect, scale: Double)? { didSet { if dustVisualize, detail?.image !== oldValue?.image { refreshDustMaps() } } }
    var detailTask: Task<Void, Never>?
    var detailRequest: CGRect?
    var detailVisible: CGRect?
    /// The width in pixels the canvas shows the whole photo at, which sets the scale a tile renders at.
    private var detailPhotoWidth: Double = 0
    private var detailRendering = false
    static let detailSettleAfterEdit: Duration = .milliseconds(700)
    /// The long edge of the first frame shown for a look under the pointer.
    static let lookDraftSize = 1024.0
    @Published var thumbnail: NSImage?
    /// The open catalog photo's development as it is being edited, for its filmstrip cell until the saved thumbnail
    /// catches up. Published at most every `liveThumbnailInterval`, and only while the crop shows as it will export.
    @Published private(set) var liveThumbnail: LiveThumbnail?
    struct LiveThumbnail { let assetID: String; let image: NSImage }
    static let liveThumbnailInterval: Duration = .milliseconds(500)
    private var pendingLiveThumbnail: LiveThumbnail?
    private var liveThumbnailTask: Task<Void, Never>?
    private var liveThumbnailShownAt: ContinuousClock.Instant?
    private func offerLiveThumbnail(_ image: NSImage?) {
        guard let image, let id = catalogAssetID, toolTab != .crop else { clearLiveThumbnail(); return }
        pendingLiveThumbnail = LiveThumbnail(assetID: id, image: image)
        guard liveThumbnailTask == nil else { return }
        let elapsed = liveThumbnailShownAt.map { ContinuousClock.now - $0 } ?? Self.liveThumbnailInterval
        let wait = max(.zero, Self.liveThumbnailInterval - elapsed)
        liveThumbnailTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, !Task.isCancelled else { return }
            self.liveThumbnailTask = nil
            guard let next = self.pendingLiveThumbnail, next.assetID == self.catalogAssetID else { return }
            self.pendingLiveThumbnail = nil; self.liveThumbnail = next; self.liveThumbnailShownAt = .now
        }
    }
    func clearLiveThumbnail() {
        liveThumbnailTask?.cancel(); liveThumbnailTask = nil; pendingLiveThumbnail = nil
        if liveThumbnail != nil { liveThumbnail = nil }
    }
    @Published var isLoading = false
    /// The Library's thumbnail of the photo being opened, shown at once while its original decodes.
    @Published var openingImage: NSImage?
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// When the system runs short of memory, what can be made again is let go: look and film thumbnails, the
    /// renderer's finished previews and Core Image's intermediates. What is on screen stays.
    func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lookThumbnails = [:]; self.lookThumbnailUse = []; self.invalidateFilmPreviews(); self.filmProofs = FilmProofs()
                if let renderer = self.renderer { Task { await renderer.releaseCaches() } }
            }
        }
        source.resume(); memoryPressure = source
    }
    @Published var isRendering = false
    @Published var isSaving = false
    @Published var isExporting = false
    @Published var spaceHeld = false
    var spaceDragged = false
    /// Only what is held is let go: setting a flag that is already off would still publish, and a menu opening over
    /// the photo (its windows take key) would then be rebuilt under the pointer, closing its submenus.
    func cancelHeldViewKeys() {
        if peekingOriginal { peekingOriginal = false }
        if spaceHeld { spaceHeld = false }
        spaceDragged = false
    }
    @Published var peekingOriginal = false
    @Published var comparing = false
    @Published var showCaptureOverlay = false { didSet { preferences.set(showCaptureOverlay, forKey: "showCaptureOverlay") } }
    @Published var comparisonSplit = 0.5
    var originalRotation = 0
    var originalColorProfile: ColorProfile?
    @Published var viewport = ImageViewport()
    var viewportImageSize = CGSize.zero
    var viewportCanvasSize = CGSize.zero
    @Published var error: String?
    /// A failure the person must see, such as a photo that could not be opened at all: an alert (`failureAlerts`), where `error` is a toast.
    @Published var failure: Failure?
    @Published var xmpReport: String?
    /// A look shown while the pointer rests on it in the Looks tab, rendered in place of `adjustments`.
    @Published var lookPreview: Adjustments?
    /// The photo through each film stock, by stock id, for the Darkroom's list; made in the background as a photo
    /// opens, and again when the edit they share changes while the Darkroom is shown.
    @Published var filmPreviews: [String: CGImage] = [:]
    /// Looks' thumbnails by file, with the edit each was made on: the one on show until it is made again on the
    /// current edit. Made only for the tiles in view (`requestLookThumbnail`), top to bottom.
    @Published var lookThumbnails: [URL: (base: Adjustments, image: CGImage)] = [:]
    /// Look thumbnails from the one shown longest ago to the latest, so a large library drops the ones scrolled away first.
    var lookThumbnailUse: [URL] = []
    static let lookThumbnailLimit = 400
    func useLookThumbnail(_ url: URL) {
        if lookThumbnailUse.last == url { return }
        lookThumbnailUse.removeAll { $0 == url }; lookThumbnailUse.append(url)
    }
    var lookThumbnailQueue: [LookFile] = []
    var lookThumbnailTask: Task<Void, Never>?
    /// The edit the previews show (without the stock), once they are all made.
    var filmPreviewsKey: Adjustments?
    var filmPreviewTask: Task<Void, Never>?
    var lookPreviewTask: Task<Void, Never>?
    @Published var lookNotes: LookNotes?
    /// The preset last applied from the Looks tab, for its Amount; it shows while the photo is still that preset.
    @Published var appliedPreset: AppliedPreset?
    /// The look last applied of each kind, so the Looks tab can mark it while it is on the photo (`isOnPhoto`).
    @Published var appliedLooks: [LookKind: AppliedLookFile] = [:]
    /// Save Preset is asking for a name, starting from `presetName`.
    @Published var namingPreset = false
    @Published var presetName = ""
    /// Counts presets saved, so the Looks tab lists them at once.
    @Published private(set) var savedPresets = 0
    func presetSaved() { savedPresets += 1 }
    var xmpSourceData: Data?
    var xmpMetadata: CatalogMetadata?
    /// Where the open photo's development is saved; nil for a photo opened only to look at (tests, the command line).
    var developmentStore: DevelopmentStore?
    @Published var catalogAssetID: String?
    var catalogStore: CatalogStore? { developmentStore?.catalog }
    func usesCatalog(_ store: CatalogStore?) -> Bool { catalogStore != nil && catalogStore === store }
    /// The open photo is one of a browsed folder: the index it is in is the folders' own, not a catalog with culling.
    var inFolder: Bool { catalogStore.map { $0.root.standardizedFileURL == CatalogModel.folderIndexRoot.standardizedFileURL } ?? false }
    /// Where the photo's looks are kept: its catalog's library, or the build's for a standalone document.
    var lookResources: ResourceStorage { catalogStore?.resources ?? .shared }
    @Published var sourceURL: URL?
    /// New each time a photo is opened or closed. The tool panels are keyed on it, so whatever a panel holds about
    /// the photo it was showing (an open chooser, results, a name being typed) starts over with the next one.
    @Published var documentID = UUID()
    /// Volume's Amount is being dragged.
    @Published var volumeAdjusting = false
    @Published var dirty = false
    @Published var gpuName = "Metal"
    @Published var savedAt: Date?
    @Published var undoStack: [Adjustments] = []
    @Published var redoStack: [Adjustments] = []
    var renderer: RawRenderer?
    var renderTask: Task<Void, Never>?
    private var renderInFlight = false
    private var renderPending = false
    private var displayedVersion = 0
    var autosaveTask: Task<Void, Never>?
    var generation = 0
    var gestureStart: Adjustments? {
        // Library thumbnails wait while a slider or brush is dragged, so the drag has the Mac to itself.
        didSet { if (gestureStart == nil) != (oldValue == nil) { holdThumbnailRenders(gestureStart != nil) } }
    }
    private var heldThumbnails: ThumbnailReactor?
    private var thumbnailHoldSequence = 0
    private func holdThumbnailRenders(_ hold: Bool) {
        thumbnailHoldSequence += 1
        let sequence = thumbnailHoldSequence, owner = ObjectIdentifier(self)
        if hold, heldThumbnails == nil, let reactor = catalogStore?.thumbnails {
            heldThumbnails = reactor
            Task { await reactor.holdRenders(true, by: owner, sequence: sequence) }
        } else if !hold, let reactor = heldThumbnails {
            heldThumbnails = nil
            Task { await reactor.holdRenders(false, by: owner, sequence: sequence) }
        }
    }
    var histogramDrag: (HistogramRegion, Double)?
    var savedAdjustments: Adjustments?
    @Published var automationBusy = false
    var automationGestureActive: Bool { gestureStart != nil || maskDragStart != nil }
    var busy: Bool { automationBusy || isLoading || isSaving || isExporting || isSelecting }
    var hasImage: Bool { renderer != nil }

    /// Installs a state the catalog has already committed (an MCP edit, a history step or a snapshot) as the saved one.
    func acceptAutomationEdits(_ value: Adjustments) {
        autosaveTask?.cancel()
        if value != adjustments { undoStack.append(adjustments); redoStack = [] }
        adjustments = value; savedAdjustments = value; dirty = false; savedAt = Date()
        if let id = selectedMaskID, !value.masks.contains(where: { $0.id == id }) { selectedMaskID = nil; adjustmentTargetID = nil }
        scheduleRender()
        scheduleFills()
        if adjustments.geometry.needsUprightAnalysis { analyzeUpright() }
    }

    /// Called by the canvas as zoom and pan change, and after each preview. Waits `settle` for the view or the
    /// sliders to come to rest, then renders the visible region from the source at the size it is shown,
    /// `photoWidth` pixels for the whole photo (never more than the source's own pixels): when fitted too, so the
    /// view settles on the full-resolution development rather than the preview. A covering detail for the current
    /// edit at that scale or finer is reused. The graph is prepared on the renderer, but the pixels render on a
    /// detached task so slider
    /// previews never wait behind a tile, and only one tile is on the GPU at a time: a request made while one
    /// renders runs when it finishes.
    func requestDetail(_ visible: CGRect?, photoWidth: Double? = nil, settle: Duration = .milliseconds(160)) {
        detailVisible = visible
        if let photoWidth { detailPhotoWidth = photoWidth }
        guard let visible else { detailTask?.cancel(); detailRequest = nil; if detail != nil { detail = nil }; return }
        // A look under the pointer shows its preview only: its tile would take the renderer from the next look.
        guard lookPreview == nil else { return }
        let width = detailPhotoWidth
        if let detail, detail.region.insetBy(dx: -0.0005, dy: -0.0005).contains(visible), detailRequest == nil,
           detail.scale >= 1 || Double(detail.image.width) / detail.region.width >= width * 0.98 { return }
        guard detailRequest != visible else { return }
        detailTask?.cancel(); detailRequest = visible
        let version = generation, (settings, sdr, proofing) = canvasRender()
        guard let renderer, !isRendering, !detailRendering else { return }
        detailTask = Task {
            // Whether this task got as far as rendering: only then can a request have been left waiting on it.
            var rendered = false
            do {
                try await Task.sleep(for: settle)
                // A little margin lets small pans reuse the same tile.
                let padded = visible.insetBy(dx: -visible.width * 0.15, dy: -visible.height * 0.15)
                guard let job = try await renderer.prepareDetail(settings, sdr: sdr, region: padded, photoWidth: width) else { return }
                detailRendering = true; rendered = true
                let result = try await Task.detached(priority: .utility) {
                    let tile = try job.render()
                    guard let proofing, let proofed = PrintProofState.render(tile.image, proofing, measuring: false).image else { return tile }
                    return (proofed, tile.region)
                }.value
                detailRendering = false
                if !Task.isCancelled, version == generation, detailRequest == visible { detail = (result.image, result.region, job.scale); detailRequest = nil }
            } catch {
                detailRendering = false
                if !(error is CancellationError), version == generation { self.error = error.localizedDescription }
            }
            // A request that arrived while this tile rendered starts now, for whichever photo is open by then. A task
            // cancelled before it rendered was replaced by the request that cancelled it: starting another from here
            // would cancel that one in turn, each cancelled task spawning the next without end.
            if rendered, detailRequest != nil, let visible = detailVisible, self.renderer != nil, !isRendering {
                detailRequest = nil; requestDetail(visible)
            }
        }
    }
    func toggleEyedropper(_ target: EyedropperTarget) { eyedropper = eyedropper == target ? nil : target }
    @Published var filmProofs = FilmProofs()
    /// Applies a click from the eyedropper. Defringe picks from the source pixels before that pass.
    func pickColor(at point: MaskPoint) {
        guard let target = eyedropper, let renderer, !busy else { return }
        if case .defringe(let band) = target {
            pickFringe(at: point, band: band, renderer: renderer)
            return
        }
        eyedropper = nil
        let snapshot = adjustments
        Task {
            do {
                switch target {
                case .whiteBalance:
                    guard let balance = try await renderer.neutralWhiteBalance(at: point, adjustments: snapshot), self.renderer === renderer else { return }
                    edit { $0.temperature = balance.temperature.rounded(); $0.tint = balance.tint.rounded() }
                case .printBalance:
                    guard let filtration = try await renderer.filmNeutralFiltration(at: point, adjustments: snapshot), self.renderer === renderer else { return }
                    edit { $0.film?.yellow = filtration.yellow; $0.film?.magenta = filtration.magenta }
                case .pointColor:
                    let rgb = try await renderer.sampleColor(at: point, adjustments: snapshot, radius: 0)
                    guard self.renderer === renderer, targetAdjustments.pointColors.count < 16 else { return }
                    editTarget { $0.pointColors.append(PointColor(red: rgb[0], green: rgb[1], blue: rgb[2])) }
                case .selectiveColor:
                    let rgb = try await renderer.sampleColor(at: point, adjustments: snapshot, radius: 0)
                    guard self.renderer === renderer else { return }
                    selectiveColorBand = EyedropperTarget.nearestBand(hue: EyedropperTarget.hue(rgb))
                case .grading(let range):
                    let rgb = try await renderer.sampleColor(at: point, adjustments: snapshot, radius: 0)
                    guard self.renderer === renderer else { return }
                    editTarget {
                        $0[keyPath: range.hue] = (EyedropperTarget.hue(rgb) * 360).rounded()
                        if $0[keyPath: range.saturation] == 0 { $0[keyPath: range.saturation] = 25 }
                    }
                case .defringe: break
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func pickFringe(at point: MaskPoint, band: Defringe.Band, renderer: RawRenderer) {
        defringePickTask?.cancel()
        let snapshot = adjustments, maskID = adjustmentTargetID
        defringePickTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let range = try await renderer.sampleDefringe(at: point, band: band, adjustments: snapshot, maskID: maskID)
                guard let self, !Task.isCancelled, self.renderer === renderer,
                      self.adjustmentTargetID == maskID, self.adjustments == snapshot, let range else { return }
                self.eyedropper = nil
                self.editTarget { $0.defringe.setPickedRange(range, for: band) }
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
        }
    }
    /// Shows a look's development in place of the current one, or the current one again when nil; never during a drag.
    func showLookPreview(_ settings: Adjustments?) {
        let next = gestureStart == nil ? settings : nil
        guard next != lookPreview else { return }
        lookPreview = next
        // The pointer has already settled on the row, so there is no drag to wait out.
        scheduleRender(after: .zero)
    }
    func scheduleRender(after delay: Duration = .milliseconds(80)) {
        // A strip or ring covers the photo: its prints go first, and the photo behind them follows.
        let delay = printing && printView != .photo && eyedropper == nil ? max(delay, .milliseconds(450)) : delay
        generation += 1
        // The detail tile shows the previous edit; drop it until the new one is rendered.
        if detail != nil || detailRequest != nil { detail = nil; detailTask?.cancel(); detailRequest = nil }
        guard renderer != nil else { return }
        isRendering = true
        // A render that is past its debounce keeps going, so a continuous drag shows intermediate states instead of
        // cancelling forever; the newest settings render as soon as it finishes.
        if renderInFlight { renderPending = true; return }
        renderTask?.cancel()
        startRender(after: delay)
    }
    private func startRender(after delay: Duration) {
        let version = generation, (settings, sdr, proofing) = canvasRender(), maskID = selectedMaskID, previewing = lookPreview != nil
        guard let renderer else { return }
        renderTask = Task {
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                renderInFlight = true
                defer { renderInFlight = false }
                // A look under the pointer shows a small frame first; the full preview also builds the thumbnail and
                // histogram, which take longer than the image itself.
                if previewing {
                    let draft = try await renderer.displayImage(settings, maxDimension: Self.lookDraftSize, sdr: sdr)
                    if self.renderer === renderer, version == generation, version > displayedVersion { preview = draft }
                    // The pointer has moved on to another look: its draft is next, not this one's full preview.
                    if version != generation { throw CancellationError() }
                }
                let result = try await renderer.preview(settings, sdr: sdr)
                var shown = result.image, coverage: (colour: Double, shadow: Double)?
                if let proofing {
                    let proofed = await Task.detached(priority: .userInitiated) { PrintProofState.render(result.image, proofing, measuring: true) }.value
                    shown = proofed.image ?? shown; coverage = proofed.coverage
                }
                let overlay: CGImage?
                if let mask = settings.masks.first(where: { $0.id == maskID }) { overlay = try await renderer.maskOverlay(mask, adjustments: settings) } else { overlay = nil }
                var rotatedOriginal: CGImage?
                if settings.hdr != originalHDR || sdr != originalSDRPreview || settings.quarterTurns != originalRotation || settings.colorProfile != originalColorProfile || settings.geometry != originalGeometry {
                    var original = renderer.info.defaults; original.quarterTurns = settings.quarterTurns; original.colorProfile = settings.colorProfile; original.geometry = settings.geometry; original.hdr = settings.hdr
                    rotatedOriginal = try await renderer.preview(original, sdr: sdr).image
                }
                // Show it if nothing newer has been shown and the document is still the same.
                guard self.renderer === renderer, version > displayedVersion else { return }
                displayedVersion = version
                if let rotatedOriginal { originalPreview = rotatedOriginal; originalRotation = settings.quarterTurns; originalColorProfile = settings.colorProfile; originalGeometry = settings.geometry; originalHDR = settings.hdr; originalSDRPreview = sdr }
                maskOverlay = overlay
                renderedGeometry = try? GeometryPlan(size: CGSize(width: info?.width ?? 1, height: info?.height ?? 1), settings: settings.geometry, quarterTurns: settings.quarterTurns)
                preview = shown; histogram = result.histogram; luminanceHistogram = result.luminance; scopeSource = result.scopeSource
                if proofing != nil, !previewing { proof.coverage = coverage }
                // A look being previewed is not the photo's development, so its thumbnail must not become a snapshot's.
                if !previewing { thumbnail = NSImage(data: result.thumbnail); lastThumbnailJPEG = result.thumbnail; offerLiveThumbnail(thumbnail) }
                if version == generation {
                    isRendering = false
                    // A tile takes a second or more of GPU time and evicts the preview's cached intermediates, so
                    // it waits until the sliders have been still for a while rather than following every move.
                    if let visible = detailVisible { detailRequest = nil; requestDetail(visible, settle: Self.detailSettleAfterEdit) }
                }
            } catch is CancellationError {}
            catch { if version == generation { self.error = error.localizedDescription; isRendering = false } }
            if renderPending { renderPending = false; startRender(after: .zero) }
        }
    }
    func autoAdjust() {
        guard let renderer, !busy else { return }
        let snapshot = adjustments
        isSelecting = true; selectionStatus = L10n.tr("Analyzing tones locally…")
        selectionTask = Task {
            defer { isSelecting = false; selectionStatus = "" }
            do {
                let result = try await renderer.autoAdjust(snapshot)
                try Task.checkCancellation()
                guard adjustments == snapshot, self.renderer === renderer else { return }
                edit { $0 = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func importProfile() {
        Task { if let url = await FileChooser.openOne(FileOpenRequest(types: UTType.iccProfiles, message: L10n.tr("RGB ICC profile"))) { importProfile(url) } }
    }
    func importProfile(_ url: URL) {
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else { throw EditorError.invalidDocument(L10n.tr("ICC profiles must be smaller than 4 MB.")) }
            var profile = ColorProfile(); profile.preset = .custom; profile.iccData = try Data(contentsOf: url); profile.name = url.deletingPathExtension().lastPathComponent
            // A profile from the library is referenced where it is; one from elsewhere is copied in when saved.
            profile.source = lookResources.folder?.reference(for: url)
            _ = try profile.colorSpace()
            edit { $0.colorProfile = profile }
        } catch { self.error = error.localizedDescription }
    }
    /// Saves pending edits before the photo is replaced or the window closes. False while a save is still running, when
    /// the catalog could not be written, or when a read-only folder needs the user to pick where to save, so the caller
    /// keeps the photo open (and, for the last, asks).
    func flushEdits() async -> Bool {
        if isSaving { return false }
        guard dirty, developmentStore != nil else { return true }
        return await save()
    }
}
