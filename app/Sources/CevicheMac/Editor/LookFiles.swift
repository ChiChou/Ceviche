import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Develop presets, camera profiles and LUTs applied from files, from the Looks tab or Photo › Apply Look File….
/// Presets describe another color pipeline, so their values are an approximation on Apple's RAW rendering.
extension EditorModel {
    func chooseLookFile() {
        guard hasImage, !busy else { return }
        let types = LookKind.allCases.flatMap(\.extensions).sorted().compactMap { UTType(filenameExtension: $0) }
        Task {
            guard let url = await FileChooser.openOne(FileOpenRequest(types: types)), let kind = LookKind(file: url) else { return }
            await applyLook(url, kind: kind)
        }
    }
    /// The development a look would produce on top of the current one, without applying it.
    func lookAdjustments(_ url: URL, kind: LookKind) async throws -> (Adjustments, [String]) {
        guard let info else { throw EditorError.invalidDocument(L10n.tr("No photo is open.")) }
        let base = adjustments, library = lookResources.folder
        return try await Task.detached(priority: .userInitiated) {
            try kind.develop(url, on: base, info: info, library: library)
        }.value
    }
    /// Applies a look as one undo step, and in a catalog as a History step named after it. Notes open the compatibility
    /// report sheet, unless `reportInline` keeps them in the Looks tab so clicking through presets is not interrupted.
    func applyLook(_ url: URL, kind: LookKind, reportInline: Bool = false) async {
        guard hasImage, !busy else { return }
        // A look being previewed stays on screen until the applied one replaces it, so the photo does not flash back.
        endMask(); endGesture(); lookPreviewTask?.cancel()
        let before = adjustments
        do {
            let result = try await lookAdjustments(url, kind: kind)
            let name = url.deletingPathExtension().lastPathComponent
            setAdjustmentTarget(nil)
            if keepsHistory {
                let summary = kind.appliedSummary(name), baseline = info?.defaults
                let applied = await historyStep { store, id in
                    // The baseline gives a photo's first edit its Original step to go back to.
                    try await store.saveEdits(result.0, assetID: id, baseline: baseline, summary: summary, milestone: true)
                    return result.0
                }
                guard applied else { return endLookPreview() }
            } else {
                edit { $0 = result.0 }
            }
            showLookPreview(nil)
            if kind == .presets { appliedPreset = AppliedPreset(name: name, before: before, full: result.0, amount: 1, enabled: true, result: result.0) }
            appliedLooks[kind] = AppliedLookFile(url: url, name: kind == .profiles ? result.0.cameraProfile?.name ?? name : kind == .luts ? result.0.lut?.name ?? name : name)
            let report = XMPCodec.compatibilityReport(result.1.joined(separator: "\n\n"))
            if reportInline { lookNotes = report.map { LookNotes(name: name, report: $0) } }
            else if let report { xmpReport = report }
        } catch { endLookPreview(); self.error = error.localizedDescription }
    }
    /// Shows a look on the photo while the pointer rests on it in the Looks tab, or the photo again for nil; nothing is
    /// edited or saved. Waits for the pointer to settle, so passing over a list renders only the row it stops on, and
    /// moving from one row to the next never shows the photo without a look in between.
    func previewLook(_ look: LookFile?) {
        lookPreviewTask?.cancel()
        guard hasImage, !busy else { return endLookPreview() }
        lookPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(look == nil ? 120 : 180))
            guard let self, !Task.isCancelled else { return }
            guard let look else { return showLookPreview(nil) }
            guard let settings = try? await lookAdjustments(look.url, kind: look.kind).0, !Task.isCancelled else { return }
            showLookPreview(settings)
        }
    }
    /// Whether `look` is what the photo shows of its kind: a preset until it is undone, removed or another one applied,
    /// edits on top of it included; a camera profile or LUT while the photo has it.
    func isOnPhoto(_ look: LookFile) -> Bool {
        // The library may list a file through a symbolic link (/var is /private/var); the name is checked first, so other
        // rows never touch the file system.
        guard let applied = appliedLooks[look.kind], applied.url.lastPathComponent == look.url.lastPathComponent,
              applied.url.resolvingSymlinksInPath() == look.url.resolvingSymlinksInPath() else { return false }
        switch look.kind {
        case .presets:
            guard let preset = appliedPreset, preset.name == applied.name else { return false }
            return adjustments != preset.before
        case .profiles: return adjustments.cameraProfile?.name == applied.name
        case .luts: return adjustments.lut?.name == applied.name
        }
    }
    /// The applied preset while the photo is still that preset, at the strength it shows: after an undo back to full
    /// strength too.
    var presetOnPhoto: AppliedPreset? {
        guard var preset = appliedPreset else { return nil }
        if preset.result == adjustments { return preset }
        guard preset.full == adjustments else { return nil }
        preset.amount = 1; preset.enabled = true; preset.result = preset.full
        return preset
    }
    /// The preset's strength, 0…1; a slider drag is one undo step (`AdjustmentSlider` opens the gesture).
    func setPresetAmount(_ amount: Double) {
        guard var preset = presetOnPhoto else { return }
        preset.amount = min(1, max(0, amount)); preset.enabled = true
        show(preset)
    }
    /// Off shows the photo without the preset, keeping its strength for when it is turned on again.
    func setPresetEnabled(_ enabled: Bool) {
        guard var preset = presetOnPhoto else { return }
        preset.enabled = enabled
        show(preset)
    }
    /// The photo as it was before the preset, as one undo step.
    func removePreset() {
        guard let preset = presetOnPhoto else { return }
        appliedPreset = nil
        edit { $0 = preset.before }
    }
    private func show(_ preset: AppliedPreset) {
        var preset = preset
        do {
            preset.result = preset.enabled ? try preset.before.blended(toward: preset.full, amount: preset.amount) : preset.before
        } catch { self.error = error.localizedDescription; return }
        // Recorded first, so the card still matches the photo when the edit lands.
        appliedPreset = preset
        let result = preset.result
        edit { $0 = result }
    }
    /// Photo › Save Preset… and the Looks tab: asks for a name when the photo has edits a preset can carry.
    func requestPresetSave() {
        guard hasImage, !busy else { return }
        endMask(); endGesture()
        guard !DevelopPreset.savedItems(in: adjustments, from: info?.defaults ?? Adjustments()).isEmpty else {
            error = L10n.tr("This photo has no edits to save."); return
        }
        presetName = L10n.tr("Untitled"); namingPreset = true
    }
    /// Saves the photo's edits to `library`'s User Presets, and opens that folder in the Looks tab.
    @discardableResult
    func savePreset(named name: String, in library: LookLibrary) -> Bool {
        guard hasImage else { return false }
        do {
            try DevelopPreset.save(adjustments, baseline: info?.defaults ?? Adjustments(), name: name, in: library)
        } catch { self.error = error.localizedDescription; return false }
        let key = "looksOpenFolders." + LookKind.presets.rawValue
        var open = (UserDefaults.standard.string(forKey: key) ?? "").split(separator: "\n").map(String.init)
        if !open.contains(DevelopPreset.userFolder) { open.append(DevelopPreset.userFolder); UserDefaults.standard.set(open.joined(separator: "\n"), forKey: key) }
        presetSaved()
        return true
    }
    func endLookPreview() {
        lookPreviewTask?.cancel(); lookPreviewTask = nil
        showLookPreview(nil)
    }
}

