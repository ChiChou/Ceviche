import Foundation
import CoreImage
import Metal
import simd

/// How much each exposure contributes to every pixel.
extension HDRMerger {
    /// How one photo contributes for a given choice of reference and members.
    struct Contribution {
        var index: Int
        /// Multiplies the photo's pixels into the reference's exposure.
        var gain: Float
        /// Relative exposure, the weight of a well-exposed sample.
        var exposure: Float
        var clip: Float
        /// Samples below this ramp toward zero weight; nil for the brightest photo, which supplies the shadows.
        var floor: Float?
        /// Samples above this fraction of `clip` ramp toward zero weight; nil for the darkest photo, which supplies the highlights.
        var shoulder: Float?
        var isReference: Bool
        /// Brings the photo's tones onto the reference's beyond the single gain; nil for the reference.
        var response: HDRResponse? = nil

        /// The photo's linear sample in the reference's exposure and tones.
        @inline(__always) func radiance(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let scaled = rgb * gain
            guard let response else { return scaled }
            return scaled * response.factor(simd_dot(scaled, SIMD3(0.2126, 0.7152, 0.0722)))
        }

        @inline(__always) func weight(_ peak: Float) -> Float {
            var w = exposure
            if let floor { w *= smoothstep(floor, 4 * floor, peak) }
            if let shoulder { w *= 1 - smoothstep(shoulder * clip, 0.98 * clip, peak) }
            return isReference ? max(w, 1e-6 * exposure) : w
        }
    }

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    func members(_ settings: HDRMergeSettings) throws -> (reference: Int, contributions: [Contribution]) {
        guard let analysis else { throw PanoramaError.message(L10n.tr("Analyze the photos first.")) }
        let included = analysis.frames.map(\.index).filter { !settings.excluded.contains($0) }
        guard included.count >= 2 else { throw PanoramaError.message(L10n.tr("Include at least two exposures.")) }
        var reference = settings.reference ?? anchor
        if !included.contains(reference) { reference = included[(included.count - 1) / 2] }
        let darkest = included.min { stops[$0] < stops[$1] }!, brightest = included.max { stops[$0] < stops[$1] }!
        let isRAW = metadata[0].isRAW
        var contributions = included.map { i in
            Contribution(index: i, gain: Float(exp2(stops[reference] - stops[i])), exposure: Float(exp2(stops[i] - stops[reference])),
                         clip: clips[i], floor: i == brightest ? nil : (isRAW ? 0.0015 : 0.004),
                         shoulder: i == darkest ? nil : (isRAW ? 0.8 : 0.6), isReference: i == reference)
        }
        let responses = responses(reference: reference)
        for k in contributions.indices { contributions[k].response = responses[contributions[k].index] }
        return (reference, contributions)
    }

    /// Each photo's response relative to the reference, measured where both are well exposed and agree to within a stop.
    /// A single exposure ratio leaves processed photos (each with its own tone curve) mismatched by tone and channel, which
    /// shows wherever the merge changes source; the curve removes that. Developed RAW photos are linear, so theirs stays
    /// near flat.
    func responses(reference: Int) -> [Int: HDRResponse] {
        if let cached = responses[reference] { return cached }
        let width = analysisWidth, height = analysisHeight, isRAW = metadata[0].isRAW
        let floor: Float = isRAW ? 0.006 : 0.02, shoulder: Float = isRAW ? 0.85 : 0.9
        let target = aligned[reference], targetClip = clips[reference]
        var result: [Int: HDRResponse] = [:]
        for i in aligned.indices where i != reference {
            let source = aligned[i], gain = Float(exp2(stops[reference] - stops[i]))
            var samples = [[SIMD3<Float>]](repeating: [], count: HDRResponse.bins)
            for p in stride(from: 0, to: width * height * 4, by: 4 * 2) where source[p + 3] > 0.999 {
                let a = SIMD3(source[p], source[p + 1], source[p + 2]), b = SIMD3(target[p], target[p + 1], target[p + 2])
                guard a.min() > floor, b.min() > floor, a.max() < shoulder * clips[i], b.max() < shoulder * targetClip else { continue }
                let scaled = a * gain
                let ratio = SIMD3(log2(b.x / scaled.x), log2(b.y / scaled.y), log2(b.z / scaled.z))
                // Something that moved says nothing about the response.
                guard abs(ratio.x) < 1, abs(ratio.y) < 1, abs(ratio.z) < 1 else { continue }
                samples[HDRResponse.bin(simd_dot(scaled, SIMD3(0.2126, 0.7152, 0.0722)))].append(ratio)
            }
            result[i] = HDRResponse(samples: samples)
        }
        responses[reference] = result
        return result
    }

