import SwiftUI
import CevicheCore

extension EditorModel {
    var targetMask: PhotoMask? { adjustments.masks.first { $0.id == adjustmentTargetID } }
    var isLocalTarget: Bool { targetMask != nil }
    var targetAdjustments: Adjustments { targetMask?.adjustments.applying(to: Adjustments()) ?? adjustments }
    var targetDefaults: Adjustments { isLocalTarget ? Adjustments() : (info?.defaults ?? Adjustments()) }
    func editTarget(_ update: (inout Adjustments) -> Void) {
        if let index = adjustments.masks.firstIndex(where: { $0.id == adjustmentTargetID }) {
            edit { value in
                var local = value.masks[index].adjustments.applying(to: Adjustments())
                update(&local); value.masks[index].adjustments = local.pixels
            }
        } else { edit(update) }
    }
    func setAdjustmentTarget(_ id: UUID?) {
        endMask(); endGesture(); maskTool = nil
        if let id { selectMask(id) } else { adjustmentTargetID = nil }
    }
    func refineTarget() {
        guard let id = adjustmentTargetID else { return }
        if [.light, .detail].contains(toolTab) { lastAdjustmentTab = toolTab }
        selectMask(id); toolTab = .masks
    }
    func editSelectedMask(in tab: ToolTab? = nil) {
        guard let id = selectedMaskID else { return }
        endMask(); adjustmentTargetID = id; maskTool = nil; toolTab = tab ?? lastAdjustmentTab
    }
    func duplicateMask(_ id: UUID) {
        guard var copy = adjustments.masks.first(where: { $0.id == id }), adjustments.masks.count < PhotoMask.maxCount else { return }
        endMask(); copy.id = UUID(); copy.name = String(L10n.tr("\(copy.name) copy").prefix(200))
        copy.components = copy.components.map { var c = $0; c.id = UUID(); return c }
        edit { $0.masks.append(copy) }; selectMask(copy.id)
    }
    func moveMask(_ id: UUID, by offset: Int) {
        guard let i = adjustments.masks.firstIndex(where: { $0.id == id }), adjustments.masks.indices.contains(i + offset) else { return }
        endMask(); edit { $0.masks.swapAt(i, i + offset) }
    }
    func copyMaskAdjustments() { copiedMaskAdjustments = selectedMask?.adjustments }
    func pasteMaskAdjustments() { guard let copiedMaskAdjustments else { return }; updateMask { $0.adjustments = copiedMaskAdjustments } }
    var editableSelection: MaskSelection? {
        guard let selectedMask else { return nil }
        return selectedMask.components.first { $0.id == selectedComponentID }?.selection ?? selectedMask.selection
    }
    func updateSelection(_ update: (inout MaskSelection) -> Void) {
        updateMask { mask in
            if let i = mask.components.firstIndex(where: { $0.id == selectedComponentID }) { update(&mask.components[i].selection) }
            else { update(&mask.selection) }
        }
    }
    func addComponent(_ kind: MaskKind, operation: MaskOperation, scene: SceneCategory? = nil, people: PeopleSelection? = nil) {
        guard let selectedMask, !busy else { return }
        pendingMaskOperation = operation; pendingMaskParentID = selectedMask.id
        if MaskKind.generatedOnPhoto.contains(kind) { generateSelection(kind, scene: scene, people: people); return }
        if kind == .object { maskTool = .object; comparing = false; _ = currentObjectPicker(); return }
        // Gradients are added where the first line is drawn; the pending operation waits for that drag.
        if kind == .linear || kind == .radial { endMask(); selectedComponentID = nil; maskTool = kind; awaitingGradient = true; redrawGradient = false; comparing = false; return }
        acceptSelection(PhotoMask(kind: kind), operation: operation, parentID: selectedMask.id)
        pendingMaskOperation = nil; pendingMaskParentID = nil; maskTool = kind; comparing = false
    }
    func acceptSelection(_ mask: PhotoMask, operation: MaskOperation?, parentID: UUID?) {
        endMask()
        if let operation, let parentID, let index = adjustments.masks.firstIndex(where: { $0.id == parentID }), adjustments.masks[index].components.count < PhotoMask.maxComponents {
            let component = MaskComponent(operation: operation, selection: mask.selection)
            edit { value in
                if value.masks[index].components.isEmpty && value.masks[index].inverted {
                    value.masks[index].selection.inverted.toggle(); value.masks[index].inverted = false
                }
                value.masks[index].components.append(component)
            }
            selectMask(parentID); selectedComponentID = component.id
        } else if operation == nil, adjustments.masks.count < PhotoMask.maxCount {
            var mask = mask
            let count = adjustments.masks.filter { $0.kind == mask.kind }.count
            if count > 0 { mask.name += " \(count+1)" }
            edit { $0.masks.append(mask) }; selectMask(mask.id)
        }
    }
}

