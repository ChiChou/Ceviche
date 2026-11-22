// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// Kodak's Cineon printing-density encoding, as a film scanner writes it: each record's printing
/// density at 0.002 D per code value over the 10-bit range. The scanner is set up on the stock's
/// laboratory aim density — the negative of a normally exposed mid grey — which reads code value
/// 445 in every record (Kodak's digital LAD), so a normal grey is neutral and Resolve's Cineon
/// Film Log reads it as grey. Everything else is the density the film holds above or below that
/// grey: the base lands near 95 where the stock's records are balanced, and wherever the film's
/// own printing densities put it where they are not. Code value 685 is the reference white a
/// normally exposed 90% card is expected near.
///
/// Values travel through the engine as the normalised signal `code value / 1023`, which is what
/// DaVinci Resolve's Cineon Film Log input and a 10-bit DPX's Cineon transfer expect.
public enum CineonLog {
    public static let densityPerCodeValue: Float = 0.002
    /// Where the scanner's set-up puts the laboratory aim density in every record.
    public static let greyCodeValue: Float = 445
    public static let maximumCodeValue: Float = 1023

    /// The normalised signal for printing density above the stock's mid grey; negative below it.
    /// Not clipped: a float delivery keeps what a 10-bit file would clip at either end.
    public static func signal(densityAboveGrey density: Float) -> Float {
        (greyCodeValue + density / densityPerCodeValue) / maximumCodeValue
    }

    /// Printing density above the stock's mid grey for a normalised signal.
    public static func densityAboveGrey(signal: Float) -> Float {
        (signal * maximumCodeValue - greyCodeValue) * densityPerCodeValue
    }

}
