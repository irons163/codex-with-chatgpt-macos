import Foundation

/// Persists the ChatGPT conversation and Project binding for one workspace.
///
/// The on-disk representation intentionally follows the TypeScript CLI: fields
/// whose value is not present are omitted from JSON rather than written as
/// `null`.  This keeps old state files compatible with the CLI and with the
/// resume logic in the Skill.
public final class SessionStore {
    private let workspaceID: String
    private let stateDirectory: URL

    private static let optionNames: Set<String> = [
        "url",
        "title",
        "task",
        "iteration",
        "state",
        "mode",
        "project-url",
        "connector-name",
        "protocol-state",
        "waiting-for",
        "goal",
        "completed-subtasks",
        "known-issues",
        "next-step",
    ]

    private static let flagNames: Set<String> = ["clear-checkpoint"]
    private static let checkpointOnlyOptions: Set<String> = [
        "protocol-state",
        "waiting-for",
        "goal",
        "completed-subtasks",
        "known-issues",
        "next-step",
    ]

    private static let protocolStates = [
        "INIT",
        "PLAN_RECEIVED",
        "EXECUTING",
        "EXECUTED_LOCAL",
        "EXECUTED_SENT",
        "DONE",
        "BLOCKED",
    ]

    private static let waitingForValues = ["none", "GPT_PLAN", "GPT_REVIEW", "USER"]

    public init(workspaceID: String, stateDirectory: URL) {
        self.workspaceID = workspaceID
        self.stateDirectory = stateDirectory.standardizedFileURL
    }

    private var sessionURL: URL {
        stateDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(workspaceID).json", isDirectory: false)
    }

    /// Return the raw saved session, or `nil` when this workspace has no state.
    public func get() -> [String: Any]? {
        AppPaths.readJSON(sessionURL)
    }

    /// Resolve the saved session into the view consumed by the setup/resume UX.
    public func conversation() -> [String: Any] {
        Self.resolveConversation(get())
    }

    /// Merge CLI-style options into the saved state and persist the result.
    ///
    /// `options` and `flags` use names after the leading `--` has been removed,
    /// for example `project-url` and `clear-checkpoint`.
    @discardableResult
    public func set(_ options: [String: String], flags: Set<String>) throws -> [String: Any] {
        // The native CLI passes its shared `--workspace` and `--json` parser
        // values through to command handlers.  They select the store/output
        // and are not session state, so strip them before strict validation.
        let stateOptions = options.filter { $0.key != "workspace" && $0.key != "json" }
        let stateFlags = flags.subtracting(["json"])
        try Self.validateOptionNames(options: stateOptions, flags: stateFlags)

        let normalized = try Self.normalizeOptions(stateOptions)
        let previous = get()
        let saved = try Self.mergeSession(previous: previous, options: normalized, flags: stateFlags)
        try AppPaths.writeJSON(saved, to: sessionURL)
        return saved
    }

    /// Forget the current chat pointer while retaining a Project binding.
    @discardableResult
    public func clear() throws -> [String: Any] {
        guard let previous = get() else {
            return ["cleared": false, "keptProject": false]
        }

        let resolved = Self.resolveConversation(previous)
        if Self.stringValue(resolved["mode"]) == "project",
           let projectURL = Self.stringValue(resolved["projectUrl"]),
           !projectURL.isEmpty {
            var kept: [String: Any] = [
                "conversationMode": "project",
                "projectUrl": projectURL,
                "savedAt": Self.nowISO8601(),
            ]
            if let connector = Self.stringValue(previous["connectorName"]) {
                kept["connectorName"] = connector
            }
            if let checkpoint = previous["checkpoint"] as? [String: Any] {
                kept["checkpoint"] = checkpoint
            }
            try AppPaths.writeJSON(kept, to: sessionURL)
            return ["cleared": true, "keptProject": true]
        }

        try FileManager.default.removeItem(at: sessionURL)
        return ["cleared": true, "keptProject": false]
    }

    // MARK: - Validation and merge

