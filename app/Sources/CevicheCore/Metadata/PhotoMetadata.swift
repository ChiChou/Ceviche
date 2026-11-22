import Foundation
import ImageIO

/// Display-ready capture metadata read from an image's ImageIO properties.
public struct PhotoMetadataSummary: Equatable, Sendable {
    public struct Field: Equatable, Sendable, Identifiable {
        public var id: String { group + "." + key }
        public let group: String
        public let key: String
        public let title: String
        public let value: String
    }
    public var make: String?
    public var model: String?
    public var lens: String?
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var focalLength: String?
    /// The 35 mm equivalent, shown only when it differs from the actual focal length.
    public var focalLength35mm: String?
    public var exposureBias: String?
    public var exposureProgram: String?
    public var metering: String?
    public var flash: String?
    public var whiteBalance: String?
    public var captured: String?
    public var software: String?
    public var artist: String?
    public var copyright: String?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    /// Every remaining scalar property, grouped by ImageIO dictionary and sorted for scanning.
    public var extended: [Field] = []

    public init() {}

    public init(properties: [String: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func number(_ value: Any?) -> Double? {
            if let array = value as? [Any] { return number(array.first) }
            return (value as? NSNumber)?.doubleValue
        }
        make = text(tiff[kCGImagePropertyTIFFMake as String])
        model = text(tiff[kCGImagePropertyTIFFModel as String])
        lens = text(exif[kCGImagePropertyExifLensModel as String]) ?? text(aux[kCGImagePropertyExifAuxLensModel as String])
        if let f = number(exif[kCGImagePropertyExifFNumber as String]), f > 0 { aperture = "ƒ/" + Self.trimmed(f, digits: 1) }
        if let t = number(exif[kCGImagePropertyExifExposureTime as String]), t > 0 { shutter = Self.shutter(t) }
        if let value = number(exif[kCGImagePropertyExifISOSpeedRatings as String]), value > 0 { iso = "ISO \(Int(value))" }
        let focal = number(exif[kCGImagePropertyExifFocalLength as String])
        if let focal, focal > 0 { focalLength = Self.trimmed(focal, digits: 1) + " mm" }
        if let equivalent = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]), equivalent > 0, abs(equivalent - (focal ?? 0)) >= 1 {
            focalLength35mm = "\(Int(equivalent)) mm"
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue as String]) {
            exposureBias = bias == 0 ? "0 EV" : String(format: "%+.1f EV", bias).replacingOccurrences(of: ".0 ", with: " ")
        }
        if let program = number(exif[kCGImagePropertyExifExposureProgram as String]).map(Int.init) {
            exposureProgram = [L10n.tr("Not defined"), L10n.tr("Manual"), L10n.tr("Program Auto"), L10n.tr("Aperture priority"), L10n.tr("Shutter priority"), L10n.tr("Creative"), L10n.tr("Action"), L10n.tr("Portrait", context: "exposure program"), L10n.tr("Landscape", context: "exposure program")][safe: program]
        }
        if let mode = number(exif[kCGImagePropertyExifMeteringMode as String]).map(Int.init) {
            metering = [0: L10n.tr("Unknown"), 1: L10n.tr("Average"), 2: L10n.tr("Center-weighted"), 3: L10n.tr("Spot"), 4: L10n.tr("Multi-spot"), 5: L10n.tr("Pattern"), 6: L10n.tr("Partial")][mode]
        }
        if let value = number(exif[kCGImagePropertyExifFlash as String]).map(Int.init) { flash = value & 1 == 1 ? L10n.tr("Fired") : L10n.tr("Did not fire") }
        if let value = number(exif[kCGImagePropertyExifWhiteBalance as String]).map(Int.init) { whiteBalance = value == 0 ? L10n.tr("Auto") : L10n.tr("Manual") }
        captured = text(exif[kCGImagePropertyExifDateTimeOriginal as String]).map(Self.date) ?? text(tiff[kCGImagePropertyTIFFDateTime as String]).map(Self.date)
        software = text(tiff[kCGImagePropertyTIFFSoftware as String])
        artist = text(tiff[kCGImagePropertyTIFFArtist as String])
        copyright = text(tiff[kCGImagePropertyTIFFCopyright as String])
        if let lat = number(gps[kCGImagePropertyGPSLatitude as String]), let lon = number(gps[kCGImagePropertyGPSLongitude as String]) {
            latitude = text(gps[kCGImagePropertyGPSLatitudeRef as String]) == "S" ? -lat : lat
            longitude = text(gps[kCGImagePropertyGPSLongitudeRef as String]) == "W" ? -lon : lon
            if let alt = number(gps[kCGImagePropertyGPSAltitude as String]) { altitude = number(gps[kCGImagePropertyGPSAltitudeRef as String]) == 1 ? -alt : alt }
        }
        let groups: [(String, String)] = [(kCGImagePropertyTIFFDictionary as String, "TIFF"), (kCGImagePropertyExifDictionary as String, "Exif"),
                                          (kCGImagePropertyExifAuxDictionary as String, "Exif Aux"), (kCGImagePropertyGPSDictionary as String, "GPS"),
                                          (kCGImagePropertyIPTCDictionary as String, "IPTC")]
        var fields: [Field] = []
        for (dictionary, group) in groups {
            for (key, value) in properties[dictionary] as? [String: Any] ?? [:] {
                guard let rendered = Self.render(value) else { continue }
                fields.append(Field(group: group, key: key, title: Self.title(key), value: rendered))
            }
        }
        for (key, value) in properties where !(value is [String: Any]) {
            guard let rendered = Self.render(value) else { continue }
            fields.append(Field(group: L10n.tr("File"), key: key, title: Self.title(key), value: rendered))
        }
        extended = fields.sorted { ($0.group, $0.title) < ($1.group, $1.title) }
    }

    /// Reads properties without decoding pixels.
    public init(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { self.init(); return }
        self.init(properties: properties)
    }

    public var camera: String? {
        guard let model else { return make }
        // Many makers repeat their name in the model string.
        guard let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") else { return model }
        return make.capitalized + " " + model
    }

    public static func shutter(_ seconds: Double) -> String {
        if seconds >= 1 { return trimmed(seconds, digits: 1) + " s" }
        let denominator = 1 / seconds
        return abs(denominator - denominator.rounded()) < 0.05 || denominator >= 10 ? L10n.tr("1/\(Int(denominator.rounded())) s") : trimmed(seconds, digits: 2) + " s"
    }
    static func trimmed(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        return text.contains(".") ? String(text.reversed().drop(while: { $0 == "0" }).drop(while: { $0 == "." }).reversed()) : text
    }
    /// EXIF stores "yyyy:MM:dd HH:mm:ss"; show it with the user's locale.
    static func date(_ value: String) -> String {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: value) else { return value }
        return date.localized(date: .abbreviated, time: .standard)
    }
    /// "FocalLenIn35mmFilm" → "Focal Len In 35mm Film".
    static func title(_ key: String) -> String {
        var words = "", previous: Character?
        for character in key {
            if let previous, character.isUppercase && previous.isLowercase || character.isNumber && previous.isLetter { words.append(" ") }
            words.append(character); previous = character
        }
        return words
    }
    static func render(_ value: Any) -> String? {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case let number as NSNumber: return trimmed(number.doubleValue, digits: 4)
        case let array as [Any]:
            let parts = array.compactMap(render)
            return parts.isEmpty || parts.count > 16 ? nil : parts.joined(separator: ", ")
        default: return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
