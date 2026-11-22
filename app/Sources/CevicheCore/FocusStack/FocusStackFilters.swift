import Foundation
import simd

/// Planar filters and small solvers for focus stacking, on the CPU. The GPU engine uses the same kernels.
enum FocusStackFilters {
    /// Normalized Gaussian taps, centre first: weights[k] applies at offsets ±k.
    static func gaussianWeights(sigma: Float) -> [Float] {
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var weights = (0...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        for k in weights.indices { weights[k] /= total }
        return weights
    }

    /// Separable Gaussian blur with edges clamped: rows, then columns, each in parallel.
    static func gaussian(_ values: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let weights = gaussianWeights(sigma: sigma)
        let radius = weights.count - 1
        func pass(_ input: [Float], count: Int, lines: Int, step: Int, lineStep: Int) -> [Float] {
            var output = input
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    let output = output
                    DispatchQueue.concurrentPerform(iterations: lines) { line in
                        let base = line * lineStep
                        for i in 0..<count {
                            var sum = weights[0] * input[base + i * step]
                            for k in 1...radius {
                                sum += weights[k] * (input[base + max(0, i - k) * step] + input[base + min(count - 1, i + k) * step])
                            }
                            output[base + i * step] = sum
                        }
                    }
                }
            }
            return output
        }
        let rows = pass(values, count: width, lines: height, step: 1, lineStep: width)
        return pass(rows, count: height, lines: width, step: width, lineStep: 1)
    }

    /// He's guided filter: `input` smoothed by locally linear models of `guide`, so its edges follow the guide's edges.
    static func guided(_ input: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let n = width * height
        func mean(_ v: [Float]) -> [Float] { HDRMerger.boxBlur(v, width: width, height: height, radius: radius) }
        let meanI = mean(guide), meanP = mean(input)
        var ii = [Float](repeating: 0, count: n), ip = ii
        for k in 0..<n { ii[k] = guide[k] * guide[k]; ip[k] = guide[k] * input[k] }
        let corrII = mean(ii), corrIP = mean(ip)
        var a = [Float](repeating: 0, count: n), b = a
        for k in 0..<n {
            let variance = corrII[k] - meanI[k] * meanI[k], covariance = corrIP[k] - meanI[k] * meanP[k]
            a[k] = covariance / (variance + epsilon)
            b[k] = meanP[k] - a[k] * meanI[k]
        }
        let meanA = mean(a), meanB = mean(b)
        var output = [Float](repeating: 0, count: n)
        for k in 0..<n { output[k] = meanA[k] * guide[k] + meanB[k] }
        return output
    }

    /// Solves the dense system `matrix · x = vector` (row-major, size × size) by elimination with partial pivoting.
    static func solve(_ matrix: [Double], _ vector: [Double], size n: Int) -> [Double]? {
        var m = matrix, v = vector
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<max(column + 1, n) where abs(m[row * n + column]) > abs(m[pivot * n + column]) { pivot = row }
            guard abs(m[pivot * n + column]) > 1e-300 else { return nil }
            if pivot != column {
                for k in 0..<n { m.swapAt(column * n + k, pivot * n + k) }
                v.swapAt(column, pivot)
            }
            let diagonal = m[column * n + column]
            for row in (column + 1)..<max(column + 1, n) {
                let factor = m[row * n + column] / diagonal
                guard factor != 0 else { continue }
                for k in column..<n { m[row * n + k] -= factor * m[column * n + k] }
                v[row] -= factor * v[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<max(row + 1, n) { sum -= m[row * n + k] * x[k] }
            x[row] = sum / m[row * n + row]
        }
        return x
    }
}

/// How sharp each photo is at each pixel, after alignment.
///
/// Sharpness is read from a variance-stabilized luminance proxy (the square root of linear luminance, so photon noise
/// is about equally strong in shadows and highlights) split into difference-of-Gaussian bands one octave apart. A band's
/// local energy counts only beyond what the photo's own noise would put there, measured per photo, so a noisy or
/// sharpened photo can't win by noise alone. Each band contributes the log of its signal-to-noise ratio: fine bands tell
/// photos apart, coarse ones keep deciding in low-texture areas, and no band dominates by sheer energy.
enum FocusStackFocus {
    /// Band scales at analysis size; the finest is also the band the full-size merge refines with.
    static let sigmas: [Float] = [1, 2, 4]
    /// Energy window per band.
    static let windows: [Float] = [1.5, 2, 4]

