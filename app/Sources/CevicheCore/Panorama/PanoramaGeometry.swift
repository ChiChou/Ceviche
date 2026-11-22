import Foundation
import simd

/// A pinhole camera with radial lens distortion. Pixel coordinates are continuous, with pixel i centred on i + 0.5.
struct PanoramaCamera {
    var width: Double
    var height: Double
    var focal: Double
    /// Radial distortion of a lens the decoder didn't correct: a point that a pinhole would put at radius r (1 at the
    /// frame's corner) lands at r·(1 + k1·r² + k2·r⁴). Zero for lens-corrected photos; negative k1 is barrel.
    var k1 = 0.0
    var k2 = 0.0
    var center: SIMD2<Double> { SIMD2(width / 2, height / 2) }
    /// Half the diagonal: the radius distortion is measured against.
    var radius: Double { hypot(width, height) / 2 }
    var distorted: Bool { k1 != 0 || k2 != 0 }
    /// Points beyond this pinhole radius are outside any photo, and there a strong polynomial could fold back inside.
    static let reach = 1.5

    func ray(_ point: SIMD2<Double>) -> SIMD3<Double> {
        let d = undistort(point - center) / focal
        return simd_normalize(SIMD3(d.x, d.y, 1))
    }
    func point(_ ray: SIMD3<Double>) -> SIMD2<Double>? {
        guard ray.z > 0.001 else { return nil }
        let d = SIMD2(ray.x, ray.y) / ray.z * focal
        guard distorted else { return d + center }
        let r2 = simd_length_squared(d) / (radius * radius)
        guard r2 < Self.reach * Self.reach else { return nil }
        return d * (1 + k1 * r2 + k2 * r2 * r2) + center
    }
    /// A pixel offset from the centre where the lens put it, back to where a pinhole would.
    func undistort(_ offset: SIMD2<Double>) -> SIMD2<Double> {
        guard distorted else { return offset }
        let rd = simd_length(offset) / radius
        guard rd > 1e-9 else { return offset }
        var r = rd
        for _ in 0..<8 {
            let r2 = r * r
            let f = r * (1 + k1 * r2 + k2 * r2 * r2) - rd, slope = 1 + 3 * k1 * r2 + 5 * k2 * r2 * r2
            guard slope > 0.05 else { break }
            r -= f / slope
        }
        return offset * (r / rd)
    }
    /// The same camera for the same photo decoded at another size.
    func resized(width: Int, height: Int) -> PanoramaCamera {
        let scale = hypot(Double(width), Double(height)) / hypot(self.width, self.height)
        var camera = self
        camera.width = Double(width); camera.height = Double(height); camera.focal = focal * scale
        return camera
    }
}

struct PanoramaEdge {
    let a: Int
    let b: Int
    /// Maps rays of camera b into camera a.
    let rotation: simd_double3x3
    let matches: [PanoramaMatch]
}

struct PanoramaSolution {
    var cameras: [PanoramaCamera]
    /// Camera-to-world rotations relative to the anchor; identity for photos left out.
    var rotations: [simd_double3x3]
    var included: [Int]
    var anchor: Int
    var edges: [PanoramaEdge]
    var medianError: Double
    var p95Error: Double
}

enum PanoramaGeometry {
    // MARK: Rotations

    /// The rotation taking `source` rays onto `target` rays in the least-squares sense (Horn's unit quaternion method).
    static func fitRotation(source: [SIMD3<Double>], target: [SIMD3<Double>]) -> simd_double3x3? {
        guard source.count >= 2, source.count == target.count else { return nil }
        var s = simd_double3x3(0)
        for (a, b) in zip(source, target) { s += simd_double3x3(columns: (a * b.x, a * b.y, a * b.z)) }
        // s[j][i] = Σ source_i · target_j
        func S(_ i: Int, _ j: Int) -> Double { s[j][i] }
        let n: [Double] = [
            S(0,0) + S(1,1) + S(2,2), S(1,2) - S(2,1), S(2,0) - S(0,2), S(0,1) - S(1,0),
            S(1,2) - S(2,1), S(0,0) - S(1,1) - S(2,2), S(0,1) + S(1,0), S(2,0) + S(0,2),
            S(2,0) - S(0,2), S(0,1) + S(1,0), -S(0,0) + S(1,1) - S(2,2), S(1,2) + S(2,1),
            S(0,1) - S(1,0), S(2,0) + S(0,2), S(1,2) + S(2,1), -S(0,0) - S(1,1) + S(2,2)]
        let (values, vectors) = symmetricEigen(n, size: 4)
        let best = values.indices.max { values[$0] < values[$1] }!
        let q = vectors[best]
        guard q.allSatisfy(\.isFinite) else { return nil }
        return simd_double3x3(simd_normalize(simd_quatd(ix: q[1], iy: q[2], iz: q[3], r: q[0])))
    }

