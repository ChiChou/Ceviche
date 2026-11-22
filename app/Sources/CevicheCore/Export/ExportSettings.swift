import Foundation
import CoreGraphics
import ImageIO

public enum ExportFormat: String, CaseIterable, Sendable, Codable {
    case tiff = "TIFF", png = "PNG", heif = "HEIF", avif = "AVIF", jpeg = "JPEG", webp = "WebP", jxl = "JPEG XL"
    public var fileExtension: String {
        switch self { case .jpeg: return "jpg"; case .heif: return "heic"; case .jxl: return "jxl"; default: return rawValue.lowercased() }
    }
    public var typeIdentifier: String {
        switch self { case .heif: return "public.heic"; case .webp: return "org.webmproject.webp"; case .jxl: return "public.jpeg-xl"; default: return "public.\(rawValue.lowercased())" }
    }
    public var isAvailable: Bool {
        if self == .webp || self == .jxl { return ModernImageEncoder.isBuilt }
        return (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(typeIdentifier)
    }
    public var supportsLosslessChoice: Bool { self == .webp || self == .jxl }
    public var depths: [Int] {
        switch self { case .tiff, .png, .jxl: return [16, 8]; case .heif, .avif: return [10, 8]; case .jpeg, .webp: return [8] }
    }
    /// The HDR encodings ImageIO can write into this container, the default first. JPEG holds HDR only as a gain map.
    public var hdrEncodings: [HDREncoding] {
        switch self {
        case .heif: return [.pq, .hlg, .gainMap, .appleGainMap]
        case .avif: return [.pq, .hlg, .gainMap]
        case .png: return [.pq, .hlg]
        case .tiff: return [.linear, .pq, .hlg]
        case .jpeg: return [.gainMap]
        case .webp, .jxl: return []
        }
    }
    /// Bit depths of the default HDR encoding.
    public var hdrDepths: [Int] { hdrEncodings.first.map { $0.depths(for: self) } ?? [] }
    public var supportsHDR: Bool { !hdrEncodings.isEmpty }
    public var isLossy: Bool { self == .jpeg || self == .heif || self == .avif || supportsLosslessChoice }
    public var supportsAlpha: Bool { self == .png || self == .tiff || self == .webp || self == .jxl }
}

/// How HDR pixels are stored. PQ and HLG are ISO 22028-5 transfer functions in Rec. 2100 primaries; the gain map is
/// ISO 21496-1 (an SDR picture plus a map HDR-aware viewers use to restore the highlights); the Apple gain map adds Apple's
/// own map beside it, as an iPhone HEIC carries; linear is unencoded float.
public enum HDREncoding: String, CaseIterable, Sendable, Codable {
    case pq = "PQ", hlg = "HLG", gainMap = "Gain map", appleGainMap = "Apple gain map", linear = "Linear float"
    public var title: String {
        switch self {
        case .pq: return L10n.tr("PQ - Rec. 2100")
        case .hlg: return L10n.tr("HLG - Rec. 2100")
        case .gainMap: return L10n.tr("Gain map - SDR compatible")
        case .appleGainMap: return L10n.tr("Gain map - iPhone style")
        case .linear: return L10n.tr("Linear float")
        }
    }
    public var summary: String {
        switch self {
        case .pq: return L10n.tr("Absolute brightness (ISO 22028-5). Best for HDR displays and Apple Photos; SDR viewers show a tone-mapped picture.")
        case .hlg: return L10n.tr("Broadcast HDR (ISO 22028-5). Looks acceptable on SDR viewers that ignore it.")
        case .gainMap: return L10n.tr("An SDR picture plus a gain map (ISO 21496-1). Every viewer shows the SDR picture; HDR-aware ones restore the highlights.")
        case .appleGainMap: return L10n.tr("Laid out like an iPhone photo: an SDR picture with the ISO 21496-1 gain map and Apple's own gain map, for apps that read only Apple's.")
        case .linear: return L10n.tr("Unencoded scene-linear float pixels for other editors.")
        }
    }
    public var isGainMap: Bool { self == .gainMap || self == .appleGainMap }
    public func depths(for format: ExportFormat) -> [Int] {
        switch self {
        case .linear: return [32]
        case .gainMap, .appleGainMap: return [8]
        case .pq, .hlg: return format == .png || format == .tiff ? [16] : [10]
        }
    }
    /// The gain map's SDR base keeps the chosen profile when it is sRGB; everything else is written as Display P3.
    public func colorSpace(profile: ColorProfile) -> CGColorSpace {
        switch self {
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .gainMap, .appleGainMap: return CGColorSpace(name: profile.preset == .sRGB ? CGColorSpace.extendedLinearSRGB : CGColorSpace.extendedLinearDisplayP3)!
        case .linear: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        }
    }
    public func profileLabel(profile: ColorProfile) -> String {
        switch self {
        case .pq: return L10n.tr("Rec. 2100 PQ")
        case .hlg: return L10n.tr("Rec. 2100 HLG")
        case .gainMap, .appleGainMap: return (profile.preset == .sRGB ? "sRGB" : L10n.tr("Display P3")) + L10n.tr(" + HDR gain map")
        case .linear: return L10n.tr("Linear Display P3")
        }
    }
}

public enum RGBProfile: String, CaseIterable, Codable, Sendable {
    case automatic = "Automatic", sRGB = "sRGB", displayP3 = "Display P3", adobeRGB = "Adobe RGB (1998)", proPhoto = "ProPhoto RGB", custom = "Imported ICC"
    /// Automatic is sRGB, which every viewer shows the same, except in HEIF: the phones that open it have P3 screens.
    public func resolved(for format: ExportFormat) -> RGBProfile {
        guard self == .automatic else { return self }
        return format == .heif ? .displayP3 : .sRGB
    }
    public var title: String { self == .automatic ? L10n.tr("Automatic") : rawValue }
    /// "Automatic (sRGB)" once the format is known.
    public func title(for format: ExportFormat) -> String {
        self == .automatic ? L10n.tr("Automatic (\(resolved(for: format).rawValue))") : rawValue
    }
    public var space: CGColorSpace {
        let name: CFString
        switch self {
        case .automatic, .sRGB, .custom: name = CGColorSpace.sRGB
        case .displayP3: name = CGColorSpace.displayP3
        case .adobeRGB: name = CGColorSpace.adobeRGB1998
        case .proPhoto: name = CGColorSpace.rommrgb
        }
        return CGColorSpace(name: name)!
    }
}

public struct ColorProfile: Codable, Equatable, Sendable {
    public var preset: RGBProfile = .automatic
    public var iccData: Data?
    public var name: String = ""
    /// The library file `iccData` was read from; storing a development writes one when it is nil.
    public var source: ResourceReference?
    /// Equal when they render the same; which file the profile was read from does not count.
    public static func == (a: Self, b: Self) -> Bool { a.preset == b.preset && a.iccData == b.iccData && a.name == b.name }
    public init() {}
    public func colorSpace() throws -> CGColorSpace {
        guard preset == .custom else { return preset.space }
        guard let iccData, iccData.count <= 4 * 1024 * 1024,
              let space = CGColorSpace(iccData: iccData as CFData), space.model == .rgb else {
            throw EditorError.invalidDocument(L10n.tr("Choose a valid RGB ICC profile (up to 4 MB)."))
        }
        return space
    }
}

/// A photo's location as the catalog knows it, written into an export in place of the original's GPS.
public enum ExportGPS: Equatable, Sendable {
    case unknown
    case at(latitude: Double, longitude: Double)
    public init(latitude: Double?, longitude: Double?) {
        if let latitude, let longitude { self = .at(latitude: latitude, longitude: longitude) } else { self = .unknown }
    }
    /// The GPS tags for this location; nil when unknown.
    public var gps: [String: Any]? {
        guard case .at(let latitude, let longitude) = self else { return nil }
        return [kCGImagePropertyGPSLatitude as String: abs(latitude), kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude as String: abs(longitude), kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E"]
    }
}

public struct ExportSettings: Equatable, Sendable, Codable {
    public var format: ExportFormat = .tiff
    public var hdr = false
    public var hdrEncoding: HDREncoding = .linear
    public var depths: [Int] { hdr ? hdrEncoding.depths(for: format) : format.depths }
    public var profileLabel: String {
        if hdr { return hdrEncoding.profileLabel(profile: resolvedProfile) }
        // An imported profile goes by its own name.
        return profile.preset == .custom && profile.iccData != nil && !profile.name.isEmpty ? profile.name : resolvedProfile.preset.rawValue
    }
    public var floatingPoint: Bool { hdr && hdrEncoding == .linear }
    /// Gain maps are written from float pixels that carry their headroom; the encoder derives the SDR base and the map.
    public var halfFloat: Bool { hdr && hdrEncoding.isGainMap }
    /// The profile written into the file: Automatic becomes sRGB or Display P3 for this format.
    public var resolvedProfile: ColorProfile {
        var resolved = profile; resolved.preset = profile.preset.resolved(for: format); return resolved
    }
    public func colorSpace() throws -> CGColorSpace {
        if hdr { return hdrEncoding.colorSpace(profile: resolvedProfile) }
        return try resolvedProfile.colorSpace()
    }
    public var depth = 16
    public var quality = 0.95
    /// WebP/JPEG XL lossless encoding preserves the rendered pixels at the selected depth, not RAW samples.
    public var lossless = true
    public var usesLossyCompression: Bool { format.isLossy && !(format.supportsLosslessChoice && lossless) }
    public var profile = ColorProfile()
    public var preserveAlpha = true
    public var includeMetadata = true
    /// Retain source GPS tags when capture metadata is included. Enabled for sharing.
    public var includeLocation = false
    /// Where the catalog says the photo was taken, set for each export: it replaces the original's GPS, so a location
    /// placed or removed in Ceviche is the one written. Nil outside a catalog, where the original's GPS is kept.
    public var location: ExportGPS?
    public var sizing = ExportSizing()
    /// NAFNet denoise strength (0–100), run on the finished image at its export size, just before encoding.
    public var aiDenoise = 0.0
    /// Stamped on the finished image, after AI denoise, so the network never smooths it.
    public var watermark: Watermark?
    public init() {}
    enum CodingKeys: String, CodingKey { case format, hdr, hdrEncoding, depth, quality, lossless, profile, preserveAlpha, includeMetadata, includeLocation, sizing, aiDenoise, watermark }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .tiff
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
        hdrEncoding = try c.decodeIfPresent(HDREncoding.self, forKey: .hdrEncoding) ?? format.hdrEncodings.first ?? .pq
        depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 16
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.95
        lossless = try c.decodeIfPresent(Bool.self, forKey: .lossless) ?? true
        profile = try c.decodeIfPresent(ColorProfile.self, forKey: .profile) ?? ColorProfile()
        preserveAlpha = try c.decodeIfPresent(Bool.self, forKey: .preserveAlpha) ?? true
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? true
        includeLocation = try c.decodeIfPresent(Bool.self, forKey: .includeLocation) ?? false
        sizing = try c.decodeIfPresent(ExportSizing.self, forKey: .sizing) ?? ExportSizing()
        aiDenoise = try c.decodeIfPresent(Double.self, forKey: .aiDenoise) ?? 0
        watermark = try? c.decodeIfPresent(Watermark.self, forKey: .watermark)
        if !format.supportsHDR { hdr = false }
        if !format.hdrEncodings.contains(hdrEncoding) { hdrEncoding = format.hdrEncodings.first ?? .pq }
        if !depths.contains(depth) { depth = depths.first ?? 0 }
    }
    public mutating func select(_ format: ExportFormat) {
        self.format = format
        if !format.supportsHDR { hdr = false }
        if !format.hdrEncodings.contains(hdrEncoding) { hdrEncoding = format.hdrEncodings.first ?? .pq }
        depth = depths.first ?? 0
    }
    /// A depth the new range still offers is kept, so remembered settings survive the dialog's opening.
    public mutating func setHDR(_ enabled: Bool) {
        hdr = enabled && format.supportsHDR
        if !format.hdrEncodings.contains(hdrEncoding) { hdrEncoding = format.hdrEncodings.first ?? .pq }
        if !depths.contains(depth) { depth = depths.first ?? 0 }
    }
    public mutating func setHDREncoding(_ encoding: HDREncoding) {
        guard format.hdrEncodings.contains(encoding) else { return }
        hdrEncoding = encoding
        depth = depths.first ?? 0
    }
    public func dimensions(for source: CGSize) throws -> ExportDimensions {
        let result = try sizing.dimensions(for: source)
        try ModernImageEncoder.checkLimits(self, width: result.width, height: result.height)
        return result
    }
    public func validate() throws {
        try sizing.validate()
        guard format.isAvailable, depths.contains(depth), (!hdr || format.hdrEncodings.contains(hdrEncoding)), quality.isFinite, (0...1).contains(quality), (0...100).contains(aiDenoise) else {
            throw EditorError.invalidDocument(L10n.tr("This export format or bit depth is not supported by the installed encoder."))
        }
        if !hdr { _ = try profile.colorSpace() }
        try watermark?.validate()
    }
}
