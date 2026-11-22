import Foundation

/// The photographic filters the Filters dialog applies on the way out. Scene filters work on the developed photo's
/// light, as a filter on the lens would; print filters work on the picture at its output size.
public enum CreativeFilterKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case glow, diffusion, bloom, polarizer, denoise, bokeh, proContrast, tonalContrast, detailExtractor, bleachBypass, crossProcess, center, fog, reflector, lightLeak, dust, border, outputSharpen
    public var id: String { rawValue }
    public enum Slot: Sendable { case scene, print }
    public var slot: Slot {
        switch self {
        case .glow, .diffusion, .bloom, .polarizer, .denoise, .bokeh: .scene
        case .proContrast, .tonalContrast, .detailExtractor, .bleachBypass, .crossProcess, .center, .fog, .reflector, .lightLeak, .border, .outputSharpen, .dust: .print
        }
    }
    /// Where a filter goes when it is switched on: noise before anything spreads it, the sky before the veils over
    /// it, tone before colour, light on the picture after both, sharpening last.
    public static let renderOrder: [CreativeFilterKind] = [.denoise, .polarizer, .bokeh, .diffusion, .bloom, .glow,
                                                           .proContrast, .tonalContrast, .detailExtractor, .bleachBypass, .crossProcess,
                                                           .fog, .reflector, .center, .lightLeak, .dust, .border, .outputSharpen]
    /// The library's groups, by what a filter is for.
    public static var groups: [(title: String, kinds: [CreativeFilterKind])] {
        [(L10n.tr("Lens"), [.glow, .diffusion, .bloom, .bokeh, .polarizer, .denoise]),
         (L10n.tr("Contrast"), [.proContrast, .tonalContrast, .detailExtractor]),
         (L10n.tr("Color"), [.bleachBypass, .crossProcess]),
         (L10n.tr("Light"), [.center, .fog, .reflector, .lightLeak]),
         (L10n.tr("Finish"), [.dust, .border, .outputSharpen])]
    }

    public var title: String {
        switch self {
        case .glow: L10n.tr("Glow")
        case .diffusion: L10n.tr("Diffusion")
        case .bloom: L10n.tr("Bloom")
        case .polarizer: L10n.tr("Polarizer")
        case .denoise: L10n.tr("AI Noise Reduction")
        case .proContrast: L10n.tr("Pro Contrast")
        case .tonalContrast: L10n.tr("Tonal Contrast")
        case .detailExtractor: L10n.tr("Detail Extractor")
        case .center: L10n.tr("Darken / Lighten Center")
        case .bokeh: L10n.tr("Bokeh")
        case .bleachBypass: L10n.tr("Bleach Bypass")
        case .crossProcess: L10n.tr("Cross Processing")
        case .fog: L10n.tr("Fog")
        case .reflector: L10n.tr("Reflector")
        case .lightLeak: L10n.tr("Light Leak")
        case .dust: L10n.tr("Dust & Scratches")
        case .border: L10n.tr("Border", context: "frame")
        case .outputSharpen: L10n.tr("Output Sharpening")
        }
    }
    public var symbol: String {
        switch self {
        case .glow: "sun.haze"
        case .diffusion: "aqi.medium"
        case .bloom: "sparkles"
        case .polarizer: "circle.lefthalf.filled"
        case .denoise: "wand.and.sparkles"
        case .proContrast: "wand.and.rays"
        case .tonalContrast: "circle.righthalf.filled.inverse"
        case .detailExtractor: "circle.hexagongrid.fill"
        case .center: "smallcircle.filled.circle"
        case .bokeh: "camera.aperture"
        case .bleachBypass: "drop.halffull"
        case .crossProcess: "arrow.triangle.swap"
        case .fog: "cloud.fog"
        case .reflector: "sun.max"
        case .lightLeak: "rays"
        case .dust: "circle.dotted"
        case .border: "square.dashed"
        case .outputSharpen: "triangle"
        }
    }
    /// What Amount runs to, in percent, and where it starts.
    public var amountRange: ClosedRange<Double> {
        switch self {
        case .bloom: 0...30
        case .border: 0...20
        case .outputSharpen: 0...200
        default: 0...100
        }
    }
    public var defaultAmount: Double {
        switch self {
        case .glow: 30
        // About 1 % is a real lens at f/8; a filter one reaches for is several times that.
        case .bloom: 5
        case .diffusion, .denoise, .reflector, .lightLeak, .bokeh, .dust: 50
        case .fog: 40
        case .bleachBypass, .crossProcess: 70
        // Percent of the long side.
        case .border: 4
        case .detailExtractor: 25
        case .polarizer, .proContrast, .tonalContrast, .center, .outputSharpen: 100
        }
    }
    /// What Amount is called on the row; a border's is its width.
    public var amountTitle: String { self == .border ? L10n.tr("Width") : L10n.tr("Amount") }
    /// True for a filter placed on the picture: its "x" and "y" are a point in percent from the top left.
    public var isPlaced: Bool { self == .center || self == .bokeh }
    public var parameters: [CreativeFilterParameter] {
        switch self {
        case .glow:
            [.init("style", L10n.tr("Style"), 0...Double(Glow.Style.allCases.count - 1), 0, choices: Glow.Style.allCases.map(\.title)),
             .init("size", L10n.tr("Size"), 0...100, 30), .init("threshold", L10n.tr("Threshold"), 0...100, 60),
             .init("angle", L10n.tr("Angle"), -90...90, 0, unit: "°")]
        case .diffusion:
            [.init("type", L10n.tr("Type"), 0...Double(DiffusionShape.fitted.count), 0, choices: [L10n.tr("Custom")] + DiffusionShape.fitted.map(\.name)),
             .init("size", L10n.tr("Size"), 0...100, 50)]
        case .bloom:
            [.init("size", L10n.tr("Size"), 0...100, 50)]
        case .polarizer:
            [.init("azimuth", L10n.tr("Sun Direction"), -180...180, 90, unit: "°"), .init("elevation", L10n.tr("Sun Height"), 0...90, 30, unit: "°"),
             .init("tilt", L10n.tr("Camera Tilt"), -45...45, 0, unit: "°"),
             .init("rotation", L10n.tr("Rotation"), 0...1, 0, choices: [L10n.tr("Auto"), L10n.tr("Manual")]),
             .init("angle", L10n.tr("Angle"), 0...180, 0, unit: "°")]
        case .denoise: []
        case .tonalContrast:
            [.init("highs", L10n.tr("Highlights"), -100...100, 30), .init("mids", L10n.tr("Midtones"), -100...100, 30),
             .init("shadows", L10n.tr("Shadows"), -100...100, 30), .init("radius", L10n.tr("Radius"), 0...100, 40)]
        case .proContrast:
            [.init("cast", L10n.tr("Color Cast"), 0...100, 0), .init("contrast", L10n.tr("Contrast"), 0...100, 50),
             .init("dynamic", L10n.tr("Dynamic"), 0...100, 30)]
        case .detailExtractor:
            [.init("contrast", L10n.tr("Contrast"), -100...100, 0), .init("saturation", L10n.tr("Saturation"), -100...100, 0),
             .init("radius", L10n.tr("Radius"), 0...2, 1, choices: [L10n.tr("Fine"), L10n.tr("Normal"), L10n.tr("Large")])]
        case .center:
            [.init("center", L10n.tr("Center"), -100...100, 25), .init("border", L10n.tr("Border"), -100...100, -50),
             .init("size", L10n.tr("Size"), 0...100, 50),
             .init("shape", L10n.tr("Shape"), 0...1, 1, choices: [L10n.tr("Round"), L10n.tr("Oval")]),
             .init("x", L10n.tr("Horizontal"), 0...100, 50), .init("y", L10n.tr("Vertical"), 0...100, 50)]
        case .bokeh:
            [.init("shape", L10n.tr("Shape"), 0...1, 0, choices: [L10n.tr("Radial"), L10n.tr("Tilt-Shift")]),
             .init("size", L10n.tr("Size"), 0...100, 40), .init("falloff", L10n.tr("Falloff"), 0...100, 50),
             .init("angle", L10n.tr("Angle"), -90...90, 0, unit: "°"), .init("highlights", L10n.tr("Highlights"), 0...100, 30),
             .init("x", L10n.tr("Horizontal"), 0...100, 50), .init("y", L10n.tr("Vertical"), 0...100, 50)]
        case .bleachBypass:
            [.init("contrast", L10n.tr("Contrast"), 0...100, 60), .init("saturation", L10n.tr("Saturation"), 0...100, 40)]
        case .crossProcess:
            [.init("method", L10n.tr("Film"), 0...1, 0, choices: [L10n.tr("Slide"), L10n.tr("Negative")])]
        case .fog:
            [.init("cover", L10n.tr("Cover"), 0...2, 0, choices: [L10n.tr("All"), L10n.tr("Top"), L10n.tr("Bottom")]),
             .init("level", L10n.tr("Horizon"), 0...100, 50)]
        case .reflector:
            [.init("tone", L10n.tr("Tone"), 0...2, 0, choices: [L10n.tr("Gold"), L10n.tr("Soft Gold"), L10n.tr("Silver")]),
             .init("direction", L10n.tr("Direction"), -180...180, 0, unit: "°"), .init("position", L10n.tr("Position"), 0...100, 50),
             .init("falloff", L10n.tr("Falloff"), 0...100, 50)]
        case .lightLeak:
            [.init("tone", L10n.tr("Tone"), 0...2, 0, choices: [L10n.tr("Warm"), L10n.tr("Red"), L10n.tr("Cool")]),
             .init("edge", L10n.tr("Edge"), 0...3, 0, choices: [L10n.tr("Left"), L10n.tr("Top"), L10n.tr("Right"), L10n.tr("Bottom")]),
             .init("position", L10n.tr("Position"), 0...100, 30), .init("size", L10n.tr("Size"), 0...100, 50)]
        case .dust:
            [.init("texture", L10n.tr("Texture"), 0...Double(FilmTexture.all.count - 1), 1, choices: FilmTexture.all.map(\.title)),
             .init("tone", L10n.tr("Tone"), 0...1, 0, choices: [L10n.tr("White"), L10n.tr("Black")]),
             .init("size", L10n.tr("Size"), 0...100, 30),
             .init("variation", L10n.tr("Variation"), 0...3, 0, choices: ["1", "2", "3", "4"])]
        case .border:
            [.init("style", L10n.tr("Style"), 0...Double(BorderChoice.titles.count - 1), 0, choices: BorderChoice.titles),
             .init("tone", L10n.tr("Tone"), 0...1, 0, choices: [L10n.tr("White"), L10n.tr("Black")])]
        case .outputSharpen:
            [.init("medium", L10n.tr("For"), 0...2, 0, choices: [L10n.tr("Screen"), L10n.tr("Glossy"), L10n.tr("Matte")])]
        }
    }
    /// The develop settings this filter does the job of: with it in the stack the photo is developed without them.
    public var replaces: CreativeFilterStack.SetAside? {
        switch self {
        case .denoise: .noiseReduction
        case .outputSharpen: .sharpening
        default: nil
        }
    }
}

