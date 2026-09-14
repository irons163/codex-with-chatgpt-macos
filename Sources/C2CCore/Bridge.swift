import Foundation
import Darwin

public final class Bridge {
    public let workspace: Workspace
    public let auth: AuthService
    public let adminToken = secureToken(prefix: "c2c_admin_")
    private let stateDirectory: URL
    private let server = HTTPServer()
    private let startedAt = timestamp()
    private var workspaceLock: Int32 = -1
    private let lifecycle = NSLock()
    private var stopped = false
    public var onShutdown: (() -> Void)?
    public var port: Int { server.port }
    public init(workspaceRoot: String, stateDirectory: URL = AppPaths.stateDirectory) throws {
        self.workspace = try Workspace(root: workspaceRoot); self.stateDirectory = stateDirectory
        self.auth = try AuthService(workspaceID: workspace.id, workspaceName: workspace.name, stateDirectory: stateDirectory)
    }
    public func start(port: Int = 48765) throws {
        let directory = stateDirectory.appendingPathComponent("runtime")
        try AppPaths.ensureDirectory(directory)
        workspaceLock = Darwin.open(directory.appendingPathComponent("\(workspace.id).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard workspaceLock >= 0 else { throw C2CError("Cannot open workspace lock") }
        _ = fcntl(workspaceLock, F_SETFD, FD_CLOEXEC)
        guard flock(workspaceLock, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(workspaceLock); workspaceLock = -1; throw C2CError("A bridge is already starting or running for this workspace") }
        let mcp = MCPService(workspace: workspace, stateDirectory: stateDirectory)
        try server.start(port: port) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503) }
            return self.handle(request, mcp: mcp)
        }
        try persist()
    }
    private func persist() throws {
        try AppPaths.writeJSON(["service": c2cService, "version": c2cVersion, "workspaceId": workspace.id, "workspaceRoot": workspace.root, "pid": ProcessInfo.processInfo.processIdentifier, "port": port, "adminToken": adminToken, "startedAt": startedAt], to: stateDirectory.appendingPathComponent("runtime/\(workspace.id).json"))
    }
    private func handle(_ request: HTTPRequest, mcp: MCPService) -> HTTPResponse {
        let base = "http://127.0.0.1:\(port)"
        // Never derive OAuth issuer/redirects from attacker-controlled Host or forwarded headers.
        if request.path == "/health" && request.method == "GET" { return .json(["service": c2cService, "version": c2cVersion, "workspaceId": workspace.id, "status": "ok"]) }
        if request.path.hasPrefix("/admin/") {
            let proxied = ["cf-connecting-ip", "x-forwarded-for", "forwarded", "x-real-ip"].contains { request.headers[$0] != nil }
            guard request.remoteAddress == "127.0.0.1", !proxied, request.headers["authorization"] == "Bearer \(adminToken)" else { return HTTPResponse(status: 404) }
            switch (request.method, request.path) {
            case ("GET", "/admin/info"):
                return .json(["service": c2cService, "version": c2cVersion, "workspaceId": workspace.id, "workspaceName": workspace.name, "workspaceRoot": workspace.root, "port": port, "tokenCount": auth.tokenCount, "pairingActive": auth.pairingActive, "pid": ProcessInfo.processInfo.processIdentifier, "startedAt": startedAt])
            case ("POST", "/admin/pairing"): return .json(auth.createPairing())
            case ("POST", "/admin/revoke-all"):
                do { return .json(["revoked": try auth.revokeAll()]) }
                catch { return .json(["error": "persist_failed"], status: 500) }
            case ("POST", "/admin/shutdown"):
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.stop(); self.onShutdown?() }
                return .json(["shuttingDown": true])
            default: return HTTPResponse(status: 404)
            }
        }
        if let response = auth.handle(request, baseURL: base) { return response }
        if request.path == "/mcp" {
            if let response = auth.authorize(request, baseURL: base) { return response }
            guard let scopes = auth.scopes(for: request) else { return .json(["error": "unauthorized"], status: 401) }
            var headers = request.headers
            headers["x-c2c-scopes"] = scopes.joined(separator: " ")
            let authorized = HTTPRequest(method: request.method, path: request.path, query: request.query, headers: headers, body: request.body, remoteAddress: request.remoteAddress)
            return mcp.handle(authorized)
        }
        return HTTPResponse(status: 404)
    }
    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !stopped else { return }; stopped = true
        server.stop()
        if workspaceLock >= 0 {
            let file = stateDirectory.appendingPathComponent("runtime/\(workspace.id).json")
            if AppPaths.readJSON(file)?["adminToken"] as? String == adminToken { try? FileManager.default.removeItem(at: file) }
            flock(workspaceLock, LOCK_UN); Darwin.close(workspaceLock); workspaceLock = -1
        }
    }
    deinit { stop() }
}

