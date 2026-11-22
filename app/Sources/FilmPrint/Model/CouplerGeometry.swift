// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// Derives a DIR inhibition matrix from per-layer release and per-interlayer transmission.
/// `FilmStock.couplerDiffusionMM` models lateral spread separately; vertical propagation composes
/// the transmission of each crossed interlayer.
public struct CouplerGeometry: Sendable, Equatable, Codable {
    /// Centre depth of each sensitive layer below the emulsion surface, in micrometres, in the
    /// engine's usual R, G, B layer order. Only the ordering and the gaps between neighbours are
    /// used; depths must be strictly monotonic so array neighbours are stack neighbours.
    public var layerDepthUM: [Float]

    /// The fraction of a donor layer's inhibitor that survives one coated interlayer, one entry per
    /// gap between adjacent layers — two for the usual three-layer stack, index 0 spanning
    /// `layerDepthUM[0]`–`[1]` and index 1 spanning `[1]`–`[2]`. In the default R, G, B order that
    /// is the red–green scavenger interlayer and the green–blue yellow filter layer.
    public var interlayerTransmission: [Float]

    /// Inhibitor released per unit of development, per donor layer, in the same R, G, B order.
    public var release: [Float]

    /// The fraction of a layer's own released inhibitor that still acts on it as a *separate*
    /// effect, rather than one already absorbed elsewhere.
    public var selfRetention: Float

    /// The stack a colour negative is coated in, in micrometres of depth.
    public static let colorNegativeDepthUM: [Float] = [14, 8, 3]

    /// The self-retention fitted across the shipped packs.
    public static let houseSelfRetention: Float = 0.091

    public init(layerDepthUM: [Float] = CouplerGeometry.colorNegativeDepthUM,
                interlayerTransmission: [Float],
                release: [Float],
                selfRetention: Float = CouplerGeometry.houseSelfRetention) {
        precondition(layerDepthUM.count == 3, "layerDepthUM must have 3 entries")
        precondition(release.count == 3, "release must have 3 entries")
        precondition(interlayerTransmission.count == layerDepthUM.count - 1,
                     "interlayerTransmission needs one entry per gap")
        self.layerDepthUM = layerDepthUM
        self.interlayerTransmission = interlayerTransmission
        self.release = release
        self.selfRetention = selfRetention
    }

    /// The per-gap transmissions an exponential decay of `rangeUM` through the stack implies.
    ///
    /// A non-positive range seals the layers.
    public static func transmission(forRangeUM range: Float,
                                    layerDepthUM: [Float]
                                        = CouplerGeometry.colorNegativeDepthUM) -> [Float] {
        (0..<(layerDepthUM.count - 1)).map { gap in
            guard range > 0 else { return 0 }
            let width = abs(layerDepthUM[gap] - layerDepthUM[gap + 1])
            return exp(-width / range)
        }
    }

    /// The inhibition matrix this geometry implies, indexed `[receiver][donor]` to match
    /// `FilmStock.couplerInhibition`.
    ///
    /// `gapReachScales` is the user's reach multiplier per gap, and it is an *exponent* on the
    /// transmission: the decay form's `exp(-w / (range * v))` is exactly
    /// `[exp(-w / range)] ^ (1/v)`, so scaling a reach and scaling a barrier are the same operation
    /// written two ways. 1 is identity, 0 seals the gap, and above 1 crosses more — the direction
    /// the slider has always had.
    public func matrix(gapReachScales: [Float]? = nil, selfScale: Float = 1) -> [[Float]] {
        let layers = layerDepthUM.count
        let scales = gapReachScales ?? [Float](repeating: 1, count: layers - 1)

        // Transmission of one gap at its reach setting. Identity short-circuits before `pow` so a
        // default render does not depend on `powf(x, 1)` being exact.
        func transmitted(_ gap: Int) -> Float {
            let scale = gap < scales.count ? scales[gap] : 1
            guard scale > 0 else { return 0 }
            let base = interlayerTransmission[gap]
            if scale == 1 { return base }
            return pow(base, 1 / scale)
        }

        return (0..<layers).map { receiver in
            (0..<layers).map { donor in
                if receiver == donor {
                    return release[receiver] * selfRetention * selfScale
                }
                // The inhibitor crosses every interlayer between the two, so the survivals
                // multiply. Sealing one gap therefore also cuts the crossings that span it.
                let span = min(receiver, donor)..<max(receiver, donor)
                let crossing = span.reduce(Float(1)) { $0 * transmitted($1) }
                return release[donor] * crossing
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case layerDepthUM
        case interlayerTransmission
        case release
        case selfRetention
    }

    /// Reject malformed layer counts before they reach the renderer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let depths = try container.decodeIfPresent(
            [Float].self, forKey: .layerDepthUM) ?? Self.colorNegativeDepthUM
        let release = try container.decode([Float].self, forKey: .release)
        guard depths.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .layerDepthUM, in: container,
                debugDescription:
                    "layerDepthUM needs one depth per layer (3), got \(depths.count)")
        }
        guard release.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .release, in: container,
                debugDescription:
                    "release needs one strength per layer (3), got \(release.count)")
        }

        let transmission = try container.decode([Float].self, forKey: .interlayerTransmission)
        guard transmission.count == depths.count - 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .interlayerTransmission, in: container,
                debugDescription: "interlayerTransmission needs two entries, got \(transmission.count)")
        }

        self.layerDepthUM = depths
        self.interlayerTransmission = transmission
        self.release = release
        self.selfRetention = try container.decodeIfPresent(
            Float.self, forKey: .selfRetention) ?? Self.houseSelfRetention
    }
}

public extension CouplerGeometry {

    /// RMS disagreement between this geometry and an authored matrix, in the matrix's own units.
    func residual(against matrix: [[Float]]) -> Float {
        let produced = self.matrix()
        var sum: Float = 0
        for i in 0..<3 {
            for j in 0..<3 {
                let d = produced[i][j] - matrix[i][j]
                sum += d * d
            }
        }
        return (sum / 9).squareRoot()
    }
}

public extension CouplerGeometry {
}
