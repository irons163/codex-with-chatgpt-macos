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
        XCTAssertTrue(source.contains("送出後附加下一批"))
        XCTAssertTrue(source.contains("從第一批重新開始"))
        XCTAssertFalse(source.contains("callNative(\"open-workspace\")"))
        XCTAssertFalse(source.contains("workspace-context.md"))
        XCTAssertTrue(source.contains("工作區：\" + WORKSPACE"))
        XCTAssertTrue(source.contains("\"my project\""))
        let cleared = EntryPanel.clearScript
        XCTAssertTrue(cleared.contains("getElementById(\"\(EntryPanel.hostID)\")"))
        XCTAssertTrue(cleared.contains("delete window.\(EntryPanel.marker)"))
    }

    func testWorkspaceAttachmentBatchUsesRawSafeFilesAndLimitsSize() throws {
        try "# Demo\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "let answer = 42\n".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "SECRET=value\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 32).write(to: project.appendingPathComponent("image.bin"))

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
    }

    func testChatGPTAttachmentUsesHiddenGeneralFileInput() {
        let expression = EntryService.chatGPTFileInputExpression
        XCTAssertTrue(expression.contains("input[type=\"file\"][multiple]"))
        XCTAssertTrue(expression.contains("!input.hasAttribute('accept')"))
        XCTAssertTrue(expression.contains("treeDistance"))
        XCTAssertFalse(expression.contains("Input.dispatchDragEvent"))
    }

}
