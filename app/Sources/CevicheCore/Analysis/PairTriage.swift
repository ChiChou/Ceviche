import Foundation

/// What becomes of a RAW + JPEG (or RAW + HEIF) shot when Tidy RAW + JPEG Pairs is applied.
public enum PairDecision: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Nothing changes.
    case undecided
    /// The camera's JPEG is finished: it leaves the library for the Archived view, and the RAW is rejected.
    case archiveJPEG
    /// The camera's JPEG is good enough to develop: it is picked and stays in the library, and the RAW is rejected.
    case keepJPEG
    /// The shot needs developing: the RAW is picked and the JPEG rejected.
    case keepRAW
    /// Not worth keeping at all: both files are rejected.
    case rejectBoth
    public var id: String { rawValue }
}

/// Why `PairTriage` suggests a decision; shown on the pair as a short tag.
public enum PairReason: String, Codable, Sendable, Identifiable {
    case edited, flagged, blank, blurry, outOfFocus, night, stars, highlights, shadows, exposureCompensation, whiteBalance
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .edited: return L10n.tr("Edited", context: "a photo the person has edited, as a short tag")
        case .flagged: return L10n.tr("Flagged")
        case .blank: return L10n.tr("Blank")
        case .blurry: return L10n.tr("Blurry")
        case .outOfFocus: return L10n.tr("Out of Focus")
        case .night: return L10n.tr("Night")
        case .stars: return L10n.tr("Stars", context: "night sky")
        case .highlights: return L10n.tr("Highlights")
        case .shadows: return L10n.tr("Shadows")
        case .exposureCompensation: return L10n.tr("±EV")
        case .whiteBalance: return L10n.tr("WB", context: "White balance, as a short tag on a photo")
        }
    }
}

/// Suggests what to do with a RAW + JPEG shot from the camera JPEG's quality report and both files' EXIF, flags and
/// edits. The JPEG is what the camera made of the RAW, so it is what gets judged: if it is clean, it is enough; if
/// developing the RAW would rescue it (a night or star scene, clipped or crushed tones, a strong cast), the RAW stays;
/// if it is blurred or blank, so is the RAW; a soft subject is left for the person to look at. The first rule that applies decides.
public enum PairTriage {
    public struct Suggestion: Equatable, Sendable {
        public var decision: PairDecision
        public var reason: PairReason?
        public init(_ decision: PairDecision, _ reason: PairReason? = nil) { self.decision = decision; self.reason = reason }
    }

    /// A cast stronger than this (`PhotoQualityReport.colorCast`) is left for the RAW to fix. Camera JPEGs of daylight
    /// and shade measured 0.003–0.033; the same photo warmed to 4500 K 0.09, tinted 40 green 0.055.
    static func castLimit(_ sensitivity: CullingSensitivity) -> Double {
        switch sensitivity { case .relaxed: 0.07; case .balanced: 0.05; case .strict: 0.04 }
    }

    public static func suggest(raw: CatalogAsset, processed: CatalogAsset, report: PhotoQualityReport?, sensitivity: CullingSensitivity = .balanced) -> Suggestion {
        // The person's own work and decisions come first.
        if raw.lastEditedAt != nil { return Suggestion(.keepRAW, .edited) }
        // An edited JPEG stays where it can be developed further.
        if processed.lastEditedAt != nil { return Suggestion(.keepJPEG, .edited) }
        let rawFlag = raw.review, jpegFlag = processed.review
        switch (rawFlag, jpegFlag) {
        case (.rejected, .rejected): return Suggestion(.rejectBoth, .flagged)
        case (.accepted, .rejected), (.accepted, .unreviewed): return Suggestion(.keepRAW, .flagged)
        case (.rejected, .accepted): return Suggestion(.keepJPEG, .flagged)
        case (.rejected, .unreviewed): return Suggestion(.archiveJPEG, .flagged)
        default: break
        }
        guard let report else { return Suggestion(.undecided) }

        let exposure = processed.exposureTime ?? raw.exposureTime ?? 0
        let iso = processed.iso ?? raw.iso ?? 0
        let aperture = processed.fNumber ?? raw.fNumber ?? 8
        let bias = processed.exposureBias ?? raw.exposureBias ?? 0
        let dark = report.brightness < 0.2 && report.brightPercentile < 0.45

        // A lens cap, a shot into the ground, a frame blown to white: nothing for the RAW to recover either.
        let peak = report.peakSharpness ?? report.sharpness
        if peak == nil && (report.brightPercentile < 0.04 || report.highlights > 0.9) { return Suggestion(.rejectBoth, .blank) }

        // Long exposures are dark and soft on purpose (trails, water, stars), so they are judged before blur.
        if dark && exposure >= 5 && (aperture <= 4 || iso >= 1600) { return Suggestion(.keepRAW, .stars) }
        if dark && (exposure >= 0.25 || iso >= 3200) { return Suggestion(.keepRAW, .night) }

        let issues = report.issues(sensitivity, exposure: ExposureSettings(exposureTime: processed.exposureTime ?? raw.exposureTime, iso: processed.iso ?? raw.iso,
                                                                           fNumber: processed.fNumber ?? raw.fNumber, exposureBias: processed.exposureBias ?? raw.exposureBias))
        if issues.contains(.blurry) { return Suggestion(.rejectBoth, .blurry) }
        // Focus is judged on a subject Vision chose, which can be the wrong one: worth a look, not a rejection.
        if issues.contains(.outOfFocus) { return Suggestion(.undecided, .outOfFocus) }

        if report.highlights > sensitivity.clipped / 3 || issues.contains(.overexposed) { return Suggestion(.keepRAW, .highlights) }
        if report.shadows > 0.12 || issues.contains(.underexposed) || dark { return Suggestion(.keepRAW, .shadows) }
        if abs(bias) >= 1 { return Suggestion(.keepRAW, .exposureCompensation) }
        if let cast = report.colorCast, cast > castLimit(sensitivity) { return Suggestion(.keepRAW, .whiteBalance) }
        return Suggestion(.archiveJPEG)
    }
}
