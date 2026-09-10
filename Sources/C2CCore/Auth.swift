import CryptoKit
import Foundation
import Security

public final class AuthService: @unchecked Sendable {
    private static let supportedScopes = [
        "workspace.read",
        "workspace.search",
        "git.read",
        "execution.read",
        "offline_access",
    ]

    private static let accessTokenTTL: TimeInterval = 60 * 60
    private static let refreshTokenTTL: TimeInterval = 30 * 24 * 60 * 60
    private static let authorizationCodeTTL: TimeInterval = 5 * 60
    private static let pendingRequestTTL: TimeInterval = 10 * 60
    private static let pairingTTL: TimeInterval = 5 * 60
    private static let pairingAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789".utf8)

    private struct ClientRegistration: Codable {
        var clientId: String
        var clientName: String?
        var redirectUris: [String]
        var createdAt: String
    }

    private struct TokenRecord: Codable {
        enum Kind: String, Codable { case access, refresh }

        var hash: String
        var kind: Kind
        var clientId: String
        var workspaceId: String
        var scopes: [String]
        var familyId: String?
        var resource: String?
        var issuedAt: Double
        var expiresAt: Double
        var revoked: Bool
    }

    private struct PersistedState: Codable {
        var clients: [ClientRegistration]
        var tokens: [TokenRecord]
        var refreshReplays: [RefreshReplayRecord]?
    }

    private struct RefreshReplayRecord: Codable {
        var hash: String
        var familyId: String
        var expiresAt: Double
    }

    private struct PendingAuthorization {
        var id: String
        var clientId: String
        var redirectUri: String
        var scopes: [String]
        var state: String?
        var codeChallenge: String
        var resource: String?
        var expiresAt: Double
    }

    private struct AuthorizationCode {
        var clientId: String
        var redirectUri: String
        var codeChallenge: String
        var scopes: [String]
        var workspaceId: String
        var pairingSessionId: String
        var resource: String?
        var expiresAt: Double
    }

    private struct PairingSession {
        var id: String
        var codeHash: Data
        var expiresAt: Double
        var attemptsLeft: Int
    }

    private struct RateWindow {
        var count: Int
        var resetAt: Double
    }

    private enum PairingResult {
        case accepted(sessionID: String)
        case rejected(reason: String, attemptsLeft: Int? = nil)
    }

    private let workspaceID: String
    private let workspaceName: String
    private let authDirectory: URL
    private let stateFile: URL
    private let lock = NSLock()

    private var clients: [String: ClientRegistration] = [:]
    private var tokens: [String: TokenRecord] = [:]
    private var authorizationCodes: [String: AuthorizationCode] = [:]
    private var pendingAuthorizations: [String: PendingAuthorization] = [:]
    private var pairingSession: PairingSession?
    private var rateWindows: [String: RateWindow] = [:]
    private var publicRateWindows: [String: RateWindow] = [:]
    private var refreshReplays: [String: RefreshReplayRecord] = [:]

    public init(workspaceID: String, workspaceName: String, stateDirectory: URL) throws {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        authDirectory = stateDirectory.appendingPathComponent("auth", isDirectory: true)
        stateFile = authDirectory.appendingPathComponent("\(workspaceID).json")

        try FileManager.default.createDirectory(
            at: authDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authDirectory.path)

        if FileManager.default.fileExists(atPath: stateFile.path) {
            let data = try Data(contentsOf: stateFile)
            let persisted = try JSONDecoder().decode(PersistedState.self, from: data)
            let now = Self.nowMilliseconds
            clients = Dictionary(uniqueKeysWithValues: persisted.clients.map { ($0.clientId, $0) })
            tokens = Dictionary(uniqueKeysWithValues: persisted.tokens.compactMap {
                (!$0.revoked && $0.expiresAt > now) ? ($0.hash, $0) : nil
            })
            refreshReplays = Dictionary(uniqueKeysWithValues: (persisted.refreshReplays ?? []).compactMap {
                $0.expiresAt > now ? ($0.hash, $0) : nil
            })
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        }
    }

