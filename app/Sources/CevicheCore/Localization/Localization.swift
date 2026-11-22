import Foundation

/// Shared by the SwiftUI app, AppKit panels and background operations. Language selection
/// follows macOS Language & Region or the user's in-app preference.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "it", "es"]
    public static let languageDidChangeNotification = Notification.Name("L10nLanguageDidChangeNotification")
    public static let bundle = Bundle.module

    private static var _activeBundle: Bundle = resolveBundle()

    public static var activeBundle: Bundle {
        _activeBundle
    }

    public static func updateActiveBundle() {
        _activeBundle = resolveBundle()
    }

    private static func resolveBundle() -> Bundle {
        let choice = LanguageChoice.current
        if choice != .system,
           let path = Bundle.module.path(forResource: choice.rawValue, ofType: "lproj"),
           let specific = Bundle(path: path) {
            return specific
        }
        return Bundle.module
    }

    /// Only call with app-owned keys, never with filenames, user text or protocol identifiers.
    public static func key(_ key: String, bundle: Bundle = activeBundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func tr(_ message: Message, bundle: Bundle = activeBundle) -> String {
        format(key(message.key, bundle: bundle), message)
    }
    /// For English that means more than one thing: `context` says which ("orientation", "exposure program"), so
    /// "Landscape" the shape and "Landscape" the scene mode are separate keys (`context|Landscape`) and get their own
    /// translations. Without a translation it reads as the English.
    public static func tr(_ message: Message, context: String, bundle: Bundle = activeBundle) -> String {
        format(bundle.localizedString(forKey: contextKey(message.key, context: context), value: message.key, table: "Localizable"), message)
    }
    /// The table key of a message in a context; the extraction script writes the same.
    static func contextKey(_ key: String, context: String) -> String { context + contextSeparator + key }
    static let contextSeparator = "|"
    private static func format(_ template: String, _ message: Message) -> String {
        guard !message.arguments.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: message.arguments)
    }
    /// The locale that formats numbers in messages: the in-app language when one is chosen.
    public static var locale: Locale {
        let choice = LanguageChoice.current
        return choice == .system ? Locale.current : Locale(identifier: choice.rawValue)
    }

    /// Interpolated values are always objects, so translators may reorder numbered placeholders
    /// without changing their types. Values themselves are never looked up as translation keys.
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
        public let key: String
        let arguments: [String]
        public init(stringLiteral value: String) { key = value; arguments = [] }
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key; arguments = stringInterpolation.arguments
        }
        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            public init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
            }
            public mutating func appendLiteral(_ literal: String) {
                key += literal.replacingOccurrences(of: "%", with: "%%")
            }
            public mutating func appendInterpolation<T>(_ value: T) { append(String(describing: value)) }
            public mutating func appendInterpolation(_ value: Int) { append(value.formatted(.number.grouping(.never))) }
            public mutating func appendInterpolation(_ value: Double) { append(value.formatted(.number.grouping(.never))) }
            public mutating func appendInterpolation(_ value: Double, specifier: String) {
                append(String(format: specifier, locale: L10n.locale, value))
            }
            public mutating func appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F) where F.FormatOutput == String {
                append(format.locale(L10n.locale).format(value))
            }
            private mutating func append(_ value: String) {
                arguments.append(value); key += "%\(arguments.count)$@"
            }
        }
    }
}
