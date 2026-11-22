import CoreImage
import Vision

/// Face-aware reshaping: bounded inverse warps placed on the face's features, all in one pass. Positions are in the
/// normalized y-up frame of retouch strokes; the features are stored as fractions of `region`, so moving or resizing
/// the region carries them along. Every amount runs −1…1; negative makes smaller, narrower or lower.
public struct FaceLiquify: Codable, Equatable, Sendable {
    public var region: CGRect
    public var features = Features()
    /// Face width, at the cheeks. Stored as `width`, the key of the first version's only control.
    public var width = 0.0
    public var jawline = 0.0, chinHeight = 0.0, forehead = 0.0
    public var eyeSize = 0.0, eyeDistance = 0.0
    public var noseWidth = 0.0
    public var mouthWidth = 0.0, smile = 0.0

    /// Where the features sit, as fractions of the region, y up (0 at its bottom edge). The defaults are the usual
    /// proportions of a frontal face in the region Vision's box gives, for a region drawn by hand.
    public struct Features: Codable, Equatable, Sendable {
        public var leftEye = MaskPoint(x: 0.3, y: 0.62), rightEye = MaskPoint(x: 0.7, y: 0.62)
        /// Reach of the eye controls, as a fraction of the region's width.
        public var eyeRadius = 0.12
        /// The nostrils' centre, and the nose's width as a fraction of the region's width.
        public var nose = MaskPoint(x: 0.5, y: 0.4), noseSpan = 0.2
        public var mouthLeft = MaskPoint(x: 0.36, y: 0.24), mouthRight = MaskPoint(x: 0.64, y: 0.24)
        /// Heights of the brow line and the chin.
        public var brow = 0.75, chin = 0.06
        /// The face's pose, measured from its landmarks; nil (a region drawn by hand) is upright and facing the camera, as a region drawn by hand. `angle` is how far the face's up direction leans from the
        /// photo's, in radians, counterclockwise. `turn` runs −1 (a profile facing the photo's left) to 1. The edges
        /// are the cheeks' outer edges at the cheek row, as distances from the nose across the upright face, in
        /// fractions of the region's width.
        public var angle: Double?, turn: Double?, leftEdge: Double?, rightEdge: Double?
        /// The far side's jawline in a turned face, from the cheek row down to the chin, with a point on it between
        /// (fractions of the region, as the other features): the jaw control pulls across it there.
        public var jawFrom: MaskPoint?, jawMid: MaskPoint?, jawTo: MaskPoint?
        public init() {}
        public static func == (a: Features, b: Features) -> Bool {
            a.leftEye == b.leftEye && a.rightEye == b.rightEye && a.eyeRadius == b.eyeRadius && a.nose == b.nose && a.noseSpan == b.noseSpan
                && a.mouthLeft == b.mouthLeft && a.mouthRight == b.mouthRight && a.brow == b.brow && a.chin == b.chin && a.angle == b.angle
                && a.turn == b.turn && a.leftEdge == b.leftEdge && a.rightEdge == b.rightEdge && a.jawFrom == b.jawFrom && a.jawMid == b.jawMid && a.jawTo == b.jawTo
        }
        /// How far the jaw control follows the jawline instead of pulling straight in: none facing the camera, all of
        /// it in profile.
        var jawFollow: Double {
            guard jawFrom != nil, jawMid != nil, jawTo != nil else { return 0 }
            let u = min(1, max(0, (abs(pose.turn) - 0.2) / 0.5)); return u * u * (3 - 2 * u)
        }
        /// A side's cheek edge as it scales the cheek control, kept short of the ear in a turned face.
        static func cheekScale(_ edge: Double) -> Double { min(1.25, edge / frontalEdge) }
        /// The pose with nothing measured filled in.
        var pose: (angle: Double, turn: Double, left: Double, right: Double) {
            (angle ?? 0, turn ?? 0, leftEdge ?? Self.frontalEdge, rightEdge ?? Self.frontalEdge)
        }
        /// The cheek's edge in a facing region: the region is 1.24 times the cheeks' span.
        static let frontalEdge = 0.5 / 1.24
        /// How much a side's cheek and jaw controls act: the side the face is turned toward is seen edge on, where
        /// pulling it in would bend the nose and lips, so it fades out as the head turns.
        func sideWeights() -> (left: Double, right: Double) {
            let t = pose.turn
            func fade(_ x: Double) -> Double { let u = min(1, max(0, (x - 0.2) / 0.5)); return 1 - u * u * (3 - 2 * u) }
            return (t < 0 ? fade(-t) : 1, t > 0 ? fade(t) : 1)
        }
        /// How much each eye's controls act: in a profile the far eye is hidden behind the nose, and Vision still
        /// places one there.
        func eyeWeights() -> (left: Double, right: Double) {
            let t = pose.turn
            func fade(_ x: Double) -> Double { let u = min(1, max(0, (x - 0.45) / 0.3)); return 1 - u * u * (3 - 2 * u) }
            return (t < 0 ? fade(-t) : 1, t > 0 ? fade(t) : 1)
        }
        var valid: Bool {
            [leftEye, rightEye, nose, mouthLeft, mouthRight].allSatisfy { (-0.5...1.5).contains($0.x) && (-0.5...1.5).contains($0.y) }
                && (0.01...0.5).contains(eyeRadius) && (0.01...1).contains(noseSpan) && (-0.5...1.5).contains(brow) && (-0.5...1.5).contains(chin)
                && (-Double.pi...Double.pi).contains(angle ?? 0) && (-1...1).contains(turn ?? 0)
                && (0.01...1.5).contains(leftEdge ?? 0.5) && (0.01...1.5).contains(rightEdge ?? 0.5)
                && [jawFrom, jawMid, jawTo].allSatisfy { p in p.map { (-0.5...1.5).contains($0.x) && (-0.5...1.5).contains($0.y) } ?? true }
        }
    }

