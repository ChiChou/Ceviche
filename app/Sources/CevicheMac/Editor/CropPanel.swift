import SwiftUI
import CevicheCore

/// The Crop tab: plain cropping on top (aspect, straighten, Rotate & Flip, overlay, Constrain Crop), then the collapsible
/// Perspective section (Upright, the four corners and the manual transform).
struct CropPanel: View {
    @ObservedObject var model: EditorModel
    private var geometry: GeometryAdjustments { model.adjustments.geometry }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("Crop")).font(.headline)
                Spacer()
                Button(action: model.resetCrop) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).help(L10n.tr("Reset crop, straighten, rotation and flips")).accessibilityLabel(L10n.tr("Reset crop"))
            }
            HStack {
                Text(L10n.tr("Aspect")).foregroundStyle(.secondary)
                PanelPicker(title: L10n.tr("Aspect"), selection: Binding(get: { geometry.aspect }, set: model.setCropAspect), options: CropAspect.allCases, label: \.localizedTitle, expands: true)
                    .controlSize(.small)
                Spacer()
                Button(action: model.swapCropAspect) { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).help(L10n.tr("Swap portrait and landscape (X)")).accessibilityLabel(L10n.tr("Swap crop orientation"))
            }
            straighten
            if model.cropStraightening { Text(L10n.tr("Drag along an edge that should be level or vertical.")).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 24) {
                tool("rotate.right", L10n.tr("Rotate right")) { model.rotateCrop(1) }
                tool("rotate.left", L10n.tr("Rotate left")) { model.rotateCrop(-1) }
                tool("arrow.left.and.right.righttriangle.left.righttriangle.right", L10n.tr("Flip horizontal")) { model.flipCrop(horizontal: true) }
                tool("arrow.up.and.down.righttriangle.up.righttriangle.down", L10n.tr("Flip vertical")) { model.flipCrop(horizontal: false) }
            }.padding(.leading, 4)
            HStack {
                Text(L10n.tr("Crop Overlay")).foregroundStyle(.secondary)
                Spacer()
                PanelPicker(title: L10n.tr("Overlay"), selection: $model.cropOverlay, options: CropOverlay.allCases, label: \.localizedTitle).controlSize(.small)
                PanelPicker(title: L10n.tr("Show overlay"), selection: $model.cropOverlayVisibility, options: CropOverlayVisibility.allCases, label: \.localizedTitle).controlSize(.small)
            }
            if model.cropOverlay.orientations > 1 { Button(L10n.tr("Turn Overlay (⇧O)")) { model.cycleCropOverlay(reverseOrientation: true) }.buttonStyle(.plain) }
            Toggle(L10n.tr("Constrain Crop"), isOn: Binding(get: { geometry.constrainCrop }, set: model.setConstrainCrop))
                .toggleStyle(.formCheckbox).help(L10n.tr("Keep empty corners outside the crop"))
            Rule()
            VolumeSection(model: model)
            Rule()
            GeometrySection(model: model)
            Rule()
            HStack {
                if let size = model.outputSize { Text(L10n.tr("\(Int(size.width)) × \(Int(size.height)) px")).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.tr("Done")) { model.cropDrawingGuide = false; model.cropPlacingCorners = false; model.finishCrop() }.buttonStyle(.primaryAction)
            }
        }.font(.system(size: 12)).padding(20).disabled(!model.hasImage || model.busy)
    }
    /// The Straighten slider, with Auto, Eyes and the ruler in its title row.
    private var straighten: some View {
        VStack(spacing: 3) {
            HStack(spacing: 0) {
                Text(L10n.tr("Straighten")).foregroundStyle(.secondary).contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.setStraighten(0) }.help(L10n.tr("Double-click to reset"))
                Spacer()
                Button(model.autoStraightening ? L10n.tr("MEASURING…") : L10n.tr("AUTO"), action: model.autoStraighten)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).disabled(model.autoStraightening)
                    .help(L10n.tr("Level the photo along its dominant edges"))
                if !model.autoStraightening {
                    Button(L10n.tr("EYES"), action: model.levelEyes)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).padding(.leading, 10)
                        .help(L10n.tr("Level the line through the eyes of the largest face"))
                }
                Button(action: model.toggleStraightenRuler) { Image(systemName: "level") }
                    .buttonStyle(.plain).foregroundStyle(model.cropStraightening ? Theme.accent : Color.secondary).padding(.leading, 12)
                    .help(L10n.tr("Drag along a horizon or vertical edge. You can also ⌘-drag on the photo."))
                    .accessibilityLabel(model.cropStraightening ? L10n.tr("Cancel ruler") : L10n.tr("Ruler"))
                Spacer()
                EditableValue(label: String(format: "%+.1f°", locale: Locale.current, geometry.straighten), value: geometry.straighten, range: -45...45, precision: 1, title: L10n.tr("Straighten"), editing: gesture) { model.setStraighten($0) }
                    .foregroundStyle(geometry.straighten == 0 ? .secondary : .primary)
            }.font(.system(size: 11))
            ResettableSlider(value: Binding(get: { geometry.straighten }, set: model.setStraighten), range: -45...45, title: L10n.tr("Straighten"), editing: gesture, reset: { model.setStraighten(0) }, appearance: .parameter(L10n.tr("Straighten")))
                .frame(height: 18)
        }
    }
    private func tool(_ symbol: String, _ title: String, action: @escaping () -> Void) -> IconButton {
        IconButton(symbol, title, pointSize: 17, size: CGSize(width: 28, height: 24), action: action)
    }
    private func gesture(_ active: Bool) { if active { model.beginGesture() } else { model.endGesture() } }
}

