import Foundation
import Darwin
import CevicheCore

// Optional stdio adapter for clients without Streamable HTTP support. All application
// operations still execute inside the running app. No catalog is opened in this process.
@main
struct CevicheMCP {
    static func main() async {
        do {
            if CommandLine.arguments.contains("--schema") {
                FileHandle.standardOutput.write(try MCPSchema.data(MCPEditSchema.document, pretty: true))
                FileHandle.standardOutput.write(Data("\n".utf8)); return
            }
            if CommandLine.arguments.contains("--tools") {
                FileHandle.standardOutput.write(try MCPSchema.data(MCPTools.all.map(\.json), pretty: true)); return
            }
            let environment = ProcessInfo.processInfo.environment
            let port = Int(environment["CEVICHE_MCP_PORT"] ?? "18432") ?? 0
            guard (1024...65535).contains(port) else { throw MCPFailure("port", "Invalid CEVICHE_MCP_PORT.") }
            let configuration = URLSessionConfiguration.ephemeral
            // Longer than the app's 10-minute request limit, so the app's own limit applies first.
            configuration.timeoutIntervalForRequest = 660; configuration.timeoutIntervalForResource = 660
            configuration.connectionProxyDictionary = [:]
            let forwarder = Forwarder(session: URLSession(configuration: configuration), endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                // FileHandle.read(upToCount:) may fill its requested length on a pipe.
                // One POSIX read returns available bytes so a client can wait for our reply.
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 {
                    // Forward a final message that was not newline-terminated.
                    if !buffer.isEmpty { await forwarder.forward(buffer) }
                    break
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw MCPFailure("stdio", "Unable to read stdin.")
                }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    await forwarder.forward(line)
                }
                // An unterminated line past the limit is answered with the forwarder's size error and dropped.
                if buffer.count > MCPHTTPRequest.maximumBodyBytes { await forwarder.forward(buffer); buffer.removeAll() }
            }
        } catch {
            FileHandle.standardError.write(Data("ceviche-mcp: \(error.localizedDescription)\nOpen Ceviche and enable MCP in Settings.\n".utf8))
            exit(1)
        }
    }
}

/// Forwards one JSON-RPC line at a time. Failures become JSON-RPC errors for that request
/// instead of terminating the adapter, so the client survives an app restart or settings change.
struct Forwarder {
    let session: URLSession
    let endpoint: URL
    private final class State: @unchecked Sendable { var sessionID: String? }
    private let state = State()

    func forward(_ line: Data) async {
        guard line.count <= MCPHTTPRequest.maximumBodyBytes else { return reply(error: "MCP request exceeds 4 MiB.", to: line) }
        do {
            var (data, status) = try await post(line)
            if status == 404, state.sessionID != nil {
                // The app restarted or its session expired: start a fresh session and retry once.
                state.sessionID = nil
                (data, status) = try await post(line)
            }
            if status == 401 {
                return reply(error: "Ceviche refused the MCP token. Set CEVICHE_MCP_TOKEN, or run ceviche-mcp as the user running Ceviche.", to: line)
            }
            guard [200, 202].contains(status) else {
                return reply(error: "Ceviche rejected the request (HTTP \(status)). Check Settings → MCP.", to: line)
            }
            if !data.isEmpty { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
        } catch {
            reply(error: "Ceviche is not reachable: \(error.localizedDescription). Open Ceviche and allow AI clients in Settings.", to: line)
        }
    }
    private func post(_ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPTools.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let id = state.sessionID { request.setValue(id, forHTTPHeaderField: "MCP-Session-Id") }
        // Read on every request, so a regenerated token or a restarted app is picked up without restarting the client.
        if let token = ProcessInfo.processInfo.environment["CEVICHE_MCP_TOKEN"] ?? MCPToken.read() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if let id = http?.value(forHTTPHeaderField: "MCP-Session-Id") { state.sessionID = id }
        return (data, http?.statusCode ?? 0)
    }
    /// Notifications (no id) get no reply, per JSON-RPC.
    private func reply(error message: String, to line: Data) {
        FileHandle.standardError.write(Data("ceviche-mcp: \(message)\n".utf8))
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = request["id"],
              let data = try? MCPSchema.data(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]) else { return }
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
