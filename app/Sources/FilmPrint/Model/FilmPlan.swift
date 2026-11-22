// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// Which stages a development runs: bits of `FilmPlan.features`, which the kernels read too.
enum FilmFeature {
    static let mtf: UInt32 = 1 << 1, halation: UInt32 = 1 << 2, couplers: UInt32 = 1 << 3, adjacency: UInt32 = 1 << 4
    static let grain: UInt32 = 1 << 5, reversal: UInt32 = 1 << 6, monochrome: UInt32 = 1 << 7, mtfLuma: UInt32 = 1 << 9
    static let couplerDiffusion: UInt32 = 1 << 10, densityIn: UInt32 = 1 << 14, printDetail: UInt32 = 1 << 15
    static let grainMottle: UInt32 = 1 << 16, printMTF: UInt32 = 1 << 17, donorLayer: UInt32 = 1 << 27
}

/// One packed description of a render: the packed configuration, feature
/// mask, seed, and spectral LUTs the Halide engine consumes.
public struct FilmPlan {
    public var configuration: [Float]
    public var spectral: SpectralPipelineTables
    public var spectralCacheID: UInt64
    public var features: UInt32
    public var seed: UInt32
    /// Whether the tone controls may key to the regional base (Options.localTone).
    public let localToneEnabled: Bool
    /// The stock and medium this develop meters its levels for, when it meters at all: Digital
    /// Reference's Auto Levels or Lab Scan's timing.
    var meterStock: FilmStock? = nil
    var meterMedium: PrintPaper = .screen
    var meterScanExposure: Float = 0
    var meterKeys: SIMD3<Float> = .zero
    var meterLevels = MeteredLevels()
    /// `spatialSupport` with halation's reach removed — the apron a strip needs when the
    /// halation fields arrive whole-frame rather than being built from the strip.
    public let spatialSupportSansHalation: Int
    /// The reach of the light chain alone (the emulsion MTF), which is all a LIGHT_OUT strip
    /// carries as apron.
    public let lightSupport: Int

    /// Narrowest grain blur any schedule will apply, in pixels. Mirrors the floor the schedules
    /// clamp to (`FotufilmHalide.cpp` and `FotufilmHalideAndroid.cpp`); here it is only what the
    /// covariance factorization below returns when its target degenerates to white noise, so
    /// a zero-size clump renders exactly the delta it asks for.
    static let grainSigmaFloorPixels: Float = 0.151

    /// Maps a continuous grain clump to the covariance produced by pixel-area integration.
    /// The target autocovariance is `gaussian(√2σ) ⊗ triangle`; the returned discrete Gaussian
    /// matches `R(1)/R(0)`. This correction applies only to clump grain because image content and
    /// Boolean discs already integrate over pixel area.
    /// R(t) = E[(1 - |t - Z|)+], Z ~ N(0, 2 sigma²): the pixel box's triangle read through a
    /// Gaussian field's autocovariance. `sigma` is the field's total continuous Gaussian.
    private static func gaussianLatticeCovariance(_ t: Float, sigma: Float) -> Float {
        // At microscope sampling the cloud spans many pixels. These CDF differences
        // then nearly cancel; Float arithmetic can make a wider cloud look narrower.
        // Keep the integral in Double until the packed kernel parameter is needed.
        let position = Double(t)
        let s = max(2 * Double(sigma) * Double(sigma), 1e-8).squareRoot()
        let phi = { (x: Double) in exp(-0.5 * x * x) / sqrt(2 * Double.pi) }
        let cdf = { (x: Double) in 0.5 * (1 + erf(x / sqrt(2))) }
        let z = { (x: Double) in (x - position) / s }
        return Float((1 + position) * (cdf(z(0)) - cdf(z(-1)))
            + (1 - position) * (cdf(z(1)) - cdf(z(0)))
            + s * (phi(z(-1)) - 2 * phi(z(0)) + phi(z(1))))
    }

    /// The lag-1 correlation the blur this lattice will actually run carries.
    ///
    /// Not a proxy for it. `gaussianRadius` decides how many taps the schedules lay, and past
    /// about 0.6 px that is five or more, whose correlation is not a three-tap's. Reading the
    /// kernel that will be rendered is what lets the sigma below be *solved* for instead of
    /// switched between two approximations that disagree where they meet.
    static func sampledGaussianCorrelation(_ sigma: Float) -> Float {
        let radius = gaussianRadius(sigma)
        guard radius > 0, sigma > 0 else { return 0 }
        let taps = (-radius...radius).map {
            exp(-Double($0 * $0) / (2 * Double(sigma) * Double(sigma)))
        }
        var zero: Double = 0
        var one: Double = 0
        for index in taps.indices { zero += taps[index] * taps[index] }
        for index in 0..<(taps.count - 1) { one += taps[index] * taps[index + 1] }
        return zero > 0 ? Float(one / zero) : 0
    }

    /// Solves a discrete Gaussian sigma for target lag-1 correlation `R(1)/R(0)`.
    /// Bisection is used because correlation is monotonic but piecewise as the kernel radius changes.
    /// Grain amplitude remains calibrated independently at the 48 µm aperture.
    private static func solvedSigma(target: Float) -> Float {
        guard target > 0 else { return grainSigmaFloorPixels }
        var high: Float = 1
        while sampledGaussianCorrelation(high) < target, high < 64 { high *= 2 }
        var low = grainSigmaFloorPixels
        guard sampledGaussianCorrelation(low) < target else { return low }
        for _ in 0..<40 {
            let middle = 0.5 * (low + high)
            if sampledGaussianCorrelation(middle) < target {
                low = middle
            } else {
                high = middle
            }
        }
        return 0.5 * (low + high)
    }

    /// The covariance mixture a partially-sharpened finish leaves on the grain.
    ///
    /// A scan finish is not a pure blur: it spreads the field at `fold` and hands `keep` of the
    /// detail back, so the kernel the grain passes through is `keep·δ + (1-keep)·gauss(fold)`
    /// and its self-correlation splits into three weighted reads — unspread, spread once, and
    /// spread against spread.
    private static func foldMixture(_ read: (Float) -> Float,
                                    fold: Float, keep: Float) -> Float {
        let kept = min(max(keep, 0), 1)
        return kept * kept * read(0)
            + 2 * kept * (1 - kept) * read(fold)
            + (1 - kept) * (1 - kept) * read(fold * 1.4142135)
    }

    /// The lag-1 correlation a continuous Gaussian clump of `clump` pixels leaves once this
    /// lattice has integrated it over pixel area and the finish has folded it.
    ///
    /// Exact pixel-integrated Gaussian covariance at every clump size; a quadrature approximation
    /// is inaccurate near the subpixel transition. `fold` is already self-correlated, so it
    /// contributes half its variance here.
    static func gaussianClumpCorrelation(clumpSigmaPixels clump: Float,
                                         foldSigmaPixels fold: Float,
                                         foldKeep keep: Float) -> Float {
        let read = { (t: Float, f: Float) -> Float in
            Self.gaussianLatticeCovariance(
                t, sigma: (clump * clump + f * f / 2).squareRoot())
        }
        let r0 = foldMixture({ read(0, $0) }, fold: fold, keep: keep)
        let r1 = foldMixture({ read(1, $0) }, fold: fold, keep: keep)
        return r0 > 0 ? r1 / r0 : 0
    }

