import Foundation

/// Horizontal run of foreground pixels: row `y`, columns `x0...x1` inclusive.
struct Run {
    var y: Int32
    var x0: Int32
    var x1: Int32
    var label: Int32
}

struct Component {
    var minX: Int, minY: Int, maxX: Int, maxY: Int
    var area: Int
    /// Indices into the run array, in raster order.
    var runs: [Int]
    var startX: Int { Int(minXOfFirstRun) }
    var startY: Int { minY }
    var minXOfFirstRun: Int32 = 0
}

/// Run-length based 8-connected component labelling with union-find.
struct ConnectedComponents {
    var runs: [Run] = []
    var components: [Component] = []

    init(_ image: BinaryImage) {
        let w = image.width, h = image.height
        var runs: [Run] = []
        runs.reserveCapacity(w * h / 64 + 16)
        var parent: [Int32] = []

        func find(_ a: Int32) -> Int32 {
            var a = a
            while parent[Int(a)] != a {
                parent[Int(a)] = parent[Int(parent[Int(a)])]
                a = parent[Int(a)]
            }
            return a
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra == rb { return }
            if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb }
        }

        image.pixels.withUnsafeBufferPointer { px in
            var prevStart = 0, prevEnd = 0 // run index range of the previous row
            for y in 0..<h {
                let rowStart = runs.count
                let base = y * w
                var x = 0
                while x < w {
                    if px[base + x] == 0 { x += 1; continue }
                    let x0 = x
                    while x < w && px[base + x] != 0 { x += 1 }
                    let x1 = x - 1
                    let label = Int32(runs.count)
                    parent.append(label)
                    var run = Run(y: Int32(y), x0: Int32(x0), x1: Int32(x1), label: label)
                    // 8-connectivity: previous row runs touching [x0-1, x1+1].
                    var p = prevStart
                    while p < prevEnd && Int(runs[p].x1) < x0 - 1 { p += 1 }
                    var q = p
                    while q < prevEnd && Int(runs[q].x0) <= x1 + 1 {
                        union(label, runs[q].label)
                        q += 1
                    }
                    if p < prevEnd { prevStart = p }
                    run.label = find(label)
                    runs.append(run)
                }
                prevStart = rowStart
                prevEnd = runs.count
            }
        }

        // Resolve labels and build components.
        var rootToComponent = [Int32: Int]()
        var comps: [Component] = []
        for i in 0..<runs.count {
            let root = find(runs[i].label)
            runs[i].label = root
            let r = runs[i]
            if let c = rootToComponent[root] {
                comps[c].minX = min(comps[c].minX, Int(r.x0))
                comps[c].maxX = max(comps[c].maxX, Int(r.x1))
                comps[c].maxY = Int(r.y)
                comps[c].area += Int(r.x1 - r.x0) + 1
                comps[c].runs.append(i)
            } else {
                rootToComponent[root] = comps.count
                comps.append(Component(minX: Int(r.x0), minY: Int(r.y), maxX: Int(r.x1), maxY: Int(r.y),
                                       area: Int(r.x1 - r.x0) + 1, runs: [i], minXOfFirstRun: r.x0))
            }
        }
        self.runs = runs
        self.components = comps
    }
}

/// Counts the vertices OpenCV's `findContours(..., CHAIN_APPROX_SIMPLE)` would keep for the
/// outer border of the 8-connected component containing `(startX, startY)`, which must be
/// its first foreground pixel in raster order. Stops early once `limit` is reached.
func contourVertexCount(image px: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int,
                        startX: Int, startY: Int, limit: Int) -> Int {
    // Moore neighbourhood, clockwise starting from west.
    let dx: [Int] = [-1, -1, 0, 1, 1, 1, 0, -1]
    let dy: [Int] = [0, -1, -1, -1, 0, 1, 1, 1]
    @inline(__always) func fg(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < w && y < h && px[y * w + x] != 0
    }

    var x = startX, y = startY
    var backtrack = 0 // index of neighbour direction to resume search from (west)
    // First move.
    var firstMove = -1
    for k in 0..<8 {
        let d = (backtrack + k) % 8
        if fg(x + dx[d], y + dy[d]) { firstMove = d; break }
    }
    if firstMove < 0 { return 1 } // isolated pixel

    var vertices = 0
    var prevDir = -1
    var dir = firstMove
    var steps = 0
    let maxSteps = 4 * (w * h) + 8
    while true {
        if dir != prevDir { vertices += 1; if vertices >= limit { return vertices } }
        prevDir = dir
        x += dx[dir]; y += dy[dir]
        steps += 1
        if steps > maxSteps { return vertices }
        // Next search starts at the neighbour after the one we came from, i.e. (dir + 5) % 8 is
        // the backtrack direction; the standard Moore rule starts searching from backtrack.
        backtrack = (dir + 5) % 8
        var next = -1
        for k in 0..<8 {
            let d = (backtrack + k) % 8
            if fg(x + dx[d], y + dy[d]) { next = d; break }
        }
        if next < 0 { return vertices }
        if x == startX && y == startY && next == firstMove { return vertices }
        dir = next
    }
}

struct ComponentFilter {
    var maxContourVertices: Int
    /// 0 = automatic (a quarter of the shorter image side).
    var maxBlobSize: Int
    var minBlobSize: Int
    var minContrast: Int
    var minSeedPixels: Int
    var maxBrightExcess: Int
    /// Width of the ring sampled around a blob for the contrast test.
    var ringWidth: Int
}

struct BlobStats {
    var contrast: Int
    var seedPixels: Int
    var brightExcess: Int
    /// Bounding box of the seed pixels (the spot itself, before dilation); the blob's box when it has none.
    var seedBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
}

