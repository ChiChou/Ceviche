import SwiftUI
import UniformTypeIdentifiers
import CevicheCore

/// Exporting photos straight from the Library, one or many, without opening them in Develop.
struct CatalogExportRequest: Identifiable {
    let id = UUID()
    let assets: [CatalogAsset]
    var settings: ExportSettings = {
        var settings = ExportSettings(); settings.format = .jpeg; settings.depth = 8; settings.quality = 0.9; return settings
    }()
    /// Nil exports each photo in the color profile chosen in its development (including an imported ICC profile).
    var profile: RGBProfile?
    /// A folder chosen in the dialog; nil asks with a panel.
    var destination: URL?
    /// One photo's file name, chosen in a save panel that has already asked about replacing a file of that name.
    var fileName: String?
    var existing = ExistingFilePolicy.rename
    /// The Filters tool's stack, applied to each photo on the way out.
    var filters: CreativeFilterStack?
}

/// What a batch export does when a file with the same name is already in the folder.
enum ExistingFilePolicy: String, CaseIterable, Identifiable {
    case rename, skip, overwrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rename: return L10n.tr("Rename the new file")
        case .skip: return L10n.tr("Skip the photo")
        case .overwrite: return L10n.tr("Overwrite")
        }
    }
}

extension CatalogModel {
    /// Opens the export dialog for the selection; it previews the first photo.
    func requestExport(_ targets: [CatalogAsset]) {
        // With Creative Filters open, Export means the filtered photo: the tool's own dialog, not the Library's.
        if filters != nil { filtersExport &+= 1; return }
        if targets.count == 1, let object = targets.first, object.isLatent { openLatent(object); return }
        let targets = targets.filter { $0.trashedAt == nil && !$0.isLatent }
        guard !targets.isEmpty, let store, canStartJob else { return }
        exportSession = CatalogExportSession(assets: targets, store: store, catalog: self)
    }
    /// `stack` is Creative Filters' chain, applied on the way out.
    func share(_ targets: [CatalogAsset], filters stack: CreativeFilterStack? = nil) {
        let targets = targets.filter { $0.trashedAt == nil && !$0.isLatent }
        guard !targets.isEmpty, let store, canStartJob else { return }
        PhotoShare.export(reportError: { [weak self] in self?.error = $0 }) { folder in
            var files: [URL] = []
            for asset in targets {
                try Task.checkCancellation()
                if let url = try await Self.exportFile(asset, store: store, settings: PhotoShare.settings,
                                                       profile: .displayP3, to: folder, filters: stack) { files.append(url) }
            }
            return files
        }
    }