    private static func validateOptionNames(options: [String: String], flags: Set<String>) throws {
        let unknownOptions = options.keys.filter { !optionNames.contains($0) }
        if let unknown = unknownOptions.sorted().first {
            throw SessionError.invalidArgument("unknown session option: \(unknown)")
        }
        let unknownFlags = flags.filter { !flagNames.contains($0) }
        if let unknown = unknownFlags.sorted().first {
            throw SessionError.invalidArgument("unknown session flag: \(unknown)")
        }

        let suppliedCheckpointOptions = Set(options.keys).intersection(checkpointOnlyOptions)
        if !suppliedCheckpointOptions.isEmpty && options["protocol-state"] == nil {
            throw SessionError.invalidArgument("checkpoint options require protocol-state")
        }
    }

    private static func normalizeOptions(_ options: [String: String]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in options {
            switch key {
            case "mode":
                let mode = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard mode == "long-chat" || mode == "project" else {
                    throw SessionError.invalidArgument("mode must be long-chat or project")
                }
                result[key] = mode
            case "iteration":
                result[key] = try parseNonNegativeInteger(value, label: "iteration")
            case "url":
                guard let normalized = normalizeConversationURL(value) else {
                    throw SessionError.invalidArgument(
                        "conversation URL must look like https://chatgpt.com/c/… or https://chatgpt.com/g/…/c/…"
                    )
                }
                result[key] = normalized
            case "protocol-state":
                let protocolState = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard protocolStates.contains(protocolState) else {
                    throw SessionError.invalidArgument(
                        "protocol-state must be one of \(protocolStates.joined(separator: ", "))"
                    )
                }
                result[key] = protocolState
            case "waiting-for":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let waiting = trimmed.lowercased() == "none" ? "none" : trimmed.uppercased()
                guard waitingForValues.contains(waiting) else {
                    throw SessionError.invalidArgument(
                        "waiting-for must be one of \(waitingForValues.joined(separator: ", "))"
                    )
                }
                result[key] = waiting
            case "project-url":
                if value.isEmpty {
                    result[key] = value
                } else if let normalized = normalizeProjectURL(value) {
                    result[key] = normalized
                } else {
                    throw SessionError.invalidArgument(
                        "project URL must look like https://chatgpt.com/g/g-p-…/project"
                    )
                }
            default:
                result[key] = value
            }
        }
        return result
    }

