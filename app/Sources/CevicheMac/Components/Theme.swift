import CevicheCore
import SwiftUI

/// The app's palette in one place. Ceviche uses a neutral surround so photos are judged against consistent tones (as in
/// other RAW editors), dark by default, with one accent the user picks in Settings. Every color follows the appearance.
enum Theme {
    /// The chosen swatch, deepened on the light palette so accent text and glyphs keep their contrast.
    static var nsAccent: NSColor { AccentChoice.current.nsColor }
    static var accent: Color { Color(nsColor: nsAccent) }
    /// Text and glyphs on a solid accent fill.
    static var onAccent: Color { Color(nsColor: AccentChoice.current.nsOnColor) }
    /// The tint for system controls (prominent buttons, switches, progress), which draw white over it.
    static var controlAccent: Color { Color(nsColor: AccentChoice.current.nsControlColor) }
    /// Window and Library background; white on the light palette, as Finder's content area is.
    static let nsCanvas = dynamic(dark: NSColor(srgbRed: 0.065, green: 0.072, blue: 0.08, alpha: 1), light: .white)
    static let canvas = Color(nsColor: nsCanvas)
    /// Develop's image surround, slightly darker than the canvas; a mid-light grey on the light palette.
    static let imageSurround = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.06, green: 0.066, blue: 0.073, alpha: 1), light: NSColor(white: 0.84, alpha: 1)))
    /// The sidebar, inspector, filmstrip and sheets; on the light palette, Finder's cool sidebar grey.
    static let panel = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.105, green: 0.115, blue: 0.125, alpha: 1), light: NSColor(srgbRed: 0.959, green: 0.96, blue: 0.966, alpha: 1)))
    /// The window header: the panel color on the dark palette, white like Finder's toolbar on the light one.
    static let toolbar = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.105, green: 0.115, blue: 0.125, alpha: 1), light: .white))
    static let statusBar = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.085, green: 0.09, blue: 0.10, alpha: 1), light: .white))
    static let placeholder = Color(nsColor: dynamic(dark: NSColor(white: 0.12, alpha: 1), light: NSColor(white: 0.88, alpha: 1)))
    /// Hairlines and quiet fills on the panels: white on the dark palette, black on the light one. Overlays drawn on the
    /// photo itself stay white.
    static let nsInk = dynamic(dark: .white, light: .black)
    static let ink = Color(nsColor: nsInk)
    /// Picked and rejected, where a decision has to read at a glance (the burst picker): a green and a red that stay
    /// clear on photos and on both palettes, with white glyphs on them.
    static let pick = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.27, green: 0.76, blue: 0.42, alpha: 1), light: NSColor(srgbRed: 0.15, green: 0.62, blue: 0.3, alpha: 1)))
    static let reject = Color(nsColor: dynamic(dark: NSColor(srgbRed: 0.94, green: 0.33, blue: 0.31, alpha: 1), light: NSColor(srgbRed: 0.84, green: 0.2, blue: 0.18, alpha: 1)))

    /// Something the photographer should look at before going on: a photo left out, a limit reached, a file offline.
    static let warning = Color.orange
    /// Something that failed: a file that couldn't be written, a value that can't be used.
    static let error = reject

    /// Corner radii: one step per kind of surface. Photos are never rounded, since a rounded clip cuts off their
    /// corners; their outlines are square too (`selectionRing`).
    enum Radius {
        /// Badges, chips, swatches and small marks.
        static let tag: CGFloat = 3
        /// Buttons, fields, segmented controls, list rows and their highlights, labels over a photo.
        static let control: CGFloat = 6
        /// A group of settings or details in a panel or dialog.
        static let card: CGFloat = 10
        /// Floating surfaces: drop targets, overlays across a view, the welcome window's cards.
        static let panel: CGFloat = 12
    }
    /// The height of every control at a size: buttons, fields, menus and segments side by side line up whatever their
    /// glyph or text, rather than each taking the height of its own content.
    static func controlHeight(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: 20
        case .small: 24
        case .large, .extraLarge: 32
        default: 28
        }
    }
    /// The one outline for cards and floating surfaces, 1 pt.
    static let hairline = ink.opacity(0.08)
    /// `Rule`'s colour: a pixel-wide line between areas and groups of controls.
    static let rule = ink.opacity(0.12)
    /// The quiet fill of a card on the panel color.
    static let cardFill = ink.opacity(0.035)

    /// Text in three levels, set once for each window so `.primary`, `.secondary` and `.tertiary` read on both palettes.
    /// The system's levels are black at 50 % and 26 % on the light palette: about 4:1 and 1.9:1 against the panels, too
    /// faint for the small labels here. These give 6:1 and 3.3:1 on light and keep the dark palette's 6:1, with its
    /// third level raised from 2.3:1 to 3.2:1 so unset stars and counts still read.
    static let label = LabelLevel(dark: 0.85, light: 0.85)
    static let secondaryLabel = LabelLevel(dark: 0.55, light: 0.62)
    static let tertiaryLabel = LabelLevel(dark: 0.38, light: 0.45)

    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

