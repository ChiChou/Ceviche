import Foundation
import simd

/// What a line probably is.
public enum NightSkyLineKind: Codable, Sendable, Equatable {
    /// Alone in its photo: probably a meteor.
    case meteor
    /// Continues into a neighboring photo, or blinks along its way: probably an aircraft or a satellite.
    case track
    /// One of several short lines in one photo: the camera probably moved during the exposure.
    case shake
}

/// A straight bright line recorded in one photo and not in its neighbors: a meteor, an aircraft or a satellite.
/// Coordinates are analysis pixels in the space it was found in (the anchor's sky, or the camera's for star trails).
struct NightSkyLine: Codable, Sendable, Equatable {
    var frame: Int
    var start: SIMD2<Double>
    var end: SIMD2<Double>
    /// Measured width across the line.
    var width: Double
    var pixels: Int
    var peak: Double
    var kind = NightSkyLineKind.meteor
    /// Joined from two lines running side by side, as an aircraft's wingtip lights draw; a meteor draws one.
    var sideBySide = false
    /// The aircraft or satellite this piece belongs to, shared by its pieces across photos; nil for other lines.
    var group: Int?
    /// Continues across photos, as an aircraft or satellite does.
    var persistent: Bool { kind == .track }

    var length: Double { simd_distance(start, end) }
    /// Half-width of the footprint the line is taken from or left out over.
    var radius: Double { max(2, width * 1.5) }

    /// Distance from `p` to the segment.
    func distance(_ p: SIMD2<Double>) -> Double {
        let d = end - start, l2 = simd_length_squared(d)
        guard l2 > 0 else { return simd_distance(p, start) }
        let t = max(0, min(1, simd_dot(p - start, d) / l2))
        return simd_distance(p, start + t * d)
    }
    /// Where to read a line's own sky for a pixel at `p`: points just outside the footprint, on both sides of the
    /// line, level with `p`. A line is restored as its light above these, so its photo's sky, which near the horizon
    /// is seldom the base photo's, is not carried into the result with it.
    func skyProbes(_ p: SIMD2<Double>) -> [SIMD2<Double>] {
        let d = end - start, length = simd_length(d)
        guard length > 0 else { return [] }
        let n = SIMD2(-d.y, d.x) / length
        // The point of the line's axis level with `p`, so both sides are read at the same distance from the line.
        let t = simd_dot(p - start, d) / (length * length)
        let axis = start + min(1, max(0, t)) * d
        return [radius + 2, radius + 4, radius + 6].flatMap { [axis + n * $0, axis - n * $0] }
    }
    /// The sky from what `skyProbes` read: the middle of the samples by brightness, so a star under one probe or a
    /// neighbouring line does not count.
    static func localSky(_ samples: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard samples.count >= 3 else { return nil }
        let sorted = samples.sorted { simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722)) < simd_dot($1, SIMD3(0.2126, 0.7152, 0.0722)) }
        let middle = sorted[(sorted.count - 1) / 2], other = sorted[sorted.count / 2]
        return (middle + other) / 2
    }
    /// How much of the line a pixel at `p` takes: 1 on the core, feathered to 0 at the footprint's edge.
    func coverage(_ p: SIMD2<Double>) -> Float {
        Float(max(0, min(1, (radius - distance(p)) / max(0.5, radius * 0.35))))
    }
}

enum NightSkyTransients {
    /// Lines in `frame` that its neighbors don't share. `frame` and `neighbors` are luminance planes in one coordinate space
    /// with NaN where a plane has no sample; the residual is against the neighbors' median, so stars (present in all)
    /// cancel, an event can't contaminate its own background, and with three or more neighbors an event in one of them
    /// doesn't leave a dark trough either. Only pixels every neighbor saw count: near the skyline stars rise and set. `interior` is 1 where lines may be found (well inside the
    /// sky); `stars` are cores excluded from the search. With `gpu`, the residual and its high pass are computed there.
    static func detect(frame: [Float], neighbors: [[Float]], interior: [Float], stars: [SIMD2<Double>], width w: Int, height h: Int, index: Int,
                       gpu: NightSkyAnalysisGPU? = nil) throws -> [NightSkyLine] {
        guard neighbors.count >= 2 else { return [] }
        let (high, inside) = try gpu?.lineHighPass(frame: frame, neighbors: neighbors, interior: interior, width: w, height: h)
            ?? highPass(frame: frame, neighbors: neighbors, interior: interior, width: w, height: h)
        return lines(high: high, inside: inside, stars: stars, width: w, height: h, index: index)
    }