    public func handle(_ request: HTTPRequest, baseURL: String) -> HTTPResponse? {
        switch (request.method.uppercased(), request.path) {
        case ("GET", "/.well-known/oauth-authorization-server"),
             ("GET", "/.well-known/oauth-authorization-server/mcp"),
             ("GET", "/.well-known/openid-configuration"):
            return .json(authorizationServerMetadata(baseURL: baseURL))
        case ("GET", "/.well-known/oauth-protected-resource"),
             ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return .json(protectedResourceMetadata(baseURL: baseURL))
        case ("POST", "/oauth/register"):
            return register(request)
        case ("GET", "/oauth/authorize"):
            return beginAuthorization(request, baseURL: baseURL)
        case ("POST", "/oauth/authorize"):
            return finishAuthorization(request)
        case ("POST", "/oauth/token"):
            return token(request)
        case ("POST", "/oauth/revoke"):
            return revoke(request)
        default:
            return nil
        }
    }

    /// Validates the bearer token for a protected workspace request.
    /// A nil response means authorization succeeded.
    public func authorize(_ request: HTTPRequest, baseURL: String) -> HTTPResponse? {
        let challenge: (String, String) -> String = { error, description in
            "Bearer realm=\"c2c\", error=\"\(error)\", error_description=\"\(description)\", " +
                "resource_metadata=\"\(baseURL)/.well-known/oauth-protected-resource/mcp\""
        }
        guard let header = request.headers["authorization"],
              header.lowercased().hasPrefix("bearer ") else {
            return .json(
                ["error": "unauthorized", "error_description": "Authentication required"],
                status: 401,
                headers: ["www-authenticate": challenge("invalid_token", "Missing bearer token")]
            )
        }

        let bearer = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict: (record: TokenRecord?, reason: String) = withLock {
            guard let record = tokens[Self.sha256Hex(bearer)] else { return (nil, "unknown") }
            guard record.kind == .access else { return (nil, "wrong_kind") }
            guard !record.revoked else { return (nil, "revoked") }
            guard Self.nowMilliseconds <= record.expiresAt else { return (nil, "expired") }
            return (record, "")
        }
        guard let record = verdict.record else {
            return .json(
                ["error": "unauthorized", "error_description": "Token \(verdict.reason)"],
                status: 401,
                headers: ["www-authenticate": challenge("invalid_token", "Token \(verdict.reason)")]
            )
        }
        guard record.workspaceId == workspaceID else {
            return .json(
                [
                    "error": "forbidden",
                    "error_description": "This token is not authorized for the connected workspace",
                ],
                status: 403
            )
        }
        if let resource = record.resource, resource != "\(baseURL)/mcp" {
            return .json(
                ["error": "forbidden", "error_description": "Token audience does not match this resource"],
                status: 403
            )
        }
        return nil
    }

