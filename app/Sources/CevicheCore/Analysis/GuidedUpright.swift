import Foundation
import simd

// Guided camera-rotation solver adapted from RAWmakase (MIT).
// Copyright (c) 2026 RAWmakase contributors. See OpenSourceLicenses/credits/rawmakase/RAWmakase-MIT.txt.
// Guides live in the untransformed photo, with a bottom-left origin.
struct GuidedUpright {
    typealias V = SIMD3<Double>
    struct Solution { var map = ProjectiveMap(); var message: String? }
    private enum Fixed { case none, plane(V), direction(V) }
    private static func unit(_ v: V) -> V { v / max(1e-15, simd_length(v)) }
    private static func toward(_ v: V, _ axis: V) -> V { simd_dot(v, axis) < 0 ? -v : v }
    private static func rows(_ h: V, _ v: V) -> [V] { [h, v, simd_cross(h, v)] }

    static func solve(_ guides: [UprightGuide], size: CGSize) throws -> Solution {
        guard guides.count >= 2 else { return Solution(message: L10n.tr("Draw at least two guides along edges that should be level or vertical.")) }
        let long = max(size.width, size.height), w = size.width / long, h = size.height / long
        // A neutral field of view; directions are solved from the guides, not from image analysis.
        let focal = 1.0
        func ray(_ p: MaskPoint) -> V { V((p.x - 0.5) * w / focal, (p.y - 0.5) * h / focal, 1) }
        func normal(_ g: UprightGuide) -> V { unit(simd_cross(ray(g.start), ray(g.end))) }
        let verticals = guides.filter { $0.axis == .vertical }.map(normal)
        let horizontals = guides.filter { $0.axis == .horizontal }.map(normal)
        let v = try fixed(verticals), hFixed = try fixed(horizontals)
        let up = V(0, 1, 0), right = V(1, 0, 0)
        let rotation: [V]
        switch (v, hFixed) {
        case (.direction(let d), _) where !horizontals.isEmpty:
            let v = toward(d, up)
            rotation = rows(toward(nearestAcross(v, normals: horizontals), right), v)
        case (.direction(let d), _): rotation = align(toward(d, up), to: up)
        case (_, .direction(let d)) where !verticals.isEmpty:
            let h = toward(d, right)
            rotation = rows(h, toward(nearestAcross(h, normals: verticals), up))
        case (_, .direction(let d)): rotation = align(toward(d, right), to: right)
        case (.plane(let nv), .plane(let nh)): rotation = leastTurn(nv: nv, nh: nh)
        default: return Solution(message: L10n.tr("Draw guides along two different edges."))
        }
        let turn = acos(min(1, max(-1, (rotation[0].x + rotation[1].y + rotation[2].z - 1) / 2))) * 180 / .pi
        let g = ProjectiveMap(m: [rotation[0].x, rotation[0].y, rotation[0].z * focal,
                                  rotation[1].x, rotation[1].y, rotation[1].z * focal,
                                  rotation[2].x / focal, rotation[2].y / focal, rotation[2].z])
        let corners = [CGPoint(x: -w / 2, y: -h / 2), CGPoint(x: w / 2, y: -h / 2), CGPoint(x: w / 2, y: h / 2), CGPoint(x: -w / 2, y: h / 2)]
        guard turn.isFinite, turn <= 60, corners.allSatisfy({ g.m[6] * $0.x + g.m[7] * $0.y + g.m[8] > 0.1 }) else {
            throw EditorError.invalidDocument(L10n.tr("These guides require too much correction. Use edges that do not cross inside the photo."))
        }
        let map = ProjectiveMap(m: [w, 0, -w / 2, 0, h, -h / 2, 0, 0, 1]).followed(by: g)
            .followed(by: ProjectiveMap(m: [1 / w, 0, 0.5, 0, 1 / h, 0.5, 0, 0, 1]))
        let worst = guides.map { guide -> Double in
            let a = map.point(CGPoint(x: guide.start.x, y: guide.start.y)), b = map.point(CGPoint(x: guide.end.x, y: guide.end.y))
            let dx = abs(b.x - a.x) * w, dy = abs(b.y - a.y) * h
            return atan2(guide.axis == .vertical ? dx : dy, guide.axis == .vertical ? dy : dx) * 180 / .pi
        }.max() ?? 0
        return Solution(map: map, message: worst > 0.5 ? L10n.tr("The guides disagree. Vertical edges take priority; adjust the other endpoints.") : nil)
    }
    private static func fixed(_ normals: [V]) throws -> Fixed {
        guard let first = normals.first else { return .none }
        guard normals.count > 1 else { return .plane(first) }
        for i in normals.indices {
            for j in normals.indices where j > i {
                guard simd_length(simd_cross(normals[i], normals[j])) > 0.005 else {
                    throw EditorError.invalidDocument(L10n.tr("These guides follow the same edge. Draw them on different edges."))
                }
            }
        }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for n in normals { for i in 0..<3 { for j in 0..<3 { a[i][j] += n[i] * n[j] } } }
        var eigenvectors = [[1.0, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            let (p, q) = [(0, 1), (0, 2), (1, 2)].max { abs(a[$0.0][$0.1]) < abs(a[$1.0][$1.1]) }!
            if abs(a[p][q]) < 1e-15 { break }
            let theta = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p]), s = sin(theta), c = cos(theta)
            for k in 0..<3 { let x = a[k][p], y = a[k][q]; a[k][p] = c * x - s * y; a[k][q] = s * x + c * y }
            let ap = a[p], aq = a[q]
            for k in 0..<3 { a[p][k] = c * ap[k] - s * aq[k]; a[q][k] = s * ap[k] + c * aq[k] }
            for k in 0..<3 { let x = eigenvectors[k][p], y = eigenvectors[k][q]; eigenvectors[k][p] = c * x - s * y; eigenvectors[k][q] = s * x + c * y }
        }
        let i = (0..<3).min { a[$0][$0] < a[$1][$1] }!
        return .direction(unit(V(eigenvectors[0][i], eigenvectors[1][i], eigenvectors[2][i])))
    }
    private static func nearestAcross(_ fixed: V, normals: [V]) -> V {
        let helper = abs(fixed.x) < 0.9 ? V(1, 0, 0) : V(0, 1, 0)
        let a = unit(simd_cross(fixed, helper)), b = simd_cross(fixed, a)
        var aa = 0.0, ab = 0.0, bb = 0.0
        for n in normals { let na = simd_dot(n, a), nb = simd_dot(n, b); aa += na * na; ab += na * nb; bb += nb * nb }
        let angle = 0.5 * atan2(2 * ab, aa - bb) + .pi / 2
        return unit(cos(angle) * a + sin(angle) * b)
    }
    private static func align(_ from: V, to: V) -> [V] {
        let v = simd_cross(from, to), c = simd_dot(from, to), k = 1 / max(1e-12, 1 + c)
        return [V(c + v.x * v.x * k, v.x * v.y * k - v.z, v.x * v.z * k + v.y),
                V(v.y * v.x * k + v.z, c + v.y * v.y * k, v.y * v.z * k - v.x),
                V(v.z * v.x * k - v.y, v.z * v.y * k + v.x, c + v.z * v.z * k)]
    }
    private static func leastTurn(nv: V, nh: V) -> [V] {
        let helper = abs(nh.x) < 0.9 ? V(1, 0, 0) : V(0, 1, 0)
        let a = unit(simd_cross(nh, helper)), b = simd_cross(nh, a)
        func at(_ t: Double) -> [V]? {
            let h = cos(t) * a + sin(t) * b, v = simd_cross(nv, h)
            guard simd_length_squared(v) > 1e-8 else { return nil }
            return rows(toward(h, V(1, 0, 0)), toward(unit(v), V(0, 1, 0)))
        }
        func score(_ t: Double) -> Double { guard let m = at(t) else { return -.infinity }; return m[0].x + m[1].y + m[2].z }
        let step = Double.pi / 720
        let best = (0..<720).map { Double($0) * step }.max { score($0) < score($1) }!
        var lo = best - step, hi = best + step
        for _ in 0..<40 { let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3; if score(m1) < score(m2) { lo = m1 } else { hi = m2 } }
        return at((lo + hi) / 2) ?? [V(1, 0, 0), V(0, 1, 0), V(0, 0, 1)]
    }
}