    /// The residual against the neighbors' median, less its local mean (`high`), and where that is measured on all sides
    /// (`inside`, 1 there).
    static func highPass(frame: [Float], neighbors: [[Float]], interior: [Float], width w: Int, height h: Int) -> (high: [Float], inside: [Float]) {
        var residual = [Float](repeating: 0, count: w * h), valid = [Float](repeating: 0, count: w * h)
        residual.withUnsafeMutableBufferPointer { residual in
            valid.withUnsafeMutableBufferPointer { valid in
                let residual = residual, valid = valid
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var values = [Float](repeating: 0, count: neighbors.count)
                    for x in 0..<w {
                        let i = y * w + x
                        let v = frame[i]
                        guard v.isFinite, interior[i] > 0.5 else { continue }
                        var n = 0
                        for neighbor in neighbors where neighbor[i].isFinite { values[n] = neighbor[i]; n += 1 }
                        guard n == neighbors.count else { continue }
                        var slice = values[0..<n]
                        slice.sort()
                        let m = n % 2 == 0 ? (slice[n / 2 - 1] + slice[n / 2]) / 2 : slice[n / 2]
                        residual[i] = v - m; valid[i] = 1
                    }
                }
            }
        }
        // Slow differences (sky glow, thin cloud) go with a local mean; lines stay.
        let background = HDRMerger.boxBlur(residual, width: w, height: h, radius: 12)
        let support = HDRMerger.boxBlur(valid, width: w, height: h, radius: 12)
        var high = [Float](repeating: 0, count: w * h)
        for i in high.indices where valid[i] > 0 { high[i] = residual[i] - (support[i] > 0 ? background[i] / support[i] : 0) }
        return (high, HDRMerger.boxBlur(valid, width: w, height: h, radius: 6))
    }

    private static func lines(high: [Float], inside: [Float], stars: [SIMD2<Double>], width w: Int, height h: Int, index: Int) -> [NightSkyLine] {
        var samples: [Double] = []
        samples.reserveCapacity(w * h / 7)
        for i in stride(from: 0, to: w * h, by: 7) where inside[i] > 0.999 { samples.append(Double(high[i])) }
        guard samples.count > 1000 else { return [] }
        let m = NightSkyStars.median(samples), sigma = max(1e-7, 1.4826 * NightSkyStars.median(samples.map { abs($0 - m) }))
        var active = [UInt8](repeating: 0, count: w * h)
        let margin = 8
        for y in margin..<(h - margin) { for x in margin..<(w - margin) {
            let i = y * w + x
            if inside[i] > 0.999 && Double(high[i]) > m + 5 * sigma { active[i] = 1 }
        }}
        for star in stars {
            let x = Int(star.x.rounded()), y = Int(star.y.rounded())
            for dy in -3...3 { for dx in -3...3 where dx * dx + dy * dy <= 9 {
                if x + dx >= 0, x + dx < w, y + dy >= 0, y + dy < h { active[(y + dy) * w + x + dx] = 0 }
            }}
        }
        var found: [NightSkyLine] = [], spots: [Spot] = []
        for seed in active.indices where active[seed] == 1 {
            var queue = [seed], head = 0
            active[seed] = 0
            while head < queue.count {
                let k = queue[head], x = k % w, y = k / w
                head += 1
                // Bridges a one-pixel gap of noise without widening the measured line.
                for dy in -2...2 { for dx in -2...2 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, xx < w, yy >= 0, yy < h, active[yy * w + xx] == 1 { active[yy * w + xx] = 0; queue.append(yy * w + xx) }
                }}
            }
            guard queue.count >= 4, queue.count < w * h / 10 else { continue }
            let n = Double(queue.count)
            let cx = queue.reduce(0.0) { $0 + Double($1 % w) } / n, cy = queue.reduce(0.0) { $0 + Double($1 / w) } / n
            var xx = 0.0, yy = 0.0, xy = 0.0
            for k in queue { let x = Double(k % w) - cx, y = Double(k / w) - cy; xx += x * x; yy += y * y; xy += x * y }
            let angle = 0.5 * atan2(2 * xy, xx - yy), ux = cos(angle), uy = sin(angle)
            let along = queue.map { (Double($0 % w) - cx) * ux + (Double($0 / w) - cy) * uy }
            let across = queue.map { abs(-(Double($0 % w) - cx) * uy + (Double($0 / w) - cy) * ux) }
            let lo = along.min()!, hi = along.max()!, width = max(1, NightSkyStars.median(across) * 2.96), length = hi - lo
            let peak = Double(queue.map { high[$0] }.max()!) / sigma
            guard queue.count >= 12, length >= 18, length / width >= 6, width <= 6 else {
                // Too short or round for a line: a star that moved, or one flash of an aircraft's beacon.
                spots.append(Spot(center: SIMD2(cx, cy), size: max(length, across.max()! * 2), peak: peak, pixels: queue.count))
                continue
            }
            found.append(NightSkyLine(frame: index, start: SIMD2(cx + lo * ux, cy + lo * uy), end: SIMD2(cx + hi * ux, cy + hi * uy),
                                      width: width, pixels: queue.count, peak: peak))
        }
        let residual = Residual(high: high, inside: inside, sigma: sigma, width: w, height: h)
        let joined = joinCollinear(found + dashes(spots, frame: index, reach: max(40, Double(max(w, h)) / 30), residual: residual))
        return joinCollinear(joined.map { trace($0, residual) })
    }

    /// One photo's residual against its neighbors, as the search sees it.
    struct Residual {
        let high: [Float], inside: [Float]
        /// The noise in `high`.
        let sigma: Double
        let width: Int, height: Int

        /// The highest median of the residual along `length` pixels from `origin`, over paths beside it up to `reach`
        /// either side, and which one that was; nil where a path leaves the searched area. The median, so a star the
        /// path crosses doesn't count.
        func strip(from origin: SIMD2<Double>, along u: SIMD2<Double>, length: Int, reach: Int) -> (median: Double, offset: Int)? {
            guard length >= 2 else { return nil }
            let n = SIMD2(-u.y, u.x)
            var best: (median: Double, offset: Int)?, column = [Float](repeating: 0, count: length)
            for c in -reach...reach {
                for k in 0..<length {
                    let p = origin + Double(k) * u + Double(c) * n
                    let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                    guard x >= 0, x < width, y >= 0, y < height, inside[y * width + x] > 0.999 else { return nil }
                    column[k] = high[y * width + x]
                }
                column.sort()
                let median = Double(column[(length - 1) / 2] + column[length / 2]) / 2
                if median > best?.median ?? -.infinity { best = (median, c) }
            }
            return best
        }
    }

    /// Follows a line out from each end while the residual along it stays clearly above the noise: the faint stretches
    /// of an aircraft's way between flashes, or a glow too wide to be found as a line, are left out with it. A step may
    /// fall short once.
    static func trace(_ line: NightSkyLine, _ residual: Residual) -> NightSkyLine {
        let length = line.length
        guard length > 0 else { return line }
        let u = (line.end - line.start) / length, reach = Int(max(3, line.radius).rounded(.up)), step = 12
        var result = line, widest = 0.0
        for forward in [true, false] {
            let origin = forward ? line.end : line.start, direction = forward ? u : -u
            var t = 0, kept = 0, misses = 0
            while misses <= 1, t < 4 * max(residual.width, residual.height) {
                guard let found = residual.strip(from: origin + Double(t) * direction, along: direction, length: step, reach: reach) else { break }
                t += step
                if found.median > 1.5 * residual.sigma { kept = t; misses = 0; widest = max(widest, Double(abs(found.offset))) } else { misses += 1 }
            }
            if forward { result.end = line.end + Double(kept) * u } else { result.start = line.start - Double(kept) * u }
        }
        // Wide enough to take what the steps found beside the line.
        result.width = max(line.width, (widest + 2) / 1.5)
        return result
    }

    /// A compact bright spot in one photo's residual.
    struct Spot {
        var center: SIMD2<Double>
        /// Its extent in pixels.
        var size: Double
        var peak: Double
        var pixels: Int
    }

    /// An aircraft's beacon flashes about once a second, so over an exposure it draws a row of evenly spaced spots along
    /// its way; a meteor, a star or noise doesn't. Finds rows of at least five such spots, each the next step along from
    /// the one before (one flash may be missing), no further apart than `reach`, and makes each row a line. Only spots
    /// several times the photo's usual size count: a flash is bright and large, while the stars that moved, which leave
    /// thousands of spots in the camera's frame, are mostly small. And the aircraft's steady lights draw a faint line
    /// between the flashes, which a chance row of bright stars, as in the Milky Way, doesn't have.
    static func dashes(_ all: [Spot], frame: Int, reach: Double, residual: Residual) -> [NightSkyLine] {
        guard all.count >= 5 else { return [] }
        // With few spots, the flashes would be what's usual.
        let usual = all.count >= 20 ? NightSkyStars.median(all.map { Double($0.pixels) }) : 0
        let spots = all.filter { Double($0.pixels) >= max(12, 4 * usual) }
        guard spots.count >= 5 else { return [] }
        let cell = reach
        var grid: [SIMD2<Int>: [Int]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down))) }
        for (i, spot) in spots.enumerated() { grid[key(spot.center), default: []].append(i) }
        func near(_ p: SIMD2<Double>, within radius: Double) -> [Int] {
            let k = key(p)
            var result: [Int] = []
            for dy in -1...1 { for dx in -1...1 {
                for i in grid[k &+ SIMD2(dx, dy)] ?? [] where simd_distance(spots[i].center, p) <= radius { result.append(i) }
            }}
            return result
        }
        var used = Set<Int>(), found: [NightSkyLine] = []
        for i in spots.indices.sorted(by: { spots[$0].peak > spots[$1].peak }) where !used.contains(i) {
            for j in near(spots[i].center, within: reach) where j != i && !used.contains(j) {
                var step = spots[j].center - spots[i].center
                guard simd_length(step) >= 8 else { continue }
                // Spots by their place in the row, in steps from the first: gaps are flashes too faint to find.
                var row: [(spot: Int, place: Int)] = [(i, 0), (j, 1)]
                for direction in [1, -1] {
                    var place = direction > 0 ? 1 : 0, misses = 0
                    while misses <= 1 {
                        place += direction
                        let first = row.min { $0.place < $1.place }!, last = row.max { $0.place < $1.place }!
                        if last.place > first.place { step = (spots[last.spot].center - spots[first.spot].center) / Double(last.place - first.place) }
                        let predicted = spots[first.spot].center + Double(place - first.place) * step
                        // Flashes come evenly but a flash merged with the steady lights sits off its centre, so the next
                        // one may stray along the way, hardly across it.
                        let size = simd_length(step), u = step / size, n = SIMD2(-u.y, u.x)
                        func across(_ k: Int) -> Double { abs(simd_dot(spots[k].center - predicted, n)) }
                        let candidates = near(predicted, within: 0.3 * size).filter { k in
                            !used.contains(k) && !row.contains { $0.spot == k } && across(k) <= 2 + 0.05 * size
                        }
                        if let k = candidates.min(by: { simd_distance(spots[$0].center, predicted) < simd_distance(spots[$1].center, predicted) }) {
                            row.append((k, place)); misses = 0
                        } else { misses += 1 }
                    }
                }
                guard row.count >= 5 else { continue }
                let points = row.map { spots[$0.spot].center }
                let u = simd_normalize(step), origin = points.reduce(.zero, +) / Double(points.count)
                let projections = points.map { simd_dot($0 - origin, u) }
                let offsets = points.map { abs(simd_dot($0 - origin, SIMD2(-u.y, u.x))) }
                guard offsets.max()! <= 3 + 0.08 * simd_length(step) else { continue }
                // The middle half of each gap between flashes, away from their glare, should carry the steady lights.
                let places = row.sorted { $0.place < $1.place }
                var gaps = 0, lit = 0
                for (a, b) in zip(places, places.dropFirst()) {
                    let from = spots[a.spot].center, to = spots[b.spot].center, span = simd_distance(from, to)
                    guard span >= 8 else { continue }
                    let direction = (to - from) / span
                    gaps += 1
                    if let found = residual.strip(from: from + 0.25 * span * direction, along: direction, length: Int(span / 2), reach: 6),
                       found.median > residual.sigma { lit += 1 }
                }
                guard gaps > 0, Double(lit) >= 0.8 * Double(gaps) else { continue }
                used.formUnion(row.map(\.spot))
                // Wide enough to take every flash, and the steady lights beside them.
                let width = max(3, NightSkyStars.median(row.map { spots[$0.spot].size })) / 1.5 + offsets.max()!
                var line = NightSkyLine(frame: frame, start: origin + (projections.min()! - simd_length(step) / 2) * u,
                                        end: origin + (projections.max()! + simd_length(step) / 2) * u,
                                        width: width, pixels: row.count, peak: row.map { spots[$0.spot].peak }.max()!)
                line.kind = .track
                found.append(line)
                break
            }
        }
        return found
    }

    /// Star cores can split one trail; joins nearby collinear pieces from the same photo.
    static func joinCollinear(_ input: [NightSkyLine]) -> [NightSkyLine] {
        var found = input, changed = true
        while changed {
            changed = false
            outer: for i in found.indices { for j in found.indices where j > i {
                let a = found[i], b = found[j], d = a.end - a.start, e = b.end - b.start, length = simd_length(d), other = simd_length(e)
                guard length > 0, other > 0 else { continue }
                let cross = abs(d.x * e.y - d.y * e.x) / (length * other)
                // The longer one sets the direction; the gap is between the two along it, nothing where they overlap.
                let (axis, piece) = length >= other ? (a, b) : (b, a)
                let u = (axis.end - axis.start) / max(length, other), n = SIMD2(-u.y, u.x)
                let along = [piece.start, piece.end].map { simd_dot($0 - axis.start, u) }
                let gap = max(0, along.min()! - max(length, other), -along.max()!)
                let offset = [piece.start, piece.end].map { abs(simd_dot($0 - axis.start, n)) }.max()!
                // A short piece inside a wide line's footprint is part of it, whatever its own direction says.
                let inside = min(length, other) < max(length, other) / 2 && offset < axis.radius
                guard gap < 24, inside || (cross < 0.035 && offset < max(3, a.width + b.width)) else { continue }
                let projections = [a.start, a.end, b.start, b.end].map { simd_dot($0 - axis.start, u) }
                // Two lights side by side, as an aircraft's wingtips draw, are one line wide enough for both.
                var joined = NightSkyLine(frame: a.frame, start: axis.start + projections.min()! * u, end: axis.start + projections.max()! * u,
                                          width: max(axis.width, piece.width + offset / 1.5), pixels: a.pixels + b.pixels, peak: max(a.peak, b.peak))
                if a.kind == .track || b.kind == .track { joined.kind = .track }
                // Apart across, with sky between them, and alongside each other for most of the shorter one's length.
                let covered = max(0, min(max(length, other), along.max()!) - max(0, along.min()!)) / min(length, other)
                joined.sideBySide = a.sideBySide || b.sideBySide
                    || (min(length, other) > 0.3 * max(length, other) && covered > 0.5 && offset > (a.width + b.width) / 2 + 1)
                found[i] = joined
                found.remove(at: j)
                changed = true
                break outer
            }}
        }
        return found
    }

    /// How `b` lies against `a`, measured along the longer of the two: the angle between them (as a sine), how far `b`
    /// strays sideways from that line, the gap between them along it (0 where they overlap), and how much of the shorter
    /// one the other covers.
    static func relation(_ a: NightSkyLine, _ b: NightSkyLine) -> (angle: Double, offset: Double, gap: Double, overlap: Double)? {
        let d = a.end - a.start, e = b.end - b.start, length = simd_length(d), other = simd_length(e)
        guard length > 0, other > 0 else { return nil }
        let (axis, piece) = length >= other ? (a, b) : (b, a)
        let span = max(length, other), u = (axis.end - axis.start) / span, n = SIMD2(-u.y, u.x)
        let along = [piece.start, piece.end].map { simd_dot($0 - axis.start, u) }
        let covered = max(0, min(span, along.max()!) - max(0, along.min()!))
        return (abs(d.x * e.y - d.y * e.x) / (length * other), [piece.start, piece.end].map { abs(simd_dot($0 - axis.start, n)) }.max()!,
                max(0, along.min()! - span, -along.max()!), covered / min(length, other))
    }

    /// Marks lines that continue, roughly collinear, into a photo at most two apart: aircraft and satellites cross the
    /// frame over many exposures, while a meteor lasts a fraction of a second and two meteors in a row are almost never
    /// collinear. Short lines that come back in the same place in another photo are left out: a branch or a light that
    /// moved, not something in the sky. Then marks photos with four or more short lines that aren't tracks: a bump during
    /// the exposure trails the bright stars, and short meteors seldom come four to one exposure. Heuristics, not a classifier.
    /// `size` is the longer side of the photos in the lines' pixels.
    static func groupTracks(_ input: [NightSkyLine], size: Int = 1280) -> [NightSkyLine] {
        let short = 40.0, clutter = max(short, Double(size) / 32)
        func sameSpot(_ a: NightSkyLine, _ b: NightSkyLine) -> Bool {
            guard a.frame != b.frame, a.length < clutter, b.length < clutter, let r = relation(a, b) else { return false }
            return r.angle < 0.25 && r.offset < 6 + a.width + b.width && r.overlap > 0.4
        }
        let lines = input.filter { line in !input.contains { sameSpot(line, $0) } }
        var result = lines, parent = Array(lines.indices)
        func root(_ i: Int) -> Int { var p = i; while parent[p] != p { p = parent[p] }; return p }
        for i in lines.indices { for j in lines.indices where j > i {
            let a = lines[i], b = lines[j], gap = abs(a.frame - b.frame)
            guard gap > 0, gap <= 2, !sameSpot(a, b), let r = relation(a, b) else { continue }
            // An aircraft seen from close by curves and its lights sit apart, so the further along, the more it may stray.
            let reach = max(a.length, b.length) * 2
            if r.angle < 0.12, r.offset < max(12, 0.06 * r.gap) + a.width + b.width, r.gap < max(30, reach) { parent[root(j)] = root(i) }
        }}
        // Two lines side by side in one photo, too far apart to have been joined: wingtip lights, one aircraft.
        var pairs = Set<Int>()
        for i in lines.indices { for j in lines.indices where j > i && lines[j].frame == lines[i].frame {
            let a = lines[i], b = lines[j]
            guard min(a.length, b.length) > 0.3 * max(a.length, b.length), let r = relation(a, b),
                  r.angle < 0.05, r.overlap > 0.5, r.offset < 12 + a.width + b.width else { continue }
            parent[root(j)] = root(i); pairs.formUnion([i, j])
        }}
        var groups: [Int: Set<Int>] = [:]
        for i in lines.indices { groups[root(i), default: []].insert(lines[i].frame) }
        for i in result.indices where groups[root(i), default: []].count >= 2 || result[i].sideBySide || pairs.contains(i) { result[i].kind = .track }
        // An aircraft turning or climbing into view: a line in a track's photo or the next, starting about where the
        // track ends, at a modest angle to it. Repeated, so a run of such pieces joins in turn.
        var grown = true
        while grown {
            grown = false
            for i in result.indices where result[i].kind == .meteor {
                let a = result[i]
                let track = result.indices.first { k in
                    let b = result[k]
                    guard b.kind == .track, abs(a.frame - b.frame) <= 1, let r = relation(a, b), r.angle < 0.5 else { return false }
                    let ends = [a.start, a.end].flatMap { p in [b.start, b.end].map { simd_distance(p, $0) } }.min()!
                    return ends < 0.6 * max(a.length, b.length)
                }
                if let track { result[i].kind = .track; parent[root(i)] = root(track); grown = true }
            }
        }
        // Each aircraft's pieces share a group, numbered in the order the aircraft first appears.
        var numbers: [Int: Int] = [:]
        for i in result.indices where result[i].kind == .track {
            let r = root(i)
            if numbers[r] == nil { numbers[r] = numbers.count }
            result[i].group = numbers[r]
        }
        for frame in Set(result.map(\.frame)) {
            let shortLines = result.indices.filter { result[$0].frame == frame && result[$0].kind == .meteor && result[$0].length < short }
            if shortLines.count >= 4 { for i in shortLines { result[i].kind = .shake } }
        }
        return result
    }
}
