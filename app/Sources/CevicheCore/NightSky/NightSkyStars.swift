import Foundation
import simd

/// A point-like source in a luminance plane: centroid, background-subtracted flux and second-moment shape.
struct NightSkyStar: Sendable {
    var point: SIMD2<Double>
    var flux: Double
    var radius: Double
    var elongation: Double
}

/// Finds stars by local-background subtraction against local noise; nothing is learned or replaced. Follows the
/// CevicheLab StarStack experiment, where detection at about 3200 pixels proved much more reliable than at 1280.
enum NightSkyStars {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }

    /// Up to `limit` stars where `mask` is above 0.95 (everywhere without one), strongest first, at most five per 48-pixel
    /// cell so one bright structure can't take the whole list.
    static func detect(_ luminance: [Float], width w: Int, height h: Int, mask: [Float]?, limit: Int = 700, sigma: Double = 6,
                       gpu: NightSkyAnalysisGPU? = nil) throws -> [NightSkyStar] {
        guard w > 16, h > 16 else { return [] }
        let background = try gpu?.filter(luminance, width: w, height: h, radius: 6) ?? HDRMerger.boxBlur(luminance, width: w, height: h, radius: 6)
        var high = [Float](repeating: 0, count: w * h)
        for i in high.indices { high[i] = luminance[i] - background[i] }
        // Noise per 64-pixel tile from the median absolute deviation, so a brighter horizon doesn't raise the bar overhead.
        let tw = (w + 63) / 64, th = (h + 63) / 64
        var noise = [Double](repeating: 1e-6, count: tw * th)
        noise.withUnsafeMutableBufferPointer { noise in
            let noise = noise
            DispatchQueue.concurrentPerform(iterations: th) { ty in
                for tx in 0..<tw {
                    var values: [Double] = []
                    values.reserveCapacity(1024)
                    for y in stride(from: ty * 64, to: min(h, ty * 64 + 64), by: 2) {
                        for x in stride(from: tx * 64, to: min(w, tx * 64 + 64), by: 2) { values.append(Double(high[y * w + x])) }
                    }
                    let m = median(values)
                    noise[ty * tw + tx] = max(1e-7, 1.4826 * median(values.map { abs($0 - m) }))
                }
            }
        }
        var rows = [[NightSkyStar]](repeating: [], count: h)
        rows.withUnsafeMutableBufferPointer { rows in
            let rows = rows
            DispatchQueue.concurrentPerform(iterations: h - 14) { r in
                let y = r + 7
                for x in 7..<(w - 7) {
                    let k = y * w + x
                    if let mask, mask[k] < 0.95 { continue }
                    let n = noise[(y / 64) * tw + x / 64], v = Double(high[k])
                    guard v > sigma * n else { continue }
                    var isMax = true
                    for dy in -2...2 { for dx in -2...2 where (dx != 0 || dy != 0) && high[(y + dy) * w + x + dx] >= high[k] { isMax = false } }
                    if !isMax { continue }
                    var total = 0.0, sx = 0.0, sy = 0.0
                    for dy in -3...3 { for dx in -3...3 {
                        let a = max(0, Double(high[(y + dy) * w + x + dx]) - n)
                        total += a; sx += a * Double(dx); sy += a * Double(dy)
                    }}
                    guard total > 0 else { continue }
                    sx /= total; sy /= total
                    var xx = 0.0, yy = 0.0, xy = 0.0
                    for dy in -3...3 { for dx in -3...3 {
                        let a = max(0, Double(high[(y + dy) * w + x + dx]) - n), ux = Double(dx) - sx, uy = Double(dy) - sy
                        xx += a * ux * ux; yy += a * uy * uy; xy += a * ux * uy
                    }}
                    xx /= total; yy /= total; xy /= total
                    let d = ((xx - yy) * (xx - yy) + 4 * xy * xy).squareRoot(), minor = max(0.01, (xx + yy - d) / 2), major = (xx + yy + d) / 2
                    let radius = ((xx + yy) / 2).squareRoot(), elongation = (max(minor, major) / minor).squareRoot()
                    // Isolated hot pixels are too small and streaks too long; mildly trailed stars are kept as measured.
                    if radius < 0.45 || radius > 3 || elongation > 3.5 { continue }
                    rows[y].append(NightSkyStar(point: SIMD2(Double(x) + sx, Double(y) + sy), flux: total, radius: radius, elongation: elongation))
                }
            }
        }
        var counts: [Int: Int] = [:], selected: [NightSkyStar] = []
        for star in rows.joined().sorted(by: { $0.flux > $1.flux }) {
            let key = Int(star.point.y) / 48 * ((w + 47) / 48) + Int(star.point.x) / 48
            if counts[key, default: 0] >= 5 { continue }
            counts[key, default: 0] += 1
            selected.append(star)
            if selected.count >= limit { break }
        }
        return selected
    }
}

