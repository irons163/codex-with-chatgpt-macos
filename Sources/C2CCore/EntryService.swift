import Foundation
import Darwin

/// Injects a local-workspace panel into the ChatGPT desktop app over CDP.
/// The panel hands a user-selected folder to the app's native local-project
/// handler, so subsequent Codex tasks use the live directory as their cwd.
public final class EntryService {
    public private(set) var workspace: Workspace
    private let appOverride: URL?
    private let preferredPort: Int?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var sessions: [String: CDPSession] = [:]
    private var resolvedApp: URL?
    private var pickerBusy = false
    private var stopped = false

    public init(workspace: Workspace, appOverride: URL? = nil, preferredPort: Int? = nil, log: @escaping (String) -> Void = { print($0) }) {
        self.workspace = workspace
        self.appOverride = appOverride
        self.preferredPort = preferredPort
        self.log = log
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public func stop() {
        withLock { stopped = true }
    }

    public func run() async throws {
        let app = try ChatGPTApp.locate(override: appOverride?.path)
        withLock { resolvedApp = app }
        log("Using app: \(app.path)")
        let port = try await ChatGPTApp.ensureDebugPort(app: app, preferred: preferredPort, log: log)
        let source = EntryPanel.installScript(workspaceName: workspace.name)
        do {
            while !withLock({ stopped }) && !Task.isCancelled {
                do { try await pollOnce(port: port, source: source) }
                catch { log("Entry poll failed: \(error.localizedDescription)") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        } catch is CancellationError {
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private func pollOnce(port: Int, source: String) async throws {
        let targets = try await CDPDebug.pageTargets(port: port)
        let ids = Set(targets.map(\.id))
        // Drop sessions whose target is gone or whose transport already closed; reconnect below.
        for (id, session) in withLock({ Array(sessions) }) where !ids.contains(id) || !session.isConnected {
            withLock { _ = sessions.removeValue(forKey: id) }
            session.close()
            log("Window \(id) went away; dropping its session.")
        }
        for target in targets {
            if withLock({ sessions[target.id] }) != nil { continue }
            guard let session = try? CDPSession.connect(target: target, port: port) else {
                log("Cannot connect to window \(target.id).")
                continue
            }
            session.onBindingCalled = { [weak self] session, name, payload in
                self?.handleBinding(session: session, name: name, payload: payload)
            }
            withLock { sessions[target.id] = session }
            do {
                try await session.send("Runtime.enable", timeout: 5)
                try await session.send("Page.enable", timeout: 5)
                try await session.addBinding(name: EntryPanel.bindingName)
                try await session.addScriptOnNewDocument(source)
                try await session.evaluate(source)
                log("Workspace reader injected into window \(target.id).")
            } catch {
                session.close()
                withLock { _ = sessions.removeValue(forKey: target.id) }
                log("Injection failed for window \(target.id): \(error.localizedDescription); retrying next poll.")
            }
        }
        for (id, session) in withLock({ Array(sessions) }) {
            guard session.isConnected else { continue }
            let present = ((try? await session.evaluateValue("window[\"\(EntryPanel.marker)\"] === true", timeout: 5)) as? Bool)
            if present != true {
                do {
                    try await session.evaluate(source)
                    log("Re-injected workspace reader into window \(id).")
                } catch {
                    session.close()
                    withLock { _ = sessions.removeValue(forKey: id) }
                    log("Re-inject failed for window \(id): \(error.localizedDescription); reconnecting next poll.")
                }
            }
        }
    }

    private func handleBinding(session: CDPSession, name: String, payload: [String: Any]) {
        guard name == EntryPanel.bindingName else { return }
        switch payload["action"] as? String {
        case "choose-workspace":
            Task { [weak self] in await self?.performChooseWorkspace(session: session) }
        case "open-workspace":
            Task { [weak self] in await self?.performOpenWorkspace(session: session) }
        default:
            Task { await respond(session, ["ok": false, "error": "Unknown action"]) }
        }
    }

    private func performChooseWorkspace(session: CDPSession) async {
        let wasBusy = withLock {
            let busy = pickerBusy
            if !busy { pickerBusy = true }
            return busy
        }
        guard !wasBusy else {
            await respond(session, ["ok": false, "error": "已經有目錄選擇視窗開啟中。"])
            return
        }
        defer { withLock { pickerBusy = false } }
        let script = "POSIX path of (choose folder with prompt \"選擇要讓 ChatGPT 讀取的工作目錄\")"
        guard let result = try? runCommand("/usr/bin/osascript", ["-e", script], timeout: 3600) else {
            await respond(session, ["ok": false, "error": "無法啟動目錄選擇視窗。"])
            return
        }
        if result.code != 0 {
            if result.output.range(of: "user canceled", options: [.regularExpression, .caseInsensitive]) != nil {
                await respond(session, ["ok": false, "cancelled": true])
            } else {
                await respond(session, ["ok": false, "error": "選擇工作目錄失敗。"])
            }
            return
        }
        do {
            let selected = try Workspace(root: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            withLock { workspace = selected }
            log("Selected workspace: \(selected.root)")
            await respond(session, ["ok": true, "action": "choose-workspace", "workspace": selected.name])
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    private func performOpenWorkspace(session: CDPSession) async {
        guard let app = withLock({ resolvedApp }) else {
            await respond(session, ["ok": false, "error": "找不到目前連線的 Codex App。"])
            return
        }
        do {
            let selected = withLock { workspace }
            try ChatGPTApp.openWorkspace(app: app, workspace: selected)
            log("Opened live local project for \(selected.name).")
            await respond(session, ["ok": true, "action": "open-workspace", "workspace": selected.name])
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    private func respond(_ session: CDPSession, _ payload: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8),
              let literalData = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
              let literal = String(data: literalData, encoding: .utf8) else { return }
        let name = EntryPanel.resultFunction
        _ = try? await session.evaluate("window[\"\(name)\"] && window[\"\(name)\"](\(literal))", timeout: 5)
    }

    private func cleanup() async {
        let snapshot = withLock { Array(sessions.values) }
        withLock { sessions.removeAll() }
        for session in snapshot {
            _ = try? await session.evaluate(EntryPanel.clearScript, timeout: 3)
            session.close()
        }
    }
}
