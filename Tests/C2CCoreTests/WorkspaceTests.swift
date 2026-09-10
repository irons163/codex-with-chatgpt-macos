import XCTest
import CryptoKit
@testable import C2CCore

final class WorkspaceTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; roots.removeAll() }

    private func temporary(_ name: String = "workspace") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c2c-swift-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url); return url
    }
    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url)
    }
    @discardableResult private func git(_ root: URL, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", root.path] + arguments; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit(); let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output); return output
    }

    func testStableIdentityAndProjectDetection() throws {
        let root = try temporary(); try write(root, "package.json", #"{"scripts":{"test":"vitest run","bad":42},"dependencies":{"react":"19"}}"#); try write(root, "tsconfig.json", "{}")
        let workspace = try Workspace(root: root.path)
        let canonical = root.resolvingSymlinksInPath().path
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == true
        let expected = SHA256.hash(data: Data((caseSensitive ? canonical : canonical.lowercased()).utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        XCTAssertEqual(workspace.id, String(expected)); XCTAssertEqual(workspace.id.count, 12)
        let info = workspace.info(); XCTAssertEqual(info["projectType"] as? String, "node"); XCTAssertTrue((info["frameworks"] as? [String])?.contains("React") == true)
        XCTAssertEqual((info["scripts"] as? [String: String])?["test"], "vitest run"); XCTAssertNil((info["scripts"] as? [String: String])?["bad"]); XCTAssertNil(info["root"])
    }

    func testTraversalSymlinkAndSensitiveFilesAreDenied() throws {
        let root = try temporary(), outside = try temporary("outside"); try write(root, "hello.txt", "hello\n"); try write(root, ".env", "SECRET=hidden\n"); try write(root, ".env.example", "SAFE=sample\n"); try write(root, ".c2cignore", "private-notes/\n"); try write(root, "private-notes/todo.md", "hidden\n"); try write(outside, "secret.txt", "outside\n")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let workspace = try Workspace(root: root.path)
        XCTAssertThrowsError(try workspace.resolve("../../etc/passwd")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .pathOutsideWorkspace) }
        XCTAssertThrowsError(try workspace.resolve("escape/secret.txt")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .pathOutsideWorkspace) }
        XCTAssertThrowsError(try workspace.resolve(".env")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .accessDeniedSensitiveFile) }
        XCTAssertThrowsError(try workspace.resolve(".git/config")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .accessDeniedSensitiveFile) }
        XCTAssertThrowsError(try workspace.resolve("private-notes/todo.md")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .accessDeniedSensitiveFile) }
        XCTAssertNoThrow(try workspace.resolve(".env.example"))
    }

    func testListingSearchAndReadPaginationHonorIgnoreFiles() throws {
        let root = try temporary(); try write(root, ".gitignore", "generated/\n"); try write(root, "generated/secret.txt", "needle\n"); try write(root, "src/app.swift", "let needle = 1\n"); try write(root, ".build/noise.txt", "needle\n")
        let lines = (1...1_000).map { "line \($0)" }.joined(separator: "\n") + "\n"; try write(root, "big.txt", lines)
        let workspace = try Workspace(root: root.path)
        let listing = try workspace.listDirectory(".", depth: 3, limit: 500) ; let paths = (listing["entries"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
        XCTAssertTrue(paths.contains("src/app.swift")); XCTAssertFalse(paths.contains(where: { $0.hasPrefix("generated") || $0.hasPrefix(".build") }))
        let search = try workspace.search(query: "needle"); let matches = search["matches"] as? [[String: Any]] ?? []
        XCTAssertEqual(matches.compactMap { $0["path"] as? String }, ["src/app.swift"])
        let page = try workspace.readFile("big.txt"); XCTAssertEqual(page["endLine"] as? Int, 400); XCTAssertEqual(page["nextStartLine"] as? Int, 401); XCTAssertEqual(page["remainingLines"] as? Int, 600)
    }

    func testGitDiffNeverLeaksSensitiveFilesOrRenameBodies() throws {
        let root = try temporary(); _ = try git(root, ["init", "-b", "main"]); _ = try git(root, ["config", "user.email", "test@example.com"]); _ = try git(root, ["config", "user.name", "Test"])
        try write(root, "visible.txt", "base\n"); try write(root, ".npmrc", "token=rename-secret\n"); _ = try git(root, ["add", "-f", ".npmrc", "visible.txt"]); _ = try git(root, ["commit", "-m", "base"])
        try write(root, "visible.txt", "safe-change\n"); _ = try git(root, ["mv", ".npmrc", "public.txt"])
        let workspace = try Workspace(root: root.path); let diff = workspace.gitDiff(mode: "staged", path: nil, offset: 0, maxBytes: 65_536)["diff"] as? String ?? ""
        XCTAssertFalse(diff.contains("rename-secret")); XCTAssertFalse(diff.contains("public.txt"))
        let unstaged = workspace.gitDiff(mode: "unstaged", path: nil, offset: 0, maxBytes: 65_536)["diff"] as? String ?? ""
        XCTAssertTrue(unstaged.contains("safe-change"))
    }

    func testReadRangeEdgeCasesAndFIFOFailSafely() throws {
        let root = try temporary(); try write(root, "short.txt", "one\ntwo\n"); try write(root, "huge-line.txt", String(repeating: "x", count: 300_000))
        let workspace = try Workspace(root: root.path)
        let empty = try workspace.readFile("short.txt", startLine: 2, endLine: 1)
        XCTAssertEqual(empty["content"] as? String, ""); XCTAssertEqual(empty["endLine"] as? Int, 1)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try workspace.readFile("pipe")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .notAFile) }
        XCTAssertThrowsError(try workspace.readFile("huge-line.txt")) { XCTAssertEqual(($0 as? WorkspaceError)?.code, .fileTooLarge) }
    }

    func testGitRepositoryCommandsCannotRunDiffOrFsmonitorHooks() throws {
        let root = try temporary(); _ = try git(root, ["init", "-b", "main"]); _ = try git(root, ["config", "user.email", "test@example.com"]); _ = try git(root, ["config", "user.name", "Test"])
        try write(root, ".gitattributes", "*.txt diff=evil\n"); try write(root, "safe.txt", "base\n"); _ = try git(root, ["add", "."]); _ = try git(root, ["commit", "-m", "base"])
        let marker = root.appendingPathComponent("hook-ran")
        let script = root.appendingPathComponent("evil.sh"); try write(root, "evil.sh", "#!/bin/sh\ntouch '\(marker.path)'\ncat \"$2\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        _ = try git(root, ["config", "diff.evil.command", script.path]); _ = try git(root, ["config", "core.fsmonitor", script.path]); try write(root, "safe.txt", "changed\n")
        let workspace = try Workspace(root: root.path); _ = workspace.gitStatus(); _ = workspace.gitDiff(mode: "unstaged", path: nil, offset: 0, maxBytes: 65_536)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testNestedWorkspaceDiffUsesWorkspaceRelativeIgnoreRules() throws {
        let repository = try temporary("repository"), nested = repository.appendingPathComponent("packages/app"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try git(repository, ["init", "-b", "main"]); _ = try git(repository, ["config", "user.email", "test@example.com"]); _ = try git(repository, ["config", "user.name", "Test"])
        try write(nested, ".c2cignore", "/private.txt\n"); try write(nested, "private.txt", "base-secret\n"); try write(nested, "visible.txt", "base\n"); _ = try git(repository, ["add", "."]); _ = try git(repository, ["commit", "-m", "base"])
        try write(nested, "private.txt", "nested-secret-value\n"); try write(nested, "visible.txt", "nested-visible-value\n")
        let diff = try Workspace(root: nested.path).gitDiff(mode: "unstaged", path: nil, offset: 0, maxBytes: 65_536)["diff"] as? String ?? ""
        XCTAssertTrue(diff.contains("nested-visible-value")); XCTAssertFalse(diff.contains("nested-secret-value")); XCTAssertFalse(diff.contains("private.txt"))
    }
}