/// A projective map in pixel coordinates, row-major 3 × 3.
struct NightSkyHomography: Codable, Sendable, Equatable {
    var m: [Double]
    static let identity = NightSkyHomography([1, 0, 0, 0, 1, 0, 0, 0, 1])
    init(_ m: [Double]) { precondition(m.count == 9); self.m = m }

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let z = m[6] * p.x + m[7] * p.y + m[8]
        return SIMD2((m[0] * p.x + m[1] * p.y + m[2]) / z, (m[3] * p.x + m[4] * p.y + m[5]) / z)
    }
    var inverse: NightSkyHomography? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let co = [e * i - f * h, c * h - b * i, b * f - c * e, f * g - d * i, a * i - c * g, c * d - a * f, d * h - e * g, b * g - a * h, a * e - b * d]
        let determinant = a * co[0] + b * co[3] + c * co[6]
        guard abs(determinant) > 1e-12, determinant.isFinite else { return nil }
        return NightSkyHomography(co.map { $0 / determinant })
    }
    /// Normalized so the last element is 1.
    var normalized: NightSkyHomography { NightSkyHomography(m.map { $0 / m[8] }) }
}

/// A low-order polynomial displacement for the lens distortion a projective map leaves. One smooth field over the whole
/// sky, fitted only when withheld stars improve; never a separate warp around each star.
struct NightSkyMorph: Codable, Sendable, Equatable {
    var x: [Double]
    var y: [Double]
    /// Coordinates are divided by this (the analysis width) before the polynomial.
    var scale: Double

    static func basis(_ p: SIMD2<Double>, _ scale: Double) -> [Double] {
        let x = p.x / scale - 0.5, y = p.y / scale - 0.35
        return [1, x, y, x * x, x * y, y * y, x * x * x, x * x * y, x * y * y, y * y * y]
    }
    func displacement(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let u = p.x / scale - 0.5, v = p.y / scale - 0.35
        func polynomial(_ a: [Double]) -> Double {
            a[0] + u * (a[1] + u * (a[3] + u * a[6]) + v * (a[4] + u * a[7] + v * a[8])) + v * (a[2] + v * (a[5] + v * a[9]))
        }
        return SIMD2(polynomial(x), polynomial(y))
    }

    static func fit(_ pairs: [NightSkyMatch], base: NightSkyHomography, scale: Double) -> NightSkyMorph? {
        guard pairs.count >= 60 else { return nil }
        var rows = pairs.map { basis($0.source, scale) }, vx: [Double] = [], vy: [Double] = []
        for p in pairs { let q = base.apply(p.source); vx.append(p.reference.x - q.x); vy.append(p.reference.y - q.y) }
        // A ridge on the higher orders keeps curvature down where no stars were matched.
        for i in 0..<10 { var row = [Double](repeating: 0, count: 10); row[i] = i >= 6 ? 0.02 : 0.001; rows.append(row); vx.append(0); vy.append(0) }
        guard let x = NightSkyRegistration.solve(rows, vx, count: 10), let y = NightSkyRegistration.solve(rows, vy, count: 10) else { return nil }
        let morph = NightSkyMorph(x: x, y: y, scale: scale)
        for gy in 0...6 { for gx in 0...10 where simd_length(morph.displacement(SIMD2(Double(gx) * scale / 10, Double(gy) * scale / 10))) > scale * 0.04 { return nil } }
        return morph
    }
}

struct NightSkyMatch: Sendable {
    var source: SIMD2<Double>
    var reference: SIMD2<Double>
}

/// Where a photo's sky lies on the anchor's: a projective map plus an optional smooth residual, from the photo's pixels to
/// the anchor's, in analysis pixels. Rendering samples the other way, through `sourcePoint`.
struct NightSkyAlignment: Codable, Sendable {
    var transform: NightSkyHomography
    var morph: NightSkyMorph?
    var inverse: NightSkyHomography
    var matches: Int
    /// 95th percentile error of withheld stars, in analysis pixels.
    var heldOutP95: Double

