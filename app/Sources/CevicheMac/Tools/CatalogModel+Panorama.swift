import AppKit
import CevicheCore

struct PanoramaMergeRequest: Identifiable {
    let id = UUID()
    /// In capture order.
    let assets: [CatalogAsset]
    /// The latent image opened, with its photos as `assets` and their stamps as saved.
    var latent: (assetID: String, saved: PanoramaLatent, sources: [LatentImage.Source])? = nil
}

extension CatalogModel {
    static func isRAW(_ asset: CatalogAsset) -> Bool {
        CatalogImporter.rawExtensions.contains((asset.filename as NSString).pathExtension.lowercased())
    }
    /// Whether a tool's photos are processed ones, whose result can be kept as they are or as a TIFF.
    static func processed(_ assets: [CatalogAsset]) -> Bool { !assets.isEmpty && !assets.contains(where: isRAW) }
    func canMergePanorama(_ targets: [CatalogAsset]) -> Bool {
        store != nil && canStartJob && !toolOpen && targets.count >= 2 && targets.allSatisfy { $0.inLibrary && !$0.isLatent && Self.isRAW($0) }
    }
    /// Opens the merge view for the selected photos; brackets among them are found there.
    func requestPanoramaMerge(_ targets: [CatalogAsset]) {
        guard canMergePanorama(targets) else { return }
        panoramaMerge = PanoramaMergeRequest(assets: targets.sorted { ($0.captureTime ?? "", $0.filename) < ($1.captureTime ?? "", $1.filename) })
    }

    /// Merges in the background, imports the DNG and selects it. `access` holds the security-scoped originals open until
    /// the merge is done.
    func startPanoramaMerge(_ merger: PanoramaMerger, alignment: PanoramaAlignment, settings: PanoramaSettings, hdr: Bool = false, editsFrom base: CatalogAsset? = nil, access: [URL]) {
        let left = alignment.excluded.count
        runMergeJob(beside: merger.urls[alignment.included.first ?? 0], suffix: hdr ? "HDR-Panorama" : "Panorama", title: hdr ? L10n.tr("Merging HDR panorama") : L10n.tr("Merging panorama"),
                    editsFrom: base, access: access,
                    merge: { url, progress in try merger.merge(settings, to: url, progress: progress) },
                    done: left == 0 ? L10n.tr("Panorama merged") : (left == 1 ? L10n.tr("Panorama merged - \(left) photo left out") : L10n.tr("Panorama merged - \(left) photos left out")),
                    detail: left == 0 ? "" : L10n.tr(" - \(left) left out"),
                    stopped: L10n.tr("Panorama merge stopped"), failed: { L10n.tr("The panorama couldn’t be merged. \($0)") })
    }