    /// Returns the trusted scopes bound to a valid access token for this workspace.
    /// Callers must ignore any scope headers supplied by the remote client.
    public func scopes(for request: HTTPRequest) -> [String]? {
        guard let header = request.headers["authorization"],
              header.lowercased().hasPrefix("bearer ") else { return nil }
        let bearer = String(header.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return withLock {
            guard let record = tokens[Self.sha256Hex(bearer)],
                  record.kind == .access,
                  !record.revoked,
                  Self.nowMilliseconds <= record.expiresAt,
                  record.workspaceId == workspaceID else { return nil }
            return record.scopes
        }
    }

    public func createPairing() -> [String: Any] {
        withLock {
            let raw = Self.generatePairingCode()
            let now = Self.nowMilliseconds
            let session = PairingSession(
                id: Self.randomHex(byteCount: 16),
                codeHash: Self.sha256(Data(raw.utf8)),
                expiresAt: now + Self.pairingTTL * 1_000,
                attemptsLeft: 5
            )
            pairingSession = session
            return [
                "sessionId": session.id,
                "code": "\(raw.prefix(4))-\(raw.dropFirst(4))",
                "expiresAt": session.expiresAt,
            ]
        }
    }

    public func revokeAll() throws -> Int {
        try withLock {
            let count = tokens.count
            let previousTokens = tokens
            let previousCodes = authorizationCodes
            let previousPairing = pairingSession
            let previousReplays = refreshReplays
            tokens.removeAll()
            authorizationCodes.removeAll()
            pairingSession = nil
            refreshReplays.removeAll()
            do {
                try saveLocked()
            } catch {
                tokens = previousTokens
                authorizationCodes = previousCodes
                pairingSession = previousPairing
                refreshReplays = previousReplays
                throw error
            }
            return count
        }
    }

    public var tokenCount: Int { withLock { tokens.count } }

    public var pairingActive: Bool {
        withLock {
            guard let pairingSession else { return false }
            return Self.nowMilliseconds <= pairingSession.expiresAt
        }
    }

    // MARK: - OAuth endpoints

    private func authorizationServerMetadata(baseURL: String) -> [String: Any] {
        [
            "issuer": baseURL,
            "authorization_endpoint": "\(baseURL)/oauth/authorize",
            "token_endpoint": "\(baseURL)/oauth/token",
            "registration_endpoint": "\(baseURL)/oauth/register",
            "revocation_endpoint": "\(baseURL)/oauth/revoke",
            "response_types_supported": ["code"],
            "response_modes_supported": ["query"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": Self.supportedScopes,
        ]
    }

    private func protectedResourceMetadata(baseURL: String) -> [String: Any] {
        [
            "resource": "\(baseURL)/mcp",
            "authorization_servers": [baseURL],
            "scopes_supported": Self.supportedScopes,
            "bearer_methods_supported": ["header"],
            "resource_name": "Codex with ChatGPT",
        ]
    }

    private func register(_ request: HTTPRequest) -> HTTPResponse {
        guard allowPublicRequest(request.remoteAddress, namespace: "register", limit: 30) else {
            return .json(["error": "rate_limited"], status: 429)
        }
        let body: [String: Any]
        do {
            body = try request.json()
        } catch {
            return .json(["error": "invalid_request"], status: 400)
        }
        guard let redirectURIs = body["redirect_uris"] as? [String],
              !redirectURIs.isEmpty,
              redirectURIs.count <= 16,
              redirectURIs.allSatisfy({ $0.utf8.count <= 2_048 }),
              redirectURIs.allSatisfy(Self.isAllowedRedirectURI) else {
            return .json(
                [
                    "error": "invalid_redirect_uri",
                    "error_description": "redirect_uris must be https URLs (or http://localhost for development)",
                ],
                status: 400
            )
        }
        let clientName = (body["client_name"] as? String).map { String($0.prefix(200)) }

        do {
            let client = try withLock { () throws -> ClientRegistration in
                guard clients.count < 1_000 else { throw C2CError("OAuth client registration limit reached") }
                let registration = ClientRegistration(
                    clientId: "c2c_client_\(Self.randomBase64URL(byteCount: 12))",
                    clientName: clientName,
                    redirectUris: redirectURIs,
                    createdAt: ISO8601DateFormatter().string(from: Date())
                )
                clients[registration.clientId] = registration
                do {
                    try saveLocked()
                } catch {
                    clients.removeValue(forKey: registration.clientId)
                    throw error
                }
                return registration
            }
            var response: [String: Any] = [
                "client_id": client.clientId,
                "redirect_uris": client.redirectUris,
                "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
            ]
            if let clientName = client.clientName { response["client_name"] = clientName }
            return .json(response, status: 201)
        } catch {
            return .json(["error": "server_error"], status: 500)
        }
    }

    private func beginAuthorization(_ request: HTTPRequest, baseURL: String) -> HTTPResponse {
        withLock {
            pruneTransientLocked()
            guard allowPublicRequestLocked(request.remoteAddress, namespace: "authorize", limit: 60),
                  pendingAuthorizations.count < 1_000 else {
                return .json(["error": "rate_limited"], status: 429)
            }
            let query = request.query
            guard let clientID = query["client_id"], let client = clients[clientID] else {
                return secureHTML("Unknown client. Please reconnect from ChatGPT.", status: 400)
            }
            guard let redirectURI = query["redirect_uri"], client.redirectUris.contains(redirectURI) else {
                return secureHTML("Invalid redirect_uri.", status: 400)
            }
            guard query["response_type"] == "code" else {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "unsupported_response_type",
                        description: "Only response_type=code is supported",
                        state: query["state"]
                    )
                )
            }
            guard let challenge = query["code_challenge"], query["code_challenge_method"] == "S256" else {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "invalid_request",
                        description: "PKCE with S256 is required",
                        state: query["state"]
                    )
                )
            }
            guard (query["state"]?.utf8.count ?? 0) <= 2_048,
                  (query["resource"]?.utf8.count ?? 0) <= 2_048,
                  (query["scope"]?.utf8.count ?? 0) <= 1_024 else {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "invalid_request",
                        description: "authorization parameter is too large",
                        state: nil
                    )
                )
            }

            guard Self.isValidPKCEChallenge(challenge) else {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "invalid_request",
                        description: "code_challenge must be an S256 base64url value",
                        state: query["state"]
                    )
                )
            }
            if let resource = query["resource"], resource != "\(baseURL)/mcp" {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "invalid_target",
                        description: "resource does not match this workspace bridge",
                        state: query["state"]
                    )
                )
            }
            guard let scopes = Self.filterScopes(query["scope"]) else {
                return redirect(
                    redirectURI,
                    items: Self.oauthErrorItems(
                        error: "invalid_scope",
                        description: "One or more requested scopes are not supported",
                        state: query["state"]
                    )
                )
            }

            let pending = PendingAuthorization(
                id: Self.randomHex(byteCount: 16),
                clientId: clientID,
                redirectUri: redirectURI,
                scopes: scopes,
                state: query["state"],
                codeChallenge: challenge,
                resource: query["resource"],
                expiresAt: Self.nowMilliseconds + Self.pendingRequestTTL * 1_000
            )
            pendingAuthorizations[pending.id] = pending
            return secureHTML(pairingPage(requestID: pending.id, scopes: pending.scopes), status: 200)
        }
    }

    private func finishAuthorization(_ request: HTTPRequest) -> HTTPResponse {
        withLock {
            pruneTransientLocked()
            let form = request.form()
            guard let requestID = form["request_id"], let pending = pendingAuthorizations[requestID] else {
                return secureHTML(
                    "This authorization request has expired. Please reconnect from ChatGPT.",
                    status: 400
                )
            }
            switch verifyPairingLocked(form["pairing_code"] ?? "", remoteAddress: request.remoteAddress) {
            case let .rejected(reason, attemptsLeft):
                let message: String
                switch reason {
                case "invalid":
                    message = "Incorrect pairing code." + (attemptsLeft.map { " \($0) attempts left." } ?? "")
                case "expired":
                    message = "This pairing code has expired. Ask Codex to generate a new one."
                case "too_many_attempts":
                    message = "Too many incorrect attempts. Ask Codex to generate a new pairing code."
                case "rate_limited":
                    message = "Too many attempts. Please wait a minute and try again."
                default:
                    message = "No active pairing session. Ask Codex to generate a pairing code."
                }
                return secureHTML(
                    pairingPage(requestID: pending.id, scopes: pending.scopes, error: message),
                    status: reason == "invalid" ? 401 : 410
                )
            case let .accepted(sessionID):
                pendingAuthorizations.removeValue(forKey: pending.id)
                let code = "c2c_ac_\(Self.randomBase64URL(byteCount: 32))"
                authorizationCodes[code] = AuthorizationCode(
                    clientId: pending.clientId,
                    redirectUri: pending.redirectUri,
                    codeChallenge: pending.codeChallenge,
                    scopes: pending.scopes,
                    workspaceId: workspaceID,
                    pairingSessionId: sessionID,
                    resource: pending.resource,
                    expiresAt: Self.nowMilliseconds + Self.authorizationCodeTTL * 1_000
                )
                var items = [URLQueryItem(name: "code", value: code)]
                if let state = pending.state { items.append(URLQueryItem(name: "state", value: state)) }
                return redirect(pending.redirectUri, items: items)
            }
        }
    }

    private func token(_ request: HTTPRequest) -> HTTPResponse {
        let body = fields(request)
        switch body["grant_type"] {
        case "authorization_code":
            guard let code = body["code"], let verifier = body["code_verifier"],
                  let clientID = body["client_id"], let redirectURI = body["redirect_uri"],
                  Self.isValidPKCEVerifier(verifier) else {
                return .json(["error": "invalid_request"], status: 400)
            }
            return withLock {
                guard let record = authorizationCodes.removeValue(forKey: code),
                      Self.nowMilliseconds <= record.expiresAt,
                      record.clientId == clientID else {
                    return .json(["error": "invalid_grant"], status: 400)
                }
                if redirectURI != record.redirectUri {
                    return .json(
                        ["error": "invalid_grant", "error_description": "redirect_uri mismatch"],
                        status: 400
                    )
                }
                guard Self.constantTimeEqual(Self.pkceChallenge(verifier), record.codeChallenge) else {
                    return .json(
                        ["error": "invalid_grant", "error_description": "PKCE verification failed"],
                        status: 400
                    )
                }
                do {
                    let issued = try issueTokensLocked(
                        clientID: clientID,
                        scopes: record.scopes,
                        resource: record.resource
                    )
                    return tokenResponse(issued)
                } catch {
                    return .json(["error": "server_error"], status: 500)
                }
            }
        case "refresh_token":
            guard let refreshToken = body["refresh_token"], let clientID = body["client_id"] else {
                return .json(["error": "invalid_request"], status: 400)
            }
            return withLock {
                let hash = Self.sha256Hex(refreshToken)
                if let replay = refreshReplays[hash] {
                    let previousTokens = tokens
                    tokens = tokens.filter { $0.value.familyId != replay.familyId }
                    do {
                        try saveLocked()
                    } catch {
                        tokens = previousTokens
                        return .json(["error": "server_error"], status: 500)
                    }
                    return .json(
                        ["error": "invalid_grant", "error_description": "refresh token replay detected"],
                        status: 400
                    )
                }
                guard let record = tokens[hash], record.kind == .refresh,
                      !record.revoked, Self.nowMilliseconds <= record.expiresAt else {
                    return .json(["error": "invalid_grant"], status: 400)
                }
                guard record.clientId == clientID else {
                    return .json(["error": "invalid_client"], status: 400)
                }
                let previousTokens = tokens
                let previousReplays = refreshReplays
                tokens.removeValue(forKey: hash)
                let familyID = record.familyId ?? Self.randomHex(byteCount: 16)
                refreshReplays[hash] = RefreshReplayRecord(
                    hash: hash,
                    familyId: familyID,
                    expiresAt: record.expiresAt
                )
                do {
                    let issued = try issueTokensLocked(
                        clientID: clientID,
                        scopes: record.scopes,
                        workspaceID: record.workspaceId,
                        familyID: familyID,
                        resource: record.resource
                    )
                    return tokenResponse(issued)
                } catch {
                    tokens = previousTokens
                    refreshReplays = previousReplays
                    return .json(["error": "server_error"], status: 500)
                }
            }
        default:
            return .json(["error": "unsupported_grant_type"], status: 400)
        }
    }

    private func revoke(_ request: HTTPRequest) -> HTTPResponse {
        let body = fields(request)
        if let token = body["token"] {
            let saved = withLock { () -> Bool in
                let previousTokens = tokens
                tokens.removeValue(forKey: Self.sha256Hex(token))
                do {
                    try saveLocked()
                    return true
                } catch {
                    tokens = previousTokens
                    return false
                }
            }
            if !saved { return .json(["error": "server_error"], status: 500) }
        }
        return .json([String: Any]())
    }

    // MARK: - Pairing and token storage

    private func verifyPairingLocked(_ input: String, remoteAddress: String) -> PairingResult {
        let now = Self.nowMilliseconds
        if !remoteAddress.isEmpty {
            var window = rateWindows[remoteAddress]
            if window == nil || now > window!.resetAt {
                window = RateWindow(count: 1, resetAt: now + 60_000)
            } else {
                window!.count += 1
            }
            rateWindows[remoteAddress] = window
            if window!.count > 10 { return .rejected(reason: "rate_limited") }
        }

        guard var session = pairingSession else { return .rejected(reason: "no_active_session") }
        if now > session.expiresAt {
            pairingSession = nil
            return .rejected(reason: "expired")
        }
        let normalized = input.uppercased().unicodeScalars.compactMap { scalar -> UInt8? in
            guard scalar.isASCII else { return nil }
            let value = UInt8(scalar.value)
            return ((65...90).contains(value) || (50...57).contains(value)) ? value : nil
        }
        let matches = Self.constantTimeEqualData(Self.sha256(Data(normalized)), session.codeHash)
        if matches {
            pairingSession = nil
            return .accepted(sessionID: session.id)
        }
        session.attemptsLeft -= 1
        if session.attemptsLeft <= 0 {
            pairingSession = nil
            return .rejected(reason: "too_many_attempts")
        }
        pairingSession = session
        return .rejected(reason: "invalid", attemptsLeft: session.attemptsLeft)
    }

    private typealias IssuedTokens = (access: String, refresh: String?, expiresIn: Int, scopes: [String])

    private func issueTokensLocked(
        clientID: String,
        scopes: [String],
        workspaceID: String? = nil,
        familyID: String? = nil,
        resource: String? = nil
    ) throws -> IssuedTokens {
        let previousTokens = tokens
        let now = Self.nowMilliseconds
        tokens = tokens.filter { !$0.value.revoked && $0.value.expiresAt > now }
        refreshReplays = refreshReplays.filter { $0.value.expiresAt > now }
        let requiredSlots = scopes.contains("offline_access") ? 2 : 1
        guard tokens.count <= 20_000 - requiredSlots else {
            tokens = previousTokens
            throw C2CError("OAuth token limit reached")
        }
        let targetWorkspace = workspaceID ?? self.workspaceID
        let targetFamily = familyID ?? Self.randomHex(byteCount: 16)
        let access = "c2c_at_\(Self.randomBase64URL(byteCount: 32))"
        let accessHash = Self.sha256Hex(access)
        tokens[accessHash] = TokenRecord(
            hash: accessHash,
            kind: .access,
            clientId: clientID,
            workspaceId: targetWorkspace,
            scopes: scopes,
            familyId: targetFamily,
            resource: resource,
            issuedAt: now,
            expiresAt: now + Self.accessTokenTTL * 1_000,
            revoked: false
        )

        var refresh: String?
        if scopes.contains("offline_access") {
            let value = "c2c_rt_\(Self.randomBase64URL(byteCount: 32))"
            let hash = Self.sha256Hex(value)
            tokens[hash] = TokenRecord(
                hash: hash,
                kind: .refresh,
                clientId: clientID,
                workspaceId: targetWorkspace,
                scopes: scopes,
                familyId: targetFamily,
                resource: resource,
                issuedAt: now,
                expiresAt: now + Self.refreshTokenTTL * 1_000,
                revoked: false
            )
            refresh = value
        }
        do {
            try saveLocked()
        } catch {
            tokens = previousTokens
            throw error
        }
        return (access, refresh, Int(Self.accessTokenTTL), scopes)
    }

    private func tokenResponse(_ issued: IssuedTokens) -> HTTPResponse {
        var response: [String: Any] = [
            "access_token": issued.access,
            "token_type": "Bearer",
            "expires_in": issued.expiresIn,
            "scope": issued.scopes.joined(separator: " "),
        ]
        if let refresh = issued.refresh { response["refresh_token"] = refresh }
        return .json(response)
    }

    private func saveLocked() throws {
        let now = Self.nowMilliseconds
        let persisted = PersistedState(
            clients: Array(clients.values),
            tokens: tokens.values.filter { !$0.revoked && $0.expiresAt > now },
            refreshReplays: refreshReplays.values.filter { $0.expiresAt > now }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        let object = try JSONSerialization.jsonObject(with: data)
        try AppPaths.writeJSON(object, to: stateFile)
    }

    private func pruneTransientLocked() {
        let now = Self.nowMilliseconds
        pendingAuthorizations = pendingAuthorizations.filter { $0.value.expiresAt >= now }
        authorizationCodes = authorizationCodes.filter { $0.value.expiresAt >= now }
        rateWindows = rateWindows.filter { $0.value.resetAt >= now }
        publicRateWindows = publicRateWindows.filter { $0.value.resetAt >= now }
        refreshReplays = refreshReplays.filter { $0.value.expiresAt >= now }
    }

    // MARK: - HTTP and encoding helpers

    private func fields(_ request: HTTPRequest) -> [String: String] {
        let contentType = request.headers["content-type"]?.lowercased() ?? ""
        if contentType.hasPrefix("application/json") {
            guard let json = try? request.json() else { return [:] }
            return json.reduce(into: [:]) { result, element in
                if let value = element.value as? String { result[element.key] = value }
            }
        }
        return request.form()
    }

    private func redirect(_ value: String, items: [URLQueryItem]) -> HTTPResponse {
        guard var components = URLComponents(string: value) else {
            return .json(["error": "invalid_request"], status: 400)
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let location = components.url?.absoluteString else {
            return .json(["error": "invalid_request"], status: 400)
        }
        return HTTPResponse(status: 302, headers: ["location": location], body: Data())
    }

    private func secureHTML(_ value: String, status: Int) -> HTTPResponse {
        var response = HTTPResponse.html(value, status: status)
        let replaced = Set([
            "content-security-policy", "x-content-type-options", "x-frame-options",
            "referrer-policy", "cache-control",
        ])
        response.headers = response.headers.filter { !replaced.contains($0.key.lowercased()) }
        response.headers["content-security-policy"] =
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https:; base-uri 'none'; frame-ancestors 'none'"
        response.headers["x-content-type-options"] = "nosniff"
        response.headers["x-frame-options"] = "DENY"
        response.headers["referrer-policy"] = "no-referrer"
        response.headers["cache-control"] = "no-store, max-age=0"
        return response
    }

    private func pairingPage(requestID: String, scopes: [String], error: String? = nil) -> String {
        let labels = [
            "workspace.read": "Read files in this workspace",
            "workspace.search": "Search this workspace",
            "git.read": "Read git status and diffs",
            "execution.read": "Read Codex execution summaries",
            "offline_access": "Stay connected between sessions",
        ]
        let scopeList = scopes.map { "<li>\(Self.escapeHTML(labels[$0] ?? $0))</li>" }.joined()
        let errorHTML = error.map { "<p class=\"error\" role=\"alert\">\(Self.escapeHTML($0))</p>" } ?? ""
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Codex with ChatGPT</title>
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0; background:#f5f5f7; color:#1d1d1f; }
        @media (prefers-color-scheme: dark) { body { background:#111; color:#eee; } .card { background:#1c1c1e !important; } }
        .card { background:#fff; border-radius:16px; padding:40px; max-width:420px; width:90%; box-shadow:0 4px 24px rgba(0,0,0,.08); }
        h1 { font-size:20px; margin:0 0 4px; } .sub { color:#86868b; font-size:14px; margin:0 0 20px; }
        ul { font-size:13px; color:#6e6e73; padding-left:18px; margin:0 0 24px; } li { margin-bottom:4px; }
        input[type=text] { width:100%; box-sizing:border-box; font-size:24px; letter-spacing:4px; text-align:center; text-transform:uppercase; padding:12px; border:1.5px solid #d2d2d7; border-radius:10px; font-family:ui-monospace, monospace; background:transparent; color:inherit; }
        button { width:100%; margin-top:16px; padding:12px; font-size:16px; border:0; border-radius:10px; background:#0071e3; color:#fff; cursor:pointer; }
        .error { color:#d70015; font-size:13px; margin:12px 0 0; } .hint { color:#86868b; font-size:12px; margin-top:16px; text-align:center; }
        </style></head><body><div class="card">
        <h1>Codex with ChatGPT</h1>
        <p class="sub">ChatGPT is requesting access to workspace <strong>\(Self.escapeHTML(workspaceName))</strong> (read-only):</p>
        <ul>\(scopeList)</ul>
        <form method="POST" action="authorize">
        <input type="hidden" name="request_id" value="\(Self.escapeHTML(requestID))">
        <input type="text" name="pairing_code" id="pairing_code" placeholder="XXXX-XXXX" autocomplete="one-time-code" autofocus maxlength="9" required>
        \(errorHTML)<button type="submit">Connect</button></form>
        <p class="hint">The pairing code was generated by Codex on this computer.<br>It expires in a few minutes.</p>
        </div></body></html>
        """
    }

    private static func oauthErrorItems(error: String, description: String, state: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "error", value: error),
            URLQueryItem(name: "error_description", value: description),
        ]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        return items
    }

    private static func filterScopes(_ value: String?) -> [String]? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return supportedScopes
        }
        let requested = value.split { $0.isWhitespace || $0 == "+" }.map(String.init)
        guard requested.allSatisfy({ supportedScopes.contains($0) }) else { return nil }
        return requested
    }

    private static func isAllowedRedirectURI(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func isValidPKCEChallenge(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }

    private static func isValidPKCEVerifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil
    }

    private func allowPublicRequest(_ address: String, namespace: String, limit: Int) -> Bool {
        withLock { allowPublicRequestLocked(address, namespace: namespace, limit: limit) }
    }

    private func allowPublicRequestLocked(_ address: String, namespace: String, limit: Int) -> Bool {
        let key = "\(namespace):\(address.isEmpty ? "unknown" : address)"
        let now = Self.nowMilliseconds
        if publicRateWindows.count >= 4_096 {
            publicRateWindows = publicRateWindows.filter { $0.value.resetAt >= now }
            if publicRateWindows.count >= 4_096, publicRateWindows[key] == nil { return false }
        }
        var window = publicRateWindows[key]
        if window == nil || now > window!.resetAt {
            window = RateWindow(count: 1, resetAt: now + 60_000)
        } else {
            window!.count += 1
        }
        publicRateWindows[key] = window
        return window!.count <= limit
    }

    private static var nowMilliseconds: Double { Date().timeIntervalSince1970 * 1_000 }

    private static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func pkceChallenge(_ verifier: String) -> String {
        sha256(Data(verifier.utf8)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqualData(Data(lhs.utf8), Data(rhs.utf8))
    }

    private static func constantTimeEqualData(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    private static func randomData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "Secure random number generation failed")
        return Data(bytes)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        randomData(byteCount: byteCount).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomHex(byteCount: Int) -> String {
        randomData(byteCount: byteCount).map { String(format: "%02x", $0) }.joined()
    }

    private static func generatePairingCode() -> String {
        var output = [UInt8]()
        let limit = UInt8((256 / pairingAlphabet.count) * pairingAlphabet.count - 1)
        while output.count < 8 {
            for byte in randomData(byteCount: 16) where byte <= limit {
                output.append(pairingAlphabet[Int(byte) % pairingAlphabet.count])
                if output.count == 8 { break }
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