    static let identity = NightSkyAlignment(transform: .identity, morph: nil, inverse: .identity, matches: 0, heldOutP95: 0)

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { transform.apply(p) + (morph?.displacement(p) ?? .zero) }

    /// The photo's point that lands on `target`: the composed map inverted by fixed-point iteration, never by negating
    /// the forward displacement.
    func sourcePoint(_ target: SIMD2<Double>) -> SIMD2<Double> { SourceMap(self)(target) }

    /// `sourcePoint` with the coefficients copied out of their arrays, for per-pixel loops: a copy holds no references,
    /// so the threads of a loop don't contend on reference counts, which in a debug build made each warp take seconds.
    struct SourceMap: Sendable {
        private let r0, r1, r2: SIMD3<Double>
        private let mx, my: SIMD16<Double>
        private let scale: Double, morphed: Bool

        init(_ alignment: NightSkyAlignment) {
            let m = alignment.inverse.m
            r0 = SIMD3(m[0], m[1], m[2]); r1 = SIMD3(m[3], m[4], m[5]); r2 = SIMD3(m[6], m[7], m[8])
            var mx = SIMD16<Double>(), my = SIMD16<Double>()
            if let morph = alignment.morph { for i in 0..<10 { mx[i] = morph.x[i]; my[i] = morph.y[i] } }
            self.mx = mx; self.my = my
            scale = alignment.morph?.scale ?? 1; morphed = alignment.morph != nil
        }

        @inline(__always) private func inverse(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let z = r2.x * p.x + r2.y * p.y + r2.z
            return SIMD2((r0.x * p.x + r0.y * p.y + r0.z) / z, (r1.x * p.x + r1.y * p.y + r1.z) / z)
        }

        /// `NightSkyMorph.displacement`, term for term.
        @inline(__always) private func displacement(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let u = p.x / scale - 0.5, v = p.y / scale - 0.35
            @inline(__always) func polynomial(_ a: SIMD16<Double>) -> Double {
                a[0] + u * (a[1] + u * (a[3] + u * a[6]) + v * (a[4] + u * a[7] + v * a[8])) + v * (a[2] + v * (a[5] + v * a[9]))
            }
            return SIMD2(polynomial(mx), polynomial(my))
        }

        @inline(__always) func callAsFunction(_ target: SIMD2<Double>) -> SIMD2<Double> {
            var p = inverse(target)
            guard morphed else { return p }
            for _ in 0..<5 {
                let next = inverse(target - displacement(p))
                if simd_distance(p, next) < 0.0001 { return next }
                p = next
            }
            return p
        }
    }

    /// First-order prediction in capture time from two earlier alignments; it only seeds matching, the photo still has
    /// to pass correspondence and withheld-star checks of its own.
    func extrapolated(from previous: NightSkyAlignment, factor: Double) -> NightSkyAlignment {
        guard factor.isFinite, abs(factor) <= 10 else { return self }
        let a = transform.normalized.m, b = previous.transform.normalized.m
        let transform = NightSkyHomography(zip(a, b).map { $0 + factor * ($0 - $1) })
        var morph = self.morph
        if let p = self.morph, let q = previous.morph {
            morph = NightSkyMorph(x: zip(p.x, q.x).map { $0 + factor * ($0 - $1) }, y: zip(p.y, q.y).map { $0 + factor * ($0 - $1) }, scale: p.scale)
        }
        return NightSkyAlignment(transform: transform, morph: morph, inverse: transform.inverse ?? .identity, matches: 0, heldOutP95: 0)
    }
}

enum NightSkyRegistrationError: Error { case failed(String) }

