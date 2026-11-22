// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

/// What a frame is: scene light to expose on the film, develop and finish, or a scanned negative to print.
public enum FilmStage: Sendable {
    case full, print
}

/// The densities a negative is carried at.
enum NegativeInterchange {
    static let range: ClosedRange<Float> = -0.5...8
}
