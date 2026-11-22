import Foundation
import Network

public struct MCPHTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public static let maximumBodyBytes = 4 * 1024 * 1024

    /// One bounded HTTP request per connection. Chunked and ambiguous framing are rejected.
    public static func parse(_ data: Data) throws -> Self? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw MCPFailure("http", "Headers too large.") }; return nil
        }
        guard separator.lowerBound <= 16384, let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw MCPFailure("http", "Invalid headers.") }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2] == "HTTP/1.1" else { throw MCPFailure("http", "Expected HTTP/1.1.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw MCPFailure("http", "Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw MCPFailure("http", "Duplicate header.") }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw MCPFailure("http", "Transfer-Encoding is not supported; send Content-Length.") }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy(\.isNumber), let length = Int(lengthText), (0...maximumBodyBytes).contains(length) else { throw MCPFailure("http", "Invalid or excessive Content-Length.") }
        let end = separator.upperBound + length
        guard data.count >= end else { return nil }
        guard data.count == end else { throw MCPFailure("http", "Pipelining is not supported.") }
        return Self(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(data[separator.upperBound..<end]))
    }
    public func originStatus(port: Int) -> Int? {
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(headers["host"]?.lowercased() ?? "") else { return 403 }
        if let origin = headers["origin"], !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin) { return 403 }
        return nil
    }
}

public enum MCPListenerState: Equatable, Sendable {
    case ready
    case failed(String)
}

/// Streamable HTTP with JSON POST responses and optional sessions for scoped cancellation.
/// The listener is restricted to IPv4 loopback.
public final class MCPHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data, String) async -> Data?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "me.chichou.ceviche.mcp.http")
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var timers: [UUID: DispatchWorkItem] = [:]
    private var sessions: [String: Date] = [:]
    private let port: Int
    private let token: String
    private let handler: Handler
    /// Every request must carry `Authorization: Bearer <token>`.
    public init(port: Int, token: String, handler: @escaping Handler, status: @escaping @Sendable (MCPListenerState) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else { throw MCPFailure("port", "Port must be 1…65535.") }
        guard token.count >= 32 else { throw MCPFailure("token", "The MCP token is too short.") }
        self.port = port; self.token = token; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        // Connections close server-side, so restarting on the same port must not wait for TIME_WAIT.
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: status(.ready)
            case .failed(let error): status(.failed(error.localizedDescription))
            case .waiting(let error): status(.failed(error.localizedDescription))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }
    public func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            for task in requests.values { task.cancel() }
            for timer in timers.values { timer.cancel() }
            connections.removeAll(); requests.removeAll(); timers.removeAll(); sessions.removeAll()
        }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
        timers[id] = timeout; queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.start(queue: queue)
        receive(connection, id: id, data: Data())
    }
    private func finish(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        requests.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var data = data; if let chunk { data.append(chunk) }
            do {
                if let request = try MCPHTTPRequest.parse(data) { self.respond(request, connection: connection, id: id) }
                else if complete || error != nil { self.finish(id) }
                else { self.receive(connection, id: id, data: data) }
            } catch { self.send(400, body: Data(#"{"error":"Invalid HTTP request"}"#.utf8), connection: connection, id: id) }
        }
    }
    private func respond(_ request: MCPHTTPRequest, connection: NWConnection, id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        if let code = request.originStatus(port: port) { send(code, connection: connection, id: id); return }
        guard MCPToken.authorizes(request.headers["authorization"], token: token) else { send(401, connection: connection, id: id); return }
        guard request.path == "/mcp" else { send(404, connection: connection, id: id); return }
        guard request.method == "POST" else { send(405, connection: connection, id: id); return }
        guard request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else { send(415, connection: connection, id: id); return }
        if let version = request.headers["mcp-protocol-version"], !["2025-11-25", "2025-06-18", "2025-03-26"].contains(version) { send(400, connection: connection, id: id); return }
        sessions = sessions.filter { $0.value > Date() }
        let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let initializes = message?["method"] as? String == "initialize" && message?["id"] != nil
        let session: String
        if let existing = request.headers["mcp-session-id"] {
            guard sessions[existing] != nil else { send(404, connection: connection, id: id); return }
            session = existing
        } else {
            session = UUID().uuidString
        }
        if initializes || request.headers["mcp-session-id"] != nil {
            if sessions.count >= 128, let oldest = sessions.min(by: { $0.value < $1.value })?.key { sessions.removeValue(forKey: oldest) }
            sessions[session] = Date().addingTimeInterval(8 * 3600)
        }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
        timers[id] = timeout; queue.asyncAfter(deadline: .now() + 600, execute: timeout)
        watchForDisconnect(connection, id: id)
        requests[id] = Task { [weak self, handler] in
            let result = await handler(request.body, session)
            guard let self else { return }
            self.queue.async { [self] in
                guard self.connections[id] != nil else { return }
                self.send(result == nil ? 202 : 200, body: result ?? Data(), connection: connection, id: id, session: initializes ? session : nil)
            }
        }
    }
    /// A client that hangs up while a tool runs cancels that tool instead of leaving it running.
    private func watchForDisconnect(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if complete || error != nil { self.finish(id) }
        }
    }
    private func send(_ status: Int, body: Data = Data(), connection: NWConnection, id: UUID, session: String? = nil) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 415: "Unsupported Media Type"][status] ?? "Error"
        var extra = status == 405 ? "Allow: POST\r\n" : status == 401 ? "WWW-Authenticate: Bearer\r\n" : ""
        if let session { extra += "MCP-Session-Id: \(session)\r\n" }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\(extra)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }
}
