import Foundation
import CevicheCore

struct ExposureRampRequest: Identifiable {
    let id = UUID()
    /// As selected; the dialog orders them by capture time.
    let assets: [CatalogAsset]
    /// The photo whose Exposure the others are balanced against.
    let referenceID: String?
}

/// Balance Exposure: evens out the light of a sequence such as a sunset timelapse, frame by frame.
extension CatalogModel {
    func canBalanceExposure(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.filter { $0.inLibrary && !$0.isLatent }.count >= 3
    }
    func requestExposureRamp(_ targets: [CatalogAsset], reference: CatalogAsset? = nil) {
        let photos = targets.filter { $0.inLibrary && !$0.isLatent }
        guard store != nil, canStartJob, !toolOpen, photos.count >= 3 else { return }
        let reference = reference ?? selected
        exposureRamp = ExposureRampRequest(assets: photos, referenceID: photos.contains { $0.id == reference?.id } ? reference?.id : nil)
    }

    /// Each frame's light before its Exposure, and its Exposure now, measured several frames at a time.
    /// `progress` receives how many are done.
    func measureExposure(_ frames: [CatalogAsset], progress: @escaping @MainActor (Int) -> Void) async throws -> [(light: Double, exposure: Double)] {
        guard let store else { throw CancellationError() }
        var results = [(light: Double, exposure: Double)?](repeating: nil, count: frames.count)
        try await withThrowingTaskGroup(of: (Int, Double, Double).self) { group in
            var next = 0, done = 0
            func add() async throws {
                guard next < frames.count else { return }
                let index = next, asset = frames[index]; next += 1
                let source = try await resolveOriginal(asset)
                group.addTask {
                    let (light, exposure) = try await Self.measure(asset, source: source, store: store)
                    return (index, light, exposure)
                }
            }
            for _ in 0..<Self.editBatchWidth { try await add() }
            while let (index, light, exposure) = try await group.next() {
                results[index] = (light, exposure); done += 1
                progress(done)
                try await add()
            }
        }
        return results.map { $0 ?? (0, 0) }
    }
    nonisolated private static func measure(_ asset: CatalogAsset, source: URL, store: CatalogStore) async throws -> (Double, Double) {
        let current = try await store.asset(asset.id)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (renderer, defaults) = try RawRenderer.open(source)
        let settings = try await store.savedAdjustments(of: current) ?? defaults
        return (try await renderer.sceneBrightness(settings), settings.effective(defaults: defaults).exposure)
    }

    /// Sets each frame's Exposure, keeping the rest of its edits, as a job in the activity queue.
    func applyExposureRamp(_ frames: [CatalogAsset], exposures: [String: Double], editor: EditorModel) {
        let changed = frames.filter { exposures[$0.id] != nil }
        Task {
            await runEditBatch(changed, editor: editor, title: L10n.tr("Balancing exposure"),
                               inEditor: { if let id = editor.catalogAssetID, let value = exposures[id] { editor.edit { $0.exposure = value } } },
                               develop: { id, saved, defaults in
                                   var settings = saved ?? defaults
                                   if let value = exposures[id] { settings.exposure = value }
                                   return settings
                               },
                               save: { store, settings, baseline, id in try await store.saveEdits(settings, assetID: id, baseline: baseline) }) { completed, total, failures in
                if completed > 0 { self.notice = completed == 1 ? L10n.tr("Exposure balanced on 1 photo") : L10n.tr("Exposure balanced on \(completed.formatted()) photos") }
                if !failures.isEmpty { self.failure = Failure(L10n.tr("Some Photos Weren’t Changed"), summary: L10n.tr("Balanced exposure on \(completed) of \(total) photos.\n").trimmingCharacters(in: .newlines), items: failures) }
            }
        }
    }
}
