import Foundation

/// A film the photo is exposed on, developed and finished on an output medium (a paper, a print film, a scan or the
/// film itself), by the film print. It takes the RAW's scene light in place of the camera's tone response, so
/// Exposure exposes the film; the other adjustments work on the scene before it.
public struct FilmSimulation: Codable, Equatable, Sendable {
    public var enabled = true
    public var stock = FilmSimulation.defaultStock
    /// The output medium (`FilmMedium.id`); nil is the one the film is made for.
    public var medium: String?
    /// How a scan to the screen places the film's tones, and the grade of its curve (0 soft … 5 hard, 2 normal).
    public var style = FilmScanStyle.auto
    public var grade = 2.0
    /// Stops lighter (positive) or darker than the medium's own timing: the enlarger's or printer's exposure on a
    /// print, the scanner's on a scan.
    public var printExposure = 0.0
    /// The print's color balance in CC units (0.01 log exposure): positive adds that color to the picture, through
    /// the enlarger's filtration, the printer's lights or the scan's correction.
    public var yellow = 0.0, magenta = 0.0
    /// The enlarger's lamp house, for a paper print.
    public var head = FilmHead.diffuser
    /// Paper preflash, in percent of the paper's mid exposure: it softens the print's highlights.
    public var preflash = 0.0
    /// How much the print holds back its shadows and burns in its highlights, in percent.
    public var dodge = 0.0, burn = 0.0
    /// The frame the photo is taken to fill, which sets how large grain and halation are against it.
    public var format = FilmGauge.mm35
    /// The light the scene was lit by. Balanced exposes neutrals neutral, as under the film's own light; another
    /// light keeps its color on the film, as tungsten light goes warm on daylight film.
    public var light = SceneLight.balanced
    /// Stops of push (positive) or pull development; only the conditions the stock lists render.
    public var push = 0.0
    /// The silver the bleach leaves in the film, in percent: 100 skips the bleach.
    public var bleachBypass = 0.0
    /// Years the roll sat past its date.
    public var expired = 0.0
    /// Percentages of the stock's own grain, halation and DIR coupler effect.
    public var grain = 100.0, halation = 100.0, couplers = 100.0
    /// Fixed, persisted seed, so previews, exports, undo and reopening show the same grain.
    public var seed: UInt32 = 1
    /// How much of the film rendering shows over the camera's own, in percent, as a look's strength.
    public var amount = 100.0
    /// Groups of settings switched off, which render at their defaults until switched back on.
    public enum Part: String, Codable, CaseIterable, Sendable { case develop, print, texture }
    public var off: Set<Part> = []
    public static let defaultStock = "portra400"
    public init() {}
    public init(stock: String) {
        self.stock = stock
        if let film { format = film.gauge }
    }

    public var film: FilmProfile? { FilmCatalog.shared.film(stock) }
    /// The medium in use: the chosen one where the film can reach it, else the film's own.
    public var output: FilmMedium? { film?.medium(medium) }
    /// The settings as rendered: switched-off parts at their defaults. The stock and medium stay.
    public var rendered: FilmSimulation {
        var result = self
        let defaults = FilmSimulation()
        if off.contains(.develop) {
            result.format = film?.gauge ?? defaults.format; result.light = defaults.light
            result.push = 0; result.bleachBypass = 0; result.expired = 0
        }
        if off.contains(.print) {
            result.style = defaults.style; result.grade = defaults.grade; result.printExposure = 0; result.yellow = 0; result.magenta = 0
            result.head = defaults.head; result.preflash = 0; result.dodge = 0; result.burn = 0
        }
        if off.contains(.texture) { result.grain = defaults.grain; result.halation = defaults.halation; result.couplers = defaults.couplers }
        if let film, !film.pushes.contains(result.push) { result.push = 0 }
        result.off = []
        return result
    }

    /// These settings with another stock, switched on: on its own medium and gauge, and without a push it can't take.
    public func with(stock: FilmProfile) -> FilmSimulation {
        var settings = self
        settings.enabled = true; settings.stock = stock.id; settings.medium = nil; settings.format = stock.gauge
        if !stock.pushes.contains(settings.push) { settings.push = 0 }
        return settings
    }
    public mutating func choose(stock id: String) {
        guard let film = FilmCatalog.shared.film(id) else { return }
        self = with(stock: film)
    }