    /// Eigenvalues and unit eigenvectors of a symmetric row-major matrix, by cyclic Jacobi rotations.
    static func symmetricEigen(_ matrix: [Double], size n: Int) -> ([Double], [[Double]]) {
        var a = matrix, v = (0..<n * n).map { $0 / n == $0 % n ? 1.0 : 0 }
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<n { for q in p + 1..<n { off += a[p * n + q] * a[p * n + q] } }
            if off < 1e-22 { break }
            for p in 0..<n { for q in p + 1..<n where abs(a[p * n + q]) > 1e-300 {
                let theta = (a[q * n + q] - a[p * n + p]) / (2 * a[p * n + q])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
                let c = 1 / sqrt(t * t + 1), s = t * c
                for k in 0..<n {
                    let akp = a[k * n + p], akq = a[k * n + q]
                    a[k * n + p] = c * akp - s * akq; a[k * n + q] = s * akp + c * akq
                }
                for k in 0..<n {
                    let apk = a[p * n + k], aqk = a[q * n + k]
                    a[p * n + k] = c * apk - s * aqk; a[q * n + k] = s * apk + c * aqk
                }
                for k in 0..<n {
                    let vkp = v[k * n + p], vkq = v[k * n + q]
                    v[k * n + p] = c * vkp - s * vkq; v[k * n + q] = s * vkp + c * vkq
                }
            }}
        }
        return ((0..<n).map { a[$0 * n + $0] }, (0..<n).map { column in (0..<n).map { v[$0 * n + column] } })
    }

    static func twoRayRotation(_ a0: SIMD3<Double>, _ a1: SIMD3<Double>, _ b0: SIMD3<Double>, _ b1: SIMD3<Double>) -> simd_double3x3? {
        func basis(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> simd_double3x3? {
            let tangent = q - simd_dot(p, q) * p
            guard simd_length(tangent) > 0.03 else { return nil }
            let t = simd_normalize(tangent)
            return simd_double3x3(columns: (p, t, simd_cross(p, t)))
        }
        guard let a = basis(a0, a1), let b = basis(b0, b1) else { return nil }
        return a * b.transpose
    }

    /// Reprojection error in pixels, the worse of the two directions.
    static func residual(_ rotation: simd_double3x3, _ match: PanoramaMatch, _ a: PanoramaCamera, _ b: PanoramaCamera) -> Double {
        guard let pa = a.point(rotation * b.ray(match.b)), let pb = b.point(rotation.transpose * a.ray(match.a)) else { return .infinity }
        return max(simd_distance(pa, match.a), simd_distance(pb, match.b))
    }

    /// Deterministic RANSAC over two-ray rotations, refined on the inliers.
    static func estimate(_ matches: [PanoramaMatch], a: PanoramaCamera, b: PanoramaCamera, threshold: Double) -> (simd_double3x3, [PanoramaMatch], Double)? {
        guard matches.count >= 4 else { return nil }
        let raysA = matches.map { a.ray($0.a) }, raysB = matches.map { b.ray($0.b) }
        var seed: UInt64 = 0xCE71C4E
        func random() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 32) % UInt64(matches.count)) }
        var best: [Int] = [], rotation = matrix_identity_double3x3
        for _ in 0..<1800 {
            let i = random(), j = random()
            guard i != j, let candidate = twoRayRotation(raysA[i], raysA[j], raysB[i], raysB[j]) else { continue }
            let inliers = matches.indices.filter { residual(candidate, matches[$0], a, b) <= threshold }
            if inliers.count > best.count { best = inliers; rotation = candidate }
        }
        guard best.count >= 4 else { return nil }
        for _ in 0..<4 {
            guard let refined = fitRotation(source: best.map { raysB[$0] }, target: best.map { raysA[$0] }) else { return nil }
            rotation = refined
            best = matches.indices.filter { residual(rotation, matches[$0], a, b) <= threshold }
            if best.count < 4 { return nil }
        }
        let errors = best.map { residual(rotation, matches[$0], a, b) }.sorted()
        return (rotation, best.map { matches[$0] }, errors[errors.count / 2])
    }

    // MARK: The whole panorama

    /// Photos joined by accepted pairs; the largest group wins, ties going to the one nearest the middle of the sequence.
    static func largestGroup(count: Int, edges: [PanoramaEdge]) -> [Int] {
        var parent = Array(0..<count)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for edge in edges { parent[find(edge.a)] = find(edge.b) }
        let groups = Dictionary(grouping: 0..<count, by: find).values.map { $0.sorted() }
        let middle = Double(count - 1) / 2
        return groups.max { a, b in
            if a.count != b.count { return a.count < b.count }
            return abs(Double(a[a.count / 2]) - middle) > abs(Double(b[b.count / 2]) - middle)
        } ?? [0]
    }

    /// Chains pair rotations along the strongest pairs from the anchor, then refines every rotation against every
    /// accepted correspondence (alternating least squares, the anchor held fixed).
    static func orientations(cameras: [PanoramaCamera], edges: [PanoramaEdge], members: [Int], anchor: Int,
                             initial: [simd_double3x3]? = nil, iterations: Int = 40) -> [simd_double3x3] {
        var rotations = initial ?? [simd_double3x3](repeating: matrix_identity_double3x3, count: cameras.count)
        let memberSet = Set(members)
        let edges = edges.filter { memberSet.contains($0.a) && memberSet.contains($0.b) }
        if initial == nil {
            var connected: Set<Int> = [anchor]
            while connected.count < members.count,
                  let edge = edges.filter({ connected.contains($0.a) != connected.contains($0.b) }).max(by: { $0.matches.count < $1.matches.count }) {
                if connected.contains(edge.a) { rotations[edge.b] = rotations[edge.a] * edge.rotation; connected.insert(edge.b) }
                else { rotations[edge.a] = rotations[edge.b] * edge.rotation.transpose; connected.insert(edge.a) }
            }
        }
        for _ in 0..<iterations {
            var change = 0.0
            for i in members where i != anchor {
                var source: [SIMD3<Double>] = [], target: [SIMD3<Double>] = []
                for edge in edges where edge.a == i || edge.b == i {
                    let other = edge.a == i ? edge.b : edge.a
                    for match in edge.matches {
                        source.append(cameras[i].ray(edge.a == i ? match.a : match.b))
                        target.append(rotations[other] * cameras[other].ray(edge.a == i ? match.b : match.a))
                    }
                }
                if let updated = fitRotation(source: source, target: target) {
                    change = max(change, simd_length(updated[2] - rotations[i][2])); rotations[i] = updated
                }
            }
            if change < 1e-9 { break }
        }
        return rotations
    }

    static func errors(cameras: [PanoramaCamera], rotations: [simd_double3x3], edges: [PanoramaEdge], members: Set<Int>) -> [Double] {
        var errors: [Double] = []
        for edge in edges where members.contains(edge.a) && members.contains(edge.b) {
            let relative = rotations[edge.a].transpose * rotations[edge.b]
            errors += edge.matches.map { residual(relative, $0, cameras[edge.a], cameras[edge.b]) }
        }
        return errors
    }

    /// Aligns every photo as the panorama CLI does: RANSAC rotations for each listed pair with the EXIF focal length,
    /// a maximum-support tree from the anchor, then joint refinement against every accepted correspondence. Photos not
    /// joined to the largest group are left out instead of failing the merge.
    /// `stars`, when given, are each photo's star centroids: pairs whose corners don't match are tried on their stars.
    static func solve(cameras: [PanoramaCamera], features: [[PanoramaFeature]], pairs: [(Int, Int)], threshold: Double,
                      minimumInliers: Int, stars: [[SIMD2<Double>]] = [], cancelled: () -> Bool) throws -> PanoramaSolution {
        var found = [PanoramaEdge?](repeating: nil, count: pairs.count)
        found.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: pairs.count) { k in
                let (a, b) = pairs[k]
                let matches = PanoramaFeatures.match(features[a], features[b], ratio: 0.78)
                var fit = estimate(matches, a: cameras[a], b: cameras[b], threshold: threshold)
                if fit == nil || fit!.1.count < minimumInliers, !stars.isEmpty,
                   let starMatches = PanoramaStars.matches(stars[a], stars[b], cameraA: cameras[a], cameraB: cameras[b], threshold: threshold, minimum: minimumInliers) {
                    fit = estimate(starMatches, a: cameras[a], b: cameras[b], threshold: threshold)
                }
                guard let fit, fit.1.count >= minimumInliers else { return }
                out[k] = PanoramaEdge(a: a, b: b, rotation: fit.0, matches: fit.1)
            }
        }
        if cancelled() { throw CancellationError() }
        let edges = found.compactMap { $0 }
        let members = largestGroup(count: cameras.count, edges: edges)
        guard members.count >= 2 else { throw PanoramaError.message(L10n.tr("The photos don’t overlap enough to be merged. Panoramas need about a third of each photo shared with its neighbour.")) }
        let anchor = members[members.count / 2]
        let rotations = orientations(cameras: cameras, edges: edges, members: members, anchor: anchor)
        let sorted = errors(cameras: cameras, rotations: rotations, edges: edges, members: Set(members)).sorted()
        guard !sorted.isEmpty, sorted.allSatisfy(\.isFinite) else { throw PanoramaError.message(L10n.tr("The photos could not be aligned.")) }
        return PanoramaSolution(cameras: cameras, rotations: rotations, included: members, anchor: anchor, edges: edges,
                                medianError: sorted[sorted.count / 2], p95Error: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }
}

