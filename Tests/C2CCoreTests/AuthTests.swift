import CryptoKit
import Foundation
import XCTest
@testable import C2CCore

final class AuthTests: XCTestCase {
    private let baseURL = "https://bridge.example.test"
    private let redirectURI = "http://127.0.0.1:19876/callback"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testDiscoveryRegistrationPairingPKCEAndBearerFlow() throws {
        let service = try makeService()
        let metadata = try json(service.handle(request("GET", "/.well-known/oauth-authorization-server"), baseURL: baseURL))
        XCTAssertEqual(metadata["authorization_endpoint"] as? String, "\(baseURL)/oauth/authorize")
        XCTAssertEqual(metadata["code_challenge_methods_supported"] as? [String], ["S256"])

        let clientID = try register(service)
        let verifier = "a-secure-pkce-verifier-with-more-than-43-characters-12345"
        let challenge = pkce(verifier)
        let pairing = service.createPairing()
        let pairingCode = try XCTUnwrap(pairing["code"] as? String)
        XCTAssertNotNil(pairingCode.range(of: "^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$", options: .regularExpression))
        XCTAssertTrue(service.pairingActive)

        let code = try authorize(service, clientID: clientID, challenge: challenge, pairingCode: pairingCode)
        XCTAssertFalse(service.pairingActive)
        let tokenResponse = try exchange(service, clientID: clientID, code: code, verifier: verifier)
        XCTAssertEqual(tokenResponse.status, 200)
        let tokenJSON = try json(tokenResponse)
        let access = try XCTUnwrap(tokenJSON["access_token"] as? String)
        XCTAssertTrue(access.hasPrefix("c2c_at_"))
        XCTAssertTrue((tokenJSON["refresh_token"] as? String)?.hasPrefix("c2c_rt_") == true)
        XCTAssertNil(service.authorize(
            request("POST", "/mcp", headers: ["Authorization": "Bearer \(access)"]),
            baseURL: baseURL
        ))
        XCTAssertEqual(
            service.scopes(for: request("POST", "/mcp", headers: ["Authorization": "Bearer \(access)"])),
            ["workspace.read", "workspace.search", "git.read", "execution.read", "offline_access"]
        )
        XCTAssertEqual(service.tokenCount, 2)
    }

    func testPairingIsSingleUseAndWrongAttemptsAreLimited() throws {
        let service = try makeService()
        let clientID = try register(service)
        let challenge = pkce("another-verifier-value-that-is-long-enough-for-pkce-123")
        let pairingCode = try XCTUnwrap(service.createPairing()["code"] as? String)

        let pending = try pendingRequestID(service, clientID: clientID, challenge: challenge)
        for expectedRemaining in stride(from: 4, through: 1, by: -1) {
            let response = service.handle(
                formRequest("/oauth/authorize", ["request_id": pending, "pairing_code": "AAAA-AAAA"]),
                baseURL: baseURL
            )
            XCTAssertEqual(response?.status, 401)
            XCTAssertTrue(String(decoding: response?.body ?? Data(), as: UTF8.self).contains("\(expectedRemaining) attempts left"))
        }
        let exhausted = service.handle(
            formRequest("/oauth/authorize", ["request_id": pending, "pairing_code": "BBBB-BBBB"]),
            baseURL: baseURL
        )
        XCTAssertEqual(exhausted?.status, 410)
        XCTAssertTrue(String(decoding: exhausted?.body ?? Data(), as: UTF8.self).contains("Too many incorrect attempts"))
        XCTAssertFalse(service.pairingActive)

        let fresh = try XCTUnwrap(service.createPairing()["code"] as? String)
        let firstCode = try authorize(service, clientID: clientID, challenge: challenge, pairingCode: fresh)
        XCTAssertFalse(firstCode.isEmpty)
        let secondPending = try pendingRequestID(service, clientID: clientID, challenge: challenge)
        let reused = service.handle(
            formRequest("/oauth/authorize", ["request_id": secondPending, "pairing_code": fresh]),
            baseURL: baseURL
        )
        XCTAssertEqual(reused?.status, 410)
        XCTAssertTrue(String(decoding: reused?.body ?? Data(), as: UTF8.self).contains("No active pairing session"))
        XCTAssertNotEqual(pairingCode, fresh)
    }

