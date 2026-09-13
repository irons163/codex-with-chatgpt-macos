import Foundation
import Darwin

public struct CDPTarget: Equatable {
    public let id: String
    public let url: String
    public let webSocketURL: URL
    public init(id: String, url: String, webSocketURL: URL) {
        self.id = id; self.url = url; self.webSocketURL = webSocketURL
    }
}

public enum CDPDebug {
    public static let portCandidates: [Int] = Array(57330...57341)

    static func fetchJSON(port: Int, path: String, timeout: TimeInterval) async throws -> Any {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw C2CError("Invalid debug port") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let (data, _) = try await client.data(for: request)
        return try JSONSerialization.jsonObject(with: data)
    }

    public static func parseTargets(_ value: Any) -> [CDPTarget] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard (entry["type"] as? String) == "page",
                  let id = entry["id"] as? String,
                  let url = entry["url"] as? String,
                  let socketRaw = (entry["webSocketDebuggerUrl"] as? String) ?? (entry["web_socket_debugger_url"] as? String),
                  let socket = URL(string: socketRaw) else { return nil }
            return CDPTarget(id: id, url: url, webSocketURL: socket)
        }
    }

    /// Only the main renderer. Quick Chat's visible UI is mounted here too; its
    /// separate `quick-chat-prewarm` target is an empty utility renderer.
    public static func isAppPageURL(_ url: String) -> Bool {
        url == "app://-/index.html"
    }

    public static func pageTargets(port: Int, timeout: TimeInterval = 2) async throws -> [CDPTarget] {
        parseTargets(try await fetchJSON(port: port, path: "/json", timeout: timeout)).filter { isAppPageURL($0.url) }
    }

    public static func hasAppTarget(port: Int) async -> Bool {
        guard (try? await fetchJSON(port: port, path: "/json/version", timeout: 0.5)) != nil else { return false }
        return ((try? await pageTargets(port: port, timeout: 1))?.isEmpty == false)
    }

    public static func existingDebugPort(preferred: Int? = nil) async -> Int? {
        var ports: [Int] = []
        if let preferred, (1...65535).contains(preferred) { ports.append(preferred) }
        ports.append(contentsOf: portCandidates.filter { $0 != preferred })
        for port in ports where await hasAppTarget(port: port) { return port }
        return nil
    }

    public static func portIsAvailable(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    public static func firstAvailablePort(from start: Int) -> Int? {
        for port in start..<(start + 200) where (1...65535).contains(port) && portIsAvailable(port) { return port }
        return nil
    }
}

final class CDPPendingCall: @unchecked Sendable {
    private let continuation: CheckedContinuation<[String: Any], Error>
    private let lock = NSLock()
    private var resumed = false
    init(_ continuation: CheckedContinuation<[String: Any], Error>) { self.continuation = continuation }
    func finish(_ result: Result<[String: Any], Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }; resumed = true
        continuation.resume(with: result)
    }
}

