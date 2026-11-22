// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// How a frame is developed and finished: what the Darkroom's controls come to, for one stock.
public struct FilmOptions: Sendable {
    /// Multipliers on the stock's own grain, on the light its base returns as halation, and on its DIR couplers'
    /// inhibition; 0 switches each off.
    public var grainScale: Float = 1
    public var halationScale: Float = 1
    public var couplerScale: Float = 1
    /// Years the roll sat past its date.
    public var expiredYears: Float = 0
    /// Stops of push (positive) or pull development; only the conditions the stock lists can be developed.
    public var developmentEV: Float = 0
    /// The share of silver the bleach leaves in the film: 1 skips the bleach.
    public var bleachBypass: Float = 0
    /// The enlarger's lamp house, for a paper print.
    public var enlarger: Enlarger = .diffuser
    /// The enlarger's timing and filtration; nil is the stock's own on the paper.
    public var printer: PrinterProfile? = nil
    /// A printer's lights, for a print film.
    public var printerLights: PrinterLights = .balanced
    /// Paper preflash, as a share of the paper's mid exposure.
    public var printerPreflash: Float = 0
    /// How far the print holds back its shadows and burns in its highlights, 0...1 each.
    public var shadowDetail: Float = 0
    public var highlightDetail: Float = 0
    /// The medium the film is finished on; nil is the one the stock is made for.
    public var paper: PrintPaper? = nil
    /// The frame the picture fills on the film, which sizes everything stated in millimeters.
    public var format: FilmFormat = .still35
    /// The grain's seed.
    public var seed: UInt64 = 0x46494C4D
    /// How a scan to the screen places the film's tones, the paper grade of its graded curve (0...5, 2 normal), and
    /// the scanner's exposure in stops and color correction.
    public var digitalReference: DigitalReferenceStyle = .default
    public var screenGrade: Float = 2
    public var screenExposureEV: Float = 0
    public var screenCMY: SIMD3<Float> = .zero
    /// Whether the frame is scene light to expose and develop, or a scanned negative to print.
    public var stage: FilmStage = .full
    /// How a scanned negative's scan is read as densities, for `stage == .print`.
    public var scanReading: ApproximateNegativeScan? = nil
    /// The color temperature of the scene's light; nil is the light the film is balanced for, which exposes
    /// neutrals neutral.
    public var sceneIlluminantKelvin: Float? = nil

    public init() {}

    /// The scene's light as a spectrum, for a film balanced for `referenceKelvin`.
    func sceneSpectrum(referenceKelvin: Float) -> [Float] {
        let base = sceneIlluminantKelvin ?? referenceKelvin
        precondition(base.isFinite && base > 0, "invalid scene illuminant")
        return Illuminant.spectrum(WhiteBalance(kelvin: WhiteBalance.miredToKelvin(WhiteBalance.kelvinToMired(base)), tint: WhiteBalance.neutral.tint))
    }

    /// Pixels per millimeter of film for a frame of this size: what every millimeter-sized stage is sized from.
    func pixelsPerMM(width: Int, height: Int) -> Float { Float(min(width, height)) / format.frameHeightMM }

    /// The medium this stock is finished on under these options: the one asked for where the stock can reach it,
    /// else the one it is made for.
    public func paper(for stock: FilmStock) -> PrintPaper {
        paper?.resolved(for: stock) ?? PrintPaper.default(for: stock)
    }
}
