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

    func testInstallScriptIsIdempotentAndIncludesActions() throws {
        let source = EntryPanel.installScript(workspaceName: "my project")
        XCTAssertTrue(source.contains("var MARKER = \"\(EntryPanel.marker)\";"))
        XCTAssertTrue(source.contains("if (window[MARKER]) return \"already\";"))
        XCTAssertTrue(source.contains(EntryPanel.bindingName))
        XCTAssertTrue(source.contains(EntryPanel.resultFunction))
        XCTAssertTrue(source.contains("input[type=\"file\"]"))
        XCTAssertTrue(source.contains("{ action: \"upload\" }"))
        XCTAssertTrue(source.contains("工作區：\" + WORKSPACE"))
        XCTAssertTrue(source.contains("\"my project\""))
        let cleared = EntryPanel.clearScript
        XCTAssertTrue(cleared.contains("getElementById(\"\(EntryPanel.hostID)\")"))
        XCTAssertTrue(cleared.contains("delete window.\(EntryPanel.marker)"))
    }

    func testSanitizeFileName() {
        XCTAssertEqual(EntryService.sanitizeFileName("photo.png"), "photo.png")
        XCTAssertEqual(EntryService.sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(EntryService.sanitizeFileName("a/b/c.txt"), "c.txt")
        XCTAssertEqual(EntryService.sanitizeFileName("  spaced name.zip "), "spaced name.zip")
        XCTAssertEqual(EntryService.sanitizeFileName(""), "untitled")
        XCTAssertEqual(EntryService.sanitizeFileName("no\0null.bin"), "nonull.bin")
    }

    func testCopyIntoWorkspaceRejectsEscapeAndDuplicatesNames() throws {
        let workspace = try Workspace(root: project.path)
        let service = EntryService(workspace: workspace)
        let source = root.appendingPathComponent("source.txt")
        try "hello\n".write(to: source, atomically: true, encoding: .utf8)

        let first = try service.copyIntoWorkspace(paths: [source.path])
        XCTAssertEqual(first, ["uploads/source.txt"])
        let second = try service.copyIntoWorkspace(paths: [source.path])
        XCTAssertEqual(second, ["uploads/source-1.txt"])

        // A directory masquerading as a file must be rejected.
        let directory = root.appendingPathComponent("folder"); try AppPaths.ensureDirectory(directory)
        XCTAssertThrowsError(try service.copyIntoWorkspace(paths: [directory.path]))

        // uploads must stay inside the workspace: replace it with a symlink outside.
        let uploads = project.appendingPathComponent("uploads")
        try FileManager.default.removeItem(at: uploads)
        try FileManager.default.createSymbolicLink(at: uploads, withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try service.copyIntoWorkspace(paths: [source.path]))
    }
}
