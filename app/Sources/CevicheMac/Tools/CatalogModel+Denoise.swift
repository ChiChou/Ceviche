import AppKit
import CevicheCore

struct DenoiseRequest: Identifiable {
    let id = UUID()
    let asset: CatalogAsset
}

/// Denoise: NAFNet over a whole RAW photo, written as a linear DNG beside it that keeps its EXIF, metadata and edits.
/// One photo at a time, as each needs its own look in the dialog.
extension CatalogModel {
    func canDenoise(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.count == 1 && targets[0].inLibrary && Self.isRAW(targets[0])
    }
    /// Opens the Denoise dialog for the selected photo.
    func requestDenoise(_ targets: [CatalogAsset]) {
        guard canDenoise(targets) else { return }
        denoise = DenoiseRequest(asset: targets[0])
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

    /// Denoises the photo as a background job. The DNG goes beside the photo when that folder is on this Mac and
    /// writable, and is imported in place; otherwise it is copied into the catalog's originals.
    func startDenoise(_ photo: CatalogAsset, settings: DenoiseSettings) {
        guard let store else { return }
        let output: PendingOutput
        do { output = try reserveOutput(source: photo, title: L10n.tr("Reducing noise"), store: store) }
        catch { self.failure = Failure(L10n.tr("Couldn’t Reduce Noise"), error); return }
        activity.start(.merging, title: L10n.tr("Reducing noise for \(photo.filename)"), detail: photo.filename) { job in
            defer { self.finishOutput(output) }
            do {
                let work = Task { try await self.denoise(photo, settings: settings, output: output, store: store) { fraction, step in
                    Task { @MainActor in
                        output.progress = fraction
                        ActivityCenter.shared.update(job, progress: fraction, detail: step)
                    }
                } }
                output.cancel = { work.cancel() }
                let made = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if self.store === store { self.indexer.workAvailable(); await self.refresh() }
                self.finishOutput(output)
                self.indexer.workAvailable()
                await self.refresh(); self.syncSoon()
                if let shown = self.assets.first(where: { $0.id == made.id }) { self.select(shown) }
                let done = L10n.tr("Saved a denoised copy of \(made.filename)")
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(made.filename), result: .photo(made.id))
            } catch is CancellationError {
                ActivityCenter.shared.finish(job, outcome: .stopped)
                self.notice = L10n.tr("Noise reduction stopped")
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Reduce Noise"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
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
        // The white balance is in the DNG's pixels; the other edits carry over, as on iPad (CevicheCore's rule for a copy).
        progress(0.96, L10n.tr("Applying edits"))
        let carriedDevelopment = try development.map { try PhotoDenoiser.carried($0, source: source) }
        var edit = try await MergeDevelopment.copied(from: photo, saved: carriedDevelopment, source: source, onto: renderer)
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
