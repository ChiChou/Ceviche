import Foundation
import SwiftUI
import CevicheCore

struct MCPActivity: Equatable {
    let tool: String
    let writes: Bool
    var title: String {
        switch tool {
        case "catalog_query", "catalog_context", "catalog_inspect", "catalog_thumbnails": L10n.tr("Reading library")
        case "catalog_import": L10n.tr("Importing photos")
        case "catalog_update": L10n.tr("Updating metadata")
        case "catalog_trash": L10n.tr("Moving photos to Trash")
        case "catalog_restore": L10n.tr("Restoring photos")
        case "photo_read", "photo_preview": L10n.tr("Rendering a preview")
        case "photo_apply": L10n.tr("Applying edits")
        case "photo_export": L10n.tr("Exporting")
        default: L10n.tr("Working")
        }
    }
}

/// A tool call started with `background: true`, followed with job_status and job_cancel.
struct MCPJob {
    let tool: String
    let started: Date
    let task: Task<[String: Any], Error>
    var finished: Date?
    var result: [String: Any]?
}

enum MCPServerState: Equatable {
    case off, starting, listening
    case failed(String)
}

@MainActor
final class MCPController: ObservableObject {
    @Published var enabled: Bool
    @Published var port: Int
    @Published var readOnly: Bool
    @Published var previewMaxEdge: Int
    @Published private(set) var serverState: MCPServerState = .off
    /// Validation problem with the values typed in Settings; the running server keeps its previous settings.
    @Published private(set) var settingsError: String?
    var endpoint: String { "http://127.0.0.1:\(activePort)/mcp" }
    /// Clients send it as `Authorization: Bearer …`; `ceviche-mcp` reads it from `tokenURL`.
    @Published private(set) var token: String?
    let tokenURL: URL
    private(set) var activePort = 18432
    @Published var isWorking = false
    /// The tool currently running, shown in the main window with a Cancel button.
    @Published var activity: MCPActivity?
    let preferences: UserDefaults
    weak var editor: EditorModel?
    weak var catalog: CatalogModel?
    var activeReadOnly = false
    var activePreviewMaxEdge = 1600
    var server: MCPHTTPServer?
    var serverGeneration = UUID()
    var queryPages: [String: (catalog: String, signature: Data, items: [[String: Any]], offset: Int, expires: Date)] = [:]
    var activeTasks: [String: Task<[String: Any], Error>] = [:]
    var jobs: [String: MCPJob] = [:]
    init(preferences: UserDefaults = .standard, tokenURL: URL = MCPToken.defaultURL) {
        self.preferences = preferences
        self.tokenURL = tokenURL
        enabled = preferences.bool(forKey: "mcp.enabled")
        port = preferences.object(forKey: "mcp.port") as? Int ?? 18432
        readOnly = preferences.bool(forKey: "mcp.readOnly")
        previewMaxEdge = preferences.object(forKey: "mcp.previewMaxEdge") as? Int ?? 1600
    }
    func attach(editor: EditorModel, catalog: CatalogModel) {
        guard self.editor == nil else { return }
        self.editor = editor; self.catalog = catalog
        if enabled { applyPreferences() }
    }
    func cancelActivity() {
        for task in activeTasks.values { task.cancel() }
        for job in jobs.values where job.finished == nil { job.task.cancel() }
    }
    func stop() {
        serverGeneration = UUID(); server?.stop(); server = nil
        for task in activeTasks.values { task.cancel() }
        for job in jobs.values where job.finished == nil { job.task.cancel() }
        serverState = .off
    }
    /// Turning MCP on or off takes effect immediately, like any macOS switch.
    func setEnabled(_ value: Bool) {
        enabled = value
        if value { applyPreferences() } else { stop(); preferences.set(false, forKey: "mcp.enabled") }
    }
    /// Access level and preview size apply to the next request without restarting the listener.
    func commitReadOnly() { activeReadOnly = readOnly; preferences.set(readOnly, forKey: "mcp.readOnly") }
    func commitPreviewMaxEdge() {
        guard (64...4096).contains(previewMaxEdge) else { settingsError = L10n.tr("Preview size must be 64–4096 pixels."); return }
        settingsError = nil; activePreviewMaxEdge = previewMaxEdge; preferences.set(previewMaxEdge, forKey: "mcp.previewMaxEdge")
    }
    func commitPort() {
        guard port != activePort || server == nil else { settingsError = nil; return }
        applyPreferences()
    }
    /// Validates everything before touching the running server, so a typo never silently
    /// leaves an old listener running with settings the UI no longer shows.
    func applyPreferences() {
        guard enabled else { stop(); preferences.set(false, forKey: "mcp.enabled"); return }
        guard (1024...65535).contains(port) else { settingsError = L10n.tr("Choose a port from 1024 to 65535."); return }
        guard (64...4096).contains(previewMaxEdge) else { settingsError = L10n.tr("Preview size must be 64–4096 pixels."); return }
        settingsError = nil
        stop()
        preferences.set(true, forKey: "mcp.enabled"); preferences.set(port, forKey: "mcp.port")
        preferences.set(readOnly, forKey: "mcp.readOnly"); preferences.set(previewMaxEdge, forKey: "mcp.previewMaxEdge")
        activeReadOnly = readOnly; activePreviewMaxEdge = previewMaxEdge; activePort = port
        let generation = serverGeneration
        serverState = .starting
        do {
            let token = try MCPToken.loadOrCreate(at: tokenURL)
            self.token = token
            server = try MCPHTTPServer(port: port, token: token, handler: { [weak self] data, session in
                await self?.handle(data, session: session)
            }, status: { [weak self] state in
                Task { @MainActor in
                    guard let self, self.serverGeneration == generation else { return }
                    switch state {
                    case .ready: self.serverState = .listening
                    case .failed(let message): self.serverState = .failed(message)
                    }
                }
            })
        } catch { serverState = .failed(error.localizedDescription) }
    }
    /// A new token disconnects every client until it is given the new one; the listener restarts with it.
    func regenerateToken() {
        do { token = try MCPToken.regenerate(at: tokenURL) } catch { settingsError = error.localizedDescription; return }
        if server != nil { applyPreferences() }
    }
    /// Shared by HTTP and tests. Requests never dispatch arbitrary Swift selectors.
    func handle(_ data: Data, session: String = "test") async -> Data? {
        func rpcError(_ id: Any, _ code: Int, _ message: String) -> Data? {
            try? MCPSchema.data(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return rpcError(NSNull(), -32700, "Parse error") }
        if let response = value as? [String: Any], response["jsonrpc"] as? String == "2.0", response["method"] == nil,
           response["id"] != nil, response["result"] != nil || response["error"] != nil { return nil }
        guard let request = value as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return rpcError(NSNull(), -32600, "Invalid request") }
        let params = request["params"] as? [String: Any] ?? [:]
        guard let id = request["id"] else {
            if method == "notifications/cancelled", let requestID = params["requestId"], let key = try? MCPSchema.data(requestID) {
                activeTasks[session + ":" + String(decoding: key, as: UTF8.self)]?.cancel()
            }
            return nil
        }
        guard id is String || (id is NSNumber && (try? MCPSchema.validate(id, against: ["type": "integer"])) != nil) else { return rpcError(NSNull(), -32600, "Invalid request id") }
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = ["2025-11-25", "2025-06-18", "2025-03-26"].contains(requested) ? requested : MCPTools.protocolVersion
            result = ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "Ceviche", "version": "1.0"],
                      "instructions": "Call catalog_query to find photos in the open catalog, or catalog_context for the photos the user has selected. To review or tag many photos, look at them with catalog_thumbnails and write ratings, review, labels, keywords or locations back with catalog_update. To edit one, call photo_read to see an image and its numeric state. Apply sparse JSON edits with expectedRevision and schemaVersion 1. d.json is available through photo_docs and the bundled ceviche-mcp --schema. Filesystem deletion is not exposed."]
        case "ping": result = [:]
        case "tools/list": result = ["tools": MCPTools.listed(readOnly: activeReadOnly).map(\.json)]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPTools.all.first(where: { $0.name == name }) else { return rpcError(id, -32602, "Unknown tool") }
            let key = session + ":" + String(decoding: (try? MCPSchema.data(id)) ?? Data(), as: UTF8.self)
            guard activeTasks[key] == nil else { return rpcError(id, -32600, "Request id already in use") }
            if tool.background, (params["arguments"] as? [String: Any])?["background"] as? Bool == true {
                do {
                    let arguments = params["arguments"] ?? [String: Any]()
                    try MCPSchema.validate(arguments, against: tool.input)
                    guard var arguments = arguments as? [String: Any] else { throw MCPFailure("invalid_value", "Arguments must be an object.") }
                    try checkAccess(tool, arguments)
                    arguments.removeValue(forKey: "background")
                    result = try MCPTools.result(startJob(tool.name, arguments))
                } catch { result = MCPTools.failure(error) }
                return try? MCPSchema.data(["jsonrpc": "2.0", "id": id, "result": result])
            }
            let task = Task { @MainActor [self] in
                let arguments = params["arguments"] ?? [String: Any]()
                try MCPSchema.validate(arguments, against: tool.input)
                guard let arguments = arguments as? [String: Any] else { throw MCPFailure("invalid_value", "Arguments must be an object.") }
                try checkAccess(tool, arguments)
                return try await call(tool.name, arguments)
            }
            activeTasks[key] = task
            // Cancelling the HTTP request (timeout or client disconnect) must stop the tool too.
            do { result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
            catch { result = MCPTools.failure(error) }
            activeTasks.removeValue(forKey: key)
        default: return rpcError(id, -32601, "Method not found")
        }
        return try? MCPSchema.data(["jsonrpc": "2.0", "id": id, "result": result])
    }
}