    /// Per photo other than the reference, how far to trust it at each analysis pixel: 1 where it agrees with the
    /// reference or can't be judged, toward 0 where something moved. Rejected areas are grown and feathered so whole
    /// moving objects come from the reference without hard edges.
    ///
    /// Photos are compared as the reference would have recorded them, clipped where it clips. Where the reference is
    /// clipped and the photo agrees that it's bright there, the photo supplies the highlight; where the photo shows
    /// something darker (a cloud that drifted off the moon), it is rejected, since its detail would otherwise appear
    /// as a hole with the reference's clipping outline. Where rejections are dense (stars, leaves, ripples, drifting
    /// cloud) the whole area comes from the reference instead of a pattern of holes.
    func consistencyMaps(reference: Int, contributions: [Contribution], deghosting: HDRDeghosting) -> [Int: [Float]] {
        guard let tolerance = deghosting.tolerance else { return [:] }
        let key = "\(reference)-\(deghosting.rawValue)-\(contributions.map { "\($0.index)" }.joined(separator: ","))"
        if let cached = consistency[key] { return cached }
        let width = analysisWidth, height = analysisHeight
        let referenceContribution = contributions.first { $0.index == reference }!
        // The reference's clipping point in radiance; its gain is 1.
        let clipped = 0.98 * referenceContribution.clip
        func smoothedLuminance(_ c: Contribution) -> [Float] {
            var y = [Float](repeating: 0, count: width * height)
            let rgba = aligned[c.index]
            for i in 0..<width * height {
                let p = i * 4
                y[i] = simd_dot(simd_min(c.radiance(SIMD3(rgba[p], rgba[p + 1], rgba[p + 2])), SIMD3(repeating: clipped)), SIMD3(0.2126, 0.7152, 0.0722))
            }
            return Self.boxBlur(y, width: width, height: height, radius: 1)
        }
        /// Where the photo can be compared: covered and short of its own clipping. Its noise floor still counts, since
        /// the noise allowance below covers noise; near black against a clipped reference is a real disagreement.
        func validity(_ c: Contribution) -> [Float] {
            let unit = Contribution(index: c.index, gain: 1, exposure: 1, clip: c.clip, floor: nil, shoulder: c.shoulder ?? 0.8, isReference: false)
            var v = [Float](repeating: 0, count: width * height)
            let rgba = aligned[c.index]
            for i in 0..<width * height {
                let p = i * 4
                v[i] = rgba[p + 3] < 0.999 ? 0 : unit.weight(max(rgba[p], rgba[p + 1], rgba[p + 2]))
            }
            // A clipped neighbourhood can't be compared even where the pixel itself isn't clipped.
            return Self.minFilter(v, width: width, height: height, radius: 2)
        }
        let referenceLuminance = smoothedLuminance(referenceContribution)
        // Where the reference itself is reliable; regional rejection only hands areas to it there.
        let referenceValidity: [Float] = {
            var v = [Float](repeating: 0, count: width * height)
            let rgba = aligned[reference]
            for i in 0..<width * height {
                let p = i * 4
                v[i] = referenceContribution.weight(max(rgba[p], rgba[p + 1], rgba[p + 2])) / referenceContribution.exposure
            }
            return Self.boxBlur(v, width: width, height: height, radius: max(2, width / 100))
        }()
        var maps: [Int: [Float]] = [:]
        for c in contributions where c.index != reference {
            let y = smoothedLuminance(c), valid = validity(c)
            // Noise in the darker exposure explains small differences in its shadows.
            let noise = 4 * (metadata[0].isRAW ? 0.0015 : 0.004) * max(c.gain, referenceContribution.gain)
            var trust = [Float](repeating: 1, count: width * height)
            // Judged wherever the photo would contribute.
            for i in 0..<width * height where valid[i] > 0.05 {
                let d = abs(log(y[i] + noise) - log(referenceLuminance[i] + noise)) / tolerance
                trust[i] = exp2(-d * d)
            }
            // Widen each rejection by two pixels so thin things (wires, antennas, branches) survive the blur; grow with a
            // soft round neighbourhood (a blurred rejection amplified, rather than a square minimum), then feather with
            // three box passes, close to a Gaussian, so the edge has no corners or steps.
            var rejected = Self.minFilter(trust, width: width, height: height, radius: 2).map { 1 - $0 }
            let grow = max(2, width / 250)
            var local = Self.boxBlur(Self.boxBlur(rejected, width: width, height: height, radius: grow), width: width, height: height, radius: grow)
            for k in local.indices { local[k] = min(1, 3 * local[k]) }
            let region = max(4, width / 25)
            let dense = Self.boxBlur(Self.boxBlur(rejected.map { $0 > 0.5 ? 1 : 0 }, width: width, height: height, radius: region),
                                     width: width, height: height, radius: region)
            for k in rejected.indices {
                rejected[k] = max(local[k], Self.smoothstep(0.03, 0.12, dense[k]) * min(1, 2 * referenceValidity[k]))
            }
            let feather = max(2, width / 80)
            for _ in 0..<3 { rejected = Self.boxBlur(rejected, width: width, height: height, radius: feather) }
            maps[c.index] = rejected.map { 1 - $0 }
        }
        // The reference's map is the opposite: how strongly it must take over, the most any photo was rejected. Its own
        // weight is tiny where it clips, so without this a photo rejected 99% would still outweigh it there.
        if !maps.isEmpty {
            var takeover = [Float](repeating: 0, count: width * height)
            for map in maps.values { for k in takeover.indices { takeover[k] = max(takeover[k], 1 - map[k]) } }
            maps[reference] = takeover
        }
        consistency[key] = maps
        return maps
    }