    func testAuthorizationCodesAreConsumedAndPKCEIsRequired() throws {
        let service = try makeService()
        let clientID = try register(service)
        let verifier = "the-correct-verifier-that-is-long-enough-to-be-used-here"
        let challenge = pkce(verifier)

        let missingPKCE = service.handle(
            request("GET", "/oauth/authorize", query: [
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "response_type": "code",
                "state": "round-trip",
            ]),
            baseURL: baseURL
        )
        XCTAssertEqual(missingPKCE?.status, 302)
        XCTAssertTrue(header(missingPKCE, "location")?.contains("error=invalid_request") == true)
        XCTAssertTrue(header(missingPKCE, "location")?.contains("state=round-trip") == true)

        let pairingCode = try XCTUnwrap(service.createPairing()["code"] as? String)
        let code = try authorize(service, clientID: clientID, challenge: challenge, pairingCode: pairingCode)
        let mismatch = try exchange(service, clientID: clientID, code: code, verifier: String(repeating: "x", count: 43))
        XCTAssertEqual(mismatch.status, 400)
        XCTAssertEqual(try json(mismatch)["error"] as? String, "invalid_grant")
        let replay = try exchange(service, clientID: clientID, code: code, verifier: verifier)
        XCTAssertEqual(replay.status, 400)
        XCTAssertEqual(try json(replay)["error"] as? String, "invalid_grant")
    }

    func testRefreshRotationRejectsReplayAndRevocationWorks() throws {
        let service = try makeService()
        let clientID = try register(service)
        let verifier = "refresh-rotation-verifier-that-has-sufficient-entropy-123"
        let code = try authorize(
            service,
            clientID: clientID,
            challenge: pkce(verifier),
            pairingCode: try XCTUnwrap(service.createPairing()["code"] as? String),
            resource: "\(baseURL)/mcp"
        )
        let initial = try json(exchange(service, clientID: clientID, code: code, verifier: verifier))
        let oldRefresh = try XCTUnwrap(initial["refresh_token"] as? String)

        let rotatedResponse = try XCTUnwrap(service.handle(
            formRequest("/oauth/token", [
                "grant_type": "refresh_token",
                "refresh_token": oldRefresh,
                "client_id": clientID,
            ]),
            baseURL: baseURL
        ))
        XCTAssertEqual(rotatedResponse.status, 200)
        let rotated = try json(rotatedResponse)
        XCTAssertNotEqual(rotated["refresh_token"] as? String, oldRefresh)
        let rotatedAccess = try XCTUnwrap(rotated["access_token"] as? String)
        XCTAssertNil(service.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(rotatedAccess)"]),
            baseURL: baseURL
        ))

