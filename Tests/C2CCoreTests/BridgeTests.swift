import XCTest
import CryptoKit
@testable import C2CCore

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class BridgeTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var state: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = root.appendingPathComponent("project"); state = root.appendingPathComponent("state")
        try AppPaths.ensureDirectory(workspace)
        try "allowed content\n".write(to: workspace.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        try "private\n".write(to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func send(_ bridge: Bridge, path: String, method: String = "GET", json: [String: Any]? = nil, form: [String: String]? = nil, headers: [String: String] = [:]) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bridge.port)\(path)")!, timeoutInterval: 5)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let form {
            request.httpBody = Data(encode(form).utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }
    private func encode(_ fields: [String: String]) -> String {
        var components = URLComponents(); components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func token(_ bridge: Bridge, scopes: String) async throws -> String {
        let callback = "https://chatgpt.com/connector/callback"
        let (registration, clientData) = try await send(bridge, path: "/oauth/register", method: "POST", json: ["redirect_uris": [callback]])
        XCTAssertEqual(registration.statusCode, 201)
        let clientID = try XCTUnwrap(object(clientData)["client_id"] as? String)
        let verifier = String(repeating: "a", count: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let query = encode(["client_id": clientID, "redirect_uri": callback, "response_type": "code", "code_challenge": challenge, "code_challenge_method": "S256", "scope": scopes])
        let (pageResponse, htmlData) = try await send(bridge, path: "/oauth/authorize?" + query)
        XCTAssertEqual(pageResponse.statusCode, 200)
        let html = String(decoding: htmlData, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "name=\"request_id\" value=\"([^\"]+)\"")
        let match = try XCTUnwrap(regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
        let requestID = (html as NSString).substring(with: match.range(at: 1))
        let (_, pairData) = try await send(bridge, path: "/admin/pairing", method: "POST", headers: ["Authorization": "Bearer \(bridge.adminToken)"])
        let pairing = try XCTUnwrap(object(pairData)["code"] as? String)
        let (redirect, _) = try await send(bridge, path: "/oauth/authorize", method: "POST", form: ["request_id": requestID, "pairing_code": pairing])
        XCTAssertEqual(redirect.statusCode, 302)
        let location = try XCTUnwrap(redirect.value(forHTTPHeaderField: "Location"))
        let code = try XCTUnwrap(URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value)
        let (issued, data) = try await send(bridge, path: "/oauth/token", method: "POST", form: ["grant_type": "authorization_code", "code": code, "client_id": clientID, "code_verifier": verifier, "redirect_uri": callback])
        XCTAssertEqual(issued.statusCode, 200)
        return try XCTUnwrap(object(data)["access_token"] as? String)
    }
    func testAuthenticatedMCPRoundTripAndAdminGuard() async throws {
        let bridge = try Bridge(workspaceRoot: workspace.path, stateDirectory: state); try bridge.start(port: 0); defer { bridge.stop() }
        let (unauthorized, _) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        XCTAssertEqual(unauthorized.statusCode, 401); XCTAssertNotNil(unauthorized.value(forHTTPHeaderField: "WWW-Authenticate"))
        for header in ["X-Forwarded-For", "CF-Connecting-IP", "Forwarded", "X-Real-IP"] {
            let (response, _) = try await send(bridge, path: "/admin/info", headers: ["Authorization": "Bearer \(bridge.adminToken)", header: "203.0.113.1"])
            XCTAssertEqual(response.statusCode, 404)
        }
        let access = try await token(bridge, scopes: "workspace.read")
        let headers = ["Authorization": "Bearer \(access)", "Accept": "application/json, text/event-stream"]
        let (initialized, initData) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]], headers: headers)
        XCTAssertEqual(initialized.statusCode, 200); XCTAssertNotNil(try object(initData)["result"])
        let (_, toolsData) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"], headers: headers)
        let tools = try XCTUnwrap((object(toolsData)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 9)
        let (_, readData) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "read_file", "arguments": ["path": "hello.txt"]]], headers: headers)
        XCTAssertTrue(String(decoding: readData, as: UTF8.self).contains("allowed content"))
        let (_, sensitiveData) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "read_file", "arguments": ["path": ".env"]]], headers: headers)
        XCTAssertFalse(String(decoding: sensitiveData, as: UTF8.self).contains("private"))
        XCTAssertTrue(String(decoding: sensitiveData, as: UTF8.self).contains("ACCESS_DENIED"))
        var forged = headers; forged["x-c2c-scopes"] = "git.read workspace.search execution.read"
        let (_, scopeData) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": ["name": "git_status", "arguments": [:]]], headers: forged)
        XCTAssertTrue(String(decoding: scopeData, as: UTF8.self).contains("INSUFFICIENT_SCOPE"))
        let (metadata, metadataData) = try await send(bridge, path: "/.well-known/oauth-authorization-server", headers: ["Host": "attacker.example", "X-Forwarded-Proto": "https"])
        XCTAssertEqual(metadata.statusCode, 200); XCTAssertFalse(String(decoding: metadataData, as: UTF8.self).contains("attacker.example"))
        let (_, revokeData) = try await send(bridge, path: "/admin/revoke-all", method: "POST", headers: ["Authorization": "Bearer \(bridge.adminToken)"])
        XCTAssertNotNil(try object(revokeData)["revoked"])
        let (revoked, _) = try await send(bridge, path: "/mcp", method: "POST", json: ["jsonrpc": "2.0", "id": 7, "method": "ping"], headers: headers)
        XCTAssertEqual(revoked.statusCode, 401)
    }
    func testDuplicateWorkspaceLockAndRuntimeLifecycle() async throws {
        let bridge = try Bridge(workspaceRoot: workspace.path, stateDirectory: state); try bridge.start(port: 0); defer { bridge.stop() }
        let other = try Bridge(workspaceRoot: workspace.path, stateDirectory: state)
        XCTAssertThrowsError(try other.start(port: 0))
        let observed = await Daemon.observation(workspaceID: bridge.workspace.id, stateDirectory: state)
        XCTAssertEqual(observed.state, "healthy")
        let file = state.appendingPathComponent("runtime/\(bridge.workspace.id).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        other.stop(); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        bridge.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testUncertainRuntimeDoesNotKillOrRestartUnrelatedProcess() async throws {
        let workspace = try Workspace(root: workspace.path)
        let file = state.appendingPathComponent("runtime/\(workspace.id).json")
        try AppPaths.writeJSON(["workspaceId": workspace.id, "port": 1, "pid": ProcessInfo.processInfo.processIdentifier, "adminToken": "fake"], to: file)
        let observed = await Daemon.observation(workspaceID: workspace.id, stateDirectory: state)
        XCTAssertEqual(observed.state, "unknown")
        do { _ = try await Daemon.stop(workspaceID: workspace.id, stateDirectory: state); XCTFail("Must not stop unknown process") } catch {}
        do { _ = try await Daemon.ensure(workspace: workspace, stateDirectory: state, executable: "/usr/bin/false"); XCTFail("Must not start duplicate") } catch {}
    }
}
