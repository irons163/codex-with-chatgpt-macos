import Foundation
import Darwin

/// Injects the upload entry panel into the ChatGPT desktop app over CDP and
/// serves its actions. The renderer can only signal "the user clicked"; the
/// native side owns every file choice (osascript picker) and every write.
public final class EntryService {
    public let workspace: Workspace
    private let appOverride: URL?
    private let preferredPort: Int?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var sessions: [String: CDPSession] = [:]
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
                log("Upload entry injected into window \(target.id).")
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
                    log("Re-injected upload entry into window \(id).")
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
        guard (payload["action"] as? String) == "upload" else {
            Task { await respond(session, ["ok": false, "error": "Unknown action"]) }
            return
        }
        Task { [weak self] in await self?.performUpload(session: session) }
    }

    private enum PickOutcome {
        case cancelled
        case failed(String)
        case picked([String])
    }

    private func pickFiles() -> PickOutcome {
        let script = """
        set chosen to choose file with multiple selections allowed
        set output to ""
        repeat with anItem in chosen
          set output to output & (POSIX path of anItem) & linefeed
        end repeat
        return output
        """
        guard let result = try? runCommand("/usr/bin/osascript", ["-e", script], timeout: 3600) else {
            return .failed("無法啟動檔案選擇視窗。")
        }
        if result.code == 0 {
            let paths = result.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return paths.isEmpty ? .cancelled : .picked(paths)
        }
        if result.output.range(of: "user canceled", options: [.regularExpression, .caseInsensitive]) != nil { return .cancelled }
        return .failed("檔案選擇失敗：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private func performUpload(session: CDPSession) async {
        let wasBusy = withLock {
            let busy = pickerBusy
            if !busy { pickerBusy = true }
            return busy
        }
        guard !wasBusy else {
            await respond(session, ["ok": false, "error": "已經有檔案選擇視窗開啟中。"])
            return
        }
        defer { withLock { pickerBusy = false } }
        switch pickFiles() {
        case .cancelled:
            await respond(session, ["ok": false, "cancelled": true])
        case .failed(let message):
            await respond(session, ["ok": false, "error": message])
        case .picked(let paths):
            do {
                let files = try copyIntoWorkspace(paths: paths)
                log("Uploaded \(files.count) file(s) into \(workspace.name)/uploads.")
                await respond(session, ["ok": true, "count": files.count, "files": files, "workspace": workspace.name])
            } catch {
                await respond(session, ["ok": false, "error": error.localizedDescription])
            }
        }
    }

    public static func sanitizeFileName(_ raw: String) -> String {
        let name = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
        let clean = name.replacingOccurrences(of: "\0", with: "")
        return clean.isEmpty ? "untitled" : clean
    }

    func copyIntoWorkspace(paths: [String]) throws -> [String] {
        let uploadsURL = URL(fileURLWithPath: workspace.root).appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: uploadsURL, withIntermediateDirectories: true)
        let canonical = uploadsURL.resolvingSymlinksInPath().path
        guard canonical == workspace.root || canonical.hasPrefix(workspace.root + "/") else {
            throw C2CError("uploads 目錄解析到工作區之外，已拒絕寫入。")
        }
        var uploaded: [String] = []
        for path in paths {
            let source = URL(fileURLWithPath: path)
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, values.isRegularFile == true else {
                throw C2CError("\(source.lastPathComponent) 不是一般檔案；資料夾與符號連結不支援。")
            }
            let destination = uniqueDestination(uploadsURL: uploadsURL, fileName: Self.sanitizeFileName(source.lastPathComponent))
            try FileManager.default.copyItem(at: source, to: destination)
            uploaded.append("uploads/" + destination.lastPathComponent)
        }
        return uploaded
    }

    private func uniqueDestination(uploadsURL: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = uploadsURL.appendingPathComponent(fileName)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) && index < 1000 {
            candidate = uploadsURL.appendingPathComponent(ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
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