    @inline(__always) static func proxy(_ r: Float, _ g: Float, _ b: Float) -> Float {
        (max(0, 0.2126 * r + 0.7152 * g + 0.0722 * b) + 1e-6).squareRoot()
    }

    static func proxy(_ rgba: [Float], gain: Float = 1) -> [Float] {
        var out = [Float](repeating: 0, count: rgba.count / 4)
        for i in out.indices { let p = i * 4; out[i] = proxy(gain * rgba[p], gain * rgba[p + 1], gain * rgba[p + 2]) }
        return out
    }

    /// The bands of `proxy`, finest first.
    static func bands(_ proxy: [Float], width: Int, height: Int) -> [[Float]] {
        var previous = proxy, previousSigma: Float = 0, result: [[Float]] = []
        for sigma in sigmas {
            // Blurs build on each other: σ² adds.
            let blurred = FocusStackFilters.gaussian(previous, width: width, height: height, sigma: (sigma * sigma - previousSigma * previousSigma).squareRoot())
            var band = [Float](repeating: 0, count: proxy.count)
            for k in band.indices { band[k] = previous[k] - blurred[k] }
            result.append(band)
            previous = blurred; previousSigma = sigma
        }
        return result
    }

    /// The variance each band passes from white noise of variance 1, measured from an impulse.
    static let noiseGains: [Float] = {
        let size = 65
        var impulse = [Float](repeating: 0, count: size * size)
        impulse[size / 2 * size + size / 2] = 1
        return bands(impulse, width: size, height: size).map { $0.reduce(0) { $0 + $1 * $1 } }
    }()

    /// White-noise variance of `proxy`: the finest band's variance in quiet 8 × 8 blocks (a low percentile, which
    /// flat and defocused areas supply), divided by that band's noise gain.
    static func noise(_ proxy: [Float], width: Int, height: Int) -> Float {
        let finest = FocusStackFilters.gaussian(proxy, width: width, height: height, sigma: sigmas[0])
        var variances: [Float] = []
        for by in stride(from: 4, to: height - 12, by: 8) { for bx in stride(from: 4, to: width - 12, by: 8) {
            var sum: Float = 0, squares: Float = 0
            for y in by..<(by + 8) { for x in bx..<(bx + 8) {
                let d = proxy[y * width + x] - finest[y * width + x]
                sum += d; squares += d * d
            }}
            variances.append(max(0, squares / 64 - (sum / 64) * (sum / 64)))
        }}
        guard !variances.isEmpty else { return 0 }
        variances.sort()
        // Block variances of pure noise scatter around their mean; the 10th percentile reads about 0.6 of it.
        return variances[variances.count / 10] / 0.6 / noiseGains[0]
    }

    /// Per-pixel focus confidence: the summed log signal-to-noise of each band's local energy. `noise` is this photo's
    /// white-noise variance, `reference` the bracket's typical one, which sets the common scale. Nil coverage (alpha
    /// below 1) gives -infinity; clipped highlights count less, since clipping flattens detail in every photo.
    static func measure(_ rgba: [Float], gain: Float, clip: Float, width: Int, height: Int, noise: Float, reference: Float) -> [Float] {
        let p = proxy(rgba, gain: gain)
        let bands = bands(p, width: width, height: height)
        var focus = [Float](repeating: 0, count: width * height)
        for (s, band) in bands.enumerated() {
            let energy = FocusStackFilters.gaussian(band.map { $0 * $0 }, width: width, height: height, sigma: windows[s])
            let expected = 2 * noise * noiseGains[s], scale = reference * noiseGains[s] + 1e-8
            for k in focus.indices { focus[k] += log1p(max(0, energy[k] - expected) / scale) }
        }
        for k in focus.indices {
            let q = k * 4
            if rgba[q + 3] < 0.999 { focus[k] = -.infinity; continue }
            if max(rgba[q], rgba[q + 1], rgba[q + 2]) > 0.95 * clip { focus[k] *= 0.3 }
        }
        return focus
    }
}
