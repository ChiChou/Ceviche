// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// Serialised form of a `FilmStock`.
public struct FilmStockDefinition: Codable, Sendable {
    /// Lookup key, unique within a pack.
    public var id: String
    /// Human-readable name, shown in user interfaces.
    public var name: String
    /// Optional one-line description for pickers ("Kodak · colour negative").
    public var subtitle: String?
    /// The gauge this stock is known on — a `FilmFormat.presets` id, such as "super35" for a
    /// motion-picture negative or "120" for a roll film whose reputation was made in medium format.
    public var nativeFormatID: String?
    /// The illuminant the stock is balanced to record neutrally, in kelvin. Absent means the
    /// ordinary 5500 K daylight balance; tungsten stocks state 3200 K in their pack record.
    public var referenceIlluminantKelvin: Float?

    public var sensitivity: [[Float]]
    public var spectral: SpectralSpec
    /// The least each capture layer responds anywhere on the grid, as a share of its own peak.
    /// A manufacturer's sensitivity graph stops where its curves leave the plot, a decade or so
    /// under the peak, and the tails continued past it fall away to nothing; a coated emulsion
    /// keeps a small response everywhere (the silver halide's own blue sensitivity under the
    /// filter layer, the sensitising dyes' far wings). Fitted where the manufacturer publishes
    /// the colour reproduction the records must reach; absent is the published curve alone.
    public var sensitivityFloor: Float?
    public var curves: [CurveSpec]
    /// Coated capture layers beyond the dye-forming ones: records that develop and release
    /// inhibitor but form no image dye (REALA's 4th Color Layer). Optional so that every
    /// earlier pack decodes unchanged; absent is the three-layer stock it always was.
    public var donorLayers: [DonorLayerSpec]?

    public var flare: Float?
    public var emulsionDiffusionMM: [Float]?
    /// Optional second positive Gaussian and the primary scale's blend share. Absent is the
    /// original single-Gaussian MTF exactly.
    public var emulsionDiffusionSecondaryMM: [Float]?
    public var emulsionDiffusionPrimaryShare: [Float]?
    /// Optional fields default to no separation, preserving decoding of earlier packs.
    public var mtfLumaShare: Float?
    public var lumaDiffusionMM: Float?
    public var couplerInhibition: [[Float]]
    /// Per-donor Hill exponents for inhibitor release. Absent is [1, 1, 1], preserving the
    /// historical linear law for older and third-party packs.
    public var couplerReleaseGamma: [Float]? = nil
    /// Optional, and where it is present it is what the engine actually uses — `couplerInhibition`
    /// above is then the matrix this produces, written out so the file still says plainly what it
    /// renders.
    public var couplerGeometry: CouplerGeometry?
    public var couplerDiffusionMM: Float
    public var chromaticFringeAmount: Float? = nil
    public var chromaticFringeRadiusMM: Float? = nil
    public var adjacencyStrength: Float?
    public var adjacencyModel: AdjacencyModel? = nil
    public var adjacencyRadiusMM: Float?

