import CoreGraphics
import CoreImage
import Foundation

/// Which way Volume undoes a wide-angle lens's stretch, as the photo is shown.
public enum VolumeMode: String, Codable, CaseIterable, Sendable {
    /// Pannini across the width: things at the sides take their shape again and verticals stay straight.
    case horizontal
    /// The same down the height, for a tall frame.
    case vertical
    /// Stereographic: corners too, at the cost of bending every line that misses the centre.
    case spherical
    public var localizedTitle: String {
        switch self {
        case .horizontal: L10n.tr("Horizontal")
        case .vertical: L10n.tr("Vertical")
        case .spherical: L10n.tr("Spherical")
        }
    }
}

/// Volume: a rectilinear wide-angle photo reprojected part of the way toward a projection that keeps shapes, so round
/// things near the edges stop looking stretched. Nothing is detected; the stretch depends only on how far off the
/// lens's axis a point lies, which the focal length says.
public struct VolumeCorrection: Codable, Equatable, Sendable {
    /// 0–100: how far from rectilinear toward the mode's projection.
    public var amount = 0.0
    public var mode = VolumeMode.horizontal
    /// The 35 mm equivalent focal length the projection is computed for: the photo's EXIF, or entered by hand.
    public var focalLength: Double?
    public init() {}
    public var isActive: Bool { amount > 0 && (focalLength ?? 0) > 0 }
    public static let focalRange = 4.0...200.0
    public func validate() throws {
        guard amount.isFinite, (0...100).contains(amount), focalLength.map({ $0.isFinite && Self.focalRange.contains($0) }) ?? true else {
            throw EditorError.invalidDocument(L10n.tr("Invalid volume correction."))
        }
    }
}

/// Volume on a photo of a given size: maps between the photo as shot and as reprojected, both in its pixels, and draws
/// it. The projection has unit scale at the centre, so the middle keeps its size and everything moves inward: the
/// reprojected photo fits in the original frame, its edges curved.
struct VolumeProjection: Sendable {
    enum Kind: Sendable { case pannini, panniniTurned, stereographic }
    let kind: Kind
    /// 0–1.
    let amount: Double
    /// Focal length and centre, in pixels.
    let focal: Double
    let center: CGPoint
    let size: CGSize

    /// `turned` says the photo is shown a quarter turn from how it was shot, so Horizontal works down the source.
    init?(_ volume: VolumeCorrection, size: CGSize, turned: Bool) {
        guard volume.isActive, let f35 = volume.focalLength else { return nil }
        switch volume.mode {
        case .horizontal: kind = turned ? .panniniTurned : .pannini
        case .vertical: kind = turned ? .pannini : .panniniTurned
        case .spherical: kind = .stereographic
        }
        amount = volume.amount / 100
        // The 35 mm equivalent is defined on the full-frame diagonal, so it holds for any aspect ratio.
        focal = f35 / 43.27 * hypot(size.width, size.height)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        self.size = size
    }

    /// A point of the photo as shot → where it lands.
    func forward(_ p: CGPoint) -> CGPoint {
        let s = CGPoint(x: (p.x - center.x) / focal, y: (p.y - center.y) / focal)
        let o: CGPoint
        switch kind {
        case .pannini: o = Self.pannini(s, amount)
        case .panniniTurned: let t = Self.pannini(CGPoint(x: s.y, y: s.x), amount); o = CGPoint(x: t.y, y: t.x)
        case .stereographic:
            let r = hypot(s.x, s.y)
            guard r > 1e-12 else { o = s; break }
            // The radius whose inverse gives back r: the inverse is the closed form, so the forward map is solved.
            let target = atan(r)
            var low = 0.0, high = r
            for _ in 0..<48 { let m = (low + high) / 2; if stereoTheta(m) < target { low = m } else { high = m } }
            let rho = (low + high) / 2
            o = CGPoint(x: s.x * rho / r, y: s.y * rho / r)
        }
        return CGPoint(x: center.x + o.x * focal, y: center.y + o.y * focal)
    }
    /// A point of the reprojected photo → the point of the photo as shot it shows; nil where it shows nothing.
    func inverse(_ p: CGPoint) -> CGPoint? {
        let o = CGPoint(x: (p.x - center.x) / focal, y: (p.y - center.y) / focal)
        let s: CGPoint
        switch kind {
        case .pannini: guard let v = Self.panniniInverse(o, amount) else { return nil }; s = v
        case .panniniTurned: guard let v = Self.panniniInverse(CGPoint(x: o.y, y: o.x), amount) else { return nil }; s = CGPoint(x: v.y, y: v.x)
        case .stereographic:
            let rho = hypot(o.x, o.y)
            guard rho > 1e-12 else { s = o; break }
            let theta = stereoTheta(rho)
            guard theta < .pi / 2 - 1e-6 else { return nil }
            s = CGPoint(x: o.x * tan(theta) / rho, y: o.y * tan(theta) / rho)
        }
        return CGPoint(x: center.x + s.x * focal, y: center.y + s.y * focal)
    }
    /// The angle off axis a reprojected radius shows: rectilinear and stereographic angles blended.
    private func stereoTheta(_ rho: Double) -> Double { (1 - amount) * atan(rho) + amount * 2 * atan(rho / 2) }

