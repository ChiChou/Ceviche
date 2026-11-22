import AppKit
import CevicheCore

struct WideAngleRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
}

/// Wide-Angle Faces: people at the sides of a wide-angle group shot made their true shape again, written beside the
/// photo with its EXIF, metadata and edits: a RAW as a linear DNG, a HEIC or JPEG in its own format, gain map included.
extension CatalogModel {
    func canCorrectWideAngle(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && !targets.isEmpty && targets.allSatisfy { $0.inLibrary && !$0.isLatent }
    }
    /// Opens the Wide-Angle Faces dialog for the selected photos. Photos it can't correct yet, without a focal length
    /// or shot with a long lens, are shown there with why, and a focal length typed there makes them correctable.
    func requestWideAngle(_ targets: [CatalogAsset]) {
        guard canCorrectWideAngle(targets) else { return }
        wideAngle = WideAngleRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// Corrects the photos one after another as one background job. `people` holds the dialog's people for the photos
    /// it showed; the others are found anew. `focals` are the focal lengths typed there. Each DNG goes beside its photo when that folder is on this Mac and
    /// writable, and is imported in place; otherwise it is copied into the catalog's originals.
    func startWideAngle(_ photos: [CatalogAsset], settings: WideAngleSettings, people: [String: [WideAnglePerson]], focals: [String: Double]) {
        guard let store, !photos.isEmpty else { return }
        let title = photos.count == 1 ? L10n.tr("Correcting faces in \(photos[0].filename)") : L10n.tr("Correcting faces in \(photos.count.formatted()) photos")
        var outputs: [PendingOutput] = []
        do { for photo in photos { outputs.append(try reserveOutput(source: photo, title: L10n.tr("Correcting faces"), store: store)) } }
        catch { outputs.forEach(finishOutput); self.failure = Failure(L10n.tr("Couldn’t Correct Faces"), error); return }
        activity.start(.merging, title: title, detail: photos[0].filename, total: photos.count == 1 ? nil : photos.count) { job in
            defer { outputs.forEach(self.finishOutput) }
            var made: [CatalogAsset] = [], failures: [String] = []
            for (number, photo) in photos.enumerated() {
                guard !Task.isCancelled else { break }
                ActivityCenter.shared.update(job, completed: number, detail: photo.filename)
                let output = outputs[number]
                guard !output.aborted else { self.finishOutput(output); continue }
                do {
                    let work = Task { try await self.correctWideAngle(photo, settings: settings, people: people[photo.id], focal: focals[photo.id], output: output, store: store) { fraction, step in
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
                self.notice = made.isEmpty ? L10n.tr("Face correction stopped") : L10n.tr("Face correction stopped after \(made.count) of \(photos.count) photos")
                return
            }
            let done = made.count == 1 ? L10n.tr("Saved a corrected copy of \(made[0].filename)") : L10n.tr("Saved corrected copies of \(made.count.formatted()) photos")
            if failures.isEmpty {
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(made.count == 1 ? made[0].filename : ""), result: made.last.map { .photo($0.id) })
            } else {
                self.failure = Failure(L10n.tr("Some Photos Weren’t Corrected"), summary: L10n.tr("Saved corrected copies of \(made.count) of \(photos.count) photos."), items: failures)
                ActivityCenter.shared.finish(job, outcome: .failed(failures.joined(separator: "\n")))
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
            try WideAngleFaces.correct(source, to: url, settings: settings, people: people, focalLength: focal, retouch: development?.retouch ?? [], progress: { progress(0.9 * $0, $1) }, cancelled: { Task.isCancelled })
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
        var edit: Adjustments
        // Edits placed on the picture (masks, crops) stay behind: the people moved under them. Its retouching is burnt in.
        if !Self.isRAW(photo) {
            // The copy has the photo's own rendering, tone and white balance included: its edits carry as they are, and
            // matching brightness would only answer the change in composition.
            edit = try development.map { try EditTransfer(sourceName: photo.filename, adjustments: $0, items: EditTransferItem.defaults).applying(to: renderer.info.defaults) }
                ?? renderer.info.defaults
        } else if let carried = try await mergeDevelopment(from: photo, onto: renderer, sourceStore: store, development: .some(development), progress: { progress(0.96, $0) }) {
            edit = carried
        } else {
            edit = renderer.info.defaults
            let original = try await Task.detached { try RawRenderer(sourceURL: source) }.value
            edit.exposure += try await Self.exposureMatching(renderer, edit, to: original, original.info.defaults)
        }
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
