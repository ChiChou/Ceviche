// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// How a scan of a color negative is read as the film's record densities: the sampled border removes base and fog,
/// and the chosen film restores its own base. Each record reads its own scan channel unless `weights` say otherwise.
/// This fits no scanner profile and corrects neither illumination nor flare.
public struct ApproximateNegativeScan: Equatable, Sendable {
    public enum Failure: Error { case positiveFilm, invalidBorder }
    public let border: [Float]
    public let baseDensity: [Float]
    /// The scan channel each record mostly reads, which sets the usable range.
    public let recordChannels: [Int]
    /// Record density per unit of scan-channel density above the border.
    public let gains: [Float]
    /// What each record reads from the scan channels' densities over the border.
    public let weights: [SIMD3<Float>]
    public let minimumSample: [Float]
    public let maximumSample: [Float]

    public init(stock: FilmStock, border: SIMD3<Float>) throws {
        guard !stock.isReversal else { throw Failure.positiveFilm }
        guard (0..<3).allSatisfy({ border[$0].isFinite && border[$0] > 0 }) else { throw Failure.invalidBorder }
        self.border = [border.x, border.y, border.z]
        baseDensity = (0..<3).map { stock.curves[$0].dMin }
        recordChannels = stock.isMonochrome ? [1, 1, 1] : [0, 1, 2]
        gains = [1, 1, 1]
        weights = NegativeScanCrosstalk.weights(for: stock, correction: .none, neutral: nil)
        var minimum = [Float](repeating: 0, count: 3)
        var maximum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        for record in 0..<3 {
            let channel = recordChannels[record]
            // A margin inside the densities a negative is carried at.
            let low = border[channel] * pow(10, (baseDensity[record] - NegativeInterchange.range.upperBound) + 0.0001)
            let high = border[channel] * pow(10, (baseDensity[record] - NegativeInterchange.range.lowerBound) - 0.0001)
            minimum[channel] = max(minimum[channel], low)
            maximum[channel] = min(maximum[channel], high)
        }
        minimumSample = minimum
        maximumSample = maximum
    }

    /// The reading as the kernels take it (`Slot.scanReading`, then `Slot.scanCrosstalk`); all zero for a print that
    /// is handed no scan.
    static func packed(_ scan: ApproximateNegativeScan?) -> [Float] {
        var slots = [Float](repeating: 0, count: Slot.scanCrosstalk - Slot.scanReading + 9)
        guard let scan else { return slots }
        slots[0] = 1
        for c in 0..<3 {
            slots[1 + c] = scan.border[c]
            slots[4 + c] = scan.baseDensity[c]
            slots[7 + c] = Float(scan.recordChannels[c])
            slots[10 + c] = scan.gains[c]
            slots[13 + c] = scan.minimumSample[c]
            slots[16 + c] = scan.maximumSample[c]
        }
        let crosstalk = Slot.scanCrosstalk - Slot.scanReading
        for record in 0..<3 { for channel in 0..<3 { slots[crosstalk + record * 3 + channel] = scan.weights[record][channel] } }
        return slots
    }
}
