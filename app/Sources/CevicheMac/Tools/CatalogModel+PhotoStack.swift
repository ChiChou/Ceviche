import AppKit
import CevicheCore

struct PhotoStackRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
    /// The mode to open in; nil for the last one used.
    var mode: PhotoStackMode?
}

extension CatalogModel {
    /// Two or more RAW photos, or two or more processed photos; the two kinds don't stack together.
    func canStack(_ targets: [CatalogAsset]) -> Bool {
        let photos = targets.filter { $0.inLibrary && !$0.isLatent }
        return store != nil && canStartJob && !toolOpen && photos.count == targets.count && photos.count >= 2
            && (photos.allSatisfy(Self.isRAW) || !photos.contains(where: Self.isRAW))
    }
    func requestStack(_ targets: [CatalogAsset], mode: PhotoStackMode? = nil) {
        guard canStack(targets) else { return }
        photoStack = PhotoStackRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) }, mode: mode)
    }

    /// The stack is the Base photo's frame, so it takes that photo's development and what is placed on the picture. The
    /// retouching is not among it: each photo's own was taken out before they were aligned.
    func startStack(_ stacker: PhotoStacker, analysis: PhotoStackAnalysis, settings: PhotoStackSettings, editsFrom base: CatalogAsset? = nil, access: [URL], format: ProcessedFormat = .original) {
        let count = analysis.frames.count - settings.excluded.count
        let mode = settings.mode.title
        runMergeJob(beside: stacker.urls[analysis.reference], suffix: "Stack", title: L10n.tr("Stacking Photos"), editsFrom: base, placed: EditTransferItem.framedRetouched, access: access, format: format,
                    merge: { url, progress in try stacker.stack(settings, to: url, progress: progress) },
                    done: L10n.tr("\(mode) of \(count) photos stacked"), detail: "",
                    stopped: L10n.tr("Stack stopped"), failed: { L10n.tr("The photos couldn’t be stacked. \($0)") })
    }
}
