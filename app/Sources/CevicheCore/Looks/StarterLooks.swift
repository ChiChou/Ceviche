import Foundation

/// Starting points written for Ceviche, as ordinary presets: nothing here is a new control. Each is Develop's own
/// settings put a known way and saved into the library's Presets, so it is applied, previewed, renamed and thrown
/// away like any other look. The values are Ceviche's own, authored here and not taken from anyone's preset pack,
/// and the names say what a look does rather than what product or film it resembles.
///
/// A look leaves the photo's exposure, white balance, crop and retouching alone: it shapes tone with the curves, not
/// the Light sliders, so it sits on top of whatever correction the photo already has. Every look of a pack carries
/// the same groups of settings, so choosing another one replaces the first completely instead of leaving part of it
/// behind.
public enum StarterLooks {
    public struct Look: Sendable {
        public let name: String
        let make: @Sendable (inout Adjustments) -> Void
    }
    public struct Pack: Sendable {
        /// The folder in Presets, and the pack's name.
        public let folder: String
        /// The groups of settings every look of the pack sets, and so what applying one replaces.
        public let items: Set<EditTransferItem>
        let prepare: @Sendable (inout Adjustments) -> Void
        public let looks: [Look]
        /// A look's settings on a fresh development.
        public func adjustments(_ look: Look) -> Adjustments {
            var settings = Adjustments()
            prepare(&settings); look.make(&settings)
            return settings
        }
    }

    public static let packs = [color, blackWhite]

    /// Writes every pack into `library`'s Presets, a folder each, leaving any file already there as it is: a look the
    /// photographer changed is theirs. Answers how many were written.
    @discardableResult
    public static func install(in library: LookLibrary) throws -> Int {
        var written = 0
        for pack in packs {
            let folder = try library.prepare(.presets).appendingPathComponent(pack.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for look in pack.looks {
                let url = folder.appendingPathComponent(look.name + ".xmp")
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                let data = try XMPCodec.encode(adjustments: pack.adjustments(look).validated(), preset: XMPPreset(name: look.name, items: pack.items))
                try data.write(to: url, options: .atomic)
                written += 1
            }
        }
        return written
    }

    // MARK: Color

    /// More contrast in the middle of the range: darks down, lights up, by the parametric curve.
    private static func contrast(_ a: inout Adjustments, _ amount: Double) { a.parametricCurve.darks -= amount; a.parametricCurve.lights += amount }
    /// Blacks that stop short of black and whites short of white, as a print on matte paper.
    private static func matte(_ a: inout Adjustments, black: Double, white: Double = 1) {
        a.curve = ToneCurve(points: [CurvePoint(x: 0, y: black), CurvePoint(x: 0.25, y: 0.25 + black * 0.45), CurvePoint(x: 0.75, y: 0.75 - (1 - white) * 0.4), CurvePoint(x: 1, y: white)])
    }
    private static func grade(_ a: inout Adjustments, shadows: (Double, Double)? = nil, highlights: (Double, Double)? = nil, balance: Double = 0) {
        if let shadows { a.splitToning.shadowHue = shadows.0; a.splitToning.shadowSaturation = shadows.1 }
        if let highlights { a.splitToning.highlightHue = highlights.0; a.splitToning.highlightSaturation = highlights.1 }
        a.splitToning.balance = balance
    }

    /// General purpose colour, kept short: four finishes by strength, and four moods. For film stocks and a wide
    /// choice of looks there are whole preset libraries to import; these are only somewhere to start.
    public static let color = Pack(folder: "Color", items: [.color, .parametricCurve, .toneCurve, .clarity, .colorGrading, .vignette, .grain], prepare: { _ in }, looks: [
        Look(name: "Natural") { contrast(&$0, 8); $0.vibrance = 8 },
        Look(name: "Vivid") { contrast(&$0, 10); $0.vibrance = 30; $0.saturation = 5; $0.clarity = 8 },
        Look(name: "Punchy") { contrast(&$0, 17); $0.vibrance = 15; $0.clarity = 18; $0.dehaze = 5 },
        Look(name: "Soft") { $0.parametricCurve.shadows = 12; $0.parametricCurve.darks = 6; $0.parametricCurve.highlights = -10; $0.clarity = -10; $0.vibrance = -5 },
        Look(name: "Dark and Moody") {
            $0.parametricCurve.shadows = -10; $0.parametricCurve.darks = -18; $0.parametricCurve.lights = -4; $0.saturation = -12
            grade(&$0, shadows: (210, 10)); $0.postCropVignette.amount = -18
        },
        Look(name: "Matte") { matte(&$0, black: 0.06); $0.parametricCurve.darks = 5; $0.vibrance = -10 },
        Look(name: "Warm") { grade(&$0, shadows: (30, 6), highlights: (45, 14)); $0.vibrance = 8; $0.clarity = -5 },
        Look(name: "Cool") { grade(&$0, shadows: (215, 12), highlights: (200, 5)); $0.vibrance = -5 },
    ])

    // MARK: Black and white

    /// Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta: how much lighter or darker each colour turns grey.
    private static func filter(_ name: String, _ mix: [Double]) -> Look { Look(name: name) { $0.blackWhiteMixer.values = mix } }
    private static func toner(_ name: String, shadows: (Double, Double), highlights: (Double, Double), balance: Double = 0) -> Look {
        Look(name: name) { grade(&$0, shadows: shadows, highlights: highlights, balance: balance) }
    }

    /// Three families. Lens filters, as they were screwed on for black-and-white film: a filter lightens its own
    /// colour and darkens the opposite one (red for dark skies, green for foliage and skin). Toners, as a print is
    /// toned after development. Grades, as paper is chosen for contrast.
    public static let blackWhite = Pack(folder: "Black & White", items: [.color, .blackWhite, .colorGrading, .parametricCurve], prepare: { $0.monochrome = true }, looks: [
        Look(name: "Neutral") { _ in },
        filter("Filter Yellow", [15, 25, 40, 0, -20, -35, -20, 0]),
        filter("Filter Red", [60, 40, 20, -30, -60, -80, -40, 20]),
        filter("Filter Green", [-30, 0, 25, 50, 10, -25, -30, -30]),
        Look(name: "Grade Soft") { $0.parametricCurve.shadows = 18; $0.parametricCurve.darks = 8; $0.parametricCurve.lights = -6; $0.parametricCurve.highlights = -14 },
        Look(name: "Grade Hard") { $0.parametricCurve.shadows = -8; $0.parametricCurve.darks = -24; $0.parametricCurve.lights = 20; $0.parametricCurve.highlights = 6 },
        toner("Toned Sepia", shadows: (35, 20), highlights: (45, 12)),
        toner("Toned Selenium", shadows: (270, 14), highlights: (40, 5), balance: -20),
    ])
}