/// One of a filter's own controls: a slider, or a choice when `choices` is set (the value is the choice's index).
public struct CreativeFilterParameter: Sendable, Identifiable {
    public let key: String
    public let title: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let unit: String
    public let choices: [String]?
    public var id: String { key }
    init(_ key: String, _ title: String, _ range: ClosedRange<Double>, _ defaultValue: Double, unit: String = "", choices: [String]? = nil) {
        self.key = key; self.title = title; self.range = range; self.defaultValue = defaultValue; self.unit = unit; self.choices = choices
    }
}

/// A filter in the stack: what it is, how strongly it applies, and its own settings by parameter key. Sizes are
/// fractions of the long side, so a preview and the full-size file filter alike.
public struct CreativeFilter: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: CreativeFilterKind
    public var enabled = true
    /// In percent, within the kind's `amountRange`.
    public var amount: Double
    public var values: [String: Double] = [:]

    public init(_ kind: CreativeFilterKind, amount: Double? = nil, _ values: [String: Double] = [:]) {
        self.kind = kind; self.amount = amount ?? kind.defaultAmount; self.values = values
    }
    /// A parameter's value, or its default where the filter doesn't set one.
    public subscript(key: String) -> Double {
        get { values[key] ?? kind.parameters.first { $0.key == key }?.defaultValue ?? 0 }
        set { values[key] = newValue }
    }
    /// A Glow filter's style.
    public var glowStyle: Glow.Style { Glow.Style(rawValue: Int(self["style"].rounded())) ?? .halo }
    /// A Border filter's style.
    public var borderChoice: BorderChoice { BorderChoice(index: Int(self["style"].rounded())) }
    public var isDefault: Bool { amount == kind.defaultAmount && kind.parameters.allSatisfy { self[$0.key] == $0.defaultValue } }
    public mutating func reset() { amount = kind.defaultAmount; values = [:] }

    func validate() throws {
        guard amount.isFinite, kind.amountRange.contains(amount) else { throw EditorError.invalidDocument(L10n.tr("Invalid filter settings.")) }
        for (key, value) in values {
            guard let parameter = kind.parameters.first(where: { $0.key == key }), value.isFinite, parameter.range.contains(value) else {
                throw EditorError.invalidDocument(L10n.tr("Invalid filter settings."))
            }
        }
    }
}

