import Foundation

/// The edit decisions Masks makes the same on every platform: what a new mask or part starts as, where a selection
/// goes, and how a mask's own adjustments are read and written through the global controls. The apps keep which mask
/// is selected and the tool held; every change to the edit goes through here.

extension MaskKind {
    /// Masks computed from the whole photo when added (Object instead waits for a click).
    public static let generatedOnPhoto: Set<MaskKind> = [.subject, .background, .sky, .depth, .scene, .people]
    /// Linear and radial: created where the first line is drawn on the photo, not when chosen.
    public var isGradient: Bool { self == .linear || self == .radial }
}

/// Where an accepted selection went: a mask of its own, or a component of an existing mask.
public enum MaskPlacement: Equatable, Sendable {
    case mask(UUID)
    case component(UUID, parent: UUID)
    /// The mask to select once the selection is in.
    public var maskID: UUID { switch self { case .mask(let id): return id; case .component(_, let parent): return parent } }
    /// The component to select, nil for a mask of its own.
    public var componentID: UUID? { if case .component(let id, _) = self { return id }; return nil }
}

extension PhotoMask {
    /// A mask of a kind as Masks adds it. A brush starts hard-edged: its strokes carry their own softness, and a feather
    /// on top would blur every stroke again.
    public static func new(_ kind: MaskKind) -> PhotoMask {
        var mask = PhotoMask(kind: kind)
        if kind == .brush { mask.feather = 0 }
        return mask
    }
    /// A gradient started at a point: both ends there, so the drag that follows draws it. A radial one is soft-edged.
    public static func gradient(_ kind: MaskKind, at point: MaskPoint) -> PhotoMask {
        var mask = new(kind)
        if kind == .radial { mask.feather = 0.125 }
        mask.start = point; mask.end = point
        return mask
    }
    /// What the Light, Color and Detail controls show for the mask: its own adjustments over neutral ones.
    public var targetAdjustments: Adjustments { adjustments.applying(to: Adjustments()) }
    /// Changes the mask's adjustments through the global controls; only what a mask takes is kept.
    public mutating func editTarget(_ update: (inout Adjustments) -> Void) {
        var local = targetAdjustments
        update(&local)
        adjustments = local.pixels
    }
}

extension MaskSelection {
    /// A gradient too short to have been drawn: a click or tap without a drag.
    public var isUndrawnGradient: Bool {
        kind.isGradient && hypot(end.x - start.x, end.y - start.y) < 0.005
    }
    /// A gradient drawn from where the drag began to `point`. A linear one ends at the point; a radial one is centred
    /// where the drag began and reaches the point. `constrained` (Shift) snaps a line to 45° steps and keeps an
    /// ellipse a circle.
    public mutating func drawGradient(from origin: MaskPoint, to point: MaskPoint, constrained: Bool = false) {
        if kind == .radial {
            var dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
            if constrained { dx = max(dx, dy); dy = dx }
            start = MaskPoint(x: origin.x - dx, y: origin.y - dy); end = MaskPoint(x: origin.x + dx, y: origin.y + dy)
        } else {
            end = constrained && kind == .linear ? point.constrainedToCardinal(from: origin) : point
        }
    }
}

extension Adjustments {
    /// Another mask fits on the photo.
    public var canAddMask: Bool { masks.count < PhotoMask.maxCount }
    /// Another component fits on the mask.
    public func canAddComponent(to maskID: UUID) -> Bool {
        masks.first { $0.id == maskID }.map { $0.components.count < PhotoMask.maxComponents } ?? false
    }
    /// Takes a new selection. With an operation and a parent it joins that mask as a component; an inverted mask keeps
    /// what it showed, its inversion moving to its base before the first part joins. Without an operation it becomes
    /// a mask of its own, named after its kind and numbered from the second of a kind ("Subject 2"). Nil when the
    /// photo or mask is full, or the parent is gone.
    @discardableResult
    public mutating func acceptSelection(_ mask: PhotoMask, operation: MaskOperation?, parentID: UUID?) -> MaskPlacement? {
        if let operation, let parentID {
            guard let index = masks.firstIndex(where: { $0.id == parentID }), masks[index].components.count < PhotoMask.maxComponents else { return nil }
            let component = MaskComponent(operation: operation, selection: mask.selection)
            if masks[index].components.isEmpty && masks[index].inverted {
                masks[index].selection.inverted.toggle(); masks[index].inverted = false
            }
            masks[index].components.append(component)
            return .component(component.id, parent: parentID)
        }
        guard operation == nil, canAddMask else { return nil }
        var mask = mask
        let count = masks.filter { $0.kind == mask.kind }.count
        if count > 0 { mask.name += " \(count + 1)" }
        masks.append(mask)
        return .mask(mask.id)
    }
    /// What Light, Color and Detail show: the photo's adjustments, or a mask's over neutral ones.
    public func target(_ maskID: UUID?) -> Adjustments {
        masks.first { $0.id == maskID }?.targetAdjustments ?? self
    }
    /// Changes what Light, Color and Detail edit: a mask's own adjustments, or the photo's when no mask is the target.
    public mutating func editTarget(_ maskID: UUID?, _ update: (inout Adjustments) -> Void) {
        if let index = masks.firstIndex(where: { $0.id == maskID }) { masks[index].editTarget(update) } else { update(&self) }
    }
}

extension RawRenderer {
    /// The color Color Range selects at a point: one pixel of the developed photo, so a mask selects the same
    /// wherever it was made.
    public func maskColor(at point: MaskPoint, adjustments: Adjustments) throws -> [Double] {
        try sampleColor(at: point, adjustments: adjustments, radius: 0)
    }
}