extension EditorModel {
    var sourceGuideAxis: GuideAxis { displayGuideAxis(guideAxis) }
    func displayGuideAxis(_ axis: GuideAxis) -> GuideAxis {
        adjustments.quarterTurns % 2 == 0 ? axis : (axis == .vertical ? .horizontal : .vertical)
    }

    /// While Constrain to image is on, a dragged crop that would leave the photo is not applied, so handles stop at its edge.
    func cropFitsImage(_ crop: CropRect) -> Bool {
        guard adjustments.geometry.constrainCrop, let info else { return true }
        var geometry = adjustments.geometry; geometry.crop = crop
        return geometry.cropFitsImage(sourceSize: CGSize(width: info.width, height: info.height), quarterTurns: adjustments.quarterTurns)
    }
    func rotateCrop(_ direction: Int) {
        edit { value in
            let crop = value.geometry.crop
            let mirrored = value.geometry.flipHorizontal != value.geometry.flipVertical
            let clockwise = direction > 0
            value.geometry.transform.rotateClockwise(clockwise)
            value.geometry.crop = clockwise
                ? CropRect(x: crop.y, y: max(0, 1 - crop.x - crop.width), width: crop.height, height: crop.width)
                : CropRect(x: max(0, 1 - crop.y - crop.height), y: crop.x, width: crop.height, height: crop.width)
            value.quarterTurns = (value.quarterTurns + (mirrored ? -direction : direction) + 4) % 4
            value.geometry.portrait.toggle()
        }
    }
    func setStraighten(_ degrees: Double) {
        guard let info else { return }
        edit { value in
            value.geometry.crop = geometryGestureStart?.geometry.crop ?? value.geometry.crop
            value.geometry.straighten = degrees
            let original = value.quarterTurns % 2 == 0 ? CGSize(width: info.width, height: info.height) : CGSize(width: info.height, height: info.width)
            guard let ratio = value.geometry.aspect.ratio(original: original, portrait: value.geometry.portrait),
                  let plan = try? GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: value.geometry, quarterTurns: value.quarterTurns) else { return }
            value.geometry.crop = Self.fittingAspect(ratio * plan.fullSize.height / plan.fullSize.width, around: value.geometry.crop)
        }
    }
    /// Turning the photo from the canvas turns only the photo: the crop keeps its size in pixels and its place relative
    /// to the photo's center, and Constrain Crop waits for `finishTurningPhoto` to hide the corners.
    func turnPhoto(straighten degrees: Double) {
        guard let info, let start = geometryGestureStart else { return }
        let source = CGSize(width: info.width, height: info.height)
        var turned = start.geometry; turned.straighten = degrees
        guard let before = try? GeometryPlan(size: source, settings: start.geometry, quarterTurns: start.quarterTurns),
              let after = try? GeometryPlan(size: source, settings: turned, quarterTurns: start.quarterTurns) else { return }
        let crop = start.geometry.crop
        let sx = before.fullSize.width / after.fullSize.width, sy = before.fullSize.height / after.fullSize.height
        let cx = min(1, max(0, 0.5 + (crop.x + crop.width / 2 - 0.5) * sx)), cy = min(1, max(0, 0.5 + (crop.y + crop.height / 2 - 0.5) * sy))
        var width = crop.width * sx, height = crop.height * sy
        // A frame the smaller turned photo can no longer hold shrinks evenly, so its shape stays.
        let scale = min(1, 2 * min(cx, 1 - cx) / width, 2 * min(cy, 1 - cy) / height)
        width *= scale; height *= scale
        guard width >= 0.01, height >= 0.01 else { return }
        edit(constrainingCrop: false) { value in
            value.geometry.straighten = degrees
            value.geometry.crop = CropRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
        }
    }
    /// Letting go of the turn: Constrain Crop refits a frame that shows empty corners, in the same undo step.
    func finishTurningPhoto() {
        guard adjustments.geometry.constrainCrop, let info else { return }
        // Fitted here, around the frame the turn kept; the general refit would start again from the full photo.
        edit(constrainingCrop: false) { $0.geometry.crop = $0.geometry.constrainedCrop(sourceSize: CGSize(width: info.width, height: info.height), quarterTurns: $0.quarterTurns) }
    }
    func setCropPortrait(_ value: Bool) {
        beginGesture(); edit { $0.geometry.portrait = value }; setCropAspect(adjustments.geometry.aspect); endGesture()
    }
    func setCropAspect(_ aspect: CropAspect) {
        guard let plan = geometryPlan, let info else { return }
        let original = adjustments.quarterTurns % 2 == 0 ? CGSize(width: info.width, height: info.height) : CGSize(width: info.height, height: info.width)
        let portrait = aspect == .original && adjustments.geometry.aspect != .original ? original.height > original.width : adjustments.geometry.portrait
        let ratio = aspect.ratio(original: original, portrait: portrait)
        edit { value in
            value.geometry.aspect = aspect; value.geometry.portrait = portrait
            if let ratio { value.geometry.crop = Self.fittingAspect(ratio * plan.fullSize.height / plan.fullSize.width, around: value.geometry.crop) }
        }
    }

    var normalizedCropAspect: Double? {
        guard let plan = geometryPlan, let info else { return nil }
        let original = adjustments.quarterTurns % 2 == 0 ? CGSize(width: info.width, height: info.height) : CGSize(width: info.height, height: info.width)
        return adjustments.geometry.aspect.ratio(original: original, portrait: adjustments.geometry.portrait).map { $0 * plan.fullSize.height / plan.fullSize.width }
    }
    func acceptGuide() {
        guard let draft = guideDraft, let info else { guideDraft = nil; return }
        defer { guideDraft = nil }
        guard hypot((draft.end.x - draft.start.x) * Double(info.width), (draft.end.y - draft.start.y) * Double(info.height)) >= Double(max(info.width, info.height)) * 0.02 else {
            guideMessage = L10n.tr("The guide is too short. Drag along a longer edge."); return
        }
        var candidate = adjustments.geometry
        if let index = candidate.guides.firstIndex(where: { $0.id == draft.id }) { candidate.guides[index] = draft }
        else {
            guard candidate.guides.count < 4 else { guideMessage = L10n.tr("Four guides are already placed. Move an endpoint or delete a guide."); return }
            candidate.guides.append(draft)
        }
        candidate.uprightEnabled = true; candidate.uprightMode = .guided
        do {
            let plan = try GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: candidate, quarterTurns: adjustments.quarterTurns)
            edit { $0.geometry = candidate }
            selectedGuideID = draft.id; guideMessage = plan.uprightMessage
        } catch { guideMessage = error.localizedDescription }
    }
}
