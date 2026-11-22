import Accelerate
import CoreImage
import Foundation
import Vision

/// Wide-Angle Faces: a rectilinear wide-angle lens keeps lines straight but stretches anything round away from the
/// middle, radially by 1/cos θ at θ off the axis, so people at the sides of a group shot look wide. The stereographic
/// projection keeps small shapes true but bends lines. A mesh is solved so each person follows the stereographic
/// projection (through their own similarity, which keeps their width as shot) and the background stays rectilinear,
/// after Shih et al. 2019, "Distortion-Free Wide-Angle Portraits on Camera Phones".
///
/// The lens model is a pinhole: the 35 mm equivalent focal length over the 35 mm frame's 43.27 mm diagonal gives the
/// focal length in pixels of the photo's diagonal, so a pixel p is the ray (p − centre, f).
public enum WideAngleFaces {
    /// The name the result gets after the photo's own: `DSC0001-WA.dng`.
    public static let suffix = "WA"
    /// Longer lenses barely stretch (1.1× in the corners at 35 mm): nothing worth a copy.
    public static let longestFocalLength = 35.0
    /// The size people are looked for and the mesh is solved at.
    static let workLongEdge = 3000

    /// Why a photo shot at `focal` mm (35 mm equivalent) isn't worth correcting; nil when it is.
    public static func refusal(focal: Double) -> String? {
        focal > longestFocalLength ? L10n.tr("Shot at \(Int(focal.rounded())) mm; only \(Int(longestFocalLength)) mm and wider stretch faces") : nil
    }

    /// A photo Wide-Angle Faces won't correct, and why: its EXIF lacks what the lens model needs, or the lens is too long.
    public struct Refusal: LocalizedError, Sendable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// The photo's 35 mm equivalent focal length from its EXIF, or the reason there is none to use.
    static func focalLength(_ equivalent: Double?) throws -> Double {
        guard let focal = equivalent, focal > 0 else {
            throw Refusal(reason: L10n.tr("No 35 mm equivalent focal length or sensor size in its EXIF"))
        }
        if let reason = refusal(focal: focal) { throw Refusal(reason: reason) }
        return focal
    }

    // MARK: Finding people

    private static let visionContext = CIContext(options: [.workingColorSpace: PanoramaDecoder.space, .cacheIntermediates: false])

