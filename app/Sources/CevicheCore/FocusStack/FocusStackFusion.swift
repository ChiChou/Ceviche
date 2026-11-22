import Foundation
import simd

/// Everything the merge needs to add one photo at a given resolution, decided by analysis.
struct FocusStackFrameStep {
    var index: Int
    /// Maps output pixels (continuous, top-left origin) into the photo's pixels at the merge's resolution.
    var inverse: HDRSimilarity
    /// Brings the photo to the reference's exposure.
    var gain: Float
    var clip: Float
    /// White-noise variance of the photo's sharpness proxy at the merge's resolution, after `gain`.
    var noise: Float
    /// The photo's weight from analysis on the prior grid: edge-aware label weights or multiscale fusion weights.
    var prior: [Float]
}

/// The shared part of a merge at one resolution.
struct FocusStackLayout {
    var width: Int
    var height: Int
    var blending: FocusStackBlending
    /// The bracket's typical noise variance at this resolution, the scale sharpness is measured against.
    var noise: Float
    /// Size of the prior grid, and how output pixels map onto it: prior = (output + offset) · scale.
    var priorWidth: Int
    var priorHeight: Int
    var priorOffset: SIMD2<Double>
    var priorScale: Double
    /// On the prior grid, how fully the layer brush decided each pixel, 0 to 1; there local sharpness at the merge's
    /// resolution no longer refines the painted weights. Nil where nothing is painted.
    var painted: [Float]? = nil

    /// How strongly local sharpness at the merge's resolution refines the analysis weights, per nat of signal-to-noise.
    static let refinement: Float = 1
    /// Weight logits for photos analysis all but ruled out.
    static let floorWeight: Float = 1e-4

    var levels: Int { max(1, min(8, Int(log2(Double(min(width, height)))) - 3)) }

    @inline(__always) func priorPoint(_ x: Int, _ y: Int) -> (Double, Double) {
        ((Double(x) + 0.5 + priorOffset.x) * priorScale - 0.5, (Double(y) + 0.5 + priorOffset.y) * priorScale - 0.5)
    }
}

/// The merge on the CPU, one photo at a time. Edge-aware label blending keeps a running weighted sum whose weights are
/// a softmax over photos of (log analysis weight + local fine-band sharpness), kept stable as photos arrive by rescaling
/// the sum whenever a pixel's best logit rises. Multiscale fusion accumulates each photo's Laplacian pyramid weighted by
/// the Gaussian pyramid of its analysis weight, and collapses the normalized sum at the end. Either way, one weight per
/// pixel serves all three channels, so the blend can't fringe colors.
final class FocusStackCPUFusion {
    let layout: FocusStackLayout
    /// Labels: RGB × weight and weight, per pixel; the running maximum logit beside it.
    private var sum: [Float] = []
    private var peak: [Float] = []
    /// Multiscale: per level, RGB × weight and weight.
    private var pyramid: [(width: Int, height: Int, values: [Float])] = []

    init(layout: FocusStackLayout) {
        self.layout = layout
        switch layout.blending {
        case .labels:
            sum = [Float](repeating: 0, count: layout.width * layout.height * 4)
            peak = [Float](repeating: -.infinity, count: layout.width * layout.height)
        case .multiscale:
            var w = layout.width, h = layout.height
            for _ in 0..<layout.levels {
                pyramid.append((w, h, [Float](repeating: 0, count: w * h * 4)))
                w = (w + 1) / 2; h = (h + 1) / 2
            }
        }
    }

    func add(_ frame: PanoramaFrame, _ step: FocusStackFrameStep, isReference: Bool) {
        var rgba = Self.warp(frame, step.inverse, gain: step.gain, width: layout.width, height: layout.height)
        switch layout.blending {
        case .labels: addLabels(rgba, step)
        case .multiscale:
            for y in 0..<layout.height { for x in 0..<layout.width {
                let p = (y * layout.width + x) * 4
                let (px, py) = layout.priorPoint(x, y)
                let prior = HDRMerger.sampleMap(step.prior, layout.priorWidth, layout.priorHeight, x: px, y: py)
                // The reference keeps a trace of weight so every covered pixel has a source.
                rgba[p + 3] *= isReference ? max(prior, 1e-6) : prior
            }}
            addPyramid(rgba)
        }
    }

