import Foundation
import CryptoKit
import Darwin

public enum WorkspaceErrorCode: String {
    case invalidPath = "INVALID_PATH"
    case pathOutsideWorkspace = "PATH_OUTSIDE_WORKSPACE"
    case accessDeniedSensitiveFile = "ACCESS_DENIED_SENSITIVE_FILE"
    case fileNotFound = "FILE_NOT_FOUND"
    case notAFile = "NOT_A_FILE"
    case notADirectory = "NOT_A_DIRECTORY"
    case binaryFile = "BINARY_FILE"
    case fileTooLarge = "FILE_TOO_LARGE"
}

public struct WorkspaceError: Error, CustomStringConvertible {
    public let code: WorkspaceErrorCode
    public let message: String
    public var description: String { "\(code.rawValue): \(message)" }
}

struct ResolvedWorkspacePath {
    let absolute: String
    let relative: String
}

struct WorkspaceTextFileCandidate {
    let path: String
    let size: Int
    let url: URL
}

struct WorkspaceTextFileEnumeration {
    let candidates: [WorkspaceTextFileCandidate]
    let incomplete: Bool
}

private struct IgnoreRule {
    let pattern: String
    let negated: Bool
}

final class WorkspaceIgnoreRules {
    private static let sensitivePatterns = [
        ".env", ".env.*", "!.env.example", "*.pem", "*.key", "*.p12", "*.pfx",
        "*.jks", "*.keystore", "id_rsa", "id_rsa.*", "id_ed25519", "id_ed25519.*",
        "id_ecdsa", "id_ecdsa.*", "id_dsa", "id_dsa.*", ".ssh/", ".aws/", ".gnupg/",
        ".npmrc", ".netrc", "_netrc", ".git-credentials", "*.keychain", "*.keychain-db",
        ".cloudflared/", ".git/", "credentials.json", "service-account*.json", "secrets.json",
        "cookies.sqlite", "Cookies", ".c2c-secrets*"
    ]
    private static let noisePatterns = [
        ".git/", "node_modules/", "dist/", "build/", "out/", ".next/", ".nuxt/",
        ".svelte-kit/", "coverage/", ".cache/", ".turbo/", ".venv/", "venv/",
        "__pycache__/", ".pytest_cache/", ".mypy_cache/", "target/", ".gradle/", ".idea/",
        ".tooling/", ".pnpm-store/", ".build/", ".swiftpm/", ".DS_Store", "*.lock", "pnpm-lock.yaml",
        "package-lock.json", "yarn.lock"
    ]

    private let sensitive: [IgnoreRule]
    private let noise: [IgnoreRule]
    private let c2c: [IgnoreRule]
    private let git: [IgnoreRule]

    init(root: String) {
        sensitive = Self.rules(Self.sensitivePatterns)
        noise = Self.rules(Self.noisePatterns)
        c2c = Self.load(root: root, name: ".c2cignore")
        git = Self.load(root: root, name: ".gitignore")
    }

    func isSensitive(_ path: String) -> Bool {
        !path.isEmpty && path != "." && (Self.matches(path, rules: sensitive) || Self.matches(path, rules: c2c))
    }

    func isHidden(_ path: String) -> Bool {
        isSensitive(path) || Self.matches(path, rules: noise) || Self.matches(path, rules: git)
    }