    /// Pannini with compression d (Sharpless): verticals and lines through the centre stay straight.
    private static func pannini(_ s: CGPoint, _ d: Double) -> CGPoint {
        let phi = atan(s.x), c = cos(phi), k = (d + 1) / (d + c)
        return CGPoint(x: k * sin(phi), y: k * s.y * c)
    }
    private static func panniniInverse(_ o: CGPoint, _ d: Double) -> CGPoint? {
        let k = o.x * o.x / ((d + 1) * (d + 1))
        let disc = k * k * d * d - (k + 1) * (k * d * d - 1)
        guard disc >= 0 else { return nil }
        let c = min(1, (-k * d + sqrt(disc)) / (k + 1))
        guard c > 1e-6 else { return nil }
        let s = sqrt(max(0, 1 - c * c)) * (o.x < 0 ? -1 : 1)
        return CGPoint(x: s / c, y: o.y / ((d + 1) / (d + c)) / c)
    }

    /// The reprojected photo's outline: the frame's edges carried over, `perEdge` points each, clockwise from the top left.
    /// 12 points an edge keep the chords within a few pixels of the curve, and inside it, since the outline is convex.
    func outline(perEdge: Int = 12) -> [CGPoint] {
        let w = size.width, h = size.height
        var points: [CGPoint] = []
        for i in 0..<perEdge { points.append(CGPoint(x: w * Double(i) / Double(perEdge), y: 0)) }
        for i in 0..<perEdge { points.append(CGPoint(x: w, y: h * Double(i) / Double(perEdge))) }
        for i in 0..<perEdge { points.append(CGPoint(x: w * (1 - Double(i) / Double(perEdge)), y: h)) }
        for i in 0..<perEdge { points.append(CGPoint(x: 0, y: h * (1 - Double(i) / Double(perEdge)))) }
        return points.map(forward)
    }

    /// `image` (its extent the whole photo, at the size this projection was made for) reprojected; transparent where the
    /// photo has nothing to show.
    func apply(to image: CIImage) -> CIImage {
        let e = image.extent
        // Core Image counts y up from the bottom; the projection is symmetric about the centre, so only the centre moves.
        let geometry = CIVector(x: e.minX + center.x, y: e.minY + center.y, z: focal, w: amount)
        let box = CIVector(x: e.minX, y: e.minY, z: e.maxX, w: e.maxY)
        let mode: Double = switch kind { case .pannini: 0; case .panniniTurned: 1; case .stereographic: 2 }
        let projection = self
        return Self.kernel.apply(extent: e, roiCallback: { _, rect in
            // Each output tile reads the part of the photo its points come from, a little wider for the filter.
            var points: [CGPoint] = []
            for i in 0...8 {
                let t = Double(i) / 8
                points += [CGPoint(x: rect.minX + rect.width * t, y: rect.minY), CGPoint(x: rect.minX + rect.width * t, y: rect.maxY),
                           CGPoint(x: rect.minX, y: rect.minY + rect.height * t), CGPoint(x: rect.maxX, y: rect.minY + rect.height * t)]
            }
            let sources = points.compactMap { projection.inverse(CGPoint(x: $0.x - e.minX, y: $0.y - e.minY)) }
            guard !sources.isEmpty else { return e }
            let xs = sources.map(\.x), ys = sources.map(\.y)
            return CGRect(x: e.minX + xs.min()! - 4, y: e.minY + ys.min()! - 4, width: xs.max()! - xs.min()! + 8, height: ys.max()! - ys.min()! + 8)
                .union(rect.insetBy(dx: -4, dy: -4)).intersection(e.insetBy(dx: -4, dy: -4))
        }, arguments: [image.clampedToExtent(), geometry, box, mode]) ?? image
    }

    private static let kernel = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        // geometry: centre (xy), focal length in pixels (z), amount 0–1 (w). box: the photo's extent (x0, y0, x1, y1).
        // mode: 0 Pannini across, 1 Pannini down, 2 stereographic blend. Each output point looks up the point it shows.
        extern "C" [[ stitchable ]] float4 volume(coreimage::sampler src, float4 geometry, float4 box, float mode, coreimage::destination dest) {
            float2 o = (dest.coord() - geometry.xy) / geometry.z;
            float d = geometry.w;
            float2 s;
            if (mode > 1.5) {
                float rho = length(o);
                float theta = (1.0 - d) * atan(rho) + d * 2.0 * atan(rho * 0.5);
                if (theta >= 1.5707) return float4(0.0);
                s = rho > 1e-7 ? o * (tan(theta) / rho) : o;
            } else {
                float2 q = mode > 0.5 ? o.yx : o;
                float k = q.x * q.x / ((d + 1.0) * (d + 1.0));
                float disc = k * k * d * d - (k + 1.0) * (k * d * d - 1.0);
                if (disc < 0.0) return float4(0.0);
                float c = min(1.0, (-k * d + sqrt(disc)) / (k + 1.0));
                if (c <= 1e-5) return float4(0.0);
                float sn = sqrt(max(0.0, 1.0 - c * c)) * (q.x < 0.0 ? -1.0 : 1.0);
                float2 r = float2(sn / c, q.y / ((d + 1.0) / (d + c)) / c);
                s = mode > 0.5 ? r.yx : r;
            }
            float2 p = geometry.xy + s * geometry.z;
            if (p.x < box.x || p.y < box.y || p.x > box.z || p.y > box.w) return float4(0.0);
            return src.sample(src.transform(p));
        }
        """)[0]
}
