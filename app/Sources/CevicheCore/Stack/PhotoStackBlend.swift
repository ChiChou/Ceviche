import Foundation
import simd

/// Lighten and Darken: lighting passes combined over a base, each pass adding (or taking) light with its own strength
/// and where it isn't brushed out.
///
/// The passes meet in a soft maximum, not the plain one. The brightest value of every pixel is also the brightest
/// noise: over five passes plain Lighten lifts the shadows by 0.66 stop. Here each pass is weighed by
/// exp((g − g_max) / τ) on its luminance smoothed over about 4 pixels, with τ the noise of that smoothed luminance at
/// the pixel's level: passes that agree within the noise are averaged (shadows within 0.02 stop of the truth, colour
/// noise of one frame), and a clearly brighter pass wins outright. Whole pixels are weighed, so the channels stay
/// together.
enum PhotoStackBlend {
    /// Fills `out` with row `y` of frame `frame` as RGBA, coverage in alpha.
    typealias Rows = (_ frame: Int, _ y: Int, _ out: UnsafeMutablePointer<Float>) -> Void

    struct Pass {
        /// How much of the light the pass adds over the base is used, 0…1.
        var strength: Float = 1
        /// Where the pass is brushed out, 1 where wholly, on a grid of `hiddenWidth` columns scaled to the picture.
        var hidden: [Float]?
        var hiddenWidth = 0
    }

    /// "Strokes only" lets a pass add light only where it is this far above the base, fading in to twice that: for
    /// light painting on black, where every pass also spills a little light on the room. It cuts real faint light
    /// too (−1.3 stop in the shadows of interior passes), so it is a choice.
    static let strokeGate: Float = 0.02

    /// The noise of the smoothed luminance against its level, measured where frames agree.
    struct Noise {
        static let bins = 28, low: Float = 1e-4, high: Float = 8
        var sigma = [Float](repeating: 0, count: bins)

        static func bin(_ level: Float) -> Float {
            let t = (log(max(level, low)) - log(low)) / (log(high) - log(low))
            return max(0, min(Float(bins - 1), t * Float(bins - 1)))
        }
        func tau(_ level: Float) -> Float {
            let b = Self.bin(level), i = Int(b), j = min(Self.bins - 1, i + 1), f = b - Float(i)
            // Never zero: identical samples (8-bit darks) would otherwise divide by nothing.
            return max(sigma[i] + (sigma[j] - sigma[i]) * f, 1e-5 + 0.001 * level)
        }
    }

    /// The smoothing radius for a picture this wide next to the analysis size it was measured at: two passes of a box
    /// of radius 4 at full size, about 4 pixels' standard deviation.
    static func radius(width: Int, fullWidth: Int) -> Int { max(1, Int((4 * Double(width) / Double(max(width, fullWidth))).rounded())) }

    /// Rows y0..<y1 of every frame's smoothed luminance, `frames` planes of (y1 − y0) × width.
    private static func guides(frames: Int, rows: Rows, width: Int, height: Int, y0: Int, y1: Int, radius: Int) -> [[Float]] {
        let margin = 2 * radius, top = max(0, y0 - margin), bottom = min(height, y1 + margin), count = bottom - top
        var row = [Float](repeating: 0, count: width * 4)
        return (0..<frames).map { k in
            var plane = [Float](repeating: 0, count: count * width)
            for y in top..<bottom {
                row.withUnsafeMutableBufferPointer { rows(k, y, $0.baseAddress!) }
                for x in 0..<width where row[x * 4 + 3] > 0.5 {
                    plane[(y - top) * width + x] = 0.2126 * row[x * 4] + 0.7152 * row[x * 4 + 1] + 0.0722 * row[x * 4 + 2]
                }
            }
            for _ in 0..<2 { plane = PhotoStackRegions.blurred(plane, width: width, height: count, radius: radius) }
            return Array(plane[((y0 - top) * width)..<((y1 - top) * width)])
        }
    }

    /// The noise of the smoothed luminance, from the differences between consecutive frames in bands spread over the
    /// picture. Lighting passes differ wherever their light does, so each level takes the lowest fifth of the
    /// differences, where two frames show the same thing, and the pair that agrees best. One frame's high-pass would
    /// not do: after demosaicing the noise is correlated, and reads 0.07–0.7 of its true size.
    static func noise(frames: Int, rows: Rows, width: Int, height: Int, radius: Int) -> Noise {
        var noise = Noise()
        guard frames >= 2 else { return noise }
        let bandRows = min(height, 48), bands = max(1, min(12, height / bandRows))
        var samples = [[[Float]]](repeating: [[Float]](repeating: [], count: Noise.bins), count: frames - 1)
        for b in 0..<bands {
            let y0 = min(height - bandRows, (2 * b + 1) * height / (2 * bands)), g = guides(frames: frames, rows: rows, width: width, height: height, y0: y0, y1: y0 + bandRows, radius: radius)
            for pair in 0..<(frames - 1) {
                for i in stride(from: pair % 3, to: g[pair].count, by: 3) {
                    let a = g[pair][i], c = g[pair + 1][i]
                    // Half the level apart is light, not noise: a level only one pass reaches would otherwise
                    // measure that pass's light.
                    let level = 0.5 * (a + c), difference = abs(a - c)
                    guard a > Noise.low, c > Noise.low, difference < 0.5 * level + 0.002 else { continue }
                    samples[pair][Int(Noise.bin(level).rounded())].append(difference)
                }
            }
        }
        var measured = [Float?](repeating: nil, count: Noise.bins)
        for bin in 0..<Noise.bins {
            for pair in 0..<(frames - 1) where samples[pair][bin].count >= 200 {
                var values = samples[pair][bin]
                values.sort()
                // The 20th percentile of |N(0, s)| is 0.2533 s, and the difference of two frames has s = √2 σ.
                let sigma = values[values.count / 5] / (0.2533 * Float(2).squareRoot())
                measured[bin] = min(measured[bin] ?? .infinity, sigma)
            }
        }
        // Levels the bands didn't reach take their neighbour's; noise doesn't fall as the level rises.
        guard let first = measured.firstIndex(where: { $0 != nil }) else { return noise }
        var last = measured[first]!
        for bin in 0..<Noise.bins {
            if bin >= first, let value = measured[bin] { last = max(last, value) }
            noise.sigma[bin] = last
        }
        return noise
    }