/// One DevTools websocket session bound to a single renderer page target.
public final class CDPSession: @unchecked Sendable {
    public typealias BindingHandler = (CDPSession, String, [String: Any]) -> Void
    public let target: CDPTarget
    public var isConnected: Bool { !withLock({ closed }) }
    public var onBindingCalled: BindingHandler?
    public var onClosed: (() -> Void)?
    private let client: URLSession
    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "c2c.cdp.session")
    private let lock = NSLock()
    private var pending: [Int: CDPPendingCall] = [:]
    private var nextID = 1
    private var closed = false

    private init(target: CDPTarget, client: URLSession, task: URLSessionWebSocketTask) {
        self.target = target; self.client = client; self.task = task
    }

    public static func connect(target: CDPTarget, port: Int, timeout: TimeInterval = 5) throws -> CDPSession {
        var request = URLRequest(url: target.webSocketURL, timeoutInterval: 30)
        // Chromium only accepts websockets whose Origin is allowed on the command line.
        request.setValue("http://127.0.0.1:\(port)", forHTTPHeaderField: "Origin")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        final class SocketDelegate: NSObject, URLSessionWebSocketDelegate {
            private(set) var opened = false
            private(set) var failure: Error?
            var onOpen: (() -> Void)?
            var onError: (() -> Void)?
            func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
                opened = true
                onOpen?()
            }
            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                guard !opened else { return }
                failure = error ?? C2CError("Connection closed before opening")
                onError?()
            }
        }
        let socketDelegate = SocketDelegate()
        let opened = DispatchSemaphore(value: 0)
        let client = URLSession(configuration: configuration, delegate: socketDelegate, delegateQueue: nil)
        let task = client.webSocketTask(with: request)
        socketDelegate.onOpen = { opened.signal() }
        socketDelegate.onError = { opened.signal() }
        task.resume()
        guard opened.wait(timeout: .now() + timeout) == .success, socketDelegate.opened else {
            task.cancel(with: .goingAway, reason: nil)
            client.finishTasksAndInvalidate()
            throw socketDelegate.failure ?? C2CError("Timed out connecting to the app renderer")
        }
        let instance = CDPSession(target: target, client: client, task: task)
        socketDelegate.onOpen = nil
        socketDelegate.onError = { [weak instance] in instance?.transportClosed() }
        instance.receiveNext()
        return instance
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                if !self.withLock({ self.closed }) { self.receiveNext() }
            case .failure:
                self.transportClosed()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            let call = withLock { pending.removeValue(forKey: id) }
            guard let call else { return }
            if let result = object["result"] as? [String: Any] {
                call.finish(.success(result))
            } else {
                let detail = object["error"] as? [String: Any]
                call.finish(.failure(C2CError((detail?["message"] as? String) ?? "CDP command failed")))
            }
        } else if let method = object["method"] as? String, method == "Runtime.bindingCalled" {
            guard let params = object["params"] as? [String: Any] else { return }
            let name = params["name"] as? String ?? ""
            var payload: [String: Any] = [:]
            if let raw = params["payload"] as? String {
                payload = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            } else if let object = params["payload"] as? [String: Any] {
                payload = object
            }
            onBindingCalled?(self, name, payload)
        }
    }

    private func transportClosed() {
        let calls: [CDPPendingCall] = withLock {
            let all = Array(pending.values)
            pending.removeAll()
            if !closed { closed = true }
            return all
        }
        calls.forEach { $0.finish(.failure(C2CError("CDP websocket closed"))) }
        onClosed?()
    }

    @discardableResult
    public func send(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard !withLock({ closed }) else { throw C2CError("CDP websocket is closed") }
        let id: Int = withLock { let current = nextID; nextID += 1; return current }
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        // CDP over Chromium only accepts TEXT frames; binary frames make it
        // close the connection immediately (verified against Chrome 152).
        let text = String(decoding: payload, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            let call = CDPPendingCall(continuation)
            withLock { pending[id] = call }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let expired = self.withLock { self.pending.removeValue(forKey: id) }
                expired?.finish(.failure(C2CError("CDP \(method) timed out")))
            }
            task.send(.string(text)) { [weak self] error in
                guard let self, let error else { return }
                let failed = self.withLock { self.pending.removeValue(forKey: id) }
                failed?.finish(.failure(error))
            }
        }
    }

    @discardableResult
    public func evaluate(_ expression: String, timeout: TimeInterval = 10) async throws -> [String: Any] {
        try await send("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": false], timeout: timeout)
    }

    @discardableResult
    public func evaluateValue(_ expression: String, timeout: TimeInterval = 10) async throws -> Any? {
        let result = try await evaluate(expression, timeout: timeout)
        if let details = result["exceptionDetails"] as? [String: Any] {
            throw C2CError((details["text"] as? String) ?? "Evaluation failed")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    public func addBinding(name: String) async throws {
        try await send("Runtime.addBinding", ["name": name])
    }

    public func addScriptOnNewDocument(_ source: String) async throws {
        try await send("Page.addScriptToEvaluateOnNewDocument", ["source": source])
    }

    public func close() {
        let wasClosed = withLock { let previous = closed; closed = true; return previous }
        guard !wasClosed else { return }
        task.cancel(with: .normalClosure, reason: nil)
        client.finishTasksAndInvalidate()
        let calls = withLock { let all = Array(pending.values); pending.removeAll(); return all }
        calls.forEach { $0.finish(.failure(C2CError("CDP session closed"))) }
    }
}

public enum ChatGPTApp {
    public static func locate(override: String?) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        if let override {
            candidates = [URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL]
        } else {
            candidates = [
                URL(fileURLWithPath: "/Applications/Codex.app"),
                URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                home.appendingPathComponent("Applications/Codex.app"),
                home.appendingPathComponent("Applications/ChatGPT.app")
            ]
        }
        for app in candidates where isViable(app) { return app }
        throw C2CError(override == nil
            ? "Cannot find the Codex or ChatGPT desktop app under /Applications. Use --app to point at the bundle."
            : "The app at \(override ?? "") is not a Codex/ChatGPT (com.openai.*) desktop bundle")
    }

    public static func readBundleValue(app: URL, key: String) -> String? {
        guard let result = try? runCommand("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", app.appendingPathComponent("Contents/Info.plist").path], timeout: 5), result.code == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isViable(_ app: URL) -> Bool {
        // Only accept the OpenAI desktop family; never point CDP flags at an unrelated bundle.
        guard let bundleID = readBundleValue(app: app, key: "CFBundleIdentifier"), bundleID.hasPrefix("com.openai.") else { return false }
        let executableName = readBundleValue(app: app, key: "CFBundleExecutable") ?? "Codex"
        for name in [executableName, "Codex", "ChatGPT"] {
            if FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(name)").path) { return true }
        }
        return false
    }

    static func mainProcessIDs(app: URL) -> [Int32] {
        guard let result = try? runCommand("/bin/ps", ["-axo", "pid=,command="], timeout: 10) else { return [] }
        let prefix = app.standardizedFileURL.path + "/Contents/MacOS/"
        return result.output.split(separator: "\n").compactMap { line -> Int32? in
            guard let separator = line.firstIndex(where: { !$0.isNumber && !$0.isWhitespace }) else { return nil }
            let pid = line[..<separator].trimmingCharacters(in: .whitespaces)
            let command = line[separator...].trimmingCharacters(in: .whitespaces)
            guard let value = Int32(pid), value > 0, command.hasPrefix(prefix) else { return nil }
            return value
        }
    }

    public static func isRunning(app: URL) -> Bool { !mainProcessIDs(app: app).isEmpty }

    static func waitForExit(app: URL, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isRunning(app: app) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !isRunning(app: app)
    }

    public static func quit(app: URL) async {
        if let bundleID = readBundleValue(app: app, key: "CFBundleIdentifier"), !bundleID.isEmpty {
            _ = try? runCommand("/usr/bin/osascript", ["-e", "tell application id \"\(bundleID)\" to quit"], timeout: 20)
        }
        if await waitForExit(app: app, seconds: 15) { return }
        for pid in mainProcessIDs(app: app) { kill(pid, SIGTERM) }
        if await waitForExit(app: app, seconds: 5) { return }
        for pid in mainProcessIDs(app: app) { kill(pid, SIGKILL) }
        _ = await waitForExit(app: app, seconds: 3)
    }

    public static func launch(app: URL, debugPort: Int) throws {
        let arguments = [
            "--args",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(debugPort)",
            "--remote-allow-origins=http://127.0.0.1:\(debugPort)"
        ]
        let result = try runCommand("/usr/bin/open", [app.path] + arguments, timeout: 20)
        guard result.code == 0 else { throw C2CError("Cannot launch \(app.lastPathComponent): \(result.output)") }
    }

    /// Returns a debug port that already serves app page targets, or relaunches the app with one.
    public static func ensureDebugPort(app: URL, preferred: Int?, log: (String) -> Void) async throws -> Int {
        if let existing = await CDPDebug.existingDebugPort(preferred: preferred) {
            log("Reusing app debug port \(existing).")
            return existing
        }
        if isRunning(app: app) {
            log("The app is running without a debug port; restarting it to enable CDP injection.")
            await quit(app: app)
        }
        guard let port = preferred ?? CDPDebug.firstAvailablePort(from: CDPDebug.portCandidates.first ?? 57330) else {
            throw C2CError("No free local debug port found")
        }
        try launch(app: app, debugPort: port)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await CDPDebug.hasAppTarget(port: port) {
                log("Launched \(app.lastPathComponent) with debug port \(port).")
                return port
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw C2CError("The app did not expose a debug target on port \(port) within 30 seconds")
    }
}