extension PanoramaGeometry {
    // MARK: Lens

    /// The lens every photo shares, relative to the cameras it was estimated from: a focal multiplier and radial distortion.
    struct Lens: Equatable {
        var scale = 1.0
        var k1 = 0.0
        var k2 = 0.0
        func apply(_ camera: PanoramaCamera) -> PanoramaCamera {
            var camera = camera
            camera.focal *= scale; camera.k1 = k1; camera.k2 = k2
            return camera
        }
    }

    /// Fits the lens with the rotations. The focal length starts from the camera's 35 mm equivalent, which pins the
    /// field of view; a zoom's recorded focal length is rounded and shifts with focus, so it may move within
    /// `focalRange`. Photos the decoder couldn't lens-correct also get radial distortion (k1, k2): without it, a wide
    /// lens's barrel bends the frame edges where photos overlap and pinhole alignment leaves them seams apart.
    /// Coordinate descent by golden-section search, each step re-solving the rotations, on a robust reprojection cost
    /// (residuals capped at three pixels so a few bad matches can't steer it). Returns `start` unless it improves clearly.
    static func refineLens(cameras: [PanoramaCamera], edges: [PanoramaEdge], members: [Int], anchor: Int,
                           rotations: [simd_double3x3], start: Lens = Lens(), focalRange: ClosedRange<Double>,
                           focalPrior: Double = 40, distortion: Bool) -> (cameras: [PanoramaCamera], rotations: [simd_double3x3], lens: Lens) {
        let memberSet = Set(members)
        func solve(_ lens: Lens) -> (cost: Double, cameras: [PanoramaCamera], rotations: [simd_double3x3]) {
            let lensed = cameras.map(lens.apply)
            let solved = orientations(cameras: lensed, edges: edges, members: members, anchor: anchor, initial: rotations, iterations: 25)
            let residuals = errors(cameras: lensed, rotations: solved, edges: edges, members: memberSet)
            let fit = residuals.reduce(0.0) { $0 + min($1, 3) * min($1, 3) } / Double(max(1, residuals.count))
            // A longer focal length and a stronger barrel fit the overlaps almost equally well, so the recorded field
            // of view settles it: 5% off costs about what a tenth of a pixel of misfit does.
            return (fit + focalPrior * log(lens.scale) * log(lens.scale), lensed, solved)
        }
        func search(_ range: ClosedRange<Double>, _ cost: (Double) -> Double) -> Double {
            var low = range.lowerBound, high = range.upperBound
            let golden = (sqrt(5.0) - 1) / 2
            var a = high - golden * (high - low), b = low + golden * (high - low)
            var fa = cost(a), fb = cost(b)
            for _ in 0..<12 {
                if fa < fb { high = b; b = a; fb = fa; a = high - golden * (high - low); fa = cost(a) }
                else { low = a; a = b; fa = fb; b = low + golden * (high - low); fb = cost(b) }
            }
            return (low + high) / 2
        }
        let initial = solve(start)
        var lens = start
        // Distortion first, at the recorded focal length, so the search starts in the valley next to it. Barrel or
        // pincushion of up to about a quarter of the corner radius covers ultra-wide zooms.
        for _ in 0..<(distortion ? 3 : 1) {
            if distortion {
                lens.k1 = search(-0.3...0.2) { var l = lens; l.k1 = $0; return solve(l).cost }
                lens.k2 = search(-0.15...0.15) { var l = lens; l.k2 = $0; return solve(l).cost }
            }
            lens.scale = exp(search(log(focalRange.lowerBound)...log(focalRange.upperBound)) { var l = lens; l.scale = exp($0); return solve(l).cost })
        }
        let best = solve(lens)
        guard best.cost < 0.9 * initial.cost else { return (initial.cameras, initial.rotations, start) }
        return (best.cameras, best.rotations, lens)
    }

