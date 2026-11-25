import AppKit
import CevicheCore

struct PixelShiftRequest: Identifiable {
    let id = UUID()
    let assets: [CatalogAsset]
}

extension CatalogModel {
    /// Whether the photos are one set, and from a camera Pixel Shift reads, shows in the window when they are read.
    /// A set of photos, or one photo that can hold a whole set (Pentax, Hasselblad).
    func canPixelShift(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && !$0.isLatent }
            && (targets.count > 1 || Self.holdsShotSet(targets[0]))
    }
    static func holdsShotSet(_ asset: CatalogAsset) -> Bool {
        PixelShiftMerger.mayHoldSet(filename: asset.filename, camera: asset.info.camera)
    }
    func requestPixelShift(_ targets: [CatalogAsset]) {
        guard canPixelShift(targets) else { return }
        pixelShift = PixelShiftRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// The merge is the first photo's frame, so it takes that photo's edits whole.
    /// A merge too large to develop as a DNG is written as a TIFF or JPEG straight away, without the edits.
    func startPixelShift(_ merger: PixelShiftMerger, analysis: PixelShiftAnalysis, first: URL, editsFrom base: CatalogAsset? = nil, access: [URL], export: ExportFormat? = nil) {
        let count = analysis.shots
        let direct = analysis.developable ? nil : export ?? .tiff
        runMergeJob(beside: first, suffix: MergeOutput.pixelShift.suffix, title: L10n.tr("Merging Pixel Shift"), editsFrom: direct == nil ? base : nil, placed: EditTransferItem.framed,
                    access: access, export: direct ?? export, writesExport: direct != nil,
                    merge: { url, progress in
                        if let direct { try merger.export(to: url, format: direct, progress: progress) } else { try merger.merge(to: url, progress: progress) }
                    },
                    done: L10n.tr("Pixel Shift merged from \(count) photos"), detail: "",
                    stopped: L10n.tr("Pixel Shift merge stopped"), failed: { L10n.tr("The photos couldn’t be merged. \($0)") })
    }
}
