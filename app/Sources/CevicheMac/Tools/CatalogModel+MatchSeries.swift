import Foundation
import CevicheCore

struct MatchSeriesRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
    /// The photo the others are matched to.
    let referenceID: String?
}

/// Match Series: brings a selection's exposure and white balance to a reference photo's.
extension CatalogModel {
    func canMatchSeries(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.count >= 2 && targets.allSatisfy { $0.inLibrary && Self.isRAW($0) }
    }
    func requestMatchSeries(_ targets: [CatalogAsset], reference: CatalogAsset? = nil) {
        guard canMatchSeries(targets) else { return }
        let reference = reference ?? selected
        let ordered = targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) }
        matchSeries = MatchSeriesRequest(assets: ordered, referenceID: ordered.contains { $0.id == reference?.id } ? reference?.id : nil)
    }

    /// Sets each photo's Exposure, Temperature and Tint, keeping the rest of its edits, as a job in the activity queue.
    func applyMatchSeries(_ photos: [CatalogAsset], values: [String: SeriesMatchValues], exposure: Bool, whiteBalance: Bool, editor: EditorModel) {
        let changed = photos.filter { values[$0.id] != nil }
        let set: @Sendable (inout Adjustments, SeriesMatchValues) -> Void = { settings, value in
            value.apply(to: &settings, exposure: exposure, whiteBalance: whiteBalance)
        }
        Task {
            await runEditBatch(changed, editor: editor, title: L10n.tr("Matching series"),
                               inEditor: { if let id = editor.catalogAssetID, let value = values[id] { editor.edit { set(&$0, value) } } },
                               develop: { id, saved, defaults in
                                   var settings = saved ?? defaults
                                   if let value = values[id] { set(&settings, value) }
                                   return settings
                               },
                               save: { store, settings, baseline, id in try await store.saveEdits(settings, assetID: id, baseline: baseline) }) { completed, total, failures in
                if completed > 0 { self.notice = completed == 1 ? L10n.tr("1 photo matched") : L10n.tr("\(completed.formatted()) photos matched") }
                if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Photos Weren’t Changed"), summary: L10n.tr("Matched \(completed) of \(total) photos.\n").trimmingCharacters(in: .newlines), items: failures) }
            }
        }
    }
}
