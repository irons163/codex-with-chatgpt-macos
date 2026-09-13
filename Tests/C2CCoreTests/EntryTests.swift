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
            ["type": "page", "id": "overlay", "url": "app://-/index.html?window=avatar-overlay", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/overlay"],
            ["type": "page", "id": "outside", "url": "https://example.com", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/page/outside"],
            ["type": "browser", "id": "browser", "url": "app://-/index.html", "webSocketDebuggerUrl": "ws://127.0.0.1:57330/devtools/browser"]
        ]
        let targets = CDPDebug.parseTargets(json).filter { CDPDebug.isAppPageURL($0.url) }
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].id, "main")
        XCTAssertEqual(targets[0].webSocketURL.port, 57330)
        XCTAssertTrue(CDPDebug.isAppPageURL("app://-/index.html"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?x=1"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?initialRoute=%2Fglobal-dictation"))
        XCTAssertFalse(CDPDebug.isAppPageURL("app://-/index.html?window=avatar-overlay"))
        XCTAssertFalse(CDPDebug.isAppPageURL("https://chatgpt.com/"))
        XCTAssertTrue(CDPDebug.parseTargets("not-a-list" as Any).isEmpty)
    }

    func testInstallScriptIsIdempotentAndIncludesWorkspaceActions() throws {
        let source = EntryPanel.installScript(workspaceName: "my project")
        XCTAssertTrue(source.contains("var MARKER = \"\(EntryPanel.marker)\";"))
        XCTAssertTrue(source.contains("if (window[MARKER]) return \"already\";"))
        XCTAssertTrue(source.contains(EntryPanel.bindingName))
        XCTAssertTrue(source.contains(EntryPanel.resultFunction))
        XCTAssertTrue(source.contains("callNative(\"choose-workspace\")"))
        XCTAssertTrue(source.contains("callNative(\"open-workspace\")"))
        XCTAssertFalse(source.contains("attach-workspace"))
        XCTAssertFalse(source.contains("workspace-context.md"))
        XCTAssertTrue(source.contains("工作區：\" + WORKSPACE"))
        XCTAssertTrue(source.contains("\"my project\""))
        let cleared = EntryPanel.clearScript
        XCTAssertTrue(cleared.contains("getElementById(\"\(EntryPanel.hostID)\")"))
        XCTAssertTrue(cleared.contains("delete window.\(EntryPanel.marker)"))
    }

    func testNativeWorkspaceOpenUsesExactAppAndDirectory() throws {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let workspace = try Workspace(root: project.path)
        XCTAssertEqual(
            ChatGPTApp.workspaceOpenArguments(app: app, workspace: workspace),
            ["-a", app.path, workspace.root]
        )
    }

}
