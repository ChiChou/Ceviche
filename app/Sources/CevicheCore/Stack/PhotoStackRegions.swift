import Foundation
import simd

/// Action Sequence's choice of photo, by region: wherever a photo differs from the background (the median), the
/// connected region is one candidate and is shown whole or not at all. Chosen pixel by pixel, subjects that touch or
/// overlap come out as a collage of several photos (photo changes per 1000 moving pixels: 153 against 45 by region,
/// and up to 10 of 12 cars torn against none on CDnet's highway).
enum PhotoStackRegions {
    /// A photo differs from the background where the difference, relative to the background's luminance plus
    /// `absolute`, passes this.
    static let threshold: Float = 0.25, absolute: Float = 0.02
    /// A candidate is left out when the regions already chosen cover more than this share of it: overlaps are
    /// resolved by leaving a subject out, never by mixing two.
    static let overlapLimit = 0.2

    /// The key of the median's plane among the photos' in `Choice.planes`.
    static let median = -1

    struct Choice {
        /// Per photo with a region (or `median`), how much of each pixel it shows instead of the stack, feathered a
        /// little.
        var planes: [Int: [Float]] = [:]
        /// Candidates left out because a chosen region was in their place.
        var leftOut = 0
    }

    private struct Candidate { let photo: Int; let pixels: [Int32]; let score: Float }

    /// `frames` are RGBA with coverage in alpha, aligned, `gains` their exposure multipliers and `photos` the index
    /// each is known by, in capture order; `background` is their median, RGBA.
    static func choose(frames: [[Float]], gains: [Float], photos: [Int], background: [Float], width: Int, height: Int,
                       overlap: PhotoStackOverlap) -> Choice {
        let pixels = width * height
        // Scaled from the sizes measured at 2000 px: 2 px closing, 150 px regions, a 12 px border where alignment
        // leaves a photo's edge.
        let closing = width >= 1200 ? 2 : 1, minimum = max(20, pixels / 18_000), border = max(2, width / 160)
        var found = [[Candidate]](repeating: [], count: frames.count)
        found.withUnsafeMutableBufferPointer { found in
            let found = found
            DispatchQueue.concurrentPerform(iterations: frames.count) { k in
                guard !Task.isCancelled else { return }
                let frame = frames[k], gain = gains[k]
                var difference = [Float](repeating: 0, count: pixels), mask = [UInt8](repeating: 0, count: pixels)
                for y in border..<max(border, height - border) {
                    for x in border..<max(border, width - border) {
                        let i = y * width + x, p = i * 4
                        guard frame[p + 3] > 0.999 else { continue }
                        let middle = SIMD3(background[p], background[p + 1], background[p + 2])
                        let d = simd_length(SIMD3(frame[p], frame[p + 1], frame[p + 2]) * gain - middle) / (PhotoStackReduce.luminance(middle) + absolute)
                        difference[i] = d
                        if d > threshold { mask[i] = 1 }
                    }
                }
                close(&mask, width: width, height: height, radius: closing)
                found[k] = components(mask, width: width, height: height, minimum: minimum).map { region in
                    Candidate(photo: photos[k], pixels: region, score: region.reduce(0) { $0 + difference[Int($1)] })
                }
            }
        }
        let candidates = found.flatMap { $0 }.sorted { a, b in
            switch overlap {
            case .strongest: a.score > b.score
            case .earliest: a.photo != b.photo ? a.photo < b.photo : a.score > b.score
            case .latest: a.photo != b.photo ? a.photo > b.photo : a.score > b.score
            }
        }
        var source = [Int32](repeating: -1, count: pixels)
        var choice = Choice()
        var shown = Set<Int>()
        for candidate in candidates {
            let taken = candidate.pixels.reduce(0) { $0 + (source[Int($1)] >= 0 ? 1 : 0) }
            if Double(taken) > overlapLimit * Double(candidate.pixels.count) { choice.leftOut += 1; continue }
            for p in candidate.pixels where source[Int(p)] < 0 { source[Int(p)] = Int32(candidate.photo) }
            shown.insert(candidate.photo)
        }
        // Feathered, so a whole subject doesn't get a cut-out edge. A blur of a partition: the weights never sum past 1.
        let feather = max(1, width / 800)
        for photo in shown {
            var plane = [Float](repeating: 0, count: pixels)
            for i in 0..<pixels where source[i] == Int32(photo) { plane[i] = 1 }
            choice.planes[photo] = blurred(plane, width: width, height: height, radius: feather)
        }
        return choice
    }

    /// Grows the mask by `radius` and shrinks it again (4-neighbours), which closes the gaps inside a subject.
    static func close(_ mask: inout [UInt8], width: Int, height: Int, radius: Int) {
        func step(_ source: [UInt8], grow: Bool) -> [UInt8] {
            var out = source
            let set: UInt8 = grow ? 1 : 0
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard source[i] != set else { continue }
                    if (x > 0 && source[i - 1] == set) || (x < width - 1 && source[i + 1] == set)
                        || (y > 0 && source[i - width] == set) || (y < height - 1 && source[i + width] == set) { out[i] = set }
                }
            }
            return out
        }
        for _ in 0..<radius { mask = step(mask, grow: true) }
        for _ in 0..<radius { mask = step(mask, grow: false) }
    }

    /// The mask's connected regions (4-neighbours) of at least `minimum` pixels, as pixel indices.
    static func components(_ mask: [UInt8], width: Int, height: Int, minimum: Int) -> [[Int32]] {
        var seen = [Bool](repeating: false, count: mask.count), regions: [[Int32]] = [], stack: [Int32] = []
        for start in mask.indices where mask[start] != 0 && !seen[start] {
            var region: [Int32] = []
            seen[start] = true; stack.append(Int32(start))
            while let p = stack.popLast() {
                region.append(p)
                let i = Int(p), x = i % width, y = i / width
                if x > 0, mask[i - 1] != 0, !seen[i - 1] { seen[i - 1] = true; stack.append(p - 1) }
                if x < width - 1, mask[i + 1] != 0, !seen[i + 1] { seen[i + 1] = true; stack.append(p + 1) }
                if y > 0, mask[i - width] != 0, !seen[i - width] { seen[i - width] = true; stack.append(p - Int32(width)) }
                if y < height - 1, mask[i + width] != 0, !seen[i + width] { seen[i + width] = true; stack.append(p + Int32(width)) }
            }
            if region.count >= minimum { regions.append(region) }
        }
        return regions
    }

    /// A box blur of `radius` each way, edges repeated.
    static func blurred(_ plane: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let span = Float(2 * radius + 1)
        var across = [Float](repeating: 0, count: plane.count), out = across
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for d in -radius...radius { sum += plane[y * width + max(0, min(width - 1, x + d))] }
                across[y * width + x] = sum / span
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for d in -radius...radius { sum += across[max(0, min(height - 1, y + d)) * width + x] }
                out[y * width + x] = sum / span
            }
        }
        return out
    }
}
