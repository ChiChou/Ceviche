// Derived from the Fotufilm engine (https://github.com/DhaliwalX/fotufilm-engine), Copyright 2026 MUAStudio Inc.,
// licensed under the Apache License, Version 2.0. Changed for Ceviche: reduced to what its film print uses.
// See Sources/CevicheMac/Resources/OpenSourceLicenses/credits/fotufilm.

import Foundation

/// A film gauge.
public struct FilmFormat: Sendable, Equatable {
    public var name: String
    /// Height of the exposed frame in millimeters — the frame's short side
    /// (e.g. 24 for the 36x24 mm 135 frame).
    public var frameHeightMM: Float
    /// Long side divided by short side for the exposed image area.
    public var frameAspectRatio: Float
    /// The support this gauge is coated on.
    public var base: FilmBase

    public init(name: String, frameHeightMM: Float,
                frameAspectRatio: Float = 3.0 / 2.0,
                base: FilmBase = .acetate(thicknessMM: 0.13)) {
        self.name = name
        self.frameHeightMM = frameHeightMM
        self.frameAspectRatio = frameAspectRatio
        self.base = base
    }

    /// Motion-picture camera negative is coated on acetate safety base of
    /// about 0.0053 inch, whatever the gauge.
    private static let cineBase = FilmBase.acetate(thicknessMM: 0.135)

    /// Super 8 motion picture frame (5.79 x 4.01 mm).
    public static let super8 = FilmFormat(name: "Super 8", frameHeightMM: 4.0,
                                          frameAspectRatio: 5.79 / 4.01,
                                          base: cineBase)
    /// Standard/Super 16 motion picture frame (~12.5 x 7.4 mm).
    public static let sixteenMM = FilmFormat(name: "16mm", frameHeightMM: 7.4,
                                             frameAspectRatio: 12.5 / 7.4,
                                             base: cineBase)
    /// Super 35 motion picture frame (24.9 x 18.7 mm).
    public static let super35 = FilmFormat(name: "35mm motion (Super 35)",
                                           frameHeightMM: 18.7,
                                           frameAspectRatio: 24.9 / 18.7,
                                           base: cineBase)
    /// 135 still frame (36 x 24 mm).
    public static let still35 = FilmFormat(name: "35mm still", frameHeightMM: 24,
                                           frameAspectRatio: 36.0 / 24.0,
                                           base: .acetate(thicknessMM: 0.13))
    /// 120 roll film, 6x6 frame (56 x 56 mm).
    public static let mediumFormat120 = FilmFormat(
        name: "120 medium format (6x6)", frameHeightMM: 56,
        frameAspectRatio: 1,
        base: .acetate(thicknessMM: 0.10))
    /// 4x5 inch sheet film (~120 x 95 mm image area).
    public static let largeFormat4x5 = FilmFormat(
        name: "4x5 large format", frameHeightMM: 95,
        frameAspectRatio: 120.0 / 95.0,
        base: .estar(thicknessMM: 0.19))

    /// An integral instant sheet.
    private static let instaxSheet = FilmBase.estar(thicknessMM: 0.10)

    /// instax mini image area, 62 x 46 mm.
    public static let instaxMini = FilmFormat(name: "instax mini",
                                              frameHeightMM: 46,
                                              frameAspectRatio: 62.0 / 46.0,
                                              base: instaxSheet)
    /// instax SQUARE image area, 62 x 62 mm.
    public static let instaxSquare = FilmFormat(name: "instax SQUARE",
                                                frameHeightMM: 62,
                                                frameAspectRatio: 1,
                                                base: instaxSheet)
    /// instax wide image area, 62 x 99 mm.
    public static let instaxWide = FilmFormat(name: "instax wide",
                                              frameHeightMM: 62,
                                              frameAspectRatio: 99.0 / 62.0,
                                              base: instaxSheet)

    /// Ordered list (smallest gauge first) keyed by CLI/UI identifier.
    public static let presets: [(id: String, format: FilmFormat)] = [
        ("super8", .super8),
        ("16mm", .sixteenMM),
        ("super35", .super35),
        ("35mm", .still35),
        ("instaxmini", .instaxMini),
        ("120", .mediumFormat120),
        ("instaxsquare", .instaxSquare),
        ("instaxwide", .instaxWide),
        ("4x5", .largeFormat4x5),
    ]

    public static func preset(id: String) -> FilmFormat? {
        presets.first { $0.id == id }?.format
    }

    /// Default gauge when neither the user, source metadata, nor stock specifies one.
    public static let houseDefaultID = "35mm"

    /// Returns the stock's declared gauge, or the 35 mm default when absent or invalid.
    public static func nativeID(forStockID id: String) -> String {
        guard let named = FilmStock.presetDefinitions[id]?.nativeFormatID,
              preset(id: named) != nil else { return houseDefaultID }
        return named
    }

    /// `nativeID(forStockID:)` resolved to the format itself.
    public static func native(forStockID id: String) -> FilmFormat {
        preset(id: nativeID(forStockID: id)) ?? .still35
    }

    /// How far apart two frame heights are, counted in enlargement: the factor between them,
    /// whichever way round it falls.
    private static func distance(_ measured: Float, _ gauge: Float) -> Float {
        gauge > 0 ? max(measured / gauge, gauge / measured) : .infinity
    }

}
