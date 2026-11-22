import Foundation
#if os(macOS)
import NetFS
#endif

/// Files on SMB servers. A share that Finder already mounted is used as is; otherwise the share is
/// mounted with the credentials saved in the Keychain for it (or as a guest).
public enum SMBAssetProvider {
    static func availability(host: String, share: String, path: String) -> AssetAvailability {
        #if !os(macOS)
        return .offline(unsupported)
        #else
        if let mount = mountPoint(host: host, share: share) {
            let url = mount.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? .available(url) : .offline(L10n.tr("The file is missing from \(share) on \(host)."))
        }
        return .fetchable("\(share) on \(host)")
        #endif
    }
    /// iPadOS cannot mount SMB shares for an app; such originals open on a Mac.
    static var unsupported: String { L10n.tr("Originals on network shares open on a Mac.") }
    static func fetch(host: String, share: String, path: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let mount = try await mount(host: host, share: share)
        let url = mount.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditorError.invalidDocument(L10n.tr("The file is missing from \(share) on \(host).")) }
        progress(1)
        return url
    }
    /// The mount point of a share Finder (or Ceviche) already mounted.
    public static func mountPoint(host: String, share: String) -> URL? {
        #if !os(macOS)
        return nil
        #else
        // From the kernel's mount table, as it stands: asking each volume how it would be remounted goes to its
        // server, and a share whose server has stopped answering holds that call, and whoever made it, indefinitely.
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&table, MNT_NOWAIT)
        guard count > 0, let table else { return nil }
        for index in 0..<Int(count) {
            var entry = table[index]
            let type = withUnsafeBytes(of: &entry.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard type == "smbfs" else { continue }
            // "//user@host/share", percent-encoded.
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let parts = from.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
            guard parts.count >= 2, let server = parts[0].split(separator: "@").last.map(String.init),
                  server.caseInsensitiveCompare(host) == .orderedSame, parts[1].caseInsensitiveCompare(share) == .orderedSame else { continue }
            let path = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
        #endif
    }
    /// Mounts `smb://host/share` with the saved credentials, returning the mount point.
    public static func mount(host: String, share: String, accounts: StorageAccounts = .load()) async throws -> URL {
        if let existing = mountPoint(host: host, share: share) { return existing }
        #if !os(macOS)
        throw EditorError.invalidDocument(unsupported)
        #else
        let server = accounts.smbServers.first { $0.host.lowercased() == host.lowercased() && $0.share.caseInsensitiveCompare(share) == .orderedSame }
        let username = server?.username ?? ""
        let password = server.flatMap { KeychainStore.string(account: $0.credentialKey) }
        return try await Task.detached(priority: .userInitiated) {
            guard let url = URL(string: "smb://\(host)/\(share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share)") else {
                throw EditorError.invalidDocument(L10n.tr("Invalid SMB address."))
            }
            let openOptions = NSMutableDictionary()
            if username.isEmpty { openOptions[kNetFSUseGuestKey] = true }
            openOptions[kNetFSAllowLoopbackKey] = true
            let mountOptions = NSMutableDictionary()
            mountOptions[kNetFSAllowSubMountsKey] = true
            var mountpoints: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(url as CFURL, nil, username.isEmpty ? nil : username as CFString, password as CFString?,
                                           openOptions, mountOptions, &mountpoints)
            guard status == 0 else {
                let reason = status == 13 || status == 1 ? L10n.tr("Permission denied; check the user name and password saved for this server.") : L10n.tr("Error \(status).")
                throw EditorError.invalidDocument(L10n.tr("Could not connect to \(share) on \(host). \(reason)"))
            }
            if let paths = mountpoints?.takeRetainedValue() as? [String], let first = paths.first { return URL(fileURLWithPath: first) }
            guard let mounted = mountPoint(host: host, share: share) else { throw EditorError.invalidDocument(L10n.tr("\(share) on \(host) did not mount.")) }
            return mounted
        }.value
        #endif
    }
}