extension MCPController {
    /// Read-only access allows tools that only read, and writing tools only as a dry run.
    func checkAccess(_ tool: MCPTool, _ arguments: [String: Any]) throws {
        guard tool.writes, activeReadOnly, !(tool.proposes && arguments["dryRun"] as? Bool == true) else { return }
        throw MCPFailure("read_only", tool.proposes ? "MCP is configured for read-only access; pass dryRun: true to see what this would change." : "MCP is configured for read-only access.")
    }
    /// Runs the tool apart from the HTTP request, so it outlives the 10-minute request limit and a client that hangs up.
    func startJob(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let expiry = Date().addingTimeInterval(-3600)
        jobs = jobs.filter { $0.value.finished.map { $0 > expiry } ?? true }
        let id = UUID().uuidString
        let task = Task { @MainActor [self] in try await call(name, arguments) }
        jobs[id] = MCPJob(tool: name, started: Date(), task: task)
        Task { @MainActor [weak self] in
            let outcome: [String: Any]
            do { outcome = try await task.value } catch { outcome = MCPTools.failure(error) }
            self?.jobs[id]?.finished = Date(); self?.jobs[id]?.result = outcome
        }
        return ["jobId": id, "tool": name, "status": "running"]
    }
    func job(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let id = args["jobId"] as! String
        guard let job = jobs[id] else { throw MCPFailure("unknown_job", "No such job; finished jobs are kept for an hour.") }
        if name == "job_cancel", job.finished == nil { job.task.cancel() }
        let formatter = ISO8601DateFormatter()
        var status: [String: Any] = ["jobId": id, "tool": job.tool, "startedAt": formatter.string(from: job.started)]
        guard let result = job.result, let finished = job.finished else {
            status["status"] = job.task.isCancelled ? "cancelling" : "running"
            return status
        }
        status["finishedAt"] = formatter.string(from: finished)
        let content = result["structuredContent"] as? [String: Any] ?? [:]
        if result["isError"] as? Bool == true {
            let error = content["error"] as? [String: Any]
            status["status"] = error?["code"] as? String == "cancelled" ? "cancelled" : "failed"
            status["error"] = error ?? [:]
        } else {
            status["status"] = content["cancelled"] as? Bool == true ? "cancelled" : "done"
            status["result"] = content
        }
        return status
    }
}

/// Explains why the window is briefly read-only while an AI client works, and offers a way out.
struct MCPActivityBanner: View {
    let activity: MCPActivity
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("AI client - \(activity.title)…")).font(.callout.weight(.medium))
                if activity.writes { Text(L10n.tr("Editing is paused until it finishes.")).font(.caption).foregroundStyle(.secondary) }
            }
            Button(L10n.tr("Cancel"), action: cancel).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .padding(.bottom, 44)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}