    public init(region: CGRect, features: Features = Features(), width: Double = 0) {
        self.region = region; self.features = features; self.width = width
    }

    /// Every control, for panels and checks.
    public static let amounts: [WritableKeyPath<FaceLiquify, Double>] = [\.eyeSize, \.eyeDistance, \.noseWidth, \.mouthWidth, \.smile, \.forehead, \.chinHeight, \.jawline, \.width]
    public var isIdentity: Bool { Self.amounts.allSatisfy { self[keyPath: $0] == 0 } }

    var valid: Bool {
        region.width >= 0.01 && region.height >= 0.01 && region.minX >= 0 && region.minY >= 0 &&
        region.maxX <= 1.000001 && region.maxY <= 1.000001 && features.valid && Self.amounts.allSatisfy { (-1...1).contains(self[keyPath: $0]) }
    }

    /// A point on the face that drags its controls: where it sits with nothing changed, and how far one whole unit of
    /// each control moves it, in the normalized y-up frame of the photo. Dragging projects the pointer's travel on
    /// each axis, so the handle follows the pointer while the photo moves under it.
    public struct Handle: Sendable {
        public enum Part: Sendable { case eye, nose, mouth, shape }
        public var part: Part
        public var base: MaskPoint
        public var axes: [(path: WritableKeyPath<FaceLiquify, Double>, delta: MaskPoint)]
    }