    public var grainStrength: Float
    public var grainSizeMM: Float
    public var grainLayerWeights: [Float]
    public var grainLumaCorrelation: Float?
    /// Optional pair describing the grain-size mixture; absent is the
    /// single-radius field every earlier pack rendered.
    public var grainMottleShare: Float?
    public var grainMottleSizeRatio: Float?
    /// Per-layer clump radius as a multiple of `grainSizeMM`. Absent is [1, 1, 1] — the
    /// single-radius pack, bit-identically.
    public var grainLayerSizeRatio: [Float]?
    /// Which granularity-against-density law the emulsion obeys. Absent reads it off the
    /// material: silver for a monochrome stock, the measured chromogenic negative shape for a
    /// colour negative, saturating power law for a dye reversal. Stated where the material and the law
    /// cross, as they do for a chromogenic black-and-white stock.
    public var grainDensityLaw: GrainDensityLaw?
    /// The chromogenic negative's granularity-against-density shape: one row of
    /// `[amplitude, toeDensity, decayDensity, humpAmplitude, humpDensity, humpWidth]` for all
    /// three records, or one such row per record; a row of three is the earlier form without
    /// the hump. Absent uses the Vision3 family shape; see `GrainDensityProfile`.
    public var grainDensityProfile: GrainDensityProfile?
    /// `[exponent p, shoulder density Ds]` of the dye reversal's saturating power law.
    /// Absent uses the provisional family profile [1.1, 3].
    public var grainReversalProfile: [Float]? = nil
    /// Developed fog, in density above the base's own dye. Absent is the shared default.
    public var grainFogDensity: Float?
    /// Which diffuse density 1.0 the sheet read its granularity at, `net` (1.0 above minimum
    /// density) or `gross`. Absent is the maker convention the material implies — gross for a
    /// reversal, net otherwise — which every earlier pack rendered.
    public var granularityReadDensity: GranularityReadDensity? = nil
    public var halationStrength: [Float]
    /// Authored presentation default: the multiple of `halationStrength` a scale of 1 renders.
    /// Absent is 1 — the measured film, bit-identically, which every earlier pack rendered.
    public var halationLookScale: Float? = nil
    /// Gaussian sigma in millimeters of the support's impurity scatter, softening the halo's
    /// edges. Absent is 0 — the clean support, which every earlier pack rendered.
    public var halationHazeMM: Float? = nil
    /// Optional independently calibrated halo shape. Its absence is the exact legacy model.
    public var halationProfile: HalationProfile? = nil
    /// Optional provisional halo shape, ignored unless explicitly enabled by the renderer.
    public var estimatedHalationProfile: HalationProfile? = nil
    /// Optional spectral return matrix (receiver rows by source columns) from the stock's
    /// per-wavelength return-trip stack transmission. Only its row shapes are rendered —
    /// `halationStrength` stays the amplitude — and its absence is the legacy diagonal mix.
    public var halationReturnMatrix: [[Float]]? = nil

    public var paperCurve: CurveSpec
    public var paperMidDensity: Float?
    /// Where this emulsion leaves the reciprocity law, when its datasheet publishes a
    /// long-exposure table. Absent keeps the classic one-stop-per-decade rule, which is
    /// what every earlier pack rendered.
    public var reciprocityFailure: ReciprocityFailure?
    /// Measured non-reference development conditions. Absent means push/pull is unavailable; the
    /// engine does not manufacture a response from the reference curve.
    public var development: DevelopmentSpec? = nil
    public var isMonochrome: Bool?
    public var isReversal: Bool?
    /// A worked example of the pack format rather than a film anyone shot.
    public var isExample: Bool?
    /// A direct positive that is the print — an integral instant sheet.
    public var isReflectionPrint: Bool?
    /// The id of the finished positive this emulsion was designed to be printed onto — a
    /// `PrintPaper` raw value such as `"vision-2383"`. Absent means the stock states no
    /// preference and takes the engine's default sheet.
    public var nativePrintMedium: String?

    public struct CurveSpec: Codable, Sendable {
        public var dMin: Float
        public var gamma: Float
        public var toe: Float
        public var toeWidth: Float
        public var shoulder: Float
        public var shoulderWidth: Float
        /// A second coated speed group. Absent preserves the original six-parameter curve.
        public var secondary: ComponentSpec?
        public var sampled: SampledCharacteristicCurve?

        public struct ComponentSpec: Codable, Sendable {
            public var gamma: Float
            public var toe: Float
            public var toeWidth: Float
            public var shoulder: Float
            public var shoulderWidth: Float

            public init(_ component: CharacteristicCurveComponent) {
                gamma = component.gamma
                toe = component.toe
                toeWidth = component.toeWidth
                shoulder = component.shoulder
                shoulderWidth = component.shoulderWidth
            }

            public var component: CharacteristicCurveComponent {
                CharacteristicCurveComponent(
                    gamma: gamma, toe: toe, toeWidth: toeWidth,
                    shoulder: shoulder, shoulderWidth: shoulderWidth)
            }
        }

