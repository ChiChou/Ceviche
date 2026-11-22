import Foundation

/// What one passport, visa or ID card asks of its photo: the print size, where the head goes, and the rules a person
/// checks against. Millimetres throughout; ranges are `[minimum, maximum]`. The bundled set is `IDPhotoSpecs.json`,
/// gathered from each issuing authority's own page (its `source`).
public struct IDPhotoSpec: Codable, Hashable, Sendable, Identifiable {
    public enum Background: String, Codable, Sendable { case white, offWhite = "off-white", lightGrey = "light-grey", lightBlue = "light-blue", whiteOrLight = "white-or-light" }
    public enum Glasses: String, Codable, Sendable { case never, discouraged, allowed = "allowed-no-glare" }
    public enum Expression: String, Codable, Sendable { case neutral, slightSmile = "neutral-or-slight-smile" }
    public struct Digital: Codable, Hashable, Sendable {
        public var minPx: [Int]?
        public var maxPx: [Int]?
        public var maxKB: Int?
        public init(minPx: [Int]? = nil, maxPx: [Int]? = nil, maxKB: Int? = nil) { self.minPx = minPx; self.maxPx = maxPx; self.maxKB = maxKB }
    }

    public var id: String
    /// ISO 3166-1 alpha-2, or "ICAO" for the generic one, or "" for one the user made.
    public var country: String
    /// English; a known one is translated by `documentTitle`.
    public var document: String
    public var widthMM: Double
    public var heightMM: Double
    /// Chin to crown, using the issuing authority’s reference; some specifications exclude hair.
    public var headHeightMM: [Double]
    public var crownToTopMM: [Double]?
    public var eyeLineFromBottomMM: [Double]?
    public var background: Background
    public var glasses: Glasses
    public var expression: Expression
    public var mouthClosed: Bool
    public var digital: Digital?
    public var printDPI: Double
    public var notes: String?
    public var source: String?

    public init(id: String, country: String, document: String, widthMM: Double, heightMM: Double, headHeightMM: [Double],
                crownToTopMM: [Double]? = nil, eyeLineFromBottomMM: [Double]? = nil, background: Background = .white,
                glasses: Glasses = .never, expression: Expression = .neutral, mouthClosed: Bool = true,
                digital: Digital? = nil, printDPI: Double = 300, notes: String? = nil, source: String? = nil) {
        self.id = id; self.country = country; self.document = document; self.widthMM = widthMM; self.heightMM = heightMM
        self.headHeightMM = headHeightMM; self.crownToTopMM = crownToTopMM; self.eyeLineFromBottomMM = eyeLineFromBottomMM
        self.background = background; self.glasses = glasses; self.expression = expression; self.mouthClosed = mouthClosed
        self.digital = digital; self.printDPI = printDPI; self.notes = notes; self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, country, document, widthMM, heightMM, headHeightMM, crownToTopMM, eyeLineFromBottomMM, background, glasses
        case expression, mouthClosed, digital, printDPI, notes, source
    }
    /// Lenient, so a value the app doesn't know yet falls back to the strictest reading instead of dropping the spec.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        document = try c.decodeIfPresent(String.self, forKey: .document) ?? ""
        widthMM = try c.decode(Double.self, forKey: .widthMM)
        heightMM = try c.decode(Double.self, forKey: .heightMM)
        headHeightMM = try c.decode([Double].self, forKey: .headHeightMM)
        crownToTopMM = try c.decodeIfPresent([Double].self, forKey: .crownToTopMM)
        eyeLineFromBottomMM = try c.decodeIfPresent([Double].self, forKey: .eyeLineFromBottomMM)
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? .white
        glasses = (try? c.decodeIfPresent(Glasses.self, forKey: .glasses)) ?? .never
        expression = (try? c.decodeIfPresent(Expression.self, forKey: .expression)) ?? .neutral
        mouthClosed = try c.decodeIfPresent(Bool.self, forKey: .mouthClosed) ?? true
        digital = try? c.decodeIfPresent(Digital.self, forKey: .digital)
        printDPI = try c.decodeIfPresent(Double.self, forKey: .printDPI) ?? 300
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    /// Usable for cropping: positive sizes and a head range that fits the frame.
    public var isValid: Bool {
        widthMM > 0 && heightMM > 0 && headHeightMM.count == 2 && headHeightMM[0] > 0 && headHeightMM[0] <= headHeightMM[1]
            && headHeightMM[1] < heightMM && printDPI >= 72 && [crownToTopMM, eyeLineFromBottomMM].allSatisfy { $0 == nil || $0!.count == 2 && $0![0] <= $0![1] }
    }