    /// The people in `image` (the photo developed as shot, linear) and where Vision sees people.
    static func analyze(_ image: CIImage) throws -> WideAngleAnalysis {
        let e = image.extent
        let W = Double(e.width), H = Double(e.height)
        let vision = try visionImage(image)
        // Vision shrinks what it is given, so one pass over a wide group finds few of its small faces: the whole frame
        // and a 3 × 2 grid of overlapping tiles, merged by centre distance.
        var tiles = [CGRect(x: 0, y: 0, width: W, height: H)]
        let tw = (W / 3 * 1.4).rounded(), th = (H / 2 * 1.4).rounded()
        for j in 0..<2 { for i in 0..<3 {
            tiles.append(CGRect(x: min(W - tw, max(0, (Double(i) + 0.5) * W / 3 - tw / 2)).rounded(),
                                y: min(H - th, max(0, (Double(j) + 0.5) * H / 2 - th / 2)).rounded(), width: tw, height: th))
        } }
        var faces: [CGRect] = [], boxes: [CGRect] = []
        var mask: (data: [Float], width: Int, height: Int) = ([], 0, 0)
        for (number, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            guard let crop = vision.cropping(to: tile) else { continue }
            let faceRequest = VNDetectFaceRectanglesRequest()
            var requests: [VNRequest] = [faceRequest]
            let peopleRequest = VNDetectHumanRectanglesRequest(), maskRequest = VNGeneratePersonSegmentationRequest()
            if number == 0 {
                peopleRequest.upperBodyOnly = false
                maskRequest.qualityLevel = .accurate
                maskRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
                requests += [peopleRequest, maskRequest]
            }
            try VNImageRequestHandler(cgImage: crop).perform(requests)
            func placed(_ b: CGRect) -> CGRect {
                CGRect(x: (tile.minX + b.minX * tile.width) / W, y: (tile.minY + (1 - b.maxY) * tile.height) / H,
                       width: b.width * tile.width / W, height: b.height * tile.height / H)
            }
            for face in faceRequest.results ?? [] where face.confidence > 0.5 {
                let r = placed(face.boundingBox)
                if let k = faces.firstIndex(where: { hypot(($0.midX - r.midX) * W, ($0.midY - r.midY) * H) < 0.5 * max($0.width, r.width) * W }) {
                    if r.width > faces[k].width { faces[k] = r }
                } else { faces.append(r) }
            }
            if number == 0 {
                boxes = (peopleRequest.results ?? []).map { placed($0.boundingBox) }
                if let buffer = maskRequest.results?.first?.pixelBuffer { mask = maskPlane(buffer) }
            }
        }
        var people: [WideAnglePerson] = []
        for face in faces {
            // Vision's box runs from the brows to the chin; the head with hair reaches higher.
            let head = CGPoint(x: face.midX, y: face.midY - 0.18 * face.height)
            // The person box this face belongs to: holding it in its top third, not absurdly wide.
            let owner = boxes.indices.filter { boxes[$0].contains(head) && head.y < boxes[$0].minY + 0.35 * boxes[$0].height && boxes[$0].width < 6 * face.width }
                .min { abs(boxes[$0].midX - head.x) < abs(boxes[$1].midX - head.x) }
            var body = CGRect(x: head.x - 1.6 * face.width, y: head.y, width: 3.2 * face.width, height: 7 * face.height)
            if let owner { body = boxes.remove(at: owner) }
            people.append(WideAnglePerson(id: people.count, head: head, headRadius: CGSize(width: 0.85 * face.width, height: 0.95 * face.height), body: body))
        }
        // People whose face wasn't found (turned away, too dark, too oblique): a head at the top of their box.
        for box in boxes where box.width > 0.02 {
            let face = 0.3 * box.width * W
            people.append(WideAnglePerson(id: people.count, head: CGPoint(x: box.midX, y: box.minY + 0.65 * face / H),
                                          headRadius: CGSize(width: 0.85 * face / W, height: 1.05 * face / H), body: box))
        }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        for i in people.indices { people[i].body = people[i].body.intersection(frame) }
        return WideAngleAnalysis(people: people, mask: mask.data, maskWidth: mask.width, maskHeight: mask.height, aspect: W / H)
    }