/// Darkness of a blob's seed pixels and its brightest pixel, both relative to the median of the
/// ring around it, plus the number of seed pixels.
private func blobStats(_ c: Component, runs: [Run], width w: Int, height h: Int, ring: Int,
                       sample: (Int, Int, Int, Int) -> (gray: [UInt8], seeds: [UInt8])) -> BlobStats {
    let x0 = max(0, c.minX - ring), y0 = max(0, c.minY - ring)
    let x1 = min(w - 1, c.maxX + ring), y1 = min(h - 1, c.maxY + ring)
    let rw = x1 - x0 + 1, rh = y1 - y0 + 1
    let (gray, seeds) = sample(x0, y0, rw, rh)

    // Seed pixels inside the blob; fall back to the blob's own pixels when it has no seeds
    // (blobs that come from the global dark threshold only).
    var seedSum = 0, seedCount = 0, brightest = 0
    var box = (minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
    for ri in c.runs {
        let r = runs[ri]
        let row = (Int(r.y) - y0) * rw
        for x in Int(r.x0)...Int(r.x1) {
            let g = Int(gray[row + x - x0])
            if g > brightest { brightest = g }
            if seeds[row + x - x0] != 0 {
                seedSum += g; seedCount += 1
                box = (min(box.minX, x), min(box.minY, Int(r.y)), max(box.maxX, x), max(box.maxY, Int(r.y)))
            }
        }
    }
    if seedCount == 0 { box = (c.minX, c.minY, c.maxX, c.maxY) }
    let realSeeds = seedCount
    if seedCount == 0 {
        for ri in c.runs {
            let r = runs[ri]
            let row = (Int(r.y) - y0) * rw
            for x in Int(r.x0)...Int(r.x1) { seedSum += Int(gray[row + x - x0]); seedCount += 1 }
        }
    }
    guard seedCount > 0 else { return BlobStats(contrast: 0, seedPixels: 0, brightExcess: 0, seedBox: box) }

    var hist = [Int](repeating: 0, count: 256)
    var ringCount = 0
    for y in 0..<rh {
        let iy = y + y0
        let inRows = iy >= c.minY && iy <= c.maxY
        for x in 0..<rw {
            let ix = x + x0
            if inRows && ix >= c.minX && ix <= c.maxX { continue }
            hist[Int(gray[y * rw + x])] += 1; ringCount += 1
        }
    }
    guard ringCount > 0 else { return BlobStats(contrast: 0, seedPixels: realSeeds, brightExcess: 0, seedBox: box) }
    var acc = 0, median = 0
    for v in 0..<256 { acc += hist[v]; if acc * 2 >= ringCount { median = v; break } }
    return BlobStats(contrast: median - seedSum / seedCount, seedPixels: realSeeds, brightExcess: brightest - median, seedBox: box)
}

/// Selects the components that look like isolated dust spots (small, few contour vertices, darker
/// than their surroundings and without a bright pixel inside).
func dustBlobs(from combined: BinaryImage, filter: ComponentFilter,
               sample: (Int, Int, Int, Int) -> (gray: [UInt8], seeds: [UInt8])) -> [DustBlob] {
    let w = combined.width, h = combined.height
    let cc = ConnectedComponents(combined)
    var blobs: [DustBlob] = []
    let maxSide = filter.maxBlobSize > 0 ? filter.maxBlobSize : max(32, min(w, h) / 4)

    let candidates: [Int] = cc.components.indices.filter { i in
        let c = cc.components[i]
        let side = max(c.maxX - c.minX + 1, c.maxY - c.minY + 1)
        if side > maxSide { return false }
        if side < filter.minBlobSize { return false }
        if c.area < 2 { return false } // zero-area contour in OpenCV (m00 == 0)
        return true
    }

    var vertexCounts = [Int](repeating: 0, count: candidates.count)
    // Each worker writes its own slot through the buffer pointer: subscripting the array itself from several
    // threads would be overlapping accesses to one variable.
    vertexCounts.withUnsafeMutableBufferPointer { counts in
        let counts = counts
        combined.pixels.withUnsafeBufferPointer { px in
            DispatchQueue.concurrentPerform(iterations: candidates.count) { k in
                let c = cc.components[candidates[k]]
                counts[k] = contourVertexCount(image: px, width: w, height: h,
                                               startX: c.startX, startY: c.startY,
                                               limit: filter.maxContourVertices)
            }
        }
    }

    for (k, ci) in candidates.enumerated() {
        let vc = vertexCounts[k]
        if vc >= filter.maxContourVertices { continue }
        let c = cc.components[ci]
        // Thin (one pixel wide) contours have zero polygon area in OpenCV and are skipped.
        if c.maxX == c.minX || c.maxY == c.minY { continue }
        let st = blobStats(c, runs: cc.runs, width: w, height: h, ring: filter.ringWidth, sample: sample)
        if filter.minContrast > 0 && st.contrast < filter.minContrast { continue }
        if filter.minSeedPixels > 0 && st.seedPixels < filter.minSeedPixels { continue }
        if filter.maxBrightExcess > 0 && st.brightExcess > filter.maxBrightExcess { continue }
        blobs.append(DustBlob(id: blobs.count, minX: c.minX, minY: c.minY, maxX: c.maxX, maxY: c.maxY,
                              area: c.area, contourVertices: vc, contrast: st.contrast,
                              seedPixels: st.seedPixels, brightExcess: st.brightExcess,
                              seedMinX: st.seedBox.minX, seedMinY: st.seedBox.minY, seedMaxX: st.seedBox.maxX, seedMaxY: st.seedBox.maxY))
    }
    return blobs
}
