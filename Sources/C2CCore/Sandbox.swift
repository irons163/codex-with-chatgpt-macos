import Foundation

/// Maintains the Codex `writable_roots` entry used for C2C's local state.
///
/// This is deliberately a small TOML editor.  It changes only the
/// `sandbox_workspace_write.writable_roots` array and preserves the rest of the
/// user's config text, matching the source CLI's behavior.
public enum SandboxConfig {
    private static let tableName = "sandbox_workspace_write"
    private static let keyName = "writable_roots"

    @discardableResult
    public static func ensure(
        stateDirectory: URL,
        configURL: URL? = nil
    ) throws -> [String: Any] {
        let stateURL = standardFileURL(stateDirectory)
        let config = configURL.map(standardFileURL) ?? defaultConfigURL()
        try AppPaths.ensureDirectory(stateURL)
        try AppPaths.ensureDirectory(config.deletingLastPathComponent())

        let content: String
        if FileManager.default.fileExists(atPath: config.path) {
            content = try String(contentsOf: config, encoding: .utf8)
        } else {
            content = ""
        }

        if try isAllowedContent(content, stateDirectory: stateURL) {
            return result(added: false, alreadyAllowed: true, stateDirectory: stateURL, configURL: config)
        }

        let next = try upsertWritableRoot(content: content, stateDirectory: stateURL)
        try writeSecureText(next, to: config)
        return result(added: true, alreadyAllowed: false, stateDirectory: stateURL, configURL: config)
    }

    public static func isAllowed(
        stateDirectory: URL,
        configURL: URL? = nil
    ) -> Bool {
        let stateURL = standardFileURL(stateDirectory)
        let config = configURL.map(standardFileURL) ?? defaultConfigURL()
        guard let content = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return (try? isAllowedContent(content, stateDirectory: stateURL)) ?? false
    }

    // MARK: - Config paths and output

    private static func result(
        added: Bool,
        alreadyAllowed: Bool,
        stateDirectory: URL,
        configURL: URL
    ) -> [String: Any] {
        [
            "ok": true,
            "added": added,
            "alreadyAllowed": alreadyAllowed,
            "stateDir": stateDirectory.path,
            "configPath": configURL.path,
        ]
    }

    private static func defaultConfigURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["C2C_CODEX_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome: URL
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            codexHome = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
        } else {
            codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("config.toml", isDirectory: false)
    }

    private static func standardFileURL(_ url: URL) -> URL {
        if url.isFileURL && url.path.hasPrefix("/") {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: url.path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    private static func writeSecureText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // Some filesystems do not expose POSIX permissions.  The write
            // itself succeeded, so preserve the source CLI's best-effort rule.
        }
    }

    // MARK: - TOML editing

    private struct Table {
        let start: Int
        let end: Int
        let body: String
    }

    private struct ArrayAssignment {
        let start: Int
        let end: Int
        let rawArray: String
    }

    private static func isAllowedContent(_ content: String, stateDirectory: URL) throws -> Bool {
        guard let table = findTable(in: content, name: tableName),
              let assignment = try findArrayAssignment(in: table.body, key: keyName) else {
            return false
        }
        return try parseTomlStringArray(assignment.rawArray).contains {
            pathsEquivalent($0, stateDirectory.path)
        }
    }

    private static func upsertWritableRoot(content: String, stateDirectory: URL) throws -> String {
        let tomlPath = toTomlPath(stateDirectory.path)
        guard let table = findTable(in: content, name: tableName) else {
            let prefix: String
            if content.isEmpty {
                prefix = ""
            } else if content.hasSuffix("\n") {
                prefix = content
            } else {
                prefix = content + "\n"
            }
            let spacer = prefix.isEmpty || prefix.hasSuffix("\n\n") ? "" : "\n"
            return "\(prefix)\(spacer)[\(tableName)]\n\(keyName) = [\"\(escapeTomlString(tomlPath))\"]\n"
        }

        guard let assignment = try findArrayAssignment(in: table.body, key: keyName) else {
            let offset = table.start + firstLineLength(table.body)
            let line = "\(keyName) = [\"\(escapeTomlString(tomlPath))\"]\n"
            return replacingUTF16Range(
                in: content,
                range: NSRange(location: offset, length: 0),
                with: line
            )
        }

        let roots = try parseTomlStringArray(assignment.rawArray)
        let nextRoots = roots + [tomlPath]
        let rendered: String
        if assignment.rawArray.contains("\n") {
            rendered = "[\n" + nextRoots
                .map { "  \"\(escapeTomlString(toTomlPath($0)))\"" }
                .joined(separator: ",\n") + ",\n]"
        } else {
            rendered = "[" + nextRoots
                .map { "\"\(escapeTomlString(toTomlPath($0)))\"" }
                .joined(separator: ", ") + "]"
        }
        let absoluteStart = table.start + assignment.start
        let absoluteEnd = table.start + assignment.end
        return replacingUTF16Range(
            in: content,
            range: NSRange(location: absoluteStart, length: absoluteEnd - absoluteStart),
            with: "\(keyName) = \(rendered)"
        )
    }

