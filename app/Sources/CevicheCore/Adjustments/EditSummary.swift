import Foundation

/// Human-readable names for what changed between two saved developments, for History.
public enum EditSummary {
    /// The top-level development fields that differ, used to fold repeated tweaks of the same controls.
    public static func changedKeys(from old: Data?, to new: Data) -> Set<String> {
        guard let after = object(new) else { return [] }
        let before = old.flatMap(object) ?? [:]
        return Set(before.keys).union(after.keys).filter { !equal(normalized($0, before[$0]), normalized($0, after[$0])) }
    }
    public static func describe(from old: Data?, to new: Data, limit: Int = 3) -> String {
        guard let after = object(new) else { return L10n.tr("Saved development") }
        let before = old.flatMap(object) ?? [:]
        let changed = Set(before.keys).union(after.keys)
            .filter { !equal(normalized($0, before[$0]), normalized($0, after[$0])) }
            .map(title).sorted()
        guard !changed.isEmpty else { return L10n.tr("Saved development") }
        let shown = changed.prefix(limit).joined(separator: ", ")
        return changed.count > limit ? L10n.tr("\(shown) +\(changed.count - limit) more") : shown
    }
    /// "Rated 3 stars", "Accepted", or the names of edited fields such as "Title, Keywords".
    public static func describe(metadata new: CatalogMetadata, from old: CatalogMetadata) -> String {
        var parts: [String] = []
        if new.rating != old.rating { parts.append(new.rating == 0 ? L10n.tr("Cleared rating") : (new.rating == 1 ? L10n.tr("Rated \(new.rating) star") : L10n.tr("Rated \(new.rating) stars"))) }
        if new.review != old.review {
            parts.append(new.review == .accepted ? L10n.tr("Picked") : new.review == .rejected ? L10n.tr("Rejected") : L10n.tr("Unflagged"))
        }
        let fields = [(L10n.tr("Title"), new.title != old.title), (L10n.tr("Caption"), new.caption != old.caption), (L10n.tr("Keywords"), new.keywords != old.keywords),
                      (L10n.tr("Capture date"), new.captureDay != old.captureDay), (L10n.tr("Location"), new.latitude != old.latitude || new.longitude != old.longitude)]
        let edited = fields.filter(\.1).map(\.0)
        if !edited.isEmpty { parts.append(L10n.tr("Edited \(edited.joined(separator: ", "))")) }
        guard let first = parts.first else { return L10n.tr("Updated metadata") }
        return ([first] + parts.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }).joined(separator: ", ")
    }
    /// "selectiveColors" → "Selective colors"
    static func title(_ key: String) -> String {
        let names: [String: String] = [
            "hdr": L10n.tr("HDR"),
            "look": L10n.tr("Look"),
            "cameraProfile": L10n.tr("Camera profile"),
            "lut": L10n.tr("LUT"),
            "film": L10n.tr("Film"),
            "aces": L10n.tr("ACES"),
            "lensCorrection": L10n.tr("Lens correction"),
            "luminanceNoiseDetail": L10n.tr("Luminance noise detail"),
            "luminanceNoiseContrast": L10n.tr("Luminance noise contrast"),
            "curveSaturation": L10n.tr("Curve saturation"),
            "colorNoiseDetail": L10n.tr("Color noise detail"),
            "colorNoiseSmoothness": L10n.tr("Color noise smoothness"),
            "defringe": L10n.tr("Defringe"),
            "postCropVignette": L10n.tr("Post crop vignette"),
            "pointColors": L10n.tr("Point colors"),
            "warmth": L10n.tr("Warmth"),
            "blur": L10n.tr("Blur"),
            "retouch": L10n.tr("Retouch"),
            "faceLiquifies": L10n.tr("Face Liquify"),
            "skinTone": L10n.tr("Even tone"),
            "redEyeCorrection": L10n.tr("Red eye correction"),
            "geometry": L10n.tr("Crop & geometry"),
            "redCurve": L10n.tr("Red curve"),
            "greenCurve": L10n.tr("Green curve"),
            "blueCurve": L10n.tr("Blue curve"),
            "parametricCurve": L10n.tr("Parametric curve"),
            "splitToning": L10n.tr("Color grading"),
            "calibration": L10n.tr("Calibration"),
            "blackWhiteMixer": L10n.tr("Black white mixer"),
            "grain": L10n.tr("Grain"),
            "sharpenRadius": L10n.tr("Sharpen radius"),
            "sharpenDetail": L10n.tr("Sharpen detail"),
            "sharpenMasking": L10n.tr("Sharpen masking"),
            "colorNoiseReduction": L10n.tr("Color noise reduction"),
            "masks": L10n.tr("Masks"),
            "colorProfile": L10n.tr("Color profile"),
            "neutralRAW": L10n.tr("Neutral RAW"),
            "exposure": L10n.tr("Exposure"),
            "contrast": L10n.tr("Contrast"),
            "highlights": L10n.tr("Highlights"),
            "shadows": L10n.tr("Shadows"),
            "whites": L10n.tr("Whites"),
            "blacks": L10n.tr("Blacks"),
            "temperature": L10n.tr("Temperature"),
            "tint": L10n.tr("Tint"),
            "vibrance": L10n.tr("Vibrance"),
            "saturation": L10n.tr("Saturation"),
            "clarity": L10n.tr("Clarity"),
            "texture": L10n.tr("Texture"),
            "dehaze": L10n.tr("Dehaze"),
            "sharpness": L10n.tr("Sharpness"),
            "noiseReduction": L10n.tr("Noise reduction"),
            "vignette": L10n.tr("Vignette"),
            "vignetteRadius": L10n.tr("Vignette radius"),
            "vignetteSoftness": L10n.tr("Vignette softness"),
            "monochrome": L10n.tr("Monochrome"),
            "quarterTurns": L10n.tr("Rotation"),
            "curve": L10n.tr("Curve"),
            "selectiveColors": L10n.tr("Selective colors"),
            "disabledSections": L10n.tr("Section toggles"),
        ]
        // Unknown fields from a newer schema stay readable without altering their identifiers.
        return names[key] ?? key
    }
    /// Sets are encoded as arrays in arbitrary order; compare them sorted.
    private static func normalized(_ key: String, _ value: Any?) -> Any? {
        guard key == "disabledSections", let array = value as? [String] else { return value }
        return array.sorted()
    }
    /// A stored development as JSON, the keys a stored one leaves out at their defaults, so a compact payload and a
    /// full one written by an earlier build compare key by key.
    private static func object(_ data: Data) -> [String: Any]? {
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return defaultObject.merging(stored) { _, stored in stored }
    }
    private static let defaultObject = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Adjustments()))) as? [String: Any]) ?? [:]
    private static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }
}
