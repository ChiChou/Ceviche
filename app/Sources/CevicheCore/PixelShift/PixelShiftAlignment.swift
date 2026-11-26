// Pixel Shift is the Mac app's alone: a sixteen-shot set peaks at 13.8 GB, more than iOS gives an app, so the iPad and
// iPhone build leaves the whole tool out.
#if os(macOS)
import Foundation

/// One shot's sensor samples normalized to 0…1 per CFA position (black subtracted, divided by white − black).
struct PixelShiftCFA {
    let samples: UnsafePointer<UInt16>
    let width: Int, height: Int
    let black: [Float], scale: [Float]

    @inline(__always) func value(_ x: Int, _ y: Int) -> Float {
        let p = (y & 1) * 2 + (x & 1)
        return (Float(samples[y * width + x]) - black[p]) * scale[p]
    }
    /// Mean of the 2×2 block at (x, y): one red, two greens and one blue whatever the CFA phase, so blocks of shots
    /// moved by any whole number of pixels compare directly.
    @inline(__always) func block(_ x: Int, _ y: Int) -> Float {
        0.25 * (value(x, y) + value(x + 1, y) + value(x, y + 1) + value(x + 1, y + 1))
    }
    /// Blocks smoothed by a 3×3 binomial, so sampling between them is close to band-limited.
    @inline(__always) func smooth(_ x: Int, _ y: Int) -> Float {
        let a = block(x - 1, y - 1) + block(x + 1, y - 1) + block(x - 1, y + 1) + block(x + 1, y + 1)
        let b = block(x, y - 1) + block(x - 1, y) + block(x + 1, y) + block(x, y + 1)
        return (a + 2 * b + 4 * block(x, y)) / 16
    }
    @inline(__always) func smooth(_ x: Float, _ y: Float) -> Float {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Float(x0), fy = y - Float(y0)
        let top = smooth(x0, y0) * (1 - fx) + smooth(x0 + 1, y0) * fx
        let bottom = smooth(x0, y0 + 1) * (1 - fx) + smooth(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

struct PixelShiftOffset: Sendable, Equatable {
    /// Whole-pixel offset: the scene at the first shot's pixel p is at p − offset in this shot.
    var dx: Int, dy: Int
    /// The same offset measured to a fraction of a pixel.
    var subX: Double, subY: Double
    /// Multiplies this shot's samples to match the first shot's exposure.
    var gain: Float
    /// Spread of block differences per √signal after alignment: the noise scale motion is measured in.
    var sigma: Float
}

enum PixelShiftAligner {
    static let readFloor: Float = 1e-4
    static let search = 3

    /// Finds a shot's offset from the first by matching 2×2 blocks on a sparse grid over the central 70 %: a
    /// whole-pixel search, then Lucas-Kanade on smoothed blocks for the fraction. A parabola through the whole-pixel
    /// errors can't place half-pixel shots. With `known`, the camera's own movement (Pentax) is taken as it is and
    /// only the exposure and noise are measured: a scene that is hard to match can't throw it off.
    static func align(reference: PixelShiftCFA, frame: PixelShiftCFA, known: (dx: Int, dy: Int)? = nil) -> PixelShiftOffset {
        let w = reference.width, h = reference.height
        let x0 = w * 15 / 100, x1 = w * 85 / 100, y0 = h * 15 / 100, y1 = h * 85 / 100
        var points: [(Int, Int)] = []
        for y in stride(from: y0, to: y1, by: 3) { for x in stride(from: x0, to: x1, by: 3) { points.append((x, y)) } }
        // Neither clipped nor black.
        let usable = points.filter { let v = reference.block($0.0, $0.1); return v > 0.005 && v < 0.85 }
        if usable.count >= 1000 { points = usable }

        var sumReference = 0.0, sumFrame = 0.0
        for (x, y) in points { sumReference += Double(reference.block(x, y)); sumFrame += Double(frame.block(x, y)) }
        var gain = Float(sumReference / max(sumFrame, 1e-9))

        if let known {
            return measured(reference: reference, frame: frame, points: points, gain: gain, dx: known.dx, dy: known.dy, tx: Float(known.dx), ty: Float(known.dy))
        }
        let n = 2 * search + 1
        var errors = [Double](repeating: 0, count: n * n)
        errors.withUnsafeMutableBufferPointer { errors in
            let errors = errors
            DispatchQueue.concurrentPerform(iterations: n * n) { i in
                let dx = i % n - search, dy = i / n - search
                var e = 0.0
                for (x, y) in points {
                    let d = frame.block(x - dx, y - dy) * gain - reference.block(x, y)
                    e += Double(d * d)
                }
                errors[i] = e
            }
        }
        let best = errors.indices.min { errors[$0] < errors[$1] }!
        let dx = best % n - search, dy = best / n - search

        let sparse = stride(from: 0, to: points.count, by: 4).map { points[$0] }
        let fixed = sparse.map { (x, y) -> (r: Float, gx: Float, gy: Float) in
            (reference.smooth(x, y), 0.5 * (reference.smooth(x + 1, y) - reference.smooth(x - 1, y)), 0.5 * (reference.smooth(x, y + 1) - reference.smooth(x, y - 1)))
        }
        var tx = Float(dx), ty = Float(dy)
        for _ in 0..<8 {
            var axx = 0.0, axy = 0.0, ayy = 0.0, bx = 0.0, by = 0.0
            for (i, (x, y)) in sparse.enumerated() {
                let f = fixed[i]
                let e = Double(frame.smooth(Float(x) - tx, Float(y) - ty) * gain - f.r)
                let gx = Double(f.gx), gy = Double(f.gy)
                axx += gx * gx; axy += gx * gy; ayy += gy * gy; bx += gx * e; by += gy * e
            }
            let det = axx * ayy - axy * axy
            guard det > 0 else { break }
            let ux = Float((ayy * bx - axy * by) / det), uy = Float((axx * by - axy * bx) / det)
            // A step that leaves the searched range means the shots don't match; keep the whole-pixel answer.
            guard abs(tx + ux - Float(dx)) < 1.5, abs(ty + uy - Float(dy)) < 1.5 else { tx = Float(dx); ty = Float(dy); break }
            tx += ux; ty += uy
            if abs(ux) < 0.001 && abs(uy) < 0.001 { break }
        }

        return measured(reference: reference, frame: frame, points: points, gain: gain, dx: dx, dy: dy, tx: tx, ty: ty)
    }

    /// The gain again at the found offset, as a median ratio, then the noise scale.
    private static func measured(reference: PixelShiftCFA, frame: PixelShiftCFA, points: [(Int, Int)], gain: Float,
                                 dx: Int, dy: Int, tx: Float, ty: Float) -> PixelShiftOffset {
        var gain = gain
        var ratios: [Float] = []; ratios.reserveCapacity(points.count)
        for (x, y) in points {
            let f = frame.block(x - dx, y - dy)
            if f > 0.01 { ratios.append(reference.block(x, y) / f) }
        }
        ratios.sort()
        if !ratios.isEmpty { gain = ratios[ratios.count / 2] }
        var residuals: [Float] = points.map { (x, y) in
            let r = reference.block(x, y)
            return abs(frame.block(x - dx, y - dy) * gain - r) / (max(r, 0) + readFloor).squareRoot()
        }
        residuals.sort()
        let sigma = max(1e-4, 1.4826 * residuals[residuals.count / 2])
        return PixelShiftOffset(dx: dx, dy: dy, subX: Double(tx), subY: Double(ty), gain: gain, sigma: sigma)
    }
}
#endif