        public init(_ curve: CharacteristicCurve) {
            dMin = curve.dMin
            gamma = curve.gamma
            toe = curve.toe
            toeWidth = curve.toeWidth
            shoulder = curve.shoulder
            shoulderWidth = curve.shoulderWidth
            secondary = curve.secondary.map(ComponentSpec.init)
            sampled = curve.sampled
        }

        public var curve: CharacteristicCurve {
            CharacteristicCurve(dMin: dMin, gamma: gamma, toe: toe,
                                toeWidth: toeWidth, shoulder: shoulder,
                                shoulderWidth: shoulderWidth,
                                secondary: secondary?.component, sampled: sampled)
        }
    }

    /// Serialised form of a `DonorCaptureLayer`.
    public struct DonorLayerSpec: Codable, Sendable {
        /// The record's name as the publication prints it ("CL").
        public var name: String
        /// Spectral sensitivity on `SpectralGrid`, in the same linear units as the
        /// dye-forming records in `spectral`.
        public var sensitivity: [Float]
        /// The donor's own development curve.
        public var curve: CurveSpec
        /// Inhibitor released into each dye-forming layer per unit of donor activation,
        /// R, G, B record order, log-exposure units.
        public var inhibition: [Float]
        /// Hill exponent for inhibitor release. Absent is the historical linear law.
        public var releaseGamma: Float? = nil
        /// Centre depth below the emulsion surface in micrometres, descriptive.
        public var depthUM: Float?

        public init(_ layer: DonorCaptureLayer) {
            name = layer.name
            sensitivity = layer.sensitivity
            curve = CurveSpec(layer.curve)
            inhibition = layer.inhibition
            releaseGamma = layer.releaseGamma
            depthUM = layer.depthUM
        }

        public var layer: DonorCaptureLayer {
            DonorCaptureLayer(name: name, sensitivity: sensitivity,
                              curve: curve.curve, inhibition: inhibition,
                              releaseGamma: releaseGamma ?? 1,
                              depthUM: depthUM)
        }
    }

    public struct DevelopmentSpec: Codable, Sendable {
        public var developer: String
        public var dilution: String?
        public var temperatureC: Float
        public var agitation: String
        public var source: String
        public var sourcePage: Int
        public var conditions: [ConditionSpec]

        public struct ConditionSpec: Codable, Sendable {
            public var stops: Float
            public var label: String
            public var timeMinutes: Float
            public var exposureIndex: Float?
            /// "measured", "transferred" (with `basisStock`) or "estimated".
            public var basis: String
            /// The stock whose published push or pull a transferred condition carries.
            public var basisStock: String?
            public var curves: [CurveSpec]
            public var donorCurves: [CurveSpec]?
            public var grainStrength: Float?
            public var grainSizeMM: Float?
            public var grainLayerWeights: [Float]?
            public var grainFogDensity: Float?
            public var adjacencyStrength: Float?

            public init(_ condition: FilmDevelopmentCondition) {
                stops = condition.stops
                label = condition.label
                timeMinutes = condition.timeMinutes
                exposureIndex = condition.exposureIndex
                switch condition.basis {
                case .measured: basis = "measured"
                case .transferred(let stock): basis = "transferred"; basisStock = stock
                case .estimated: basis = "estimated"
                }
                curves = condition.curves.map(CurveSpec.init)
                donorCurves = condition.donorCurves.isEmpty
                    ? nil : condition.donorCurves.map(CurveSpec.init)
                grainStrength = condition.grainStrength
                grainSizeMM = condition.grainSizeMM
                grainLayerWeights = condition.grainLayerWeights
                grainFogDensity = condition.grainFogDensity
                adjacencyStrength = condition.adjacencyStrength
            }

            /// Nil for a basis the validator rejects.
            public var resolvedBasis: FilmDevelopmentBasis? {
                switch (basis, basisStock) {
                case ("measured", nil): return .measured
                case ("transferred", let stock?): return .transferred(from: stock)
                case ("estimated", nil): return .estimated
                default: return nil
                }
            }