    private static func load(root: String, name: String) -> [IgnoreRule] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        let canonical = url.resolvingSymlinksInPath().path
        guard (canonical == root || canonical.hasPrefix(root + "/")), canonical == url.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return rules(text.components(separatedBy: .newlines))
    }

    private static func rules(_ lines: [String]) -> [IgnoreRule] {
        lines.compactMap { raw in
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            let negated = value.hasPrefix("!")
            if negated { value.removeFirst() }
            return value.isEmpty ? nil : IgnoreRule(pattern: value, negated: negated)
        }
    }

    private static func matches(_ rawPath: String, rules: [IgnoreRule]) -> Bool {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var ignored = false
        for rule in rules where glob(rule.pattern, matches: path) {
            ignored = !rule.negated
        }
        return ignored
    }

    private static func glob(_ rawPattern: String, matches path: String) -> Bool {
        var pattern = rawPattern.replacingOccurrences(of: "\\", with: "/")
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly { pattern.removeLast() }
        let anchored = pattern.hasPrefix("/")
        if anchored { pattern.removeFirst() }
        guard !pattern.isEmpty else { return false }

        var expression = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    expression += ".*"
                    index = pattern.index(after: next)
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        let prefix = anchored || pattern.contains("/") ? "^" : "(^|.*/)"
        let suffix = directoryOnly ? "(/.*)?$" : "($|/.*$)"
        return path.range(of: prefix + expression + suffix, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public final class Workspace {
    public let id: String
    public let name: String
    public let root: String
    let ignoreRules: WorkspaceIgnoreRules
    private let projectConfig: [String: Any]

    public init(root rootInput: String) throws {
        let expanded = (rootInput as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let standardized = (absolute as NSString).standardizingPath
        let real = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory) else {
            throw WorkspaceError(code: .fileNotFound, message: "Workspace root does not exist: \(rootInput)")
        }
        guard isDirectory.boolValue else {
            throw WorkspaceError(code: .notADirectory, message: "Workspace root is not a directory: \(rootInput)")
        }
        self.root = real
        let caseSensitive = (try? URL(fileURLWithPath: real).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == true
        let digest = SHA256.hash(data: Data((caseSensitive ? real : real.lowercased()).utf8))
        self.id = digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
        let configURL = URL(fileURLWithPath: real).appendingPathComponent(".c2c.json")
        let configCanonical = configURL.resolvingSymlinksInPath().path
        if configCanonical == configURL.path,
           let configValues = try? configURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), configValues.isRegularFile == true, configValues.isSymbolicLink != true,
           let data = try? Data(contentsOf: configURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var parsed: [String: Any] = [:]
            if let value = object["name"] as? String { parsed["name"] = value }
            if let value = object["maxIterations"] as? NSNumber { parsed["maxIterations"] = value.intValue }
            projectConfig = parsed
        } else {
            projectConfig = [:]
        }
        self.name = projectConfig["name"] as? String ?? URL(fileURLWithPath: real).lastPathComponent
        self.ignoreRules = WorkspaceIgnoreRules(root: real)
    }

    public func info() -> [String: Any] {
        let project = detectProject()
        return [
            "workspaceId": id,
            "workspaceName": name,
            "rootAlias": "workspace:/",
            "projectType": project.projectType,
            "languages": project.languages,
            "frameworks": project.frameworks,
            "packageManager": project.packageManager ?? NSNull(),
            "scripts": project.scripts,
            "git": gitInfo()
        ]
    }

    func resolve(_ requested: String, allowSensitive: Bool = false) throws -> ResolvedWorkspacePath {
        guard !requested.contains("\0") else { throw WorkspaceError(code: .invalidPath, message: "Invalid path") }
        var value = requested.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if value.lowercased().hasPrefix("workspace:") {
            value = String(value.dropFirst("workspace:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if value.isEmpty || value == "/" { value = "." }
        let initial = value.hasPrefix("/") ? value : (root as NSString).appendingPathComponent(value)
        let canonical = canonicalize((initial as NSString).standardizingPath)
        guard canonical == root || canonical.hasPrefix(root + "/") else {
            throw WorkspaceError(code: .pathOutsideWorkspace, message: "Path resolves outside the connected workspace: \(requested)")
        }
        let relative = canonical == root ? "" : String(canonical.dropFirst(root.count + 1)).replacingOccurrences(of: "\\", with: "/")
        guard !relative.hasPrefix("..") else {
            throw WorkspaceError(code: .pathOutsideWorkspace, message: "Path resolves outside the connected workspace: \(requested)")
        }
        if !allowSensitive && !relative.isEmpty && ignoreRules.isSensitive(relative) {
            throw WorkspaceError(code: .accessDeniedSensitiveFile, message: "ACCESS_DENIED_SENSITIVE_FILE: '\(relative)' matches the sensitive-file policy and cannot be read.")
        }
        return ResolvedWorkspacePath(absolute: canonical, relative: relative)
    }

    private func canonicalize(_ path: String) -> String {
        var current = path
        var suffix: [String] = []
        while true {
            if FileManager.default.fileExists(atPath: current) {
                let real = URL(fileURLWithPath: current).resolvingSymlinksInPath().path
                return suffix.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return path }
            suffix.insert((current as NSString).lastPathComponent, at: 0)
            current = parent
        }
    }

    func validatedTextFile(at url: URL, maxFileBytes: Int) -> WorkspaceTextFileCandidate? {
        guard maxFileBytes > 0 else { return nil }
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(root + "/") else { return nil }
        let relative = String(standardized.dropFirst(root.count + 1)).replacingOccurrences(of: "\\", with: "/")
        guard !ignoreRules.isHidden(relative), !ignoreRules.isHidden(relative + "/") else { return nil }

        let descriptor = Darwin.open(standardized, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maxFileBytes else { return nil }
        var actualPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &actualPath) == 0 else { return nil }
        let opened = URL(fileURLWithPath: String(cString: actualPath)).resolvingSymlinksInPath().path
        guard opened == standardized, opened.hasPrefix(root + "/") else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxFileBytes))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count + count <= maxFileBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.prefix(8192).contains(0), String(data: data, encoding: .utf8) != nil else { return nil }
        return WorkspaceTextFileCandidate(path: relative, size: data.count, url: URL(fileURLWithPath: opened))
    }

    func readFile(_ requested: String, startLine requestedStart: Int? = nil, endLine requestedEnd: Int? = nil) throws -> [String: Any] {
        let resolved = try resolve(requested)
        let descriptor = Darwin.open(resolved.absolute, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw WorkspaceError(code: .fileNotFound, message: "File not found: \(resolved.relative)")
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError(code: .notAFile, message: "Not a regular file: \(resolved.relative)") }
        let hardLimit = 16 * 1024 * 1024
        guard status.st_size <= hardLimit else { throw WorkspaceError(code: .fileTooLarge, message: "File is too large to read safely: \(resolved.relative)") }
        var actualPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &actualPath) == 0 else { throw WorkspaceError(code: .pathOutsideWorkspace, message: "Unable to verify opened file path") }
        let opened = URL(fileURLWithPath: String(cString: actualPath)).resolvingSymlinksInPath().path
        guard opened == root || opened.hasPrefix(root + "/") else { throw WorkspaceError(code: .pathOutsideWorkspace, message: "Path resolves outside the connected workspace: \(requested)") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw WorkspaceError(code: .fileNotFound, message: "Unable to read file: \(resolved.relative)") }
            guard data.count + count <= hardLimit else { throw WorkspaceError(code: .fileTooLarge, message: "File is too large to read safely: \(resolved.relative)") }
            data.append(contentsOf: buffer.prefix(count))
        }
        if data.prefix(8192).contains(0) { throw WorkspaceError(code: .binaryFile, message: "Binary file (\(data.count) bytes): \(resolved.relative). Content is not returned.") }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError(code: .binaryFile, message: "Binary file (\(data.count) bytes): \(resolved.relative). Content is not returned.") }
        var lines = text.components(separatedBy: .newlines)
        if text.hasSuffix("\n") || text.hasSuffix("\r") { lines.removeLast() }
        let total = lines.count
        let start = max(1, requestedStart ?? 1)
        let hardEnd = start > Int.max - 1999 ? Int.max : start + 1999
        let defaultEnd = start > Int.max - 399 ? Int.max : start + 399
        let requestedLimit = requestedEnd.map { min($0, hardEnd) } ?? defaultEnd
        let upper = min(total, max(start - 1, requestedLimit))
        var selected: [String] = []
        var bytes = 0
        var actualEnd = start - 1
        if start <= total && upper >= start {
            for number in start...upper {
                let line = lines[number - 1]
                let cost = line.utf8.count + 1
                if cost > 256 * 1024 && selected.isEmpty { throw WorkspaceError(code: .fileTooLarge, message: "A line exceeds the safe read limit: \(resolved.relative)") }
                if bytes > 256 * 1024 - cost { break }
                selected.append(line)
                bytes += cost
                actualEnd = number
            }
        }
        let remaining = max(0, total - actualEnd)
        return [
            "path": resolved.relative, "sizeBytes": data.count, "totalLines": total,
            "startLine": min(start, max(total, 1)), "endLine": actualEnd,
            "truncated": remaining > 0, "remainingLines": remaining,
            "nextStartLine": remaining > 0 ? actualEnd + 1 : NSNull(), "content": selected.joined(separator: "\n")
        ]
    }

    func listDirectory(_ requested: String, depth requestedDepth: Int = 1, limit requestedLimit: Int = 200, offset requestedOffset: Int = 0) throws -> [String: Any] {
        let resolved = try resolve(requested)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.absolute, isDirectory: &isDirectory) else {
            throw WorkspaceError(code: .fileNotFound, message: "Directory not found: \(resolved.relative.isEmpty ? "." : resolved.relative)")
        }
        guard isDirectory.boolValue else { throw WorkspaceError(code: .notADirectory, message: "Not a directory: \(resolved.relative)") }
        let depth = min(4, max(1, requestedDepth)), limit = min(1000, max(1, requestedLimit)), offset = max(0, requestedOffset)
        let collectionCap = offset > Int.max - limit - 2000 ? Int.max : offset + limit + 2000
        var all: [[String: Any]] = []
        func walk(_ directory: String, relative: String, level: Int) {
            guard all.count < collectionCap,
                  let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else { return }
            let sorted = urls.sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let rd = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return ld == rd ? lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending : ld
            }
            for url in sorted {
                let child = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), values.isSymbolicLink != true else { continue }
                if ignoreRules.isHidden(child) || ignoreRules.isHidden(child + "/") { continue }
                if values.isDirectory == true {
                    all.append(["path": child + "/", "type": "dir"])
                    if level < depth { walk(url.path, relative: child, level: level + 1) }
                } else if values.isRegularFile == true {
                    all.append(["path": child, "type": "file", "sizeBytes": values.fileSize ?? 0])
                }
            }
        }
        walk(resolved.absolute, relative: resolved.relative, level: 1)
        let page = Array(all.dropFirst(min(offset, all.count)).prefix(limit))
        let endOffset = offset > Int.max - page.count ? Int.max : offset + page.count
        return ["path": resolved.relative.isEmpty ? "." : resolved.relative, "entries": page, "total": all.count, "offset": offset, "limit": limit, "hasMore": endOffset < all.count]
    }

    /// Recursively discovers text files for attachment without the depth and
    /// result caps used by the MCP directory-listing tool.
    func enumerateTextFiles(
        preferredNames: Set<String>,
        extensions: Set<String>,
        maxFileBytes: Int
    ) -> WorkspaceTextFileEnumeration {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var incomplete = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in incomplete = true; return true }
        ) else {
            return WorkspaceTextFileEnumeration(candidates: [], incomplete: true)
        }

        var candidates: [WorkspaceTextFileCandidate] = []
        while let url = enumerator.nextObject() as? URL {
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(root + "/") else {
                enumerator.skipDescendants()
                incomplete = true
                continue
            }
            let relative = String(standardized.dropFirst(root.count + 1)).replacingOccurrences(of: "\\", with: "/")
            guard let values = try? url.resourceValues(forKeys: keys) else {
                incomplete = true
                continue
            }
            if values.isSymbolicLink == true || ignoreRules.isHidden(relative) || ignoreRules.isHidden(relative + "/") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard size >= 0, size <= maxFileBytes,
                  preferredNames.contains(url.lastPathComponent) || extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let candidate = validatedTextFile(at: url, maxFileBytes: maxFileBytes) else { continue }
            candidates.append(candidate)
        }
        return WorkspaceTextFileEnumeration(candidates: candidates, incomplete: incomplete)
    }

    func search(query: String, path: String? = nil, glob: String? = nil, limit requestedLimit: Int = 50, regex: Bool = false) throws -> [String: Any] {
        guard query.count >= 2 else { return ["matches": [], "matchCount": 0, "truncated": false, "engine": "node"] }
        let resolved = try resolve(path ?? ".")
        let limit = min(200, max(1, requestedLimit))
        if regex {
            let unsafe = query.utf8.count > 128 || query.range(of: #"\\[1-9]|\(\?|\([^)]*[*+][^)]*\)[*+{]"#, options: .regularExpression) != nil
            if unsafe { throw WorkspaceError(code: .invalidPath, message: "Regex is too complex for bounded workspace search") }
        }
        let matcher = regex ? try NSRegularExpression(pattern: query, options: [.caseInsensitive]) : nil
        let globExpression = glob.map(Self.globRegex)
        var matches: [[String: Any]] = []
        var truncated = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        func inspect(_ url: URL, relative: String) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 2 * 1024 * 1024 else { return }
            if let globExpression, relative.range(of: globExpression, options: [.regularExpression, .caseInsensitive]) == nil { return }
            guard let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0), let content = String(data: data, encoding: .utf8) else { return }
            for (index, line) in content.components(separatedBy: .newlines).enumerated() {
                let searchable = regex ? String(line.prefix(4096)) : line
                let range = NSRange(searchable.startIndex..<searchable.endIndex, in: searchable)
                let hit = matcher?.firstMatch(in: searchable, range: range) != nil || (!regex && searchable.localizedCaseInsensitiveContains(query))
                if hit {
                    matches.append(["path": relative, "line": index + 1, "text": String(line.prefix(500))])
                    if matches.count >= limit { truncated = true; return }
                }
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.absolute, isDirectory: &isDirectory) else { throw WorkspaceError(code: .fileNotFound, message: "Path not found: \(resolved.relative)") }
        if !isDirectory.boolValue {
            inspect(URL(fileURLWithPath: resolved.absolute), relative: resolved.relative)
            return ["matches": matches, "matchCount": matches.count, "truncated": truncated, "engine": "swift"]
        }
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: resolved.absolute), includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return ["matches": [], "matchCount": 0, "truncated": false, "engine": "swift"]
        }
        while let url = enumerator.nextObject() as? URL {
            let canonicalPath = url.resolvingSymlinksInPath().path
            guard canonicalPath.hasPrefix(root + "/") else { enumerator.skipDescendants(); continue }
            let relative = String(canonicalPath.dropFirst(root.count + 1)).replacingOccurrences(of: "\\", with: "/")
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true || ignoreRules.isHidden(relative) || ignoreRules.isHidden(relative + "/") {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            inspect(url, relative: relative)
            if truncated { break }
        }
        return ["matches": matches, "matchCount": matches.count, "truncated": truncated, "engine": "swift"]
    }

    private static func globRegex(_ glob: String) -> String {
        var result = "(^|.*/)"
        var index = glob.startIndex
        while index < glob.endIndex {
            let c = glob[index]
            if c == "*" {
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    let after = glob.index(after: next)
                    if after < glob.endIndex, glob[after] == "/" { result += "(?:.*/)?"; index = after }
                    else { result += ".*"; index = next }
                } else { result += "[^/]*" }
            }
            else if c == "?" { result += "[^/]" }
            else { result += NSRegularExpression.escapedPattern(for: String(c)) }
            index = glob.index(after: index)
        }
        return result + "$"
    }

    private func detectProject() -> (projectType: String, languages: [String], frameworks: [String], packageManager: String?, scripts: [String: String]) {
        func has(_ name: String) -> Bool {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().path == url.path,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        var projectType = "unknown", languages: [String] = [], frameworks: [String] = [], packageManager: String?, scripts: [String: String] = [:]
        if has("package.json") {
            projectType = "node"; languages.append("JavaScript")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("package.json")), let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                scripts = (package["scripts"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
                let dependencies = (package["dependencies"] as? [String: Any] ?? [:]).merging(package["devDependencies"] as? [String: Any] ?? [:]) { _, rhs in rhs }
                let known = ["next": "Next.js", "react": "React", "vue": "Vue", "svelte": "Svelte", "express": "Express", "fastify": "Fastify", "@nestjs/core": "NestJS", "electron": "Electron", "vitest": "Vitest", "jest": "Jest"]
                for key in known.keys.sorted() where dependencies[key] != nil { frameworks.append(known[key]!) }
            }
            if has("pnpm-lock.yaml") { packageManager = "pnpm" } else if has("yarn.lock") { packageManager = "yarn" } else if has("bun.lockb") || has("bun.lock") { packageManager = "bun" } else if has("package-lock.json") { packageManager = "npm" }
        }
        if has("tsconfig.json") { languages.append("TypeScript") }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") { languages.append("Python"); if projectType == "unknown" { projectType = "python" } }
        if has("Cargo.toml") { languages.append("Rust"); if projectType == "unknown" { projectType = "rust" } }
        if has("go.mod") { languages.append("Go"); if projectType == "unknown" { projectType = "go" } }
        if has("Package.swift") { languages.append("Swift"); if projectType == "unknown" { projectType = "swift" } }
        return (projectType, languages, frameworks, packageManager, scripts)
    }

    func runGit(_ arguments: [String]) -> (ok: Bool, data: Data, text: String) {
        let process = Process(), stdout = Pipe(), lock = NSLock()
        var collected = Data(), exceededLimit = false
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "-c", "core.fsmonitor=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_EXTERNAL_DIFF"] { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_PAGER"] = "cat"
        process.environment = environment
        process.standardOutput = stdout; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            if collected.count + chunk.count <= 64 * 1024 * 1024 { collected.append(chunk) } else { exceededLimit = true }
            lock.unlock()
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return (false, Data(), "") }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.05); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); return (false, Data(), "") }
        stdout.fileHandleForReading.readabilityHandler = nil
        let tail = stdout.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); if collected.count + tail.count <= 64 * 1024 * 1024 { collected.append(tail) } else { exceededLimit = true }; let data = collected; lock.unlock()
        return (process.terminationStatus == 0 && !exceededLimit, data, String(data: data, encoding: .utf8) ?? "")
    }

    func gitInfo() -> [String: Any] {
        let check = runGit(["rev-parse", "--is-inside-work-tree"])
        guard check.ok, check.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return ["isRepo": false, "branch": NSNull(), "commit": NSNull(), "dirty": false] }
        let branch = runGit(["rev-parse", "--abbrev-ref", "HEAD"]), commit = runGit(["rev-parse", "--short", "HEAD"]), status = runGit(["status", "--porcelain", "--", "."])
        return ["isRepo": true, "branch": branch.ok ? branch.text.trimmingCharacters(in: .whitespacesAndNewlines) : NSNull(), "commit": commit.ok ? commit.text.trimmingCharacters(in: .whitespacesAndNewlines) : NSNull(), "dirty": status.ok && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty]
    }
}
