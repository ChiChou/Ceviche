import Foundation
import simd

/// Matches star fields between overlapping night photos, where corner descriptors fail: every star looks alike, so
/// the ratio test rejects them all. Stars are matched by geometry instead. A rotation of the camera keeps the angles
/// between stars, so triangles of neighbouring stars, described by their three angular sides, are compared between
/// the photos; each pair of similar triangles proposes a rotation, and the one that brings the most stars onto stars wins.
enum PanoramaStars {
    /// Star centroids in the plane's pixels, strongest first.
    static func detect(_ plane: LuminancePlane, limit: Int = 300) -> [SIMD2<Double>] {
        ((try? NightSkyStars.detect(plane.values, width: plane.width, height: plane.height, mask: nil, limit: limit)) ?? []).map(\.point)
    }

    struct Triangle {
        /// Vertices ordered by the side opposite them, shortest first.
        let rays: [SIMD3<Double>]
        let sides: SIMD3<Double>
    }

    /// Triangles of each of the brightest stars with pairs of its nearest neighbours, sides as angles.
    static func triangles(_ rays: [SIMD3<Double>], smallest: Double) -> [Triangle] {
        let rays = Array(rays.prefix(80))
        var result: [Triangle] = [], seen = Set<[Int]>()
        for i in rays.indices {
            let near = rays.indices.filter { $0 != i }.sorted { simd_dot(rays[i], rays[$0]) > simd_dot(rays[i], rays[$1]) }.prefix(6)
            let list = Array(near)
            for j in 0..<list.count { for k in j + 1..<list.count {
                let ids = [i, list[j], list[k]].sorted()
                guard seen.insert(ids).inserted else { continue }
                let r = ids.map { rays[$0] }
                func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { acos(max(-1, min(1, simd_dot(a, b)))) }
                // Side k is opposite vertex k.
                let sides = [angle(r[1], r[2]), angle(r[0], r[2]), angle(r[0], r[1])]
                let order = [0, 1, 2].sorted { sides[$0] < sides[$1] }
                guard sides[order[0]] > smallest, sides[order[2]] - sides[order[1]] > smallest * 0.3 || sides[order[1]] - sides[order[0]] > smallest * 0.3 else { continue }
                result.append(Triangle(rays: order.map { r[$0] }, sides: SIMD3(sides[order[0]], sides[order[1]], sides[order[2]])))
            }}
        }
        return result
    }

    /// Star correspondences between photos a and b, in their pixels, under the best rotation found; nil when no
    /// rotation brings at least `minimum` stars together within `threshold` pixels.
    static func matches(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>], cameraA: PanoramaCamera, cameraB: PanoramaCamera,
                        threshold: Double, minimum: Int) -> [PanoramaMatch]? {
        guard a.count >= minimum, b.count >= minimum else { return nil }
        let raysA = a.map(cameraA.ray), raysB = b.map(cameraB.ray)
        // Angular tolerance of about two pixels.
        let tolerance = 2 / cameraA.focal
        let trianglesA = triangles(raysA, smallest: 12 / cameraA.focal), trianglesB = triangles(raysB, smallest: 12 / cameraB.focal)
        func key(_ s: SIMD3<Double>) -> SIMD3<Int> { SIMD3(Int((s.x / tolerance).rounded(.down)), Int((s.y / tolerance).rounded(.down)), Int((s.z / tolerance).rounded(.down))) }
        var buckets: [SIMD3<Int>: [Int]] = [:]
        for (k, t) in trianglesA.enumerated() { buckets[key(t.sides), default: []].append(k) }
        // Stars of a on a grid, for nearest-star lookups.
        let cell = max(threshold, 4)
        var grid: [SIMD2<Int>: [Int]] = [:]
        for (k, p) in a.enumerated() { grid[SIMD2(Int(p.x / cell), Int(p.y / cell)), default: []].append(k) }
        func nearest(_ p: SIMD2<Double>) -> (Int, Double)? {
            let c = SIMD2(Int(p.x / cell), Int(p.y / cell))
            var best: (Int, Double)?
            for dx in -1...1 { for dy in -1...1 {
                for k in grid[c &+ SIMD2(dx, dy)] ?? [] {
                    let d = simd_distance(a[k], p)
                    if d <= threshold, d < best?.1 ?? .infinity { best = (k, d) }
                }
            }}
            return best
        }
        func pairs(_ rotation: simd_double3x3, limit: Int) -> [(Int, Int, Double)] {
            var found: [(Int, Int, Double)] = []
            for k in 0..<min(limit, b.count) {
                guard let p = cameraA.point(rotation * raysB[k]), let (j, d) = nearest(p) else { continue }
                found.append((j, k, d))
            }
            // Each star of a once.
            var used = Set<Int>()
            return found.sorted { $0.2 < $1.2 }.filter { used.insert($0.0).inserted }
        }
        var bestRotation: simd_double3x3?, bestCount = 0
        outer: for t in trianglesB {
            let k = key(t.sides)
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for index in buckets[k &+ SIMD3(dx, dy, dz)] ?? [] {
                    let s = trianglesA[index]
                    guard simd_reduce_max(simd_abs(s.sides - t.sides)) < tolerance,
                          let rotation = PanoramaGeometry.fitRotation(source: t.rays, target: s.rays) else { continue }
                    let count = pairs(rotation, limit: 60).count
                    if count > bestCount { bestCount = count; bestRotation = rotation }
                    if bestCount >= 30 { break outer }
                }
            }}}
        }
        guard var rotation = bestRotation, bestCount >= min(minimum, 12) else { return nil }
        // Refit on every star that agrees, twice.
        var agreed = pairs(rotation, limit: b.count)
        for _ in 0..<2 {
            guard agreed.count >= 4, let refit = PanoramaGeometry.fitRotation(source: agreed.map { raysB[$0.1] }, target: agreed.map { raysA[$0.0] }) else { break }
            rotation = refit
            agreed = pairs(rotation, limit: b.count)
        }
        // A true overlap explains most of the stars that land inside the other photo; a chance alignment of noise or
        // cloud texture explains a few of many.
        let landing = raysB.filter { ray in cameraA.point(rotation * ray).map { $0.x > 0 && $0.y > 0 && $0.x < cameraA.width && $0.y < cameraA.height } ?? false }.count
        guard agreed.count >= minimum, Double(agreed.count) >= 0.35 * Double(landing) else { return nil }
        return agreed.map { PanoramaMatch(a: a[$0.0], b: b[$0.1], distance: Float($0.2)) }
    }
}