        let replay = try XCTUnwrap(service.handle(
            formRequest("/oauth/token", [
                "grant_type": "refresh_token",
                "refresh_token": oldRefresh,
                "client_id": clientID,
            ]),
            baseURL: baseURL
        ))
        XCTAssertEqual(replay.status, 400)
        XCTAssertEqual(try json(replay)["error"] as? String, "invalid_grant")
        XCTAssertEqual(service.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(rotatedAccess)"]),
            baseURL: baseURL
        )?.status, 401)

        let freshVerifier = "fresh-revocation-verifier-that-is-long-enough-123456"
        let freshCode = try authorize(
            service,
            clientID: clientID,
            challenge: pkce(freshVerifier),
            pairingCode: try XCTUnwrap(service.createPairing()["code"] as? String)
        )
        let freshAccess = try XCTUnwrap(
            try json(exchange(service, clientID: clientID, code: freshCode, verifier: freshVerifier))["access_token"] as? String
        )
        XCTAssertNil(service.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(freshAccess)"]),
            baseURL: baseURL
        ))
        let revoke = service.handle(
            formRequest("/oauth/revoke", ["token": freshAccess]),
            baseURL: baseURL
        )
        XCTAssertEqual(revoke?.status, 200)
        XCTAssertEqual(service.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(freshAccess)"]),
            baseURL: baseURL
        )?.status, 401)
    }

    func testStatePersistsOnlyHashesAndWorkspaceBindingIsEnforced() throws {
        let directory = temporaryDirectory()
        var service: AuthService? = try AuthService(
            workspaceID: "workspace-a",
            workspaceName: "Workspace A",
            stateDirectory: directory
        )
        let clientID = try register(try XCTUnwrap(service))
        let verifier = "persistence-verifier-that-is-long-enough-for-this-test"
        let code = try authorize(
            try XCTUnwrap(service),
            clientID: clientID,
            challenge: pkce(verifier),
            pairingCode: try XCTUnwrap(service?.createPairing()["code"] as? String)
        )
        let issued = try json(exchange(try XCTUnwrap(service), clientID: clientID, code: code, verifier: verifier))
        let access = try XCTUnwrap(issued["access_token"] as? String)
        let refresh = try XCTUnwrap(issued["refresh_token"] as? String)
        service = nil

        let stateFile = directory.appendingPathComponent("auth/workspace-a.json")
        let stateText = try String(contentsOf: stateFile)
        XCTAssertFalse(stateText.contains(access))
        XCTAssertFalse(stateText.contains(refresh))
        let permissions = try FileManager.default.attributesOfItem(atPath: stateFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? -1, 0o600)

        let restored = try AuthService(
            workspaceID: "workspace-a",
            workspaceName: "Workspace A",
            stateDirectory: directory
        )
        XCTAssertNil(restored.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(access)"]),
            baseURL: baseURL
        ))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stateText.utf8)) as? [String: Any])
        var records = try XCTUnwrap(object["tokens"] as? [[String: Any]])
        let accessHash = SHA256.hash(data: Data(access.utf8)).map { String(format: "%02x", $0) }.joined()
        let accessIndex = try XCTUnwrap(records.firstIndex { $0["hash"] as? String == accessHash })
        records[accessIndex]["workspaceId"] = "workspace-b"
        object["tokens"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: stateFile, options: .atomic)
        let foreign = try AuthService(
            workspaceID: "workspace-a",
            workspaceName: "Workspace A",
            stateDirectory: directory
        )
        let response = foreign.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(access)"]),
            baseURL: baseURL
        )
        XCTAssertEqual(response?.status, 403)
        XCTAssertNil(foreign.scopes(for: request(
            "POST", "/mcp", headers: ["authorization": "Bearer \(access)"]
        )))
    }

    func testRedirectValidationHTMLSecurityAndEscaping() throws {
        let service = try AuthService(
            workspaceID: "html-workspace",
            workspaceName: "<script>alert('xss')</script>",
            stateDirectory: temporaryDirectory()
        )
        let rejected = service.handle(
            jsonRequest("/oauth/register", ["redirect_uris": ["http://evil.example.com/callback"]]),
            baseURL: baseURL
        )
        XCTAssertEqual(rejected?.status, 400)
        XCTAssertEqual(try json(rejected)["error"] as? String, "invalid_redirect_uri")
        for invalid in [
            "https://user@example.com/callback",
            "https://example.com/callback#fragment",
        ] {
            let response = service.handle(
                jsonRequest("/oauth/register", ["redirect_uris": [invalid]]),
                baseURL: baseURL
            )
            XCTAssertEqual(response?.status, 400)
        }
        let tooManyRedirects = service.handle(
            jsonRequest("/oauth/register", [
                "redirect_uris": (0..<17).map { "https://example.com/callback/\($0)" },
            ]),
            baseURL: baseURL
        )
        XCTAssertEqual(tooManyRedirects?.status, 400)

        let clientID = try register(service)
        let response = service.handle(
            request("GET", "/oauth/authorize", query: [
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "response_type": "code",
                "code_challenge": pkce("some-verifier-value-used-for-rendering-the-page-123"),
                "code_challenge_method": "S256",
            ]),
            baseURL: baseURL
        )
        XCTAssertEqual(response?.status, 200)
        let html = String(decoding: response?.body ?? Data(), as: UTF8.self)
        XCTAssertFalse(html.contains("<script>alert('xss')</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"))
        XCTAssertEqual(
            header(response, "content-security-policy"),
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https:; base-uri 'none'; frame-ancestors 'none'"
        )
        XCTAssertEqual(header(response, "x-frame-options"), "DENY")
        XCTAssertEqual(header(response, "cache-control"), "no-store, max-age=0")
    }

    func testUnknownScopesResourceAudienceAndJSONTokenRequestAreChecked() throws {
        let service = try makeService()
        let clientID = try register(service)
        let challenge = pkce("resource-audience-verifier-that-is-long-enough-12345")
        let common = [
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ]

        var unknownScope = common
        unknownScope["scope"] = "workspace.read workspace.write"
        let invalidScope = service.handle(request("GET", "/oauth/authorize", query: unknownScope), baseURL: baseURL)
        XCTAssertEqual(invalidScope?.status, 302)
        XCTAssertTrue(header(invalidScope, "location")?.contains("error=invalid_scope") == true)

        var wrongResource = common
        wrongResource["resource"] = "https://another.example.test/mcp"
        let invalidTarget = service.handle(request("GET", "/oauth/authorize", query: wrongResource), baseURL: baseURL)
        XCTAssertEqual(invalidTarget?.status, 302)
        XCTAssertTrue(header(invalidTarget, "location")?.contains("error=invalid_target") == true)

        let verifier = "json-token-request-verifier-that-is-long-enough-123456"
        let code = try authorize(
            service,
            clientID: clientID,
            challenge: pkce(verifier),
            pairingCode: try XCTUnwrap(service.createPairing()["code"] as? String),
            resource: "\(baseURL)/mcp"
        )
        let response = service.handle(
            jsonRequest("/oauth/token", [
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "client_id": clientID,
                "redirect_uri": redirectURI,
            ]),
            baseURL: baseURL
        )
        XCTAssertEqual(response?.status, 200)
        let access = try XCTUnwrap(try json(response)["access_token"] as? String)
        XCTAssertEqual(service.authorize(
            request("POST", "/mcp", headers: ["authorization": "Bearer \(access)"]),
            baseURL: "https://replacement.example.test"
        )?.status, 403)
    }

    // MARK: - Helpers

    private func makeService() throws -> AuthService {
        try AuthService(workspaceID: "workspace-a", workspaceName: "Workspace A", stateDirectory: temporaryDirectory())
    }

    private func temporaryDirectory() -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("c2c-auth-tests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(value)
        return value
    }

    private func register(_ service: AuthService) throws -> String {
        let response = service.handle(
            jsonRequest("/oauth/register", ["client_name": "Test Client", "redirect_uris": [redirectURI]]),
            baseURL: baseURL
        )
        XCTAssertEqual(response?.status, 201)
        return try XCTUnwrap(try json(response)["client_id"] as? String)
    }

    private func pendingRequestID(
        _ service: AuthService,
        clientID: String,
        challenge: String,
        resource: String? = nil
    ) throws -> String {
        var query = [
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "state": "state-value",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "scope": "workspace.read workspace.search git.read execution.read offline_access",
        ]
        if let resource { query["resource"] = resource }
        let page = service.handle(
            request("GET", "/oauth/authorize", query: query),
            baseURL: baseURL
        )
        XCTAssertEqual(page?.status, 200)
        let html = String(decoding: page?.body ?? Data(), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "name=\\\"request_id\\\" value=\\\"([a-f0-9]+)\\\"")
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let match = try XCTUnwrap(expression.firstMatch(in: html, range: range))
        let capture = try XCTUnwrap(Range(match.range(at: 1), in: html))
        return String(html[capture])
    }

    private func authorize(
        _ service: AuthService,
        clientID: String,
        challenge: String,
        pairingCode: String,
        resource: String? = nil
    ) throws -> String {
        let requestID = try pendingRequestID(
            service,
            clientID: clientID,
            challenge: challenge,
            resource: resource
        )
        let response = service.handle(
            formRequest("/oauth/authorize", ["request_id": requestID, "pairing_code": pairingCode]),
            baseURL: baseURL
        )
        XCTAssertEqual(response?.status, 302)
        let location = try XCTUnwrap(header(response, "location"))
        let components = try XCTUnwrap(URLComponents(string: location))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "state" })?.value, "state-value")
        return try XCTUnwrap(components.queryItems?.first(where: { $0.name == "code" })?.value)
    }

    private func exchange(_ service: AuthService, clientID: String, code: String, verifier: String) throws -> HTTPResponse {
        try XCTUnwrap(service.handle(
            formRequest("/oauth/token", [
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "client_id": clientID,
                "redirect_uri": redirectURI,
            ]),
            baseURL: baseURL
        ))
    }

    private func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data(),
        remoteAddress: String = "127.0.0.1"
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: query, headers: headers, body: body, remoteAddress: remoteAddress)
    }

    private func jsonRequest(_ path: String, _ value: [String: Any]) -> HTTPRequest {
        request(
            "POST",
            path,
            headers: ["content-type": "application/json"],
            body: try! JSONSerialization.data(withJSONObject: value)
        )
    }

    private func formRequest(_ path: String, _ value: [String: String]) -> HTTPRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = value.sorted { $0.key < $1.key }.map { key, field in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)! )=\(field.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return request(
            "POST",
            path,
            headers: ["content-type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
    }

    private func json(_ response: HTTPResponse?) throws -> [String: Any] {
        let response = try XCTUnwrap(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func header(_ response: HTTPResponse?, _ name: String) -> String? {
        response?.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func pkce(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
