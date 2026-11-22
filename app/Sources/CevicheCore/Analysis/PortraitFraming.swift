import CoreGraphics
import CoreImage
import Vision

/// Crop's portrait framings: a crop around the largest face sized for how much of the person shows, with the eyes on
/// the upper third, the top of the head kept and room on the side the face is turned to.
public enum PortraitFraming: String, CaseIterable, Sendable {
    case closeUp, shoulders, waist
    public var localizedTitle: String {
        switch self {
        case .closeUp: return L10n.tr("Close-up")
        case .shoulders: return L10n.tr("Shoulders")
        case .waist: return L10n.tr("Waist")
        }
    }
    /// The crop's height in face heights (eyebrows to chin, Vision's face box).
    var faceHeights: Double {
        switch self {
        case .closeUp: return 2.6
        case .shoulders: return 4
        case .waist: return 7
        }
    }

    /// Where the face is, as points of the photo (normalized, origin bottom left), for `crop`.
    public struct Face: Sendable, Equatable {
        public var leftEye: MaskPoint, rightEye: MaskPoint, headTop: MaskPoint, chin: MaskPoint, nose: MaskPoint
        public init(leftEye: MaskPoint, rightEye: MaskPoint, headTop: MaskPoint, chin: MaskPoint, nose: MaskPoint) {
            self.leftEye = leftEye; self.rightEye = rightEye; self.headTop = headTop; self.chin = chin; self.nose = nose
        }
    }

    /// How far beside the outermost faces a group's crop reaches, in face heights: the heads, then the shoulders,
    /// then the arms.
    var groupMargin: Double {
        switch self {
        case .closeUp: return 0.6
        case .shoulders: return 1.1
        case .waist: return 1.5
        }
    }

    /// The crop for several people: tall enough for the framing at the largest face's size, wide enough for every
    /// face with `groupMargin` beside the outermost, the eyes' average on the upper third and every head's top kept.
    /// No lead room: a group faces every way. One face is `crop(for:plan:aspect:)`.
    public func crop(for faces: [Face], plan: GeometryPlan, aspect: Double) -> CropRect? {
        guard let first = faces.first else { return nil }
        guard faces.count > 1 else { return crop(for: first, plan: plan, aspect: aspect) }
        let full = plan.fullSize, cropRect = plan.cropPixels
        func place(_ p: MaskPoint) -> CGPoint {
            let d = plan.displayPoint(p)
            return CGPoint(x: cropRect.minX + d.x * cropRect.width, y: cropRect.minY + d.y * cropRect.height)
        }
        struct Placed { let eyes: CGPoint; let top: CGPoint; let chin: CGPoint; let height: Double }
        let placed = faces.map { face -> Placed in
            let one = place(face.leftEye), other = place(face.rightEye)
            let eyes = CGPoint(x: (one.x + other.x) / 2, y: (one.y + other.y) / 2), chin = place(face.chin)
            return Placed(eyes: eyes, top: place(face.headTop), chin: chin, height: max(1, hypot(eyes.x - chin.x, eyes.y - chin.y) * 1.6))
        }
        let unit = placed.map(\.height).max() ?? 1
        let left = placed.map { $0.eyes.x }.min()! - unit * groupMargin, right = placed.map { $0.eyes.x }.max()! + unit * groupMargin
        var height = unit * faceHeights, width = height * aspect
        if width < right - left { width = right - left; height = width / aspect }
        let fit = min(1, full.width / width, full.height / height)
        width *= fit; height *= fit
        let eyesY = placed.map { $0.eyes.y }.reduce(0, +) / Double(placed.count)
        let top = placed.map { $0.top.y + unit * 0.1 }.max()!
        var maxY = max(eyesY + height / 3, min(top, eyesY + height * 0.8))
        // Every chin inside too, when the frame is tall enough for both.
        let chin = placed.map { $0.chin.y }.min()! - unit * 0.15
        if maxY - height > chin { maxY = max(chin + height, top) }
        var minX = (left + right) / 2 - width / 2, minY = maxY - height
        minX = min(max(0, minX), full.width - width); minY = min(max(0, minY), full.height - height)
        return CropRect(x: minX / full.width, y: minY / full.height, width: width / full.width, height: height / full.height)
    }

