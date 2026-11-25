import SwiftUI
import CoreImage
import CevicheCore

/// Finds sensor dust (on the Visualize map when it is on, otherwise with the classic detector), lets the spots be
/// reviewed on the photo, then heals them as retouch strokes.
struct DustSection: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            visualize
            Rule()
            slider(L10n.tr("Sensitivity"), $model.dustSensitivity, 0...1, label: "\(Int((model.dustSensitivity*100).rounded()))%").help(L10n.tr("Higher finds fainter spots, and more false ones"))
            if !model.dustVisualize {
                slider(L10n.tr("Spot size"), $model.dustSpotSize, 2...20, label: "\(Int(model.dustSpotSize.rounded())) px").help(L10n.tr("Expected dust radius on a 4000-pixel-wide frame"))
                Toggle(L10n.tr("Night sky or high ISO"), isOn: $model.dustNightSky).toggleStyle(.formCheckbox)
                    .help(L10n.tr("Smooths noise first and lets a dark sky be searched as a whole"))
            }
            HStack(spacing: 8) {
                Button(action: model.findDust) {
                    Label(model.dustSpots.isEmpty ? L10n.tr("Find Dust") : L10n.tr("Find Again"), systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
                }.buttonStyle(ActionButtonStyle(role: model.dustSpots.isEmpty ? .primary : .secondary))
                    .disabled(model.dustWorking)
                    .help(model.dustVisualize ? L10n.tr("Searches the map for spots on bright, clear areas, at every size") : L10n.tr("Finds small dark spots that stand apart from their surroundings. Fast; tune it to the photo."))
                if model.dustWorking { Button(L10n.tr("Cancel"), action: model.cancelDust).buttonStyle(.secondaryAction) }
            }
            if model.dustWorking { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            if let report = model.dustReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !model.dustSpots.isEmpty { Rule(); found }
        }
    }
    /// Visualize Spots: the photo as a map of what is darker than its surroundings, and how it is made.
    @ViewBuilder private var visualize: some View {
        Toggle(L10n.tr("Visualize"), isOn: $model.dustVisualize).toggleStyle(.formCheckbox)
            .help(L10n.tr("Shows dust as white dots on black (A); Find Dust then searches the map"))
        if model.dustVisualize {
            let options = $model.dustVisualOptions
            slider(L10n.tr("Strength"), options.strength, 0...1, label: "\(Int((model.dustVisualOptions.strength*100).rounded()))%")
                .help(L10n.tr("Brings out fainter spots, and more noise"))
            slider(L10n.tr("Max size"), options.size, 10...200, label: "\(Int(model.dustVisualOptions.size.rounded())) px")
                .help(L10n.tr("Largest spot radius shown whole on a 4000-pixel frame; larger ones show only their edge"))
            slider(L10n.tr("Smoothing"), options.smoothing, 0...12, label: String(format: "%.1f px", locale: Locale.current, model.dustVisualOptions.smoothing))
                .help(L10n.tr("Hides noise, and the smallest spots"))
        }
    }
    private func header(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold))
            Text(L10n.tr("\(count)")).monospacedDigit().foregroundStyle(.secondary)
        }
    }
    /// Spots the finder found, not yet part of the edit.
    @ViewBuilder private var found: some View {
        header(L10n.tr("FOUND"), model.dustSpots.count)
            .help(L10n.tr("Shift-click or drag a box to select several; Delete removes them. Drag a circle to move it, its edge to resize it; click to add one."))
        HStack(spacing: 8) {
            Button(L10n.tr("Dodge/Burn")) { model.repairDustSpots(tonal: true) }.fixedSize().buttonStyle(.secondaryAction).disabled(model.dustWorking)
                .help(L10n.tr("Meter the spot against its surroundings."))
            Button(action: model.healDustSpots) { Text(L10n.tr("Heal")).frame(maxWidth: .infinity) }.buttonStyle(.primaryAction)
                .disabled(model.dustWorking)
                .help(L10n.tr("Adds a heal stroke for each spot, sampling a matching clean area nearby"))
            Button(L10n.tr("Clear"), action: model.clearDustSpots).fixedSize().buttonStyle(.secondaryAction).disabled(model.dustWorking)
        }
    }
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, label: String) -> some View {
        VStack(spacing: 5) { HStack { Text(title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }; FormSlider(value: value, in: range) }
    }
}

extension EditorModel {
    var selectedDustSpot: DustSpot? { selectedRetouchID.flatMap { id in (dustSpots + healedDustHandles).first { $0.id == id } } }
    func isHealedDust(_ id: UUID) -> Bool { adjustments.retouch.contains { $0.id == id && $0.suggested } }
    func resetDust() { dustTask?.cancel(); dustTask = nil; dustSpots = []; selectedRetouchIDs = []; dustReport = nil; dustWorking = false }
    /// Replaces the spots under review with what the finder sees: on the map while Visualize is on (every size, bright
    /// clear areas), otherwise the classic detector with Spot size and Night sky.
    func findDust() {
        guard let renderer, !busy, !dustWorking else { return }
        let settings = adjustments
        let options = dustVisualize ? DustFinder.Options(sensitivity: dustSensitivity, onMap: true)
            : DustFinder.Options(spotSize: dustSpotSize, sensitivity: dustSensitivity, nightSky: dustNightSky)
        dustWorking = true; dustReport = nil
        dustTask = Task {
            defer { if self.renderer === renderer { dustWorking = false } }
            do {
                let spots = try await renderer.findDust(settings, options: options)
                guard self.renderer === renderer, !Task.isCancelled else { return }
                selectedRetouchIDs.subtract(dustSpots.map(\.id)); dustSpots = spots
                dustReport = spots.isEmpty ? L10n.tr("No dust spots found.") : nil
            } catch is CancellationError {
            } catch { if self.renderer === renderer { self.error = error.localizedDescription } }
        }
    }
    func cancelDust() { dustTask?.cancel() }