    private static func mergeSession(
        previous: [String: Any]?,
        options: [String: Any],
        flags: Set<String>
    ) throws -> [String: Any] {
        let conversationMode = stringValue(options["mode"]) ?? stringValue(previous?["conversationMode"])

        let rawProjectURL: String?
        if let supplied = options["project-url"] {
            rawProjectURL = stringValue(supplied) ?? ""
        } else {
            rawProjectURL = stringValue(previous?["projectUrl"])
        }

        let projectURL: String?
        if let rawProjectURL {
            if rawProjectURL.isEmpty {
                projectURL = rawProjectURL
            } else if let normalized = normalizeProjectURL(rawProjectURL) {
                projectURL = normalized
            } else {
                throw SessionError.invalidArgument(
                    "project URL must look like https://chatgpt.com/g/g-p-…/project"
                )
            }
        } else {
            projectURL = nil
        }

        let previousHasProject = stringValue(previous?["projectUrl"])?.isEmpty == false
        if conversationMode == "project" && (projectURL == nil || projectURL?.isEmpty == true) &&
            !previousHasProject {
            throw SessionError.invalidArgument("project mode requires --project-url")
        }

        let url = stringValue(options["url"]) ?? stringValue(previous?["url"])
        let taskID = stringValue(options["task"]) ?? stringValue(previous?["taskId"])
        let hasChat = url != nil && !(url?.isEmpty ?? true)
        let hasProject = projectURL != nil && !(projectURL?.isEmpty ?? true)
        let hasTask = taskID != nil && !(taskID?.isEmpty ?? true)
        let hasCheckpoint = options["protocol-state"] != nil || flags.contains("clear-checkpoint") ||
            previous?["checkpoint"] != nil

        if !hasChat && !hasProject && conversationMode != "long-chat" && !hasTask && !hasCheckpoint {
            throw SessionError.invalidArgument("nothing to save: pass --url, --project-url, or --mode")
        }

        var checkpoint: [String: Any]? = previous?["checkpoint"] as? [String: Any]
        if flags.contains("clear-checkpoint") {
            checkpoint = nil
        } else if let protocolState = stringValue(options["protocol-state"]) {
            let previousCheckpoint = previous?["checkpoint"] as? [String: Any]
            let checkpointTaskID = stringValue(options["task"])
                ?? stringValue(previousCheckpoint?["taskId"])
                ?? stringValue(previous?["taskId"])
            guard let checkpointTaskID, !checkpointTaskID.isEmpty else {
                throw SessionError.invalidArgument("checkpoint requires task id and protocol state")
            }

            let iteration = intValue(options["iteration"])
                ?? intValue(previousCheckpoint?["iteration"])
                ?? intValue(previous?["iteration"])
                ?? 0
            guard iteration >= 0 else {
                throw SessionError.invalidArgument("iteration must be a non-negative integer")
            }

            let previousProtocol = stringValue(previousCheckpoint?["protocolState"])
            guard protocolStates.contains(protocolState) || protocolStates.contains(previousProtocol ?? "") else {
                throw SessionError.invalidArgument(
                    "protocol-state must be one of \(protocolStates.joined(separator: ", "))"
                )
            }

            let waitingFor = stringValue(options["waiting-for"])
                ?? stringValue(previousCheckpoint?["waitingFor"])
                ?? "none"
            guard waitingForValues.contains(waitingFor) else {
                throw SessionError.invalidArgument(
                    "waiting-for must be one of \(waitingForValues.joined(separator: ", "))"
                )
            }

            var next: [String: Any] = [
                "taskId": checkpointTaskID,
                "iteration": iteration,
                "protocolState": protocolState,
                "waitingFor": waitingFor,
                "updatedAt": nowISO8601(),
            ]
            let originalGoal = cappedText(
                stringValue(options["goal"]) ?? stringValue(previousCheckpoint?["originalGoal"]),
                maxLength: 500
            )
            let completedSubtasks = cappedText(
                stringValue(options["completed-subtasks"]) ?? stringValue(previousCheckpoint?["completedSubtasks"]),
                maxLength: 800
            )
            let knownIssues = cappedText(
                stringValue(options["known-issues"]) ?? stringValue(previousCheckpoint?["knownIssues"]),
                maxLength: 800
            )
            let nextExpectedStep = cappedText(
                stringValue(options["next-step"]) ?? stringValue(previousCheckpoint?["nextExpectedStep"]),
                maxLength: 400
            )
            if let originalGoal { next["originalGoal"] = originalGoal }
            if let completedSubtasks { next["completedSubtasks"] = completedSubtasks }
            if let knownIssues { next["knownIssues"] = knownIssues }
            if let nextExpectedStep { next["nextExpectedStep"] = nextExpectedStep }
            if let chatURL = stringValue(previousCheckpoint?["chatUrl"]) ?? url {
                next["chatUrl"] = chatURL
            }
            if let checkpointProjectURL = stringValue(previousCheckpoint?["projectUrl"]) ?? projectURL {
                next["projectUrl"] = checkpointProjectURL
            }
            checkpoint = next
        }

        var saved: [String: Any] = ["savedAt": nowISO8601()]
        if let url { saved["url"] = url }
        if let title = stringValue(options["title"]) ?? stringValue(previous?["title"]) {
            saved["title"] = title
        }
        if let taskID { saved["taskId"] = taskID }
        if let iteration = intValue(options["iteration"]) ?? intValue(previous?["iteration"]) {
            saved["iteration"] = iteration
        }
        if let state = stringValue(options["state"]) ?? stringValue(previous?["lastState"]) {
            saved["lastState"] = state
        }
        if let conversationMode {
            saved["conversationMode"] = conversationMode
        }
        if let projectURL {
            saved["projectUrl"] = projectURL
        }
        if let connectorName = stringValue(options["connector-name"]) ?? stringValue(previous?["connectorName"]) {
            saved["connectorName"] = connectorName
        }
        if let checkpoint {
            saved["checkpoint"] = checkpoint
        }
        return saved
    }