    /// 8-bit sRGB for Vision, lifted so the 90th percentile sits at mid-grey (at most 4 stops): night frames are too dark
    /// for it otherwise.
    private static func visionImage(_ image: CIImage) throws -> CGImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
        var pixels = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes {
            visionContext.render(small, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: PanoramaDecoder.space)
        }
        var luma = stride(from: 0, to: pixels.count, by: 4).map { 0.2126 * pixels[$0] + 0.7152 * pixels[$0 + 1] + 0.0722 * pixels[$0 + 2] }
        luma.sort()
        let p90 = Double(luma.isEmpty ? 0.5 : luma[luma.count * 9 / 10])
        let gain = min(16, max(1, 0.5 / max(1e-4, p90)))
        let lifted = gain > 1.01 ? image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: log2(gain)]) : image
        guard let cg = visionContext.createCGImage(lifted, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw PanoramaError.message(L10n.tr("The photo couldn’t be read for faces."))
        }
        return cg
    }

    private static func maskPlane(_ buffer: CVPixelBuffer) -> ([Float], Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return ([], 0, 0) }
        var data = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { data[y * w + x] = Float(base[y * row + x]) / 255 } }
        return (data, w, h)
    }

    // MARK: The mesh

    /// The mesh for a photo `aspect` wide (width over height) shot at `focal` mm (35 mm equivalent), solved at the
    /// working size.
    public static func solve(_ analysis: WideAngleAnalysis, people: [WideAnglePerson], focal: Double, settings: WideAngleSettings) -> WideAngleMesh {
        let aspect = analysis.aspect
        let W = aspect >= 1 ? Double(workLongEdge) : Double(workLongEdge) * aspect
        let H = aspect >= 1 ? Double(workLongEdge) / aspect : Double(workLongEdge)
        let f = focal / hypot(36, 24) * hypot(W, H)
        let c = SIMD2(W / 2, H / 2)
        struct Head { var center: SIMD2<Double>; var rx: Double; var ry: Double; var theta: Double; var body: CGRect; var on: Bool }
        let heads = people.map { p -> Head in
            let center = SIMD2(p.head.x * W, p.head.y * H), d = center - c
            return Head(center: center, rx: p.headRadius.width * W, ry: p.headRadius.height * H, theta: atan((d * d).sum().squareRoot() / f),
                        body: CGRect(x: p.body.minX * W, y: p.body.minY * H, width: p.body.width * W, height: p.body.height * H), on: p.enabled)
        }
        let minHead = heads.filter(\.on).map { min($0.rx, $0.ry) }.min() ?? 60
        let step = max(10, min(32, minHead / 2.5))
        let nx = Int((W / step).rounded()) + 1, ny = Int((H / step).rounded()) + 1
        let sx = W / Double(nx - 1), sy = H / Double(ny - 1)
        var p: [SIMD2<Double>] = []
        p.reserveCapacity(nx * ny)
        for j in 0..<ny { for i in 0..<nx { p.append(SIMD2(Double(i) * sx, Double(j) * sy)) } }
        let n = nx * ny
        let mesh = { (v: [SIMD2<Double>]) in
            WideAngleMesh(columns: nx, rows: ny, source: p.map { CGPoint(x: $0.x / W, y: $0.y / H) }, target: v.map { CGPoint(x: $0.x / W, y: $0.y / H) })
        }
        guard heads.contains(where: \.on), settings.strength > 0 else { return mesh(p) }

        func stereographic(_ q: SIMD2<Double>) -> SIMD2<Double> {
            let d = q - c, r = (d * d).sum().squareRoot()
            guard r > 1e-9 else { return .zero }
            return d * (2 * f * tan(atan(r / f) / 2) / r)
        }
        // Unknowns: x and y of each grid point, then each person's similarity (a, b, tx, ty).
        let unknowns = 2 * n + 4 * heads.count
        var rows = [[(Int, Double)]](), rhs = [Double]()
        func add(_ terms: [(Int, Double)], _ b: Double, _ weight: Double) {
            rows.append(terms.map { ($0.0, $0.1 * weight) }); rhs.append(b * weight)
        }
        let wFace = 4.0, wScale = 2.0, wSmooth = 0.5, wEdge = 8.0
        let wLine = 2.0 * pow(4, (settings.straightLines - 0.5) * 2)
        func headWeight(_ q: SIMD2<Double>, _ h: Head) -> Double {
            let dx = (q.x - h.center.x) / (h.rx * 1.25), dy = (q.y - h.center.y) / (h.ry * 1.25)
            return min(1, max(0, (1 - (dx * dx + dy * dy).squareRoot()) / 0.25))
        }
        func follow(_ i: Int, _ k: Int, weight: Double) {
            let a = 2 * n + 4 * k, b = a + 1, u = stereographic(p[i])
            // x = a ux − b uy + tx + cx; y = b ux + a uy + ty + cy
            add([(2 * i, 1), (a, -u.x), (b, u.y), (a + 2, -1)], c.x, weight)
            add([(2 * i + 1, 1), (b, -u.x), (a, -u.y), (a + 3, -1)], c.y, weight)
        }
        for (k, h) in heads.enumerated() {
            let a = 2 * n + 4 * k
            // The similarity's scale keeps the head's width as shot: rectilinear f/cos θ over stereographic f/cos²(θ/2).
            let target = cos(h.theta / 2) * cos(h.theta / 2) / cos(h.theta)
            let w = wScale * (h.rx + h.ry) / 2 / step
            add([(a, 1)], target, w); add([(a + 1, 1)], 0, w)
            guard h.on else { continue }
            for i in 0..<n {
                let m = headWeight(p[i], h)
                if m > 0 { follow(i, k, weight: wFace * m) }
            }
        }
        // Bodies: points where people are, outside every head, follow the head they belong to.
        if settings.bodies, settings.bodyAmount > 0 {
            for i in 0..<n where heads.allSatisfy({ headWeight(p[i], $0) == 0 }) {
                let q = CGPoint(x: p[i].x, y: p[i].y)
                let inBox = heads.contains { $0.body.contains(q) }
                let m = max(Double(analysis.mask(at: CGPoint(x: p[i].x / W, y: p[i].y / H))), inBox ? 0.6 : 0)
                guard m > 0.3 else { continue }
                // Whoever is in front stands or crouches lower in the frame: among heads above whose box holds the
                // point (else within shoulder reach), the lowest.
                let above = heads.indices.filter { heads[$0].center.y - heads[$0].ry < p[i].y }
                var candidates = above.filter { heads[$0].body.insetBy(dx: -heads[$0].rx * 0.3, dy: 0).contains(q) }
                if candidates.isEmpty { candidates = above.filter { abs(p[i].x - heads[$0].center.x) < 3.5 * heads[$0].rx } }
                // Someone left as shot keeps their body as shot too.
                guard let owner = candidates.max(by: { heads[$0].center.y < heads[$1].center.y }), heads[owner].on else { continue }
                // The stretch shows at the neck and shoulders; one similarity can't also fit legs far down the frame
                // (close up, a body spans much of the lens's angle), so the hold fades out by the waist.
                let below = max(0, p[i].y - heads[owner].center.y) / heads[owner].ry
                let fade = max(0, 1 - below / 6)
                guard fade > 0 else { continue }
                follow(i, owner, weight: wFace * settings.bodyAmount * m * fade)
            }
        }
        for j in 0..<ny { for i in 0..<nx {
            let k = j * nx + i
            if i + 1 < nx {
                add([(2 * (k + 1) + 1, 1), (2 * k + 1, -1)], 0, wLine)                      // stays level
                add([(2 * (k + 1), 1), (2 * k, -1)], p[k + 1].x - p[k].x, wSmooth)
            }
            if j + 1 < ny {
                add([(2 * (k + nx), 1), (2 * k, -1)], 0, wLine)                             // stays upright
                add([(2 * (k + nx) + 1, 1), (2 * k + 1, -1)], p[k + nx].y - p[k].y, wSmooth)
            }
            if i == 0 || i == nx - 1 { add([(2 * k, 1)], p[k].x, wEdge) }
            if j == 0 || j == ny - 1 { add([(2 * k + 1, 1)], p[k].y, wEdge) }
        } }
        guard let x = leastSquares(rows: rows, rhs: rhs, unknowns: unknowns) else { return mesh(p) }
        let s = min(1, max(0, settings.strength))
        return mesh((0..<n).map { i in p[i] + (SIMD2(x[2 * i], x[2 * i + 1]) - p[i]) * s })
    }

    /// Least squares through the normal equations, AᵀA x = Aᵀb, by sparse Cholesky.
    private static func leastSquares(rows: [[(Int, Double)]], rhs: [Double], unknowns: Int) -> [Double]? {
        var normal: [Int: Double] = [:]   // upper triangle, key row × unknowns + column
        var atb = [Double](repeating: 0, count: unknowns)
        for (r, terms) in rows.enumerated() {
            for (ci, vi) in terms {
                atb[ci] += vi * rhs[r]
                for (cj, vj) in terms where cj >= ci { normal[ci * unknowns + cj, default: 0] += vi * vj }
            }
        }
        var rr: [Int32] = [], cc: [Int32] = [], vv: [Double] = []
        rr.reserveCapacity(normal.count); cc.reserveCapacity(normal.count); vv.reserveCapacity(normal.count)
        for (key, value) in normal { rr.append(Int32(key / unknowns)); cc.append(Int32(key % unknowns)); vv.append(value) }
        var attributes = SparseAttributes_t()
        attributes.triangle = SparseUpperTriangle
        attributes.kind = SparseSymmetric
        let matrix = SparseConvertFromCoordinate(Int32(unknowns), Int32(unknowns), vv.count, 1, attributes, rr, cc, vv)
        defer { SparseCleanup(matrix) }
        let factor = SparseFactor(SparseFactorizationCholesky, matrix)
        defer { SparseCleanup(factor) }
        guard factor.status == SparseStatusOK else { return nil }
        var x = [Double](repeating: 0, count: unknowns)
        atb.withUnsafeMutableBufferPointer { b in
            x.withUnsafeMutableBufferPointer { xs in
                SparseSolve(factor, DenseVector_Double(count: Int32(unknowns), data: b.baseAddress!), DenseVector_Double(count: Int32(unknowns), data: xs.baseAddress!))
            }
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: The warp

    /// For each point of the result, where in the photo as shot it comes from, as fractions with y up (Core Image's
    /// way), on a grid `longEdge` across: the mesh drawn triangle by triangle. Points no triangle covers stay put.
    static func inverseMap(_ mesh: WideAngleMesh, aspect: Double, longEdge: Int = 1536) -> (data: [Float], width: Int, height: Int) {
        let w = aspect >= 1 ? longEdge : max(2, Int(Double(longEdge) * aspect)), h = aspect >= 1 ? max(2, Int(Double(longEdge) / aspect)) : longEdge
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            data[i] = (Float(x) + 0.5) / Float(w); data[i + 1] = 1 - (Float(y) + 0.5) / Float(h); data[i + 3] = 1
        } }
        let W = Double(w), H = Double(h)
        func triangle(_ a: Int, _ b: Int, _ c: Int) {
            let A = mesh.target[a], B = mesh.target[b], C = mesh.target[c]
            let ax = A.x * W, ay = A.y * H, bx = B.x * W, by = B.y * H, cx = C.x * W, cy = C.y * H
            let det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            guard abs(det) > 1e-12 else { return }
            let x0 = max(0, Int(floor(min(ax, bx, cx)))), x1 = min(w - 1, Int(ceil(max(ax, bx, cx))))
            let y0 = max(0, Int(floor(min(ay, by, cy)))), y1 = min(h - 1, Int(ceil(max(ay, by, cy))))
            guard x0 <= x1, y0 <= y1 else { return }
            let sa = mesh.source[a], sb = mesh.source[b], sc = mesh.source[c]
            for y in y0...y1 { for x in x0...x1 {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / det
                let l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / det
                let l3 = 1 - l1 - l2
                guard l1 >= -1e-6, l2 >= -1e-6, l3 >= -1e-6 else { continue }
                let i = (y * w + x) * 4
                data[i] = Float(sa.x * l1 + sb.x * l2 + sc.x * l3)
                data[i + 1] = Float(1 - (sa.y * l1 + sb.y * l2 + sc.y * l3))
            } }
        }
        for j in 0..<(mesh.rows - 1) { for i in 0..<(mesh.columns - 1) {
            let k = j * mesh.columns + i
            triangle(k, k + 1, k + mesh.columns + 1); triangle(k, k + mesh.columns + 1, k + mesh.columns)
        } }
        return (data, w, h)
    }

    private static let warpKernel = try! CIKernel.kernels(withMetalString: """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        // `map` holds, for each point of the result, the point of the photo it shows, as fractions of `size`.
        extern "C" [[ stitchable ]] float4 wideAngle(coreimage::sampler src, coreimage::sampler map, float4 size, coreimage::destination dest) {
            float2 at = map.sample(map.transform(dest.coord())).xy;
            return src.sample(src.transform(size.xy + at * size.zw));
        }
        """)[0]

    /// `image` with the mesh applied. `image` covers the whole photo.
    public static func warped(_ image: CIImage, mesh: WideAngleMesh) throws -> CIImage {
        let e = image.extent
        let aspect = e.width / max(1, e.height)
        let map = inverseMap(mesh, aspect: aspect)
        let mapImage = CIImage(bitmapData: map.data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: map.width * 16,
                               size: CGSize(width: map.width, height: map.height), format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / Double(map.width), y: e.height / Double(map.height)))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .clampedToExtent()
        // How far any point moves, so each tile reads only the photo around it.
        let reach = zip(mesh.source, mesh.target).map { max(abs($0.x - $1.x) * e.width, abs($0.y - $1.y) * e.height) }.max() ?? 0
        let margin = ceil(reach) + 4
        guard let result = warpKernel.apply(extent: e, roiCallback: { index, rect in
            index == 0 ? rect.insetBy(dx: -margin, dy: -margin) : rect.insetBy(dx: -4, dy: -4)
        }, arguments: [image.clampedToExtent(), mapImage, CIVector(x: e.minX, y: e.minY, z: e.width, w: e.height)]) else {
            throw EditorError.render
        }
        return result
    }
}
