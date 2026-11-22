import Foundation
import CevicheCore

/// What can be done about a check that isn't met. Framing, colour and background are fixed here; light and red eye
/// need Develop; what the camera saw (a turned head, glasses, closed eyes, too few pixels) needs a new photo.
enum IDPhotoFix: Equatable {
    case fitToSpec, adjustFraming, autoWhiteBalance, replaceBackground, develop, retake

    var title: String {
        switch self {
        case .fitToSpec: L10n.tr("Fit")
        case .adjustFraming: L10n.tr("Adjust…")
        case .autoWhiteBalance: L10n.tr("Auto")
        case .replaceBackground: L10n.tr("Replace")
        case .develop: L10n.tr("Develop")
        case .retake: L10n.tr("Retake")
        }
    }
    var help: String {
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

/// How a photo stands: ready to print, fixable here, or in need of a new photo.
enum IDPhotoReadiness: Int, Comparable {
    case ready, needsFix, retake
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension IDPhotoCheck {
    /// The fix for this check when it isn't met.
    var fix: IDPhotoFix? {
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

extension IDPhotoModel {
    /// The checks not met: failures first, then warnings, then Apple Intelligence's hints. None can be dismissed; they
    /// inform, and never stop a print or an export.
    var issues: [IDPhotoCheck] {
        checks.filter { $0.status >= .warning }
            .sorted { ($0.advisory ? 1 : 0, -$0.status.rawValue) < ($1.advisory ? 1 : 0, -$1.status.rawValue) }
    }
    var passed: [IDPhotoCheck] { checks.filter { $0.status < .warning } }

    /// A failure that needs a new photo makes it a retake; any other issue left needs a fix; a photo still developing
    /// counts as ready until it's measured.
    var readiness: IDPhotoReadiness {
        let open = issues
        if open.contains(where: { $0.status == .failure && $0.fix == .retake }) { return .retake }
        return open.isEmpty ? .ready : .needsFix
    }
    var readinessTitle: String {
        guard layout != nil else { return "" }
        return switch readiness {
        case .ready: L10n.tr("Ready")
        case .needsFix: issues.count == 1 ? L10n.tr("1 issue") : L10n.tr("\(issues.count) issues")
        case .retake: L10n.tr("Retake")
        }
    }
}