    private static func resolveConversation(_ session: [String: Any]?) -> [String: Any] {
        guard let session else {
            return [
                "mode": "project",
                "reason": "new-workspace",
                "projectUrl": NSNull(),
                "projectReady": false,
                "chatUrl": NSNull(),
                "connectorName": NSNull(),
                "reuseSavedChat": false,
            ]
        }

        let projectURL = stringValue(session["projectUrl"]).flatMap(normalizeProjectURL)
        let projectReady = projectURL != nil
        let mode = stringValue(session["conversationMode"])
        let chatURL = stringValue(session["url"])
        let hasChatURL = chatURL != nil && !(chatURL?.isEmpty ?? true)

        if mode == "long-chat" {
            return conversationDictionary(
                mode: "long-chat",
                reason: "existing-long-chat",
                projectURL: nil,
                projectReady: false,
                chatURL: chatURL,
                connectorName: stringValue(session["connectorName"]),
                reuseSavedChat: hasChatURL
            )
        }

        if mode == "project" || projectReady {
            return conversationDictionary(
                mode: "project",
                reason: "project",
                projectURL: projectURL,
                projectReady: projectReady,
                chatURL: chatURL,
                connectorName: stringValue(session["connectorName"]),
                reuseSavedChat: false
            )
        }

        return conversationDictionary(
            mode: "long-chat",
            reason: "existing-long-chat",
            projectURL: nil,
            projectReady: false,
            chatURL: chatURL,
            connectorName: stringValue(session["connectorName"]),
            reuseSavedChat: hasChatURL
        )
    }

    private static func conversationDictionary(
        mode: String,
        reason: String,
        projectURL: String?,
        projectReady: Bool,
        chatURL: String?,
        connectorName: String?,
        reuseSavedChat: Bool
    ) -> [String: Any] {
        [
            "mode": mode,
            "reason": reason,
            "projectUrl": projectURL ?? NSNull(),
            "projectReady": projectReady,
            "chatUrl": chatURL ?? NSNull(),
            "connectorName": connectorName ?? NSNull(),
            "reuseSavedChat": reuseSavedChat,
        ]
    }

    private static func normalizeProjectURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "chatgpt.com" || host == "www.chatgpt.com" else {
            return nil
        }

        let path = url.path
        let pattern = #"^/g/(g-p-[a-zA-Z0-9]+)/project/?$"#
        guard let match = path.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let projectID = String(path[match]).split(separator: "/")[1]
        return "https://chatgpt.com/g/\(projectID)/project"
    }

    private static func normalizeConversationURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "chatgpt.com" || host == "www.chatgpt.com",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return nil
        }

        let path = url.path
        let directPattern = #"^/c/[^/]+/?$"#
        let projectPattern = #"^/g/[^/]+/c/[^/]+/?$"#
        guard path.range(of: directPattern, options: .regularExpression) != nil ||
            path.range(of: projectPattern, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func cappedText(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxLength {
            return String(trimmed.prefix(maxLength)) + "…"
        }
        return trimmed
    }

    private static func parseNonNegativeInteger(_ value: String, label: String) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber }),
              let parsed = Int(trimmed),
              parsed >= 0,
              parsed <= 9_007_199_254_740_991 else {
            throw SessionError.invalidArgument("\(label) must be a non-negative integer")
        }
        return parsed
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.rounded() == double else { return nil }
            let result = number.intValue
            guard NSNumber(value: result).doubleValue == double else { return nil }
            return result
        }
        return nil
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public enum SessionError: Error, LocalizedError, Equatable {
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): return message
        }
    }
}
