import Foundation
import Security

/// The bearer token every MCP request must carry. The loopback listener answers any process on the Mac,
/// other users' included, so Host and Origin checks alone are not enough.
/// The app writes it to Application Support (0600) and the bundled `ceviche-mcp` reads it from there.
public enum MCPToken {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ceviche/mcp-token")
    }

    /// The saved token, or a new one written with owner-only permissions.
    public static func loadOrCreate(at url: URL = defaultURL) throws -> String {
        if let token = read(at: url) { return token }
        return try regenerate(at: url)
    }

    /// Replaces the token; clients holding the old one get 401 until they read the new one.
    @discardableResult
    public static func regenerate(at url: URL = defaultURL) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPFailure("token", "Unable to generate a token.") }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written to a private temporary file and renamed, so the token is never readable by others, not even briefly.
        let temporary = directory.appendingPathComponent(".mcp-token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw MCPFailure("token", "Unable to write \(url.path).")
        }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    public static func read(at url: URL = defaultURL) -> String? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.count >= 32 ? token : nil
    }

    /// Constant-time comparison of an `Authorization` header against the token.
    public static func authorizes(_ header: String?, token: String) -> Bool {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        let given = Array(header.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
