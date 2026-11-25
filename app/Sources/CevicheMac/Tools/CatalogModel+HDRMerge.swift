import AppKit
import CevicheCore

struct HDRMergeRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
}

extension CatalogModel {
    /// Brackets are two or more RAW photos, or two or more processed photos; the two kinds don't merge together.
    func canMergeHDR(_ targets: [CatalogAsset]) -> Bool {
        let photos = targets.filter { $0.inLibrary && !$0.isLatent }
        return store != nil && canStartJob && !toolOpen && photos.count == targets.count && photos.count >= 2
            && (photos.allSatisfy(Self.isRAW) || !photos.contains(where: Self.isRAW))
    }
    /// Opens the merge view for the selected brackets.
    func requestHDRMerge(_ targets: [CatalogAsset]) {
        guard canMergeHDR(targets) else { return }
        hdrMerge = HDRMergeRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// The merge takes the development of the base exposure, `editsFrom`.
    func startHDRMerge(_ merger: HDRMerger, analysis: HDRMergeAnalysis, settings: HDRMergeSettings, editsFrom base: CatalogAsset? = nil, access: [URL], format: ProcessedFormat = .original) {
        let reference = settings.reference ?? analysis.suggestedReference
        let count = analysis.frames.count - settings.excluded.count
        runMergeJob(beside: merger.urls[reference], suffix: MergeOutput.hdr.suffix, title: L10n.tr("Merging HDR"), editsFrom: base, access: access, format: format,
                    merge: { url, progress in try merger.merge(settings, to: url, progress: progress) },
                    done: L10n.tr("HDR merged from \(count) exposures"), detail: "",
                    stopped: L10n.tr("HDR merge stopped"), failed: { L10n.tr("The exposures couldn’t be merged. \($0)") })
    }
}