    static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        separable(values, width: width, height: height, radius: radius, minimum: false)
    }
    static func minFilter(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        separable(values, width: width, height: height, radius: radius, minimum: true)
    }
    /// A box mean or minimum over (2 radius + 1)² pixels, clamped at the edges: rows, then columns, each in parallel.
    private static func separable(_ values: [Float], width: Int, height: Int, radius: Int, minimum: Bool) -> [Float] {
        func pass(_ input: [Float], count: Int, lines: Int, step: Int, lineStep: Int) -> [Float] {
            var output = input
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    let output = output
                    DispatchQueue.concurrentPerform(iterations: lines) { line in
                        let base = line * lineStep
                        if minimum {
                            for i in 0..<count {
                                var m = Float.infinity
                                for j in max(0, i - radius)...min(count - 1, i + radius) { m = min(m, input[base + j * step]) }
                                output[base + i * step] = m
                            }
                        } else {
                            // Running sum over the clamped window.
                            var sum: Float = 0
                            for j in 0...min(count - 1, radius) { sum += input[base + j * step] }
                            for i in 0..<count {
                                let low = max(0, i - radius), high = min(count - 1, i + radius)
                                output[base + i * step] = sum / Float(high - low + 1)
                                if i + radius + 1 < count { sum += input[base + (i + radius + 1) * step] }
                                if i - radius >= 0 { sum -= input[base + (i - radius) * step] }
                            }
                        }
                    }
                }
            }
            return output
        }
        let rows = pass(values, count: width, lines: height, step: 1, lineStep: width)
        return pass(rows, count: height, lines: width, step: width, lineStep: 1)
    }
}
