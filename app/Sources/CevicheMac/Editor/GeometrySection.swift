import SwiftUI
import CevicheCore

/// How the photo is squared up: Upright off, analysed or along guides, or four corners on a flat work. The corners
/// are stored apart from Upright's mode and take its place, so the panel offers them as one choice.
private enum PerspectiveMethod: Hashable, CaseIterable {
    case off, auto, guided, corners
    var title: String {
        switch self {
        case .off: UprightMode.off.localizedTitle
        case .auto: UprightMode.auto.localizedTitle
        case .guided: UprightMode.guided.localizedTitle
        case .corners: L10n.tr("Corners")
        }
    }
    var help: String {
        switch self {
        case .off: L10n.tr("No upright correction")
        case .auto: L10n.tr("Level the photo and straighten part of its perspective, keeping it natural")
        case .guided: L10n.tr("Correct along guides drawn on the photo")
        case .corners: L10n.tr("Drag four corners onto an artwork, document or screen photographed at an angle")
        }
    }
}

/// The Perspective section of the Crop tab: one row chooses how the photo is squared up, the rows under it belong
/// to that choice, and the manual transform is folded away below. Its switch bypasses Upright and the sliders together.
struct GeometrySection: View {
    @ObservedObject var model: EditorModel
    @AppStorage("cropGeometryExpanded") private var expanded = true
    @AppStorage("cropTransformExpanded") private var transformExpanded = false
    private var geometry: GeometryAdjustments { model.adjustments.geometry }
    private var method: PerspectiveMethod {
        if geometry.perspective != nil { return .corners }
        switch geometry.uprightMode {
        case .off: return .off
        case .guided: return .guided
        default: return .auto
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DisclosureTitle(title: L10n.tr("Perspective", context: "crop"), expanded: $expanded)
                Spacer()
                if model.uprightAnalyzing || model.detectingCorners { ProgressView().controlSize(.mini).padding(.trailing, 6).accessibilityLabel(L10n.tr("Analyzing the photo")) }
                if method == .auto {
                    Button(L10n.tr("Update")) { model.analyzeUpright(replacing: true) }
                        .buttonStyle(.secondaryAction).controlSize(.small)
                        .disabled(!geometry.uprightEnabled || model.uprightAnalyzing)
                        .help(L10n.tr("Analyze the photo again, for example after rotating it or changing lens correction"))
                }
                Button(action: model.resetTransform) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).padding(.horizontal, 6).help(L10n.tr("Reset Upright, its guides and the manual transform")).accessibilityLabel(L10n.tr("Reset geometry"))
                Toggle(L10n.tr("Apply geometry"), isOn: Binding(get: { geometry.uprightEnabled || geometry.transform.enabled }, set: model.setTransformEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if expanded {
                SegmentRow(options: PerspectiveMethod.allCases, selection: method, title: \.title, help: \.help, choose: choose)
                    .disabled(!geometry.uprightEnabled && geometry.perspective == nil)
                switch method {
                case .off: EmptyView()
                case .auto:
                    SegmentRow(options: [UprightMode.auto, .level, .vertical, .full], selection: geometry.uprightMode, title: \.localizedTitle, help: { Self.help[$0] ?? "" }, choose: model.setUprightMode)
                        .disabled(!geometry.uprightEnabled)
                case .guided: guides.disabled(!geometry.uprightEnabled)
                case .corners: corners
                }
                // While analysing, the spinner in the title row says so; a stored result's own message shows afterwards.
                if let message = model.guideMessage ?? (method == .auto || method == .guided ? (geometry.needsUprightAnalysis ? nil : model.geometryPlan?.uprightMessage) : nil) {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    DisclosureTitle(title: L10n.tr("Transform"), expanded: $transformExpanded)
                    // Folded sliders that are doing something say so.
                    if !transformExpanded, transformEdited { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                    Spacer()
                }.padding(.top, 2)
                if transformExpanded {
                    VStack(spacing: 12) {
                        control(L10n.tr("Vertical"), key: \.vertical)
                        control(L10n.tr("Horizontal"), key: \.horizontal)
                        control(L10n.tr("Rotate"), key: \.rotate, range: -10...10, unit: "°")
                        control(L10n.tr("Aspect"), key: \.aspect)
                        control(L10n.tr("Scale"), key: \.scale, range: 50...150, unit: "%", neutral: 100)
                        control(L10n.tr("Offset X"), key: \.offsetX)
                        control(L10n.tr("Offset Y"), key: \.offsetY)
                    }.disabled(!geometry.transform.enabled)
                }
            }
        }
    }
    private var transformEdited: Bool {
        var neutral = ManualTransform(); neutral.enabled = geometry.transform.enabled
        return geometry.transform != neutral
    }
    private func choose(_ choice: PerspectiveMethod) {
        switch choice {
        case .off: if geometry.perspective != nil { model.removePerspective() } else { model.setUprightMode(.off) }
        case .auto: if method != .auto { model.setUprightMode(.auto) }
        case .guided: model.setUprightMode(.guided)
        case .corners: if geometry.perspective == nil { model.togglePerspectiveCorners() }
        }
    }
    @ViewBuilder private var guides: some View {
        HStack {
            Text(L10n.tr("Guides"))
            Button(L10n.tr("Draw"), action: model.toggleGuideDrawing)
                .buttonStyle(ActionButtonStyle(role: model.cropDrawingGuide ? .primary : .secondary))
                .help(L10n.tr("Draw up to four guides along edges that should be vertical or level"))
            Text(L10n.tr("\(geometry.guides.count) of 4")).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(L10n.tr("Clear"), action: model.clearGuides).buttonStyle(.secondaryAction).disabled(geometry.guides.isEmpty)
        }
        if model.cropDrawingGuide {
            HStack(spacing: 12) {
                Toggle(L10n.tr("Show Loupe"), isOn: $model.showGuideLoupe).help(L10n.tr("Magnify the photo while placing a guide's end"))
                Toggle(L10n.tr("Grid"), isOn: $model.showGuideGrid)
            }.toggleStyle(.formCheckbox)
            Text(L10n.tr("Drag along edges that should be vertical or level; direction is automatic. Drag an endpoint to adjust it; select a guide and press Delete to remove it."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(geometry.guides.enumerated()), id: \.element.id) { index, guide in
            HStack {
                Button { model.selectedGuideID = guide.id; if !model.cropDrawingGuide { model.toggleGuideDrawing() } } label: {
                    Label(L10n.tr("\(index+1) - \(model.displayGuideAxis(guide.axis).localizedTitle)"), systemImage: model.displayGuideAxis(guide.axis) == .vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                }.buttonStyle(.plain).foregroundStyle(model.selectedGuideID == guide.id ? Theme.accent : Color.secondary)
                Spacer()
                Button { model.selectedGuideID = guide.id; model.deleteSelectedGuide() } label: { Image(systemName: "trash") }.buttonStyle(.plain).help(L10n.tr("Delete guide")).accessibilityLabel(L10n.tr("Delete guide \(index+1)"))
            }
        }
    }
    /// The four corners of a work photographed at an angle, and the proportions it is pulled square to.
    @ViewBuilder private var corners: some View {
        if let crop = geometry.perspective {
            HStack {
                Text(L10n.tr("Corners"))
                Button(L10n.tr("Adjust"), action: model.togglePerspectiveCorners)
                    .buttonStyle(ActionButtonStyle(role: model.cropPlacingCorners ? .primary : .secondary))
                Spacer()
                Button(action: model.resetPerspectiveCorners) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).help(L10n.tr("Reset Corners")).accessibilityLabel(L10n.tr("Reset Corners"))
            }
            HStack {
                Text(L10n.tr("Proportions"))
                PanelPicker(title: L10n.tr("Proportions"), selection: Binding(get: { crop.proportion.isCustom ? nil : crop.proportion }, set: chooseProportion),
                            options: PerspectiveProportion.presets.map(Optional.some) + [nil], label: { $0?.title ?? L10n.tr("Custom") }, expands: true)
                    .controlSize(.small)
                    .help(L10n.tr("The work’s own proportions. They can’t be read reliably from the photo, so choose or enter them."))
            }
            if case .custom(let width, let height) = crop.proportion {
                HStack {
                    Spacer()
                    TextField(L10n.tr("Width"), value: Binding(get: { width }, set: { model.setPerspectiveProportion(.custom(width: $0, height: height)) }), format: .number.grouping(.never))
                        .textFieldStyle(.formField).controlSize(.small).frame(width: 64)
                    Text("×").foregroundStyle(.secondary)
                    TextField(L10n.tr("Height"), value: Binding(get: { height }, set: { model.setPerspectiveProportion(.custom(width: width, height: $0)) }), format: .number.grouping(.never))
                        .textFieldStyle(.formField).controlSize(.small).frame(width: 64)
                }
            }
        }
    }
    /// Custom starts from the size the corners measure.
    private func chooseProportion(_ choice: PerspectiveProportion?) {
        if let choice { model.setPerspectiveProportion(choice); return }
        let size = model.info.flatMap { info in geometry.perspective.map { $0.outputSize(source: CGSize(width: info.width, height: info.height)) } }
        model.setPerspectiveProportion(.custom(width: size.map { Double($0.width.rounded()) } ?? 3, height: size.map { Double($0.height.rounded()) } ?? 2))
    }
    private func control(_ title: String, key: WritableKeyPath<ManualTransform, Double>, range: ClosedRange<Double> = -100...100, unit: String = "", neutral: Double = 0) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { model.adjustments.geometry.transform[keyPath: key] }, set: { model.setManualTransform(key, to: $0) }), range: range, unit: unit,
                         editing: { if $0 { model.beginGesture() } else { model.endGesture() } }, reset: { model.setManualTransform(key, to: neutral) })
    }
    private static var help: [UprightMode: String] { [
        .auto: L10n.tr("Level the photo and straighten part of its perspective, keeping it natural"),
        .level: L10n.tr("Level the horizon or verticals by rotation only"),
        .vertical: L10n.tr("Level and make vertical lines plumb"), .full: L10n.tr("Level and make vertical and horizontal lines straight")] }
}

/// The Volume section of the Crop tab: undoes a wide-angle lens's stretch across the whole photo, before Perspective.
struct VolumeSection: View {
    @ObservedObject var model: EditorModel
    @AppStorage("cropVolumeExpanded") private var expanded = true
    private var volume: VolumeCorrection { model.adjustments.geometry.volume }
    /// The focal length the projection uses: set on the photo, else its EXIF.
    private var focal: Double? { volume.focalLength ?? model.info?.focalLength35mm }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DisclosureTitle(title: L10n.tr("Volume"), expanded: $expanded)
                // Folded and doing something says so.
                if !expanded, volume.isActive { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                Spacer()
                Button(action: model.resetVolume) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).padding(.horizontal, 6).help(L10n.tr("Reset Volume")).accessibilityLabel(L10n.tr("Reset Volume"))
            }
            if expanded {
                SegmentRow(options: VolumeMode.allCases, selection: volume.mode, title: \.localizedTitle, help: { Self.help[$0] ?? "" },
                           choose: { mode in model.setVolume { $0.mode = mode } })
                    .accessibilityLabel(L10n.tr("Volume mode"))
                AdjustmentSlider(title: L10n.tr("Amount"), value: Binding(get: { volume.amount }, set: { value in model.setVolume { $0.amount = value } }), range: 0...100, unit: "%",
                                 editing: model.adjustingVolume, reset: { model.setVolume { $0.amount = 0 } })
                    .disabled(focal == nil)
                HStack {
                    Text(L10n.tr("Focal Length")).foregroundStyle(.secondary)
                    Spacer()
                    TextField(L10n.tr("Focal Length"), value: Binding(get: { focal }, set: { value in
                        guard let value, VolumeCorrection.focalRange.contains(value) else { return }
                        model.setVolume { $0.focalLength = value }
                    }), format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.formField).controlSize(.small).multilineTextAlignment(.trailing).frame(width: 52)
                        .help(L10n.tr("35 mm equivalent, from the photo's EXIF; change it for a photo cropped from a wider frame"))
                    Text(L10n.tr("mm")).foregroundStyle(.secondary)
                }
                if focal == nil {
                    Text(L10n.tr("No focal length in the EXIF. Enter the lens's 35 mm equivalent."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private static var help: [VolumeMode: String] { [
        .horizontal: L10n.tr("Undo the stretch at the sides; verticals stay straight"),
        .vertical: L10n.tr("Undo the stretch at the top and bottom; horizontals stay straight"),
        .spherical: L10n.tr("Undo the stretch everywhere, corners too; lines away from the center bend")] }
}

/// A section title that folds what is under it.
private struct DisclosureTitle: View {
    let title: String
    @Binding var expanded: Bool
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(expanded ? 0 : -90))
                Text(title).font(.subheadline.weight(.medium))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded ? L10n.tr("Expanded") : L10n.tr("Collapsed"))
    }
}

/// One row of choices drawn as segments. Upright's analysed modes sit in a second row under the method they belong
/// to, so the rows are drawn alike by hand.
private struct SegmentRow<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    let help: (Value) -> String
    let choose: (Value) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { choose(option) } label: {
                    Text(title(option)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(option == selection ? Color.primary.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                    .help(help(option))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("Upright mode"))
    }
}

extension EditorModel {
    /// Changes Volume. The photo's EXIF focal length is taken on the first change; a crop that followed the photo
    /// follows it from where the drag began.
    func setVolume(_ update: (inout VolumeCorrection) -> Void) {
        var candidate = adjustments.geometry
        update(&candidate.volume)
        if candidate.volume.focalLength == nil { candidate.volume.focalLength = info?.focalLength35mm }
        candidate.crop = geometryGestureStart?.geometry.crop ?? candidate.crop
        if apply(candidate) { guideMessage = nil }
    }
    func resetVolume() {
        var candidate = adjustments.geometry; candidate.volume = VolumeCorrection()
        if apply(candidate) { guideMessage = nil }
    }
    /// While Amount is dragged the canvas shows a grid, to judge how lines bend against it.
    func adjustingVolume(_ active: Bool) {
        volumeAdjusting = active
        if active { beginGesture() } else { endGesture() }
    }
    /// The panel's switch bypasses Upright and the manual transform together, keeping their values.
    func setTransformEnabled(_ enabled: Bool) {
        if !enabled, cropDrawingGuide { cropDrawingGuide = false; guideDraft = nil }
        var candidate = adjustments.geometry
        candidate.uprightEnabled = enabled; candidate.transform.enabled = enabled
        apply(candidate)
    }
    /// Chooses an Upright mode. Guided picks up the guide tool; an analysed mode analyses the photo first if it has
    /// not been analysed yet.
    func setUprightMode(_ mode: UprightMode) {
        guideMessage = nil
        if mode != .guided, cropDrawingGuide { cropDrawingGuide = false; guideDraft = nil }
        var candidate = adjustments.geometry
        candidate.uprightMode = mode; candidate.uprightEnabled = true
        // Upright and a perspective crop both square the photo up: choosing one lets go of the other.
        if mode != .off, candidate.perspective != nil { candidate.perspective = nil; candidate.crop = .full; cropPlacingCorners = false; cornerDraft = nil }
        guard apply(candidate) else { return }
        if mode == .guided, !cropDrawingGuide { toggleGuideDrawing() }
        if candidate.needsUprightAnalysis { analyzeUpright() }
    }
    /// Analyses the photo as displayed, without its crop, straightening, transform or upright, and stores the
    /// correction for every analysed mode. The first analysis fills in silently, as part of choosing the mode;
    /// `replacing` (Update) is its own undo step. One analysis runs at a time; a photo opened meanwhile that needs
    /// one is analysed once this run ends.
    func analyzeUpright(replacing: Bool = false) {
        guard let renderer, let info, !uprightAnalyzing else { return }
        uprightAnalyzing = true; guideMessage = nil
        let snapshot = adjustments
        Task {
            defer {
                uprightAnalyzing = false
                if self.renderer !== renderer, adjustments.geometry.needsUprightAnalysis { analyzeUpright() }
            }
            do {
                var settings = snapshot
                settings.geometry = GeometryAdjustments()
                settings.geometry.flipHorizontal = snapshot.geometry.flipHorizontal
                settings.geometry.flipVertical = snapshot.geometry.flipVertical
                let result = try await renderer.preview(settings, sdr: true)
                let focal = UprightAnalyzer.focal(equivalent35mm: info.focalLength35mm, focalLength: info.focalLength, make: info.make, model: info.camera)
                let size = CGSize(width: info.width, height: info.height)
                let analysis = await Task.detached(priority: .userInitiated) {
                    UprightAnalyzer.analyze(result.image, focal: focal, sourceSize: size, quarterTurns: settings.quarterTurns,
                                            flipHorizontal: settings.geometry.flipHorizontal, flipVertical: settings.geometry.flipVertical)
                }.value
                guard self.renderer === renderer else { return }
                guard let analysis else { guideMessage = L10n.tr("The photo could not be analyzed."); return }
                storeUprightAnalysis(analysis, replacing: replacing)
                if analysis.empty { guideMessage = L10n.tr("No clear vertical or level edges were found. Draw guides instead.") }
            } catch { if self.renderer === renderer { guideMessage = error.localizedDescription } }
        }
    }
    private func storeUprightAnalysis(_ analysis: UprightAnalysis, replacing: Bool) {
        var candidate = adjustments.geometry
        candidate.uprightAnalysis = analysis
        if replacing, adjustments.geometry.uprightAnalysis != nil { apply(candidate); return }
        // The first analysis describes the photo, not an edit: every state of this photo gets it, so undoing the
        // mode change and choosing it again needs no new analysis.
        guard let info, (try? GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: candidate, quarterTurns: adjustments.quarterTurns)) != nil else {
            guideMessage = L10n.tr("The analysed correction is too extreme for this photo."); return
        }
        editSilently { if $0.geometry.uprightAnalysis == nil { $0.geometry.uprightAnalysis = analysis } }
    }
    /// Applies a geometry change once the plan and Constrain Crop accept it; the panel shows why otherwise.
    @discardableResult
    func apply(_ candidate: GeometryAdjustments) -> Bool {
        guard let info else { return false }
        var candidate = candidate
        do {
            _ = try GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: candidate, quarterTurns: adjustments.quarterTurns)
            try constrainGeometry(&candidate)
        } catch { guideMessage = error.localizedDescription; return false }
        edit { $0.geometry = candidate }
        return true
    }
    func setManualTransform(_ key: WritableKeyPath<ManualTransform, Double>, to value: Double) {
        var candidate = adjustments.geometry
        candidate.transform[keyPath: key] = value
        candidate.crop = geometryGestureStart?.geometry.crop ?? candidate.crop
        if apply(candidate) { guideMessage = nil }
    }
    func setConstrainCrop(_ enabled: Bool) {
        var candidate = adjustments.geometry; candidate.constrainCrop = enabled
        if apply(candidate) { guideMessage = nil }
    }
    private func constrainGeometry(_ candidate: inout GeometryAdjustments) throws {
        guard candidate.constrainCrop, let info else { return }
        let size = CGSize(width: info.width, height: info.height)
        candidate.crop = constrainedCrop(candidate, quarterTurns: adjustments.quarterTurns, before: adjustments, info: info)
        guard candidate.cropFitsImage(sourceSize: size, quarterTurns: adjustments.quarterTurns) else {
            throw EditorError.invalidDocument(L10n.tr("No crop fits inside the image. Reduce the offsets or turn off Constrain Crop."))
        }
    }
    func resetCrop() {
        cropStraightening = false
        edit {
            $0.geometry.crop = .full; $0.geometry.aspect = .free; $0.geometry.portrait = false
            $0.geometry.straighten = 0; $0.geometry.flipHorizontal = false; $0.geometry.flipVertical = false
            $0.quarterTurns = 0
        }
    }
    func resetTransform() {
        cropDrawingGuide = false; guideDraft = nil; selectedGuideID = nil; guideMessage = nil
        cropPlacingCorners = false; cornerDraft = nil
        edit {
            $0.geometry.transform = ManualTransform()
            $0.geometry.guides = []; $0.geometry.uprightEnabled = true
            $0.geometry.uprightMode = .off; $0.geometry.uprightAnalysis = nil
            if $0.geometry.perspective != nil { $0.geometry.perspective = nil; $0.geometry.crop = .full }
        }
    }
}
