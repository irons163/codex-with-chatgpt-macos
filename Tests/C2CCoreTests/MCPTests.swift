import XCTest
@testable import C2CCore

final class MCPTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func service() throws -> (MCPService, ExecutionStore) {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("c2c-mcp-ws-\(UUID().uuidString)"); let state = FileManager.default.temporaryDirectory.appendingPathComponent("c2c-mcp-state-\(UUID().uuidString)"); roots += [workspace, state]
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true); try Data("hello\n".utf8).write(to: workspace.appendingPathComponent("hello.txt"))
        let ws = try Workspace(root: workspace.path); return (MCPService(workspace: ws, stateDirectory: state), ExecutionStore(workspaceID: ws.id, stateDirectory: state))
    }
    private func request(_ value: [String: Any], scopes: String? = "workspace.read workspace.search git.read execution.read") throws -> HTTPRequest {
        var headers = ["content-type": "application/json"]; if let scopes { headers["x-c2c-scopes"] = scopes }
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: value))
    }
    private func body(_ response: HTTPResponse) throws -> [String: Any] { try JSONSerialization.jsonObject(with: response.body) as! [String: Any] }

    func testInitializePingAndToolListing() throws {
        let (service, _) = try service()
        let initialized = try body(service.handle(request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])))
        XCTAssertEqual(((initialized["result"] as? [String: Any])?["protocolVersion"] as? String), "2025-03-26")
        let pong = try body(service.handle(request(["jsonrpc": "2.0", "id": 2, "method": "ping"]))); XCTAssertNotNil(pong["result"])
        let listed = try body(service.handle(request(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])))
        let names = (((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["execution_output", "execution_summary", "git_diff", "git_status", "list_directory", "read_file", "search_workspace", "test_status", "workspace_info"])
    }

    func testToolCallReturnsMatchingStructuredAndTextContent() throws {
        let (service, _) = try service(); let response = service.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "read_file", "arguments": ["path": "hello.txt"]]]))
        let result = (try body(response)["result"] as? [String: Any])!; XCTAssertNil(result["isError"])
        let structured = result["structuredContent"] as? [String: Any]; XCTAssertEqual(structured?["content"] as? String, "hello")
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String)!; XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["path"] as? String, "hello.txt")
    }

    func testMissingAndInsufficientScopesFailClosed() throws {
        let (service, _) = try service()
        for scopes in [nil, "workspace.read"] as [String?] {
            let response = service.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "git_status", "arguments": [:]]], scopes: scopes))
            let result = (try body(response)["result"] as? [String: Any])!; XCTAssertEqual(result["isError"] as? Bool, true)
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""; XCTAssertTrue(text.contains("INSUFFICIENT_SCOPE"))
        }
    }

    func testExecutionOutputCannotExposeRestrictedBody() throws {
        let (service, store) = try service(); let record = try store.record(["taskId": "x", "iteration": 0, "changedFiles": 0, "exitStatus": "ok", "command": "cat .env", "output": "never-show-this"]); let id = record["outputId"] as! Int
        let response = service.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "execution_output", "arguments": ["action": "read", "id": id]]]))
        let result = (try body(response)["result"] as? [String: Any])!; let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("OUTPUT_RESTRICTED")); XCTAssertFalse(text.contains("never-show-this"))
    }

    func testProtocolErrorsAndNotifications() throws {
        let (service, _) = try service(); XCTAssertEqual(service.handle(HTTPRequest(method: "GET", path: "/mcp")).status, 405)
        XCTAssertEqual(service.handle(HTTPRequest(method: "POST", path: "/mcp", body: Data("bad".utf8))).status, 200)
        XCTAssertEqual(service.handle(try request(["jsonrpc": "2.0", "method": "notifications/initialized"])).status, 202)
    }

    func testToolArgumentsRejectUnknownWrongTypeBoolAndOutOfRangeValues() throws {
        let (service, _) = try service()
        let invalidArguments: [[String: Any]] = [
            ["path": "hello.txt", "start_line": true],
            ["path": "hello.txt", "unknown": 1],
            ["path": ".", "depth": 5],
            ["path": ".", "offset": -1]
        ]
        for arguments in invalidArguments {
            let name = arguments["depth"] != nil || arguments["offset"] != nil ? "list_directory" : "read_file"
            let response = service.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]))
            let result = (try body(response)["result"] as? [String: Any])!; let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            XCTAssertEqual(result["isError"] as? Bool, true); XCTAssertTrue(text.contains("INVALID_ARGUMENTS"))
        }
    }
}