    /// Runs a merge that writes a DNG as a background job, imports the DNG and selects it. The DNG goes beside `first`
    /// when that folder is on this Mac and writable, and is imported in place; otherwise it is copied into the catalog's
    /// originals. `access` holds the security-scoped originals open until the merge is done.
    /// The exposure change that brings `renderer`'s picture with `edit` to the mean brightness of `target` with `targetEdit`.
    static func exposureMatching(_ renderer: RawRenderer, _ edit: Adjustments, to target: RawRenderer, _ targetEdit: Adjustments) async throws -> Double {
        func brightness(_ image: CGImage) -> Double {
            let picture = CIImage(cgImage: image)
            guard let mean = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: picture, kCIInputExtentKey: CIVector(cgRect: picture.extent)])?.outputImage else { return 0 }
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(mean, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        }
        let goal = brightness(try await target.displayImage(targetEdit, maxDimension: 512, sdr: true))
        // Brightness rises with exposure, so halving the interval converges; a hundredth of a stop is close enough.
        var low = -2.0, high = 2.0
        for _ in 0..<9 {
            var trial = edit
            trial.exposure += (low + high) / 2
            if brightness(try await renderer.displayImage(trial, maxDimension: 512, sdr: true)) < goal { low = (low + high) / 2 } else { high = (low + high) / 2 }
        }
        return ((low + high) / 2 * 100).rounded() / 100
    }

    /// The development of a merge in `renderer`: the source photo's, as Paste Edits copies it (lens correction is already
    /// in the pixels). Nil when the source has no edits of its own; Auto is one click away in Develop. A merge that keeps
    /// the source's framing pixel for pixel also takes what is placed on the picture: `placed`.
    func mergeDevelopment(from source: CatalogAsset?, onto renderer: RawRenderer, placed: Set<EditTransferItem> = [],
                          sourceStore: CatalogStore? = nil, development: Adjustments?? = nil,
                          progress: (String) -> Void = { _ in }) async throws -> Adjustments? {
        guard let store = sourceStore ?? store else { return nil }
        let defaults = renderer.info.defaults
        guard let source else { return nil }
        let savedValue: Adjustments?
        if let development { savedValue = development } else { savedValue = try await store.savedAdjustments(of: store.asset(source.id)) }
        guard let saved = savedValue else { return nil }
        progress(L10n.tr("Applying edits"))
        // The merge was developed at the source's as-shot white balance and is stored with a neutral one, so the source's
        // white balance carries over as its change from as shot, not as the same numbers.
        // A processed photo's merge is encoded back through the photo's own profile, so it looks as the photo did and its
        // edits carry as they are.
        guard renderer.info.isRAW else {
            let transfer = EditTransfer(sourceName: source.filename, adjustments: saved, items: EditTransferItem.defaults.subtracting([.lensCorrection]).union(placed))
            return try transfer.applying(to: defaults)
        }
        let sourceURL = CatalogImporter.sourceURL(for: source, root: store.root)
        let original = try await Task.detached { try RawRenderer(sourceURL: sourceURL) }.value
        let asShot = original.info.defaults
        var carried = saved
        carried.temperature = min(50000, max(2000, 1e6 / (1e6 / defaults.temperature + 1e6 / saved.temperature - 1e6 / asShot.temperature)))
        carried.tint = min(150, max(-150, defaults.tint + saved.tint - asShot.tint))
        let transfer = EditTransfer(sourceName: source.filename, adjustments: carried, items: EditTransferItem.defaults.subtracting([.lensCorrection]).union(placed))
        var edit = try transfer.applying(to: defaults)
        // Any difference in brightness between the source and the merge with the same sliders (merges written before their
        // DNGs dropped the identity tone curve opened flatter) is made up with exposure.
        // A framed merge is the source's own exposure, or a blend of lights that is meant to be brighter.
        if placed.isEmpty { edit.exposure += try await Self.exposureMatching(renderer, edit, to: original, saved) }
        return edit
    }

    /// Each photo's own retouching by its original's URL, AI fills included, for a merge to burn into the photo before
    /// aligning: dust, removed objects and face spots are in each photo's own place, not their place in the result.
    func retouching(of assets: [CatalogAsset], at urls: [URL]) async -> [URL: [RetouchStroke]] {
        guard let store else { return [:] }
        var found: [URL: [RetouchStroke]] = [:]
        for (asset, url) in zip(assets, urls) {
            if let saved = try? await store.savedAdjustments(of: asset), !saved.retouch.isEmpty { found[url] = saved.retouch }
        }
        return found
    }

    /// A merge preview developed as the result will be: with the edits of `asset`, the photo the result is based on.
    /// `known` is what an earlier call found for that photo, so its edits are read once; `.some(nil)` is a photo with
    /// none, which leaves the preview as drawn, as a failure does.
    func developedPreview(_ source: MergePreviewSource, from asset: CatalogAsset, placed: Set<EditTransferItem>, maxDimension: Int,
                          known: Adjustments??) async -> (image: CGImage?, edit: Adjustments??) {
        if case .some(.none) = known { return (nil, known) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Ceviche Merge Preview \(UUID().uuidString).\(source.fileExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let renderer = try await Task.detached(priority: .userInitiated) { try source.write(to: file); return try RawRenderer(sourceURL: file) }.value
            let edit: Adjustments
            if case .some(.some(let found)) = known { edit = found } else {
                guard let found = try await mergeDevelopment(from: asset, onto: renderer, placed: placed) else { return (nil, .some(nil)) }
                edit = found
            }
            return (try await renderer.displayImage(edit, maxDimension: Double(maxDimension), sdr: true), .some(edit))
        } catch { return (nil, known) }
    }

    /// A merge of processed photos is kept as `format` asks (see `ProcessedFormat`); of RAW photos, as a DNG.
    /// With `export`, the merge is developed with the photo defaults and kept in that format instead of the DNG, which
    /// is written to a temporary folder and removed: a full-quality JPEG or a 16-bit TIFF, for results whose DNG is too
    /// large to keep. With `writesExport` the merge writes that file itself: for a result too large to develop as a DNG,
    /// which then takes no edits.
    func runMergeJob(beside first: URL, suffix: String, title: String, editsFrom source: CatalogAsset? = nil, placed: Set<EditTransferItem> = [], access: [URL], export: ExportFormat? = nil,
                     writesExport: Bool = false, format: ProcessedFormat = .original,
                     merge: @escaping @Sendable (URL, @escaping @Sendable (Double, String) -> Void) throws -> Void,
                     done: String, detail: String, stopped: String, failed: @escaping (String) -> String) {
        guard let store else { access.forEach { $0.stopAccessingSecurityScopedResource() }; return }
        let output: PendingOutput
        do { output = try reserveOutput(source: source, title: title, store: store) }
        catch { access.forEach { $0.stopAccessingSecurityScopedResource() }; self.failure = Failure(L10n.tr("Couldn’t Start the Merge"), error); return }
        let folder = first.deletingLastPathComponent()
        let insideCatalog = first.standardizedFileURL.path.hasPrefix(store.originalsRoot.standardizedFileURL.path + "/")
        let beside = !insideCatalog && AssetLocator.describing(first).scheme == .file && (try? folder.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true && FileManager.default.isWritableFile(atPath: folder.path)
        let directory = output.scratchDirectory
        let stem = first.deletingPathExtension().lastPathComponent
        let fileExtension = export?.fileExtension ?? ToolResult.fileExtension(for: first, format: format)
        var destination = directory.appendingPathComponent("\(stem)-\(suffix).\(fileExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) { destination = directory.appendingPathComponent("\(stem)-\(suffix)-\(number).\(fileExtension)"); number += 1 }
        let url = destination
        let scratch = directory.appendingPathComponent("DNG")
        let rendersExport = export != nil && !writesExport
        let merged = rendersExport ? scratch.appendingPathComponent("\(stem)-\(suffix).dng") : url
        let activityID = activity.start(.merging, title: title, detail: url.lastPathComponent) { job in
            var installed = false
            var copied: URL?
            defer {
                if !installed {
                    try? FileManager.default.removeItem(at: url)
                    if let copied { try? FileManager.default.removeItem(at: copied) }
                }
                self.finishOutput(output)
                access.forEach { $0.stopAccessingSecurityScopedResource() }
                if !beside { try? FileManager.default.removeItem(at: directory) }
                if rendersExport { try? FileManager.default.removeItem(at: scratch) }
            }
            do {
                guard !output.aborted else { throw CancellationError() }
                let development: Adjustments?
                // Carrying the source's edits over is a courtesy: edits that can't be read leave the merge undeveloped.
                if let source { development = (try? await store.savedAdjustments(of: store.asset(source.id))) ?? nil } else { development = nil }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if rendersExport { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) }
                let share = rendersExport ? 0.8 : 0.95
                let work = Task.detached(priority: .userInitiated) {
                    try merge(merged) { fraction, step in
                        Task { @MainActor in
                            output.progress = fraction * share
                            ActivityCenter.shared.update(job, progress: fraction * share, detail: step)
                        }
                    }
                }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                if let export, rendersExport {
                    ActivityCenter.shared.update(job, progress: 0.82, detail: L10n.tr("Writing \(export.rawValue)"))
                    let renderer = try await Task.detached(priority: .userInitiated) { try RawRenderer(sourceURL: merged) }.value
                    var settings = ExportSettings(); settings.select(export); settings.quality = 1; settings.profile.preset = .sRGB
                    if settings.depths.contains(16) { settings.depth = 16 }
                    let edit = ((try? await self.mergeDevelopment(from: source, onto: renderer, placed: placed, sourceStore: store, development: .some(development))) ?? nil) ?? renderer.info.defaults
                    try await renderer.export(to: url, adjustments: edit, settings: settings)
                    try? FileManager.default.removeItem(at: scratch)
                }
                ActivityCenter.shared.update(job, progress: 0.96, detail: L10n.tr("Adding to the catalog"))
                var options = CatalogImporter.ImportOptions(mode: .copy, catalogRoot: store.originalsRoot)
                if beside { options.copyFolder = folder }
                let prepared = try await Task.detached(priority: .utility) { try CatalogImporter.prepare(url, options: options) }.value
                var asset = prepared.0; asset.importBatchID = UUID().uuidString; asset.id = output.id
                var thumbnail = prepared.1
                copied = CatalogImporter.sourceURL(for: asset.asset, root: store.root)
                try output.recordGenerated(copied)
                if source != nil, export == nil {
                    let imported = CatalogImporter.sourceURL(for: asset.asset, root: store.root)
                    let renderer = try await Task.detached { try RawRenderer(sourceURL: imported) }.value
                    // A finished merge is never thrown away over its carried-over edits.
                    if let edit = (try? await self.mergeDevelopment(from: source, onto: renderer, placed: placed, sourceStore: store, development: .some(development), progress: { detail in
                        ActivityCenter.shared.update(job, progress: 0.98, detail: detail)
                    })) ?? nil, edit != renderer.info.defaults {
                        let rendered = try await renderer.preview(edit)
                        asset.adjustmentsData = try JSONEncoder().encode(edit)
                        thumbnail = rendered.thumbnail
                    }
                }
                try output.beginCommit()
                let inserted = try await store.insertCompletedOutput(asset, thumbnail: thumbnail)
                installed = true
                if let album = output.albumID { try? await store.addToAlbum(album, assetIDs: [inserted.id]) }
                self.indexer.workAvailable()
                await self.refresh(); self.syncSoon()
                if let shown = self.assets.first(where: { $0.id == inserted.id }) { self.select(shown) }
                self.notice = done
                ActivityCenter.shared.finish(job, title: done, outcome: .done(url.lastPathComponent + detail), result: .photo(inserted.id))
            } catch is CancellationError {
                self.notice = stopped
            } catch {
                self.failure = Failure(L10n.tr("Couldn’t Merge the Photos"), failed(error.localizedDescription))
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
        output.cancel = { ActivityCenter.shared.cancel(activityID) }
    }
}