extension LookLibrary {
    /// The library the Looks tab and MCP show: the catalog of the photo in Develop, else the open catalog's.
    @MainActor static func current(editor: EditorModel?, catalog: CatalogModel?) -> LookLibrary {
        LookLibrary(resources: editor?.catalogStore?.resources ?? catalog?.store?.resources ?? .shared)
    }
}

extension LookKind {
    /// `url`'s look on top of `base` for a photo described by `info`, with notes on what differs from the original.
    func develop(_ url: URL, on base: Adjustments, info: ImageInfo, library: FolderResources?) throws -> (Adjustments, [String]) {
        switch self {
        case .presets:
            return try DevelopPreset.apply(url, to: base, defaults: info.defaults, profiles: info.profileResolver)
        case .profiles:
            var profile = CameraProfileLibrary.shared.separated(try CameraProfile(dcp: url))
            var next = base
            if let current = base.cameraProfile { profile.amount = current.amount }
            next.cameraProfile = profile
            var notes: [String] = []
            if !info.isRAW { notes.append(L10n.tr("Camera profiles apply only to RAW photos.")) }
            // A chart profile is for its light: far from it, it does more harm than good.
            let temperature = base.effective(defaults: info.defaults).temperature
            if let light = profile.calibrationTemperature, !profile.suits(temperature: temperature) {
                notes.append(L10n.tr("‘\(profile.name)’ was made in \(Int((light / 50).rounded()) * 50) K light; this photo is developed at \(Int((temperature / 50).rounded()) * 50) K, where it may do more harm than good."))
            }
            if profile.baseProfile == nil, profile.hasTables {
                notes.append(L10n.tr("No base profile for \(profile.camera.isEmpty ? L10n.key("this profile's camera") : profile.camera), so ‘\(profile.name)’ includes its camera calibration."))
            }
            return (next, notes)
        case .luts:
            var lut = try CreativeLUT(contentsOf: url)
            // A LUT from the library is referenced where it is; one from elsewhere is copied in when saved.
            lut.source = library?.reference(for: url)
            if let current = base.lut { lut.amount = current.amount; lut.space = current.space }
            var next = base; next.lut = lut
            return (next, [])
        }
    }
    /// The History step a look adds.
    func appliedSummary(_ name: String) -> String {
        switch self {
        case .presets: L10n.tr("Applied preset “\(name)”")
        case .profiles: L10n.tr("Applied camera profile “\(name)”")
        case .luts: L10n.tr("Applied LUT “\(name)”")
        }
    }
}

/// A file in the look library, as a row of the Looks tab.
struct LookFile: Hashable {
    let url: URL
    let kind: LookKind
}

/// A preset applied from the Looks tab: the photo before it and with it at full strength, the strength and on/off its
/// card shows, and the development they give, which is what the photo must still be for the card to show.
struct AppliedPreset: Equatable {
    let name: String
    let before: Adjustments
    let full: Adjustments
    var amount: Double
    var enabled: Bool
    var result: Adjustments
}

/// A look file applied to the photo, with the name of what it put there.
struct AppliedLookFile: Equatable {
    let url: URL
    let name: String
}

/// The compatibility notes of the look last applied from the Looks tab.
struct LookNotes: Hashable {
    let name: String
    let report: String
}