    /// Every handle, for a photo `aspect` (width over height) wide. The deltas are how far the kernel moves the
    /// content at the handle for an amount of 1, so a handle stays on its feature as it is dragged. They are laid out
    /// across the upright face and turned with it; a control that does nothing on this face (the far eye of a profile,
    /// the cheek it is turned toward) has no handle.
    public func handles(aspect: Double) -> [Handle] {
        let w = region.width, h = region.height, f = features, pose = f.pose
        // Upright frame: pixel-proportioned (x scaled by the aspect), turned about the region's centre.
        let c = MaskPoint(x: region.midX, y: region.midY)
        let cs = cos(pose.angle), sn = sin(pose.angle)
        func turned(_ v: MaskPoint) -> MaskPoint {
            let x = v.x * aspect, y = v.y
            return MaskPoint(x: (x * cs - y * sn) / aspect, y: x * sn + y * cs)
        }
        func upright(_ p: MaskPoint) -> MaskPoint {
            let x = (p.x - c.x) * aspect, y = p.y - c.y
            return MaskPoint(x: c.x + (x * cs + y * sn) / aspect, y: c.y - x * sn + y * cs)
        }
        func place(_ p: MaskPoint) -> MaskPoint { let d = turned(MaskPoint(x: p.x - c.x, y: p.y - c.y)); return MaskPoint(x: c.x + d.x, y: c.y + d.y) }
        func at(_ u: Double, _ v: Double) -> MaskPoint { MaskPoint(x: region.minX + u * w, y: region.minY + v * h) }
        func at(_ p: MaskPoint) -> MaskPoint { at(p.x, p.y) }
        var result: [Handle] = []
        func add(_ part: Handle.Part, _ base: MaskPoint, _ axes: [(WritableKeyPath<FaceLiquify, Double>, MaskPoint)]) {
            result.append(Handle(part: part, base: place(base), axes: axes.map { ($0.0, turned($0.1)) }))
        }
        let eyes = [upright(at(f.leftEye)), upright(at(f.rightEye))]
        let mid = (eyes[0].x + eyes[1].x) / 2, r = f.eyeRadius * w, eyeWeights = f.eyeWeights()
        for (eye, weight) in zip(eyes, [eyeWeights.left, eyeWeights.right]) where weight > 0.5 {
            let side = eye.x < mid ? -1.0 : 1.0
            // At the eye's outer corner, clear of the centre handle: 0.7 of the reach, where the scale moves content
            // by 0.3 × bump(0.7) = 0.3 × 0.26 of the distance.
            add(.eye, MaskPoint(x: eye.x + side * r * 0.7, y: eye.y), [(\.eyeSize, MaskPoint(x: side * r * 0.7 * 0.3 * 0.2601, y: 0))])
            add(.eye, eye, [(\.eyeDistance, MaskPoint(x: side * r * 0.3, y: 0))])
        }
        let nose = upright(at(f.nose)), span = f.noseSpan * w / 2
        for side in [-1.0, 1.0] {
            // The nostril's edge sits at 1/1.6 of the ellipse, where bump is 0.37.
            add(.nose, MaskPoint(x: nose.x + side * span, y: nose.y), [(\.noseWidth, MaskPoint(x: side * span * 0.3 * 0.37, y: 0))])
        }
        let left = upright(at(f.mouthLeft)), right = upright(at(f.mouthRight)), spread = abs(right.x - left.x) / 2
        for (corner, side) in [(left, -1.0), (right, 1.0)] {
            // Width at the corner (1/1.5 of the ellipse, bump 0.31); the smile lifts it by 0.3 of the half width,
            // measured in pixels, so in y it is scaled by the photo's shape.
            add(.mouth, corner, [(\.mouthWidth, MaskPoint(x: side * spread * 0.3 * 0.31, y: 0)), (\.smile, MaskPoint(x: 0, y: spread * 0.3 * aspect))])
        }
        // The cheek and jaw shifts fade within their own travel: these are where content from the handle lands
        // (δ = peak × (1 − (δ / reach)²)², solved for a peak of 0.08 over 0.18 and 0.06 over 0.16 on a facing face,
        // scaled with the side's edge).
        // A region drawn by hand keeps its controls about its middle.
        let sides = f.sideWeights(), noseU = f.turn == nil ? 0.5 : (nose.x - region.minX) / w
        let follow = f.jawFollow, farSide = pose.turn < 0 ? 1.0 : -1.0
        for (side, edge, weight) in [(-1.0, pose.left, sides.left), (1.0, pose.right, sides.right)] where weight > 0.5 {
            let scale = edge / FaceLiquify.Features.frontalEdge, cheek = FaceLiquify.Features.cheekScale(edge)
            add(.shape, at(noseU + side * 0.32 * cheek, 0.35), [(\.width, MaskPoint(x: side * 0.0621 * cheek * w, y: 0))])
            if side == farSide, follow > 0.5, let a = f.jawFrom, let b = f.jawTo, let m = f.jawMid {
                // On the jawline itself, moving across it: the line's normal toward the nose, in pixel proportions.
                let from = upright(at(a)), to = upright(at(b)), mid = upright(at(m))
                var n = MaskPoint(x: -(to.y - from.y) / aspect, y: (to.x - from.x) * aspect)
                let length = max(1e-6, hypot(n.x * aspect, n.y))
                n = MaskPoint(x: n.x / length, y: n.y / length)
                if (nose.x - mid.x) * n.x * aspect * aspect + (nose.y - mid.y) * n.y < 0 { n = MaskPoint(x: -n.x, y: -n.y) }
                let travel = 0.0492 * w * aspect
                add(.shape, mid, [(\.jawline, MaskPoint(x: -n.x * travel, y: -n.y * travel))])
            } else {
                add(.shape, at(noseU + side * 0.34 * scale, 0.14), [(\.jawline, MaskPoint(x: side * 0.0492 * scale * w, y: 0))])
            }
        }
        let middle = noseU + (pose.right - pose.left) / 2
        add(.shape, at(middle, f.chin), [(\.chinHeight, MaskPoint(x: 0, y: -0.06 * h))])
        add(.shape, at(middle, 1), [(\.forehead, MaskPoint(x: 0, y: 0.07 * h))])
        return result
    }

