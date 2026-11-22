import Foundation
import CoreGraphics

/// One-click export settings: common sizes and formats, and recommended social image sizes.
/// Social presets use sRGB and leave capture metadata (including location) out of the file.
public struct ExportPreset: Identifiable, Hashable, Sendable {
    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let id: String
    public let name: String
    /// The service a social preset belongs to; presets of one platform share a submenu.
    public let platform: String?
    public let format: ExportFormat
    public let depth: Int
    public let quality: Double
    /// Photos larger than this are shrunk to it; nil keeps the original size.
    public let longEdge: Int?
    /// Social export targets: center-crop to its ratio, then scale to exactly these pixels.
    public let frame: ExportDimensions?
    /// nil exports in the photo's own development profile.
    public let profile: RGBProfile?
    public let includeMetadata: Bool
    public let includeLocation: Bool
    /// A saved watermark, looked up when the preset is used so later changes to it apply.
    public let watermark: UUID?
    /// A preset saved from the export dialog keeps every setting the dialog had.
    private var saved: ExportSettings?
    public init(id: String, name: String, platform: String? = nil, format: ExportFormat, depth: Int = 8, quality: Double = 0.92, longEdge: Int? = nil, frame: ExportDimensions? = nil, profile: RGBProfile? = nil, includeMetadata: Bool = true, includeLocation: Bool = false, watermark: UUID? = nil) {
        self.id = id; self.name = name; self.platform = platform; self.format = format; self.depth = depth; self.quality = quality; self.longEdge = longEdge; self.frame = frame; self.profile = profile; self.includeMetadata = includeMetadata; self.includeLocation = includeLocation; self.watermark = watermark
    }
    init(id: String, name: String, saved settings: ExportSettings, developedProfile: Bool) {
        self.init(id: id, name: name, format: settings.format, depth: settings.depth, quality: settings.quality, longEdge: settings.sizing.longEdge,
                  frame: settings.sizing.frame, profile: developedProfile ? nil : settings.profile.preset,
                  includeMetadata: settings.includeMetadata, includeLocation: settings.includeLocation, watermark: settings.watermark?.id)
        saved = settings
    }
    /// Format, quality, depth, dimensions and profile, for menu tooltips.
    public var detail: String {
        var parts = [format == .heif ? "HEIC" : format.rawValue]
        if saved?.usesLossyCompression ?? format.isLossy { parts.append(L10n.tr("\(Int((quality * 100).rounded()))%")) }
        parts.append(L10n.tr("\(depth)-bit"))
        parts.append(frame?.label ?? longEdge.map { "\($0) px" } ?? saved.flatMap { Self.sizeLabel($0.sizing) } ?? L10n.tr("Full size"))
        if let profile { parts.append(profile.title(for: format)) }
        return parts.joined(separator: " - ")
    }
    /// Settings for this preset. The photo's own profile is kept when the preset names none; a watermark deleted since is left out.
    public func settings(developmentProfile: ColorProfile = ColorProfile(), watermarks: WatermarkLibrary = .standard) -> ExportSettings {
        if var settings = saved {
            if profile == nil { settings.profile = developmentProfile }
            settings.watermark = watermark.flatMap { watermarks.watermark(id: $0) }
            return settings
        }
        var settings = ExportSettings()
        settings.select(format); settings.quality = quality
        if settings.depths.contains(depth) { settings.depth = depth }
        settings.includeMetadata = includeMetadata; settings.includeLocation = includeLocation; settings.preserveAlpha = false
        settings.sizing.longEdge = longEdge; settings.sizing.frame = frame
        if let profile { settings.profile = ColorProfile(); settings.profile.preset = profile } else { settings.profile = developmentProfile }
        settings.watermark = watermark.flatMap { watermarks.watermark(id: $0) }
        return settings
    }
    public static let standard: [ExportPreset] = [
        ExportPreset(id: "jpeg-full", name: L10n.tr("JPEG - Full Size - 92%"), format: .jpeg, quality: 0.92, profile: .sRGB),
        ExportPreset(id: "jpeg-2560", name: L10n.tr("JPEG - 2560 px - 85%"), format: .jpeg, quality: 0.85, longEdge: 2560, profile: .sRGB, includeMetadata: false),
        ExportPreset(id: "heic-full", name: L10n.tr("HEIC - Full Size - 90%"), format: .heif, quality: 0.9),
        ExportPreset(id: "tiff-16", name: L10n.tr("TIFF - Full Size - 16-bit"), format: .tiff, depth: 16, quality: 1)
    ]
    /// Convenient social export targets, not mandatory platform dimensions.
    /// Photos are center-cropped to the chosen ratio and scaled to the target pixels.
    /// Instagram includes 3:4; YouTube uses its recommended 3840 × 2160 thumbnail size.
    public static let social: [ExportPreset] = [
        social("instagram-portrait", L10n.tr("Instagram"), L10n.tr("Post (3:4)"), 1080, 1440),
        social("instagram-post", L10n.tr("Instagram"), L10n.tr("Post (4:5)"), 1080, 1350),
        social("instagram-square", L10n.tr("Instagram"), L10n.tr("Square (1:1)"), 1080, 1080),
        social("instagram-landscape", L10n.tr("Instagram"), L10n.tr("Landscape (1.91:1)"), 1080, 566),
        social("instagram-story", L10n.tr("Instagram"), L10n.tr("Story or Reel (9:16)"), 1080, 1920),
        social("facebook-post", L10n.tr("Facebook"), L10n.tr("Post (4:5)"), 1080, 1350),
        social("facebook-square", L10n.tr("Facebook"), L10n.tr("Square (1:1)"), 1080, 1080),
        social("facebook-landscape", L10n.tr("Facebook"), L10n.tr("Landscape (1.91:1)"), 1080, 566),
        social("facebook-story", L10n.tr("Facebook"), L10n.tr("Story (9:16)"), 1080, 1920),
        social("threads-post", L10n.tr("Threads"), L10n.tr("Post (3:4)"), 1440, 1920),
        social("x-landscape", "X", L10n.tr("Landscape (16:9)"), 1280, 720),
        social("x-square", "X", L10n.tr("Square (1:1)"), 1080, 1080),
        social("x-vertical", "X", L10n.tr("Vertical (9:16)"), 720, 1280),
        social("tiktok-photo", L10n.tr("TikTok"), L10n.tr("Photo (9:16)"), 1080, 1920),
        social("pinterest-pin", L10n.tr("Pinterest"), L10n.tr("Pin (2:3)"), 1000, 1500),
        social("youtube-thumbnail", L10n.tr("YouTube"), L10n.tr("Thumbnail (16:9)"), 3840, 2160),
        social("linkedin-square", L10n.tr("LinkedIn"), L10n.tr("Square (1:1)"), 1080, 1080),
        social("linkedin-portrait", L10n.tr("LinkedIn"), L10n.tr("Portrait (4:5)"), 1080, 1350)
    ]
    private static func social(_ id: String, _ platform: String, _ size: String, _ width: Int, _ height: Int) -> ExportPreset {
        ExportPreset(id: id, name: "\(platform) \(size)", platform: platform, format: .jpeg, quality: 0.9, frame: ExportDimensions(width: width, height: height), profile: .sRGB, includeMetadata: false)
    }
    /// The size part of a social preset's name, for its platform's submenu.
    public var shortName: String {
        guard let platform, name.hasPrefix(platform + " ") else { return name }
        return String(name.dropFirst(platform.count + 1))
    }
    /// Social presets in menu order, grouped by platform.
    public static var socialByPlatform: [(platform: String, presets: [ExportPreset])] {
        var order: [String] = [], groups: [String: [ExportPreset]] = [:]
        for preset in social { let key = preset.platform ?? preset.name; if groups[key] == nil { order.append(key) }; groups[key, default: []].append(preset) }
        return order.map { ($0, groups[$0]!) }
    }
    public static func named(_ id: String) -> ExportPreset? { (standard + social + savedByUser()).first { $0.id == id } }

