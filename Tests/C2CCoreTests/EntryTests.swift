import XCTest
@testable import C2CCore

final class EntryTests: XCTestCase {
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = root.appendingPathComponent("project")
        try AppPaths.ensureDirectory(project)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testParseTargetsFiltersAppPages() throws {
        let json: [[String: Any]] = [
            ["type": "page", "id": "main", "url": "app://-/index.html", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/main"],
            ["type": "page", "id": "quick", "url": "app://-/index.html?initialRoute=%2Fchatgpt%2Fquick-chat-prewarm", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/quick"],
            ["type": "page", "id": "overlay", "url": "app://-/index.html?window=avatar-overlay", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/overlay"],
            ["type": "page", "id": "outside", "url": "https://example.com", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/outside"],
            ["type": "browser", "id": "browser", "url": "app://-/index.html", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/browser"]
        ]
        let targets = CDPDebug.parseTargets(json).filter { CDPDebug.isAppPageURL($0.url) }
        XCTAssertEqual(targets.map(\.id), ["main"])
        XCTAssertEqual(targets[0].webSocketURL.port, 57330)
        XCTAssertTrue(CDPDebug.isAppPageURL("app://-/index.html"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?initialRoute=%2Fchatgpt%2Fquick-chat-prewarm"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?x=1"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?initialRoute=%2Fglobal-dictation"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?window=avatar-overlay"))
        XCTAssertFalse(CDPDebug.isAppPageURL("https://chatgpt.com/"))
        XCTAssertTrue(CDPDebug.parseTargets("not-a-list" as Any).isEmpty)
    }

    func testInstallScriptIsIdempotentAndIncludesWorkspaceActions() throws {
        let source = EntryPanel.installScript(workspaceName: "my project")
        XCTAssertTrue(source.contains("var MARKER = \"\(EntryPanel.marker)\";"))
        XCTAssertTrue(source.contains("var VERSION = \"\(EntryPanel.version)\";"))
        XCTAssertTrue(source.contains("if (window[MARKER] === VERSION && previousHost) return \"already\";"))
        XCTAssertTrue(source.contains("if (previousHost) previousHost.remove();"))
        XCTAssertTrue(EntryPanel.presenceScript.contains(EntryPanel.version))
        XCTAssertTrue(EntryPanel.presenceScript.contains(EntryPanel.hostID))
        XCTAssertTrue(source.contains(EntryPanel.bindingName))
        XCTAssertTrue(source.contains(EntryPanel.resultFunction))
        XCTAssertTrue(source.contains("callNative(\"choose-workspace\")"))
        XCTAssertTrue(source.contains("callNative(\"attach-workspace-files\")"))
        XCTAssertTrue(source.contains("callNative(\"get-state\", true)"))
        XCTAssertTrue(source.contains("payload.action === \"state\""))
        XCTAssertTrue(source.contains("data-app-action-sidebar-thread-id"))
        XCTAssertTrue(source.contains("data-c2c-quick-chat-button"))
        XCTAssertTrue(source.contains("[data-app-action-sidebar-thread-row]>[data-c2c-quick-chat-button]{inset-inline-end:6px}"))
        XCTAssertTrue(source.contains("row.appendChild(button)"))
        XCTAssertTrue(source.contains("解除 Quick Chat 綁定"))
        XCTAssertTrue(source.contains("data-c2c-quick-chat-unbind-button"))
        XCTAssertTrue(source.contains("row.appendChild(unbindButton)"))
        XCTAssertTrue(source.contains("unbindQuickChat(threadID)"))
        XCTAssertTrue(source.contains("delete quickChatBindings[threadID]"))
        XCTAssertFalse(source.contains("button.addEventListener(\"contextmenu\""))
        XCTAssertTrue(source.contains(EntryPanel.quickChatStorageKey))
        XCTAssertTrue(source.contains("data-above-composer-conversation-id"))
        XCTAssertTrue(source.contains("onConversationSelect"))
        XCTAssertTrue(source.contains("conversation.title || fallbackTitle"))
        XCTAssertTrue(source.contains("無法繼續這個 session 原本的 Quick Chat 對話"))
        XCTAssertTrue(source.contains("if (!changed) return"))
        XCTAssertTrue(source.contains("cancelAnimationFrame(quickChatScanFrame)"))
        XCTAssertFalse(source.contains("conversation.projectId"))
        XCTAssertTrue(source.contains("openQuickChatForThread(row)"))
        XCTAssertTrue(source.contains("送出後附加下一批"))
        XCTAssertTrue(source.contains("從第一批重新開始"))
        XCTAssertFalse(source.contains("callNative(\"open-workspace\")"))
        XCTAssertFalse(source.contains("workspace-context.md"))
        XCTAssertTrue(source.contains("工作區：\" + WORKSPACE"))
        XCTAssertTrue(source.contains("\"my project\""))
        let cleared = EntryPanel.clearScript
        XCTAssertTrue(cleared.contains("getElementById(\"\(EntryPanel.hostID)\")"))
        XCTAssertTrue(cleared.contains("delete window.\(EntryPanel.marker)"))
        XCTAssertTrue(cleared.contains(EntryPanel.quickChatCleanupFunction))
    }

    func testWorkspaceAttachmentBatchUsesRawSafeFilesAndLimitsSize() throws {
        try "# Demo\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let answer = 42\n".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "SECRET=value\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 32).write(to: project.appendingPathComponent("image.bin"))
        try Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x00, 0xd1]).write(to: project.appendingPathComponent("binary.plist"))

        let service = EntryService(workspace: try Workspace(root: project.path))
        let batch = try service.workspaceAttachmentBatch(maxFiles: 1, maxFileBytes: 1024, maxTotalBytes: 1024)
        XCTAssertEqual(batch.files.map(\.lastPathComponent), ["README.md"])
        XCTAssertEqual(batch.candidateCount, 2)
        XCTAssertEqual(batch.pageCount, 2)
        XCTAssertEqual(batch.remainingCount, 1)
        XCTAssertTrue(batch.hasMore)
        XCTAssertTrue(batch.truncated)
        XCTAssertFalse(batch.files.map(\.lastPathComponent).contains(".env"))
    }

    func testWorkspaceAttachmentBatchNeverExceedsChatGPTLimit() throws {
        for index in 0..<25 {
            try "let value = \(index)\n".write(
                to: project.appendingPathComponent("File\(index).swift"),
                atomically: true,
                encoding: .utf8
            )
        }

        let service = EntryService(workspace: try Workspace(root: project.path))
        let batch = try service.workspaceAttachmentBatch(maxFiles: 100)
        XCTAssertEqual(EntryService.chatGPTMaximumAttachmentFiles, 20)
        XCTAssertEqual(batch.files.count, 20)
        XCTAssertEqual(batch.candidateCount, 25)
        XCTAssertEqual(batch.pageIndex, 0)
        XCTAssertEqual(batch.pageCount, 2)
        XCTAssertEqual(batch.remainingCount, 5)
        XCTAssertTrue(batch.hasMore)
        XCTAssertTrue(batch.truncated)

        let secondBatch = try service.workspaceAttachmentBatch(pageIndex: 1, maxFiles: 100)
        XCTAssertEqual(secondBatch.files.count, 5)
        XCTAssertEqual(secondBatch.pageIndex, 1)
        XCTAssertEqual(secondBatch.pageCount, 2)
        XCTAssertEqual(secondBatch.remainingCount, 0)
        XCTAssertFalse(secondBatch.hasMore)

        var frozenQueue = try service.workspaceAttachmentQueue(maxFiles: 100)
        try "let inserted = true\n".write(
            to: project.appendingPathComponent("A.swift"),
            atomically: true,
            encoding: .utf8
        )
        frozenQueue.nextPageIndex = 1
        let frozenSecondBatch = try XCTUnwrap(frozenQueue.currentBatch)
        XCTAssertEqual(frozenSecondBatch.files.count, 5)
        XCTAssertFalse(frozenSecondBatch.files.map(\.lastPathComponent).contains("A.swift"))
        XCTAssertEqual(try service.workspaceAttachmentQueue(maxFiles: 100).candidateCount, 26)

        XCTAssertThrowsError(try service.workspaceAttachmentBatch(pageIndex: 99))
    }

    func testAttachmentScannerHasNoDepthOrThousandEntryCap() throws {
        let deep = project
            .appendingPathComponent("one/two/three/four/five/six", isDirectory: true)
        try AppPaths.ensureDirectory(deep)
        try "deep\n".write(to: deep.appendingPathComponent("Deep.swift"), atomically: true, encoding: .utf8)
        for index in 0..<1_001 {
            let created = FileManager.default.createFile(
                atPath: project.appendingPathComponent("Source\(index).swift").path,
                contents: Data("let n = \(index)\n".utf8)
            )
            XCTAssertTrue(created)
        }

        let service = EntryService(workspace: try Workspace(root: project.path))
        let queue = try service.workspaceAttachmentQueue()
        XCTAssertEqual(queue.candidateCount, 1_002)
        XCTAssertEqual(queue.pages.count, 51)
        XCTAssertTrue(queue.pages.flatMap { $0 }.contains { $0.lastPathComponent == "Deep.swift" })
        XCTAssertFalse(queue.incomplete)
    }

    func testChatGPTAttachmentUsesHiddenGeneralFileInput() {
        let expression = EntryService.chatGPTFileInputExpression
        XCTAssertTrue(expression.contains("input[type=\"file\"][multiple]"))
        XCTAssertTrue(expression.contains("!input.hasAttribute('accept')"))
        XCTAssertTrue(expression.contains("treeDistance"))
        XCTAssertFalse(expression.contains("Input.dispatchDragEvent"))
        XCTAssertTrue(EntryService.chatGPTComposerHasAttachmentsExpression.contains("data-composer-attachments-row"))
    }

}