    /// A preset skips the sheet: the folder panel opens right away.
    func export(_ targets: [CatalogAsset], preset: ExportPreset, filters stack: CreativeFilterStack? = nil) {
        let targets = targets.filter { $0.trashedAt == nil && !$0.isLatent }
        guard !targets.isEmpty, canStartJob else { return }
        export(CatalogExportRequest(assets: targets, settings: preset.settings(), profile: preset.profile, filters: stack))
    }
    /// The folder the last batch export went to, offered again next time.
    var lastExportFolder: URL? {
        get { preferences.string(forKey: "exportFolder").flatMap { path in FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil } }
        set { preferences.set(newValue?.path, forKey: "exportFolder") }
    }
    /// Renders each photo with its saved development into the request's folder, asking for one when it has none.
    func export(_ request: CatalogExportRequest) {
        exportSession = nil
        guard canStartJob else { return }
        if let folder = request.destination { lastExportFolder = folder; export(request, to: folder); return }
        Task {
            guard let folder = await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true,
                message: request.assets.count == 1 ? L10n.tr("Choose a folder for \(request.assets.count) exported photo.") : L10n.tr("Choose a folder for \(request.assets.count) exported photos."),
                prompt: L10n.tr("Export"), directory: lastExportFolder)), canStartJob else { return }
            lastExportFolder = folder
            export(request, to: folder)
        }
    }

    private func export(_ request: CatalogExportRequest, to folder: URL) {
        guard let store else { return }
        // Each export is its own job, so a second one can start while the first is still writing.
        // A single photo has no count to advance, so its bar stays indeterminate rather than sitting at 0%.
        activity.start(.exporting, title: L10n.tr("Exporting photos"), total: request.assets.count > 1 ? request.assets.count : nil) { [weak self] job in
            guard let self else { return }
            var exported: [URL] = [], failures: [String] = [], skipped = 0
            // AI denoise is most of such an export, so the bar follows its tiles; otherwise it counts photos.
            let denoising = request.settings.aiDenoise > 0 || request.filters?.denoiseInput != nil, count = Double(request.assets.count)
            for (index, asset) in request.assets.enumerated() {
                if Task.isCancelled { break }
                activity.update(job, completed: index, progress: denoising ? Double(index) / count : nil,
                                detail: L10n.tr("\(index + 1) of \(request.assets.count) - \(asset.filename)"))
                let denoise = denoising ? DenoiseRun { [weak activity] done in
                    Task { @MainActor in activity?.update(job, progress: (Double(index) + done) / count) }
                } : nil
                do {
                    if let url = try await Self.exportFile(asset, store: store, settings: request.settings, profile: request.profile, to: folder, existing: request.existing,
                                                           name: request.fileName, filters: request.filters, denoise: denoise) { exported.append(url) }
                    else { skipped += 1 }
                } catch is CancellationError { break
                } catch { failures.append("\(asset.filename): \(error.localizedDescription)") }
            }
            var summary = [Task.isCancelled ? L10n.tr("Export stopped") : nil, exported.isEmpty ? nil : Self.counted(exported.count, .exported)].compactMap { $0 }
            if skipped > 0 { summary.append(L10n.tr("\(skipped.formatted()) already in the folder")) }
            if !summary.isEmpty { notice = summary.joined(separator: " - ") }
            if !exported.isEmpty { NSWorkspace.shared.showInFinder(exported) }
            activity.finish(job, title: L10n.tr("Export"), outcome: exported.isEmpty && !failures.isEmpty ? .failed(L10n.tr("\(failures.count.formatted()) failed"))
                            : Task.isCancelled ? .stopped : .done(summary.filter { $0 != L10n.tr("Export stopped") }.joined(separator: " - ") + (failures.isEmpty ? "" : L10n.tr(" - \(failures.count.formatted()) failed"))),
                            result: exported.isEmpty ? nil : .files(exported))
            if !failures.isEmpty { failure = Failure(L10n.tr("Some Photos Weren’t Exported"), summary: (failures.count == 1 ? L10n.tr("\(failures.count) photo couldn’t be exported.\n") : L10n.tr("\(failures.count) photos couldn’t be exported.\n")).trimmingCharacters(in: .newlines), items: failures) }
        }
    }
    func exportOriginals(_ targets: [CatalogAsset]) {
        let targets = targets.filter { $0.trashedAt == nil && !$0.isLatent }
        guard !targets.isEmpty, store != nil, canStartJob else { return }
        Task {
            guard let folder = await FileChooser.openOne(FileOpenRequest(files: false, folders: true, createFolders: true,
                message: targets.count == 1 ? L10n.tr("Choose a folder for \(targets.count) original photo with XMP.") : L10n.tr("Choose a folder for \(targets.count) original photos with XMP."),
                prompt: L10n.tr("Export Originals"), directory: lastExportFolder)) else { return }
            exportOriginals(targets, to: folder)
        }
    }
    func exportOriginals(_ targets: [CatalogAsset], to folder: URL) {
        guard let store, canStartJob else { return }
        lastExportFolder = folder
        activity.start(.exporting, title: L10n.tr("Exporting originals with XMP"), total: targets.count) { [weak self] job in
            guard let self else { return }
            var exported = 0, failures: [String] = []
            for (index, asset) in targets.enumerated() {
                if Task.isCancelled { break }
                activity.update(job, completed: index, detail: L10n.tr("\(index + 1) of \(targets.count) - \(asset.filename)"))
                do {
                    let current = try await store.asset(asset.id)
                    // Edits this build can't read don't keep the original in: it goes with the XMP it was imported
                    // with, if any, and the edits left out are listed.
                    let saved: Adjustments?, unreadable: String?
                    do { saved = try await store.savedAdjustments(of: current); unreadable = nil }
                    catch { saved = nil; unreadable = error.localizedDescription }
                    let sourceXMP: Data? = (try? await store.development(current.id))?.xmpData
                    // Copying a RAW file takes long enough to stall the window; it and the XMP are written off the main actor.
                    let sidecarProblem = try await Task.detached(priority: .userInitiated) { () throws -> String? in
                        let source = CatalogImporter.sourceURL(for: current, root: store.root)
                        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
                        let base = (current.filename as NSString).deletingPathExtension
                        let ext = source.pathExtension
                        var destination = folder.appendingPathComponent(base).appendingPathExtension(ext)
                        var suffix = 2
                        while FileManager.default.fileExists(atPath: destination.path) {
                            destination = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext); suffix += 1
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                        // The original is out; a sidecar that can't be written is reported beside it.
                        let xmpURL = destination.deletingPathExtension().appendingPathExtension("xmp")
                        do {
                            if let unreadable {
                                try sourceXMP?.write(to: xmpURL, options: .atomic)
                                return L10n.tr("exported without its edits (\(unreadable))")
                            }
                            let defaults = CatalogImporter.developmentDefaults(for: source, info: current.info)
                            let xmpData = try XMPCodec.encode(adjustments: saved ?? defaults, metadata: current.metadata, defaults: defaults, sourceData: sourceXMP, filename: source.lastPathComponent)
                            try xmpData.write(to: xmpURL, options: .atomic)
                            return nil
                        } catch { return "\(xmpURL.lastPathComponent): \(error.localizedDescription)" }
                    }.value
                    exported += 1
                    if let sidecarProblem { failures.append("\(asset.filename): \(sidecarProblem)") }
                } catch { failures.append("\(asset.filename): \(error.localizedDescription)") }
            }
            if exported > 0 { notice = Self.counted(exported, .exportedWithXMP) }
            if exported > 0 { NSWorkspace.shared.showInFinder([folder]) }
            activity.finish(job, title: L10n.tr("Export originals with XMP"), outcome: exported == 0 && !failures.isEmpty ? .failed(L10n.tr("\(failures.count.formatted()) failed"))
                            : Task.isCancelled ? .stopped : .done(Self.counted(exported, .exported) + (failures.isEmpty ? "" : L10n.tr(" - \(failures.count.formatted()) failed"))),
                            result: exported > 0 ? .files([folder]) : nil)
            if !failures.isEmpty { failure = Failure(L10n.tr("Some Photos Weren’t Exported"), summary: (failures.count == 1 ? L10n.tr("\(failures.count) photo couldn’t be exported.\n") : L10n.tr("\(failures.count) photos couldn’t be exported.\n")).trimmingCharacters(in: .newlines), items: failures) }
        }
    }

    /// Returns nil when the policy skips a photo whose file already exists.
    static func exportFile(_ asset: CatalogAsset, store: CatalogStore, settings: ExportSettings, profile: RGBProfile? = nil, to folder: URL, existing: ExistingFilePolicy = .rename, suffix: String = "",
                           name: String? = nil, filters: CreativeFilterStack? = nil, denoise: DenoiseRun? = nil) async throws -> URL? {
        let current = try await store.asset(asset.id)
        let source = CatalogImporter.sourceURL(for: current, root: store.root)
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let (renderer, defaults) = try await Task.detached(priority: .userInitiated) { try RawRenderer.open(source, hdr: current.hdr) }.value
        let adjustments = try await store.savedAdjustments(of: current) ?? defaults
        // HDR is kept for a photo developed in HDR; any other goes out in SDR.
        var output = settings
        if output.hdr && !adjustments.hdr.enabled { output.setHDR(false) }
        output.location = ExportGPS(latitude: current.latitude, longitude: current.longitude)
        // An ICC profile chosen for the export (the proof's printer profile) is already in the settings.
        if let profile { if profile != .custom || output.profile.iccData == nil { output.profile = ColorProfile(); output.profile.preset = profile } } else { output.profile = adjustments.colorProfile }
        try output.validate()
        if let name {
            let destination = folder.appendingPathComponent(name)
            try await renderer.export(to: destination, adjustments: adjustments, settings: output, overwriteExisting: true, filters: filters, denoise: denoise)
            return destination
        }
        let base = (current.filename as NSString).deletingPathExtension + suffix
        var destination = folder.appendingPathComponent(base).appendingPathExtension(output.format.fileExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            switch existing {
            case .skip: return nil
            case .overwrite: break
            case .rename:
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(output.format.fileExtension); suffix += 1
                }
            }
        }
        try await renderer.export(to: destination, adjustments: adjustments, settings: output, overwriteExisting: existing == .overwrite, filters: filters, denoise: denoise)
        return destination
    }
}