    /// Remakes the Visualize maps for the preview and the detail on screen; a newer request supersedes this one.
    func refreshDustMaps() {
        dustMapTask?.cancel(); dustMapTask = nil
        guard dustVisualize else { dustPreviewMap = nil; dustDetailMap = nil; return }
        let preview = preview, detail = detail.map { ($0.image, $0.region) }, options = dustVisualOptions
        dustMapTask = Task {
            let maps = await Task.detached(priority: .userInitiated) {
                let context = DustMapContext.shared
                // Both are measured against the whole photo, so a spot reads the same zoomed in or out.
                let whole = preview.flatMap { DustVisualizer.render($0, photoSize: Double(max($0.width, $0.height)), options: options, context: context) }
                let part = detail.flatMap { image, region in
                    let size = max(Double(image.width) / max(0.0001, region.width), Double(image.height) / max(0.0001, region.height))
                    return DustVisualizer.render(image, photoSize: size, options: options, context: context)
                }
                return (whole, part)
            }.value
            guard !Task.isCancelled else { return }
            dustPreviewMap = zip(preview, maps.0); dustDetailMap = zip(detail?.0, maps.1)
        }
    }
    /// A spot placed by hand, sized like the selected one (or the last one found).
    func addDustSpot(at center: MaskPoint) {
        let radius = selectedDustSpot?.radius ?? dustSpots.last?.radius ?? 0.008
        let spot = DustSpot(center: center, radius: radius)
        dustSpots.append(spot); selectedRetouchID = spot.id
    }
    /// Moves or resizes a found spot, or a healed one's stroke (inside the drag's gesture, so one undo step).
    func updateDustSpot(_ id: UUID, center: MaskPoint? = nil, radius: Double? = nil) {
        if isHealedDust(id) {
            updateRetouch(id) { $0.moveDustSpot(to: center, radius: radius) }
            return
        }
        guard let index = dustSpots.firstIndex(where: { $0.id == id }) else { return }
        dustSpots[index].move(to: center, radius: radius)
    }
    var healedDustCount: Int { adjustments.retouch.lazy.filter(\.suggested).count }
    /// Healed dust as handles on the photo, each with its heal stroke's id, while Healed is shown.
    var healedDustHandles: [DustSpot] {
        guard dustShowHealed else { return [] }
        return adjustments.retouch.compactMap { stroke in
            guard stroke.suggested, let center = stroke.points.first else { return nil }
            var spot = DustSpot(center: center, radius: stroke.radius); spot.id = stroke.id
            return spot
        }
    }
    func clearDustSpots() { selectedRetouchIDs.subtract(dustSpots.map(\.id)); dustSpots = []; dustReport = nil }
    /// Turns the found spots into suggested heal strokes in one undoable edit; they join the stroke list as Dust spots.
    func healDustSpots() { repairDustSpots(tonal: false) }
    func repairDustSpots(tonal: Bool) {
        guard let renderer, !busy, !dustWorking else { return }
        let room = adjustments.retouchRoom
        guard room > 0 else { dustReport = L10n.tr("The retouch list already holds \(DustFinder.strokeLimit) strokes."); return }
        let (spots, skipped) = DustRepair.batch(dustSpots, room: room)
        guard !spots.isEmpty else { return }
        let settings = adjustments
        dustWorking = true; dustReport = nil
        dustTask = Task {
            defer { if self.renderer === renderer { dustWorking = false } }
            do {
                let strokes = try await renderer.dustStrokes(spots, settings: settings, tonal: tonal)
                guard self.renderer === renderer, !Task.isCancelled else { return }
                // Strokes added meanwhile take room first; spots removed meanwhile stay removed.
                let added = DustRepair.accepted(spots, strokes: strokes, current: dustSpots, room: adjustments.retouchRoom)
                edit { $0.retouch += added.map(\.stroke) }
                let healed = Set(added.map(\.spot.id))
                dustSpots.removeAll { healed.contains($0.id) }; selectedRetouchIDs.subtract(healed)
                // The stroke list says how many; only what was left out needs saying.
                dustReport = skipped > 0 ? L10n.tr(" \(skipped) did not fit in the retouch list.").trimmingCharacters(in: .whitespaces) : nil
            } catch is CancellationError {
            } catch { if self.renderer === renderer { self.error = error.localizedDescription } }
        }
    }
}

/// One Core Image context for the Visualize maps, kept for the session.
private enum DustMapContext {
    static let shared = CIContext(options: [.cacheIntermediates: false])
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? { if let a, let b { (a, b) } else { nil } }