struct AdjustmentTargetBar: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                PanelPicker(title: L10n.tr("Target"), selection: Binding(get: { model.targetMask?.id }, set: { model.setAdjustmentTarget($0) }),
                            options: [nil] + model.adjustments.masks.map { Optional($0.id) },
                            // Fills the row and truncates: a mask's name can be long (People masks list their parts), and
                            // hugging it pushed the panel, and the tool rail beside it, past the window's edge.
                            label: { id in id.flatMap { id in model.adjustments.masks.first { $0.id == id }?.name } ?? L10n.tr("Global") }, expands: true).controlSize(.small)
                Menu {
                    Button(L10n.tr("Select Subject")) { model.addMask(.subject) }
                    Button(L10n.tr("Select Sky")) { model.addMask(.sky) }
                    Button(L10n.tr("Select Background")) { model.addMask(.background) }
                    Button(L10n.tr("Select Object")) { model.addMask(.object) }
                    Divider()
                    Button(L10n.tr("Brush")) { model.addMask(.brush) }
                    Button(L10n.tr("Linear Gradient")) { model.addMask(.linear) }
                    Button(L10n.tr("Radial Gradient")) { model.addMask(.radial) }
                    Button(L10n.tr("Color Range")) { model.addMask(.color) }
                } label: { Image(systemName: "plus.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.tr("Add local adjustment")).accessibilityLabel(L10n.tr("Add local adjustment"))
                if model.isLocalTarget {
                    Button(action: model.refineTarget) { Image(systemName: "circle.dashed") }.buttonStyle(.plain).help(L10n.tr("Refine mask")).accessibilityLabel(L10n.tr("Refine mask"))
                    Button { model.editTarget { $0.pixels = PixelAdjustments() } } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).help(L10n.tr("Reset mask adjustments")).accessibilityLabel(L10n.tr("Reset mask adjustments"))
                }
            }
            if let mask = model.targetMask {
                HStack {
                    Text(L10n.tr("Amount")).font(.system(size: 11)).foregroundStyle(.secondary)
                    FormSlider(value: Binding(get: { model.targetMask?.opacity ?? 1 }, set: { v in model.edit { a in if let i = a.masks.firstIndex(where: { $0.id == mask.id }) { a.masks[i].opacity = v } } }), in: 0...1, onEditingChanged: { active in if active { model.beginGesture() } else { model.endGesture() } })
                    EditableValue(label: "\(Int((mask.opacity*100).rounded()))%", value: mask.opacity, range: 0...1, scale: 100, title: L10n.tr("Amount"), width: 40, size: 10, editing: { active in if active { model.beginGesture() } else { model.endGesture() } }) { v in model.edit { a in if let i = a.masks.firstIndex(where: { $0.id == mask.id }) { a.masks[i].opacity = v } } }
                    Button { model.edit { a in if let i = a.masks.firstIndex(where: { $0.id == mask.id }) { a.masks[i].enabled.toggle() } } } label: { Image(systemName: mask.enabled ? "eye" : "eye.slash") }.buttonStyle(.plain).help(L10n.tr("Toggle mask")).accessibilityLabel(L10n.tr("Toggle mask"))
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(model.isLocalTarget ? Theme.accent.opacity(0.07) : .clear).disabled(!model.hasImage || model.busy)
    }
}