    /// The warp in `newRegion`. Moved, the features go with it, as a region carried to another face. Resized, features
    /// measured on the face stay where they are on the photo, so the handles stay on the eyes, nose and mouth; a drawn
    /// region's usual proportions scale with it.
    public func placed(in newRegion: CGRect) -> FaceLiquify {
        var result = self
        result.region = newRegion
        let resized = abs(newRegion.width - region.width) > 1e-6 || abs(newRegion.height - region.height) > 1e-6
        guard resized, features != Features(), newRegion.width > 0, newRegion.height > 0 else { return result }
        let sx = region.width / newRegion.width, sy = region.height / newRegion.height
        let dx = (region.minX - newRegion.minX) / newRegion.width, dy = (region.minY - newRegion.minY) / newRegion.height
        func x(_ u: Double) -> Double { dx + u * sx }
        func y(_ v: Double) -> Double { dy + v * sy }
        func p(_ m: MaskPoint) -> MaskPoint { MaskPoint(x: x(m.x), y: y(m.y)) }
        var f = features
        f.leftEye = p(f.leftEye); f.rightEye = p(f.rightEye); f.nose = p(f.nose)
        f.mouthLeft = p(f.mouthLeft); f.mouthRight = p(f.mouthRight)
        f.brow = y(f.brow); f.chin = y(f.chin)
        f.eyeRadius = min(0.5, max(0.01, f.eyeRadius * sx)); f.noseSpan = min(1, max(0.01, f.noseSpan * sx))
        f.leftEdge = f.leftEdge.map { min(1.5, max(0.01, $0 * sx)) }; f.rightEdge = f.rightEdge.map { min(1.5, max(0.01, $0 * sx)) }
        f.jawFrom = f.jawFrom.map(p); f.jawMid = f.jawMid.map(p); f.jawTo = f.jawTo.map(p)
        result.features = f
        return result
    }

    /// Where a handle is drawn for the current amounts.
    public func position(of handle: Handle) -> MaskPoint {
        handle.axes.reduce(handle.base) { p, axis in
            MaskPoint(x: p.x + axis.delta.x * self[keyPath: axis.path], y: p.y + axis.delta.y * self[keyPath: axis.path])
        }
    }

    enum CodingKeys: String, CodingKey { case region, features, width, jawline, chinHeight, forehead, eyeSize, eyeDistance, noseWidth, mouthWidth, smile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = try c.decode(CGRect.self, forKey: .region)
        features = try c.decodeIfPresent(Features.self, forKey: .features) ?? Features()
        for (key, path) in zip([CodingKeys.width, .jawline, .chinHeight, .forehead, .eyeSize, .eyeDistance, .noseWidth, .mouthWidth, .smile],
                               [\FaceLiquify.width, \.jawline, \.chinHeight, \.forehead, \.eyeSize, \.eyeDistance, \.noseWidth, \.mouthWidth, \.smile]) {
            self[keyPath: path] = try c.decodeIfPresent(Double.self, forKey: key) ?? 0
        }
    }

