import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Opening, saving, exporting and printing the open photo, and its XMP sidecar.
extension EditorModel {
    /// Everything that belongs to the photo being left, in the model and, through `documentID`, in the tool panels.
    /// Called on closing and when another photo takes this one's place.
    private func leavePhoto() {
        documentID = UUID()
        selectionTask?.cancel(); selectionTask = nil; isSelecting = false
        selectedMaskID = nil; adjustmentTargetID = nil; selectedComponentID = nil; pendingMaskOperation = nil; pendingMaskParentID = nil
        maskTool = nil; maskOverlay = nil; partPreviews = []; portraitFaces = []; selectedFaceID = nil; showingFramings = false; touchingUp = false; groupPlacements = [:]; hoveredFaceID = nil
    }

    func closeDocument() {
        catalogAssetID = nil; developmentStore = nil; xmpSourceData = nil; xmpMetadata = nil; xmpReport = nil; history = []; snapshots = []; lastThumbnailJPEG = nil
        clearLiveThumbnail()
        eyedropper = nil; lookPreviewTask?.cancel(); lookPreview = nil; lookNotes = nil; appliedPreset = nil; appliedLooks = [:]
        renderTask?.cancel(); autosaveTask?.cancel(); generation += 1
        leavePhoto(); embeddedSkyAvailable = false
        renderer = nil; info = nil; sourceURL = nil
        invalidateFilmPreviews(); filmProofs = FilmProofs()
        lookThumbnailTask?.cancel(); lookThumbnailQueue = []; lookThumbnails = [:]; lookThumbnailUse = []
        renderedGeometry = nil; cropStraightening = false; selectedGuideID = nil; guideMessage = nil
        cancelHeldViewKeys(); preview = nil; originalPreview = nil; originalRotation = 0; originalColorProfile = nil; comparing = false; comparisonSplit = 0.5; thumbnail = nil; histogram = []; luminanceHistogram = []; scopeSource = nil; scopeDisplays = [:]; detail = nil; detailTask?.cancel(); detailRequest = nil; detailVisible = nil
        originalGeometry = GeometryAdjustments(); guideDraft = nil; cropDrawingGuide = false; cropPlacingCorners = false; cornerDraft = nil; selectedRetouchID = nil
        resetDust(); redEyeReport = nil; resetBlemishSearch(); resetFills()
        adjustments = Adjustments(); savedAdjustments = nil; dirty = false; viewport.fit()
        undoStack = []; redoStack = []; gestureStart = nil; histogramDrag = nil; isRendering = false
    }
    /// Opens a catalog photo, or with neither argument a photo whose edits are not saved.
    @discardableResult
    func open(_ url: URL, catalog: CatalogStore? = nil, asset: CatalogAsset? = nil) async -> Bool {
        if let catalog, let asset {
            // Only when another photo is coming up: reopening the same one keeps its own preview on screen.
            if asset.id != catalogAssetID, asset.thumbnailKey != nil, let data = try? await catalog.previews.data(assetID: asset.id) { openingImage = NSImage(data: data) }
            defer { openingImage = nil }
            return await open(url, store: CatalogDevelopmentStore(store: catalog, asset: asset), hdr: asset.hdr)
        }
        return await open(url, store: nil)
    }
    @discardableResult
    /// `hdr` is the catalog's record of whether the photo opens in HDR; nil looks at the file.
    func open(_ url: URL, store: DevelopmentStore?, hdr: Bool? = nil) async -> Bool {
        autosaveTask?.cancel(); renderTask?.cancel(); generation += 1
        lookPreviewTask?.cancel(); lookPreview = nil; lookNotes = nil; appliedPreset = nil; appliedLooks = [:]
        invalidateFilmPreviews(); filmProofs = FilmProofs(); watchMemoryPressure()
        lookThumbnailTask?.cancel(); lookThumbnailQueue = []; lookThumbnails = [:]; lookThumbnailUse = []
        isLoading = true
        defer { isLoading = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let readOnly = store == nil && url.pathExtension.lowercased() == "xmp"
            let load = try await store?.prepareLoad() ?? .readOnly(packet: readOnly ? url : nil)
            let loaded = try await Task.detached(priority: .userInitiated) {
                // An XMP file opened on its own develops the original beside it.
                let imageURL = readOnly ? try XMPPacket(url: url).originalURL(beside: url) : url
                try load.verify(imageURL)
                let decoded = try RawRenderer.open(imageURL, hdr: hdr)
                let development = try load.resolve(imageURL, decoded.1, decoded.0.info)
                return (decoded.0, development.adjustments, development.xmpSource, development.metadata, development.warnings)
            }.value
            // Prepare before replacing the active document so a failed open preserves current work.
            var initialSettings = loaded.1
            if toolTab == .crop { initialSettings.geometry.crop = .full }
            let initial = try await loaded.0.preview(initialSettings, sdr: sdrPreview)
            var originalSettings = loaded.0.info.defaults; originalSettings.quarterTurns = loaded.1.quarterTurns; originalSettings.colorProfile = loaded.1.colorProfile; originalSettings.geometry = initialSettings.geometry; originalSettings.hdr = loaded.1.hdr
            let original = try await loaded.0.preview(originalSettings, sdr: sdrPreview)
            originalRotation = loaded.1.quarterTurns; originalColorProfile = loaded.1.colorProfile; originalGeometry = initialSettings.geometry; originalHDR = loaded.1.hdr; originalSDRPreview = sdrPreview
            // Read before the new renderer is installed: a suspension between it and its adjustments could let an old render land.
            let embeddedSky = await loaded.0.hasEmbeddedSkyMatte
            // A photo of the same size and shape keeps the zoom and position, so flipping between frames compares the same detail.
            let keepsViewport = toolTab != .crop && info.map { $0.width == loaded.0.info.width && $0.height == loaded.0.info.height } == true
                && preview.map { $0.width == initial.image.width && $0.height == initial.image.height } == true
            guideDraft = nil; cropDrawingGuide = false; cropPlacingCorners = false; cornerDraft = nil; selectedRetouchID = nil; resetDust(); redEyeReport = nil; resetBlemishSearch(); resetFills()
            renderer = loaded.0; sourceURL = loaded.0.sourceURL; info = loaded.0.info; gpuName = loaded.0.gpuName
            embeddedSkyAvailable = embeddedSky
            leavePhoto()
            renderedGeometry = try? GeometryPlan(size: CGSize(width: loaded.0.info.width, height: loaded.0.info.height), settings: initialSettings.geometry, quarterTurns: initialSettings.quarterTurns)
            // The previous photo's tile would otherwise count as covering the view and be drawn over this one.
            detail = nil; detailTask?.cancel(); detailRequest = nil
            adjustments = loaded.1; preview = initial.image; originalPreview = original.image
            histogram = initial.histogram; luminanceHistogram = initial.luminance; scopeSource = initial.scopeSource; thumbnail = NSImage(data: initial.thumbnail)
            clearLiveThumbnail()
            developmentStore = store; catalogAssetID = store?.assetID; history = []; snapshots = []
            if toolTab == .history { refreshHistory() }
            xmpSourceData = loaded.2; xmpMetadata = loaded.3
            xmpReport = loaded.4.isEmpty ? nil : loaded.4
            savedAdjustments = adjustments; dirty = false; savedAt = nil; isRendering = false
            undoStack = []; redoStack = []; gestureStart = nil; histogramDrag = nil; comparing = false; comparisonSplit = 0.5
            // Crop left open across photos: Escape goes back to how this one came.
            if toolTab == .crop { markCropEntry() }
            if !keepsViewport { viewport.fit() }
            // The opening preview is the photo itself: under a proof it is rendered again as the print.
            if proof.on { proof.coverage = nil; scheduleRender(after: .zero) }
            // The canvas reports the same region when the new photo fits the same way, so settle on its tile from here.
            if let visible = detailVisible { requestDetail(visible, settle: Self.detailSettleAfterEdit) }
            if adjustments.geometry.needsUprightAnalysis { analyzeUpright() }
            // Fills left out of XMP or a pasted edit are made again.
            scheduleFills()
            if let catalog = store as? CatalogDevelopmentStore {
                let asset = catalog.asset
                // Crop mode displays the uncropped canvas; the library must show the saved crop.
                // The document is already open: a thumbnail failure must not report the open as failed.
                do {
                    let catalogThumbnail = initialSettings == loaded.1 ? initial.thumbnail : try await loaded.0.preview(loaded.1).thumbnail
                    try await catalog.store.installThumbnail(catalogThumbnail, assetID: asset.id, renderKey: asset.renderKey)
                } catch { self.error = L10n.tr("Photo opened, but its library thumbnail could not be refreshed: \(error.localizedDescription)") }
            }
            isLoading = false
            prewarmFilmPreviews(after: .milliseconds(600))
            return true
        } catch {
            lastOpenError = error; isRendering = false
            // A catalog photo whose edits can't be read: the catalog says so itself, offering Reset Edits.
            if !(store is CatalogDevelopmentStore && Self.recoverableEdits(error) != nil) { failure = Failure(L10n.tr("Couldn’t Open the Photo"), error) }
            if renderer != nil { changed() } // Resume the active document after a failed open.
            return false
        }
    }
    /// A catalog photo's saved edits that can't be read, or that use a LUT or profile no longer in the library: the
    /// parts Reset Unreadable would take out (empty when it can't tell); nil for any other failure.
    nonisolated static func recoverableEdits(_ error: Error?) -> [String]? {
        if case .unreadableEdits(_, let parts)? = error as? EditorError { return parts }
        if let missing = error as? ResourceUnavailable, !missing.downloading { return [] }
        return nil
    }
    func chooseXMPImport() {
        guard hasImage, !busy else { return }
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(types: [.xmp],
                message: L10n.tr("Apply XMP settings to the current photo. Missing fields retain current values."))) else { return }
            await importXMP(from: url)
        }
    }
    func importXMP(from url: URL) async {
        guard hasImage, !busy, let info else { return }
        endGesture(); autosaveTask?.cancel(); isLoading = true
        defer { isLoading = false; if dirty { scheduleAutosave() } }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let base = adjustments
            let metadata: CatalogMetadata
            if let catalogStore, let catalogAssetID { metadata = try await catalogStore.asset(catalogAssetID).metadata }
            else { metadata = xmpMetadata ?? CatalogMetadata() }
            let imported = try await Task.detached {
                try XMPCodec.apply(XMPPacket(url: url), to: base, metadata: metadata, defaults: info.defaults, profiles: info.profileResolver)
            }.value
            if let catalogStore, let catalogAssetID {
                // Persist current edits before the import so history can restore them.
                _ = try await catalogStore.saveEdits(base, assetID: catalogAssetID, baseline: info.defaults)
                try await catalogStore.importXMP(imported, assetID: catalogAssetID, baseline: base)
                savedAdjustments = imported.adjustments
            }
            edit { $0 = imported.adjustments }
            xmpSourceData = imported.sourceData; xmpMetadata = imported.metadata
            dirty = adjustments != savedAdjustments
            if let catalogStore, let catalogAssetID, let renderer {
                let current = try await catalogStore.asset(catalogAssetID)
                Task {
                    do {
                        let rendered = try await renderer.preview(imported.adjustments)
                        try await catalogStore.installThumbnail(rendered.thumbnail, assetID: catalogAssetID, renderKey: current.renderKey)
                    } catch { self.error = L10n.tr("XMP saved, but thumbnail refresh failed: \(error.localizedDescription)") }
                }
            }
            xmpReport = imported.warnings.isEmpty ? XMPCodec.importedNotice : imported.warnings.joined(separator: "\n\n")
        } catch { self.failure = Failure(L10n.tr("Couldn’t Import XMP"), error) }
    }
    func chooseXMPExport() {
        guard hasImage, !busy, let sourceURL else { return }
        Task {
            guard let url = await FileChooser.save(FileSaveRequest(name: sourceURL.deletingPathExtension().lastPathComponent + ".ceviche.xmp", types: [.xmp],
                message: L10n.tr("Export settings and metadata as an XMP sidecar."))) else { return }
            await exportXMP(to: url)
        }
    }
    func exportXMP(to url: URL) async {
        guard hasImage, !busy, let sourceURL, let info else { return }
        isExporting = true; defer { isExporting = false }
        do {
            var metadata = xmpMetadata, source = xmpSourceData
            if let catalogStore, let catalogAssetID {
                let asset = try await catalogStore.asset(catalogAssetID)
                metadata = asset.metadata; source = try await catalogStore.development(catalogAssetID).xmpData
            }
            let settings = adjustments, exportMetadata = metadata, sourceData = source
            try await Task.detached {
                let data = try XMPCodec.encode(adjustments: settings, metadata: exportMetadata, defaults: info.defaults, sourceData: sourceData, filename: sourceURL.lastPathComponent)
                try XMPCodec.write(data, to: url, protecting: sourceURL)
            }.value
            xmpReport = XMPCodec.exportNotice
        } catch { self.failure = Failure(L10n.tr("Couldn’t Export XMP"), error) }
    }
    /// Writes the edits to the photo's catalog entry or sidecar. A photo opened without a store (tests, a path on the
    /// command line) has nowhere to save, nor does one whose sidecar folder is read-only (`saveCopy` then).
    @discardableResult
    func save(coalescing: Bool = false) async -> Bool {
        guard let renderer, !isSaving, !isLoading, let developmentStore, developmentStore.canSave else { return false }
        autosaveTask?.cancel()
        let settings = adjustments
        isSaving = true
        do {
            let key = try await developmentStore.save(settings, baseline: renderer.info.defaults, metadata: xmpMetadata, coalescing: coalescing)
            savedAdjustments = settings; dirty = adjustments != settings; savedAt = Date(); isSaving = false
            if let key, let catalogStore, let catalogAssetID { Task {
                do {
                    let rendered = try await renderer.preview(settings)
                    try await catalogStore.installThumbnail(rendered.thumbnail, assetID: catalogAssetID, renderKey: key)
                    if toolTab == .history { refreshHistory() }
                } catch { self.error = L10n.tr("Edits saved, but thumbnail refresh failed: \(error.localizedDescription)") }
            } }
            if dirty { scheduleAutosave() }
            return true
        } catch {
            // A folder that turned read-only isn't an error to show: the edits stay unsaved and the window asks where.
            if developmentStore.canSave { self.failure = Failure(L10n.tr("Couldn’t Save Edits"), error) }
            isSaving = false; return false
        }
    }
    /// Saves a copy of the photo, with its sidecars and these edits, at `destination`, and keeps editing the copy.
    /// For a photo whose folder can't be written.
    @discardableResult
    func saveCopy(to destination: URL) async -> Bool {
        guard let renderer, !isSaving, !isLoading, let store = developmentStore as? SidecarDevelopmentStore else { return false }
        autosaveTask?.cancel()
        let settings = adjustments
        isSaving = true
        do {
            try await store.saveCopy(to: destination, settings, baseline: renderer.info.defaults, metadata: xmpMetadata)
            sourceURL = destination
            savedAdjustments = settings; dirty = adjustments != settings; savedAt = Date(); isSaving = false
            if dirty { scheduleAutosave() }
            return true
        } catch { self.failure = Failure(L10n.tr("Couldn’t Save a Copy"), error); isSaving = false; return false }
    }
    /// The dialog opens with the last export's format and settings, in this photo's profile and size, and in HDR
    /// whenever the photo is edited in HDR (every format can hold it: PQ, HLG or a gain map).
    func prepareExport(format: ExportFormat? = nil) {
        if let last = ExportSettings.lastUsed(preferences) { exportSettings = last }
        if let format { exportSettings.select(format) }
        exportSettings.setHDR(adjustments.hdr.enabled)
        exportSettings.profile = adjustments.colorProfile
        // A preset's size cap or frame belongs to that preset, not to the dialog's Original size.
        exportSettings.sizing.longEdge = nil; exportSettings.sizing.frame = nil
        if let size = outputSize {
            exportSettings.sizing.updateSource(size)
        }
        showExport = true
    }
    func share() {
        guard !busy, let renderer, let info else { return }
        let edits = adjustments
        let filename = (info.filename as NSString).deletingPathExtension + "-edited.heic"
        let store = catalogStore, assetID = catalogAssetID
        PhotoShare.export(reportError: { [weak self] in self?.error = $0 }) { folder in
            let url = folder.appendingPathComponent(filename)
            var shared = PhotoShare.settings; shared.location = await EditorModel.exportLocation(store: store, assetID: assetID)
            try await renderer.export(to: url, adjustments: edits, settings: shared)
            return [url]
        }
    }

    /// One click: the preset's settings, then straight to the save panel.
    func export(preset: ExportPreset) {
        guard hasImage, !busy else { return }
        exportSettings = preset.settings(developmentProfile: adjustments.colorProfile)
        if let size = outputSize { exportSettings.sizing.updateSource(size) }
        performExport()
    }
    func makeExportPreview() async throws -> CGImage? {
        guard let renderer else { return nil }
        return try await renderer.exportPreview(adjustments, settings: exportSettings)
    }
    /// The file name an export is offered under.
    var exportFilename: String? { info.map { ($0.filename as NSString).deletingPathExtension + "-edited." + exportSettings.format.fileExtension } }
    private func validatedExportDimensions() -> ExportDimensions? {
        do {
            try exportSettings.validate()
            guard let sourceSize = outputSize else { return nil }
            return try exportSettings.dimensions(for: sourceSize)
        } catch { self.failure = Failure(L10n.tr("Couldn’t Export"), error); return nil }
    }
    func performExport() {
        guard hasImage, !busy, let filename = exportFilename, let dimensions = validatedExportDimensions() else { return }
        let options = exportSettings
        Task {
            guard let url = await FileChooser.save(FileSaveRequest(name: filename, types: [UTType(options.format.typeIdentifier) ?? .image],
                message: L10n.tr("\(dimensions.label) - \(options.depth)-bit RGB - \(options.profileLabel)"))) else { return }
            showExport = false
            options.rememberAsLastUsed(preferences)
            exportFile(to: url) { NSWorkspace.shared.showInFinder([$0]) }
        }
    }


    private func exportFile(to url: URL, then completion: @escaping @MainActor (URL) -> Void) {
        guard let renderer else { return }
        let options = exportSettings, settings = adjustments, store = catalogStore, assetID = catalogAssetID
        // A job of its own: it renders a snapshot of the edits, so editing and other exports carry on meanwhile.
        ActivityCenter.shared.start(.exporting, title: L10n.tr("Exporting \(url.lastPathComponent)")) { [weak self] job in
            do {
                var output = options; output.location = await EditorModel.exportLocation(store: store, assetID: assetID)
                try await renderer.export(to: url, adjustments: settings, settings: output)
                if !Task.isCancelled {
                    completion(url)
                    ActivityCenter.shared.finish(job, title: L10n.tr("Exported"), outcome: .done(url.lastPathComponent), result: .files([url]))
                }
            } catch is CancellationError {
            } catch {
                self?.failure = Failure(L10n.tr("Couldn’t Export"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }
    /// The open catalog photo's location, for an export to write in place of the original's GPS; nil for a file
    /// opened on its own.
    static func exportLocation(store: CatalogStore?, assetID: String?) async -> ExportGPS? {
        guard let store, let assetID, let asset = try? await store.asset(assetID) else { return nil }
        return ExportGPS(latitude: asset.latitude, longitude: asset.longitude)
    }
    /// Prints the open photo as developed. Under a proof with an RGB printer profile the print can be made in that
    /// profile, converted as the proof shows it.
    func printPhoto() {
        guard hasImage, !busy, let renderer, let info else { return }
        let settings = adjustments, name = (info.filename as NSString).deletingPathExtension
        let proofing = proof.active.flatMap { $0.profile.isRGB ? $0 : nil }
        ActivityCenter.shared.start(.exporting, title: L10n.tr("Preparing \(name) to print")) { [weak self] job in
            do {
                let document = try PhotoPrintDocument()
                try await document.append(renderer: renderer, adjustments: settings, proof: proofing)
                try Task.checkCancellation()
                ActivityCenter.shared.finish(job, outcome: .done(""))
                PhotoPrinting.run(document: document, title: name)
            } catch is CancellationError {
            } catch {
                self?.failure = Failure(L10n.tr("Couldn’t Print"), error)
                ActivityCenter.shared.finish(job, outcome: .failed(error.localizedDescription))
            }
        }
    }
}
