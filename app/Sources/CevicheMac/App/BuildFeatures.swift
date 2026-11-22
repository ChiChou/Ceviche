import Foundation

/// Features chosen at build time (Config/Ceviche.xcconfig), read from the app's Info.plist so that the libraries build
/// the same for every distribution. Outside the app (tests) every feature is off.
enum BuildFeatures {
    /// iCloud catalogs: creating, opening and listing them (`CevicheICloud`). Builds without it hide every iCloud control.
    static let iCloud = info("CevicheICloud") == "YES"
    /// The App Store build (`CevicheDistribution` = appstore): macOS 26, Ceviche Pro; its models are to come from
    /// Apple-hosted assets, and until then are added from files. The community build sells nothing and downloads the
    /// model set it pins from GitHub.
    static let appStore = info("CevicheDistribution") == "appstore"
    /// Ceviche Pro's App Store product IDs, from `CevicheStoreProducts` in Info.plist (CEVICHE_STORE_PRODUCTS); none
    /// outside the App Store build.
    static let storeProducts: [String] = appStore ? storeProducts(from: info("CevicheStoreProducts")) : []
    static func storeProducts(from value: String?) -> [String] {
        var seen = Set<String>()
        return (value ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { seen.insert($0).inserted }
    }
    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
}
