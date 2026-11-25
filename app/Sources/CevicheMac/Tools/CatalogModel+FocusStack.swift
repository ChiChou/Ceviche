import AppKit
import CevicheCore

struct FocusStackRequest: Identifiable {
    let id = UUID()
    /// In capture order, which is usually focus order.
    let assets: [CatalogAsset]
    /// The latent image opened, with its photos as `assets`.
    var latent: (assetID: String, saved: FocusStackSettings)? = nil
}

extension CatalogModel {
    /// A focus bracket is two or more RAW photos, or two or more processed photos; the two kinds don't stack together.
    func canFocusStack(_ targets: [CatalogAsset]) -> Bool {
        let photos = targets.filter { $0.inLibrary && !$0.isLatent }
        return store != nil && canStartJob && !toolOpen && photos.count == targets.count && photos.count >= 2
            && (photos.allSatisfy(Self.isRAW) || !photos.contains(where: Self.isRAW))
    }
    /// Opens the focus stack view for the selected bracket.
    func requestFocusStack(_ targets: [CatalogAsset]) {
        guard canFocusStack(targets) else { return }
        focusStack = FocusStackRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// The stack takes the development of the base photo, `editsFrom`.
    func startFocusStack(_ stacker: FocusStacker, analysis: FocusStackAnalysis, settings: FocusStackSettings, editsFrom base: CatalogAsset? = nil, access: [URL], format: ProcessedFormat = .original) {
        let reference = settings.reference ?? analysis.suggestedReference
        let count = analysis.frames.count - settings.excluded.count
        runMergeJob(beside: stacker.urls[reference], suffix: MergeOutput.focusStack.suffix, title: L10n.tr("Focus stacking"), editsFrom: base, access: access, format: format,
                    merge: { url, progress in try stacker.merge(settings, to: url, progress: progress) },
                    done: L10n.tr("Focus stacked from \(count) photos"), detail: "",
                    stopped: L10n.tr("Focus stack stopped"), failed: { L10n.tr("The photos couldn’t be focus stacked. \($0)") })
    }
}
