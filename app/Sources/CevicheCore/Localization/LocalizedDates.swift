import Foundation

/// Dates shown in the interface, in the in-app language. `formatted()` alone follows `Locale.current`, which keeps the
/// language the process launched with after the language is changed in Settings.
public extension Date {
    func localized(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: L10n.locale))
    }
    func localized(_ style: Date.FormatStyle) -> String { formatted(style.locale(L10n.locale)) }
    /// "2 hours ago", "yesterday".
    func localizedRelative() -> String { formatted(Date.RelativeFormatStyle(presentation: .named, locale: L10n.locale)) }
    /// The same in as few characters as the language allows ("3 min. ago"), for a list's narrow column.
    func localizedRelativeShort() -> String { formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .narrow, locale: L10n.locale)) }
}

public extension Duration {
    func localized(_ style: Duration.UnitsFormatStyle) -> String { formatted(style.locale(L10n.locale)) }
}
