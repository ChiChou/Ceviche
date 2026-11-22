import Foundation
import FilmPrint

/// Where a developed film is finished: a paper under an enlarger, a release print film, a scan or the film itself.
/// `id` is Fotufilm's name for it, which edits save.
public struct FilmMedium: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case paper, printFilm, scan, view }
    public let id: String
    public let kind: Kind
    /// Papers and print films keep their makers' names; the scans and views are Ceviche's words.
    enum Label: Hashable, Sendable { case stock(String), scan, labScan, telecine, negative, transparency, instant }
    let label: Label
    /// What the print settings reach on this medium, for the film it was listed for.
    public let hasExposure: Bool, hasBalance: Bool, hasHead: Bool, hasStyle: Bool, hasGrade: Bool, hasDetail: Bool
    public var name: String {
        switch label {
        case .stock(let name): return name
        case .scan: return L10n.tr("Scan")
        case .labScan: return L10n.tr("Lab Scan")
        case .telecine: return L10n.tr("Telecine")
        case .negative: return L10n.tr("Negative", context: "film medium")
        case .transparency: return L10n.tr("Transparency")
        case .instant: return L10n.tr("Instant Print")
        }
    }
}

/// A film stock from Fotufilm's profiles (CC BY-SA 4.0, MUAStudio Inc.), as the Darkroom lists it.
public struct FilmProfile: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case negative, slide, monochrome, cine, creative, instant }
    public let id: String
    public let name: String
    /// The maker, where the profile names one.
    public let maker: String?
    public let kind: Kind
    public let isPositive: Bool
    public let isMonochrome: Bool
    /// The gauge the stock is known on.
    public let gauge: FilmGauge
    /// The developments the stock lists, in stops, normal (0) included.
    public let pushes: [Double]
    /// The media the film can be finished on, the one it is made for first in `own`.
    public let media: [FilmMedium]
    public let own: String

    /// The medium an edit asks for where this film reaches it, else its own.
    public func medium(_ id: String?) -> FilmMedium? {
        media.first { $0.id == id } ?? media.first { $0.id == own } ?? media.first
    }
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Fotufilm's stocks and what the film print can do with each, read once.
public final class FilmCatalog: @unchecked Sendable {
    public static let shared = FilmCatalog()
    public let films: [FilmProfile]
    private let stocks: [String: FilmPrint.FilmStock]
    /// Whether the Mac has a GPU for the film print. Without one a film renders as the camera's own picture and the
    /// Darkroom says so.
    public let isAvailable: Bool

    public func film(_ id: String) -> FilmProfile? { films.first { $0.id == id } }
    public func films(_ kind: FilmProfile.Kind) -> [FilmProfile] { films.filter { $0.kind == kind } }

