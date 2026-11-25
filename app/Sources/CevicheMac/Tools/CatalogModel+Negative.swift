import AppKit
import CevicheCore

struct NegativeRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
}

/// Convert Negative: a camera scan of a film negative, straightened, cropped and inverted into a linear DNG beside it.
/// Dust and damage are left to retouching in Develop.
extension CatalogModel {
    func canConvertNegative(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && Self.isRAW($0) }
    }

    func requestNegative(_ targets: [CatalogAsset]) {
        guard canConvertNegative(targets) else { return }
        negative = NegativeRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// Converts the scans one after another as one background job, like Denoise.
    func startNegative(_ photos: [CatalogAsset], choices: [String: NegativeChoice]) {
        guard let store, !photos.isEmpty else { return }
        let title = photos.count == 1 ? L10n.tr("Converting \(photos[0].filename)") : L10n.tr("Converting \(photos.count.formatted()) negatives")
        var outputs: [PendingOutput] = []
        do { for photo in photos { outputs.append(try reserveOutput(source: photo, title: L10n.tr("Converting \(photo.filename)"), store: store)) } }
        catch { outputs.forEach(finishOutput); self.failure = Failure(L10n.tr("Couldn’t Convert the Negatives"), error); return }
        activity.start(.merging, title: title, detail: photos[0].filename, total: photos.count == 1 ? nil : photos.count) { job in
            defer { outputs.forEach(self.finishOutput) }
            var made: [CatalogAsset] = [], failures: [String] = []
            for (number, photo) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                ActivityCenter.shared.update(job, completed: number, detail: photo.filename)
                let output = outputs[number]
                guard !output.aborted else { self.finishOutput(output); continue }
                do {
                    let work = Task { try await self.convertNegative(photo, choice: choices[photo.id] ?? NegativeChoice(), output: output, store: store) { fraction, step in
                        let detail = photos.count == 1 ? step : L10n.tr("\(number + 1) of \(photos.count) - \(step)")
                        Task { @MainActor in
                            output.progress = fraction
                            ActivityCenter.shared.update(job, progress: (Double(number) + fraction) / Double(photos.count), detail: detail)
                        }
                    } }
                    output.cancel = { work.cancel() }
                    made.append(try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() })
                    if self.store === store { self.indexer.workAvailable(); await self.refresh() }
                    self.finishOutput(output)
                } catch is CancellationError {
                    self.finishOutput(output)
                    if Task.isCancelled { break }
                } catch {
                    self.finishOutput(output)
                    failures.append("\(photo.filename): \(error.localizedDescription)")
                }
            }
            if !made.isEmpty {
                self.indexer.workAvailable()
                await self.refresh(); self.syncSoon()
                if let shown = self.assets.first(where: { $0.id == made.last?.id }) { self.select(shown) }
            }
            // Errors outrank a stop: an aborted photo must not hide why another failed.
            if failures.isEmpty, Task.isCancelled || outputs.contains(where: { $0.aborted }) {
                ActivityCenter.shared.finish(job, outcome: .stopped)
                self.notice = made.isEmpty ? L10n.tr("Convert Negative stopped") : L10n.tr("Convert Negative stopped after \(made.count) of \(photos.count) photos")
                return
            }
            let done = made.count == 1 ? L10n.tr("Saved a positive of \(made[0].filename)") : L10n.tr("Saved positives of \(made.count.formatted()) negatives")
            if failures.isEmpty {
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(made.count == 1 ? made[0].filename : ""), result: made.last.map { .photo($0.id) })
            } else {
                self.failure = Failure(L10n.tr("Some Negatives Weren’t Converted"), summary: L10n.tr("Saved positives of \(made.count) of \(photos.count) negatives.\n").trimmingCharacters(in: .newlines), items: failures)
                ActivityCenter.shared.finish(job, outcome: .failed(failures.joined(separator: "\n")))
            }
        }
    }

    /// Converts one scan into a DNG, imports it and gives it the scan's metadata.
    private func convertNegative(_ photo: CatalogAsset, choice: NegativeChoice, output: PendingOutput, store: CatalogStore,
                                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> CatalogAsset {
        try Task.checkCancellation()
        guard self.store === store, !output.aborted else { throw CancellationError() }
        let source = try await resolveOriginal(photo)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let folder = source.deletingLastPathComponent()
        let insideCatalog = source.standardizedFileURL.path.hasPrefix(store.originalsRoot.standardizedFileURL.path + "/")
        let beside = !insideCatalog && AssetLocator.describing(source).scheme == .file && (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true && FileManager.default.isWritableFile(atPath: folder.path)
        let directory = output.scratchDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = NegativeConverter.destination(for: source, in: directory)
        var installed = false
        var copied: URL?
        defer { if !installed, let copied { try? FileManager.default.removeItem(at: copied) } }
        let work = Task.detached(priority: .userInitiated) {
            try NegativeConverter.convert(source, to: url, choice: choice, progress: { progress(0.9 * $0, $1) }, cancelled: { Task.isCancelled })
        }
        do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch { try? FileManager.default.removeItem(at: url); throw error }

        progress(0.92, L10n.tr("Adding to the catalog"))
        var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
        if beside { options.copyFolder = folder }
        let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
        var asset = prepared.0; asset.importBatchID = UUID().uuidString; asset.id = output.id
        copied = CatalogImporter.sourceURL(for: asset.asset, root: store.root)
        try output.recordGenerated(copied)
        let current = try await store.asset(photo.id)
        asset.metadata = current.metadata
        try output.beginCommit()
        let inserted = try await store.insertCompletedOutput(asset, thumbnail: prepared.1)
        installed = true
        if let album = output.albumID { try? await store.addToAlbum(album, assetIDs: [inserted.id]) }
        return inserted
    }
}