    private static let kernel = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        // Fades from 1 at the centre to 0 at q = 1, with zero slope at both ends.
        float bump(float q) { if (q >= 1.0) return 0.0; float t = 1.0 - q * q; return t * t; }
        // 0 at the start of a run, 1 at its end, held for 0.3 of its length (so the chin or hairline handle, moved by
        // the full shift, still sits on moved content), then easing back to 0 over 0.6.
        float run(float t) { if (t <= 0.0) return 0.0; if (t <= 1.0) return t * t * (3.0 - 2.0 * t); if (t <= 1.3) return 1.0; return bump((t - 1.3) / 0.6); }
        // Everything is worked out across the upright face: `pose` holds the turn's cosine and sine and the centre it
        // turns about, `sides` the nose's place across the region, each cheek's edge from it and the eyes' weights,
        // `weights` each side's.
        extern "C" [[ stitchable ]] float4 face(coreimage::sampler src, float4 box, float4 eyes, float4 eyeAmounts, float4 nose,
                                                 float4 mouth, float4 mouthAmounts, float4 shape, float4 lines, float4 pose,
                                                 float4 sides, float4 weights, float4 jawLine, float4 jawMid, coreimage::destination dest) {
            // Strengths keep each control's steepest displacement change under about 0.8 per pixel, so content
            // never folds over itself.
            float2 d = dest.coord() - pose.zw;
            float2 p = pose.zw + float2(d.x * pose.x + d.y * pose.y, -d.x * pose.y + d.y * pose.x), q = p;
            float2 uv = (p - box.xy) / box.zw;
            float dx = uv.x - sides.x, side = sign(dx);
            float edge = dx < 0.0 ? sides.y : sides.z, scale = edge / 0.403226, weight = dx < 0.0 ? weights.x : weights.y;
            float cheekScale = min(1.25, scale);
            // Face width at the cheeks, and the jawline below them: content drawn in from further out narrows.
            float2 cheek = float2((abs(dx) - 0.32 * cheekScale) / (0.18 * cheekScale), (uv.y - 0.35) / 0.28);
            float fc = max(0.0, 1.0 - dot(cheek, cheek));
            q.x -= side * weight * shape.x * box.z * 0.08 * cheekScale * fc * fc;
            // In a turned face the far jaw runs from below the ear to the chin, so it is pulled in across that line
            // (`jawMid.z` of the way) instead of straight across the face.
            float follow = side == jawMid.w ? jawMid.z : 0.0;
            float2 jaw = float2((abs(dx) - 0.34 * scale) / (0.16 * scale), (uv.y - 0.14) / 0.16);
            float fj = max(0.0, 1.0 - dot(jaw, jaw));
            q.x -= side * weight * (1.0 - follow) * shape.y * box.z * 0.06 * scale * fj * fj;
            if (follow > 0.0) {
                float2 t = normalize(jawLine.zw - jawLine.xy), n = float2(-t.y, t.x);
                if (dot(n, nose.xy - jawMid.xy) < 0.0) n = -n;
                float reach = box.z * 0.16, along = max(1.0, length(jawLine.zw - jawLine.xy) * 0.5);
                float2 o = p - (jawMid.xy + n * reach * 0.5);
                float a = dot(o, n) / reach, b = dot(o, t) / along;
                float fo = max(0.0, 1.0 - a * a - b * b);
                q += n * (follow * shape.y * box.z * 0.06 * fo * fo);
            }
            // Eyes: scaled about their centres, and moved apart or together.
            float r = eyeAmounts.x, mid = (eyes.x + eyes.z) * 0.5;
            for (int k = 0; k < 2; k++) {
                float2 c = k == 0 ? eyes.xy : eyes.zw;
                float f = bump(length(p - c) / r) * (k == 0 ? sides.w : weights.z);
                q -= (p - c) * eyeAmounts.y * 0.3 * f;
                q.x -= sign(c.x - mid) * eyeAmounts.z * r * 0.3 * f;
            }
            // Nose width about the nostrils.
            float fn = bump(length((p - nose.xy) / float2(nose.z * 1.6, nose.w)));
            q.x -= (p.x - nose.x) * mouthAmounts.z * 0.3 * fn;
            // Mouth width about its middle; a smile lifts the corners.
            float2 m = (mouth.xy + mouth.zw) * 0.5;
            float spread = max(1.0, abs(mouth.z - mouth.x) * 0.5);
            float fm = bump(length((p - m) / float2(spread * 1.5, spread * 0.7)));
            q.x -= (p.x - m.x) * mouthAmounts.x * 0.3 * fm;
            for (int k = 0; k < 2; k++) {
                float2 c = k == 0 ? mouth.xy : mouth.zw;
                q.y -= mouthAmounts.y * spread * 0.3 * bump(length(p - c) / (spread * 0.6));
            }
            // Chin height: nothing moves at the lower lip; the shift builds to the chin and fades below it.
            float across = bump(abs(p.x - m.x) / (box.z * 0.3));
            if (p.y < lines.y) q.y += shape.z * box.w * 0.06 * run((lines.y - p.y) / max(1.0, lines.y - lines.z)) * across;
            // Forehead height: nothing moves at the brows; the shift builds to the top of the face.
            float middle = sides.x + (sides.z - sides.y) * 0.5;
            if (p.y > lines.x) q.y -= shape.w * box.w * 0.07 * run((p.y - lines.x) / max(1.0, lines.w - lines.x)) * bump(abs(uv.x - middle) / 0.6);
            // Back to the photo's frame.
            float2 e = q - pose.zw;
            return src.sample(src.transform(pose.zw + float2(e.x * pose.x - e.y * pose.y, e.x * pose.y + e.y * pose.x)));
        }
        """)[0]

    func apply(to image: CIImage) throws -> CIImage {
        guard !isIdentity else { return image }
        let e = image.extent
        let box = CGRect(x: e.minX + region.minX * e.width, y: e.minY + region.minY * e.height, width: region.width * e.width, height: region.height * e.height)
        let f = features, pose = f.pose
        // Features are placed on the upright face: turned about the region's centre by the face's lean.
        let cs = cos(pose.angle), sn = sin(pose.angle), centre = CGPoint(x: box.midX, y: box.midY)
        func at(_ p: MaskPoint) -> CGPoint {
            let x = box.minX + p.x * box.width - centre.x, y = box.minY + p.y * box.height - centre.y
            return CGPoint(x: centre.x + x * cs + y * sn, y: centre.y - x * sn + y * cs)
        }
        let (le, re, n, ml, mr) = (at(f.leftEye), at(f.rightEye), at(f.nose), at(f.mouthLeft), at(f.mouthRight))
        let lip = min(ml.y, mr.y) - abs(mr.x - ml.x) * 0.25
        // Eye weights follow the eyes' order on the upright face, as the kernel takes them.
        let sides = f.sideWeights(), eyeWeights = f.eyeWeights()
        let follow = f.jawFollow
        let jawFrom = at(f.jawFrom ?? f.nose), jawMid = at(f.jawMid ?? f.nose), jawTo = at(f.jawTo ?? f.nose)
        let arguments: [Any] = [
            image.clampedToExtent(), CIVector(cgRect: box),
            CIVector(x: le.x, y: le.y, z: re.x, w: re.y), CIVector(x: f.eyeRadius * box.width, y: eyeSize, z: eyeDistance, w: 0),
            CIVector(x: n.x, y: n.y, z: f.noseSpan * box.width / 2, w: f.noseSpan * box.width / 2),
            CIVector(x: ml.x, y: ml.y, z: mr.x, w: mr.y), CIVector(x: mouthWidth, y: smile, z: noseWidth, w: 0),
            CIVector(x: width, y: jawline, z: chinHeight, w: forehead),
            CIVector(x: box.minY + f.brow * box.height, y: lip, z: box.minY + f.chin * box.height, w: box.maxY),
            CIVector(x: cs, y: sn, z: centre.x, w: centre.y),
            CIVector(x: f.turn == nil ? 0.5 : (n.x - box.minX) / box.width, y: pose.left, z: pose.right, w: eyeWeights.left),
            CIVector(x: sides.left, y: sides.right, z: eyeWeights.right, w: 0),
            CIVector(x: jawFrom.x, y: jawFrom.y, z: jawTo.x, w: jawTo.y), CIVector(x: jawMid.x, y: jawMid.y, z: follow, w: pose.turn < 0 ? 1 : -1)]
        // The largest shift any control makes, with a margin.
        let reach = ceil(max(box.width, box.height) * 0.1) + 2
        guard let result = Self.kernel.apply(extent: e, roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) }, arguments: arguments)
        else { throw EditorError.render }
        return result
    }
}

extension RawRenderer {
    /// The largest visible face, with room around the jaw, and its features measured from Vision's landmarks.
    public func liquifyFace(_ settings: Adjustments) throws -> FaceLiquify? {
        guard let (region, face, size) = try detectedFace(settings, fitCheeks: true) else { return nil }
        return FaceLiquify(region: region, features: Self.features(of: face, in: region, size: size))
    }
    /// The warp's placement for each of `faces` (Vision boxes, as `PortraitFace` has them), in their order; nil where
    /// that face isn't found again.
    public func liquifyFaces(_ settings: Adjustments, faces: [CGRect]) throws -> [FaceLiquify?] {
        let (found, size) = try faceObservations(settings)
        return faces.map { box in
            guard let face = Self.pick(found, near: box) else { return nil }
            let region = Self.region(of: face, fitCheeks: true)
            return FaceLiquify(region: region, features: Self.features(of: face, in: region, size: size))
        }
    }

    /// Where `liquifyFace` puts the face.
    public func liquifyRegion(_ settings: Adjustments) throws -> CGRect? { try liquifyFace(settings)?.region }

    func detectedPortraitRegion(_ settings: Adjustments, fitCheeks: Bool) throws -> CGRect? {
        try detectedFace(settings, fitCheeks: fitCheeks)?.region
    }
    /// Every face's region, as `detectedPortraitRegion` places the largest one's (without fitting the cheeks).
    func detectedPortraitRegions(_ settings: Adjustments) throws -> [CGRect] {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.faceLiquify = nil
        let image = try pipeline(base, maxDimension: 1600)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        return try FaceDetection.faces(ciImage: image).map { face in
            let b = face.boundingBox
            return b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.08).intersection(bounds)
        }
    }

    /// The largest face, or with `near` the face whose box holds its centre.
    private func detectedFace(_ settings: Adjustments, fitCheeks: Bool, near: CGRect? = nil) throws -> (region: CGRect, face: VNFaceObservation, size: CGSize)? {
        let (found, size) = try faceObservations(settings)
        guard let face = Self.pick(found, near: near) else { return nil }
        return (Self.region(of: face, fitCheeks: fitCheeks), face, size)
    }
    /// Every face Vision finds on the photo as it was shot (a warp already applied would move the landmarks it is
    /// placed by), with the size of the image it looked at.
    private func faceObservations(_ settings: Adjustments) throws -> ([VNFaceObservation], CGSize) {
        var base = settings
        base.geometry = GeometryAdjustments(); base.quarterTurns = 0; base.faceLiquify = nil
        let image = try pipeline(base, maxDimension: 1600)
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(ciImage: image).perform([request])
        return (request.results ?? [], image.extent.size)
    }
    private static func pick(_ found: [VNFaceObservation], near: CGRect?) -> VNFaceObservation? {
        guard let near else { return found.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height } }
        return found.first { $0.boundingBox.contains(CGPoint(x: near.midX, y: near.midY)) || near.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
    }
    /// The face's region: Vision's box with room around the jaw, fitted to the cheeks where the jawline crosses the
    /// handle row (accounting for the head's turn).
    private static func region(of face: VNFaceObservation, fitCheeks: Bool) -> CGRect {
        let b = face.boundingBox
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let region = b.insetBy(dx: -b.width * 0.15, dy: -b.height * 0.08).intersection(bounds)
        guard fitCheeks, let contour = face.landmarks?.faceContour?.normalizedPoints else { return region }
        let y = (region.minY + 0.35 * region.height - b.minY) / b.height
        var crossings: [CGFloat] = []
        for (p, q) in zip(contour, contour.dropFirst()) where (p.y > y) != (q.y > y) {
            let x = p.x + (q.x - p.x) * (y - p.y) / (q.y - p.y)
            crossings.append(b.minX + x * b.width)
        }
        guard let left = crossings.min(), let right = crossings.max(), right - left > b.width * 0.25 else { return region }
        let span = (right - left) * 1.24
        return CGRect(x: (left + right - span) / 2, y: region.minY, width: span, height: region.height).intersection(bounds)
    }

    /// Landmarks as fractions of `region`; a feature Vision did not find keeps its usual place. `size` is the image's
    /// in pixels, for the pose.
    static func features(of face: VNFaceObservation, in region: CGRect, size: CGSize) -> FaceLiquify.Features {
        var f = FaceLiquify.Features()
        guard let l = face.landmarks, region.width > 0, region.height > 0 else { return f }
        let b = face.boundingBox
        func local(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: (b.minX + $0.x * b.width - region.minX) / region.width, y: (b.minY + $0.y * b.height - region.minY) / region.height) }
        }
        func centre(_ points: [CGPoint]) -> MaskPoint {
            MaskPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
        }
        // Image left and right, whichever eye Vision calls which.
        let eyes = [l.leftEye, l.rightEye].compactMap { $0.map { local($0.normalizedPoints) } }.filter { !$0.isEmpty }
        if eyes.count == 2 {
            let sorted = eyes.sorted { centre($0).x < centre($1).x }
            f.leftEye = centre(sorted[0]); f.rightEye = centre(sorted[1])
            let span = sorted.map { ($0.map(\.x).max() ?? 0) - ($0.map(\.x).min() ?? 0) }.max() ?? 0
            if span > 0 { f.eyeRadius = min(0.5, max(0.02, span * 0.8)) }
        }
        if let nose = l.nose.map({ local($0.normalizedPoints) }), !nose.isEmpty {
            let xs = nose.map(\.x), ys = nose.map(\.y)
            let low = ys.min() ?? 0, high = ys.max() ?? 0
            f.nose = MaskPoint(x: xs.reduce(0, +) / Double(xs.count), y: low + (high - low) * 0.25)
            f.noseSpan = min(1, max(0.02, (xs.max() ?? 0) - (xs.min() ?? 0)))
        }
        if let lips = l.outerLips.map({ local($0.normalizedPoints) }), let left = lips.min(by: { $0.x < $1.x }), let right = lips.max(by: { $0.x < $1.x }) {
            f.mouthLeft = MaskPoint(x: left.x, y: left.y); f.mouthRight = MaskPoint(x: right.x, y: right.y)
        }
        let brows = [l.leftEyebrow, l.rightEyebrow].compactMap { $0.map { local($0.normalizedPoints) } }.flatMap { $0 }
        if let top = brows.map(\.y).max() { f.brow = top }
        if let contour = l.faceContour.map({ local($0.normalizedPoints) }), let bottom = contour.map(\.y).min() { f.chin = bottom }
        measurePose(&f, face: face, region: region, size: size)
        return f
    }

    /// The face's lean, turn and cheek edges (see `Features`). The lean comes from the line through the eyes while
    /// both are seen; a turned face's far eye is a guess, so then from Vision's roll. The turn and edges come from
    /// where the jawline crosses the cheek row, across the upright face, against the nose.
    private static func measurePose(_ f: inout FaceLiquify.Features, face: VNFaceObservation, region: CGRect, size: CGSize) {
        guard let l = face.landmarks, size.width > 0, size.height > 0, region.width > 0 else { return }
        let b = face.boundingBox
        func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: (b.minX + p.x * b.width) * size.width, y: (b.minY + p.y * b.height) * size.height) }
        let rw = region.width * size.width, rh = region.height * size.height
        let centre = CGPoint(x: region.midX * size.width, y: region.midY * size.height)
        let yaw = face.yaw?.doubleValue ?? 0
        var angle = face.roll?.doubleValue ?? 0
        func middle(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
            var x = 0.0, y = 0.0
            for point in points { let q = pixel(point); x += q.x; y += q.y }
            return CGPoint(x: x / Double(points.count), y: y / Double(points.count))
        }
        let eyes: [CGPoint] = [middle(l.leftEye), middle(l.rightEye)].compactMap { $0 }.sorted { $0.x < $1.x }
        if eyes.count == 2, abs(yaw) < 0.5 { angle = atan2(eyes[1].y - eyes[0].y, eyes[1].x - eyes[0].x) }
        guard abs(angle) < 1.2 else { return }
        let cs = cos(angle), sn = sin(angle)
        func upright(_ p: CGPoint) -> CGPoint {
            let x = p.x - centre.x, y = p.y - centre.y
            return CGPoint(x: (centre.x + x * cs + y * sn - (centre.x - rw / 2)) / rw, y: (centre.y - x * sn + y * cs - (centre.y - rh / 2)) / rh)
        }
        guard let contour = l.faceContour?.normalizedPoints.map({ upright(pixel($0)) }), let noseRegion = l.nose?.normalizedPoints, !noseRegion.isEmpty else { return }
        let nose = noseRegion.map { upright(pixel($0)) }
        let noseX = nose.map(\.x).reduce(0, +) / Double(nose.count)
        let row = 0.35
        var crossings: [Double] = []
        for (p, q) in zip(contour, contour.dropFirst()) where (p.y > row) != (q.y > row) {
            crossings.append(p.x + (q.x - p.x) * (row - p.y) / (q.y - p.y))
        }
        // A profile's jawline may cross only on the far side: the near edge is then the nose itself.
        guard let far = crossings.max(), let near = crossings.min() else { return }
        let left = min(near, noseX), right = max(far, noseX)
        guard right - left > 0.05 else { return }
        f.angle = angle
        f.turn = max(-1, min(1, ((noseX - left) - (right - noseX)) / (right - left)))
        f.leftEdge = max(0.02, noseX - left); f.rightEdge = max(0.02, right - noseX)
        // The far side's jawline: the contour from its crossing of the cheek row down to the chin, its lowest point.
        guard let chinIndex = contour.indices.min(by: { contour[$0].y < contour[$1].y }) else { return }
        let farRight = f.turn ?? 0 < 0
        let crossing = contour.indices.filter { contour[$0].y >= row }.min { abs(contour[$0].x - (farRight ? far : near)) < abs(contour[$1].x - (farRight ? far : near)) }
        guard let start = crossing, start != chinIndex else { return }
        let path = start < chinIndex ? Array(contour[start...chinIndex]) : Array(contour[chinIndex...start].reversed())
        guard path.count >= 3 else { return }
        // Back to the photo's frame, as the other features.
        func photo(_ u: CGPoint) -> MaskPoint {
            let x = (u.x - 0.5) * rw, y = (u.y - 0.5) * rh
            return MaskPoint(x: 0.5 + (x * cs - y * sn) / rw, y: 0.5 + (x * sn + y * cs) / rh)
        }
        f.jawFrom = photo(path[0]); f.jawMid = photo(path[path.count / 2]); f.jawTo = photo(path[path.count - 1])
    }
}