    /// The crop, normalized to the corrected frame (`plan.fullSize`, origin bottom left) as `GeometryAdjustments.crop`
    /// is, with width ÷ height `aspect` in pixels. The face's points are placed through `plan`, so straighten, turns
    /// and flips already set are respected. When the framing doesn't fit, it is the largest that does, kept on the
    /// face.
    public func crop(for face: Face, plan: GeometryPlan, aspect: Double) -> CropRect {
        let full = plan.fullSize, crop = plan.cropPixels
        func place(_ p: MaskPoint) -> CGPoint {
            let d = plan.displayPoint(p)
            return CGPoint(x: crop.minX + d.x * crop.width, y: crop.minY + d.y * crop.height)
        }
        let one = place(face.leftEye), other = place(face.rightEye)
        let eyes = CGPoint(x: (one.x + other.x) / 2, y: (one.y + other.y) / 2), center = eyes
        let top = place(face.headTop), chin = place(face.chin), nose = place(face.nose)
        // Up in the frame: from chin to the top of the head (the photo may be turned).
        let faceHeight = max(1, hypot(eyes.x - chin.x, eyes.y - chin.y) * 1.6)
        var height = faceHeight * faceHeights, width = height * aspect
        // Larger than the frame: the largest that fits.
        let fit = min(1, full.width / width, full.height / height)
        width *= fit; height *= fit
        // Eyes on the upper third; the head's top kept with a little room above it.
        var maxY = eyes.y + height / 3
        maxY = max(maxY, min(top.y + faceHeight * 0.1, eyes.y + height * 0.8))
        // Turned clearly to one side: the face toward the third away from it, so it looks into the frame. A face
        // turned to the right of the picture shows its nose nearer the eye on that side.
        let (leftOfPicture, rightOfPicture) = one.x <= other.x ? (one, other) : (other, one)
        let toLeft = hypot(nose.x - leftOfPicture.x, nose.y - leftOfPicture.y), toRight = hypot(nose.x - rightOfPicture.x, nose.y - rightOfPicture.y)
        let turn = (toLeft - toRight) / max(1, toLeft + toRight)
        let offset = abs(turn) > 0.1 ? (turn > 0 ? -1.0 : 1.0) * width / 6 : 0
        var minX = center.x - width / 2 + offset
        var minY = maxY - height
        minX = min(max(0, minX), full.width - width); minY = min(max(0, minY), full.height - height)
        return CropRect(x: minX / full.width, y: minY / full.height, width: width / full.width, height: height / full.height)
    }
}

extension RawRenderer {
    /// The largest face's eyes, head top, chin, nose and middle, as points of the photo (Vision's landmarks on the
    /// photo as developed, before geometry). Nil without a face.
    public func portraitFace(_ settings: Adjustments) throws -> PortraitFraming.Face? {
        try portraitFramingFaces(settings).first?.face
    }
    /// Every face as `portraitFace` measures it, largest first, with Vision's box (normalized, origin bottom left) to
    /// tell them apart.
    public func portraitFramingFaces(_ settings: Adjustments) throws -> [(face: PortraitFraming.Face, box: CGRect)] {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.masks = []; base.postCropVignette = PostCropVignette()
        let image = try pipeline(base, maxDimension: 1600)
        let e = image.extent
        guard let cg = context.createCGImage(image, from: e, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw EditorError.render }
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let size = CGSize(width: cg.width, height: cg.height)
        let faces = (request.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        return faces.map { (Self.framingFace(of: $0, size: size), $0.boundingBox) }
    }
    private static func framingFace(of face: VNFaceObservation, size: CGSize) -> PortraitFraming.Face {
        func normalized(_ p: CGPoint) -> MaskPoint { MaskPoint(x: p.x / size.width, y: p.y / size.height) }
        func middle(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.pointsInImage(imageSize: size), !points.isEmpty else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        let b = face.boundingBox
        let box = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
        let landmarks = face.landmarks
        let left = middle(landmarks?.leftPupil) ?? middle(landmarks?.leftEye) ?? CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.62)
        let right = middle(landmarks?.rightPupil) ?? middle(landmarks?.rightEye) ?? CGPoint(x: box.minX + box.width * 0.7, y: box.minY + box.height * 0.62)
        let eyes = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        // The face box runs from the brows to the chin, so the line from the eyes to the chin, carried on up past the
        // brows, finds the top of the head: about one face box above the eyes.
        let chin = CGPoint(x: box.midX, y: box.minY)
        let up = CGPoint(x: eyes.x - chin.x, y: eyes.y - chin.y)
        let headTop = CGPoint(x: eyes.x + up.x * 1.25, y: eyes.y + up.y * 1.25)
        // The nose's tip: the lowest point of its crest, below the bridge.
        let crest = landmarks?.noseCrest?.pointsInImage(imageSize: size) ?? []
        let nose = crest.min { $0.y < $1.y } ?? middle(landmarks?.nose) ?? CGPoint(x: box.midX, y: box.midY)
        return PortraitFraming.Face(leftEye: normalized(left), rightEye: normalized(right), headTop: normalized(headTop), chin: normalized(chin), nose: normalized(nose))
    }
}
