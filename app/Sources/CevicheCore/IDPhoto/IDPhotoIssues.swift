import Foundation

/// What can be done about a check that isn't met. Framing, colour and background are fixed in the tool; light and red
/// eye need Develop; what the camera saw (a turned head, glasses, closed eyes, too few pixels) needs a new photo.
public enum IDPhotoFix: Equatable, Sendable {
    case fitToSpec, adjustFraming, autoWhiteBalance, replaceBackground, develop, retake

    public var title: String {
        switch self {
        case .fitToSpec: L10n.tr("Fit")
        case .adjustFraming: L10n.tr("Adjust…")
        case .autoWhiteBalance: L10n.tr("Auto")
        case .replaceBackground: L10n.tr("Replace")
        case .develop: L10n.tr("Develop")
        case .retake: L10n.tr("Retake")
        }
    }
    public var help: String {
        switch self {
        case .fitToSpec: L10n.tr("Head size and position back to the middle of what the document allows")
        case .adjustFraming: L10n.tr("Move the crown, chin and eye markers on the photo")
        case .autoWhiteBalance: L10n.tr("Balance from the skin and the wall behind the head")
        case .replaceBackground: L10n.tr("Put every photo on the document's background colour")
        case .develop: L10n.tr("Fix this in Develop")
        case .retake: L10n.tr("This can't be fixed in the photo: leave it out, or take it again")
        }
    }
}

/// How a photo stands: ready to print, fixable in the tool, or in need of a new photo.
public enum IDPhotoReadiness: Int, Comparable, Sendable {
    case ready, needsFix, retake
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension IDPhotoCheck {
    /// The fix for this check when it isn't met.
    public var fix: IDPhotoFix? {
        guard status >= .warning else { return nil }
        switch id {
        case "head", "crown", "eyes": return .fitToSpec
        case "edges": return .adjustFraming
        case "cast": return .autoWhiteBalance
        case "background": return .replaceBackground
        case "shadows", "exposure", "ai-redeye": return .develop
        case "tilt": return nil
        case "resolution", "face", "yaw", "pitch", "eyesOpen", "mouth", "glasses", "headwear", "headphones", "quality",
             "ai-hair", "ai-makeup", "ai-smile", "ai-glasses", "ai-headwear", "ai-glare":
            return .retake
        default: return nil
        }
    }
}

extension Array where Element == IDPhotoCheck {
    /// The checks not met: failures first, then warnings, then Apple Intelligence's hints. None can be dismissed; they
    /// inform, and never stop a print or an export.
    public var issues: [IDPhotoCheck] {
        filter { $0.status >= .warning }
            .sorted { ($0.advisory ? 1 : 0, -$0.status.rawValue) < ($1.advisory ? 1 : 0, -$1.status.rawValue) }
    }
    public var passed: [IDPhotoCheck] { filter { $0.status < .warning } }

    /// A failure that needs a new photo makes it a retake; any other issue left needs a fix.
    public var readiness: IDPhotoReadiness {
        let open = issues
        if open.contains(where: { $0.status == .failure && $0.fix == .retake }) { return .retake }
        return open.isEmpty ? .ready : .needsFix
    }
}