    // MARK: - User-saved presets

    private static let userPresetsKey = "userExportPresets"

    public static func savedByUser(_ defaults: UserDefaults = .standard) -> [ExportPreset] {
        SavedList<StoredPreset>(defaults.data(forKey: userPresetsKey)).items.map { $0.preset }
    }

    /// A saved preset's size for its tooltip: a preset's long edge or typed pixels; nil for the original size.
    private static func sizeLabel(_ sizing: ExportSizing) -> String? {
        if let edge = sizing.preset.longEdge { return "\(edge) px" }
        return sizing.preset == .custom ? "\(sizing.width) × \(sizing.height) px" : nil
    }

    /// Saves the dialog's settings as they are, in SDR. `developedProfile`: each photo keeps its own color profile.
    public static func saveUserPreset(name: String, settings: ExportSettings, developedProfile: Bool = false, defaults: UserDefaults = .standard) {
        let id = "user-\(UUID().uuidString.prefix(8).lowercased())"
        // Presets this build can't read are kept as they are.
        var stored = SavedList<StoredPreset>(defaults.data(forKey: userPresetsKey))
        // Presets export in SDR, so the depth stored is the one the format offers in SDR.
        var settings = settings; settings.setHDR(false)
        stored.items.append(StoredPreset(id: id, name: name, settings: settings, developedProfile: developedProfile))
        try? stored.write(to: defaults, key: userPresetsKey)
    }

    public static func deleteUserPreset(_ id: String, defaults: UserDefaults = .standard) {
        var stored = SavedList<StoredPreset>(defaults.data(forKey: userPresetsKey))
        stored.items.removeAll { $0.id == id }
        try? stored.write(to: defaults, key: userPresetsKey)
    }

    private struct StoredPreset: Codable {
        var id: String
        var name: String
        var settings: ExportSettings
        var developedProfile: Bool
        var preset: ExportPreset { ExportPreset(id: id, name: name, saved: settings, developedProfile: developedProfile) }
    }
}