    static func discreteGrainSigma(clumpSigmaPixels clump: Float,
                                   foldSigmaPixels fold: Float,
                                   foldKeep keep: Float) -> Float {
        solvedSigma(target: gaussianClumpCorrelation(
            clumpSigmaPixels: clump, foldSigmaPixels: fold, foldKeep: keep))
    }

    /// The lag-1 correlation the Boolean field of a silver emulsion leaves on this lattice.
    ///
    /// A silver emulsion's grain is `BooleanGrain`'s field of opaque discs, whose covariance
    /// `(1 - a)² (exp(λ K(h)) - 1)` shortens as coverage `a` rises: past the first disc a second
    /// one mostly lands on film already covered and adds no fluctuation there. The bare overlap
    /// `K(h)` is that field at vanishing coverage only, so the target is read at the coverage the
    /// emulsion actually sits at — `FilmStock.grainAnchorCoverage`, the density the published
    /// granularity is read at. At 157.5 px/mm and a 1.26 px disc that is a lag-1 of 0.475 rather
    /// than the bare overlap's 0.642; the real Coolscan and Noritsu silver targets read 0.27-0.55.
    ///
    /// What the lattice reads is that covariance integrated over the pixel's own area in both
    /// axes and through the enlarger fold. The pixel box's autocorrelation is a triangle per axis
    /// and the fold is separable, so the two-dimensional read factors into one weight row per
    /// axis: `R(t) = ∫∫ C(√(u² + v²)) w_t(u) w_0(v) du dv` with
    /// `w_t(u) = ∫ tri(t - u - s) g_fold(s) ds`, which is `gaussianLatticeCovariance` at `t - u`.
    /// R(0) is divided by C's integral over the plane — the density normalisation that makes a
    /// vanishing disc read 1, the white-noise limit the amplitude is calibrated to. One model at
    /// every radius: a hand-over to the Gaussian route would be a change of model, not of
    /// approximation, at the resolution where it sat.
    static func booleanGrainCorrelation(discRadiusPixels r: Float,
                                        coverage: Float,
                                        foldSigmaPixels fold: Float,
                                        foldKeep keep: Float) -> Float {
        guard r > 0 else { return 0 }
        let radius = Double(r)
        let coverage = Double(min(max(coverage, 1e-4), 0.99))
        let covariance = { (h: Double) -> Double in
            BooleanGrain.coverageCovariance(separation: h, radius: radius,
                                            coverage: coverage)
        }
        // The integrand is bounded by both of its factors: the covariance vanishes past 2r,
        // because discs that far apart can share no centre, and the weights vanish past the
        // triangle's one pixel plus the fold's tail. Whichever is narrower sets the grid, so a
        // disc many pixels wide costs no more to read than a sub-pixel one.
        let span = min(2 * radius, 2 + 6 * Double(fold))
        let steps = min(max(Int((2 * span / 0.03).rounded(.up)), 64), 256) / 2 * 2
        let step = 2 * span / Double(steps)
        let axis = (0..<steps).map { -span + (Double($0) + 0.5) * step }
        var grid = [Float](repeating: 0, count: steps * steps)
        for i in (steps / 2)..<steps {
            for j in (steps / 2)..<steps {
                let value = Float(covariance(
                    (axis[i] * axis[i] + axis[j] * axis[j]).squareRoot()))
                grid[i * steps + j] = value
                grid[(steps - 1 - i) * steps + j] = value
                grid[i * steps + (steps - 1 - j)] = value
                grid[(steps - 1 - i) * steps + (steps - 1 - j)] = value
            }
        }
        // C over the whole plane, radially: what one grain contributes to a reading that cannot
        // resolve it, and so the scale the white-noise limit is measured against.
        let radialSteps = 512
        var radial = 0.0
        for index in 0..<radialSteps {
            let h = 2 * radius * (Double(index) + 0.5) / Double(radialSteps)
            radial += covariance(h) * h
        }
        let integral = Float(2 * Double.pi * radial * 2 * radius / Double(radialSteps))
        guard integral > 0 else { return 0 }
        // `foldMixture` hands this the finish component's self-correlated width; the covariance
        // already carries both arms of the grain's own correlation.
        let response = { (t: Float, f: Float) -> Float in
            let sigma = f * 0.7071068
            let across = axis.map {
                Self.gaussianLatticeCovariance(t - Float($0), sigma: sigma)
            }
            let down = axis.map {
                Self.gaussianLatticeCovariance(-Float($0), sigma: sigma)
            }
            var total: Float = 0
            for i in 0..<steps where across[i] != 0 {
                var row: Float = 0
                for j in 0..<steps { row += grid[i * steps + j] * down[j] }
                total += across[i] * row
            }
            return total * Float(step * step) / integral
        }
        let r0 = min(foldMixture({ response(0, $0) }, fold: fold, keep: keep), 1)
        let r1 = foldMixture({ response(1, $0) }, fold: fold, keep: keep)
        return r0 > 0 ? r1 / r0 : 0
    }

    /// The Gaussian clump, in pixels, that stands in for a silver emulsion's Boolean field on
    /// this lattice: the one whose pixel-integrated correlation is the field's own.
    ///
    /// The render lays a Gaussian, so this is the clump the whole chain past the solve has to
    /// read — the amplitude's 48 µm aperture correction above all, which charges for exactly the
    /// width the render carries. It is not the crystal clump: the Boolean covariance is more
    /// peaked than any Gaussian, so the stand-in is narrower, and reading the correction at the
    /// emulsion's own radius put Tri-X 4.4% over its published granularity at 500 px/mm.
    static func silverEquivalentClumpPixels(discRadiusPixels r: Float,
                                            coverage: Float,
                                            foldSigmaPixels fold: Float,
                                            foldKeep keep: Float) -> Float {
        let target = booleanGrainCorrelation(discRadiusPixels: r, coverage: coverage,
                                             foldSigmaPixels: fold, foldKeep: keep)
        guard target > 0 else { return 0 }
        let correlation = { (clump: Float) -> Float in
            Self.gaussianClumpCorrelation(clumpSigmaPixels: clump,
                                          foldSigmaPixels: fold, foldKeep: keep)
        }
        var high: Float = 1
        while correlation(high) < target, high < 64 { high *= 2 }
        var low: Float = 0
        guard correlation(low) < target else { return 0 }
        for _ in 0..<40 {
            let middle = 0.5 * (low + high)
            if correlation(middle) < target { low = middle } else { high = middle }
        }
        return 0.5 * (low + high)
    }

    /// A reach narrow enough that every schedule resolves it to nothing: `gaussianRadius` returns
    /// zero for it, so the Gaussian collapses to one tap normalised by itself, and it is below
    /// the two-sample threshold at which a blur is run on a decimated grid, so no resampling is
    /// left behind either. What a spatial stage is given when it has been switched off.
    static let noSpatialReachPixels: Float = 0.1

