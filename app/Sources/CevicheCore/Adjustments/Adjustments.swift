import Foundation

/// How the scene's light becomes the picture: the camera's own rendering, the ACES 2 output transform or a film print.
public enum Rendering: String, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case camera = "Camera", aces = "ACES", film = "Film"
}

public struct Adjustments: Codable, Equatable, Sendable {
    public var hdr = HDRSettings()
    @Boxed public var look: ImportedLook?
    /// Look tables and tone curve from a DNG camera profile, applied to RAW photos.
    @Boxed public var cameraProfile: CameraProfile?
    /// An imported 3D lookup table, applied after global and local adjustments.
    @Boxed public var lut: CreativeLUT?
    /// A film and paper the RAW's scene light is rendered through, in place of the camera's tone response.
    @Boxed public var film: FilmSimulation?
    /// The ACES 2 output transform renders the RAW's scene light in place of the camera's tone response. A film on
    /// the photo takes precedence.
    public var aces = false
    /// macOS's built-in RAW lens correction, when the camera and lens support it.
    public var lensCorrection = true
    /// Sidecar luminance noise reduction Detail (default 50) and Contrast (default 0), RAW only.
    public var luminanceNoiseDetail = 50.0
    public var luminanceNoiseContrast = 0.0
    public var retouch: [RetouchStroke] = []
    public var redEyeCorrection = false
    /// Facial Features: one warp for each face reshaped, each placed on its own face.
    public var faceLiquifies: [FaceLiquify] = []
    /// The first face's warp; setting nil takes out every face's.
    public var faceLiquify: FaceLiquify? {
        get { faceLiquifies.first }
        set {
            if let newValue { if faceLiquifies.isEmpty { faceLiquifies = [newValue] } else { faceLiquifies[0] = newValue } }
            else { faceLiquifies = [] }
        }
    }
    /// Portrait's Even tone: each face's blend layer and the amount it is applied with.
    public var skinTone: SkinTone?
    public var geometry = GeometryAdjustments()
    public var masks: [PhotoMask] = []
    public var colorProfile = ColorProfile()
    public var neutralRAW = false
    public var pixels = PixelAdjustments()
    public var temperature = 6500.0
    public var quarterTurns = 0
    public var exposure: Double { get { pixels.exposure } set { pixels.exposure = newValue } }
    public var contrast: Double { get { pixels.contrast } set { pixels.contrast = newValue } }
    public var highlights: Double { get { pixels.highlights } set { pixels.highlights = newValue } }
    public var shadows: Double { get { pixels.shadows } set { pixels.shadows = newValue } }
    public var whites: Double { get { pixels.whites } set { pixels.whites = newValue } }
    public var blacks: Double { get { pixels.blacks } set { pixels.blacks = newValue } }
    public var tint: Double { get { pixels.tint } set { pixels.tint = newValue } }
    public var vibrance: Double { get { pixels.vibrance } set { pixels.vibrance = newValue } }
    public var saturation: Double { get { pixels.saturation } set { pixels.saturation = newValue } }
    public var clarity: Double { get { pixels.clarity } set { pixels.clarity = newValue } }
    public var texture: Double { get { pixels.texture } set { pixels.texture = newValue } }
    public var dehaze: Double { get { pixels.dehaze } set { pixels.dehaze = newValue } }
    public var sharpness: Double { get { pixels.sharpness } set { pixels.sharpness = newValue } }
    public var noiseReduction: Double { get { pixels.noiseReduction } set { pixels.noiseReduction = newValue } }
    public var vignette: Double { get { pixels.vignette } set { pixels.vignette = newValue } }
    public var vignetteRadius: Double { get { pixels.vignetteRadius } set { pixels.vignetteRadius = newValue } }
    public var vignetteSoftness: Double { get { pixels.vignetteSoftness } set { pixels.vignetteSoftness = newValue } }
    public var selectiveColors: [SelectiveColorAdjustment] { get { pixels.selectiveColors } set { pixels.selectiveColors = newValue } }
    public var disabledSections: Set<AdjustmentGroup> { get { pixels.disabledSections } set { pixels.disabledSections = newValue } }
    public var monochrome: Bool { get { pixels.monochrome } set { pixels.monochrome = newValue } }
    public var curve: ToneCurve { get { pixels.curve } set { pixels.curve = newValue } }
    public var redCurve: ToneCurve { get { pixels.redCurve } set { pixels.redCurve = newValue } }
    public var greenCurve: ToneCurve { get { pixels.greenCurve } set { pixels.greenCurve = newValue } }
    public var blueCurve: ToneCurve { get { pixels.blueCurve } set { pixels.blueCurve = newValue } }
    public var parametricCurve: ParametricCurve { get { pixels.parametricCurve } set { pixels.parametricCurve = newValue } }
    public var splitToning: SplitToning { get { pixels.splitToning } set { pixels.splitToning = newValue } }
    public var calibration: PrimaryCalibration { get { pixels.calibration } set { pixels.calibration = newValue } }
    public var blackWhiteMixer: BlackWhiteMixer { get { pixels.blackWhiteMixer } set { pixels.blackWhiteMixer = newValue } }
    public var grain: FilmGrain { get { pixels.grain } set { pixels.grain = newValue } }
    public var sharpenRadius: Double { get { pixels.sharpenRadius } set { pixels.sharpenRadius = newValue } }
    public var sharpenDetail: Double { get { pixels.sharpenDetail } set { pixels.sharpenDetail = newValue } }
    public var sharpenMasking: Double { get { pixels.sharpenMasking } set { pixels.sharpenMasking = newValue } }
    public var colorNoiseReduction: Double? { get { pixels.colorNoiseReduction } set { pixels.colorNoiseReduction = newValue } }
    public var warmth: Double { get { pixels.warmth } set { pixels.warmth = newValue } }
    public var blur: Double { get { pixels.blur } set { pixels.blur = newValue } }
    public var curveSaturation: Double { get { pixels.curveSaturation } set { pixels.curveSaturation = newValue } }
    public var colorNoiseDetail: Double { get { pixels.colorNoiseDetail } set { pixels.colorNoiseDetail = newValue } }
    public var colorNoiseSmoothness: Double { get { pixels.colorNoiseSmoothness } set { pixels.colorNoiseSmoothness = newValue } }
    public var defringe: Defringe { get { pixels.defringe } set { pixels.defringe = newValue } }
    public var postCropVignette: PostCropVignette { get { pixels.postCropVignette } set { pixels.postCropVignette = newValue } }
    public var pointColors: [PointColor] { get { pixels.pointColors } set { pixels.pointColors = newValue } }
    public init() {}

