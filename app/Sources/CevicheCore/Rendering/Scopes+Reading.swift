import Foundation

public extension Scopes {
    /// What a point on the vectorscope stands for: its hue in degrees (0 red, 120 green, 240 blue, as in HSL) and its
    /// saturation as a share of the distance to sRGB's edge in that direction, so 1 is a fully saturated sRGB colour
    /// and more than 1 is outside sRGB.
    static func reading(cb: Double, cr: Double) -> (hue: Double, saturation: Double) {
        let length = hypot(cb, cr)
        guard length > 1e-6 else { return (0, 0) }
        // RGB at mid luma for the hue.
        let y = 0.5, r = y + 1.5748 * cr, b = y + 1.8556 * cb, g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
        let maximum = max(r, g, b), minimum = min(r, g, b), range = maximum - minimum
        var hue: Double
        if range < 1e-9 { hue = 0 }
        else if maximum == r { hue = 60 * ((g - b) / range).truncatingRemainder(dividingBy: 6) }
        else if maximum == g { hue = 60 * ((b - r) / range + 2) }
        else { hue = 60 * ((r - g) / range + 4) }
        if hue < 0 { hue += 360 }
        return (hue, length / edge(towards: cb / length, cr / length))
    }

    /// The distance from the centre to the hexagon of 100 % targets along a unit direction.
    static func edge(towards dx: Double, _ dy: Double) -> Double {
        var nearest = Double.infinity
        for index in targets.indices {
            let a = targets[index], c = targets[(index + 1) % targets.count]
            // Solve t·d = a + s·(c − a) for t ≥ 0, 0 ≤ s ≤ 1.
            let ex = c.cb - a.cb, ey = c.cr - a.cr
            let denominator = dx * ey - dy * ex
            guard abs(denominator) > 1e-12 else { continue }
            let t = (a.cb * ey - a.cr * ex) / denominator
            let s = (a.cb * dy - a.cr * dx) / denominator
            if t > 0, s >= -1e-9, s <= 1 + 1e-9 { nearest = min(nearest, t) }
        }
        return nearest.isFinite ? nearest : 0.5
    }
}