    /// How far a sampled Gaussian of `sigma` has to reach before the taps left out carry less than
    /// 0.27% of its weight — the share a continuous Gaussian leaves outside three sigma, which is
    /// the bound the radii here were always meant to satisfy.
    static func gaussianRadius(_ sigma: Float) -> Int {
        guard sigma > 0.15 else { return 0 }
        let variance = 2 * sigma * sigma
        let limit = Int(ceil(4 * sigma)) + 1
        let tail = (1...limit).map { exp(-Float($0 * $0) / variance) }
        let total = 1 + 2 * tail.reduce(0, +)
        var dropped: Float = 0
        for radius in stride(from: limit, through: 1, by: -1) {
            dropped += 2 * tail[radius - 1]
            if dropped > 0.0027 * total { return radius }
        }
        return 1
    }

    /// The box radius whose triple-pass chain carries `sigmaPixels`, or 0 when the Gaussian is
    /// finer than any expressible radius. Zero is passed through, not clamped to one: the scales
    /// are a weighted mixture, so a scale rendered wider than it was solved for would smear the
    /// continuous profile at exactly the resolutions where its compact lobe is sub-pixel. An
    /// identity scale keeps its weight's energy in place and leaves the mixture sum untouched.
    static func halationBoxRadius(sigmaPixels: Float) -> Int {
        guard sigmaPixels > 0.3 else { return 0 }
        let boxWidth = sqrt(12 * sigmaPixels * sigmaPixels / 3 + 1)
        return Int((boxWidth - 1) / 2)
    }

    /// The triple box spans three radii on the decimated grid. Include the annular sample,
    /// box-cell alignment and bilinear neighbour, as the AOT storage-footprint check does.
    static func boxPyramidSupport(radius: Int, stride: Int, ringRadius: Float = 0) -> Int {
        let gridRadius = Int(GridGeometry.halationStridedRadius(Int32(radius), Int32(stride)))
        let reach = 3 * gridRadius + Int(ceil(ringRadius / Float(stride)))
        return stride == 1 ? reach + 1 : stride * (reach + 2)
    }

    /// The variance a sampled Gaussian of `sigma` actually delivers on this lattice, in pixels².
    ///
    /// A continuous blur and the lattice kernel that stands for it are not the same operator. The
    /// kernel is the continuous Gaussian read at integer offsets and renormalised, and below about
    /// one pixel that reading loses most of the blur: at sigma 0.455 the neighbouring tap carries
    /// 7.6% and the second moment comes to 0.152 px² where the continuous Gaussian asks for 0.207.
    /// Truncation takes a little more at every width. What is left over is a blur the stage was
    /// asked for and did not perform, and the grain — which is the only thing on the frame with
    /// energy right up at Nyquist for it to remove — is where the shortfall shows.
    static func sampledGaussianVariance(_ sigma: Float) -> Float {
        let radius = gaussianRadius(sigma)
        guard radius > 0, sigma > 0 else { return 0 }
        var total: Float = 0
        var moment: Float = 0
        for offset in -radius...radius {
            let weight = exp(-Float(offset * offset) / (2 * sigma * sigma))
            total += weight
            moment += weight * Float(offset * offset)
        }
        return total > 0 ? moment / total : 0
    }

    /// Every stage that happens before the density seam — the scene side, the emulsion's response
    /// and the negative's own spatial work. `FilmStage.print` starts after all of them.
    static let sceneSideFeatures: UInt32 =
        FilmFeature.mtf | FilmFeature.mtfLuma
        | FilmFeature.halation | FilmFeature.couplers
        | FilmFeature.couplerDiffusion | FilmFeature.adjacency
        | FilmFeature.grain | FilmFeature.grainMottle
        // The donor rides the coupler stage, and its exposure comes off the scene through the
        // fourth channel of the exposure LUT — a density-in span is handed a developed negative
        // and has no scene light left to expose a fourth record with, which is why the frame
        // schedule gates the stage on `!density_in`. Without it here the print span would ask
        // for a variant carrying a stage it cannot run.
        | FilmFeature.donorLayer

