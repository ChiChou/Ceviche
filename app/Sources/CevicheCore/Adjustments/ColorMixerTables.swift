// Color mixer tables adapted from RAWmakase (MIT).
// Copyright (c) 2026 RAWmakase contributors. See OpenSourceLicenses/credits/rawmakase/RAWmakase-MIT.txt.
import Foundation
import simd

/// The eight-band HSL mixer as a hue/saturation/value lookup in linear ProPhoto RGB. For each band's Hue,
/// Saturation and Luminance at ±100 the tables hold the change measured on another converter's renders: hue shift
/// (turns), log2 saturation and log2 value factors, on 36 hues × 6 saturations (spaced by √s) × 6 values (spaced
/// by v^0.45). Slider positions scale the hue shift, the value factor's log and positive saturation's log linearly;
/// negative changes scale the saturation factor itself; band Luminance follows the slider to a measured power.
/// Several sliders add their changes. Range, which the measured mixer lacks, stretches a band's tables along hue
/// about the hue where they act most.
struct ColorMixerTables {
    static let hues = 36, saturations = 6, values = 6
    static let cells = hues * saturations * values
    static let table = 3 * cells
    static let luminanceDarken = 1.6, luminanceLighten = 0.79
    static let data: [Int16] = {
        let bytes = Data(base64Encoded: encodedTables)!
        precondition(bytes.count == 48 * table * 2)
        return bytes.withUnsafeBytes { raw in (0..<(48 * table)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
    }()
    static func value(_ t: Int, _ channel: Int, _ cell: Int) -> Double { Double(data[t * table + channel * cells + cell]) / 8000 }
    /// Each band's hue (turns) in ProPhoto HSV: the circular mean of its tables' changes.
    static let centers: [Double] = (0..<8).map { band in
        var sum = SIMD2<Double>.zero
        for t in band * 6..<(band * 6 + 6) {
            let channel = (t % 6) / 2
            for cell in 0..<cells {
                let angle = (Double(cell / (saturations * values)) + 0.5) / Double(hues) * 2 * .pi
                sum += abs(value(t, channel, cell)) * SIMD2(cos(angle), sin(angle))
            }
        }
        let turn = atan2(sum.y, sum.x) / (2 * .pi)
        return turn - floor(turn)
    }

    /// A band's summed changes per cell; bands at Range 1 share one grid.
    struct Band { var center: Double, range: Double, grid: [SIMD3<Double>] }
    let bands: [Band]

    /// `nil` unless eight bands change something.
    init?(_ adjustments: [SelectiveColorAdjustment]) {
        guard adjustments.count == 8 else { return nil }
        var shared: [SIMD3<Double>]?, bands: [Band] = []
        for (band, a) in adjustments.enumerated() {
            // Hue is stored in degrees, ±60 at the slider's ends.
            let sliders = [a.hue / 60, a.saturation / 100, a.luminance / 100]
            var grid = [SIMD3<Double>](repeating: .zero, count: Self.cells), active = false
            for (kind, s) in sliders.enumerated() where s != 0 {
                active = true
                let size = min(1, abs(s)), index = (band * 3 + kind) * 2 + (s > 0 ? 1 : 0)
                let strength = kind == 2 ? pow(size, s < 0 ? Self.luminanceDarken : Self.luminanceLighten) : size
                for cell in 0..<Self.cells {
                    for c in 0..<3 {
                        let v = Self.value(index, c, cell)
                        // Negative tables scale the saturation factor itself.
                        grid[cell][c] += c == 1 && index % 2 == 0 ? log2(max(1e-3, 1 + strength * (exp2(v) - 1))) : v * strength
                    }
                }
            }
            guard active else { continue }
            if a.range == 1 { shared = shared.map { zip($0, grid).map { $0 + $1 } } ?? grid }
            else { bands.append(Band(center: Self.centers[band], range: a.range, grid: grid)) }
        }
        if let shared { bands.append(Band(center: 0, range: 1, grid: shared)) }
        guard !bands.isEmpty else { return nil }
        self.bands = bands
    }

    /// `rgb` is linear sRGB.
    func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let p = simd_max(FilmMath.toProPhoto * rgb, .zero)
        let high = p.max(), low = p.min()
        guard high > 1e-6 else { return rgb }
        let d = high - low
        // No band moves a neutral.
        guard d >= 1e-9 else { return rgb }
        var h: Double
        if high == p.x { h = (p.y - p.z) / d; h = (h - 6 * floor(h / 6)) / 6 }
        else if high == p.y { h = ((p.z - p.x) / d + 2) / 6 }
        else { h = ((p.x - p.y) / d + 4) / 6 }
        let s = d / high
        var delta = SIMD3<Double>.zero
        for band in bands {
            var offset = h - band.center
            offset -= (offset + 0.5).rounded(.down)
            delta += Self.lookup(band.center + offset / band.range, s, high, band.grid)
        }
        // Colors outside every band stay exactly as they were.
        if delta == .zero { return rgb }
        let hue = (h + delta.x - floor(h + delta.x)) * 6
        let saturation = min(1, max(0, s * exp2(delta.y))), v = high * exp2(delta.z)
        let c = v * saturation, x = c * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let q: SIMD3<Double>
        switch Int(hue) {
        case 0: q = SIMD3(c, x, 0)
        case 1: q = SIMD3(x, c, 0)
        case 2: q = SIMD3(0, c, x)
        case 3: q = SIMD3(0, x, c)
        case 4: q = SIMD3(x, 0, c)
        default: q = SIMD3(c, 0, x)
        }
        return FilmMath.fromProPhoto * (q + (v - c))
    }

    /// Trilinear lookup between grid centers; hue wraps.
    static func lookup(_ h: Double, _ s: Double, _ v: Double, _ grid: [SIMD3<Double>]) -> SIMD3<Double> {
        let fh = (h - floor(h)) * Double(hues) - 0.5
        let fs = min(Double(saturations - 1), max(0, sqrt(min(1, max(0, s))) * Double(saturations) - 0.5))
        let fv = min(Double(values - 1), max(0, pow(min(1, max(0, v)), 0.45) * Double(values) - 0.5))
        let h0 = floor(fh), th = fh - h0, ts = fs - floor(fs), tv = fv - floor(fv)
        let ha = (Int(h0) % hues + hues) % hues, hb = (ha + 1) % hues
        let s0 = Int(fs), v0 = Int(fv), s1 = min(s0 + 1, saturations - 1), v1 = min(v0 + 1, values - 1)
        func at(_ h: Int, _ s: Int, _ v: Int) -> SIMD3<Double> { grid[(h * saturations + s) * values + v] }
        func plane(_ h: Int) -> SIMD3<Double> {
            (at(h, s0, v0) * (1 - tv) + at(h, s0, v1) * tv) * (1 - ts) + (at(h, s1, v0) * (1 - tv) + at(h, s1, v1) * tv) * ts
        }
        return plane(ha) * (1 - th) + plane(hb) * th
    }
}
