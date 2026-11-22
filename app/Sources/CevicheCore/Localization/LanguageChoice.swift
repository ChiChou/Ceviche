import Foundation

public enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case it = "it"
    case es = "es"

    public static let key = "appLanguage"

    public static var current: LanguageChoice {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(LanguageChoice.init) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
            L10n.updateActiveBundle()
            NotificationCenter.default.post(name: L10n.languageDidChangeNotification, object: nil)
        }
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return L10n.tr("System Default")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .it: return "Italiano"
        case .es: return "Español"
        }
    }
}
