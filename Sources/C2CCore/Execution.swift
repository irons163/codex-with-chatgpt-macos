import Foundation
import Darwin

public final class ExecutionStore {
    public let workspaceID: String
    public let stateDirectory: URL
    private let fileManager = FileManager.default
    private let maxOutputRecords = 40

    public init(workspaceID: String, stateDirectory: URL) {
        self.workspaceID = workspaceID
        self.stateDirectory = stateDirectory
    }

    @discardableResult
    public func record(_ values: [String: Any]) throws -> [String: Any] {
        guard let taskID = values["taskId"] as? String, !taskID.isEmpty else { throw ExecutionError.invalid("taskId must be a non-empty string") }
        guard let iteration = Self.integer(values["iteration"]), iteration >= 0 else { throw ExecutionError.invalid("iteration must be a non-negative integer") }
        let changedFiles: Any
        if let array = values["changedFiles"] as? [String] { changedFiles = array }
        else if let count = Self.integer(values["changedFiles"]), count >= 0 { changedFiles = count }
        else { throw ExecutionError.invalid("changedFiles must be file paths or a non-negative count") }
        guard let exitStatus = values["exitStatus"] as? String, !exitStatus.isEmpty else { throw ExecutionError.invalid("exitStatus must be a string") }
        let tests: Any = values["tests"] as? String ?? NSNull()

        var record: [String: Any] = [
            "taskId": taskID, "iteration": iteration, "changedFiles": changedFiles,
            "tests": tests, "exitStatus": exitStatus, "timestamp": Self.timestamp()
        ]
        if let notes = values["notes"] as? String { record["notes"] = String(notes.prefix(400)) }

        if let command = values["command"] as? String, let output = values["output"] as? String {
            let meta = try saveOutput(command: command, raw: output, exitCode: Self.integer(values["exitCode"]), taskID: taskID, iteration: iteration)
            record["outputId"] = meta["id"]
            record["outputAvailable"] = meta["allowed"] as? Bool ?? false
        }
        let data = try JSONSerialization.data(withJSONObject: record)
        try append(data + Data([0x0a]), to: recordsURL())
        return record
    }

    func readRecords(limit: Int = 10) -> [[String: Any]] {
        guard let text = try? String(contentsOf: recordsURL(), encoding: .utf8) else { return [] }
        var result: [[String: Any]] = []
        for line in text.components(separatedBy: .newlines).reversed() where !line.isEmpty {
            guard result.count < max(1, limit), let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Self.validRecord(object) else { continue }
            result.append(object)
        }
        return result.reversed()
    }

    func latestRecord() -> [String: Any]? { readRecords(limit: 1).last }

    func listOutputs(limit: Int = 20) -> [[String: Any]] {
        let items = readIndex()["items"] as? [[String: Any]] ?? []
        return Array(items.suffix(min(50, max(1, limit))))
    }

    func readOutput(id: Int) -> Result<([String: Any], String), ExecutionOutputError> {
        guard let meta = (readIndex()["items"] as? [[String: Any]] ?? []).first(where: { Self.integer($0["id"]) == id }) else { return .failure(.notFound) }
        guard meta["allowed"] as? Bool == true else { return .failure(.restricted) }
        let text = (try? String(contentsOf: bodyURL(id: id), encoding: .utf8)) ?? ""
        return .success((meta, text))
    }

