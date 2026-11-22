// Color grading curves adapted from RAWmakase (MIT).
// Copyright (c) 2026 RAWmakase contributors. See OpenSourceLicenses/credits/rawmakase/RAWmakase-MIT.txt.
import Foundation
import simd

/// Color grading as a curve per channel of linear ProPhoto RGB: a channel's output depends on that channel's
/// input only. A region's tint gains are 1 + Σ A_k(x) p_k, with profiles A along the channel value that Blending
/// and Balance shape and per-channel coefficients p that hue and saturation set; regions multiply. Luminance is one
/// curve for all channels, applied before the tint. The tables were fitted to another converter's renders of a
/// synthetic chart, so sidecar and preset grading lands where it was made.
struct ColorGradeCurves {
    /// Samples of each curve over x^(1/2.2), 0…1.
    static let samples = 64
    static let blends: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let balances: [Double] = [-1, -0.88, -0.75, -0.62, -0.5, -0.38, -0.25, -0.12, 0, 0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88, 1]
    static let hues = 12
    static let saturations: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let luminances: [Double] = [-1, -0.75, -0.5, -0.25, 0, 0.25, 0.5, 0.75, 1]
    static let terms = 3, shapedTerms = 2
    static let grid = 0
    static let global = grid + 3 * blends.count * balances.count * samples * shapedTerms
    static let coefficientsStart = global + samples * terms
    static let luminanceStart = coefficientsStart + 4 * hues * (saturations.count - 1) * 3 * terms
    static let count = luminanceStart + 4 * (luminances.count - 1) * samples
    static let tables: [Float] = {
        let data = Data(base64Encoded: encodedTables)!
        precondition(data.count == count * 4)
        return data.withUnsafeBytes { raw in (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) } }
    }()
    static func value(_ i: Int) -> Double { Double(tables[i]) }

    enum Region: Int, CaseIterable { case shadows, midtones, highlights, global }
    typealias Profiles = [[Double]]

    /// Per-channel gains at each sample.
    let gain: [SIMD3<Double>]

    /// `nil` when nothing changes. A record with split toning but no color grading renders at Blending 100.
    init?(_ s: SplitToning) {
        let settings: [(hue: Double, saturation: Double, luminance: Double)] = [
            (s.shadowHue, s.shadowSaturation, s.shadowLuminance), (s.midtoneHue, s.midtoneSaturation, s.midtoneLuminance),
            (s.highlightHue, s.highlightSaturation, s.highlightLuminance), (s.globalHue, s.globalSaturation, s.globalLuminance)
        ].map { ($0.0 / 360, $0.1 / 100, $0.2 / 100) }
        guard let gain = Self.gains(settings, blending: s.blending / 100, balance: s.balance / 100) else { return nil }
        self.gain = gain
    }

    /// `p` is linear ProPhoto RGB.
    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
        func channel(_ v: Double, _ c: Int) -> Double {
            let at = pow(min(1, max(0, v)), 1 / 2.2) * Double(Self.samples - 1)
            let i = min(Self.samples - 2, Int(at)), t = at - Double(i)
            return v * (gain[i][c] * (1 - t) + gain[i + 1][c] * t)
        }
        return SIMD3(channel(p.x, 0), channel(p.y, 1), channel(p.z, 2))
    }
    /// `rgb` is sRGB-encoded; colors graded beyond sRGB clip per channel.
    func transform(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        FilmMath.encode(FilmMath.clamp(FilmMath.fromProPhoto * apply(FilmMath.toProPhoto * FilmMath.decode(rgb))))
    }

    /// The interval of `knots` holding `x` and the position within it.
    static func bracket(_ knots: [Double], _ x: Double) -> (Int, Double) {
        let x = min(knots[knots.count - 1], max(knots[0], x))
        let i = min(knots.count - 2, max(0, (knots.firstIndex { $0 > x } ?? knots.count) - 1))
        return (i, (x - knots[i]) / (knots[i + 1] - knots[i]))
    }
    static func encoded(_ k: Int) -> Double { Double(k) / Double(samples - 1) }
    static func sample(_ table: [Double], _ at: Double) -> Double {
        let at = min(Double(samples - 1), max(0, at)), i = min(samples - 2, Int(at)), t = at - Double(i)
        return table[i] * (1 - t) + table[i + 1] * t
    }

    static func profiles(_ region: Region, blending: Double, balance: Double) -> Profiles {
        if region == .global { return (0..<samples).map { k in (0..<terms).map { value(global + k * terms + $0) } } }
        let (i, u) = bracket(blends, blending), (j, v) = bracket(balances, balance)
        func at(_ b: Int, _ a: Int, _ k: Int, _ t: Int) -> Double {
            value(grid + (((region.rawValue * blends.count + b) * balances.count + a) * samples + k) * shapedTerms + t)
        }
        return (0..<samples).map { k in
            (0..<terms).map { t in
                t >= shapedTerms ? 0 : at(i, j, k, t) * (1 - u) * (1 - v) + at(i + 1, j, k, t) * u * (1 - v)
                    + at(i, j + 1, k, t) * (1 - u) * v + at(i + 1, j + 1, k, t) * u * v
            }
        }
    }

    /// The region's per-channel coefficients for `hue` (a turn) and `saturation` (0…1).
    static func coefficients(_ region: Region, hue: Double, saturation: Double) -> [[Double]] {
        let f = (hue - floor(hue)) * Double(hues), h0 = Int(f) % hues, w = f - floor(f)
        let (s, u) = bracket(saturations, saturation)
        // Saturation 0 has no tint; the table starts at 25.
        func at(_ h: Int, _ s: Int, _ c: Int, _ t: Int) -> Double {
            s == 0 ? 0 : value(coefficientsStart + (((region.rawValue * hues + h) * (saturations.count - 1) + s - 1) * 3 + c) * terms + t)
        }
        return (0..<3).map { c in
            (0..<terms).map { t in
                func atHue(_ s: Int) -> Double { at(h0, s, c, t) * (1 - w) + at((h0 + 1) % hues, s, c, t) * w }
                return atHue(s) * (1 - u) + atHue(s + 1) * u
            }
        }
    }

    /// log2 of the measured Luminance gains at `amount` (−1…1), Blending 50 and Balance 0.
    static func luminanceLog(_ region: Region, amount: Double) -> [Double] {
        let (j, u) = bracket(luminances, amount)
        func table(_ i: Int) -> [Double] {
            if i == 4 { return Array(repeating: 0, count: samples) }
            let start = luminanceStart + (region.rawValue * (luminances.count - 1) + (i < 4 ? i : i - 1)) * samples
            return (0..<samples).map { log2(value(start + $0)) }
        }
        let a = table(j), b = table(j + 1)
        return (0..<samples).map { a[$0] * (1 - u) + b[$0] * u }
    }

    /// The region's first profile, scaled to peak at 1: where it sits along the channel.
    static func weight(_ region: Region, blending: Double, balance: Double) -> [Double] {
        let p = profiles(region, blending: blending, balance: balance)
        let peak = p.map { $0[0] }.reduce(0.0) { abs($1) > abs($0) ? $1 : $0 }
        return p.map { peak == 0 ? 0 : $0[0] / peak }
    }

    /// The Luminance gains at `amount`, Blending and Balance: Luminance keeps the strength it has at the default
    /// where the region's weight is the same, on the same side of the weight's peak. Darkening keeps its gain
    /// there, lifts their encoded offset.
    static func luminance(_ region: Region, amount: Double, blending: Double, balance: Double) -> [Double] {
        let log = luminanceLog(region, amount: amount)
        if region == .global || (abs(blending - 0.5) < 1e-4 && abs(balance) < 1e-4) { return log.map { exp2($0) } }
        let w = weight(region, blending: blending, balance: balance), w0 = weight(region, blending: 0.5, balance: 0)
        let peak = w.indices.max { w[$0] < w[$1] } ?? 0, peak0 = w0.indices.max { w0[$0] < w0[$1] } ?? 0
        let at: [Double] = (0..<samples).map { k in
            let segment = Array(k <= peak ? 0...peak0 : peak0...(samples - 1))
            let near = segment.indices.min { abs(w0[segment[$0]] - w[k]) < abs(w0[segment[$1]] - w[k]) } ?? 0
            for (a, b) in [(near - 1, near), (near, near + 1)] where a >= 0 && b < segment.count {
                let lo = w0[segment[a]], hi = w0[segment[b]]
                if (lo - w[k]) * (hi - w[k]) <= 0 && lo != hi {
                    return Double(segment[a]) + (w[k] - lo) / (hi - lo) * Double(segment[b] - segment[a])
                }
            }
            return Double(segment[near])
        }
        if amount < 0 { return (0..<samples).map { exp2(sample(log, at[$0])) } }
        let offset = (0..<samples).map { encoded($0) * (exp2(log[$0] / 2.2) - 1) }
        return (0..<samples).map { k in k == 0 ? exp2(log[0]) : pow((encoded(k) + sample(offset, at[k])) / encoded(k), 2.2) }
    }

    static func gains(_ settings: [(hue: Double, saturation: Double, luminance: Double)], blending: Double, balance: Double) -> [SIMD3<Double>]? {
        guard settings.contains(where: { $0.saturation != 0 || $0.luminance != 0 }) else { return nil }
        var lum = [Double](repeating: 1, count: samples)
        var tint = [SIMD3<Double>](repeating: SIMD3(repeating: 1), count: samples)
        for (region, setting) in zip(Region.allCases, settings) {
            if setting.luminance != 0 {
                let l = luminance(region, amount: setting.luminance, blending: blending, balance: balance)
                for k in 0..<samples { lum[k] *= l[k] }
            }
            if setting.saturation != 0 {
                let p = profiles(region, blending: blending, balance: balance)
                let c = coefficients(region, hue: setting.hue, saturation: setting.saturation)
                for k in 0..<samples {
                    for ch in 0..<3 { tint[k][ch] *= 1 + zip(p[k], c[ch]).map { $0 * $1 }.reduce(0, +) }
                }
            }
        }
        // Luminance first, then the tint on its result.
        let channels = (0..<3).map { c in tint.map { $0[c] } }
        return (0..<samples).map { k in
            let after = pow(min(1, max(0, pow(encoded(k), 2.2) * lum[k])), 1 / 2.2) * Double(samples - 1)
            return SIMD3((0..<3).map { lum[k] * max(0, sample(channels[$0], after)) })
        }
    }
}
