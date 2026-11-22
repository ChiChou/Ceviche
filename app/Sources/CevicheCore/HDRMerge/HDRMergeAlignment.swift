import Foundation
import simd

/// A similarity transform from a bracket's pixel coordinates to the reference's: q = linear · p + translation.
/// Brackets shot by hand from one spot differ by a small shift and roll; scale stays near 1 but is solved for focus breathing.
struct HDRSimilarity: Sendable, Equatable {
    var linear: simd_double2x2
    var translation: SIMD2<Double>
    static let identity = HDRSimilarity(linear: matrix_identity_double2x2, translation: .zero)

    func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { linear * p + translation }
    var inverse: HDRSimilarity {
        let inverse = linear.inverse
        return HDRSimilarity(linear: inverse, translation: -(inverse * translation))
    }
    var rotationDegrees: Double { atan2(linear[0][1], linear[0][0]) * 180 / .pi }
    var scale: Double { hypot(linear[0][0], linear[0][1]) }
    /// The same transform for images `factor` times larger.
    func scaled(by factor: Double) -> HDRSimilarity { HDRSimilarity(linear: linear, translation: translation * factor) }
    /// This transform after `other`: p ↦ self(other(p)).
    func after(_ other: HDRSimilarity) -> HDRSimilarity {
        HDRSimilarity(linear: linear * other.linear, translation: linear * other.translation + translation)
    }
    /// Largest displacement of the image's corners, in pixels.
    func displacement(width: Double, height: Double) -> Double {
        [SIMD2(0, 0), SIMD2(width, 0), SIMD2(0, height), SIMD2(width, height)].map { simd_distance(apply($0), $0) }.max() ?? 0
    }
}

enum HDRMergeAlignment {
    /// Exposure-independent matching proxy: luminance mapped through its own cumulative histogram, so brackets of the same
    /// scene look alike wherever neither is clipped.
    /// Values under `floor` are noise in a dark bracket; they are held flat so equalizing doesn't turn them into corners.
    static func equalized(_ plane: LuminancePlane, floor: Float = 1e-6) -> LuminancePlane {
        let bins = 4096
        let logs = plane.values.map { log2(max($0, floor)) }
        let low = logs.min() ?? 0, high = max(low + 1e-3, logs.max() ?? 1)
        var histogram = [Int](repeating: 0, count: bins)
        let index = { (v: Float) in min(bins - 1, Int((v - low) / (high - low) * Float(bins - 1))) }
        for v in logs { histogram[index(v)] += 1 }
        var cumulative = [Float](repeating: 0, count: bins), total = 0
        for i in 0..<bins { total += histogram[i]; cumulative[i] = Float(total) / Float(logs.count) }
        return LuminancePlane(width: plane.width, height: plane.height, values: logs.map { cumulative[index($0)] })
    }

    /// The transform taking `frame` onto `reference`, or nil when too few features agree.
    static func estimate(frame: [PanoramaFeature], reference: [PanoramaFeature]) -> (HDRSimilarity, inliers: Int)? {
        let matches = PanoramaFeatures.match(frame, reference, ratio: 0.8)
        guard matches.count >= 12 else { return nil }
        var seed: UInt64 = 0x5DEECE66D
        func random() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(matches.count)) }
        let threshold = 2.0
        var best: [PanoramaMatch] = []
        for _ in 0..<600 {
            let i = random(), j = random()
            guard i != j, let model = fromTwo(matches[i], matches[j]), plausible(model) else { continue }
            let inliers = matches.filter { simd_distance(model.apply($0.a), $0.b) < threshold }
            if inliers.count > best.count { best = inliers }
        }
        guard best.count >= 12, var model = fit(best) else { return nil }
        // One refinement pass with the fitted model's own inliers.
        let refined = matches.filter { simd_distance(model.apply($0.a), $0.b) < threshold }
        if refined.count >= best.count, let again = fit(refined) { model = again; best = refined }
        guard plausible(model) else { return nil }
        // From a tripod the foreground stays put while stars, clouds or water move together and can outnumber it. A
        // sizeable group of features that hasn't moved at all only happens when the camera didn't: keep the frame.
        let still = matches.filter { simd_distance($0.a, $0.b) < 1 }.count
        if model.displacement(width: 1600, height: 1600) > 1.5, still >= 20, Double(still) >= 0.15 * Double(best.count) {
            return (.identity, still)
        }
        return (model, best.count)
    }

    private static func plausible(_ model: HDRSimilarity) -> Bool {
        abs(model.scale - 1) < 0.08 && abs(model.rotationDegrees) < 6
    }

    private static func fromTwo(_ m: PanoramaMatch, _ n: PanoramaMatch) -> HDRSimilarity? {
        let a = n.a - m.a, b = n.b - m.b
        let lengthSquared = simd_length_squared(a)
        guard lengthSquared > 100 else { return nil }
        // b = [[c, -s], [s, c]] a
        let c = (a.x * b.x + a.y * b.y) / lengthSquared, s = (a.x * b.y - a.y * b.x) / lengthSquared
        let linear = simd_double2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
        return HDRSimilarity(linear: linear, translation: m.b - linear * m.a)
    }

    /// Least-squares similarity (Umeyama in two dimensions).
    static func fit(_ matches: [PanoramaMatch]) -> HDRSimilarity? {
        guard matches.count >= 2 else { return nil }
        let n = Double(matches.count)
        let ma = matches.reduce(SIMD2<Double>.zero) { $0 + $1.a } / n, mb = matches.reduce(SIMD2<Double>.zero) { $0 + $1.b } / n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for match in matches {
            let a = match.a - ma, b = match.b - mb
            dot += a.x * b.x + a.y * b.y; cross += a.x * b.y - a.y * b.x; norm += simd_length_squared(a)
        }
        guard norm > 0 else { return nil }
        let c = dot / norm, s = cross / norm
        let linear = simd_double2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
        return HDRSimilarity(linear: linear, translation: mb - linear * ma)
    }
}
