import SwiftUI
import CevicheCore

/// View-only composition aids; they never become part of a saved edit.
enum CropOverlay: String, CaseIterable {
    var localizedTitle: String { L10n.key(rawValue) }

    case grid = "Grid", thirds = "Thirds", diagonal = "Diagonal", triangle = "Triangle", goldenRatio = "Golden Ratio", goldenSpiral = "Golden Spiral"
    var orientations: Int { self == .triangle ? 2 : self == .goldenSpiral ? 4 : 1 }
    func lines(in rect: CGRect, orientation: Int) -> [[CGPoint]] {
        let w = rect.width, h = rect.height
        func vertical(_ t: Double) -> [CGPoint] { [CGPoint(x: w * t, y: 0), CGPoint(x: w * t, y: h)] }
        func horizontal(_ t: Double) -> [CGPoint] { [CGPoint(x: 0, y: h * t), CGPoint(x: w, y: h * t)] }
        var lines: [[CGPoint]] = []
        switch self {
        case .grid:
            let step = max(w, h) / 12
            guard step > 0 else { return [] }
            for x in stride(from: step, to: w, by: step) { lines.append([CGPoint(x: x, y: 0), CGPoint(x: x, y: h)]) }
            for y in stride(from: step, to: h, by: step) { lines.append([CGPoint(x: 0, y: y), CGPoint(x: w, y: y)]) }
        case .thirds: lines = [vertical(1 / 3), vertical(2 / 3), horizontal(1 / 3), horizontal(2 / 3)]
        case .goldenRatio: lines = [vertical(0.382), vertical(0.618), horizontal(0.382), horizontal(0.618)]
        case .diagonal:
            let d = min(w, h)
            lines = [[.zero, CGPoint(x: d, y: d)], [CGPoint(x: w, y: 0), CGPoint(x: w - d, y: d)],
                     [CGPoint(x: 0, y: h), CGPoint(x: d, y: h - d)], [CGPoint(x: w, y: h), CGPoint(x: w - d, y: h - d)]]
        case .triangle:
            func foot(_ x: Double, _ y: Double) -> CGPoint { let t = (x * w + y * h) / (w * w + h * h); return CGPoint(x: t * w, y: t * h) }
            lines = [[.zero, CGPoint(x: w, y: h)], [CGPoint(x: w, y: 0), foot(w, 0)], [CGPoint(x: 0, y: h), foot(0, h)]]
        case .goldenSpiral:
            // Successive golden rectangles, each contributing a quarter-circle.
            let phi = (1 + sqrt(5.0)) / 2
            var x = 0.0, y = 0.0, rw = phi, rh = 1.0
            for i in 0..<10 {
                let side: Double, center: CGPoint, start: Double
                switch i % 4 {
                case 0: side = rh; center = CGPoint(x: x + side, y: y + side); start = .pi; x += side; rw -= side
                case 1: side = rw; center = CGPoint(x: x, y: y + side); start = -.pi / 2; y += side; rh -= side
                case 2: side = rh; center = CGPoint(x: x + rw - side, y: y); start = 0; rw -= side
                default: side = rw; center = CGPoint(x: x + side, y: y + rh - side); start = .pi / 2; rh -= side
                }
                lines.append((0...24).map { j in let a = start + Double(j) / 24 * .pi / 2; return CGPoint(x: (center.x + side * cos(a)) * w / phi, y: (center.y + side * sin(a)) * h) })
            }
        }
        let turn = orientation % orientations
        return lines.map { $0.map { CGPoint(x: rect.minX + (turn % 2 == 1 ? w - $0.x : $0.x), y: rect.minY + (turn >= 2 ? h - $0.y : $0.y)) } }
    }
}
enum CropOverlayVisibility: String, CaseIterable {
    case always = "Always", auto = "Auto", never = "Never"
    var localizedTitle: String { L10n.key(rawValue) }
}