    /// Resamples `frame` onto the output grid with a Catmull-Rom cubic, times `gain`: fine detail keeps its contrast,
    /// where bilinear sampling would soften exactly what focus stacking is for. Alpha is 1 where the photo covers the
    /// point; beyond its edge the nearest edge pixels are repeated with alpha 0, so blurs near the edge see no black border.
    static func warp(_ frame: PanoramaFrame, _ inverse: HDRSimilarity, gain: Float, width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 4)
        frame.pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { out in
                let out = out
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let p = inverse.apply(SIMD2(Double(x) + 0.5, Double(y) + 0.5)) - 0.5
                        let inside = p.x >= -0.5 && p.y >= -0.5 && p.x <= Double(frame.width) - 0.5 && p.y <= Double(frame.height) - 0.5
                        let sample = simd_max(cubic(source, frame.width, frame.height, Float(p.x), Float(p.y)), .zero) * gain
                        let o = (y * width + x) * 4
                        out[o] = sample.x; out[o + 1] = sample.y; out[o + 2] = sample.z; out[o + 3] = inside ? 1 : 0
                    }
                }
            }
        }
        return out
    }

    @inline(__always) static func cubicWeights(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t, t3 = t2 * t
        return SIMD4(-t3 + 2 * t2 - t, 3 * t3 - 5 * t2 + 2, -3 * t3 + 4 * t2 + t, t3 - t2) * 0.5
    }

    /// Catmull-Rom sample at (x, y) in pixel indices, with taps clamped to the photo.
    @inline(__always) static func cubic(_ pixels: UnsafeBufferPointer<Float>, _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> SIMD3<Float> {
        let cx = max(0, min(Float(width - 1), x)), cy = max(0, min(Float(height - 1), y))
        let x0 = Int(cx), y0 = Int(cy)
        let wx = cubicWeights(cx - Float(x0)), wy = cubicWeights(cy - Float(y0))
        var sum = SIMD3<Float>.zero
        for j in 0..<4 {
            let row = max(0, min(height - 1, y0 - 1 + j)) * width
            var line = SIMD3<Float>.zero
            for i in 0..<4 {
                let p = (row + max(0, min(width - 1, x0 - 1 + i))) * 4
                line += wx[i] * SIMD3(pixels[p], pixels[p + 1], pixels[p + 2])
            }
            sum += wy[j] * line
        }
        return sum
    }

    /// The fine-band energy the merge refines with, from a warped photo.
    static func fineEnergy(_ rgba: [Float], width: Int, height: Int) -> [Float] {
        let proxy = FocusStackFocus.proxy(rgba)
        let blurred = FocusStackFilters.gaussian(proxy, width: width, height: height, sigma: FocusStackFocus.sigmas[0])
        var squares = [Float](repeating: 0, count: proxy.count)
        for k in squares.indices { let d = proxy[k] - blurred[k]; squares[k] = d * d }
        return FocusStackFilters.gaussian(squares, width: width, height: height, sigma: FocusStackFocus.windows[0])
    }

    @inline(__always) static func logit(prior: Float, energy: Float, noise: Float, reference: Float, peak: Float, clip: Float, painted: Float = 0) -> Float {
        let gain = FocusStackFocus.noiseGains[0]
        var value = log(max(prior, FocusStackLayout.floorWeight))
            + FocusStackLayout.refinement * (1 - painted) * log(1 + max(0, energy - 2 * noise * gain) / (reference * gain + 1e-8))
        if peak > 0.95 * clip { value -= 2 }
        return value
    }

    private func addLabels(_ rgba: [Float], _ step: FocusStackFrameStep) {
        let width = layout.width, height = layout.height, layout = self.layout
        let energy = Self.fineEnergy(rgba, width: width, height: height)
        let clip = step.clip * step.gain
        sum.withUnsafeMutableBufferPointer { sum in
            peak.withUnsafeMutableBufferPointer { peak in
                let sum = sum, peak = peak
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let i = y * width + x, p = i * 4
                        guard rgba[p + 3] > 0.999 else { continue }
                        let (px, py) = layout.priorPoint(x, y)
                        let prior = HDRMerger.sampleMap(step.prior, layout.priorWidth, layout.priorHeight, x: px, y: py)
                        let painted = layout.painted.map { HDRMerger.sampleMap($0, layout.priorWidth, layout.priorHeight, x: px, y: py) } ?? 0
                        let value = Self.logit(prior: prior, energy: energy[i], noise: step.noise, reference: layout.noise,
                                               peak: max(rgba[p], rgba[p + 1], rgba[p + 2]), clip: clip, painted: painted)
                        if value > peak[i] {
                            let rescale = peak[i] == -.infinity ? 0 : exp(peak[i] - value)
                            for c in 0..<4 { sum[p + c] *= rescale }
                            peak[i] = value
                        }
                        let w = exp(value - peak[i])
                        sum[p] += w * rgba[p]; sum[p + 1] += w * rgba[p + 1]; sum[p + 2] += w * rgba[p + 2]; sum[p + 3] += w
                    }
                }
            }
        }
    }

    // MARK: Multiscale

    /// Halves a raster with a [1 3 3 1]/8 kernel centred between pixel pairs.
    static func reduce(_ values: [Float], width: Int, height: Int) -> (Int, Int, [Float]) {
        let w = (width + 1) / 2, h = (height + 1) / 2
        let taps: [Float] = [0.125, 0.375, 0.375, 0.125]
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var sum = SIMD4<Float>.zero
                    for j in 0..<4 {
                        let sy = max(0, min(height - 1, 2 * y - 1 + j))
                        for i in 0..<4 {
                            let sx = max(0, min(width - 1, 2 * x - 1 + i)), p = (sy * width + sx) * 4
                            sum += taps[i] * taps[j] * SIMD4(values[p], values[p + 1], values[p + 2], values[p + 3])
                        }
                    }
                    let o = (y * w + x) * 4
                    out[o] = sum.x; out[o + 1] = sum.y; out[o + 2] = sum.z; out[o + 3] = sum.w
                }
            }
        }
        return (w, h, out)
    }

    /// The coarser level's value at a finer pixel, bilinearly.
    @inline(__always) static func expand(_ values: [Float], _ w: Int, _ h: Int, x: Int, y: Int) -> SIMD4<Float> {
        let cx = max(0, min(Double(w - 1), (Double(x) + 0.5) / 2 - 0.5)), cy = max(0, min(Double(h - 1), (Double(y) + 0.5) / 2 - 0.5))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let fx = Float(cx - Double(x0)), fy = Float(cy - Double(y0))
        func at(_ x: Int, _ y: Int) -> SIMD4<Float> { let p = (y * w + x) * 4; return SIMD4(values[p], values[p + 1], values[p + 2], values[p + 3]) }
        return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
    }

    private func addPyramid(_ rgba: [Float]) {
        var level = (width: layout.width, height: layout.height, values: rgba)
        for l in 0..<pyramid.count {
            let coarser = l + 1 < pyramid.count ? Self.reduce(level.values, width: level.width, height: level.height) : nil
            let current = level
            pyramid[l].values.withUnsafeMutableBufferPointer { sum in
                let sum = sum
                DispatchQueue.concurrentPerform(iterations: current.height) { y in
                    for x in 0..<current.width {
                        let p = (y * current.width + x) * 4
                        let w = current.values[p + 3]
                        guard w > 0 else { continue }
                        var detail = SIMD3(current.values[p], current.values[p + 1], current.values[p + 2])
                        if let (cw, ch, coarse) = coarser {
                            let e = Self.expand(coarse, cw, ch, x: x, y: y)
                            detail -= SIMD3(e.x, e.y, e.z)
                        }
                        sum[p] += w * detail.x; sum[p + 1] += w * detail.y; sum[p + 2] += w * detail.z; sum[p + 3] += w
                    }
                }
            }
            if let (cw, ch, coarse) = coarser { level = (cw, ch, coarse) }
        }
    }

    func finish() -> PanoramaRaster {
        switch layout.blending {
        case .labels:
            let rgba = sum
            sum = []; peak = []
            return HDRMerger.normalized(consume rgba, width: layout.width, height: layout.height)
        case .multiscale:
            var collapsed: [Float] = []
            var cw = 0, ch = 0
            for l in stride(from: pyramid.count - 1, through: 0, by: -1) {
                let (w, h, sum) = pyramid[l]
                var out = [Float](repeating: 0, count: w * h * 4)
                let previous = collapsed, pw = cw, ph = ch, top = l == pyramid.count - 1
                out.withUnsafeMutableBufferPointer { out in
                    let out = out
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let p = (y * w + x) * 4
                            var value = sum[p + 3] > 0 ? SIMD3(sum[p], sum[p + 1], sum[p + 2]) / sum[p + 3] : .zero
                            if !top { let e = Self.expand(previous, pw, ph, x: x, y: y); value += SIMD3(e.x, e.y, e.z) }
                            out[p] = value.x; out[p + 1] = value.y; out[p + 2] = value.z; out[p + 3] = 1
                        }
                    }
                }
                collapsed = out; cw = w; ch = h
            }
            pyramid = []
            return PanoramaRaster(width: cw, height: ch, rgba: collapsed)
        }
    }
}