            public var condition: FilmDevelopmentCondition {
                FilmDevelopmentCondition(
                    stops: stops, label: label, timeMinutes: timeMinutes,
                    exposureIndex: exposureIndex, basis: resolvedBasis ?? .estimated,
                    curves: curves.map(\.curve),
                    donorCurves: donorCurves?.map(\.curve) ?? [],
                    grainStrength: grainStrength, grainSizeMM: grainSizeMM,
                    grainLayerWeights: grainLayerWeights,
                    grainFogDensity: grainFogDensity,
                    adjacencyStrength: adjacencyStrength)
            }
        }

        public init(_ profile: FilmDevelopmentProfile) {
            developer = profile.developer
            dilution = profile.dilution
            temperatureC = profile.temperatureC
            agitation = profile.agitation
            source = profile.source
            sourcePage = profile.sourcePage
            conditions = profile.conditions.map(ConditionSpec.init)
        }

        public var profile: FilmDevelopmentProfile {
            FilmDevelopmentProfile(
                developer: developer, dilution: dilution,
                temperatureC: temperatureC, agitation: agitation,
                source: source, sourcePage: sourcePage,
                conditions: conditions.map(\.condition))
        }
    }

    /// How a pack describes the stock's wavelength-domain behaviour. `samples` is the exact form:
    /// `SpectralGrid.count` values per layer on the 380...780 nm grid, which is what a pack calibrated from measured
    /// data will carry.
    public enum SpectralSpec: Codable, Sendable {
        /// Fully specified: sensitivity and image-dye density per layer, already on `SpectralGrid`.
        case samples(layerSensitivity: [[Float]], imageDyeDensity: [[Float]])
        /// Whole-film minimum density plus dye spectra per unit of net record density.
        /// A distinct kind makes older readers reject this model instead of ignoring its base.
        case separatedBase(layerSensitivity: [[Float]], imageDyeDensity: [[Float]],
                           minimumDensity: [Float])
        /// Measured layer sensitivities, with image dyes taken from a process family.
        case measured(layerSensitivity: [[Float]], dyeFamily: FilmDyeFamily)
        /// Generated asymmetric-Gaussian layers from peak wavelengths.
        case color(peaksNM: [Float], widthsNM: [Float]?, dyeFamily: FilmDyeFamily)
        /// Panchromatic response built from broad RGB bands.
        case monochrome(rgbWeights: [Float])