/// The filters applied to a photo on the way out, in order within their slot: scene filters first, then, at the
/// output size, print filters.
public struct CreativeFilterStack: Codable, Equatable, Sendable {
    public var filters: [CreativeFilter] = []
    public init(_ filters: [CreativeFilter] = []) { self.filters = filters }

    public enum SetAside: String, Sendable, CaseIterable {
        case noiseReduction, sharpening
        public var title: String { self == .noiseReduction ? L10n.tr("Noise Reduction") : L10n.tr("Sharpening") }
    }
    var active: [CreativeFilter] { filters.filter { $0.enabled && $0.amount > 0 } }
    public var isEmpty: Bool { active.isEmpty }
    /// The develop settings the stack's filters replace.
    public var setAside: [SetAside] { SetAside.allCases.filter { aside in active.contains { $0.kind.replaces == aside } } }
    /// The filters that are on, in the order they apply: those on the photo's light, then those on the finished
    /// picture, the border last.
    public var applied: [CreativeFilter] {
        let on = filters.filter(\.enabled)
        return on.filter { $0.kind.slot == .scene } + on.filter { $0.kind.slot == .print && $0.kind != .border } + on.filter { $0.kind == .border }
    }
    /// What AI Noise Reduction's tiles depend on besides the photo: the lens filters before it and the develop
    /// settings the stack sets aside. Nil while the filter is off; while it stays the same, a preview can keep the tiles.
    public struct DenoiseInput: Equatable, Sendable { let before: [CreativeFilter], setAside: [SetAside] }
    public var denoiseInput: DenoiseInput? {
        let scene = active.filter { $0.kind.slot == .scene }
        guard let index = scene.firstIndex(where: { $0.kind == .denoise }) else { return nil }
        return DenoiseInput(before: Array(scene[..<index]), setAside: setAside)
    }
    /// One of each filter at most, in `CreativeFilterKind.renderOrder`.
    public func ordered() -> CreativeFilterStack {
        CreativeFilterStack(CreativeFilterKind.renderOrder.compactMap { kind in filters.first { $0.kind == kind } })
    }
    public func validated() throws -> CreativeFilterStack {
        guard filters.count <= 32 else { throw EditorError.invalidDocument(L10n.tr("Too many filters.")) }
        try filters.forEach { try $0.validate() }
        return self
    }