public enum Daemon {
    public static func request(port: Int, route: String, method: String = "GET", token: String? = nil, timeout: TimeInterval = 5) async throws -> (Int, [String: Any]) {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { throw C2CError("Invalid bridge port") }
        var request = URLRequest(url: url, timeoutInterval: timeout); request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }
    public static func admin(_ runtime: [String: Any], route: String, method: String = "GET", timeout: TimeInterval = 70) async throws -> [String: Any] {
        guard let port = runtime["port"] as? Int, let token = runtime["adminToken"] as? String else { throw C2CError("Invalid runtime state") }
        let (status, body) = try await request(port: port, route: route, method: method, token: token, timeout: timeout)
        guard (200...299).contains(status) else { throw C2CError(body["message"] as? String ?? "Admin request failed (\(status))") }
        return body
    }
    public static func observation(workspaceID: String, stateDirectory: URL) async -> (state: String, runtime: [String: Any]?, reason: String) {
        let file = stateDirectory.appendingPathComponent("runtime/\(workspaceID).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return ("stopped", nil, "runtime_missing") }
        guard let runtime = AppPaths.readJSON(file), runtime["workspaceId"] as? String == workspaceID, let port = runtime["port"] as? Int, let pid = runtime["pid"] as? Int32, pid > 0 else { return ("unknown", nil, "invalid_runtime") }
        if let (status, health) = try? await request(port: port, route: "/health", timeout: 2), status == 200, health["service"] as? String == c2cService {
            guard health["workspaceId"] as? String == workspaceID else { return ("unknown", runtime, "workspace_mismatch") }
            // Authenticate the admin endpoint before reusing a listener or trusting stale PID state.
            if let info = try? await admin(runtime, route: "/admin/info", timeout: 2), info["workspaceId"] as? String == workspaceID { return ("healthy", runtime, "ok") }
            return ("unknown", runtime, "admin_verification_failed")
        }
        if kill(pid, 0) != 0 && errno == ESRCH { return ("stopped", runtime, "pid_missing") }
        return ("unknown", runtime, "probe_failed")
    }
    public static func ensure(workspace: Workspace, stateDirectory: URL, executable: String, port: Int = 48765) async throws -> [String: Any] {
        let observed = await observation(workspaceID: workspace.id, stateDirectory: stateDirectory)
        if observed.state == "healthy", let runtime = observed.runtime { return runtime }
        guard observed.state == "stopped" else { throw C2CError("Bridge state is uncertain (\(observed.reason)); refusing to start another bridge") }
        let logs = stateDirectory.appendingPathComponent("logs"); try AppPaths.ensureDirectory(logs)
        let file = logs.appendingPathComponent("bridge-\(workspace.id).out.log")
        let fd = Darwin.open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw C2CError("Cannot open bridge log") }
        fchmod(fd, 0o600)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["serve", "--workspace", workspace.root, "--port", String(port)]
        var environment = ProcessInfo.processInfo.environment; environment["C2C_STATE_DIR"] = stateDirectory.path; environment["C2C_DAEMON"] = "1"; child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = handle; child.standardError = handle
        try child.run()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 150_000_000)
            let observed = await observation(workspaceID: workspace.id, stateDirectory: stateDirectory)
            if observed.state == "healthy", let runtime = observed.runtime { return runtime }
            if !child.isRunning { throw C2CError("Bridge exited. See \(file.path)") }
        }
        if child.isRunning { child.terminate() }
        throw C2CError("Bridge did not become healthy within 20 seconds. See \(file.path)")
    }
    public static func stop(workspaceID: String, stateDirectory: URL) async throws -> Bool {
        let observed = await observation(workspaceID: workspaceID, stateDirectory: stateDirectory)
        if observed.state == "stopped" { return false }
        guard observed.state == "healthy", let runtime = observed.runtime else { throw C2CError("Cannot verify bridge identity; refusing to stop an unrelated process") }
        _ = try await admin(runtime, route: "/admin/shutdown", method: "POST", timeout: 5)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("runtime/\(workspaceID).json").path) { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw C2CError("Bridge shutdown has not completed")
    }
}