    private func saveOutput(command: String, raw: String, exitCode: Int?, taskID: String, iteration: Int) throws -> [String: Any] {
        try secureDirectory(outputDirectory())
        let lockURL = outputDirectory().appendingPathComponent(".lock")
        let lockDescriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX) == 0 else { if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }; throw C2CError("Cannot lock execution output state") }
        defer { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor) }
        var index = readIndex()
        let id = Self.integer(index["nextId"]) ?? 1
        let commandAllowed = Self.isAllowedCommand(command)
        let sanitized = Self.sanitize(raw)
        let allowed = commandAllowed && sanitized.allowed
        let text = allowed ? sanitized.text : ""
        let sanitizedCommand = Self.sanitize(command)
        var meta: [String: Any] = [
            "id": id, "command": String((sanitizedCommand.allowed ? sanitizedCommand.text : "[REDACTED]").prefix(200)), "exitCode": exitCode ?? NSNull(),
            "timestamp": Self.timestamp(), "taskId": taskID, "iteration": iteration,
            "allowed": allowed, "truncated": allowed ? sanitized.truncated : false, "sizeBytes": text.utf8.count
        ]
        if !allowed { meta["restrictedReason"] = commandAllowed ? sanitized.reason : "command_not_allowlisted" }
        if allowed && !text.isEmpty {
            try secureDirectory(bodyURL(id: id).deletingLastPathComponent())
            try secureWrite(Data(text.utf8), to: bodyURL(id: id))
        }
        var items = index["items"] as? [[String: Any]] ?? []
        items.append(meta)
        while items.count > maxOutputRecords {
            let removed = items.removeFirst()
            if let removedID = Self.integer(removed["id"]) { try? fileManager.removeItem(at: bodyURL(id: removedID)) }
        }
        index = ["nextId": id + 1, "items": items]
        try writeJSON(index, to: indexURL())
        return meta
    }

    private func recordsURL() -> URL { stateDirectory.appendingPathComponent("executions", isDirectory: true).appendingPathComponent("\(workspaceID).jsonl") }
    private func outputDirectory() -> URL { stateDirectory.appendingPathComponent("execution-outputs", isDirectory: true).appendingPathComponent(workspaceID, isDirectory: true) }
    private func indexURL() -> URL { outputDirectory().appendingPathComponent("index.json") }
    private func bodyURL(id: Int) -> URL { outputDirectory().appendingPathComponent("bodies", isDirectory: true).appendingPathComponent("\(id).txt") }

    private func readIndex() -> [String: Any] {
        guard let data = try? Data(contentsOf: indexURL()), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["nextId": 1, "items": []] }
        return object
    }

    private func append(_ data: Data, to url: URL) throws {
        try secureDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw C2CError("Cannot append execution record") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw C2CError("Cannot lock execution records") }
        defer { flock(descriptor, LOCK_UN) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard count > 0 else { throw C2CError("Cannot append execution record") }
                written += count
            }
        }
        fchmod(descriptor, S_IRUSR | S_IWUSR)
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        try secureDirectory(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try secureWrite(data, to: url)
    }

    private func secureWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw C2CError("Cannot create private execution state") }
        defer { Darwin.close(descriptor); try? fileManager.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard count > 0 else { throw C2CError("Cannot write execution state") }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw C2CError("Cannot persist execution state") }
    }

    private func secureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(url.path, S_IRWXU)
    }

    private static func validRecord(_ record: [String: Any]) -> Bool {
        guard record["taskId"] is String, let iteration = integer(record["iteration"]), iteration >= 0,
              record["exitStatus"] is String, record["timestamp"] is String else { return false }
        let changed = record["changedFiles"]
        guard changed is [String] || (integer(changed).map { $0 >= 0 } ?? false) else { return false }
        return record["tests"] is String || record["tests"] is NSNull
    }

    static func isAllowedCommand(_ command: String) -> Bool {
        if command.range(of: #"[;&|`<>]|\$\("#, options: .regularExpression) != nil { return false }
        let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return false }
        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        let rest = words.dropFirst().map { $0.lowercased() }
        switch executable {
        case "xcodebuild": return rest.contains("test") || rest.contains("build") || rest.contains("analyze")
        case "swift": return rest.first.map { ["test", "build"].contains($0) } ?? false
        case "cargo": return rest.first.map { ["test", "check", "build", "clippy", "fmt"].contains($0) } ?? false
        case "go": return rest.first == "test"
        case "pytest": return true
        case "python", "python3": return rest.count >= 2 && rest[rest.startIndex] == "-m" && rest[rest.index(after: rest.startIndex)] == "pytest"
        case "npm", "pnpm", "yarn", "bun":
            let approved = ["test", "build", "lint", "typecheck", "check"]
            if let first = rest.first, approved.contains(first) { return true }
            return rest.count >= 2 && rest.first == "run" && approved.contains(rest[rest.index(after: rest.startIndex)])
        case "npx": return rest.first.map { ["tsc", "eslint", "vitest", "jest"].contains($0) } ?? false
        case "mvn", "mvnw": return rest.contains("test") || rest.contains("verify")
        case "gradle", "gradlew": return rest.contains(where: { $0 == "test" || $0.hasSuffix(":test") || $0 == "check" || $0 == "build" })
        case "dotnet": return rest.first.map { ["test", "build"].contains($0) } ?? false
        case "make": return rest.first.map { ["test", "check", "build", "lint"].contains($0) } ?? false
        default: return false
        }
    }

    private static func sanitize(_ raw: String) -> (allowed: Bool, text: String, truncated: Bool, reason: String) {
        let privateKey = #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOCK-----"#
        if raw.range(of: privateKey, options: .regularExpression) != nil { return (false, "", false, "private_key") }
        var text = redact(raw)
        let patterns = [
            #"\bghp_[A-Za-z0-9]{20,}\b"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,
            #"\bsk-[A-Za-z0-9]{20,}\b"#, #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            #"\bAKIA[0-9A-Z]{16}\b"#, #"\bAIza[0-9A-Za-z_-]{20,}\b"#,
            #"(?i)((?:api[_-]?key|secret|password|passwd|authorization)\s*[:=]\s*)\S+"#
        ]
        for pattern in patterns { text = replace(pattern, in: text, template: "$1[REDACTED]") }
        text = replace(#"/Users/[^/\s\"'`]+"#, in: text, template: "/Users/[user]")
        text = replace(#"/home/[^/\s\"'`]+"#, in: text, template: "/home/[user]")
        text = replace(#"(?i)C:\\Users\\[^\\\s\"'`]+"#, in: text, template: #"C:\Users\[user]"#)
        var truncated = false
        var lines = text.components(separatedBy: .newlines)
        if lines.count > 200 { lines = Array(lines.prefix(200)); lines.append("…[truncated]"); text = lines.joined(separator: "\n"); truncated = true }
        if text.utf8.count > 64 * 1024 {
            var bytes = Data(text.utf8).prefix(64 * 1024 - 16)
            while String(data: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
            text = (String(data: bytes, encoding: .utf8) ?? "") + "\n…[truncated]"; truncated = true
        }
        return (true, text, truncated, "")
    }

    static func redact(_ input: String) -> String {
        var result = input
        let patterns = [
            #"c2c_(?:at|rt|ac|admin)_[A-Za-z0-9_-]+"#,
            #"(?i)(authorization\"?\s*[:=]\s*\"?bearer\s+)[^\s\"']+"#,
            #"(?i)((?:access_token|refresh_token|client_secret|code_verifier|code|token)\"?\s*[:=]\s*\"?)[A-Za-z0-9._~+/-]{16,}"#,
            #"\b[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}\b"#
        ]
        for pattern in patterns { result = replace(pattern, in: result, template: "$1[REDACTED]") }
        return result
    }

    private static func replace(_ pattern: String, in input: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        return regex.stringByReplacingMatches(in: input, range: NSRange(input.startIndex..<input.endIndex, in: input), withTemplate: template)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return value as? Int }
        let double = number.doubleValue
        return double.rounded() == double ? number.intValue : nil
    }
    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

public enum ExecutionError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { if case .invalid(let message) = self { return message }; return "Invalid execution record" }
}

enum ExecutionOutputError: Error { case notFound, restricted }
