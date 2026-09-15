import Foundation
import CryptoKit
import Darwin

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
    static let policyMarker = "# c2c-ignore-policy-v1"
    static let defaultPolicy = """
    # c2c-ignore-policy-v1
    # Attachment and workspace exclusion policy.
    # Edit this file like .gitignore. Removing a rule may expose sensitive data to ChatGPT.

    # Environment files (keep the public example)
    .env
    .env.*
    !.env.example

    # Private keys, certificates, credentials and local account data
    *.pem
    *.key
    *.p12
    *.pfx
    *.jks
    *.keystore
    id_rsa
    id_rsa.*
    id_ed25519
    id_ed25519.*
    id_ecdsa
    id_ecdsa.*
    id_dsa
    id_dsa.*
    .ssh/
    .aws/
    .gnupg/
    .npmrc
    .netrc
    _netrc
    .git-credentials
    *.keychain
    *.keychain-db
    .cloudflared/
    credentials.json
    service-account*.json
    secrets.json
    cookies.sqlite
    Cookies
    .c2c-secrets*

    # Generated files, dependencies and build caches
    .git/
    node_modules/
    dist/
    build/
    out/
    .next/
    .nuxt/
    .svelte-kit/
    coverage/
    .cache/
    .turbo/
    .venv/
    venv/
    __pycache__/
    .pytest_cache/
    .mypy_cache/
    target/
    .gradle/
    .idea/
    .tooling/
    .pnpm-store/
    .build/
    .swiftpm/
    .DS_Store
    *.lock
    pnpm-lock.yaml
    package-lock.json
    yarn.lock
    """

    private let policy: [IgnoreRule]
    private let git: [IgnoreRule]

    init(root: String) {
        let customText = Self.loadText(root: root, name: ".c2cignore")
        let policyText: String
        if let customText, customText.contains(Self.policyMarker) {
            policyText = customText
        } else {
            policyText = Self.defaultPolicy + (customText.map { "\n\n# Existing project-specific rules\n" + $0 } ?? "")
        }
        policy = Self.rules(policyText.components(separatedBy: .newlines))
        git = Self.load(root: root, name: ".gitignore")
    }

    func isSensitive(_ path: String) -> Bool {
        !path.isEmpty && path != "." && Self.matches(path, rules: policy)
    }

    func isHidden(_ path: String) -> Bool {
        isSensitive(path) || Self.matches(path, rules: git)
    }

    private static func load(root: String, name: String) -> [IgnoreRule] {
        rules(loadText(root: root, name: name)?.components(separatedBy: .newlines) ?? [])
    }

    private static func loadText(root: String, name: String) -> String? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        let canonical = url.resolvingSymlinksInPath().path
        guard (canonical == root || canonical.hasPrefix(root + "/")), canonical == url.path,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }

    static func prepareEditablePolicy(root: String) throws -> URL {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".c2cignore")
        var existing = ""
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw C2CError(".c2cignore 必須是工作目錄中的一般檔案，不能是 symlink。")
            }
            existing = try String(contentsOf: url, encoding: .utf8)
            if existing.contains(policyMarker) { return url }
        }
        var policyText = defaultPolicy
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            policyText += "\n\n# Existing project-specific rules migrated from the previous format\n" + existing
            if !policyText.hasSuffix("\n") { policyText += "\n" }
        }
        try writePolicy(policyText, to: url)
        return url
    }

    private static func writePolicy(_ text: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".c2cignore.\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw C2CError("無法建立 .c2cignore。") }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw C2CError("無法寫入 .c2cignore。") }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw C2CError("無法儲存 .c2cignore。")
        }
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

    public init(root rootInput: String) throws {
        let expanded = (rootInput as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let standardized = (absolute as NSString).standardizingPath
        let real = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory) else {
            throw C2CError("Workspace root does not exist: \(rootInput)")
        }
        guard isDirectory.boolValue else {
            throw C2CError("Workspace root is not a directory: \(rootInput)")
        }
        self.root = real
        let caseSensitive = (try? URL(fileURLWithPath: real).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == true
        let digest = SHA256.hash(data: Data((caseSensitive ? real : real.lowercased()).utf8))
        self.id = digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
        self.name = URL(fileURLWithPath: real).lastPathComponent
        self.ignoreRules = WorkspaceIgnoreRules(root: real)
    }

    func prepareEditableIgnorePolicy() throws -> URL {
        try WorkspaceIgnoreRules.prepareEditablePolicy(root: root)
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

    /// Recursively discovers safe text files for ChatGPT attachments.
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

}