    enum CodingKeys: String, CodingKey { case hdr, look, cameraProfile, lut, film, aces, glow, lensCorrection, luminanceNoiseDetail, luminanceNoiseContrast, curveSaturation, colorNoiseDetail, colorNoiseSmoothness, defringe, postCropVignette, pointColors, warmth, blur, retouch, redEyeCorrection, faceLiquifies, skinTone, geometry, redCurve, greenCurve, blueCurve, parametricCurve, splitToning, calibration, blackWhiteMixer, grain, sharpenRadius, sharpenDetail, sharpenMasking, colorNoiseReduction, masks, colorProfile, neutralRAW, exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, clarity, texture, dehaze, sharpness, noiseReduction, vignette, vignetteRadius, vignetteSoftness, monochrome, quarterTurns, curve, selectiveColors, disabledSections }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hdr = try c.decodeIfPresent(HDRSettings.self, forKey: .hdr) ?? HDRSettings()
        retouch = try c.decodeIfPresent([RetouchStroke].self, forKey: .retouch) ?? []
        redEyeCorrection = try c.decodeIfPresent(Bool.self, forKey: .redEyeCorrection) ?? false
        faceLiquifies = try c.decodeIfPresent([FaceLiquify].self, forKey: .faceLiquifies) ?? []
        skinTone = try c.decodeIfPresent(SkinTone.self, forKey: .skinTone)
        geometry = try c.decodeIfPresent(GeometryAdjustments.self, forKey: .geometry) ?? geometry
        masks = try c.decodeIfPresent([PhotoMask].self, forKey: .masks) ?? []
        colorProfile = try c.decodeIfPresent(ColorProfile.self, forKey: .colorProfile) ?? colorProfile
        neutralRAW = try c.decodeIfPresent(Bool.self, forKey: .neutralRAW) ?? false
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? blacks
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? clarity
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? sharpness
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? noiseReduction
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        vignetteRadius = try c.decodeIfPresent(Double.self, forKey: .vignetteRadius) ?? vignetteRadius
        vignetteSoftness = try c.decodeIfPresent(Double.self, forKey: .vignetteSoftness) ?? vignetteSoftness
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? monochrome
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? quarterTurns
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve) ?? curve
        selectiveColors = try c.decodeIfPresent([SelectiveColorAdjustment].self, forKey: .selectiveColors) ?? selectiveColors
        // A section a newer build added is skipped, not the whole list of sections turned off.
        disabledSections = try c.decodeIfPresent([String].self, forKey: .disabledSections).map { Set($0.compactMap(AdjustmentGroup.init(rawValue:))) } ?? disabledSections
        redCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .redCurve) ?? redCurve
        greenCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .greenCurve) ?? greenCurve
        blueCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .blueCurve) ?? blueCurve
        parametricCurve = try c.decodeIfPresent(ParametricCurve.self, forKey: .parametricCurve) ?? parametricCurve
        splitToning = try c.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? splitToning
        calibration = try c.decodeIfPresent(PrimaryCalibration.self, forKey: .calibration) ?? calibration
        blackWhiteMixer = try c.decodeIfPresent(BlackWhiteMixer.self, forKey: .blackWhiteMixer) ?? blackWhiteMixer
        grain = try c.decodeIfPresent(FilmGrain.self, forKey: .grain) ?? grain
        sharpenRadius = try c.decodeIfPresent(Double.self, forKey: .sharpenRadius) ?? sharpenRadius
        sharpenDetail = try c.decodeIfPresent(Double.self, forKey: .sharpenDetail) ?? sharpenDetail
        sharpenMasking = try c.decodeIfPresent(Double.self, forKey: .sharpenMasking) ?? sharpenMasking
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        look = try c.decodeIfPresent(ImportedLook.self, forKey: .look)
        cameraProfile = try c.decodeIfPresent(CameraProfile.self, forKey: .cameraProfile)
        lut = try c.decodeIfPresent(CreativeLUT.self, forKey: .lut)
        film = try c.decodeIfPresent(FilmSimulation.self, forKey: .film)
        aces = try c.decodeIfPresent(Bool.self, forKey: .aces) ?? false
        lensCorrection = try c.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? true
        luminanceNoiseDetail = try c.decodeIfPresent(Double.self, forKey: .luminanceNoiseDetail) ?? 50
        luminanceNoiseContrast = try c.decodeIfPresent(Double.self, forKey: .luminanceNoiseContrast) ?? 0
        curveSaturation = try c.decodeIfPresent(Double.self, forKey: .curveSaturation) ?? 100
        colorNoiseDetail = try c.decodeIfPresent(Double.self, forKey: .colorNoiseDetail) ?? 50
        colorNoiseSmoothness = try c.decodeIfPresent(Double.self, forKey: .colorNoiseSmoothness) ?? 50
        defringe = try c.decodeIfPresent(Defringe.self, forKey: .defringe) ?? Defringe()
        postCropVignette = try c.decodeIfPresent(PostCropVignette.self, forKey: .postCropVignette) ?? PostCropVignette()
        pointColors = try c.decodeIfPresent([PointColor].self, forKey: .pointColors) ?? []
        _ = try validated()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Stored developments leave out what equals the default, which decoding restores (`sparseKey`).
        let base = encoder.userInfo[Self.sparseKey] as? Bool == true ? Adjustments() : nil
        func put<T: Encodable & Equatable>(_ path: KeyPath<Adjustments, T>, _ key: CodingKeys) throws {
            let value = self[keyPath: path]
            if let base, base[keyPath: path] == value { return }
            try c.encode(value, forKey: key)
        }
        try put(\.hdr, .hdr)
        try c.encodeIfPresent(look, forKey: .look)
        try c.encodeIfPresent(cameraProfile, forKey: .cameraProfile)
        try c.encodeIfPresent(lut, forKey: .lut)
        try c.encodeIfPresent(film, forKey: .film)
        if aces { try put(\.aces, .aces) }
        try put(\.lensCorrection, .lensCorrection)
        try put(\.luminanceNoiseDetail, .luminanceNoiseDetail)
        try put(\.luminanceNoiseContrast, .luminanceNoiseContrast)
        try put(\.curveSaturation, .curveSaturation)
        try put(\.colorNoiseDetail, .colorNoiseDetail)
        try put(\.colorNoiseSmoothness, .colorNoiseSmoothness)
        try put(\.defringe, .defringe)
        try put(\.postCropVignette, .postCropVignette)
        try put(\.pointColors, .pointColors)
        try put(\.retouch, .retouch)
        if redEyeCorrection { try c.encode(true, forKey: .redEyeCorrection) }
        if !faceLiquifies.isEmpty { try put(\.faceLiquifies, .faceLiquifies) }
        try c.encodeIfPresent(skinTone, forKey: .skinTone)
        try put(\.geometry, .geometry)
        try put(\.redCurve, .redCurve)
        try put(\.greenCurve, .greenCurve)
        try put(\.blueCurve, .blueCurve)
        try put(\.parametricCurve, .parametricCurve)
        try put(\.splitToning, .splitToning)
        try put(\.calibration, .calibration)
        try put(\.blackWhiteMixer, .blackWhiteMixer)
        try put(\.grain, .grain)
        try put(\.sharpenRadius, .sharpenRadius)
        try put(\.sharpenDetail, .sharpenDetail)
        try put(\.sharpenMasking, .sharpenMasking)
        // Always written: a missing value means unset (nil), not the default 0.
        try c.encode(colorNoiseReduction, forKey: .colorNoiseReduction)
        try put(\.masks, .masks)
        try put(\.colorProfile, .colorProfile)
        try put(\.neutralRAW, .neutralRAW)
        try put(\.exposure, .exposure)
        try put(\.contrast, .contrast)
        try put(\.highlights, .highlights)
        try put(\.shadows, .shadows)
        try put(\.whites, .whites)
        try put(\.blacks, .blacks)
        try put(\.temperature, .temperature)
        try put(\.tint, .tint)
        try put(\.vibrance, .vibrance)
        try put(\.saturation, .saturation)
        try put(\.clarity, .clarity)
        try put(\.texture, .texture)
        try put(\.dehaze, .dehaze)
        try put(\.sharpness, .sharpness)
        try put(\.noiseReduction, .noiseReduction)
        try put(\.vignette, .vignette)
        try put(\.vignetteRadius, .vignetteRadius)
        try put(\.vignetteSoftness, .vignetteSoftness)
        try put(\.monochrome, .monochrome)
        try put(\.quarterTurns, .quarterTurns)
        try put(\.curve, .curve)
        try put(\.selectiveColors, .selectiveColors)
        // Sorted, so equal developments encode to equal bytes.
        if base == nil || !disabledSections.isEmpty { try c.encode(disabledSections.sorted { $0.rawValue < $1.rawValue }, forKey: .disabledSections) }
        try put(\.warmth, .warmth)
        try put(\.blur, .blur)
    }
    /// Set to true in an encoder's `userInfo` to leave out every value that equals `Adjustments()`'s: how the catalog
    /// stores developments and camera defaults. Decoding restores each missing value to that default.
    public static let sparseKey = CodingUserInfoKey(rawValue: "ceviche.sparseAdjustments")!

    public mutating func resetValues(for group: AdjustmentGroup, to defaults: Adjustments) {
        for key in group.keys { self[keyPath: key] = defaults[keyPath: key] }
        if group == .curve { curveSaturation = defaults.curveSaturation; curve = defaults.curve; redCurve = defaults.redCurve; greenCurve = defaults.greenCurve; blueCurve = defaults.blueCurve }
        if group == .parametricCurve { parametricCurve = defaults.parametricCurve }
        if group == .splitToning { splitToning = defaults.splitToning }
        if group == .calibration { calibration = defaults.calibration }
        if group == .blackWhite { blackWhiteMixer = defaults.blackWhiteMixer }
        if group == .grain { grain = defaults.grain }
        if group == .detail { blur = defaults.blur }
        if group == .noiseReduction { luminanceNoiseDetail = defaults.luminanceNoiseDetail; luminanceNoiseContrast = defaults.luminanceNoiseContrast; colorNoiseDetail = defaults.colorNoiseDetail; colorNoiseSmoothness = defaults.colorNoiseSmoothness; colorNoiseReduction = defaults.colorNoiseReduction }
        if group == .color { monochrome = defaults.monochrome; warmth = defaults.warmth }
        if group == .vignette { postCropVignette = defaults.postCropVignette }
        if group == .defringe { defringe = defaults.defringe }
        if group == .pointColor { pointColors = defaults.pointColors }
        if group == .selectiveColor { selectiveColors = defaults.selectiveColors }
        if group == .faceSpots { retouch.removeAll { $0.group == .face } }
        if group == .portraitLight { masks.removeAll { $0.portraitCorrection.map { !$0.isDetail } ?? false }; skinTone = nil }
        if group == .portraitDetails { masks.removeAll { $0.portraitCorrection?.isDetail ?? false }; redEyeCorrection = false }
        if group == .facialFeatures { faceLiquify = nil }
    }
    public func effective(defaults: Adjustments) -> Adjustments {
        var result = self
        for group in disabledSections { result.resetValues(for: group, to: defaults) }
        return result
    }

    public func validated() throws -> Self {
        try hdr.validate()
        guard masks.count <= PhotoMask.maxCount, Set(masks.map(\.id)).count == masks.count else { throw EditorError.invalidDocument(L10n.tr("Too many or duplicate masks.")) }
        guard retouch.count <= 200, Set(retouch.map(\.id)).count == retouch.count else { throw EditorError.invalidDocument(L10n.tr("Too many or duplicate retouch strokes.")) }
        guard faceLiquifies.count <= 20, faceLiquifies.allSatisfy(\.valid) else { throw EditorError.invalidDocument(L10n.tr("Invalid Face Liquify region.")) }
        try skinTone?.validate()
        for stroke in retouch { try stroke.validate() }
        try look?.validate(); try cameraProfile?.validate(); try lut?.validate(); try film?.validate()
        try check([luminanceNoiseDetail, luminanceNoiseContrast], in: 0...100)
        _ = try pixels.validated()
        try geometry.validate()
        for mask in masks { try mask.validate() }
        _ = try colorProfile.colorSpace()
        // The pixel controls were checked above; the global development adds RAW white balance, orientation and a
        // sharpening slider that only softens locally.
        guard temperature.isFinite, (2000...50000).contains(temperature), (0...100).contains(sharpness), (0...3).contains(quarterTurns) else {
            throw EditorError.invalidDocument(L10n.tr("Adjustment values are out of range."))
        }
        return self
    }
}

