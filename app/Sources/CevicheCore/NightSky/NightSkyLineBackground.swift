import simd

/// The source-minus-base sky beside a line, in analysis coordinates. Sampling outside the footprint keeps the
/// meteor out of the estimate; separate profiles on its two sides follow both longitudinal and transverse glow.
/// All render paths use the preview's estimate, so a full-size export does not change the background match.
struct NightSkyLineBackground {
    let line: NightSkyLine
    let sides: [SIMD3<Float>]
    var count: Int { sides.count / 2 }
    var axis: SIMD2<Double> { (line.end - line.start) / max(1e-6, line.length) }

    init?(line: NightSkyLine, sample: (SIMD2<Double>) -> SIMD3<Float>?) {
        guard line.length > 0 else { return nil }
        self.line = line
        let direction = (line.end - line.start) / line.length, normal = SIMD2(-direction.y, direction.x)
        let radius = line.radius, extent = line.length + 2 * radius
        let count = max(2, Int(ceil(extent / max(8, radius))) + 1)
        var measured = [[SIMD3<Float>?]](repeating: [nil, nil], count: count)
        for i in 0..<count {
            let center = line.start + direction * (-radius + extent * Double(i) / Double(count - 1))
            for side in 0..<2 {
                var values: [SIMD3<Float>] = []
                for along in -2...2 { for across in 0..<3 {
                    let p = center + direction * (Double(along) * radius * 0.5)
                        + normal * ((side == 0 ? -1 : 1) * radius * (1.5 + Double(across) * 0.5))
                    if let v = sample(p), v.x.isFinite, v.y.isFinite, v.z.isFinite { values.append(v) }
                }}
                guard values.count >= 5 else { continue }
                var median = SIMD3<Float>.zero
                for c in 0..<3 { median[c] = values.map { $0[c] }.sorted()[values.count / 2] }
                measured[i][side] = median
            }
        }
        // A clipped side can use the other side's level. Missing stations interpolate between supported ones;
        // nothing is restored when no surrounding sky was measurable at all.
        let supported = measured.indices.filter { measured[$0].contains { $0 != nil } }
        guard !supported.isEmpty else { return nil }
        for i in supported {
            measured[i][0] = measured[i][0] ?? measured[i][1]
            measured[i][1] = measured[i][1] ?? measured[i][0]
        }
        for i in measured.indices where measured[i][0] == nil {
            let left = supported.last { $0 < i } ?? supported[0]
            let right = supported.first { $0 > i } ?? supported[supported.count - 1]
            let t = left == right ? 0 : Float(i - left) / Float(right - left)
            for side in 0..<2 { measured[i][side] = measured[left][side]! * (1 - t) + measured[right][side]! * t }
        }
        sides = measured.flatMap { $0.map { $0! } }
    }

    func value(at p: SIMD2<Double>) -> SIMD3<Float> {
        let d = p - line.start, direction = axis
        let t = max(0, min(Double(count - 1), (simd_dot(d, direction) + line.radius) / (line.length + 2 * line.radius) * Double(count - 1)))
        let i = min(count - 2, Int(t)), f = Float(t - Double(i))
        let across = Float(max(0, min(1, 0.5 + simd_dot(d, SIMD2(-direction.y, direction.x)) / (4 * line.radius))))
        let left = sides[i * 2] * (1 - f) + sides[(i + 1) * 2] * f
        let right = sides[i * 2 + 1] * (1 - f) + sides[(i + 1) * 2 + 1] * f
        return left * (1 - across) + right * across
    }

    /// Packed RGB pairs for Metal (SIMD3 itself has a four-float stride).
    var packed: [Float] { [Float(count)] + sides.flatMap { [$0.x, $0.y, $0.z] } }
}

extension NightSkyAnalyzer {
    /// Measures in the same coordinates and against the same clean composite used to restore the line.
    func lineBackgrounds(_ plan: Plan, clean: [Float]) throws -> [NightSkyLineBackground?] {
        guard let cache else { return plan.restore.map { _ in nil } }
        var result: [NightSkyLineBackground?] = []
        try cache.read { reader in
            clean.withUnsafeBufferPointer { pixels in
                for line in plan.restore {
                    result.append(NightSkyLineBackground(line: line) { a in
                        guard !plan.restore.contains(where: { $0.distance(a) <= $0.radius }) else { return nil }
                        let camera = plan.restoreAsCaptured ? a : pointOnBase(a, base: plan.base)
                        guard isSky(camera), let base = Self.bilinear(pixels, previewWidth, previewHeight,
                            (camera + 0.5) / previewScale - 0.5, channels: 3),
                            let source = reader.bilinear(line.frame, plan.restoreAsCaptured ? 0 : 1, (a + 0.5) / previewScale - 0.5) else { return nil }
                        return source * gains[line.frame] - base
                    })
                }
            }
        }
        return result
    }
}