/// White on the dark palette, black on the light one, at an opacity per palette. Resolved from the view's own color
/// scheme, so a dark overlay on the light palette (`.environment(\.colorScheme, .dark)`) gets light text.
struct LabelLevel: ShapeStyle {
    let dark: Double
    let light: Double
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.colorScheme == .dark ? Color(white: 1, opacity: dark) : Color(white: 0, opacity: light)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// The accent swatches offered in Settings.
enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, indigo, blue, aqua, mint, gold, coral, pink
    /// White on the dark palette and black on the light one.
    case neutral
    static let key = "accentColor"
    static var current: AccentChoice { UserDefaults.standard.string(forKey: key).flatMap(AccentChoice.init) ?? .neutral }
    var id: String { rawValue }
    var name: String {
        switch self {
        case .violet: return L10n.tr("Violet")
        case .indigo: return L10n.tr("Indigo")
        case .blue: return L10n.tr("Blue")
        case .aqua: return L10n.tr("Aqua")
        case .mint: return L10n.tr("Mint")
        case .gold: return L10n.tr("Gold")
        case .coral: return L10n.tr("Coral")
        case .pink: return L10n.tr("Pink")
        case .neutral: return L10n.tr("Neutral")
        }
    }
    private var rgb: (Double, Double, Double) {
        switch self {
        case .neutral: (0.92, 0.92, 0.92)
        case .violet: (0.62, 0.52, 1.0)
        case .indigo: (0.47, 0.50, 0.98)
        case .blue: (0.36, 0.64, 1.0)
        case .aqua: (0.30, 0.82, 0.88)
        case .mint: (0.38, 0.84, 0.62)
        case .gold: (0.89, 0.72, 0.42)
        case .coral: (1.0, 0.52, 0.45)
        case .pink: (0.96, 0.48, 0.76)
        }
    }
    private var dark: NSColor {
        let (r, g, b) = rgb
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    /// Deepened until accent text and glyphs reach 4.5:1 on the light panels: a fixed 30 % left aqua, mint and gold
    /// near 3.3:1.
    private var light: NSColor {
        guard self != .neutral else { return NSColor(white: 0.12, alpha: 1) }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = rgb, panel = 0.906
        var keep = 0.7
        while keep > 0.3 {
            let luminance = 0.2126 * linear(r * keep) + 0.7152 * linear(g * keep) + 0.0722 * linear(b * keep)
            if (panel + 0.05) / (luminance + 0.05) >= 4.5 { break }
            keep -= 0.01
        }
        return NSColor(srgbRed: r * keep, green: g * keep, blue: b * keep, alpha: 1)
    }
    var nsColor: NSColor { Theme.dynamic(dark: dark, light: light) }
    var nsOnColor: NSColor {
        func on(_ color: NSColor) -> NSColor {
            let c = color.usingColorSpace(.sRGB) ?? color
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.5 ? .black : .white
        }
        return Theme.dynamic(dark: on(dark), light: on(light))
    }
    var nsControlColor: NSColor {
        self == .neutral ? Theme.dynamic(dark: NSColor(white: 0.5, alpha: 1), light: NSColor(white: 0.42, alpha: 1)) : nsColor
    }
    var color: Color { Color(nsColor: nsColor) }
}

/// The app-wide appearance from Settings; Dark by default, as photo editors usually are.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    static var current: AppearanceChoice { UserDefaults.standard.string(forKey: key).flatMap(AppearanceChoice.init) ?? .dark }
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return L10n.tr("System")
        case .light: return L10n.tr("Light", context: "appearance")
        case .dark: return L10n.tr("Dark", context: "appearance")
        }
    }
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension View {
    /// Applies the appearance and accent from Settings. A new accent rebuilds the window's views, since the palette is
    /// read from static properties rather than the environment; the models keep their state.
    func themed() -> some View { modifier(ThemeModifier()) }
}

private struct ThemeModifier: ViewModifier {
    @AppStorage(AccentChoice.key) private var accent = AccentChoice.neutral.rawValue
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark.rawValue
    @AppStorage(LanguageChoice.key) private var language = LanguageChoice.system.rawValue
    func body(content: Content) -> some View {
        content.tint(Theme.controlAccent).foregroundStyle(Theme.label, Theme.secondaryLabel, Theme.tertiaryLabel)
            .environment(\.locale, L10n.locale).id("\(accent)-\(language)")
            .onChange(of: appearance, initial: true) { _, _ in AppearanceChoice.current.apply() }
    }
}
