// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

/// Where each quantity sits in a development's packed configuration: the float array `FilmPlan` builds on
/// the CPU and every Metal kernel reads. Offsets are in floats. The shaders take the same numbers through
/// `metalDefinitions`, so the two sides cannot drift apart.
enum Slot {
    static let curves = 0
    static let halation = 18
    static let coupler = 21
    static let grain = 30
    static let paper = 33
    static let masking = 39
    static let mtfSigma = 42
    static let mtfRadius = 45
    static let halationRadius = 48
    static let couplerSigma = 51
    static let couplerRadius = 52
    static let adjacencySigma = 53
    static let adjacencyRadius = 54
    static let grainSigma = 55
    static let grainRadius = 56
    static let flare = 57
    static let couplerScale = 58
    static let adjacencyStrength = 59
    static let grainLambda = 60
    static let exposureGain = 61
    static let paperMidpoint = 62
    static let flareMean = 63
    static let couplerWarp = 66
    static let whiteBalance = 450
    static let highlights = 453
    static let shadows = 454
    static let saturation = 455
    static let vibrance = 456
    static let halationKernel = 457
    static let grainCorrelation = 466
    static let mtfLumaShare = 467
    static let mtfLumaSigma = 468
    static let mtfLumaRadius = 469
    static let gradeLift = 470
    static let gradeGain = 473
    static let gradeInvGamma = 476
    static let frameWidth = 479
    static let frameHeight = 480
    static let toneGridWidth = 481
    static let toneGridHeight = 482
    static let toneGridA = 483
    static let toneGridB = 4579
    static let grainMode = 8675
    static let gradeSpace = 8676
    static let mottleSigma = 8677
    static let mottleRadius = 8678
    static let mottleLambda = 8679
    static let mottle = 8680
    static let paperRed = 8683
    static let paperBlue = 8689
    static let paperMidpointRed = 8695
    static let paperMidpointBlue = 8696
    static let grainLaw = 8697
    static let grainAnchor = 8698
    static let grainFog = 8701
    static let grainSigmaLayer = 8704
    static let mottleSigmaLayer = 8707
    static let printMtfSigma = 8710
    static let printMtfRadius = 8711
    static let outputMatrix = 8712
    static let outputTransfer = 8721
    static let outputCoefficients = 8722
    static let outputPremultiplied = 8728
    static let printSharpen = 8729
    static let diffusionDirect = 8730
    static let diffusionKernel = 8731
    static let diffusionRadius = 8740
    static let donorCurve = 8743
    static let donorRelease = 8749
    static let halationRingRadius = 8752
    static let halationMatrix = 8755
    static let curveSecondary = 8764
    static let mtfSecondarySigma = 8779
    static let mtfSecondaryRadius = 8782
    static let mtfPrimaryShare = 8785
    static let couplerReleaseGamma = 8788
    static let donorReleaseGamma = 8791
    static let donorDiffusionKernel = 8792
    static let developComplement = 8795
    static let grainDensityProfile = 8796
    static let outputShoulder = 8799
    static let outputGamut = 8800
    static let sampledCurves = 8804
    static let adjacencyModel = 18023
    static let adjacencySecondarySigma = 18024
    static let adjacencySecondaryRadius = 18025
    static let chromaticFringeAmount = 18026
    static let chromaticFringeSigma = 18027
    static let chromaticFringeRadius = 18028
    static let recordInput = 18029
    static let grainReversalProfile = 18030
    static let cameraPreflash = 18032
    static let printerPreflash = 18033
    static let byteBasis = 18034
    static let grainDensityRecords = 18036
    static let filmTile = 18054
    static let gate = 18220
    static let hdrRange = 18225
    static let gateCorner = 18227
    static let carrier = 18228
    static let printFinish = 18236
    static let scanReading = 18243
    static let scanCrosstalk = 18262
    static let printDetail = 18271
    /// Floats in a configuration.
    static let count = 18281

    /// Samples per record in the coupler neutral-anchor table, and the log exposures it spans.
    static let couplerWarpSamples = 128
    static let couplerWarpMin: Float = -4, couplerWarpMax: Float = 4
    /// Cells along each side of the regional tone grid.
    static let toneGridEdge = 64
    static let toneGridCells = toneGridEdge * toneGridEdge
    /// Knots a measured characteristic curve may carry, and the floats one record's block takes: a count, then
    /// (log exposure, density, slope) per knot.
    static let sampledCurveMaxSamples = 1024
    static let sampledCurveStride = 1 + 3 * sampledCurveMaxSamples