extension EditorModel {
    static func fittingAspect(_ ratio: Double, around crop: CropRect) -> CropRect {
        guard ratio.isFinite, ratio > 0 else { return crop }
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        var width = sqrt(crop.width * crop.height * ratio), height = width / ratio
        let scale = min(1, min(2 * min(cx, 1 - cx) / width, 2 * min(cy, 1 - cy) / height))
        width *= scale; height *= scale
        guard width >= 0.01, height >= 0.01 else { return crop }
        return CropRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }
    func swapCropAspect() {
        guard let plan = geometryPlan else { return }
        if adjustments.geometry.aspect != .free { setCropPortrait(!adjustments.geometry.portrait); return }
        let crop = adjustments.geometry.crop
        let ratio = crop.width * plan.fullSize.width / (crop.height * plan.fullSize.height)
        edit { $0.geometry.crop = Self.fittingAspect(plan.fullSize.height / (ratio * plan.fullSize.width), around: crop); $0.geometry.portrait.toggle() }
    }
    func flipCrop(horizontal: Bool) {
        edit { value in
            value.geometry.transform.flip(horizontal: horizontal)
            if horizontal { value.geometry.crop.x = 1 - value.geometry.crop.x - value.geometry.crop.width; value.geometry.flipHorizontal.toggle() }
            else { value.geometry.crop.y = 1 - value.geometry.crop.y - value.geometry.crop.height; value.geometry.flipVertical.toggle() }
        }
    }
    func toggleGuideDrawing() {
        cropStraightening = false; comparing = false; guideDraft = nil; guideMessage = nil
        cropPlacingCorners = false; cornerDraft = nil
        cropDrawingGuide.toggle()
        if cropDrawingGuide { viewport.fit() } else { focusCrop() }
    }
    func toggleStraightenRuler() { cropDrawingGuide = false; guideDraft = nil; cropPlacingCorners = false; cornerDraft = nil; comparing = false; cropStraightening.toggle() }
    func deleteSelectedGuide() {
        guard let id = selectedGuideID else { return }
        if guideDraft?.id == id { guideDraft = nil }
        edit { $0.geometry.guides.removeAll { $0.id == id } }; selectedGuideID = nil; guideMessage = nil
    }
    func clearGuides() { edit { $0.geometry.guides = [] }; guideDraft = nil; selectedGuideID = nil; guideMessage = nil }
    func cycleCropOverlay(reverseOrientation: Bool = false) {
        if reverseOrientation { cropOverlayOrientation = (cropOverlayOrientation + 1) % cropOverlay.orientations }
        else { cropOverlay = CropOverlay.allCases[(CropOverlay.allCases.firstIndex(of: cropOverlay)! + 1) % CropOverlay.allCases.count]; cropOverlayOrientation = 0 }
    }
    /// Canvas coordinates have y downward. The nearer horizontal/vertical direction wins.
    static func rulerCorrection(from a: CGPoint, to b: CGPoint) -> Double {
        var degrees = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        degrees -= (degrees / 90).rounded() * 90
        return -degrees
    }
    func straightenAlong(from a: CGPoint, to b: CGPoint) {
        guard hypot(b.x - a.x, b.y - a.y) >= 10 else { return }
        let mirror = adjustments.geometry.flipHorizontal != adjustments.geometry.flipVertical
        setStraighten(min(45, max(-45, adjustments.geometry.straighten + Self.rulerCorrection(from: a, to: b) * (mirror ? -1 : 1))))
        cropStraightening = false
    }
    /// Straighten so the line through the eyes of the largest face is level: for a portrait whose camera was tilted.
    func levelEyes() {
        guard let renderer, !autoStraightening, !busy else { return }
        autoStraightening = true; guideMessage = nil
        let snapshot = adjustments
        Task {
            defer { autoStraightening = false }
            do {
                var settings = snapshot
                settings.geometry = GeometryAdjustments()
                settings.geometry.flipHorizontal = snapshot.geometry.flipHorizontal
                settings.geometry.flipVertical = snapshot.geometry.flipVertical
                let result = try await renderer.preview(settings, sdr: true)
                let correction = try await renderer.eyeCorrection(for: result.image)
                guard self.renderer === renderer, adjustments.geometry == snapshot.geometry, adjustments.quarterTurns == snapshot.quarterTurns else { return }
                guard let correction else { guideMessage = L10n.tr("No eyes found. Use the ruler instead."); return }
                let mirror = snapshot.geometry.flipHorizontal != snapshot.geometry.flipVertical
                setStraighten(correction * (mirror ? -1 : 1))
            } catch { if self.renderer === renderer { guideMessage = error.localizedDescription } }
        }
    }
    func autoStraighten() {
        guard let renderer, !autoStraightening, !busy else { return }
        autoStraightening = true; guideMessage = nil
        let snapshot = adjustments
        Task {
            defer { autoStraightening = false }
            do {
                var settings = snapshot
                settings.geometry = GeometryAdjustments()
                settings.geometry.flipHorizontal = snapshot.geometry.flipHorizontal
                settings.geometry.flipVertical = snapshot.geometry.flipVertical
                let result = try await renderer.preview(settings, sdr: true)
                let correction = await Task.detached(priority: .utility) { StraightenEstimator.correction(for: result.image) }.value
                guard self.renderer === renderer, adjustments.geometry == snapshot.geometry, adjustments.quarterTurns == snapshot.quarterTurns else { return }
                guard let correction else { guideMessage = L10n.tr("No clear level or vertical edges found. Use the ruler instead."); return }
                let mirror = snapshot.geometry.flipHorizontal != snapshot.geometry.flipVertical
                setStraighten(correction * (mirror ? -1 : 1))
            } catch { if self.renderer === renderer { guideMessage = error.localizedDescription } }
        }
    }
}