    public var headRange: ClosedRange<Double> { headHeightMM[0]...headHeightMM[1] }
    public var crownRange: ClosedRange<Double>? { crownToTopMM.map { $0[0]...$0[1] } }
    public var eyeRange: ClosedRange<Double>? { eyeLineFromBottomMM.map { $0[0]...$0[1] } }

    /// The print in pixels at `printDPI`.
    public var pixelSize: (width: Int, height: Int) {
        (Int((widthMM / 25.4 * printDPI).rounded()), Int((heightMM / 25.4 * printDPI).rounded()))
    }

    // MARK: Names

    public var countryName: String {
        switch country {
        case "ICAO": return L10n.tr("International (ICAO)")
        case "": return L10n.tr("Custom")
        case "EU": return L10n.tr("Schengen")
        default: return L10n.locale.localizedString(forRegionCode: country) ?? country
        }
    }
    public var documentTitle: String {
        switch document {
        case "Passport": return L10n.tr("Passport")
        case "Visa": return L10n.tr("Visa")
        case "ID Card": return L10n.tr("ID Card")
        case "Passport / ID Card": return L10n.tr("Passport and ID Card")
        case "Residence Permit": return L10n.tr("Residence Permit")
        case "Green Card": return L10n.tr("Green Card")
        case "Driving Licence": return L10n.tr("Driving Licence")
        default: return document
        }
    }
    public var title: String { country.isEmpty ? document : "\(countryName) \(documentTitle)" }
    /// The country's flag emoji, to find it by sight; nil for a template.
    public var flag: String? {
        switch country {
        case "": return nil
        case "ICAO": return "🌐"
        default:
            let scalars = country.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
            guard country.count == 2, scalars.count == 2 else { return nil }
            return String(String.UnicodeScalarView(scalars))
        }
    }
    /// Whether `query` starts a word of the country's or the document's name, in the app's language or in English,
    /// ignoring case and accents ("kong", "日本", "Japan" in Chinese, "id" for ID cards). Sizes and country codes aren't
    /// searched. A template matches by its name.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        var names = [document]
        if !country.isEmpty {
            names += [countryName, documentTitle]
            if country.count == 2, let english = Locale(identifier: "en").localizedString(forRegionCode: country) {
                names.append(english)
            }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .anchored]
        return names.contains { name in
            if name.range(of: query, options: options) != nil { return true }
            var hit = false
            name.enumerateSubstrings(in: name.startIndex..., options: .byWords) { _, range, _, stop in
                if name.range(of: query, options: options, range: range.lowerBound..<name.endIndex) != nil { hit = true; stop = true }
            }
            return hit
        }
    }
    /// "35 × 45 mm", or inches for a US size.
    public var sizeTitle: String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)) }
        // 2 × 2 in (US, India and others) reads in inches.
        if abs(widthMM - 50.8) < 0.5 && abs(heightMM - 50.8) < 0.5 {
            return "\(number(widthMM / 25.4)) × \(number(heightMM / 25.4)) in"
        }
        return "\(number(widthMM)) × \(number(heightMM)) mm"
    }
}

public enum IDPhotoSpecs {
    /// The bundled specs, by country name and then document.
    public static let all: [IDPhotoSpec] = {
        guard let url = Bundle.module.url(forResource: "IDPhotoSpecs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let specs = try? JSONDecoder().decode([IDPhotoSpec].self, from: data) else { return [] }
        return specs.filter(\.isValid)
    }()
    public static func spec(_ id: String) -> IDPhotoSpec? { all.first { $0.id == id } }
    /// ICAO 9303's 35 × 45 mm, which most countries follow.
    public static var fallback: IDPhotoSpec {
        spec("icao") ?? IDPhotoSpec(id: "icao", country: "ICAO", document: "Passport", widthMM: 35, heightMM: 45, headHeightMM: [32, 36])
    }
}
