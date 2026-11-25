import Foundation
import CevicheCore

extension IDPhotoModel {
    /// The checks not met (see `[IDPhotoCheck].issues`).
    var issues: [IDPhotoCheck] { checks.issues }
    var passed: [IDPhotoCheck] { checks.passed }

    /// A photo still developing counts as ready until it's measured.
    var readiness: IDPhotoReadiness { checks.readiness }
    var readinessTitle: String {
        guard layout != nil else { return "" }
        return switch readiness {
        case .ready: L10n.tr("Ready")
        case .needsFix: issues.count == 1 ? L10n.tr("1 issue") : L10n.tr("\(issues.count) issues")
        case .retake: L10n.tr("Retake")
        }
    }
}
