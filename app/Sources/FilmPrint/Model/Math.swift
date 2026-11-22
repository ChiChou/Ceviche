// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

@inlinable
public func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
    min(max(x, lo), hi)
}

@inlinable
public func softplus(_ x: Float) -> Float {
    if x > 20 { return x }
    if x < -20 { return exp(x) }
    return log1p(exp(x))
}

/// Modified Bessel function I0, scaled by exp(-x). Abramowitz & Stegun 9.8.1 and 9.8.2.
///
/// The scaling is not a convenience: the grain aperture response needs I0 at arguments in the
/// tens, where I0 itself overflows well before the answer stops being useful, and only the ratio
/// exp(-x) I0(x) is wanted.
func scaledBesselI0(_ x: Float) -> Float {
    let ax = Double(abs(x))
    if ax < 3.75 {
        let t = (ax / 3.75) * (ax / 3.75)
        let series = 1.0 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492
            + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
        return Float(series * Foundation.exp(-ax))
    }
    let t = 3.75 / ax
    let series = 0.39894228 + t * (0.01328592 + t * (0.00225319
        + t * (-0.00157565 + t * (0.00916281 + t * (-0.02057706
        + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
    return Float(series / ax.squareRoot())
}

/// Modified Bessel function I1, scaled by exp(-x). Abramowitz & Stegun 9.8.3 and 9.8.4.
func scaledBesselI1(_ x: Float) -> Float {
    let ax = Double(abs(x))
    if ax < 3.75 {
        let t = (ax / 3.75) * (ax / 3.75)
        let series = ax * (0.5 + t * (0.87890594 + t * (0.51498869
            + t * (0.15084934 + t * (0.02658733 + t * (0.00301532
            + t * 0.00032411))))))
        return Float(series * Foundation.exp(-ax))
    }
    let t = 3.75 / ax
    let tail = 0.02282967 + t * (-0.02895312 + t * (0.01787654 - t * 0.00420059))
    let series = 0.39894228 + t * (-0.03988024 + t * (-0.00362018
        + t * (0.00163801 + t * (-0.01031555 + t * tail))))
    return Float(series / ax.squareRoot())
}