        private enum CodingKeys: String, CodingKey {
            case kind, layerSensitivity, imageDyeDensity, dyeFamily, minimumDensity
            case peaksNM, widthsNM, rgbWeights
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "separatedBase":
                self = .separatedBase(
                    layerSensitivity: try container.decode([[Float]].self, forKey: .layerSensitivity),
                    imageDyeDensity: try container.decode([[Float]].self, forKey: .imageDyeDensity),
                    minimumDensity: try container.decode([Float].self, forKey: .minimumDensity))
            case "samples":
                self = .samples(
                    layerSensitivity: try container.decode([[Float]].self, forKey: .layerSensitivity),
                    imageDyeDensity: try container.decode([[Float]].self, forKey: .imageDyeDensity))
            case "measured":
                self = .measured(
                    layerSensitivity: try container.decode([[Float]].self, forKey: .layerSensitivity),
                    dyeFamily: try container.decode(FilmDyeFamily.self, forKey: .dyeFamily))
            case "color":
                self = .color(
                    peaksNM: try container.decode([Float].self, forKey: .peaksNM),
                    widthsNM: try container.decodeIfPresent([Float].self, forKey: .widthsNM),
                    dyeFamily: try container.decode(FilmDyeFamily.self, forKey: .dyeFamily))
            case "monochrome":
                self = .monochrome(
                    rgbWeights: try container.decode([Float].self, forKey: .rgbWeights))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container,
                    debugDescription: "unknown spectral kind '\(kind)'; expected "
                        + "samples, separatedBase, measured, color or monochrome")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .separatedBase(layerSensitivity, imageDyeDensity, minimumDensity):
                try container.encode("separatedBase", forKey: .kind)
                try container.encode(layerSensitivity, forKey: .layerSensitivity)
                try container.encode(imageDyeDensity, forKey: .imageDyeDensity)
                try container.encode(minimumDensity, forKey: .minimumDensity)
            case let .samples(layerSensitivity, imageDyeDensity):
                try container.encode("samples", forKey: .kind)
                try container.encode(layerSensitivity, forKey: .layerSensitivity)
                try container.encode(imageDyeDensity, forKey: .imageDyeDensity)
            case let .measured(layerSensitivity, dyeFamily):
                try container.encode("measured", forKey: .kind)
                try container.encode(layerSensitivity, forKey: .layerSensitivity)
                try container.encode(dyeFamily, forKey: .dyeFamily)
            case let .color(peaksNM, widthsNM, dyeFamily):
                try container.encode("color", forKey: .kind)
                try container.encode(peaksNM, forKey: .peaksNM)
                try container.encodeIfPresent(widthsNM, forKey: .widthsNM)
                try container.encode(dyeFamily, forKey: .dyeFamily)
            case let .monochrome(rgbWeights):
                try container.encode("monochrome", forKey: .kind)
                try container.encode(rgbWeights, forKey: .rgbWeights)
            }
        }

        public var profile: FilmSpectralProfile {
            switch self {
            case let .separatedBase(layerSensitivity, imageDyeDensity, minimumDensity):
                return FilmSpectralProfile(layerSensitivity: layerSensitivity,
                                          imageDyeDensity: imageDyeDensity,
                                          minimumDensity: minimumDensity)
            case let .samples(layerSensitivity, imageDyeDensity):
                return FilmSpectralProfile(layerSensitivity: layerSensitivity,
                                           imageDyeDensity: imageDyeDensity)
            case let .measured(layerSensitivity, dyeFamily):
                return .measured(layerSensitivity: layerSensitivity, dyeFamily: dyeFamily)
            case let .color(peaksNM, widthsNM, dyeFamily):
                if let widthsNM {
                    return .color(peaksNM: peaksNM, widthsNM: widthsNM, dyeFamily: dyeFamily)
                }
                return .color(peaksNM: peaksNM, dyeFamily: dyeFamily)
            case let .monochrome(rgbWeights):
                return .monochrome(rgbWeights: rgbWeights)
            }
        }
    }
}

public extension FilmStockDefinition {