public struct ImageInfo: Codable, Sendable {
    public var filename: String
    public var width: Int
    public var height: Int
    public var camera: String
    /// Camera manufacturer, when recorded; nil for older metadata.
    public var make: String?
    public var lens: String
    public var capture: String
    public var isRAW: Bool
    public var defaults: Adjustments
    /// Per-image capability reported by the current macOS RAW decoder. Nil for older metadata.
    public var lensCorrectionSupported: Bool?
    public var sourceBitDepth: Int?
    /// Focal length and its 35 mm equivalent in millimetres, for Upright's analysis; nil when not recorded.
    public var focalLength: Double?
    public var focalLength35mm: Double?
    /// True when `defaults` hold what the catalog read from the original at import (`RawRenderer.cameraDefaults`, and
    /// whether it opens in HDR), so they are used without opening the file again; nil for older imports.
    public var defaultsFromImport: Bool?
    public init(filename: String, width: Int, height: Int, camera: String = "", lens: String = "", capture: String = "", isRAW: Bool, defaults: Adjustments, sourceBitDepth: Int? = nil, lensCorrectionSupported: Bool? = nil) {
        self.filename = filename; self.width = width; self.height = height
        self.camera = camera; self.lens = lens; self.capture = capture
        self.isRAW = isRAW; self.defaults = defaults; self.sourceBitDepth = sourceBitDepth
        self.lensCorrectionSupported = lensCorrectionSupported
    }
    /// As the catalog keeps it (`CatalogAsset.infoData`): the defaults without the values every photo shares.
    public func storedData() throws -> Data {
        let encoder = JSONEncoder(); encoder.userInfo[Adjustments.sparseKey] = true
        return try encoder.encode(self)
    }
    /// Matches camera profiles from presets against this photo's camera.
    public var profileResolver: CameraProfileResolver { CameraProfileLibrary.shared.resolver(make: make ?? "", model: camera) }
}