    private static func findTable(in content: String, name: String) -> Table? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let headerRegex = try? NSRegularExpression(
            pattern: "(?m)^[ \\t]*\\[\(escaped)\\][ \\t]*(?:#[^\\r\\n]*)?$"
        ),
        let header = headerRegex.firstMatch(
            in: content,
            range: NSRange(location: 0, length: (content as NSString).length)
        ) else {
            return nil
        }

        let start = header.range.location
        let afterHeader = NSMaxRange(header.range)
        let remainingLength = (content as NSString).length - afterHeader
        let remaining = (content as NSString).substring(with: NSRange(location: afterHeader, length: remainingLength))
        let nextHeaderRegex = try? NSRegularExpression(
            pattern: "(?m)^[ \\t]*\\[[^\\]\\r\\n]+\\][ \\t]*(?:#[^\\r\\n]*)?$"
        )
        let nextHeader = nextHeaderRegex?.firstMatch(
            in: remaining,
            range: NSRange(location: 0, length: (remaining as NSString).length)
        )
        let end = afterHeader + (nextHeader?.range.location ?? remainingLength)
        let body = (content as NSString).substring(with: NSRange(location: start, length: end - start))
        return Table(start: start, end: end, body: body)
    }

    private static func findArrayAssignment(in tableBody: String, key: String) throws -> ArrayAssignment? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: "(?m)^[ \\t]*\(escaped)[ \\t]*=[ \\t]*"
        ) else { return nil }
        let matches = regex.matches(
            in: tableBody,
            range: NSRange(location: 0, length: (tableBody as NSString).length)
        )
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let match = matches.first else {
            throw SandboxConfigError.invalidConfig("sandbox config has duplicate \(key) assignments")
        }

        let source = (tableBody as NSString)
        let valueStart = NSMaxRange(match.range)
        guard valueStart < source.length, source.character(at: valueStart) == 91 else {
            throw SandboxConfigError.invalidConfig("sandbox config \(key) must be an array of strings")
        }

        let value = source.substring(from: valueStart)
        guard let close = try findArrayClosingBracket(in: value) else {
            throw SandboxConfigError.invalidConfig("sandbox config \(key) has an unterminated array")
        }
        let closeLength = utf16Length(of: String(value[value.startIndex...close]))
        let arrayRange = NSRange(location: valueStart, length: closeLength)
        let rawArray = source.substring(with: arrayRange)

        let suffixStart = value.index(after: close)
        let suffix = value[suffixStart...]
        guard suffixIsCommentOrWhitespace(String(suffix)) else {
            throw SandboxConfigError.invalidConfig("sandbox config has unexpected text after \(key)")
        }
        return ArrayAssignment(start: match.range.location, end: valueStart + closeLength, rawArray: rawArray)
    }

    private static func findArrayClosingBracket(in source: String) throws -> String.Index? {
        var index = source.startIndex
        var depth = 0
        var state: StringState = .outside

        while index < source.endIndex {
            let character = source[index]
            switch state {
            case .outside:
                if character == "#" {
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                }
                if character == "\"" {
                    state = .basicString
                } else if character == "'" {
                    state = .literalString
                } else if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth -= 1
                    if depth == 0 { return index }
                    if depth < 0 {
                        throw SandboxConfigError.invalidConfig("sandbox config has an unexpected closing bracket")
                    }
                }
            case .basicString:
                if character == "\\" {
                    let escaped = source.index(after: index)
                    guard escaped < source.endIndex else {
                        throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
                    }
                    index = escaped
                } else if character == "\"" {
                    state = .outside
                } else if character == "\n" || character == "\r" {
                    throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
                }
            case .literalString:
                if character == "'" {
                    state = .outside
                } else if character == "\n" || character == "\r" {
                    throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
                }
            }
            index = source.index(after: index)
        }

        if state != .outside {
            throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
        }
        return nil
    }

    private static func parseTomlStringArray(_ source: String) throws -> [String] {
        var index = source.startIndex
        guard consume("[", from: source, index: &index) else {
            throw SandboxConfigError.invalidConfig("sandbox config writable_roots value must be an array")
        }

        var values: [String] = []
        var needsValue = true
        while true {
            skipTomlWhitespaceAndComments(in: source, index: &index)
            guard index < source.endIndex else {
                throw SandboxConfigError.invalidConfig("sandbox config writable_roots has an unterminated array")
            }
            if source[index] == "]" {
                if needsValue && !values.isEmpty {
                    // A trailing comma is valid TOML; an empty array is valid
                    // as well.  The state only rejects a dangling comma when
                    // it was followed by a non-comment token below.
                }
                return values
            }

            guard source[index] == "\"" || source[index] == "'" else {
                throw SandboxConfigError.invalidConfig("sandbox config writable_roots must contain only strings")
            }
            let quote = source[index]
            index = source.index(after: index)
            var raw = ""
            var closed = false
            while index < source.endIndex {
                let character = source[index]
                if character == quote {
                    closed = true
                    index = source.index(after: index)
                    break
                }
                if character == "\n" || character == "\r" {
                    throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
                }
                if quote == "\"" && character == "\\" {
                    let escaped = source.index(after: index)
                    guard escaped < source.endIndex else {
                        throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
                    }
                    raw.append(character)
                    index = escaped
                    raw.append(source[index])
                    index = source.index(after: index)
                } else {
                    raw.append(character)
                    index = source.index(after: index)
                }
            }
            guard closed else {
                throw SandboxConfigError.invalidConfig("sandbox config has an unterminated string")
            }
            values.append(quote == "\"" ? unescapeTomlString(raw) : raw)
            needsValue = false

            skipTomlWhitespaceAndComments(in: source, index: &index)
            guard index < source.endIndex else {
                throw SandboxConfigError.invalidConfig("sandbox config writable_roots has an unterminated array")
            }
            if source[index] == "]" { return values }
            guard source[index] == "," else {
                throw SandboxConfigError.invalidConfig("sandbox config writable_roots expects commas between strings")
            }
            index = source.index(after: index)
            needsValue = true
        }
    }

    private enum StringState: Equatable {
        case outside
        case basicString
        case literalString
    }

    private static func consume(_ expected: Character, from source: String, index: inout String.Index) -> Bool {
        guard index < source.endIndex, source[index] == expected else { return false }
        index = source.index(after: index)
        return true
    }

    private static func skipTomlWhitespaceAndComments(in source: String, index: inout String.Index) {
        while index < source.endIndex {
            let character = source[index]
            if character == " " || character == "\t" || character == "\n" || character == "\r" {
                index = source.index(after: index)
            } else if character == "#" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
            } else {
                break
            }
        }
    }

    private static func suffixIsCommentOrWhitespace(_ suffix: String) -> Bool {
        for character in suffix {
            if character == "\n" || character == "\r" { return true }
            if character == " " || character == "\t" { continue }
            if character == "#" { return true }
            return false
        }
        return true
    }

    private static func utf16Length(of text: String) -> Int {
        text.utf16.count
    }

    private static func unescapeTomlString(_ source: String) -> String {
        var result = ""
        var escaped = false
        for character in source {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func firstLineLength(_ text: String) -> Int {
        guard let newline = text.firstIndex(of: "\n") else {
            return (text as NSString).length
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: newline.samePosition(in: text.utf16)!) + 1
    }

    private static func replacingUTF16Range(in text: String, range: NSRange, with replacement: String) -> String {
        let nsText = text as NSString
        let before = nsText.substring(with: NSRange(location: 0, length: range.location))
        let afterStart = NSMaxRange(range)
        let after = nsText.substring(with: NSRange(location: afterStart, length: nsText.length - afterStart))
        return before + replacement + after
    }

    // MARK: - Path handling

    private static func toTomlPath(_ path: String) -> String {
        if isWindowsStyle(path) {
            return path.replacingOccurrences(of: "\\", with: "/")
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
            .replacingOccurrences(of: "\\", with: "/")
    }

    private static func pathsEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizeCompare(lhs)
        let right = normalizeCompare(rhs)
        if isWindowsStyle(lhs) || isWindowsStyle(rhs) {
            return left.lowercased() == right.lowercased()
        }
        return left == right
    }

    private static func normalizeCompare(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func isWindowsStyle(_ path: String) -> Bool {
        if path.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil {
            return true
        }
        return path.contains("\\")
    }

    private static func escapeTomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum SandboxConfigError: Error, LocalizedError, Equatable {
    case invalidConfig(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let message): return message
        }
    }
}