/// Perspective crop: four corners dragged onto a work photographed at an angle, which the edit pulls square.
extension EditorModel {
    /// Picks the corners up or puts them down. The first time on a photo they start on the rectangle found in it.
    func togglePerspectiveCorners() {
        cropStraightening = false; comparing = false; guideDraft = nil; guideMessage = nil; cornerDraft = nil
        if cropDrawingGuide { cropDrawingGuide = false }
        if cropPlacingCorners { cropPlacingCorners = false; focusCrop(); return }
        if adjustments.geometry.perspective == nil {
            var candidate = adjustments.geometry
            candidate.perspective = PerspectiveCrop(); candidate.uprightMode = .off; candidate.crop = .full
            guard apply(candidate) else { return }
            detectPerspectiveCorners()
        }
        cropPlacingCorners = true
    }
    /// A dragged corner let go: kept when the four still make a quadrilateral.
    func acceptCorners() {
        guard let draft = cornerDraft, var perspective = adjustments.geometry.perspective else { cornerDraft = nil; return }
        defer { cornerDraft = nil }
        perspective.corners = draft
        guard perspective.isValid else { guideMessage = L10n.tr("The corners cross: drag them into a quadrilateral"); return }
        var candidate = adjustments.geometry; candidate.perspective = perspective
        if apply(candidate) { guideMessage = nil }
    }
    func setPerspectiveProportion(_ proportion: PerspectiveProportion) {
        var candidate = adjustments.geometry
        candidate.perspective?.proportion = proportion
        if apply(candidate) { guideMessage = nil }
    }
    func resetPerspectiveCorners() {
        var candidate = adjustments.geometry
        candidate.perspective?.corners = PerspectiveCrop.inset
        guideMessage = nil
        apply(candidate); detectPerspectiveCorners()
    }
    func removePerspective() {
        cornerDraft = nil; guideMessage = nil
        var candidate = adjustments.geometry
        candidate.perspective = nil; candidate.crop = .full
        apply(candidate)
        cropPlacingCorners = false
    }
    /// Looks for a rectangle in the photo as displayed, without its geometry, and moves corners still on the inset
    /// frame onto it. No undo step of its own: it completes the one that placed the frame.
    private func detectPerspectiveCorners() {
        guard let renderer, let info, !detectingCorners else { return }
        detectingCorners = true
        let snapshot = adjustments
        Task {
            defer { detectingCorners = false }
            var settings = snapshot
            settings.geometry = GeometryAdjustments()
            settings.geometry.flipHorizontal = snapshot.geometry.flipHorizontal
            settings.geometry.flipVertical = snapshot.geometry.flipVertical
            guard let result = try? await renderer.preview(settings, sdr: true),
                  let plan = try? GeometryPlan(size: CGSize(width: info.width, height: info.height), settings: settings.geometry, quarterTurns: settings.quarterTurns) else { return }
            let found = await Task.detached(priority: .userInitiated) { PerspectiveCrop.detect(in: result.image) }.value
            guard self.renderer === renderer, adjustments.geometry.perspective?.corners == PerspectiveCrop.inset else { return }
            guard let found else { guideMessage = L10n.tr("No rectangle found: drag the corners onto the work"); return }
            let corners = found.map { let p = plan.sourcePoint($0); return MaskPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y))) }
            guard PerspectiveCrop(corners: corners).isValid else { return }
            editSilently { if $0.geometry.perspective?.corners == PerspectiveCrop.inset { $0.geometry.perspective?.corners = corners } }
        }
    }
}