    /// Where the photo sits inside the stack's border; none without one.
    public var border: BorderLayout {
        guard let border = active.last(where: { $0.kind == .border }) else { return .none }
        switch border.borderChoice {
        case .drawn(let style): return .margins(style.insets(width: border.amount / 100))
        case .asset(let asset): return .opening(asset.opening, turns: asset.turns)
        }
    }

    /// `adjustments` without the develop settings the stack replaces, so they aren't applied twice.
    func developing(_ adjustments: Adjustments) -> Adjustments {
        var next = adjustments
        for aside in setAside {
            switch aside {
            case .noiseReduction: next.pixels.noiseReduction = 0; next.pixels.colorNoiseReduction = 0
            case .sharpening: next.pixels.sharpness = 0
            }
        }
        return next
    }
}

/// A real diffusion filter's spread, fitted from tripod pairs shot with and without it: a share of the light moved by a
/// core Gaussian and a share by a tail Gaussian, widths in fractions of the long side. The rest stays where it was, so
/// light is moved, not added. Amount 50 is the filter as measured.
public struct DiffusionShape: Sendable, Equatable {
    public let name: String
    public let core: Double, coreWidth: Double
    public let tail: Double, tailWidth: Double
    /// From fits to soft-focus and diffuser filters on a still-life series (see the Diffusion prototype in git history):
    /// mild image softeners, a medium and a strong soft focus, one whose tail reaches 1.6 %, and a diffuser with a strong
    /// tail (its 104 % of moved light is scaled to all of it).
    public static let fitted: [DiffusionShape] = [
        .init(name: L10n.tr("Light", context: "strength"), core: 0.71, coreWidth: 0.001, tail: 0.02, tailWidth: 0.008),
        .init(name: L10n.tr("Medium"), core: 0.67, coreWidth: 0.001, tail: 0.12, tailWidth: 0.008),
        .init(name: L10n.tr("Strong"), core: 0.86, coreWidth: 0.001, tail: 0.13, tailWidth: 0.008),
        .init(name: L10n.tr("Long Tail"), core: 0.49, coreWidth: 0.001, tail: 0.09, tailWidth: 0.016),
        .init(name: L10n.tr("Diffuser"), core: 0.58, coreWidth: 0.001, tail: 0.42, tailWidth: 0.008),
    ]
    /// The shape for a Diffusion filter's Type, nil for Custom.
    public static func of(_ filter: CreativeFilter) -> DiffusionShape? {
        let index = Int(filter["type"].rounded())
        return fitted.indices.contains(index - 1) ? fitted[index - 1] : nil
    }
}

