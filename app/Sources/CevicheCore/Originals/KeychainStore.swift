import Foundation
import Security

/// Generic-password items for storage credentials. Secrets never go into the catalog or iCloud.
public enum KeychainStore {
    public static let service = "me.chichou.ceviche.storage"
    public static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw EditorError.invalidDocument(L10n.tr("Keychain error \(status).")) }
    }
    public static func set(_ string: String, account: String) throws { try set(Data(string.utf8), account: account) }
    public static func data(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    public static func string(account: String) -> String? { data(account: account).flatMap { String(data: $0, encoding: .utf8) } }
    public static func remove(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Storage the user has set up: SMB servers. Secrets live in the Keychain.
public struct StorageAccounts: Codable, Equatable, Sendable {
    public struct SMBServer: Codable, Hashable, Identifiable, Sendable {
        public var host: String
        public var share: String
        public var username: String
        public var id: String { "smb://\(host.lowercased())/\(share)" }
        public init(host: String, share: String, username: String = "") { self.host = host; self.share = share; self.username = username }
        /// Keychain account for the password.
        public var credentialKey: String { "smb:\(host.lowercased())/\(share)" }
    }
    public var smbServers: [SMBServer] = []
    public init() {}
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche/storage.json")
    }
    public static func load(from url: URL = fileURL) -> StorageAccounts {
        guard let data = try? Data(contentsOf: url), let accounts = try? JSONDecoder().decode(StorageAccounts.self, from: data) else { return StorageAccounts() }
        return accounts
    }
    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