    /// Plans the development of a `width` by `height` frame on `stock` as `options` say, or throws
    /// `FilmDevelopmentError` for a development condition the stock does not list.
    public init(stock: FilmStock, options: FilmOptions, width: Int, height: Int) throws {
        // A development condition supplies the fresh roll's curves before age and reciprocity.
        let developed = try stock.pushed(stops: options.developmentEV)
        // Every table key below sees the final developed roll.
        let stock = developed.expired(years: max(options.expiredYears, 0))
        // Resolved once, against the developed roll: every stage below reads the medium the
        // picture actually lands on rather than the request, which may name one this stock
        // cannot reach or may name none at all.
        let printMedium = options.paper(for: stock)
        let printer = PrinterProfile.resolved(options.printer, stock: stock, paper: printMedium)
        let printerLights = PrinterLights.resolved(options.printerLights, stock: stock, paper: printMedium)
        // A crop keeps only `frameCoverage` of the frame's short edge, so the same buffer
        // spans fewer millimetres of emulsion and every millimetre-sized structure grows
        // in pixels. The floor keeps a degenerate sliver from asking for unbounded radii.
        let pxPerMM = options.pixelsPerMM(width: width, height: height)
        let mtfSigmas = stock.emulsionDiffusionMM.map { $0 * pxPerMM }
        let mtfRadii = mtfSigmas.map { Self.gaussianRadius($0) }
        let mtfSecondarySigmas = stock.emulsionDiffusionSecondaryMM.map { $0 * pxPerMM }
        let mtfSecondaryRadii = mtfSecondarySigmas.map { Self.gaussianRadius($0) }
        let mtfPrimaryShare = stock.emulsionDiffusionPrimaryShare.map {
            min(max($0, 0), 1)
        }

        // The look scale rides here rather than in the sheet's strengths so the calibrated
        // triple stays readable as physics and a scale of 1/lookScale recovers it exactly.
        let returned = stock.halationStrength.map { max($0, 0) * options.halationScale * stock.halationLookScale }
        let halation = HalationRuntime.kernel(
            returned: returned, base: options.format.base,
            profile: stock.resolvedHalationProfile(useEstimate: false),
            hazeMM: stock.halationHazeMM,
            returnMatrix: stock.halationReturnMatrix)
        let halationMix = halation.mix
        let halationRadii = halation.sigmaMM.map {
            Self.halationBoxRadius(sigmaPixels: $0 * pxPerMM)
        }
        let halationRingRadii = halation.ringRadiusMM.map { max($0 * pxPerMM, 0) }

        let mtfLumaSigma = stock.lumaDiffusionMM * pxPerMM
        let mtfLumaRadius = Self.gaussianRadius(mtfLumaSigma)

        // The couplers' diffusion and the adjacency effect blur on grids, at a stride chosen from the sigma.
        let couplerSigma = stock.couplerDiffusionMM * pxPerMM
        let couplerRadius = Self.gaussianRadius(couplerSigma)
        let adjacencyReferenceSigma = stock.adjacencyRadiusMM * pxPerMM
        let screenedAdjacency = stock.adjacencyModel == .screenedDiffusion
        let adjacencySigma = adjacencyReferenceSigma * (screenedAdjacency
            ? AdjacencyModel.screenedPrimarySigma : 1)
        let adjacencySecondarySigma = screenedAdjacency
            ? adjacencyReferenceSigma * AdjacencyModel.screenedSecondarySigma : 0
        let adjacencySecondaryRadius = Self.gaussianRadius(adjacencySecondarySigma)
        let adjacencyRadius = Self.gaussianRadius(adjacencySigma)
        let adjacencyStrength = stock.adjacencyStrength
        let grainScale = options.grainScale
        // The clump radius is a property of the emulsion, so each layer carries its own: a colour
        // negative coats the blue-sensitive layer on top with the coarsest crystals, and its grain
        // is lower in frequency as well as louder. The blur takes one sigma per channel and one
        // radius wide enough for the widest of them.
        let clumpSigmaMM = stock.grainLayerSizeRatio.map {
            stock.grainClumpSigmaMM * $0
        }
        // A negative that is the output medium is looked at on a light box.
        let negativeViewing = printMedium.isNegative ? NegativeViewing.lightBox : nil
        let showingNegative = negativeViewing != nil && !stock.isReversal
        // Add the enlarger variance that its sampled stage cannot represent at the current pixel
        // spacing. The residual is `sigma² - sampledGaussianVariance(sigma)`, which changes
        // continuously as the sampled kernel gains support. Apply the residual to the spread arm
        // of `keep·δ + (1-keep)·spread`; direct film viewing omits it.
        let enlargerSigmaPixels = printMedium.enlargerBlurMM * pxPerMM
        let enlargerFoldPixels: Float = {
            guard !showingNegative, !printMedium.viewsFilmDirectly(for: stock), enlargerSigmaPixels > 0
            else { return 0 }
            let shortfall = enlargerSigmaPixels * enlargerSigmaPixels
                - Self.sampledGaussianVariance(enlargerSigmaPixels)
            return max(shortfall, 0).squareRoot()
        }()
        let enlargerFoldKeep = enlargerFoldPixels > 0
            ? min(max(printMedium.scanSharpening, 0), 1) : 1
        // A silver emulsion's grain is opaque discs, so what the lattice should carry is the
        // Boolean field's own covariance at the coverage the emulsion sits at, not a Gaussian's
        // tail — which no real silver scan shows once the pixels are coarse. The render still
        // lays a Gaussian, so the clump the rest of the chain reads is the stand-in's, matched
        // to that covariance on this lattice; everything past here — the aperture correction
        // above all — has to be charged for the width actually laid.
        let renderedClumpMM = stock.grainDensityLaw == .silver
            ? clumpSigmaMM.map { clump in
                Self.silverEquivalentClumpPixels(
                    discRadiusPixels: 2 * clump * pxPerMM,
                    coverage: stock.grainAnchorCoverage,
                    foldSigmaPixels: enlargerFoldPixels,
                    foldKeep: enlargerFoldKeep) / pxPerMM
            }
            : clumpSigmaMM
        let grainSigmaLayer = renderedClumpMM.map { clump -> Float in
            Self.discreteGrainSigma(clumpSigmaPixels: clump * pxPerMM,
                                    foldSigmaPixels: enlargerFoldPixels,
                                    foldKeep: enlargerFoldKeep)
        }
        let grainSigma = grainSigmaLayer.max() ?? Self.grainSigmaFloorPixels
        let grainRadius = Self.gaussianRadius(grainSigma)

        // Published granularity is standard deviation through a 48 µm aperture. Correct amplitude
        // using the clump the render lays, not the 0.151 px numerical sigma floor; using the
        // floor made granularity resolution-dependent. The aperture response naturally approaches
        // one for sub-pixel clumps.
        let apertureScale = renderedClumpMM.map { sigma in
            sqrt(Float.pi) * FilmStock.granularityApertureRadiusMM * pxPerMM
                / FilmStock.granularityApertureResponse(clumpSigmaMM: sigma)
        }
        // The grain-size mixture: the published RMS granularity stays the single
        // calibration anchor, split by variance between the sharp field and the
        // coarse mottle, each corrected through the 48 µm aperture at its own
        // size — so the sum reads back the published figure whatever the split.
        // A scanned negative's print keeps to the single field at its whole amplitude.
        let mottleShare = options.stage != .full ? 0 : min(max(stock.grainMottleShare, 0), 0.9)
        let mottleSizeRatio = min(max(stock.grainMottleSizeRatio, 1), 8)
        let mottleClumpMM = clumpSigmaMM.map { $0 * mottleSizeRatio }
        let renderedMottleMM = stock.grainDensityLaw == .silver
            ? mottleClumpMM.map { clump in
                Self.silverEquivalentClumpPixels(
                    discRadiusPixels: 2 * clump * pxPerMM,
                    coverage: stock.grainAnchorCoverage,
                    foldSigmaPixels: enlargerFoldPixels,
                    foldKeep: enlargerFoldKeep) / pxPerMM
            }
            : mottleClumpMM
        let mottleSigmaLayer = renderedMottleMM.map { mottle -> Float in
            Self.discreteGrainSigma(clumpSigmaPixels: mottle * pxPerMM,
                                    foldSigmaPixels: enlargerFoldPixels,
                                    foldKeep: enlargerFoldKeep)
        }
        let mottleSigma = mottleSigmaLayer.max() ?? Self.grainSigmaFloorPixels
        let mottleRadius = Self.gaussianRadius(mottleSigma)
        let mottleApertureScale = renderedMottleMM.map { sigma in
            sqrt(Float.pi) * FilmStock.granularityApertureRadiusMM * pxPerMM
                / FilmStock.granularityApertureResponse(clumpSigmaMM: sigma)
        }
        // The published figure is read where the sheet says — net diffuse density 1.0 for a
        // negative, gross 1.0 for a reversal — so the density law is normalised there and the
        // render reads back the figure at the sheet's condition. Away from that density the
        // law is the emulsion's own: a colour negative's measured granularity peaks 0.15-0.2
        // above D-min and falls, so it is not monotone, and the pipeline evaluates the shape
        // per pixel.
        let grainStrength = stock.grainLayerWeights.enumerated().map { layer, weight in
            stock.grainStrength * grainScale * weight
                * apertureScale[layer] * (1 - mottleShare).squareRoot()
        }
        let mottleStrength = stock.grainLayerWeights.enumerated().map { layer, weight in
            stock.grainStrength * grainScale * weight
                * mottleApertureScale[layer] * mottleShare.squareRoot()
        }
        let clumpsPerPixel = stock.grainClumpsPerMM2 / (pxPerMM * pxPerMM)
        let mottleLambda = clumpsPerPixel
            / (mottleSizeRatio * mottleSizeRatio)
        // The enlarger lens and the paper's own scattering, as one Gaussian on the film's scale.
        // Only when something actually images the film: direct viewing has no enlarger.
        let printMTFActive = !showingNegative && !printMedium.viewsFilmDirectly(for: stock)
            && printMedium.enlargerBlurMM > 0
        let printMTFSigma = max(printMedium.enlargerBlurMM * pxPerMM,
                                Self.grainSigmaFloorPixels)
        let printMTFRadius = printMTFActive ? Self.gaussianRadius(printMTFSigma) : 0
        var contrast = printer == nil
            ? stock.printingContrastScale(correction: 0, paper: printMedium)
            : [Float](repeating: 1, count: 3)
        // A scan's graded styles level the receiver's read in these same slots: the film base to the graded
        // curve's black. Auto Levels and Lab Scan take the frame's own reading on top, once it has been metered
        // (`setToneBase`); until then they sit at the fixed print. A positive takes the paper stage for them too.
        let levelsPositive = printMedium.levelsPositive(for: stock, digitalReference: options.digitalReference)
        // Lab Scan levels each frame on its scan, and takes the operator's colour keys and
        // lightening on the light its film receives (`LabScanTiming`).
        let labScanSetup = printMedium == .labScan && !showingNegative
            ? LabScanTiming.setup(for: stock, sceneHighlightStops: nil, sceneMedianStops: nil, exposureEV: 0,
                                  scanExposure: options.screenExposureEV, keys: options.screenCMY)
            : .identity
        let filmCurves = labScanSetup.curves(for: stock)
        let levels: (scale: SIMD3<Float>, shift: SIMD3<Float>)
        if printMedium == .screen && (levelsPositive || !stock.isReversal) {
            let screen = DigitalReferenceReceiver.levels(for: stock, style: options.digitalReference, sceneHighlightStops: nil, exposureEV: 0)
            levels = (SIMD3(repeating: screen.scale), SIMD3(repeating: screen.shift))
        } else {
            levels = (labScanSetup.scale, labScanSetup.print)
        }
        // Auto Levels re-times red and blue apart from green, in the same midpoint slots.
        let autoColour = printMedium == .screen && options.digitalReference == .autoLevels
            ? DigitalReferenceReceiver.autoColourShift(for: stock, channelMedians: nil, exposureEV: 0)
            : SIMD3<Float>.zero
        contrast = (0..<3).map { contrast[$0] * levels.scale[$0] }
        // Reverse the positive paper's exposure axis in the existing shared CPU/Metal slots.
        let masking = contrast.map { $0 * printMedium.exposureDirection }
        // The paper's three records, each anchored at its own calibrated
        // midpoint so a neutral mid-grey prints neutral through records that
        // do not share a curve. Green keeps the legacy slots; red and blue
        // ride the appended ones.
        let paperCurves = printMedium.printCurves(for: stock,
                                                  digitalReference: options.digitalReference)
        let paper = paperCurves[1]
        // The screen exposure rides the same slots, a constant the meter's deltas leave alone.
        let screenShift = levels.shift + SpectralRuntime.screenExposureShift(
            options.screenExposureEV, stock: stock, paper: printMedium,
            digitalReference: options.digitalReference, screenGrade: options.screenGrade)
        var xMids = printMedium.printExposureMidpoints(
            for: stock, digitalReference: options.digitalReference)
            .enumerated().map { $1 + printMedium.exposureDirection * (screenShift[$0] + autoColour[$0]) }
        // Manual receiver balance follows metering, so Auto Levels cannot cancel the cast.
        // The existing per-record midpoint slots are shared by CPU, Metal and AOT kernels.
        let colourShift = DigitalReferenceReceiver.colourShift(options.screenCMY,
                                                               stock: stock, paper: printMedium)
        for channel in 0..<3 { xMids[channel] += colourShift[channel] }
        // Paper exposure shifts log light after film transmission, before the paper curves.
        // Reuse the midpoint slots to preserve the packed ABI and avoid rebuilding spectral LUTs.
        if let printer, printer.exposureEV != 0 {
            let shift = printMedium.exposureDirection * printer.exposureEV * log10(Float(2))
            xMids = xMids.map { $0 + shift }
        }
        let xMid = xMids[1]

        var featureMask: UInt32 = 0
        let primaryMTFActive = zip(mtfRadii, mtfPrimaryShare)
            .contains { pair in pair.0 > 0 && pair.1 > 0 }
        let secondaryMTFActive = zip(mtfSecondaryRadii, mtfPrimaryShare)
            .contains { pair in pair.0 > 0 && pair.1 < 1 }
        if primaryMTFActive || secondaryMTFActive { featureMask |= FilmFeature.mtf }
        let mtfLumaActive = featureMask & FilmFeature.mtf != 0
            && stock.mtfLumaShare > 0 && mtfLumaRadius > 0
        let mtfProfileActive = featureMask & FilmFeature.mtf != 0
            && (mtfLumaActive || secondaryMTFActive)
        if mtfProfileActive { featureMask |= FilmFeature.mtfLuma }
        if halationMix.contains(where: { $0 > 0 })
            && (halationRadii.contains(where: { $0 > 0 })
                || halationRingRadii.contains(where: { $0 > 0 })) {
            featureMask |= FilmFeature.halation
        }
        let inhibition = stock.couplerGeometry.map { geometry in
            geometry.matrix(gapReachScales: [Float](repeating: 1, count: geometry.layerDepthUM.count - 1), selfScale: 1)
        } ?? stock.couplerInhibition
        let couplerScale = Self.effectiveCouplerScale(options.couplerScale)
        let couplersActive = couplerScale > 0
            && inhibition.contains { $0.contains { $0 != 0 } }
        let requestedFringeAmount = stock.chromaticFringeAmount
        let requestedFringeMM = stock.chromaticFringeRadiusMM
        let fringeAmount = requestedFringeAmount.isFinite ? min(max(requestedFringeAmount, 0), 1) : 0
        let fringeMM = requestedFringeMM.isFinite ? min(max(requestedFringeMM, 0), 2) : 0
        let hasCrossLayerInhibition = inhibition.enumerated().contains { receiver, row in
            row.enumerated().contains { donor, value in receiver != donor && value != 0 }
        }
        let fringeActive = couplersActive && !stock.isMonochrome
            && hasCrossLayerInhibition && fringeAmount > 0
            && fringeMM > stock.couplerDiffusionMM
            && Self.gaussianRadius(fringeMM * pxPerMM) > 0
        let fringeSigma = fringeActive ? fringeMM * pxPerMM : Self.noSpatialReachPixels
        let fringeRadius = fringeActive ? Self.gaussianRadius(fringeSigma) : 0
        if couplersActive { featureMask |= FilmFeature.couplers }
        // The donor capture layer rides the coupler stage: its release row joins the
        // inhibition sum, its activation joins the diffusion blur, and `couplerScale` scales
        // it like the rest. Gated on the reconstruction model being loaded, because the
        // exposure cube's fourth channel is integrated with it — the compact RGB fallback has
        // no spectrum to expose a fourth record, and a donor whose exposure never rose would
        // leave the warp table adding back an inhibition no pixel released.
        let donor = stock.donorLayers.first
        let donorActive = couplerScale > 0
            && donor?.inhibition.contains { $0 != 0 } == true
            && SpectralRuntime.hasReconstructionModel
            // A 4th Color Layer is an inter-image device between colour records that modulates
            // how much *dye* each one forms, so it belongs to a chromogenic colour emulsion and
            // to nothing else: the monochrome schedule develops one record, and a silver emulsion's
            // image is opaque silver rather than a dye cloud. Both are gated here rather than left
            // to the stocks.
            && !stock.isMonochrome && stock.grainDensityLaw != .silver
        if donorActive { featureMask |= FilmFeature.donorLayer }
        if (couplersActive || donorActive) && max(couplerRadius, fringeRadius) > 0 {
            featureMask |= FilmFeature.couplerDiffusion
        }
        if couplerScale > 0 && adjacencyStrength > 0
            && max(adjacencyRadius, adjacencySecondaryRadius) > 0 {
            featureMask |= FilmFeature.adjacency
        }
        if grainScale > 0 && stock.grainStrength > 0 {
            featureMask |= FilmFeature.grain
            if mottleShare > 0 { featureMask |= FilmFeature.grainMottle }
        }
        if printMTFActive && printMTFRadius > 0 {
            featureMask |= FilmFeature.printMTF
        }
        // Shadow and Highlight Detail dodge and burn whatever the film is printed, scanned or
        // viewed as: never the viewed negative.
        let printsDetail = !showingNegative && !printMedium.deliversCodeValues
        if printsDetail && (options.shadowDetail > 0 || options.highlightDetail > 0) {
            featureMask |= FilmFeature.printDetail
        }
        if (printMedium.viewsFilmDirectly(for: stock) && !levelsPositive) || showingNegative {
            featureMask |= FilmFeature.reversal
        }
        if stock.isMonochrome { featureMask |= FilmFeature.monochrome }
        // A scanned negative was exposed and developed already: its print starts from its densities, with none of
        // the stages before them.
        if options.stage == .print { featureMask = (featureMask & ~Self.sceneSideFeatures) | FilmFeature.densityIn }

        var configuration = filmCurves.flatMap(Self.parameters)
        configuration += halationMix
        configuration += inhibition.flatMap { $0 }
        configuration += grainStrength
        configuration += Self.parameters(paper)
        configuration += masking
        configuration += mtfSigmas
        configuration += mtfRadii.map(Float.init)
        configuration += halationRadii.map(Float.init)
        configuration += [couplerSigma, Float(couplerRadius)]
        configuration += [adjacencySigma, Float(adjacencyRadius)]
        configuration += [grainSigma, Float(grainRadius)]
        // No veiling glare is added; the exposure gain is 1 until a metered frame boosts its film.
        configuration += [0, couplerScale, stock.adjacencyStrength * couplerScale, clumpsPerPixel, 1, xMid]
        configuration += [-1, -1, -1]
        // The warp mirrors exactly what a neutral pixel releases per-pixel: the matrix only
        // when the coupler stage runs, the donor row only when the donor does.
        configuration += Self.couplerWarp(
            curves: stock.curves,
            inhibition: couplersActive ? inhibition
                : inhibition.map { $0.map { _ in 0 } },
            scale: (couplersActive || donorActive) ? couplerScale : 0,
            releaseGamma: stock.couplerReleaseGamma,
            donor: donorActive ? donor : nil)
        // The scene's light is integrated in the exposure cube, so its RGB balance is at rest; the tone masks'
        // highlights and shadows are a metered frame's to move (`applyMeteredLevels`), at full saturation.
        configuration += [1, 1, 1]
        configuration += [0, 0, 1, 0]
        configuration += halation.weights.flatMap { $0 }
        configuration += [stock.grainLumaCorrelation]
        configuration += [mtfLumaActive ? stock.mtfLumaShare : 0,
                          mtfLumaSigma, Float(mtfLumaRadius)]
        // The print grade's lift, gain and inverse gamma, at rest.
        configuration += [0, 0, 0, 1, 1, 1, 1, 1, 1]
        configuration += [Float(width), Float(height)]
        configuration += [1, 1]
        var toneGrid = [Float](repeating: 0, count: 2 * Slot.toneGridCells)
        toneGrid[0] = 1
        toneGrid[Slot.toneGridCells] = -0.0
        configuration += toneGrid

        configuration += [0, 0]
        configuration += [mottleSigma, Float(mottleRadius), mottleLambda]
        configuration += mottleStrength
        configuration += Self.parameters(paperCurves[0])
        configuration += Self.parameters(paperCurves[2])
        configuration += [xMids[0], xMids[2]]
        configuration += [Float(stock.grainDensityLaw.rawValue)]
        configuration += (0..<3).map { stock.granularityAnchorDensity(layer: $0) }
        configuration += [Float](repeating: stock.grainFogDensity, count: 3)
        configuration += grainSigmaLayer
        configuration += mottleSigmaLayer
        configuration += [printMTFSigma, Float(printMTFRadius)]
        // Slots of a delivery transform the print does not make.
        configuration += [1, 0, 0, 0, 1, 0, 0, 0, 1] + [Float](repeating: 0, count: 8)
        configuration += [printMTFActive
            ? min(max(printMedium.scanSharpening, 0), 1) : 0]
        // No diffusion filter on the lens: all of the light is direct.
        configuration += [1] + [Float](repeating: 0, count: 9) + [0, 0, 0]
        // The donor capture layer's own curve and its per-receiver release. Read only when
        // FOTUFILM_FRAME_DONOR_LAYER is set, so a stock without one leaves harmless zeros.
        configuration += donorActive ? Self.parameters(labScanSetup.uncoloured(donor!.curve))
                                     : [Float](repeating: 0, count: 6)
        configuration += donorActive ? donor!.inhibition : [0, 0, 0]
        configuration += halationRingRadii
        // The spectral return matrix, in the mix domain (rows sum to the receiver's mix
        // share). Gated exactly as the scalar shares above: a masked-off stage's slots are
        // never read, and a zero matrix returns the direct light whatever the blur did.
        configuration += halation.matrix.flatMap { $0 }
        // Optional second H&D population, followed by the two-scale MTF profile. These are
        // appended so every legacy configuration offset remains stable.
        configuration += filmCurves.flatMap(Self.secondaryParameters)
        configuration += mtfSecondarySigmas
        configuration += mtfSecondaryRadii.map(Float.init)
        configuration += mtfPrimaryShare
        configuration += stock.couplerReleaseGamma
        configuration += [donor?.releaseGamma ?? 1]
        configuration += [0, 0, 0]
        // Only a genuine reversal stock develops to a direct positive. A negative viewed on a
        // light box or scanner shares the reversal feature bit — the output routing is the same —
        // but its emulsion still forms a negative, and the grain rides that density.
        configuration += [stock.isReversal ? 1 : 0]
        // The superseded shared slot keeps the green record's first three coefficients for
        // kernels built against the earlier layout; the per-record rows are appended below.
        configuration += Array(stock.grainDensityProfile.records[1].prefix(3))
        // The material's own SDR knee, which the byte delivery reads; `setOutputTransform`
        // replaces it with the stated delivery's before enabling an `encodeOut` variant.
        configuration += [0]
        configuration += [0, 0, 0, 0] // optional output gamut fit
        for curve in filmCurves { configuration += Self.sampledParameters(curve) }
        configuration += [screenedAdjacency ? 1 : 0,
                          adjacencySecondarySigma, Float(adjacencySecondaryRadius)]
        configuration += [fringeActive ? fringeAmount : 0, fringeSigma, Float(fringeRadius)]
        configuration += [0] // typed record-exposure seam
        configuration += stock.grainReversalProfile
        let printerPreflash = Enlarger.illuminates(stock: stock, paper: printMedium) ? max(0, options.printerPreflash) : 0
        configuration += [0, printerPreflash]
        // The byte frames' primaries, input then output: Display P3 until a road says sRGB.
        configuration += [0, 0]
        configuration += stock.grainDensityProfile.records.flatMap { $0 }
        configuration += [Float](repeating: 0, count: 166)
        // No camera gate: the whole frame is the picture.
        configuration += [0, 0, 0, 0, -1]
        configuration += [0.75, 0]
        configuration += [0]
        configuration += [0, 0, 0, 0, 0, -1, 0, 1]
        configuration += [Float](repeating: 0, count: 7)
        configuration += ApproximateNegativeScan.packed(
            options.stage == .print ? options.scanReading : nil)
        configuration += PrintDetail.packed(
            shadows: printsDetail ? options.shadowDetail : 0,
            highlights: printsDetail ? options.highlightDetail : 0, curves: paperCurves,
            midpoints: printMedium.printExposureMidpoints(
                for: stock, digitalReference: options.digitalReference),
            shown: printMedium == .screen ? DigitalReferenceReceiver.detailDensities(
                style: options.digitalReference, stock: stock,
                grade: SpectralRuntime.effectiveScreenGrade(
                    options.screenGrade, stock: stock, paper: printMedium,
                    digitalReference: options.digitalReference)) : nil)
        precondition(configuration.count == Slot.count)

        var optical = 0
        var lightReach = 0
        if featureMask & FilmFeature.mtf != 0 {
            lightReach = max(mtfRadii.max() ?? 0,
                             mtfSecondaryRadii.max() ?? 0,
                             mtfLumaActive ? mtfLumaRadius : 0)
            optical += lightReach
        }
        var halationReach = 0
        if featureMask & FilmFeature.halation != 0 {
            halationReach = zip(halationRadii, halationRingRadii).map {
                Self.boxPyramidSupport(radius: $0.0,
                    stride: Int(GridGeometry.halationStride(Int32($0.0))), ringRadius: $0.1)
            }.max() ?? 0
            optical += halationReach
        }
        // The coupler, fringe and adjacency fields blur on decimated grids, and a decimated blur
        // reads past its nominal radius: the reach is what the schedule really touches.
        var diffusion = 0
        if featureMask & FilmFeature.couplers != 0 {
            diffusion = max(diffusion,
                            Int(GridGeometry.gaussianReach(couplerSigma, Int32(couplerRadius))),
                            Int(GridGeometry.gaussianReach(fringeSigma, Int32(fringeRadius))))
        }
        if featureMask & FilmFeature.adjacency != 0 {
            diffusion = max(diffusion,
                            Int(GridGeometry.gaussianReach(adjacencySigma,
                                                             Int32(adjacencyRadius))),
                            Int(GridGeometry.gaussianReach(adjacencySecondarySigma,
                                                             Int32(adjacencySecondaryRadius))))
        }
        optical += diffusion
        let grainSupport = featureMask & FilmFeature.grain != 0 ? grainRadius : 0
        // The print MTF reads neighbouring developed densities, so its reach stacks after both
        // the optical chain and the grain field. Omitting it from the optical reach truncates
        // the negative near a tile boundary before the print reads those neighbours.
        let printSupport = featureMask & FilmFeature.printMTF != 0 ? printMTFRadius : 0
        // The same support with halation's reach taken out — what a strip needs when the
        // halation fields arrive whole-frame — and the two pieces the fields path prices its
        // passes by: the reach of the light chain alone, and halation's own.
        self.spatialSupportSansHalation = max(optical - halationReach,
                                              grainSupport) + printSupport
        self.lightSupport = lightReach

        // A regional tone base is a measurement of the scene, which a scanned negative's print is not handed.
        self.localToneEnabled = options.stage == .full
        self.configuration = configuration
        let screenMeters = printMedium == .screen && (!stock.isReversal || levelsPositive)
            && options.digitalReference == .autoLevels
        let labScanMeters = printMedium == .labScan && !stock.isReversal
        if !showingNegative, !stock.isReflectionPrint, screenMeters || labScanMeters, options.stage == .full {
            self.meterStock = stock
            self.meterMedium = printMedium
            self.meterScanExposure = options.screenExposureEV
            self.meterKeys = options.screenCMY
            self.meterLevels = MeteredLevels(
                scale: levels.scale, shift: levels.shift + autoColour, film: labScanSetup)
        }
        if showingNegative, let look = negativeViewing {
            let base = SpectralRuntime.tables(for: stock)
            self.spectral = SpectralPipelineTables(
                exposure: base.exposure,
                filmOutput: SpectralRuntime.negativeViewing(
                    for: stock, look: look, bleachBypass: options.bleachBypass),
                paperOutput: nil)
            self.spectralCacheID = (SpectralRuntime.cacheIdentifier(
                for: stock, bleachBypass: options.bleachBypass))
                ^ (0x4E45474154495645 &+ look.ordinal)
        } else {
            let callier = options.enlarger.callierCoefficient(for: stock, paper: printMedium)
            self.spectral = SpectralRuntime.tables(
                for: stock, paper: printMedium,
                bleachBypass: options.bleachBypass,
                printViewingKelvin: nil,
                callier: callier, printer: printer, printerLights: printerLights,
                digitalReference: options.digitalReference,
                screenGrade: options.screenGrade, screenExposureEV: options.screenExposureEV,
                labScanLook: 1, receiverBands: .paper)
            self.spectralCacheID = SpectralRuntime.cacheIdentifier(
                for: stock, paper: printMedium,
                bleachBypass: options.bleachBypass,
                printViewingKelvin: nil,
                callier: callier, printer: printer, printerLights: printerLights,
                digitalReference: options.digitalReference,
                screenGrade: options.screenGrade, screenExposureEV: options.screenExposureEV,
                labScanLook: 1, receiverBands: .paper)
        }
        // The scene's light is integrated with the film's sensitivities, here; its pixels arrive neutral.
        let illuminant = options.sceneSpectrum(referenceKelvin: stock.referenceIlluminantKelvin)
        self.spectral = SpectralPipelineTables(
            exposure: SpectralRuntime.sceneExposure(for: stock, illuminant: illuminant), filmOutput: self.spectral.filmOutput,
            paperOutput: self.spectral.paperOutput)
        self.spectralCacheID = (self.spectralCacheID ^ SpectralRuntime.illuminantSignature(illuminant)) &* 0x100000001b3
        // Only a print that takes the hold reads the film's corners; any other leaves them zero.
        if featureMask & FilmFeature.printDetail != 0 {
            let corners = Slot.printDetail + 4
            self.configuration.replaceSubrange(corners..<corners + 6,
                                               with: PrintDetail.corners(of: self.spectral.filmOutput))
        }
        self.features = featureMask
        self.seed = UInt32(truncatingIfNeeded: options.seed)
    }