/// A stack saved by name.
public struct CreativeFilterRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var stack: CreativeFilterStack
    public init(name: String, stack: CreativeFilterStack) { self.name = name; self.stack = stack }

    /// Starting points the library always offers. Strengths are from fits to real filters: a soft-focus
    /// filter is Diffusion at 40–85 %, a mist filter mostly veil.
    public static let builtIn: [CreativeFilterRecipe] = [
        .init(name: L10n.tr("Soft Focus"), stack: .init([CreativeFilter(.diffusion, amount: 60, ["size": 50])])),
        .init(name: L10n.tr("Mist"), stack: .init([CreativeFilter(.diffusion, amount: 25, ["size": 70]), CreativeFilter(.bloom, amount: 10, ["size": 60])])),
        .init(name: L10n.tr("Highlight Glow"), stack: .init([CreativeFilter(.glow, amount: 45, ["size": 40, "threshold": 55])])),
        .init(name: L10n.tr("Halation"), stack: .init([CreativeFilter(.glow, amount: 40, ["style": Double(Glow.Style.halation.rawValue), "size": 30, "threshold": 50])])),
        .init(name: L10n.tr("Clear Sky"), stack: .init([CreativeFilter(.polarizer)])),
        .init(name: L10n.tr("Detail"), stack: .init([CreativeFilter(.tonalContrast, amount: 100, ["highs": 20, "mids": 45, "shadows": 35, "radius": 30])])),
        .init(name: L10n.tr("Dramatic"), stack: .init([CreativeFilter(.polarizer), CreativeFilter(.tonalContrast, amount: 100, ["highs": 40, "mids": 60, "shadows": 50, "radius": 60])])),
    ]
}
