import AppKit
import SwiftUI
import CevicheCore

/// Portrait's Touch Up on the photo: the face part under the pointer (teeth, lips, eyes, brows) is tinted, and a click
/// opens that part's correction for that person beside it.
extension ImageCanvas {
    func showsFaceParts(_ model: EditorModel) -> Bool {
        model.toolTab == .face && model.touchingUp && !model.comparing && !model.busy
    }
    private func path(_ loop: [MaskPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        for (i, p) in loop.enumerated() { let q = sourceCanvasPoint(p); if i == 0 { path.move(to: q) } else { path.line(to: q) } }
        path.close()
        return path
    }
    /// The part under `point`: teeth inside an open mouth, lips around it, then eyes and brows.
    func facePart(at point: CGPoint) -> (outline: PortraitPartOutline, part: PortraitPartOutline.Part)? {
        guard let model, showsFaceParts(model) else { return nil }
        for outline in model.portraitParts {
            for part in PortraitPartOutline.Part.allCases where outline.loops(part).contains(where: { path($0).contains(point) }) {
                return (outline, part)
            }
        }
        return nil
    }
    func drawFaceParts(model: EditorModel) {
        guard let pointerPosition, let (outline, part) = facePart(at: pointerPosition) else { return }
        let shape = NSBezierPath()
        for loop in outline.loops(part) { shape.append(path(loop)) }
        if part == .lips, outline.mouthOpen { shape.append(path(outline.mouth)); shape.windingRule = .evenOdd }
        Theme.nsAccent.withAlphaComponent(0.3).setFill(); shape.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke(); shape.lineWidth = 1.5; shape.stroke()
    }
    /// Opens the part's controls beside it, for the face it belongs to.
    func openFacePart(_ hit: (outline: PortraitPartOutline, part: PortraitPartOutline.Part), model: EditorModel) {
        let bounds = hit.outline.loops(hit.part).flatMap { $0 }.map(sourceCanvasPoint)
        guard let minX = bounds.map(\.x).min(), let maxX = bounds.map(\.x).max(), let minY = bounds.map(\.y).min(), let maxY = bounds.map(\.y).max() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: PortraitPartControls(model: model, kind: hit.part.correction, face: hit.outline.face))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)), of: self, preferredEdge: .maxX)
    }
}

extension PortraitPartOutline.Part {
    /// The Details correction a part opens.
    var correction: PortraitCorrection {
        switch self {
        case .teeth: return .teeth
        case .lips: return .lips
        case .eyes: return .eyes
        case .brows: return .brows
        }
    }
}

/// One part's correction for one person, as Portrait › Details has it: Auto until it is made, then its Amount, a wand
/// that measures again and a remove button. The eyes add Red eye, which is the photo's.
struct PortraitPartControls: View {
    @ObservedObject var model: EditorModel
    let kind: PortraitCorrection
    let face: CGRect
    private var mask: PhotoMask? { model.adjustments.masks.first { $0.portraitCorrection == kind && PortraitFace.covers($0.face, [face]) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mask {
                RetouchSlider(model: model, title: kind.title, value: Binding(get: { mask.strength }, set: { value in
                    model.edit { a in
                        for i in a.masks.indices where a.masks[i].portraitCorrection == kind && PortraitFace.covers(a.masks[i].face, [face]) { a.masks[i].strength = value }
                    }
                }), range: 0...2, gesture: true, resetTo: 1,
                              measure: { model.applyPortraitDetail(kind, faces: [face]) }, remove: { model.removePortraitCorrection(kind, faces: [face]) })
            } else {
                CorrectionRow(title: kind.title, button: L10n.tr("Auto")) { model.applyPortraitDetail(kind, faces: [face]) }
            }
            if kind == .eyes {
                // An action, not a value: Fix finds red pupils and neutralizes them; Remove takes that out.
                let on = model.adjustments.redEyeCorrection
                CorrectionRow(title: L10n.tr("Red eye"), note: model.isGroupPortrait ? L10n.tr("Whole photo") : nil, on: on,
                              button: on ? L10n.tr("Remove") : L10n.tr("Fix")) { model.toggleRedEyeCorrection() }
                if let report = model.redEyeReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let report = model.blemishReport { Text(report).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .font(.system(size: 12)).padding(14).frame(width: 240)
        .disabled(model.busy)
    }
}