    // MARK: Straightening

    /// How the panorama is laid out: world rotations that put its up direction on the canvas's vertical, and whether the
    /// canvas is transposed (a vertical sweep, such as horizon to zenith to horizon, is laid out along its sweep and then
    /// turned so the photos stay upright).
    struct Straightening {
        var world: simd_double3x3
        var transposed: Bool
        var flipped: Bool
    }

    /// Finds the panorama's up direction, as OpenCV's horizontal wave correction does: the camera x axes of a level
    /// panorama all lie in the horizontal plane, so up is the direction most perpendicular to all of them. Without it
    /// small tilts accumulate along the sequence and the panorama bends into a wave. A sweep whose viewing directions lie
    /// in a vertical plane turns about the photos' own x axis instead, and that axis becomes the layout's.
    static func straighten(rotations: [simd_double3x3], members: [Int]) -> Straightening {
        let identity = Straightening(world: matrix_identity_double3x3, transposed: false, flipped: false)
        guard members.count >= 2 else { return identity }
        func outer(_ v: SIMD3<Double>) -> [Double] { [v.x * v.x, v.x * v.y, v.x * v.z, v.y * v.x, v.y * v.y, v.y * v.z, v.z * v.x, v.z * v.y, v.z * v.z] }
        func eigen(_ vectors: [SIMD3<Double>]) -> [(Double, SIMD3<Double>)] {
            var m = [Double](repeating: 0, count: 9)
            for v in vectors { for (k, x) in outer(v).enumerated() { m[k] += x } }
            let (values, columns) = symmetricEigen(m, size: 3)
            return values.indices.map { (values[$0], SIMD3(columns[$0][0], columns[$0][1], columns[$0][2])) }.sorted { $0.0 > $1.0 }
        }
        let right = members.map { rotations[$0][0] }, down = members.map { rotations[$0][1] }, forward = members.map { rotations[$0][2] }
        let meanRight = simd_normalize(right.reduce(.zero, +)), meanDown = simd_normalize(down.reduce(.zero, +))
        let meanForward = simd_normalize(forward.reduce(.zero, +))
        // The plane of the viewing directions; its normal is the sweep's axis once the sweep spans enough.
        let views = eigen(forward)
        let span = views[1].0 / max(views[0].0, 1e-12)
        var axis: SIMD3<Double>
        var transposed = false
        if span > 0.03, abs(simd_dot(views[2].1, meanRight)) > abs(simd_dot(views[2].1, meanDown)) {
            // Turning about the photos' x axis: a vertical sweep. Its axis points along the photos' right.
            axis = views[2].1 * (simd_dot(views[2].1, meanRight) > 0 ? 1 : -1)
            transposed = true
        } else {
            let horizontal = eigen(right)
            if horizontal[1].0 / max(horizontal[0].0, 1e-12) > 0.01 {
                axis = horizontal[2].1
            } else {
                // The x axes are nearly parallel (a narrow panorama): keep the photos' own average down, minus roll.
                axis = meanDown - simd_dot(meanDown, meanRight) * meanRight
            }
            axis = simd_normalize(axis) * (simd_dot(axis, meanDown) > 0 ? 1 : -1)
        }
        axis = simd_normalize(axis)
        // World y along the axis (down), z toward the middle of the panorama, x completing a right-handed frame.
        var z = meanForward - simd_dot(meanForward, axis) * axis
        guard simd_length(z) > 1e-6 else { return identity }
        z = simd_normalize(z)
        let x = simd_cross(axis, z)
        // Rows x, y, z: world' = W · world.
        let world = simd_double3x3(rows: [x, axis, z])
        var flipped = false
        if transposed {
            // The canvas's vertical runs along the angle about the axis; flip it when the photos' down points the other way.
            let down = world * meanDown
            flipped = down.x < 0
        }
        return Straightening(world: world, transposed: transposed, flipped: flipped)
    }
}
