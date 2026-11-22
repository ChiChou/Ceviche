import Foundation
import Security

/// iCloud containers this process is signed for; empty for an ad-hoc build.
enum Entitlements {
    static func containers(_ key: String) -> [String] {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil), let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return [] }
        return value as? [String] ?? []
        #else
        // iOS cannot read its own entitlements, but an app there runs only with its provisioning profile's, and the
        // build names the one container it signs both iCloud entitlements for.
        return (Bundle.main.object(forInfoDictionaryKey: "CevicheCloudContainer") as? String).map { [$0] } ?? []
        #endif
    }
}
