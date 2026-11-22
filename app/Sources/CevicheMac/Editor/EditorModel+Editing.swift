import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Changing the edit: undoable edits, slider gestures, curves, the histogram drag, zoom, and autosave.
extension EditorModel {
    func setComparisonSplit(_ fraction: Double) {
        comparisonSplit = min(0.98, max(0.02, fraction))
    }
    func updateViewportGeometry(image: CGSize, canvas: CGSize) {
        viewportImageSize = image; viewportCanvasSize = canvas
        if toolTab == .crop, cropFocusPending { focusCrop() }
    }
    func zoomImageIn() { setImageZoom(viewport.nextLarger) }
    func zoomImageOut() { setImageZoom(viewport.nextSmaller) }
    /// Zooms about the canvas center, as the bottom bar's slider does.
    func zoomImage(to scale: Double) { setImageZoom(scale) }
    private func setImageZoom(_ scale: Double, anchor: CGPoint? = nil) {
        viewport.zoom(to: scale, anchor: anchor, image: viewportImageSize, canvas: viewportCanvasSize)
    }
    func magnifyImage(by delta: Double, anchor: CGPoint) {
        setImageZoom(viewport.scale + delta, anchor: anchor)
    }
    func toggleImageFit(anchor: CGPoint? = nil) {
        if viewport.isFitted { setImageZoom(2, anchor: anchor) } else { viewport.fit() }
    }
    func panImage(by delta: CGSize) { viewport.pan(by: delta, image: viewportImageSize, canvas: viewportCanvasSize) }
    func edit(constrainingCrop: Bool = true, _ update: (inout Adjustments) -> Void) {
        let before = adjustments
        update(&adjustments)
        if constrainingCrop { constrainCropIfNeeded(before: before) }
        guard before != adjustments else { return }
        if gestureStart == nil { undoStack.append(before); redoStack = [] }
        changed()
    }
    /// Constrain Crop: any geometry change refits a crop that would show empty corners.
    private func constrainCropIfNeeded(before: Adjustments) {
        guard adjustments.geometry.constrainCrop, let info,
              adjustments.geometry != before.geometry || adjustments.quarterTurns != before.quarterTurns else { return }
        adjustments.geometry.crop = constrainedCrop(adjustments.geometry, quarterTurns: adjustments.quarterTurns, before: before, info: info)
    }
    /// A crop that followed the photo before the change (or before the drag that is changing it) follows it after.
    func constrainedCrop(_ geometry: GeometryAdjustments, quarterTurns: Int, before: Adjustments, info: ImageInfo) -> CropRect {
        let reference = gestureStart ?? before
        return geometry.constrainedCrop(after: reference.geometry, previousQuarterTurns: reference.quarterTurns,
                                        sourceSize: CGSize(width: info.width, height: info.height), quarterTurns: quarterTurns)
    }
    /// A change that describes the photo rather than an edit (Upright's analysis): rendered and saved, but no undo
    /// step, and every remembered state of the photo gets it too.
    func editSilently(_ update: (inout Adjustments) -> Void) {
        for i in undoStack.indices { update(&undoStack[i]) }
        for i in redoStack.indices { update(&redoStack[i]) }
        if gestureStart != nil { update(&gestureStart!) }
        let before = adjustments
        update(&adjustments)
        constrainCropIfNeeded(before: before)
        guard before != adjustments else { return }
        changed()
    }
    func beginGesture() { if gestureStart == nil { autosaveTask?.cancel(); gestureStart = adjustments } }
    func endGesture() {
        if let start = gestureStart, start != adjustments { undoStack.append(start); redoStack = [] }
        gestureStart = nil
        // Do not autosave in the middle of a long mouse gesture.
        if dirty { scheduleAutosave() }
        scheduleFills()
    }
    func undo() {
        endGesture()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(adjustments); adjustments = previous; changed()
    }
    func redo() {
        endGesture()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(adjustments); adjustments = next; changed()
    }
    func reset() { guard let info else { return }; edit { $0 = info.defaults } }
    func resetSection(_ section: AdjustmentGroup) {
        let defaults = targetDefaults
        editTarget { $0.resetValues(for: section, to: defaults) }
    }
    func setSection(_ section: AdjustmentGroup, enabled: Bool) {
        if section == .defringe, !enabled, case .defringe? = eyedropper { eyedropper = nil }
        editTarget { if enabled { $0.disabledSections.remove(section) } else { $0.disabledSections.insert(section) } }
    }
    @discardableResult
    func addCurvePoint(x: Double, y: Double) -> Int? {
        var index: Int?
        let key = curveChannel.key, upper = curveUpperInput
        editTarget { index = $0[keyPath: key].insert(x: x, y: y, upper: upper) }
        return index
    }
    func moveCurvePoint(at index: Int, x: Double, y: Double) { let key = curveChannel.key, upper = curveUpperInput; editTarget { $0[keyPath: key].move(at: index, x: x, y: y, upper: upper) } }
    /// Stops above SDR white the curve editor shows: the output headroom while editing HDR, nil for SDR.
    var curveHDRStops: Double? { adjustments.hdr.enabled && !sdrPreview ? min(ToneCurve.maximumStops, max(1, adjustments.hdr.headroom)) : nil }
    var curveUpperInput: Double { curveHDRStops.map { 1 + $0 } ?? 1 }
    func removeCurvePoint(at index: Int) { let key = curveChannel.key; editTarget { $0[keyPath: key].remove(at: index) } }
    func beginHistogramDrag(_ region: HistogramRegion) {
        beginGesture(); histogramDrag = (region, targetAdjustments[keyPath: region.key])
    }
    func updateHistogramDrag(translation: Double) {
        guard let (region, start) = histogramDrag else { return }
        editTarget { $0[keyPath: region.key] = region.adjusted(start: start, translation: translation) }
    }
    func endHistogramDrag() { histogramDrag = nil; endGesture() }
    /// A preset temperature with neutral tint, or the as-shot pair.
    func whiteBalance(_ temperature: Double?) {
        guard let info else { return }
        edit { $0.temperature = temperature ?? info.defaults.temperature; $0.tint = temperature == nil ? info.defaults.tint : 0 }
    }
    func changed() {
        lookPreview = nil
        dirty = adjustments != savedAdjustments
        scheduleRender()
        scheduleAutosave()
        scheduleFills()
    }
    func scheduleAutosave() {
        autosaveTask?.cancel()
        guard developmentStore?.canSave == true, gestureStart == nil else { return }
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.save(coalescing: true)
        }
    }
}