    private init() {
        #if canImport(Metal)
        isAvailable = FilmPrintRenderer.shared != nil
        // The kernels compile while the Darkroom is still being looked at.
        DispatchQueue.global(qos: .utility).async { FilmPrintRenderer.shared?.prepare() }
        #else
        isAvailable = false
        #endif
        let definitions = FilmPrint.FilmStock.presetDefinitions
        var stocks: [String: FilmPrint.FilmStock] = [:], films: [FilmProfile] = []
        for id in FilmPrint.FilmStock.presetIDs {
            guard let stock = FilmPrint.FilmStock.named(id) else { continue }
            let definition = definitions[id]
            let gauge = Self.gauge(definition?.nativeFormatID)
            let media = PrintPaper.choices(for: stock).filter { !$0.deliversCodeValues }.map { Self.medium($0, for: stock) }
            let kind: FilmProfile.Kind = stock.isReflectionPrint ? .instant : stock.isMonochrome ? .monochrome
                : Self.creative.contains(where: id.hasPrefix) ? .creative : gauge == .super35 ? .cine : stock.isReversal ? .slide : .negative
            stocks[id] = stock
            films.append(FilmProfile(id: id, name: definition?.name ?? stock.name,
                                     maker: definition?.subtitle?.components(separatedBy: " · ").first, kind: kind,
                                     isPositive: stock.isReversal, isMonochrome: stock.isMonochrome, gauge: gauge,
                                     pushes: ([0] + stock.supportedDevelopmentStops.map(Double.init)).sorted(),
                                     media: media, own: PrintPaper.default(for: stock).id))
        }
        self.stocks = stocks
        self.films = films.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Stocks whose colors are the point: Lomography's and the false-color infrared films.
    private static let creative = ["lomo", "aerochrome", "infrared"]
    private static func gauge(_ id: String?) -> FilmGauge {
        switch id {
        case "super8": return .super8
        case "16mm": return .mm16
        case "super35": return .super35
        case "120": return .mf66
        case "4x5": return .lf45
        case "instaxmini", "instaxsquare": return .instaxMini
        case "instaxwide": return .instaxWide
        default: return .mm35
        }
    }
    private static func medium(_ paper: PrintPaper, for stock: FilmPrint.FilmStock) -> FilmMedium {
        let enlarged = Enlarger.illuminates(stock: stock, paper: paper), released = PrinterLights.applies(stock: stock, paper: paper)
        let screen = paper == .screen && !stock.isReflectionPrint, scanned = screen || paper == .labScan
        let color = !stock.isMonochrome
        let kind: FilmMedium.Kind, label: FilmMedium.Label
        if let print = paper.printStock {
            kind = print.process.isProjected ? .printFilm : .paper; label = .stock(print.name)
        } else {
            kind = paper.isNegative || stock.isReversal ? .view : .scan
            switch paper {
            case .labScan: label = .labScan
            case .telecine: label = .telecine
            case .negative: label = .negative
            default: label = stock.isReflectionPrint ? .instant : stock.isReversal ? .transparency : .scan
            }
        }
        return FilmMedium(id: paper.id, kind: kind, label: label,
                          hasExposure: enlarged || released || scanned,
                          hasBalance: color && (enlarged || released || (scanned && !stock.isReversal)),
                          hasHead: enlarged, hasStyle: screen, hasGrade: screen && !stock.isReversal, hasDetail: !paper.isNegative)
    }

    /// A film as the engine takes it: the stock and the options `settings` ask of it, the same at any size, so a
    /// preview and the export differ only in how many pixels the frame has. Nil for a stock the catalog lacks.
    func development(_ settings: FilmSimulation) -> FilmDevelopment? {
        guard let stock = stocks[settings.stock], let profile = film(settings.stock), let medium = profile.medium(settings.medium),
              let paper = PrintPaper(rawValue: medium.id) else { return nil }
        var o = FilmOptions()
        o.paper = paper
        let frame = settings.format.frame
        o.format = FilmPrint.FilmFormat(name: settings.format.rawValue, frameHeightMM: Float(frame.short), frameAspectRatio: Float(frame.long / frame.short),
                                           base: Self.native(settings.format).base)
        o.seed = UInt64(settings.seed)
        o.grainScale = Float(settings.grain / 100); o.halationScale = Float(settings.halation / 100); o.couplerScale = Float(settings.couplers / 100)
        o.sceneIlluminantKelvin = settings.light.kelvin.map { Float($0) }
        if stock.supportsDevelopment(stops: Float(settings.push)) { o.developmentEV = Float(settings.push) }
        o.bleachBypass = Float(settings.bleachBypass / 100); o.expiredYears = Float(settings.expired)
        if medium.hasDetail { o.shadowDetail = Float(settings.dodge / 100); o.highlightDetail = Float(settings.burn / 100) }
        let exposure = medium.hasExposure ? Float(settings.printExposure) : 0
        let magenta = medium.hasBalance ? Float(settings.magenta) : 0, yellow = medium.hasBalance ? Float(settings.yellow) : 0
        if medium.hasHead {
            o.enlarger = settings.head == .condenser ? .condenser : .diffuser
            o.printerPreflash = Float(settings.preflash / 100)
            // The enlarger's own timing and filtration until one is asked for. A lighter print is less exposure on a
            // paper that darkens with light and more on Ilfochrome, which lightens; filtration follows the same way.
            if exposure != 0 || magenta != 0 || yellow != 0 {
                let sign: Float = paper.isPositivePaper ? 1 : -1, neutral = PrinterProfile.simulatedTungsten
                o.printer = PrinterProfile(lampKelvin: neutral.lampKelvin, exposureEV: sign * exposure,
                                           magenta: neutral.magenta + sign * magenta / 100, yellow: neutral.yellow + sign * yellow / 100)
            }
        } else if medium.kind == .printFilm {
            // Twelve printer points to the stop, 0.025 log exposure each; more green light adds magenta, more blue yellow.
            let base = PrinterLights.centre - exposure * 0.30103 / PrinterLights.logExposurePerPoint
            let point = 0.01 / PrinterLights.logExposurePerPoint
            o.printerLights = PrinterLights(red: base, green: base + magenta * point, blue: base + yellow * point)
        } else if medium.hasExposure {
            o.screenExposureEV = exposure
            o.screenCMY = SIMD3(0, max(-1, min(1, magenta / 50)), max(-1, min(1, yellow / 50)))
        }
        if medium.hasStyle {
            switch settings.style { case .auto: o.digitalReference = .autoLevels; case .graded: o.digitalReference = .gradedPrint; case .fixed: o.digitalReference = .referenceExposure }
            if medium.hasGrade { o.screenGrade = Float(settings.grade) }
        }
        return FilmDevelopment(stock: stock, options: o)
    }
    /// The engine's own gauge where it has one, for the base the film is coated on.
    private static func native(_ gauge: FilmGauge) -> FilmPrint.FilmFormat {
        switch gauge {
        case .super8: return .super8
        case .mm16: return .sixteenMM
        case .super35: return .super35
        case .halfFrame, .mm35: return .still35
        case .mf645, .mf66, .mf67, .mf69: return .mediumFormat120
        case .lf45: return .largeFormat4x5
        case .instaxMini: return .instaxMini
        case .instaxWide: return .instaxWide
        }
    }

    /// The media Convert Negative prints a color negative scan on, for the stock the roll was shot on.
    public func printMedia(for stock: String) -> [FilmMedium] {
        film(stock)?.media.filter { $0.kind == .paper || $0.kind == .printFilm } ?? []
    }
}

/// A stock with the engine's options for it.
struct FilmDevelopment: @unchecked Sendable {
    let stock: FilmPrint.FilmStock
    var options: FilmOptions
}
