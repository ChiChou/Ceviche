import AppKit
import CevicheCore

extension ImageCanvas {
    /// Reshape Face shows the face's handles alone: the frame they are measured in is placed from the face's
    /// landmarks and never drawn or dragged, so the handles can't be pulled off their features.
    enum FaceRegionDrag {
        /// A Face Liquify handle: where the pointer went down, the amounts then, and each axis on the canvas.
        case liquify(start: CGPoint, axes: [(path: WritableKeyPath<FaceLiquify, Double>, start: Double, vector: CGVector)])
    }

    /// The Face Liquify handles shown, once Face Liquify is on.
    private func liquifyHandles(_ model: EditorModel) -> [FaceLiquify.Handle] {
        guard model.showingLiquify || model.reshapeWarp != nil, model.currentFaceRegion != nil, let info = model.info, info.height > 0 else { return [] }
        return model.liquify.handles(aspect: Double(info.width) / Double(info.height))
    }

    /// A handle's drag on the canvas: how far the pointer travels for one unit of each control. The face itself moves
    /// only a few points at full strength, which would put the whole range within a twitch, so a unit is at least 30
    /// points. The handle is still drawn where its feature has moved to, so it never leaves the face; it lags the
    /// pointer while dragged.
    private static let unitTravel = 30.0
    private func canvasAxes(_ handle: FaceLiquify.Handle) -> (base: CGPoint, axes: [(path: WritableKeyPath<FaceLiquify, Double>, vector: CGVector)]) {
        let base = sourceCanvasPoint(handle.base)
        return (base, handle.axes.map { axis in
            let end = sourceCanvasPoint(MaskPoint(x: handle.base.x + axis.delta.x, y: handle.base.y + axis.delta.y))
            var v = CGVector(dx: end.x - base.x, dy: end.y - base.y)
            let length = hypot(v.dx, v.dy)
            if length > 0, length < Self.unitTravel { v = CGVector(dx: v.dx / length * Self.unitTravel, dy: v.dy / length * Self.unitTravel) }
            return (axis.path, v)
        })
    }
    /// Where the handle's feature is now, after the warp.
    private func canvasPosition(_ handle: FaceLiquify.Handle, _ warp: FaceLiquify) -> CGPoint {
        sourceCanvasPoint(warp.position(of: handle))
    }

    /// What a press at `point` would grab: a Face Liquify handle, or nothing.
    private enum FaceRegionPart { case handle(FaceLiquify.Handle), outside }
    private func faceRegionPart(at point: CGPoint, model: EditorModel) -> FaceRegionPart {
        guard model.currentFaceRegion != nil else { return .outside }
        let warp = model.liquify
        let near = liquifyHandles(model).map { ($0, canvasPosition($0, warp)) }
            .filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= 9 }
            .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
        if let (handle, _) = near { return .handle(handle) }
        return .outside
    }

    func faceRegionCursor(at point: CGPoint, model: EditorModel) -> NSCursor {
        if faceRegionDrag != nil { return .closedHand }
        switch faceRegionPart(at: point, model: model) {
        case .handle(let handle):
            // The pointer says which way the handle goes.
            if handle.axes.allSatisfy({ $0.delta.y == 0 }) { return .resizeLeftRight }
            if handle.axes.allSatisfy({ $0.delta.x == 0 }) { return .resizeUpDown }
            return .openHand
        case .outside: return .arrow
        }
    }

    /// A press on the face's handles; a double-click on one puts its controls back to nothing changed.
    func beginFaceRegion(at point: CGPoint, model: EditorModel, clickCount: Int = 1) {
        switch faceRegionPart(at: point, model: model) {
        case .handle(let handle) where clickCount == 2:
            model.setLiquify(handle.axes.map { ($0.path, 0) })
        case .handle(let handle):
            let warp = model.liquify
            faceRegionDrag = .liquify(start: point, axes: canvasAxes(handle).axes.map { ($0.path, warp[keyPath: $0.path], $0.vector) })
            model.beginGesture()
            NSCursor.closedHand.set()
        case .outside:
            // A click away from the handles leaves them, as a click outside a text field ends its editing.
            if model.currentFaceRegion != nil { model.portraitTool = .photo; NSCursor.arrow.set() }
        }
    }

    func dragFaceRegion(to point: CGPoint, model: EditorModel) {
        guard let drag = faceRegionDrag else { return }
        if case .liquify(let start, let axes) = drag {
            // The pointer's travel along each axis, in units of the handle's travel for an amount of 1.
            let travel = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            model.setLiquify(axes.map { axis in
                let length = axis.vector.dx * axis.vector.dx + axis.vector.dy * axis.vector.dy
                return (axis.path, length > 0 ? axis.start + (travel.dx * axis.vector.dx + travel.dy * axis.vector.dy) / length : axis.start)
            })
            return
        }
    }

    /// The face's handles, without the frame they are measured in.
    func drawFaceRegion(_ rect: CGRect) {
        if let model {
            let warp = model.liquify
            for handle in liquifyHandles(model) {
                let p = canvasPosition(handle, warp)
                let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                // Eye size is a ring at the eye's corner; every other handle is a dot on its feature.
                if handle.axes.contains(where: { $0.path == \FaceLiquify.eyeSize }) {
                    NSColor.black.withAlphaComponent(0.6).setStroke(); dot.lineWidth = 3.5; dot.stroke()
                    Theme.nsAccent.setStroke(); dot.lineWidth = 2; dot.stroke()
                } else {
                    Theme.nsAccent.setFill(); dot.fill()
                    NSColor.white.setStroke(); dot.lineWidth = 1; dot.stroke()
                }
            }
        }
    }
}
