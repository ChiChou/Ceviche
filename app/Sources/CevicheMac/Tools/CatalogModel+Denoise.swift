import AppKit
import CevicheCore

struct DenoiseRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
}

/// Denoise: NAFNet over a whole RAW photo, written as a linear DNG beside it that keeps its EXIF, metadata and edits.
extension CatalogModel {
    func canDenoise(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && Self.isRAW($0) }
    }
    /// Opens the Denoise dialog for the selected photos.
    func requestDenoise(_ targets: [CatalogAsset]) {
        guard canDenoise(targets) else { return }
        denoise = DenoiseRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// The photo's saved Exposure, which Denoise brightens it by before the network looks at it.
    func denoiseExposure(_ asset: CatalogAsset) async -> Double {
        guard let store, let current = try? await store.asset(asset.id), let saved = try? await store.savedAdjustments(of: current) else { return 0 }
        return saved.exposure
    }
    /// The photo's saved Exposure and white balance, which Denoise develops it at.
    func denoiseDevelopment(_ asset: CatalogAsset) async -> DenoiseDevelopment {
        guard let store, let current = try? await store.asset(asset.id), let saved = try? await store.savedAdjustments(of: current) else { return DenoiseDevelopment() }
        return DenoiseDevelopment(saved)
    }

    /// Denoises the photos one after another as one background job. Each DNG goes beside its photo when that folder is
    /// on this Mac and writable, and is imported in place; otherwise it is copied into the catalog's originals.
    func startDenoise(_ photos: [CatalogAsset], settings: DenoiseSettings) {
        guard let store, !photos.isEmpty else { return }
        let title = photos.count == 1 ? L10n.tr("Reducing noise for \(photos[0].filename)") : L10n.tr("Reducing noise for \(photos.count.formatted()) photos")
        var outputs: [PendingOutput] = []
        do { for photo in photos { outputs.append(try reserveOutput(source: photo, title: L10n.tr("Reducing noise"), store: store)) } }
        catch { outputs.forEach(finishOutput); self.failure = Failure(L10n.tr("Couldn’t Reduce Noise"), error); return }
        activity.start(.merging, title: title, detail: photos[0].filename, total: photos.count == 1 ? nil : photos.count) { job in
            defer { outputs.forEach(self.finishOutput) }
            var made: [CatalogAsset] = [], failures: [String] = []
            for (number, photo) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                ActivityCenter.shared.update(job, completed: number, detail: photo.filename)
                let output = outputs[number]
                guard !output.aborted else { self.finishOutput(output); continue }
                do {
                    let work = Task { try await self.denoise(photo, settings: settings, output: output, store: store) { fraction, step in
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
                self.notice = made.isEmpty ? L10n.tr("Noise reduction stopped") : L10n.tr("Noise reduction stopped after \(made.count) of \(photos.count) photos")
                return
            }
            let done = made.count == 1 ? L10n.tr("Saved a denoised copy of \(made[0].filename)") : L10n.tr("Saved denoised copies of \(made.count.formatted()) photos")
            if failures.isEmpty {
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(made.count == 1 ? made[0].filename : ""), result: made.last.map { .photo($0.id) })
            } else {
                self.failure = Failure(L10n.tr("Some Photos Weren’t Denoised"), summary: L10n.tr("Saved denoised copies of \(made.count) of \(photos.count) photos.\n").trimmingCharacters(in: .newlines), items: failures)
                ActivityCenter.shared.finish(job, outcome: .failed(failures.joined(separator: "\n")))
            }
        }
    }

    /// Denoises one photo into a DNG, imports it and gives it the photo's edits and metadata.
    private func denoise(_ photo: CatalogAsset, settings: DenoiseSettings, output: PendingOutput, store: CatalogStore,
                         progress: @escaping @Sendable (Double, String) -> Void) async throws -> CatalogAsset {
        try Task.checkCancellation()
        guard self.store === store, !output.aborted else { throw CancellationError() }
        let source = try await resolveOriginal(photo)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let current = try await store.asset(photo.id)
        // An unreadable development denoises as shot, as the dialog's preview did.
        let development = (try? await store.savedAdjustments(of: current)) ?? nil
        let denoising = DenoiseDevelopment(development)
        let folder = source.deletingLastPathComponent()
        let insideCatalog = source.standardizedFileURL.path.hasPrefix(store.originalsRoot.standardizedFileURL.path + "/")
        let beside = !insideCatalog && AssetLocator.describing(source).scheme == .file && (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true && FileManager.default.isWritableFile(atPath: folder.path)
        let directory = output.scratchDirectory
        defer { if !beside { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(stem)-\(PhotoDenoiser.suffix).dng")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)-\(PhotoDenoiser.suffix)-\(number).dng"); number += 1
        }
        let url = destination
        var installed = false
        var copied: URL?
        defer {
            if !installed {
                try? FileManager.default.removeItem(at: url)
                if let copied { try? FileManager.default.removeItem(at: copied) }
            }
        }
        let work = Task.detached(priority: .userInitiated) {
            try PhotoDenoiser.denoise(source, to: url, settings: settings, development: denoising, progress: { progress(0.9 * $0, $1) }, cancelled: { Task.isCancelled })
        }
        do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch { try? FileManager.default.removeItem(at: url); throw error }

        progress(0.92, L10n.tr("Adding to the catalog"))
        var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
        if beside { options.copyFolder = folder }
        let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
        var asset = prepared.0; asset.importBatchID = UUID().uuidString; asset.id = output.id
        var thumbnail = prepared.1
        // Title, caption, keywords, rating and a location set in the catalog come along, not only what the file says.
        asset.metadata = current.metadata

        let imported = CatalogImporter.sourceURL(for: asset.asset, root: store.root)
        copied = imported
        try output.recordGenerated(copied)
        let renderer = try await Task.detached { try RawRenderer(sourceURL: imported) }.value
        var edit: Adjustments
        // The white balance is in the DNG's pixels; the other edits carry over.
        let carriedDevelopment = try development.map { try PhotoDenoiser.carried($0, source: source) }
        if let carried = try await mergeDevelopment(from: photo, onto: renderer, sourceStore: store, development: .some(carriedDevelopment), progress: { progress(0.96, $0) }) {
            edit = carried
        } else {
            // Unedited, it still looks as the photo does as shot, despite the generic file's milder tone response.
            edit = renderer.info.defaults
            let original = try await Task.detached { try RawRenderer(sourceURL: source) }.value
            edit.exposure += try await Self.exposureMatching(renderer, edit, to: original, original.info.defaults)
        }
        // The noise is gone; the decoder's own noise reduction would only soften detail on top.
        edit.noiseReduction = 0
        if edit.colorNoiseReduction != nil { edit.colorNoiseReduction = 0 }
        if edit != renderer.info.defaults {
            let rendered = try await renderer.preview(edit)
            asset.adjustmentsData = try JSONEncoder().encode(edit)
            thumbnail = rendered.thumbnail
        }
        try output.beginCommit()
        let inserted = try await store.insertCompletedOutput(asset, thumbnail: thumbnail)
        installed = true
        if let album = output.albumID { try? await store.addToAlbum(album, assetIDs: [inserted.id]) }
        return inserted
    }
}