    private static func parameters(_ curve: CharacteristicCurve) -> [Float] {
        // Legacy range consumers still read gamma * (shoulder - toe).
        let gamma = curve.sampled == nil ? curve.gamma
            : (curve.dMax - curve.dMin) / (curve.shoulder - curve.toe)
        return [curve.dMin, gamma, curve.toe, curve.toeWidth,
         curve.shoulder, curve.shoulderWidth]
    }

    /// The calibrated stock is the 100% position. Above it, the creative overdrive approaches a
    /// second calibrated dose instead of continuing without bound: doubled spatial inhibition can
    /// otherwise pull a small yellow subject toward a green surround. Values through 100% retain
    /// their historical linear meaning exactly; the UI's 200% endpoint resolves to 150% physical
    /// inhibition and the asymptote remains 200%.
    static func effectiveCouplerScale(_ requested: Float) -> Float {
        let nonnegative = max(requested, 0)
        guard nonnegative > 1 else { return nonnegative }
        let overdrive = nonnegative - 1
        return 1 + overdrive / (1 + overdrive)
    }

    private static func sampledParameters(_ curve: CharacteristicCurve) -> [Float] {
        var record = [Float](repeating: 0, count: Slot.sampledCurveStride)
        if let sampled = curve.sampled {
            record[0] = Float(sampled.logExposure.count)
            for i in sampled.logExposure.indices {
                record[1 + i * 3] = sampled.logExposure[i]
                record[2 + i * 3] = sampled.density[i]
                record[3 + i * 3] = sampled.slopes[i]
            }
        }
        return record
    }