public enum EditorError: LocalizedError {
    case noGPU, decode, render, database(String), invalidDocument(String)
    /// A saved development this build can't read (made by an earlier one), with what in it could not be read and,
    /// when the rest can be kept, the parts that would go (`RevisionPayload.salvage`).
    case unreadableEdits(String, parts: [String] = [])
    public var errorDescription: String? {
        switch self {
        case .noGPU: return L10n.tr("A Metal-capable GPU is required.")
        case .decode: return L10n.tr("This image could not be decoded. RAW support depends on the camera and this version of macOS.")
        case .render: return L10n.tr("Core Image could not render this image.")
        case .database(let message): return L10n.tr("Document database: \(message)")
        case .invalidDocument(let message): return L10n.tr("Invalid Ceviche document: \(message)")
        case .unreadableEdits(let detail, _): return L10n.tr("Its saved edits come from an earlier version of Ceviche and can’t be read (\(detail)).")
        }
    }
}

extension EditorError {
    /// What a decoding error could not read, by its place in the edit: "skinTone › faces › 1 › amount is missing".
    public static func describe(_ error: DecodingError) -> String {
        let path = place
        switch error {
        case .keyNotFound(let key, let context): return L10n.tr("\(path(context.codingPath + [key])) is missing")
        case .valueNotFound(_, let context): return L10n.tr("\(path(context.codingPath)) is empty")
        case .typeMismatch(_, let context): return L10n.tr("\(path(context.codingPath)) has an unexpected kind of value")
        case .dataCorrupted(let context): return context.codingPath.isEmpty ? L10n.tr("the data is damaged") : L10n.tr("\(path(context.codingPath)) is damaged")
        @unknown default: return error.localizedDescription
        }
    }
    /// A place in an edit, items counted from 1: "skinTone › faces › 1".
    public static func place(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { String($0 + 1) } ?? $0.stringValue }.joined(separator: " › ")
    }
}

extension Adjustments {
    /// The rendering in use: an enabled film (in a build with the film engine), else ACES, else the camera's.
    public var rendering: Rendering {
        if let film, film.enabled, film.film != nil, FilmCatalog.shared.isAvailable { return .film }
        return aces ? .aces : .camera
    }
}