    /// The same layout as preprocessor definitions for the Metal kernels.
    static let metalDefinitions: String = {
        let slots: [(String, Int)] = [
            ("CURVES", curves), ("HALATION", halation), ("COUPLER", coupler), ("GRAIN", grain), ("PAPER", paper), ("MASKING", masking),
            ("MTF_SIGMA", mtfSigma), ("MTF_RADIUS", mtfRadius), ("HALATION_RADIUS", halationRadius), ("COUPLER_SIGMA", couplerSigma),
            ("COUPLER_RADIUS", couplerRadius), ("ADJACENCY_SIGMA", adjacencySigma), ("ADJACENCY_RADIUS", adjacencyRadius),
            ("GRAIN_SIGMA", grainSigma), ("GRAIN_RADIUS", grainRadius), ("FLARE", flare), ("COUPLER_SCALE", couplerScale),
            ("ADJACENCY_STRENGTH", adjacencyStrength), ("GRAIN_LAMBDA", grainLambda), ("EXPOSURE_GAIN", exposureGain),
            ("PAPER_MIDPOINT", paperMidpoint), ("FLARE_MEAN", flareMean), ("COUPLER_WARP", couplerWarp), ("WHITE_BALANCE", whiteBalance),
            ("HIGHLIGHTS", highlights), ("SHADOWS", shadows), ("SATURATION", saturation), ("VIBRANCE", vibrance),
            ("HALATION_KERNEL", halationKernel), ("GRAIN_CORRELATION", grainCorrelation), ("MTF_LUMA_SHARE", mtfLumaShare),
            ("MTF_LUMA_SIGMA", mtfLumaSigma), ("MTF_LUMA_RADIUS", mtfLumaRadius), ("GRADE_LIFT", gradeLift), ("GRADE_GAIN", gradeGain),
            ("GRADE_INV_GAMMA", gradeInvGamma), ("FRAME_WIDTH", frameWidth), ("FRAME_HEIGHT", frameHeight), ("TONE_GRID_WIDTH", toneGridWidth),
            ("TONE_GRID_HEIGHT", toneGridHeight), ("TONE_GRID_A", toneGridA), ("TONE_GRID_B", toneGridB), ("GRAIN_MODE", grainMode),
            ("GRADE_SPACE", gradeSpace), ("MOTTLE_SIGMA", mottleSigma), ("MOTTLE_RADIUS", mottleRadius), ("MOTTLE_LAMBDA", mottleLambda),
            ("MOTTLE", mottle), ("PAPER_RED", paperRed), ("PAPER_BLUE", paperBlue), ("PAPER_MIDPOINT_RED", paperMidpointRed),
            ("PAPER_MIDPOINT_BLUE", paperMidpointBlue), ("GRAIN_LAW", grainLaw), ("GRAIN_ANCHOR", grainAnchor), ("GRAIN_FOG", grainFog),
            ("GRAIN_SIGMA_LAYER", grainSigmaLayer), ("MOTTLE_SIGMA_LAYER", mottleSigmaLayer), ("PRINT_MTF_SIGMA", printMtfSigma),
            ("PRINT_MTF_RADIUS", printMtfRadius), ("OUTPUT_MATRIX", outputMatrix), ("OUTPUT_TRANSFER", outputTransfer),
            ("OUTPUT_COEFFICIENTS", outputCoefficients), ("OUTPUT_PREMULTIPLIED", outputPremultiplied), ("PRINT_SHARPEN", printSharpen),
            ("DIFFUSION_DIRECT", diffusionDirect), ("DIFFUSION_KERNEL", diffusionKernel), ("DIFFUSION_RADIUS", diffusionRadius),
            ("DONOR_CURVE", donorCurve), ("DONOR_RELEASE", donorRelease), ("HALATION_RING_RADIUS", halationRingRadius),
            ("HALATION_MATRIX", halationMatrix), ("CURVE_SECONDARY", curveSecondary), ("MTF_SECONDARY_SIGMA", mtfSecondarySigma),
            ("MTF_SECONDARY_RADIUS", mtfSecondaryRadius), ("MTF_PRIMARY_SHARE", mtfPrimaryShare), ("COUPLER_RELEASE_GAMMA", couplerReleaseGamma),
            ("DONOR_RELEASE_GAMMA", donorReleaseGamma), ("DONOR_DIFFUSION_KERNEL", donorDiffusionKernel), ("DEVELOP_COMPLEMENT", developComplement),
            ("GRAIN_DENSITY_PROFILE", grainDensityProfile), ("OUTPUT_SHOULDER", outputShoulder), ("OUTPUT_GAMUT", outputGamut),
            ("SAMPLED_CURVES", sampledCurves), ("ADJACENCY_MODEL", adjacencyModel), ("ADJACENCY_SECONDARY_SIGMA", adjacencySecondarySigma),
            ("ADJACENCY_SECONDARY_RADIUS", adjacencySecondaryRadius), ("CHROMATIC_FRINGE_AMOUNT", chromaticFringeAmount),
            ("CHROMATIC_FRINGE_SIGMA", chromaticFringeSigma), ("CHROMATIC_FRINGE_RADIUS", chromaticFringeRadius), ("RECORD_INPUT", recordInput),
            ("GRAIN_REVERSAL_PROFILE", grainReversalProfile), ("CAMERA_PREFLASH", cameraPreflash), ("PRINTER_PREFLASH", printerPreflash),
            ("BYTE_BASIS", byteBasis), ("GRAIN_DENSITY_RECORDS", grainDensityRecords), ("FILM_TILE", filmTile), ("GATE", gate),
            ("HDR_RANGE", hdrRange), ("GATE_CORNER", gateCorner), ("CARRIER", carrier), ("PRINT_FINISH", printFinish), ("SCAN_READING", scanReading),
            ("SCAN_CROSSTALK", scanCrosstalk), ("PRINT_DETAIL", printDetail)
        ]
        var text = slots.map { "#define S_\($0.0) \($0.1)\n" }.joined()
        text += "#define S_COUNT \(count)\n#define COUPLER_WARP_SAMPLES \(couplerWarpSamples)\n"
        text += "#define COUPLER_WARP_MIN \(couplerWarpMin)f\n#define COUPLER_WARP_MAX \(couplerWarpMax)f\n"
        text += "#define SAMPLED_CURVE_MAX_SAMPLES \(sampledCurveMaxSamples)\n#define SAMPLED_CURVE_STRIDE \(sampledCurveStride)\n"
        return text
    }()
}