    /// The passes over the base into `out` (RGBA). Frame 0 of `rows` is the base and frame k + 1 is `passes[k]`.
    static func blend(passes: [Pass], rows: Rows, width: Int, height: Int, radius: Int, noise: Noise, darken: Bool, strokesOnly: Bool,
                      into out: UnsafeMutablePointer<Float>, cancelled: @escaping @Sendable () -> Bool = { false }) {
        let frames = passes.count + 1, bandRows = 64, bands = (height + bandRows - 1) / bandRows
        let sign: Float = darken ? -1 : 1
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            guard !cancelled() else { return }
            let y0 = band * bandRows, y1 = min(height, y0 + bandRows)
            let guide = guides(frames: frames, rows: rows, width: width, height: height, y0: y0, y1: y1, radius: radius)
            var base = [Float](repeating: 0, count: width * 4), row = base
            // How much of each pass's difference from the base is used at each pixel, then its weight.
            var amount = [Float](repeating: 0, count: passes.count * width), best = [Float](repeating: 0, count: width)
            var sum = [Float](repeating: 0, count: width * 3), total = [Float](repeating: 0, count: width)
            for y in y0..<y1 {
                let line = (y - y0) * width
                base.withUnsafeMutableBufferPointer { rows(0, y, $0.baseAddress!) }
                for x in 0..<width { best[x] = guide[0][line + x] * sign }
                for (k, pass) in passes.enumerated() {
                    for x in 0..<width {
                        let lift = guide[k + 1][line + x] - guide[0][line + x]
                        var a = pass.strength
                        if strokesOnly, !darken { a *= smoothstep(strokeGate, 2 * strokeGate, lift) }
                        if let hidden = pass.hidden, a > 0 { a *= 1 - sample(hidden, width: pass.hiddenWidth, x: x, y: y, scale: Float(pass.hiddenWidth) / Float(width)) }
                        amount[k * width + x] = a
                        best[x] = max(best[x], (guide[0][line + x] + a * lift) * sign)
                    }
                }
                for x in 0..<width {
                    total[x] = exp((guide[0][line + x] * sign - best[x]) / noise.tau(best[x] * sign))
                    for c in 0..<3 { sum[x * 3 + c] = base[x * 4 + c] * total[x] }
                }
                for k in passes.indices {
                    row.withUnsafeMutableBufferPointer { rows(k + 1, y, $0.baseAddress!) }
                    for x in 0..<width {
                        let a = amount[k * width + x]
                        guard a > 0, row[x * 4 + 3] > 0.5 else { continue }
                        let own = guide[0][line + x] + a * (guide[k + 1][line + x] - guide[0][line + x])
                        let w = exp((own * sign - best[x]) / noise.tau(best[x] * sign))
                        guard w > 1e-6 else { continue }
                        total[x] += w
                        for c in 0..<3 { sum[x * 3 + c] += (base[x * 4 + c] + a * (row[x * 4 + c] - base[x * 4 + c])) * w }
                    }
                }
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    for c in 0..<3 { out[o + c] = sum[x * 3 + c] / total[x] }
                    out[o + 3] = 1
                }
            }
        }
    }

    @inline(__always) private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// `plane` (of `width` columns) at picture pixel (x, y), bilinear; `scale` is plane pixels per picture pixel.
    @inline(__always) private static func sample(_ plane: [Float], width: Int, x: Int, y: Int, scale: Float) -> Float {
        let height = plane.count / width
        let fx = max(0, min(Float(width - 1), (Float(x) + 0.5) * scale - 0.5)), fy = max(0, min(Float(height - 1), (Float(y) + 0.5) * scale - 0.5))
        let x0 = Int(fx), y0 = Int(fy), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1), tx = fx - Float(x0), ty = fy - Float(y0)
        let top = plane[y0 * width + x0] * (1 - tx) + plane[y0 * width + x1] * tx, bottom = plane[y1 * width + x0] * (1 - tx) + plane[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }
}