    /// Re-packs the film's records, and the donor's when it has one, as `setup` exposes them:
    /// every slot a curve occupies, so a metered frame's setup reaches each renderer.
    mutating func packFilmCurves(of stock: FilmStock, setup: LabScanTiming.Setup) {
        let curves = setup.curves(for: stock)
        func write(_ values: [Float], at offset: Int) {
            configuration.replaceSubrange(offset..<(offset + values.count), with: values)
        }
        write(curves.flatMap(Self.parameters), at: Slot.curves)
        write(curves.flatMap(Self.secondaryParameters), at: Slot.curveSecondary)
        write(curves.flatMap(Self.sampledParameters), at: Slot.sampledCurves)
        if let donor = stock.donorLayers.first, features & FilmFeature.donorLayer != 0 {
            write(Self.parameters(setup.uncoloured(donor.curve)), at: Slot.donorCurve)
        }
    }

    private static func secondaryParameters(_ curve: CharacteristicCurve) -> [Float] {
        if curve.sampled != nil { return [0, 0, 1, 0, 1] }
        guard let secondary = curve.secondary else { return [0, 0, 1, 0, 1] }
        return [secondary.gamma, secondary.toe, secondary.toeWidth,
                secondary.shoulder, secondary.shoulderWidth]
    }

    /// Solves the neutral anchor for the DIR coupler stage. `donor` joins the release sum the
    /// way it joins the per-pixel one: the published curves already carry every inter-image
    /// effect a neutral develops — the donor's included — so a donor outside the warp would
    /// develop its inhibition twice on the grey axis.
    static func couplerWarp(curves: [CharacteristicCurve],
                            inhibition: [[Float]], scale: Float,
                            releaseGamma: [Float] = [1, 1, 1],
                            donor: DonorCaptureLayer? = nil) -> [Float] {
        let samples = Slot.couplerWarpSamples
        guard scale > 0,
              inhibition.contains(where: { $0.contains { $0 != 0 } })
                || donor?.inhibition.contains(where: { $0 != 0 }) == true else {
            return [Float](repeating: 0, count: 3 * samples)
        }
        let solveCount = 4 * samples
        let solveLow = Slot.couplerWarpMin - 1
        let solveStep = ((Slot.couplerWarpMax + 1) - solveLow) / Float(solveCount - 1)

        var activation = [[Float]](
            repeating: [Float](repeating: 0, count: solveCount), count: 3)
        for layer in 0..<3 {
            let curve = curves[layer]
            let range = curve.dMax - curve.dMin
            guard range > 0 else { continue }
            for i in 0..<solveCount {
                let l = solveLow + Float(i) * solveStep
                let developed = (curve.density(logExposure: l) - curve.dMin) / range
                activation[layer][i] = inhibitorRelease(
                    activation: developed, gamma: releaseGamma[layer])
            }
        }
        // On the neutral axis the donor is exposed exactly as the layers are — that is what
        // the shared neutral normalization buys — so its activation sits on the same axis.
        var donorActivation = [Float](repeating: 0, count: solveCount)
        if let donor, donor.curve.dMax > donor.curve.dMin {
            let range = donor.curve.dMax - donor.curve.dMin
            for i in 0..<solveCount {
                let l = solveLow + Float(i) * solveStep
                let developed =
                    (donor.curve.density(logExposure: l) - donor.curve.dMin) / range
                donorActivation[i] = inhibitorRelease(
                    activation: developed, gamma: donor.releaseGamma)
            }
        }

        var table = [Float](repeating: 0, count: 3 * samples)
        for channel in 0..<3 {
            var u = [Float](repeating: 0, count: solveCount)
            var offset = [Float](repeating: 0, count: solveCount)
            for i in 0..<solveCount {
                var released: Float = 0
                for donorLayer in 0..<3 {
                    released += inhibition[channel][donorLayer]
                        * activation[donorLayer][i]
                }
                if let donor {
                    released += donor.inhibition[channel] * donorActivation[i]
                }
                offset[i] = scale * released
                u[i] = solveLow + Float(i) * solveStep - offset[i]
            }
            for i in 1..<solveCount where u[i] <= u[i - 1] {
                u[i] = u[i - 1] + 1e-6
            }
            var cursor = 0
            for k in 0..<samples {
                let target = Slot.couplerWarpMin
                    + (Slot.couplerWarpMax - Slot.couplerWarpMin) * Float(k) / Float(samples - 1)
                while cursor + 2 < solveCount && u[cursor + 1] < target { cursor += 1 }
                let span = u[cursor + 1] - u[cursor]
                let t = span > 0 ? min(max((target - u[cursor]) / span, 0), 1) : 0
                table[channel * samples + k] =
                    offset[cursor] + t * (offset[cursor + 1] - offset[cursor])
            }
        }
        return table
    }

    /// Threshold-and-saturation law for development-inhibitor release. The normalized Hill form
    /// fixes 0, 0.5 and 1, so it changes chromatic inter-image response without moving the neutral
    /// anchor's midpoint. Gamma 1 is kept as an exact linear compatibility mode.
    static func inhibitorRelease(activation: Float, gamma: Float) -> Float {
        let a = min(max(activation, 0), 1)
        guard gamma != 1 else { return a }
        let released = Float(pow(Double(a), Double(gamma)))
        let retained = Float(pow(Double(1 - a), Double(gamma)))
        return released / max(released + retained, Float.leastNonzeroMagnitude)
    }

}
