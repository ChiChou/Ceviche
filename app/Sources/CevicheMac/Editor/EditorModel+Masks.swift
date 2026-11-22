import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CevicheCore

/// Local adjustment masks: making, selecting, brushing and deleting them.
extension EditorModel {
    var selectedMask: PhotoMask? { adjustments.masks.first { $0.id == selectedMaskID } }
    func selectMask(_ id: UUID) { endMask(); selectedMaskID = id; adjustmentTargetID = id; selectedComponentID = nil; maskTool = nil; pendingMaskOperation = nil; pendingMaskParentID = nil; scheduleRender() }
    func updateMask(_ update: (inout PhotoMask) -> Void) {
        guard let index = adjustments.masks.firstIndex(where: { $0.id == selectedMaskID }) else { return }
        edit { update(&$0.masks[index]) }
    }
    func deleteMask(_ id: UUID) {
        endMask(); endGesture()
        edit { $0.masks.removeAll { $0.id == id } }
        if selectedMaskID == id { selectedMaskID = adjustments.masks.last?.id; selectedComponentID = nil; maskTool = nil; maskOverlay = nil }
        if adjustmentTargetID == id { adjustmentTargetID = nil }
        scheduleRender()
    }
    func addMask(_ kind: MaskKind, scene: SceneCategory? = nil, people: PeopleSelection? = nil) {
        guard hasImage, !busy, adjustments.masks.count < PhotoMask.maxCount else { return }
        endMask(); pendingMaskOperation = nil; pendingMaskParentID = nil; selectedComponentID = nil
        toolTab = .masks; comparing = false
        if MaskKind.generatedOnPhoto.contains(kind) { generateSelection(kind, scene: scene, people: people); return }
        if kind == .object { maskTool = .object; _ = currentObjectPicker(); return }
        if kind == .linear || kind == .radial {
            // Choosing the tool creates nothing; the mask appears where the first line is drawn.
            selectedMaskID = nil; adjustmentTargetID = nil; selectedComponentID = nil; maskOverlay = nil
            maskTool = kind; awaitingGradient = true; redrawGradient = false; scheduleRender(); return
        }
        var mask = PhotoMask(kind: kind)
        if kind == .brush { mask.feather = 0 }
        acceptSelection(mask, operation: nil, parentID: nil); maskTool = kind
    }
    /// Delete removes the selected component, or the selected mask when its base is selected.
    func deleteSelectedMaskOrComponent() {
        guard let mask = selectedMask, !busy else { return }
        if let component = selectedComponentID, mask.components.contains(where: { $0.id == component }) {
            endMask(); updateMask { $0.components.removeAll { $0.id == component } }; selectedComponentID = nil; maskTool = nil
        } else { deleteMask(mask.id) }
    }
    /// A new gradient: the mask or component is created at the mouse-down point inside the drag's gesture, so creating and drawing undo together.
    static func gradientMask(_ kind: MaskKind, at point: MaskPoint) -> PhotoMask {
        var mask = PhotoMask(kind: kind)
        if kind == .radial { mask.feather = 0.125 }
        mask.start = point; mask.end = point
        return mask
    }
    func generateSelection(_ kind: MaskKind, point: MaskPoint? = nil, scene: SceneCategory? = nil, people: PeopleSelection? = nil) {
        guard let renderer, !busy else { return }
        let operation = pendingMaskOperation, parentID = pendingMaskParentID
        pendingMaskOperation = nil; pendingMaskParentID = nil
        isSelecting = true
        selectionStatus = kind == .depth ? L10n.tr("Estimating depth…") : L10n.tr("Selecting \(scene?.localizedTitle ?? kind.localizedTitle)…")
        selectionTask = Task {
            defer { isSelecting = false; selectionStatus = "" }
            do {
                let mask = try await renderer.selection(kind, point: point, scene: scene, people: people)
                try Task.checkCancellation()
                guard self.renderer === renderer else { return }
                acceptSelection(mask, operation: operation, parentID: parentID); maskTool = nil
            } catch is CancellationError {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    /// Masks › Object: once the pointer has rested a moment, the mask a click there would make is outlined.
    func hoverMaskObject(at point: MaskPoint?) {
        objectHover?.cancel()
        guard let point, toolTab == .masks, maskTool == .object, !busy else { if maskObjectPreview != nil { maskObjectPreview = nil }; return }
        if let preview = maskObjectPreview, hypot(preview.point.x - point.x, preview.point.y - point.y) < 0.004 { return }
        objectHover = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, let task = self.currentObjectPicker() else { return }
            do {
                let made = try await task.value.objectMask(at: point)
                guard !Task.isCancelled, self.maskTool == .object else { return }
                self.maskObjectPreview = MaskObjectPreview(point: point, mask: made.mask, outline: made.outline)
            } catch { if !Task.isCancelled { self.maskObjectPreview = nil } }
        }
    }
    func cancelSelection() { selectionTask?.cancel(); pendingMaskOperation = nil; pendingMaskParentID = nil }
    func beginMask(at point: MaskPoint, erase: Bool = false) {
        guard !busy, toolTab == .masks, let tool = maskTool else { return }
        if tool == .object {
            // The mask the outline shows is taken at once.
            if let preview = maskObjectPreview, hypot(preview.point.x - point.x, preview.point.y - point.y) < 0.004 {
                let operation = pendingMaskOperation, parentID = pendingMaskParentID
                pendingMaskOperation = nil; pendingMaskParentID = nil; maskObjectPreview = nil
                objectHover?.cancel()
                acceptSelection(preview.mask, operation: operation, parentID: parentID); maskTool = nil
                return
            }
            maskObjectPreview = nil
            generateSelection(.object, point: point); return
        }
        if tool == .color {
            guard let renderer, let id = selectedMaskID else { return }
            let snapshot = adjustments
            isSelecting = true; selectionStatus = L10n.tr("Sampling color…")
            selectionTask = Task {
                defer { isSelecting = false; selectionStatus = "" }
                do {
                    let color = try await renderer.sampleColor(at: point, adjustments: snapshot)
                    try Task.checkCancellation()
                    guard self.renderer === renderer, selectedMaskID == id else { return }
                    updateSelection { $0.color = color }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            return
        }
        if awaitingGradient, tool == .linear || tool == .radial {
            beginGesture()
            let mask = Self.gradientMask(tool, at: point), operation = pendingMaskOperation, parent = pendingMaskParentID
            pendingMaskOperation = nil; pendingMaskParentID = nil
            acceptSelection(mask, operation: operation, parentID: parent)
            // acceptSelection selects the result, which clears the tool; the drag that follows still draws it.
            maskTool = tool; awaitingGradient = false
            drawnGradientID = selectedComponentID ?? selectedMaskID
            if drawnGradientID == nil { endGesture(); return }
            maskDragStart = point; return
        }
        guard selectedMask != nil else { return }
        maskDragStart = point; beginGesture()
        if tool == .brush {
            // The stroke is its own layer while it is painted: the canvas draws it over the mask as it stands, and
            // the mask, with whatever it is built from, is made again once, when the pointer is released.
            liveStroke = MaskStroke(points: [point], radius: brushRadius, softness: brushSoftness, erase: brushErase || erase)
        } else { updateSelection { $0.start = point; $0.end = point } }
    }
    func dragMask(to point: MaskPoint, shift: Bool = false) {
        guard let origin = maskDragStart, !busy else { return }
        if maskTool == .brush {
            if let previous = liveStroke?.points.last, hypot(previous.x - point.x, previous.y - point.y) < 0.001 { return }
            liveStroke?.points.append(point)
        } else if maskTool == .radial {
            // The mouse-down point is the center; the drag sets the half-extents. Shift keeps it a circle.
            var dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
            if shift { dx = max(dx, dy); dy = dx }
            updateSelection { $0.start = MaskPoint(x: origin.x - dx, y: origin.y - dy); $0.end = MaskPoint(x: origin.x + dx, y: origin.y + dy) }
        } else {
            // Shift snaps a linear gradient to 45° steps.
            let adjusted = shift && maskTool == .linear ? point.constrainedToCardinal(from: origin) : point
            updateSelection { $0.end = adjusted }
        }
    }
    func endMask() {
        guard maskDragStart != nil else { return }
        maskDragStart = nil
        // The painted stroke joins the mask: one edit, one render.
        if let stroke = liveStroke { liveStroke = nil; updateSelection { $0.strokes.append(stroke) } }
        // A click without a drag draws no gradient: remove the empty one and keep waiting for a line.
        if let drawn = drawnGradientID, let selection = editableSelection, hypot(selection.end.x - selection.start.x, selection.end.y - selection.start.y) < 0.005 {
            if selectedComponentID == drawn { updateMask { $0.components.removeAll { $0.id == drawn } }; selectedComponentID = nil }
            else { edit { $0.masks.removeAll { $0.id == drawn } }; selectedMaskID = nil; adjustmentTargetID = nil; maskOverlay = nil }
            awaitingGradient = true
        }
        drawnGradientID = nil; redrawGradient = false
        endGesture()
    }
}
