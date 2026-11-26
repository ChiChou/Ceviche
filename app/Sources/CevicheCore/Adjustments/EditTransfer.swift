import Foundation

/// The panels of Copy Edits, each grouping the settings it can copy.
public enum EditTransferSection: String, CaseIterable, Identifiable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case light = "Light", color = "Color", profile = "Profile", detail = "Detail", effects = "Effects", optics = "Optics"
    case geometry = "Crop & transform", masks = "Masks", remove = "Remove"
    public var id: String { rawValue }
    public var items: [EditTransferItem] { EditTransferItem.allCases.filter { $0.section == self } }
}

/// One setting Copy Edits can copy on its own.
public enum EditTransferItem: String, CaseIterable, Identifiable, Codable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case hdr = "HDR", light = "Light", toneCurve = "Tone curve", parametricCurve = "Parametric curve"
    case whiteBalance = "White balance", color = "Color", selectiveColor = "Selective color", blackWhite = "B&W mixer"
    case pointColor = "Point color", colorGrading = "Color grading", calibration = "Primary calibration"
    case colorProfile = "Color profile", cameraProfile = "Camera profile & looks", toneResponse = "Tone response", film = "Film print"
    case clarity = "Clarity", sharpening = "Sharpening", noiseReduction = "Noise reduction"
    case vignette = "Vignette", grain = "Film grain"
    case lensCorrection = "Lens correction", defringe = "Defringe"
    case crop = "Crop & rotation", transform = "Upright & transform"
    case masks = "Masks"
    case brushStrokes = "Brush strokes", dustSpots = "Dust spots", faceSpots = "Face spots", people = "People", redEye = "Red eye", faceLiquify = "Face Liquify"
    public var id: String { rawValue }
    public var section: EditTransferSection {
        switch self {
        case .hdr, .light, .toneCurve, .parametricCurve: return .light
        case .whiteBalance, .color, .selectiveColor, .blackWhite, .pointColor, .colorGrading, .calibration: return .color
        case .colorProfile, .cameraProfile, .toneResponse, .film: return .profile
        case .clarity, .sharpening, .noiseReduction: return .detail
        case .vignette, .grain: return .effects
        case .lensCorrection, .defringe: return .optics
        case .crop, .transform: return .geometry
        case .masks: return .masks
        case .brushStrokes, .dustSpots, .faceSpots, .people, .redEye, .faceLiquify: return .remove
        }
    }
    /// Development and white balance; never the output profile, composition, masks or retouching, which belong to one photo.
    /// Copy Selected Edits starts from these until a choice is made there.
    public static let defaults = Set(allCases).subtracting([.colorProfile, .crop, .transform, .masks, .brushStrokes, .dustSpots, .faceSpots, .people, .redEye, .faceLiquify])

    /// What is placed on the picture: it carries to a result that keeps the photo's framing pixel for pixel, as a stack
    /// on its Base photo does.
    public static let framed: Set<EditTransferItem> = [.crop, .transform, .masks, .brushStrokes, .dustSpots, .faceSpots, .people, .redEye, .faceLiquify]
    /// The same without the retouching, for a merge that took each photo's own out before aligning them.
    public static let framedRetouched: Set<EditTransferItem> = [.crop, .transform, .masks, .redEye, .faceLiquify]

    /// The panel switches whose on/off state travels with this item.
    var sections: [AdjustmentGroup] {
        switch self {
        case .light: return [.light]
        case .toneCurve: return [.curve]
        case .parametricCurve: return [.parametricCurve]
        case .color: return [.color]
        case .selectiveColor: return [.selectiveColor]
        case .blackWhite: return [.blackWhite]
        case .pointColor: return [.pointColor]
        case .colorGrading: return [.splitToning]
        case .calibration: return [.calibration]
        case .clarity: return [.detail]
        case .sharpening: return [.sharpening]
        case .noiseReduction: return [.noiseReduction]
        case .vignette: return [.vignette]
        case .grain: return [.grain]
        case .defringe: return [.defringe]
        case .faceSpots: return [.faceSpots]
        case .faceLiquify: return [.facialFeatures]
        default: return []
        }
    }

    /// Copies this item's settings from `source` into `result`, leaving everything else as it is.
    func copy(from source: Adjustments, into result: inout Adjustments) {
        let s = source
        switch self {
        case .hdr: result.hdr = s.hdr
        case .light: result.exposure = s.exposure; result.contrast = s.contrast; result.highlights = s.highlights
            result.shadows = s.shadows; result.whites = s.whites; result.blacks = s.blacks
        case .toneCurve: result.curve = s.curve; result.redCurve = s.redCurve; result.greenCurve = s.greenCurve
            result.blueCurve = s.blueCurve; result.curveSaturation = s.curveSaturation
        case .parametricCurve: result.parametricCurve = s.parametricCurve
        case .whiteBalance: result.temperature = s.temperature; result.tint = s.tint
        case .color: result.vibrance = s.vibrance; result.saturation = s.saturation; result.monochrome = s.monochrome; result.warmth = s.warmth
        case .selectiveColor: result.selectiveColors = s.selectiveColors
        case .blackWhite: result.blackWhiteMixer = s.blackWhiteMixer
        case .pointColor: result.pointColors = s.pointColors
        case .colorGrading: result.splitToning = s.splitToning
        case .calibration: result.calibration = s.calibration
        case .colorProfile: result.colorProfile = s.colorProfile
        case .cameraProfile: result.cameraProfile = s.cameraProfile; result.look = s.look; result.lut = s.lut
        case .toneResponse: result.neutralRAW = s.neutralRAW
        case .film: result.film = s.film; result.aces = s.aces
        case .clarity: result.clarity = s.clarity; result.texture = s.texture; result.dehaze = s.dehaze; result.blur = s.blur
        case .sharpening: result.sharpness = s.sharpness; result.sharpenRadius = s.sharpenRadius
            result.sharpenDetail = s.sharpenDetail; result.sharpenMasking = s.sharpenMasking
        case .noiseReduction: result.noiseReduction = s.noiseReduction; result.colorNoiseReduction = s.colorNoiseReduction
            result.luminanceNoiseDetail = s.luminanceNoiseDetail; result.luminanceNoiseContrast = s.luminanceNoiseContrast
            result.colorNoiseDetail = s.colorNoiseDetail; result.colorNoiseSmoothness = s.colorNoiseSmoothness
        case .vignette: result.postCropVignette = s.postCropVignette; result.vignette = s.vignette
            result.vignetteRadius = s.vignetteRadius; result.vignetteSoftness = s.vignetteSoftness
        case .grain: result.grain = s.grain
        case .lensCorrection: result.lensCorrection = s.lensCorrection
        case .defringe: result.defringe = s.defringe
        case .crop:
            let g = s.geometry
            result.geometry.crop = g.crop; result.geometry.aspect = g.aspect; result.geometry.customAspect = g.customAspect; result.geometry.portrait = g.portrait
            result.geometry.straighten = g.straighten; result.geometry.constrainCrop = g.constrainCrop
            result.geometry.flipHorizontal = g.flipHorizontal; result.geometry.flipVertical = g.flipVertical
            result.quarterTurns = s.quarterTurns
        case .transform:
            let g = s.geometry
            result.geometry.guides = g.guides; result.geometry.uprightMode = g.uprightMode
            result.geometry.uprightEnabled = g.uprightEnabled; result.geometry.transform = g.transform
            result.geometry.perspective = g.perspective
            // Upright's analysis describes the photo it was made on; the destination is analysed again.
            result.geometry.uprightAnalysis = nil
        case .masks:
            // Even tone goes with Portrait's other Light corrections, which are masks.
            result.skinTone = s.skinTone
            result.masks = s.masks.map { mask in
                var copy = mask; copy.id = UUID()
                copy.components = copy.components.map { var c = $0; c.id = UUID(); return c }
                return copy
            }
        case .brushStrokes, .dustSpots, .faceSpots, .people:
            let group: RetouchStroke.Group = self == .dustSpots ? .dust : self == .faceSpots ? .face : self == .people ? .people : .drawn
            // AI fills are made from the source photo's pixels, so the destination's strokes start as patch Remove.
            result.retouch = result.retouch.filter { $0.group != group } + s.retouch.filter { $0.group == group }.map(\.removingFill)
        case .faceLiquify: result.faceLiquifies = s.faceLiquifies
        case .redEye: result.redEyeCorrection = s.redEyeCorrection
        }
        for group in sections {
            if s.disabledSections.contains(group) { result.disabledSections.insert(group) } else { result.disabledSections.remove(group) }
        }
    }
    /// Whether the source differs from `baseline`, its photo's camera defaults, in this item, so copying it carries an edit.
    /// A RAW's as-shot white balance and the decoder's noise reduction are in its defaults, so they count as unedited.
    public func isModified(in source: Adjustments, from baseline: Adjustments = Adjustments()) -> Bool {
        var copied = baseline
        copy(from: source, into: &copied)
        return copied != baseline
    }
    /// The items edited away from `baseline`: Copy Changed Edits takes only these, so pasting leaves every other
    /// setting of the destination as it is.
    public static func edited(in source: Adjustments, from baseline: Adjustments = Adjustments()) -> Set<EditTransferItem> {
        Set(allCases.filter { $0.isModified(in: source, from: baseline) })
    }
}

/// A value snapshot: later edits to the source photo never change the clipboard.
public struct EditTransfer: Sendable {
    public let sourceName: String
    public let adjustments: Adjustments
    /// The source photo's camera defaults, against which an item counts as edited.
    public let baseline: Adjustments
    public var items: Set<EditTransferItem>
    public init(sourceName: String, adjustments: Adjustments, baseline: Adjustments = Adjustments(), items: Set<EditTransferItem> = EditTransferItem.defaults) {
        self.sourceName = sourceName; self.adjustments = adjustments; self.baseline = baseline; self.items = items
    }
    public func isModified(_ item: EditTransferItem) -> Bool { item.isModified(in: adjustments, from: baseline) }
    public func applying(to destination: Adjustments) throws -> Adjustments {
        var result = destination
        for item in EditTransferItem.allCases where items.contains(item) { item.copy(from: adjustments, into: &result) }
        // Strokes render in order, so copying every kind keeps the source's order rather than grouping them.
        if items.isSuperset(of: [.brushStrokes, .dustSpots, .faceSpots, .people]) { result.retouch = adjustments.retouch.map(\.removingFill) }
        return try result.validated()
    }
}