    /// Materialise the definition into a renderable stock. `FilmStock.init` re-normalises the RGB
    /// matrix and validates layer counts, so a malformed pack fails here rather than part-way
    /// through a render.
    var stock: FilmStock {
        FilmStock(
            name: name,
            sensitivity: sensitivity,
            referenceIlluminantKelvin: referenceIlluminantKelvin ?? 5500,
            spectralProfile: spectral.profile.floored(at: sensitivityFloor ?? 0),
            curves: curves.map(\.curve),
            donorLayers: donorLayers?.map(\.layer) ?? [],
            flare: flare ?? 0.008,
            emulsionDiffusionMM: emulsionDiffusionMM ?? [0, 0, 0],
            emulsionDiffusionSecondaryMM: emulsionDiffusionSecondaryMM ?? [0, 0, 0],
            emulsionDiffusionPrimaryShare: emulsionDiffusionPrimaryShare ?? [1, 1, 1],
            mtfLumaShare: mtfLumaShare ?? 0,
            lumaDiffusionMM: lumaDiffusionMM,
            couplerInhibition: couplerInhibition,
            couplerReleaseGamma: couplerReleaseGamma ?? [1, 1, 1],
            couplerGeometry: couplerGeometry,
            couplerDiffusionMM: couplerDiffusionMM,
            chromaticFringeAmount: chromaticFringeAmount ?? 0,
            chromaticFringeRadiusMM: chromaticFringeRadiusMM ?? 0.1,
            adjacencyStrength: adjacencyStrength ?? 0,
            adjacencyModel: adjacencyModel ?? .gaussian,
            adjacencyRadiusMM: adjacencyRadiusMM ?? 0,
            grainStrength: grainStrength,
            grainSizeMM: grainSizeMM,
            grainLayerWeights: grainLayerWeights,
            grainLumaCorrelation: grainLumaCorrelation ?? 0,
            grainMottleShare: grainMottleShare ?? 0,
            grainMottleSizeRatio: grainMottleSizeRatio ?? 3,
            grainLayerSizeRatio: grainLayerSizeRatio ?? [1, 1, 1],
            grainDensityLaw: grainDensityLaw,
            grainDensityProfile: grainDensityProfile,
            grainReversalProfile: grainReversalProfile ?? FilmStock.defaultGrainReversalProfile,
            grainFogDensity: grainFogDensity ?? FilmStock.defaultGrainFogDensity,
            granularityReadDensity: granularityReadDensity,
            halationStrength: halationStrength,
            halationLookScale: halationLookScale ?? 1,
            halationHazeMM: halationHazeMM ?? 0,
            halationProfile: halationProfile,
            estimatedHalationProfile: estimatedHalationProfile,
            halationReturnMatrix: halationReturnMatrix,
            paperCurve: paperCurve.curve,
            paperMidDensity: paperMidDensity ?? 0.744,
            reciprocityFailure: reciprocityFailure,
            developmentProfile: development?.profile,
            isMonochrome: isMonochrome ?? false,
            isReversal: isReversal ?? false,
            isReflectionPrint: isReflectionPrint ?? false,
            nativePrintMedium: nativePrintMedium.flatMap(PrintPaper.preset(id:)))
    }

}

/// The film stocks the library ships: one definition a file in its `Stocks` resources, as JSON or the same
/// LZFSE-compressed (`<id>.json.lzfse`). Read once, on first use; a stock is materialised from its definition when it
/// is first asked for and kept.
public enum FilmStockLibrary {
    /// Definitions by id, with the presentation metadata `FilmStock` does not carry.
    public static let definitions: [String: FilmStockDefinition] = {
        guard let directory = Bundle.module.url(forResource: "Stocks", withExtension: nil),
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var loaded = [FilmStockDefinition?](repeating: nil, count: entries.count)
        loaded.withUnsafeMutableBufferPointer { slots in
            let slots = UncheckedSendableBox(slots)
            DispatchQueue.concurrentPerform(iterations: entries.count) { index in
                let url = entries[index], name = url.lastPathComponent.lowercased()
                let compressed = name.hasSuffix(".json.lzfse")
                guard compressed || name.hasSuffix(".json"), var data = try? Data(contentsOf: url) else { return }
                if compressed {
                    guard let expanded = try? (data as NSData).decompressed(using: .lzfse) as Data else { return }
                    data = expanded
                }
                slots.value[index] = try? JSONDecoder().decode(FilmStockDefinition.self, from: data)
            }
        }
        return Dictionary(loaded.compactMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// The films to offer, by id: the engineering examples aside.
    public static let ids: [String] = definitions.values.filter { $0.isExample != true }.map(\.id).sorted()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stocks: [String: FilmStock] = [:]

    /// The stock with this id, ready to develop.
    public static func stock(_ id: String) -> FilmStock? {
        lock.lock(); defer { lock.unlock() }
        if let stock = stocks[id] { return stock }
        guard let stock = definitions[id]?.stock else { return nil }
        stocks[id] = stock
        return stock
    }
}

/// Carries a pointer into concurrent work that writes disjoint elements.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

public extension FilmStock {
    static var presetDefinitions: [String: FilmStockDefinition] { FilmStockLibrary.definitions }
    static var presetIDs: [String] { FilmStockLibrary.ids }
    static func named(_ id: String) -> FilmStock? { FilmStockLibrary.stock(id) }
}
