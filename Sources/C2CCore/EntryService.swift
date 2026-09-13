import Foundation
import Darwin

/// Injects a workspace attachment panel into ChatGPT over CDP. Each click
/// rescans the selected directory and sets the current safe source files on
/// ChatGPT's file input. This is a refreshed attachment batch, not filesystem
/// tooling inside the model runtime.
public final class EntryService {
    /// Selects ChatGPT's general-purpose file input nearest to the rightmost
    /// visible composer. In the Codex desktop layout that is Quick Chat, while
    /// a standalone ChatGPT window simply has one visible composer.
    static let chatGPTFileInputExpression = """
    (() => {
      const visibleEditors = Array.from(document.querySelectorAll(
        '[contenteditable="true"][role="textbox"], textarea[role="textbox"]'
      )).filter(element => {
        const rect = element.getBoundingClientRect();
        return rect.width > 80 && rect.height > 10 && rect.bottom > 0 && rect.right > 0 &&
          rect.top < innerHeight && rect.left < innerWidth;
      }).sort((left, right) => {
        const a = left.getBoundingClientRect();
        const b = right.getBoundingClientRect();
        const horizontal = (b.left + b.width / 2) - (a.left + a.width / 2);
        return horizontal !== 0 ? horizontal : b.bottom - a.bottom;
      });
      if (!visibleEditors.length) return null;

      const inputs = Array.from(document.querySelectorAll('input[type="file"][multiple]'))
        .filter(input => !input.disabled && !input.hasAttribute('accept'));
      if (!inputs.length) return null;

      const editor = visibleEditors[0];
      function treeDistance(left, right) {
        const ancestors = new Map();
        let node = left, distance = 0;
        while (node) { ancestors.set(node, distance++); node = node.parentElement; }
        node = right; distance = 0;
        while (node) {
          if (ancestors.has(node)) return distance + ancestors.get(node);
          distance++; node = node.parentElement;
        }
        return Number.MAX_SAFE_INTEGER;
      }
      inputs.sort((left, right) => treeDistance(left, editor) - treeDistance(right, editor));
      return inputs[0];
    })()
    """

    public private(set) var workspace: Workspace
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
                log("Workspace reader injected into window \(target.id).")
            } catch {
                session.close()
                withLock { _ = sessions.removeValue(forKey: target.id) }
                log("Injection failed for window \(target.id): \(error.localizedDescription); retrying next poll.")
            }
        }
        for (id, session) in withLock({ Array(sessions) }) {
            guard session.isConnected else { continue }
            let present = ((try? await session.evaluateValue(EntryPanel.presenceScript, timeout: 5)) as? Bool)
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
        case "attach-workspace-files":
            Task { [weak self] in await self?.performAttachWorkspaceFiles(session: session) }
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

    struct AttachmentBatch {
        let files: [URL]
        let candidateCount: Int
        let truncated: Bool
    }

    func workspaceAttachmentBatch(maxFiles: Int = 40, maxFileBytes: Int = 1 * 1024 * 1024, maxTotalBytes: Int = 8 * 1024 * 1024) throws -> AttachmentBatch {
        guard maxFiles > 0, maxFileBytes > 0, maxTotalBytes > 0 else {
            throw C2CError("附件數量與容量上限必須大於零。")
        }
        let selected = withLock { workspace }
        let listing = try selected.listDirectory(".", depth: 4, limit: 1000)
        let entries = listing["entries"] as? [[String: Any]] ?? []
        let preferredNames = [
            "AGENTS.md", "README.md", "README", "Package.swift", "package.json",
            "Cargo.toml", "pyproject.toml", "Gemfile", "Podfile", "Makefile"
        ]
        let textExtensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "rs", "go", "py", "rb",
            "js", "jsx", "ts", "tsx", "java", "kt", "kts", "cs", "php", "sh",
            "zsh", "fish", "md", "txt", "json", "yaml", "yml", "toml", "xml",
            "html", "css", "scss", "sql", "graphql", "proto", "gradle", "plist",
            "strings", "pbxproj", "xcconfig"
        ]
        let candidates = entries.compactMap { entry -> (path: String, size: Int)? in
            guard entry["type"] as? String == "file",
                  let path = entry["path"] as? String,
                  let size = entry["sizeBytes"] as? Int,
                  size >= 0, size <= maxFileBytes else { return nil }
            let url = URL(fileURLWithPath: path)
            guard preferredNames.contains(url.lastPathComponent) || textExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return (path, size)
        }.sorted { lhs, rhs in
            let left = preferredNames.firstIndex(of: URL(fileURLWithPath: lhs.path).lastPathComponent) ?? preferredNames.count
            let right = preferredNames.firstIndex(of: URL(fileURLWithPath: rhs.path).lastPathComponent) ?? preferredNames.count
            return left == right ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending : left < right
        }

        var files: [URL] = []
        var totalBytes = 0
        var skippedForLimit = false
        for candidate in candidates {
            guard files.count < maxFiles,
                  candidate.size <= maxTotalBytes - totalBytes else {
                skippedForLimit = true
                continue
            }
            let resolved = try selected.resolve(candidate.path)
            let url = URL(fileURLWithPath: resolved.absolute)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url)
            totalBytes += candidate.size
        }
        return AttachmentBatch(
            files: files,
            candidateCount: candidates.count,
            truncated: skippedForLimit || listing["hasMore"] as? Bool == true
        )
    }

    private func performAttachWorkspaceFiles(session: CDPSession) async {
        do {
            let selected = withLock { workspace }
            let batch = try workspaceAttachmentBatch()
            guard !batch.files.isEmpty else { throw C2CError("工作目錄中沒有可附加的文字或程式碼檔案。") }
            try await attachToChatGPT(batch.files, session: session)
            log("Attached \(batch.files.count) current workspace file(s) to ChatGPT for \(selected.name).")
            await respond(session, [
                "ok": true,
                "action": "attach-workspace-files",
                "workspace": selected.name,
                "count": batch.files.count,
                "candidateCount": batch.candidateCount,
                "truncated": batch.truncated
            ])
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    private func attachToChatGPT(_ files: [URL], session: CDPSession) async throws {
        let evaluation = try await session.send("Runtime.evaluate", [
            "expression": Self.chatGPTFileInputExpression,
            "returnByValue": false,
            "awaitPromise": false
        ], timeout: 5)
        if let details = evaluation["exceptionDetails"] as? [String: Any] {
            throw C2CError((details["text"] as? String) ?? "無法尋找 ChatGPT 附件輸入。")
        }
        guard let remoteObject = evaluation["result"] as? [String: Any],
              let objectID = remoteObject["objectId"] as? String,
              remoteObject["subtype"] as? String != "null" else {
            throw C2CError("找不到 ChatGPT／Quick Chat 的附件輸入。請先開啟 Quick Chat，再按一次。")
        }
        defer {
            Task { _ = try? await session.send("Runtime.releaseObject", ["objectId": objectID], timeout: 3) }
        }
        _ = try await session.send("DOM.setFileInputFiles", [
            "files": files.map(\.path),
            "objectId": objectID
        ], timeout: 15)
        try await Task.sleep(nanoseconds: 500_000_000)
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
