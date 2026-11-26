import AppKit
import CevicheCore

struct WideAngleRequest: Identifiable {
    let id = UUID()
    let asset: CatalogAsset
}

/// Wide-Angle Faces: people at the sides of a wide-angle group shot made their true shape again, written beside the
/// photo with its EXIF, metadata and edits: a RAW as a linear DNG, a HEIC or JPEG in its own format, gain map included.
/// One photo at a time, as each needs its own people and lens checked in the dialog.
extension CatalogModel {
    func canCorrectWideAngle(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.count == 1 && targets[0].inLibrary && !targets[0].isLatent
    }
    /// Opens the Wide-Angle Faces dialog for the selected photo. A photo it can't correct yet, without a focal length
    /// or shot with a long lens, is shown there with why, and a focal length typed there makes it correctable.
    func requestWideAngle(_ targets: [CatalogAsset]) {
        guard canCorrectWideAngle(targets) else { return }
        wideAngle = WideAngleRequest(asset: targets[0])
    }

    /// Corrects the photo as a background job. `people` are the dialog's people, nil to find them anew; `focal` is a
    /// focal length typed there. The copy goes beside the photo when that folder is on this Mac and writable, and is
    /// imported in place; otherwise it is copied into the catalog's originals.
    func startWideAngle(_ photo: CatalogAsset, settings: WideAngleSettings, people: [WideAnglePerson]?, focal: Double?) {
        guard let store else { return }
        let output: PendingOutput
        do { output = try reserveOutput(source: photo, title: L10n.tr("Correcting faces"), store: store) }
        catch { self.failure = Failure(L10n.tr("Couldn’t Correct Faces"), error); return }
        activity.start(.merging, title: L10n.tr("Correcting faces in \(photo.filename)"), detail: photo.filename) { job in
            defer { self.finishOutput(output) }
            do {
                let work = Task { try await self.correctWideAngle(photo, settings: settings, people: people, focal: focal, output: output, store: store) { fraction, step in
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
                let done = L10n.tr("Saved a corrected copy of \(made.filename)")
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(made.filename), result: .photo(made.id))
            } catch is CancellationError {
                ActivityCenter.shared.finish(job, outcome: .stopped)
                self.notice = L10n.tr("Face correction stopped")
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Correct Faces"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }

    /// Corrects one photo into a DNG, imports it and gives it the photo's edits and metadata.
    private func correctWideAngle(_ photo: CatalogAsset, settings: WideAngleSettings, people: [WideAnglePerson]?, focal: Double?, output: PendingOutput, store: CatalogStore,
                                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> CatalogAsset {
        try Task.checkCancellation()
        guard self.store === store, !output.aborted else { throw CancellationError() }
        let source = try await resolveOriginal(photo)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let current = try await store.asset(photo.id)
        let development = (try? await store.savedAdjustments(of: current)) ?? nil
        let folder = source.deletingLastPathComponent()
        let insideCatalog = source.standardizedFileURL.path.hasPrefix(store.originalsRoot.standardizedFileURL.path + "/")
        let beside = !insideCatalog && AssetLocator.describing(source).scheme == .file && (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true && FileManager.default.isWritableFile(atPath: folder.path)
        let directory = output.scratchDirectory
        defer { if !beside { try? FileManager.default.removeItem(at: directory) } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = WideAngleFaces.outputExtension(for: source, format: settings.format)
        var destination = directory.appendingPathComponent("\(stem)-\(WideAngleFaces.suffix).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)-\(WideAngleFaces.suffix)-\(number).\(ext)"); number += 1
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
            try autoreleasepool {
                try WideAngleFaces.correct(source, to: url, settings: settings, people: people, focalLength: focal, retouch: development?.retouch ?? [], progress: { progress(0.9 * $0, $1) }, cancelled: { Task.isCancelled })
            }
        }
        do { try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
        catch { try? FileManager.default.removeItem(at: url); throw error }

        progress(0.92, L10n.tr("Adding to the catalog"))
        var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
        if beside { options.copyFolder = folder }
        let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
        var asset = prepared.0; asset.importBatchID = UUID().uuidString; asset.id = output.id
        var thumbnail = prepared.1
        asset.metadata = current.metadata

        let imported = CatalogImporter.sourceURL(for: asset.asset, root: store.root)
        copied = imported
        try output.recordGenerated(copied)
        let renderer = try await Task.detached { try RawRenderer(sourceURL: imported) }.value
        // Edits placed on the picture (masks, crops) stay behind: the people moved under them. Its retouching is burnt in.
        // CevicheCore's rule for a copy, shared with iPad.
        progress(0.96, L10n.tr("Applying edits"))
        let edit = try await MergeDevelopment.copied(from: photo, saved: development, source: source, onto: renderer)
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
