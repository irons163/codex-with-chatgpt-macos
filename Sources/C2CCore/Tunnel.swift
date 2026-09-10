import Foundation
import Darwin

public final class TunnelManager {
    private let stateDirectory: URL
    private let workspaceID: String
    private let lock = NSLock()
    private let operation = NSLock()
    private let binaryOverride: String?
    private let startTimeout: TimeInterval
    private var child: Process?
    private var pipe: Pipe?
    private var currentURL: String?
    private var lastError: String?
    private var provider = "cloudflare-quick"
    public init(workspaceID: String, stateDirectory: URL, binary: String? = nil, startTimeout: TimeInterval = 60) { self.workspaceID = workspaceID; self.stateDirectory = stateDirectory; self.binaryOverride = binary; self.startTimeout = startTimeout }
    public static func stateFile(_ id: String, _ dir: URL) -> URL { dir.appendingPathComponent("tunnels/\(id).json") }
    public static func state(_ id: String, _ dir: URL) -> [String: Any] { AppPaths.readJSON(stateFile(id, dir)) ?? ["workspaceId": id, "preference": "unset"] }
    public static var loggedIn: Bool {
        let cert = ProcessInfo.processInfo.environment["TUNNEL_ORIGIN_CERT"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared/cert.pem").path
        return FileManager.default.fileExists(atPath: cert)
    }
    public static func hostname(_ raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard value.range(of: "^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", options: .regularExpression) != nil else { throw C2CError("Invalid hostname") }
        return value
    }
    public static func zone(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("://"), let host = URL(string: value)?.host { return try hostname(host) }
        return try hostname(value)
    }
    public static func suggestedHostname(zone: String, name: String, id: String) throws -> String {
        let slug = name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return try hostname("c2c-\(slug.isEmpty ? "workspace" : String(slug.prefix(36)))-\(id.prefix(6)).\(zone)")
    }
    public static func login() throws {
        if loggedIn { return }
        guard let binary = findExecutable("cloudflared") else { throw C2CError("Install cloudflared: brew install cloudflared") }
        let result = try runCommand(binary, ["tunnel", "login"], timeout: 300)
        guard result.code == 0, loggedIn else { throw C2CError("Cloudflare login did not finish") }
    }
    public static func choose(mode: String, workspaceID: String, workspaceName: String, stateDirectory: URL, zone rawZone: String?, hostname rawHostname: String?) throws -> [String: Any] {
        guard ["quick", "named"].contains(mode) else { throw C2CError("mode must be quick or named") }
        var state: [String: Any] = ["workspaceId": workspaceID, "preference": mode, "askedAt": timestamp(), "provider": "cloudflare-\(mode)"]
        if mode == "named" {
            guard let rawZone else { throw C2CError("--zone is required for a named tunnel") }
            let zone = try zone(rawZone)
            let host = try rawHostname.map(hostname) ?? suggestedHostname(zone: zone, name: workspaceName, id: workspaceID)
            guard host.hasSuffix("." + zone) else { throw C2CError("Hostname must be under the selected zone") }
            try login()
            guard let binary = findExecutable("cloudflared") else { throw C2CError("Install cloudflared: brew install cloudflared") }
            let name = "c2c-\(workspaceID)"
            let list = try runCommand(binary, ["tunnel", "list", "--output", "json"])
            guard list.code == 0 else { throw C2CError("Cannot list Cloudflare tunnels") }
            var rows = (try? JSONSerialization.jsonObject(with: Data(list.output.utf8))) as? [[String: Any]] ?? []
            if !rows.contains(where: { $0["name"] as? String == name }) {
                let create = try runCommand(binary, ["tunnel", "create", name])
                guard create.code == 0 else { throw C2CError("Cannot create named tunnel: \(create.output.prefix(400))") }
                let refreshed = try runCommand(binary, ["tunnel", "list", "--output", "json"])
                rows = (try? JSONSerialization.jsonObject(with: Data(refreshed.output.utf8))) as? [[String: Any]] ?? []
            }
            guard let row = rows.first(where: { $0["name"] as? String == name }), let id = row["id"] as? String else { throw C2CError("Cannot confirm named tunnel identity") }
            let route = try runCommand(binary, ["tunnel", "route", "dns", name, host])
            guard route.code == 0 else { throw C2CError("Cannot route DNS: \(route.output.prefix(400))") }
            state["tunnelName"] = name; state["tunnelId"] = id; state["hostname"] = host; state["zone"] = zone; state["configuredAt"] = timestamp()
        }
        try AppPaths.writeJSON(state, to: stateFile(workspaceID, stateDirectory))
        return state
    }
    public var publicURL: String? { lock.lock(); defer { lock.unlock() }; return child?.isRunning == true ? currentURL : nil }
    public func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let running = child?.isRunning == true && currentURL != nil
        return ["running": running, "url": running ? (currentURL as Any? ?? NSNull()) : NSNull(), "provider": provider, "detail": lastError as Any? ?? NSNull()]
    }
    public func start(port: Int) throws -> String {
        operation.lock(); defer { operation.unlock() }
        if let url = publicURL { return url }
        stopProcess()
        guard let binary = binaryOverride ?? findExecutable("cloudflared") else { throw C2CError("NEED_CLOUDFLARED: brew install cloudflared") }
        let settings = Self.state(workspaceID, stateDirectory)
        let named = settings["preference"] as? String == "named"
        let host = named ? try Self.hostname(settings["hostname"] as? String ?? "") : nil
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        if named {
            guard let name = settings["tunnelName"] as? String, name.hasPrefix("c2c-"), name.count <= 128 else { throw C2CError("Invalid named tunnel configuration") }
            arguments += ["run", name]
        } else { arguments += ["--protocol", "http2"] }
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        lock.lock(); self.child = process; self.pipe = pipe; provider = named ? "cloudflare-named" : "cloudflare-quick"; currentURL = nil; lastError = nil; lock.unlock()
        var text = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            text += String(decoding: data, as: UTF8.self)
            if let host, text.localizedCaseInsensitiveContains("registered tunnel connection") { self.currentURL = "https://\(host)" }
            if !named, let range = text.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com", options: .regularExpression) { self.currentURL = String(text[range]) }
            if let errorLine = text.components(separatedBy: .newlines).last(where: { $0.range(of: "\\b(error|failed|fatal)\\b", options: [.regularExpression, .caseInsensitive]) != nil }) {
                self.lastError = String(errorLine.prefix(400))
            }
            if text.count > 16384 { text = String(text.suffix(8192)) }
        }
        do { try process.run() } catch { stopProcess(); throw error }
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline && process.isRunning {
            if let url = publicURL { return url }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let reason = process.isRunning ? "Tunnel did not establish a connection within \(Int(startTimeout)) seconds" : "cloudflared exited with status \(process.terminationStatus)"
        stopProcess()
        lock.lock(); lastError = reason; lock.unlock()
        throw C2CError(reason)
    }
    private func stopProcess() {
        lock.lock(); let process = child; let pipe = self.pipe; child = nil; self.pipe = nil; currentURL = nil; lock.unlock()
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
    public func stop() { operation.lock(); defer { operation.unlock() }; stopProcess() }
    deinit { stopProcess() }
}