/// Star-pattern registration: triangle similarity to bootstrap (or a time-extrapolated prediction), then robust
/// projective refits with a cross-validated smooth residual. Reports withheld-star error so a poor fit is rejected
/// instead of rendered.
enum NightSkyRegistration {
    /// Least squares through the normal equations with pivoting; the systems here are small and normalized.
    static func solve(_ rows: [[Double]], _ values: [Double], count n: Int) -> [Double]? {
        var a = Array(repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, v) in zip(rows, values) {
            for i in 0..<n { for j in 0..<n { a[i][j] += row[i] * row[j] }; a[i][n] += row[i] * v }
        }
        for i in 0..<n {
            let pivot = (i..<n).max { abs(a[$0][i]) < abs(a[$1][i]) }!
            guard abs(a[pivot][i]) > 1e-10 else { return nil }
            a.swapAt(i, pivot)
            let divisor = a[i][i]
            for j in i...n { a[i][j] /= divisor }
            for k in 0..<n where k != i { let f = a[k][i]; for j in i...n { a[k][j] -= f * a[i][j] } }
        }
        let result = a.map { $0[n] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    static func fit(_ pairs: [NightSkyMatch], scale: Double) -> NightSkyHomography? {
        guard pairs.count >= 4 else { return nil }
        var rows: [[Double]] = [], v: [Double] = []
        for p in pairs {
            let x = p.source.x / scale, y = p.source.y / scale, u = p.reference.x / scale, w = p.reference.y / scale
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); v.append(u)
            rows.append([0, 0, 0, x, y, 1, -w * x, -w * y]); v.append(w)
        }
        guard let a = solve(rows, v, count: 8) else { return nil }
        return NightSkyHomography([a[0], a[1], a[2] * scale, a[3], a[4], a[5] * scale, a[6] / scale, a[7] / scale, 1])
    }

    struct Triangle {
        let vertices: [SIMD2<Double>]
        let r1: Double, r2: Double
    }
    static func triangles(_ stars: [NightSkyStar]) -> [Triangle] {
        let points = stars.prefix(90).map(\.point)
        var result: [Triangle] = [], seen = Set<[Int]>()
        for i in points.indices {
            let near = Array(points.indices.filter { $0 != i }.sorted { simd_distance(points[i], points[$0]) < simd_distance(points[i], points[$1]) }.prefix(7))
            for j in 0..<near.count { for k in (j + 1)..<max(j + 1, near.count) {
                let ids = [i, near[j], near[k]].sorted()
                guard seen.insert(ids).inserted else { continue }
                let p = ids.map { points[$0] }
                let sides = [simd_distance(p[1], p[2]), simd_distance(p[0], p[2]), simd_distance(p[0], p[1])]
                let order = [0, 1, 2].sorted { sides[$0] < sides[$1] }, long = sides[order[2]]
                let area = abs((p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x))
                if long < 15 || area / (long * long) < 0.08 { continue }
                result.append(Triangle(vertices: order.map { p[$0] }, r1: sides[order[0]] / long, r2: sides[order[1]] / long))
            }}
        }
        return result
    }
    static func similarity(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> NightSkyHomography? {
        var rows: [[Double]] = [], v: [Double] = []
        for (p, q) in zip(a, b) { rows.append([p.x, -p.y, 1, 0]); v.append(q.x); rows.append([p.y, p.x, 0, 1]); v.append(q.y) }
        guard let s = solve(rows, v, count: 4) else { return nil }
        let scale = hypot(s[0], s[1])
        guard scale > 0.8, scale < 1.25 else { return nil }
        return NightSkyHomography([s[0], -s[1], s[2], s[1], s[0], s[3], 0, 0, 1])
    }
    /// Nearest reference star within `radius` of each mapped source star, each reference star used once.
    static func matches(_ source: [NightSkyStar], _ reference: [NightSkyStar], _ warp: (SIMD2<Double>) -> SIMD2<Double>, radius: Double) -> [NightSkyMatch] {
        var candidates: [(Int, Int, Double)] = []
        for (i, s) in source.enumerated() {
            let p = warp(s.point)
            var best = radius, index: Int?
            for (j, r) in reference.enumerated() { let d = simd_distance(p, r.point); if d < best { best = d; index = j } }
            if let index { candidates.append((i, index, best)) }
        }
        var used = Set<Int>(), pairs: [NightSkyMatch] = []
        for c in candidates.sorted(by: { $0.2 < $1.2 }) where used.insert(c.1).inserted {
            pairs.append(NightSkyMatch(source: source[c.0].point, reference: reference[c.1].point))
        }
        return pairs
    }

    static func align(source: [NightSkyStar], reference: [NightSkyStar], width: Int, initial: NightSkyAlignment? = nil) throws -> NightSkyAlignment {
        guard source.count >= 12, reference.count >= 12 else {
            throw NightSkyRegistrationError.failed(L10n.tr("Too few stars to align (\(min(source.count, reference.count)))."))
        }
        let scale = Double(width)
        var best = NightSkyHomography.identity, bestPairs: [NightSkyMatch] = []
        if let initial { best = initial.transform; bestPairs = matches(source, reference, initial.apply, radius: 5) }
        if bestPairs.count < max(25, min(source.count, reference.count) / 3) {
            let referenceTriangles = triangles(reference), sourceTriangles = triangles(source)
            var buckets: [Int: [Triangle]] = [:]
            func key(_ x: Int, _ y: Int) -> Int { x * 200 + y }
            for t in referenceTriangles { buckets[key(Int(t.r1 * 100), Int(t.r2 * 100)), default: []].append(t) }
            let ss = Array(source.prefix(120)), rr = Array(reference.prefix(200))
            outer: for t in sourceTriangles {
                let x = Int(t.r1 * 100), y = Int(t.r2 * 100)
                for dx in -1...1 { for dy in -1...1 {
                    for r in buckets[key(x + dx, y + dy), default: []] {
                        guard abs(t.r1 - r.r1) < 0.008, abs(t.r2 - r.r2) < 0.008, let h = similarity(t.vertices, r.vertices) else { continue }
                        let pairs = matches(ss, rr, h.apply, radius: 3)
                        if pairs.count > bestPairs.count { bestPairs = pairs; best = h }
                        if bestPairs.count >= min(70, ss.count * 2 / 3) { break outer }
                    }
                }}
            }
        }
        guard bestPairs.count >= 12 else { throw NightSkyRegistrationError.failed(L10n.tr("No star pattern matched the base photo.")) }
        // Grow correspondences and refit robustly; the bootstrap similarity only starts the search.
        var pairs = bestPairs.count > 100 ? bestPairs : matches(source, reference, best.apply, radius: 5)
        var residual: NightSkyMorph?
        func mapped(_ p: SIMD2<Double>) -> SIMD2<Double> { best.apply(p) + (residual?.displacement(p) ?? .zero) }
        for _ in 0..<5 {
            let errors = pairs.map { simd_distance(mapped($0.source), $0.reference) }, m = NightSkyStars.median(errors)
            let threshold = max(1.2, min(5, m * 3))
            let filtered = zip(pairs, errors).filter { $0.1 < threshold }.map(\.0)
            guard let fitted = fit(filtered, scale: scale) else { break }
            best = fitted
            residual = NightSkyMorph.fit(filtered, base: best, scale: scale)
            pairs = matches(source, reference, mapped, radius: 2.5)
        }
        // Keep the last search's loose matches (faint noise peaks within the radius) out of the final fit.
        let finalResiduals = pairs.map { simd_distance(mapped($0.source), $0.reference) }
        let center = NightSkyStars.median(finalResiduals), spread = 1.4826 * NightSkyStars.median(finalResiduals.map { abs($0 - center) })
        let cutoff = max(0.6, min(1.5, center + 3 * spread))
        pairs = zip(pairs, finalResiduals).filter { $0.1 < cutoff }.map(\.0)
        guard pairs.count >= 12 else { throw NightSkyRegistrationError.failed(L10n.tr("Too few stars agree on one sky motion.")) }
        // A deterministic, spatially spread holdout that the validation fit never sees.
        pairs.sort { $0.source.y == $1.source.y ? $0.source.x < $1.source.x : $0.source.y < $1.source.y }
        let train = pairs.enumerated().filter { $0.offset % 4 != 0 }.map(\.element)
        let held = pairs.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        guard let validation = fit(train, scale: scale), let final = fit(pairs, scale: scale), let inverse = final.inverse else {
            throw NightSkyRegistrationError.failed(L10n.tr("The matched stars don’t determine a sky motion."))
        }
        func p95(_ x: [Double]) -> Double { x.isEmpty ? 0 : x[min(x.count - 1, Int(Double(x.count) * 0.95))] }
        var validationErrors = held.map { simd_distance(validation.apply($0.source), $0.reference) }.sorted()
        var selected: NightSkyMorph?
        if let validationMorph = NightSkyMorph.fit(train, base: validation, scale: scale), let finalMorph = NightSkyMorph.fit(pairs, base: final, scale: scale) {
            let candidate = held.map { simd_distance(validation.apply($0.source) + validationMorph.displacement($0.source), $0.reference) }.sorted()
            if p95(candidate) < p95(validationErrors) * 0.85 && NightSkyStars.median(candidate) < NightSkyStars.median(validationErrors) * 0.9 {
                selected = finalMorph; validationErrors = candidate
            }
        }
        guard p95(validationErrors) < 2.5 else {
            throw NightSkyRegistrationError.failed(L10n.tr("The stars don’t line up closely enough (\(String(format: "%.1f", p95(validationErrors))) pixels)."))
        }
        return NightSkyAlignment(transform: final, morph: selected, inverse: inverse, matches: pairs.count, heldOutP95: p95(validationErrors))
    }
}
