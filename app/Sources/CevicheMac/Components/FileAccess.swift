import AppKit
import Security
import CevicheCore

/// Keep user-selected grants alive for background work and restore them before reopening catalogs.
@MainActor
final class FileAccess {
    static let shared = FileAccess()
    nonisolated static var sandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true
    }
    nonisolated static var home: URL {
        guard let path = getpwuid(getuid())?.pointee.pw_dir else { return FileManager.default.homeDirectoryForCurrentUser }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    private var grants: [String: URL] = [:]
    private var bookmarks: [String: Data]
    private init() {
        bookmarks = UserDefaults.standard.dictionary(forKey: "fileAccessBookmarks") as? [String: Data] ?? [:]
        for data in bookmarks.values {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() { grants[url.standardizedFileURL.path] = url }
        }
    }
    func remember(_ url: URL) {
        guard Self.sandboxed else { return }
        let path = url.standardizedFileURL.path
        guard grants[path] == nil || bookmarks[path] == nil else { return }
        let access = grants[path] == nil && url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks[path] = data
            UserDefaults.standard.set(bookmarks, forKey: "fileAccessBookmarks")
        }
        if access { grants[path] = url }
    }
    /// Ordinary bookmarks transfer the caller's current sandbox extensions across XPC. App-scoped bookmarks
    /// stored in the catalog belong to the main app and cannot grant the service access on their own.
    func transferBookmarks(for root: URL) -> [Data] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return (Array(grants.values) + [root, support]).compactMap {
            try? $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
    /// A sidebar path carries no Powerbox grant. Ask for the selected folder, never the entire disk.
    func authorizeFolder(_ url: URL) -> Bool {
        guard Self.sandboxed else { return true }
        let path = url.standardizedFileURL.path
        if grants.keys.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = url
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.standardizedFileURL.path == path else { return false }
        remember(selected)
        return true
    }
}
