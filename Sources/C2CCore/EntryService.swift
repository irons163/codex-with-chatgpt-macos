import Foundation
import Darwin

/// Injects a workspace attachment panel into ChatGPT over CDP. The first click
/// snapshots safe source paths into stable pages; subsequent clicks consume
/// that queue through ChatGPT's file input.
public final class EntryService {
    static let chatGPTMaximumAttachmentFiles = 20

    static let chatGPTComposerHasAttachmentsExpression = """
    (() => {
      const candidates = Array.from(document.querySelectorAll('input[type="file"][multiple]'))
        .filter(input => !input.disabled && !input.hasAttribute('accept'))
        .map(input => {
          const root = input.parentElement;
          const editor = root?.querySelector('[contenteditable="true"][role="textbox"], textarea[role="textbox"]');
          const rect = editor?.getBoundingClientRect();
          return { input, root, editor, rect };
        })
        .filter(candidate => candidate.rect && candidate.rect.width > 80 && candidate.rect.height > 10)
        .sort((left, right) => right.rect.x - left.rect.x);
      const composer = candidates[0];
      if (!composer) return null;
      return composer.root.querySelector('[data-composer-attachments-row]') !== null;
    })()
    """

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
    private var attachmentBusy = false
    private var attachmentQueue: AttachmentQueueSnapshot?
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
        case "get-state":
            Task { [weak self] in await self?.respond(session, self?.entryStatePayload() ?? ["ok": false]) }
        case "choose-workspace":
            Task { [weak self] in await self?.performChooseWorkspace(session: session) }
        case "edit-ignore-rules":
            Task { [weak self] in await self?.performEditIgnoreRules(session: session) }
        case "attach-workspace-files":
            Task { [weak self] in await self?.performAttachWorkspaceFiles(session: session) }
        default:
            Task { await respond(session, ["ok": false, "error": "Unknown action"]) }
        }
    }

    private func performChooseWorkspace(session: CDPSession) async {
        let wasBusy = withLock {
            let busy = pickerBusy || attachmentBusy
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
            withLock {
                workspace = selected
                attachmentQueue = nil
            }
            log("Selected workspace: \(selected.root)")
            await respond(session, ["ok": true, "action": "choose-workspace", "workspace": selected.name])
            await broadcastState()
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    private func performEditIgnoreRules(session: CDPSession) async {
        let wasBusy = withLock {
            let busy = pickerBusy || attachmentBusy
            if !busy { pickerBusy = true }
            return busy
        }
        guard !wasBusy else {
            await respond(session, ["ok": false, "error": "附件或目錄操作仍在處理中，請稍候。"])
            return
        }
        defer { withLock { pickerBusy = false } }
        do {
            let selected = withLock { workspace }
            let policyURL = try selected.prepareEditableIgnorePolicy()
            let refreshed = try Workspace(root: selected.root)
            withLock {
                if workspace.root == selected.root {
                    workspace = refreshed
                    attachmentQueue = nil
                }
            }
            let result = try runCommand("/usr/bin/open", ["-t", policyURL.path], timeout: 20)
            guard result.code == 0 else { throw C2CError("無法開啟 .c2cignore。") }
            await respond(session, [
                "ok": true,
                "action": "edit-ignore-rules",
                "workspace": refreshed.name,
                "path": policyURL.path
            ])
            await broadcastState()
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    struct AttachmentBatch {
        let files: [URL]
        let candidateCount: Int
        let pageIndex: Int
        let pageCount: Int
        let remainingCount: Int
        let hasMore: Bool
        let incomplete: Bool
        let truncated: Bool
    }

    struct AttachmentQueueSnapshot {
        let workspaceID: String
        let workspaceRoot: String
        let pages: [[URL]]
        let candidateCount: Int
        let incomplete: Bool
        let maxFileBytes: Int
        var nextPageIndex: Int

        var currentBatch: AttachmentBatch? {
            guard pages.indices.contains(nextPageIndex) else { return nil }
            let remainingCount = pages.indices
                .filter { $0 > nextPageIndex }
                .reduce(0) { $0 + pages[$1].count }
            return AttachmentBatch(
                files: pages[nextPageIndex],
                candidateCount: candidateCount,
                pageIndex: nextPageIndex,
                pageCount: pages.count,
                remainingCount: remainingCount,
                hasMore: nextPageIndex + 1 < pages.count,
                incomplete: incomplete,
                truncated: incomplete || nextPageIndex + 1 < pages.count
            )
        }
    }

    func workspaceAttachmentQueue(maxFiles: Int = EntryService.chatGPTMaximumAttachmentFiles, maxFileBytes: Int = 1 * 1024 * 1024, maxTotalBytes: Int = 8 * 1024 * 1024) throws -> AttachmentQueueSnapshot {
        let current = withLock { workspace }
        let selected = try Workspace(root: current.root)
        withLock {
            if workspace.root == current.root { workspace = selected }
        }
        return try workspaceAttachmentQueue(
            workspace: selected,
            maxFiles: maxFiles,
            maxFileBytes: maxFileBytes,
            maxTotalBytes: maxTotalBytes
        )
    }

    private func workspaceAttachmentQueue(workspace selected: Workspace, maxFiles: Int, maxFileBytes: Int, maxTotalBytes: Int) throws -> AttachmentQueueSnapshot {
        guard maxFiles > 0, maxFileBytes > 0, maxTotalBytes > 0 else {
            throw C2CError("附件數量與容量上限必須大於零。")
        }
        let effectiveMaxFiles = min(maxFiles, Self.chatGPTMaximumAttachmentFiles)
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
        let enumeration = selected.enumerateTextFiles(
            preferredNames: Set(preferredNames),
            extensions: textExtensions,
            maxFileBytes: maxFileBytes
        )
        let candidates = enumeration.candidates.sorted { lhs, rhs in
            let left = preferredNames.firstIndex(of: URL(fileURLWithPath: lhs.path).lastPathComponent) ?? preferredNames.count
            let right = preferredNames.firstIndex(of: URL(fileURLWithPath: rhs.path).lastPathComponent) ?? preferredNames.count
            return left == right ? lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending : left < right
        }

        var pages: [[URL]] = []
        var currentPage: [URL] = []
        var currentPageBytes = 0
        var skippedForLimit = false
        for candidate in candidates {
            guard candidate.size <= maxTotalBytes else {
                skippedForLimit = true
                continue
            }
            if currentPage.count == effectiveMaxFiles ||
                (!currentPage.isEmpty && candidate.size > maxTotalBytes - currentPageBytes) {
                pages.append(currentPage)
                currentPage = []
                currentPageBytes = 0
            }
            currentPage.append(candidate.url)
            currentPageBytes += candidate.size
        }
        if !currentPage.isEmpty { pages.append(currentPage) }
        return AttachmentQueueSnapshot(
            workspaceID: selected.id,
            workspaceRoot: selected.root,
            pages: pages,
            candidateCount: candidates.count,
            incomplete: skippedForLimit || enumeration.incomplete,
            maxFileBytes: maxFileBytes,
            nextPageIndex: 0
        )
    }

    func workspaceAttachmentBatch(pageIndex: Int = 0, maxFiles: Int = EntryService.chatGPTMaximumAttachmentFiles, maxFileBytes: Int = 1 * 1024 * 1024, maxTotalBytes: Int = 8 * 1024 * 1024) throws -> AttachmentBatch {
        var queue = try workspaceAttachmentQueue(maxFiles: maxFiles, maxFileBytes: maxFileBytes, maxTotalBytes: maxTotalBytes)
        queue.nextPageIndex = pageIndex
        guard let batch = queue.currentBatch else { throw C2CError("附件批次已失效，請從第一批重新開始。") }
        return batch
    }

    private func performAttachWorkspaceFiles(session: CDPSession) async {
        let request = withLock { () -> (busy: Bool, workspace: Workspace, queue: AttachmentQueueSnapshot?) in
            let busy = attachmentBusy || pickerBusy
            if !busy { attachmentBusy = true }
            return (busy, workspace, attachmentQueue)
        }
        guard !request.busy else {
            await respond(session, ["ok": false, "error": "附件仍在處理中，請稍候。"])
            return
        }
        defer { withLock { attachmentBusy = false } }
        do {
            let selected = try Workspace(root: request.workspace.root)
            withLock {
                if workspace.root == request.workspace.root { workspace = selected }
            }
            var queue = try request.queue ?? workspaceAttachmentQueue(
                workspace: selected,
                maxFiles: Self.chatGPTMaximumAttachmentFiles,
                maxFileBytes: 1 * 1024 * 1024,
                maxTotalBytes: 8 * 1024 * 1024
            )
            guard queue.workspaceID == selected.id, queue.workspaceRoot == selected.root else {
                throw C2CError("工作目錄已變更，附件批次已重置，請再按一次。")
            }
            guard let batch = queue.currentBatch else {
                throw C2CError("附件批次已失效，請從第一批重新開始。")
            }
            guard !batch.files.isEmpty else { throw C2CError("工作目錄中沒有可附加的文字或程式碼檔案。") }
            let validatedFiles = batch.files.compactMap {
                selected.validatedTextFile(at: $0, maxFileBytes: queue.maxFileBytes)?.url
            }
            guard validatedFiles.count == batch.files.count else {
                withLock { attachmentQueue = nil }
                await broadcastState()
                throw C2CError("批次快照中的檔案已刪除或不再安全，已重置；請從第一批重新開始。")
            }
            if try await chatGPTComposerHasAttachments(session: session) {
                throw C2CError("ChatGPT／Quick Chat 輸入框仍有附件。請先送出或移除目前附件，再附加下一批。")
            }
            try await attachToChatGPT(validatedFiles, session: session)
            if batch.hasMore { queue.nextPageIndex += 1 }
            withLock {
                if workspace.root == selected.root {
                    attachmentQueue = batch.hasMore ? queue : nil
                }
            }
            log("Attached workspace batch \(batch.pageIndex + 1)/\(batch.pageCount) (\(batch.files.count) file(s)) to ChatGPT for \(selected.name).")
            await respond(session, [
                "ok": true,
                "action": "attach-workspace-files",
                "workspace": selected.name,
                "count": batch.files.count,
                "candidateCount": batch.candidateCount,
                "batchNumber": batch.pageIndex + 1,
                "batchCount": batch.pageCount,
                "remainingCount": batch.remainingCount,
                "hasMore": batch.hasMore,
                "incomplete": batch.incomplete,
                "truncated": batch.truncated
            ])
            await broadcastState()
        } catch {
            await respond(session, ["ok": false, "error": error.localizedDescription])
        }
    }

    private func chatGPTComposerHasAttachments(session: CDPSession) async throws -> Bool {
        (try await session.evaluateValue(Self.chatGPTComposerHasAttachmentsExpression, timeout: 5) as? Bool) == true
    }

    private func entryStatePayload() -> [String: Any] {
        withLock {
            var payload: [String: Any] = [
                "ok": true,
                "action": "state",
                "workspace": workspace.name,
                "hasPendingBatch": false
            ]
            if let queue = attachmentQueue, let batch = queue.currentBatch,
               queue.workspaceID == workspace.id {
                payload["hasPendingBatch"] = true
                payload["batchNumber"] = batch.pageIndex + 1
                payload["batchCount"] = batch.pageCount
                payload["remainingCount"] = batch.files.count + batch.remainingCount
            }
            return payload
        }
    }

    private func broadcastState() async {
        let payload = entryStatePayload()
        for session in withLock({ Array(sessions.values) }) where session.isConnected {
            await respond(session, payload)
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
