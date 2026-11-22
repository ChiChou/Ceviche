// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// Reciprocity failure shifts each layer's characteristic curve for long exposures. Corrections
/// follow stock data as `rate × log10(time / threshold)` and stop at the last stated exposure.
/// Stocks without reciprocity data remain unchanged.

/// Where a particular emulsion leaves the law, as its datasheet says.
public struct ReciprocityFailure: Codable, Sendable, Equatable {
    /// Exposures at or under this many seconds are inside the law.
    public var thresholdSeconds: Float
    /// Stops lost per decade past the threshold. Zero represents a stated no-correction interval.
    public var lostStopsPerDecade: Float
    /// Last exposure covered by the source data. The correction is held constant beyond it. Nil
    /// represents an open-ended published rule.
    public var statedThroughSeconds: Float?
    /// Per-record rate multipliers in R, G, B order with mean 1. Nil uses the default colour
    /// ordering; monochrome uses 1.
    public var layerWeights: [Float]?

    public init(thresholdSeconds: Float, lostStopsPerDecade: Float,
                statedThroughSeconds: Float? = nil,
                layerWeights: [Float]? = nil) {
        self.thresholdSeconds = thresholdSeconds
        self.lostStopsPerDecade = lostStopsPerDecade
        self.statedThroughSeconds = statedThroughSeconds
        self.layerWeights = layerWeights
    }
}

extension FilmStock {

}
