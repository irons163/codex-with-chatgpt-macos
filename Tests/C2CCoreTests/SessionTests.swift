import Foundation
import XCTest
@testable import C2CCore

final class SessionTests: XCTestCase {
    private var stateDirectory: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2c-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        store = SessionStore(workspaceID: "workspace-test", stateDirectory: stateDirectory)
    }

    override func tearDownWithError() throws {
        if let stateDirectory {
            try? FileManager.default.removeItem(at: stateDirectory)
        }
        store = nil
        stateDirectory = nil
        try super.tearDownWithError()
    }

    func testNewWorkspaceDefaultsToProjectConversation() {
        let conversation = store.conversation()
        XCTAssertEqual(conversation["mode"] as? String, "project")
        XCTAssertEqual(conversation["reason"] as? String, "new-workspace")
        XCTAssertEqual(conversation["projectReady"] as? Bool, false)
        XCTAssertEqual(conversation["reuseSavedChat"] as? Bool, false)
        XCTAssertTrue(conversation["projectUrl"] is NSNull)
        XCTAssertTrue(conversation["chatUrl"] is NSNull)
        XCTAssertTrue(conversation["connectorName"] is NSNull)
    }

    func testProjectURLIsValidatedAndCanonicalized() throws {
        let saved = try store.set(
            [
                "mode": "PROJECT",
                "project-url": " https://www.chatgpt.com/g/g-p-Ab12/project/?tab=home#top ",
                "url": "https://chatgpt.com/c/example",
            ],
            flags: []
        )

        XCTAssertEqual(saved["conversationMode"] as? String, "project")
        XCTAssertEqual(saved["projectUrl"] as? String, "https://chatgpt.com/g/g-p-Ab12/project")
        XCTAssertEqual(store.conversation()["projectReady"] as? Bool, true)
        XCTAssertEqual(
            store.conversation()["projectUrl"] as? String,
            "https://chatgpt.com/g/g-p-Ab12/project"
        )
    }

    func testInvalidProjectURLAndModeAreRejected() {
        XCTAssertThrowsError(try store.set(["mode": "project"], flags: [])) { error in
            XCTAssertEqual(error.localizedDescription, "project mode requires --project-url")
        }
        XCTAssertThrowsError(
            try store.set(["mode": "project", "project-url": "https://evil.example/g/g-p-id/project"], flags: [])
        )
        XCTAssertThrowsError(try store.set(["mode": "sideways", "url": "chat"], flags: []))
        XCTAssertThrowsError(try store.set(["mode": "project", "project-url": "https://chatgpt.com/g/id/project"], flags: []))
    }

    func testConversationURLsRequireHTTPSChatGPTChatPaths() throws {
        let direct = try store.set(["url": " https://www.chatgpt.com/c/direct-chat?tab=home#latest "], flags: [])
        XCTAssertEqual(direct["url"] as? String, "https://www.chatgpt.com/c/direct-chat?tab=home#latest")

        let projectChat = try store.set(
            ["url": "https://chatgpt.com/g/g-p-project/c/project-chat"],
            flags: []
        )
        XCTAssertEqual(projectChat["url"] as? String, "https://chatgpt.com/g/g-p-project/c/project-chat")

        for invalid in [
            "http://chatgpt.com/c/chat",
            "https://evil.example/c/chat",
            "https://user:password@chatgpt.com/c/chat",
            "https://chatgpt.com:443/c/chat",
            "https://chatgpt.com/c/",
            "https://chatgpt.com/g/g-p-project/project",
            "https://chatgpt.com/g/g-p-project/c/",
            "https://chatgpt.com/c/chat/extra",
        ] {
            XCTAssertThrowsError(try store.set(["url": invalid], flags: []), "Expected rejection for \(invalid)")
        }
    }

    func testLegacySessionURLsRemainReadableAndArePreservedOnOtherUpdates() throws {
        let legacyURL = "http://legacy.example/conversation"
        let file = stateDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("workspace-test.json", isDirectory: false)
        try AppPaths.writeJSON(
            ["url": legacyURL, "savedAt": "2026-01-01T00:00:00.000Z"],
            to: file
        )

        XCTAssertEqual(store.get()?["url"] as? String, legacyURL)
        XCTAssertEqual(store.conversation()["chatUrl"] as? String, legacyURL)
        let updated = try store.set(["title": "Legacy conversation"], flags: [])
        XCTAssertEqual(updated["url"] as? String, legacyURL)
        XCTAssertEqual(updated["title"] as? String, "Legacy conversation")
    }

    func testCheckpointMergeCapsTextAndCarriesChatAndProject() throws {
        let goal = String(repeating: "g", count: 501)
        let saved = try store.set(
            [
                "mode": "project",
                "project-url": "https://chatgpt.com/g/g-p-project/project",
                "url": "https://chatgpt.com/c/chat",
                "task": "task-1",
                "iteration": "2",
                "protocol-state": "executed_sent",
                "waiting-for": "gpt_review",
                "goal": goal,
                "completed-subtasks": "  done  ",
                "known-issues": "   ",
                "next-step": "review",
            ],
            flags: []
        )

        let checkpoint = try XCTUnwrap(saved["checkpoint"] as? [String: Any])
        XCTAssertEqual(checkpoint["taskId"] as? String, "task-1")
        XCTAssertEqual(checkpoint["iteration"] as? Int, 2)
        XCTAssertEqual(checkpoint["protocolState"] as? String, "EXECUTED_SENT")
        XCTAssertEqual(checkpoint["waitingFor"] as? String, "GPT_REVIEW")
        XCTAssertEqual((checkpoint["originalGoal"] as? String)?.count, 501) // 500 + ellipsis
        XCTAssertEqual(checkpoint["completedSubtasks"] as? String, "done")
        XCTAssertNil(checkpoint["knownIssues"])
        XCTAssertEqual(checkpoint["nextExpectedStep"] as? String, "review")
        XCTAssertEqual(checkpoint["chatUrl"] as? String, "https://chatgpt.com/c/chat")
        XCTAssertEqual(
            checkpoint["projectUrl"] as? String,
            "https://chatgpt.com/g/g-p-project/project"
        )
        XCTAssertNotNil(checkpoint["updatedAt"] as? String)
    }

    func testCheckpointRequiresTaskAndStrictValues() throws {
        XCTAssertThrowsError(
            try store.set(["protocol-state": "INIT"], flags: [])
        )
        XCTAssertThrowsError(
            try store.set(["task": "task", "protocol-state": "INIT", "iteration": "1x"], flags: [])
        )
        XCTAssertThrowsError(
            try store.set(["task": "task", "protocol-state": "INIT", "waiting-for": "nobody"], flags: [])
        )
        XCTAssertThrowsError(
            try store.set(["task": "task", "goal": "a"], flags: [])
        )
        XCTAssertThrowsError(
            try store.set(["task": "task", "protocol-state": "INIT"], flags: ["unknown"])
        )
    }

    func testClearRemovesLongChatAndKeepsProjectBinding() throws {
        try store.set(["mode": "long-chat", "url": "https://chatgpt.com/c/long", "title": "Long"], flags: [])
        let removed = try store.clear()
        XCTAssertEqual(removed["cleared"] as? Bool, true)
        XCTAssertEqual(removed["keptProject"] as? Bool, false)
        XCTAssertNil(store.get())

        try store.set(
            [
                "mode": "project",
                "project-url": "https://chatgpt.com/g/g-p-project/project",
                "url": "https://chatgpt.com/c/project-chat",
                "connector-name": "Connector",
            ],
            flags: []
        )
        let kept = try store.clear()
        XCTAssertEqual(kept["cleared"] as? Bool, true)
        XCTAssertEqual(kept["keptProject"] as? Bool, true)
        let saved = try XCTUnwrap(store.get())
        XCTAssertNil(saved["url"])
        XCTAssertNil(saved["title"])
        XCTAssertEqual(saved["projectUrl"] as? String, "https://chatgpt.com/g/g-p-project/project")
        XCTAssertEqual(saved["connectorName"] as? String, "Connector")
        XCTAssertEqual(store.conversation()["reuseSavedChat"] as? Bool, false)
    }

    func testClearWithNoSessionIsIdempotent() throws {
        let result = try store.clear()
        XCTAssertEqual(result["cleared"] as? Bool, false)
        XCTAssertEqual(result["keptProject"] as? Bool, false)
    }
}