    enum CodingKeys: String, CodingKey {
        case enabled, stock, medium, style, grade, printExposure, yellow, magenta, head, preflash, dodge, burn, format, light, push, bleachBypass, expired
        case grain, halation, couplers, seed, amount, off
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys, _ fallback: Double) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? fallback }
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // A stock the catalog lacks (from a pack since removed) stays as saved: it renders without the
        // film, and the Darkroom says so.
        stock = try c.decode(String.self, forKey: .stock)
        medium = try c.decodeIfPresent(String.self, forKey: .medium)
        style = (try? c.decodeIfPresent(FilmScanStyle.self, forKey: .style)) ?? .auto
        grade = try number(.grade, 2)
        printExposure = try number(.printExposure, 0)
        yellow = try number(.yellow, 0); magenta = try number(.magenta, 0)
        head = (try? c.decodeIfPresent(FilmHead.self, forKey: .head)) ?? .diffuser
        preflash = try number(.preflash, 0)
        dodge = try number(.dodge, 0); burn = try number(.burn, 0)
        format = (try? c.decodeIfPresent(FilmGauge.self, forKey: .format)) ?? .mm35
        light = (try? c.decodeIfPresent(SceneLight.self, forKey: .light)) ?? .balanced
        push = try number(.push, 0)
        bleachBypass = try number(.bleachBypass, 0); expired = try number(.expired, 0)
        grain = try number(.grain, 100); halation = try number(.halation, 100); couplers = try number(.couplers, 100)
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        amount = try number(.amount, 100)
        off = Set((try c.decodeIfPresent([String].self, forKey: .off) ?? []).compactMap(Part.init))
    }
    func validate() throws {
        guard !stock.isEmpty, stock.count < 100, (medium?.count ?? 0) < 100,
              printExposure.isFinite, (-5...5).contains(printExposure), grade.isFinite, (0...5).contains(grade),
              [yellow, magenta].allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              [grain, halation, couplers].allSatisfy({ $0.isFinite && (0...200).contains($0) }),
              [amount, dodge, burn, bleachBypass].allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              preflash.isFinite, (0...10).contains(preflash), push.isFinite, (-3...3).contains(push),
              expired.isFinite, (0...50).contains(expired) else {
            throw EditorError.invalidDocument(L10n.tr("Invalid film settings."))
        }
    }
}

/// The light a scene was lit by, as the film sees it.
public enum SceneLight: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case balanced = "Balanced", daylight = "Daylight", shade = "Shade", tungsten = "Tungsten"
    /// The light's color temperature; nil for the film's own.
    public var kelvin: Double? {
        switch self { case .balanced: return nil; case .daylight: return 5500; case .shade: return 7500; case .tungsten: return 3200 }
    }
}

/// How a scan to the screen places the film's tones: a fixed calibrated exposure, that exposure through a graded
/// paper curve, or each frame timed by its own highlights as a lab scanner does.
public enum FilmScanStyle: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case auto = "Auto", graded = "Graded", fixed = "Fixed"
}

/// An enlarger's lamp house: a condenser prints harder than a diffuser, black-and-white most of all.
public enum FilmHead: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case diffuser = "Diffuser", condenser = "Condenser"
}

/// Film gauges and formats by their frame.
public enum FilmGauge: String, Codable, CaseIterable, Sendable {
    public var localizedTitle: String { L10n.key(rawValue) }

    case super8 = "Super 8", mm16 = "16 mm", super35 = "Super 35", halfFrame = "Half frame", mm35 = "35 mm"
    case mf645 = "6×4.5", mf66 = "6×6", mf67 = "6×7", mf69 = "6×9", lf45 = "4×5", instaxMini = "instax mini", instaxWide = "instax wide"
    /// The frame's short and long sides in millimeters.
    public var frame: (short: Double, long: Double) {
        switch self {
        case .super8: return (4.01, 5.79)
        case .mm16: return (7.4, 12.5)
        case .super35: return (18.7, 24.9)
        case .halfFrame: return (18, 24)
        case .mm35: return (24, 36)
        case .mf645: return (41.5, 56)
        case .mf66: return (56, 56)
        case .mf67: return (56, 70)
        case .mf69: return (56, 84)
        case .lf45: return (95, 120)
        case .instaxMini: return (46, 62)
        case .instaxWide: return (62, 99)
        }
    }
}
